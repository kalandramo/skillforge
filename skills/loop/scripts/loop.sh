#!/usr/bin/env bash
# loop.sh — 迭代账本与判定引擎（语言无关，零外部依赖）
#
# 职责边界（这是本脚本存在的唯一理由）：
#   只做「记录 / 判定 / 回滚」，不做「验证」。
#   验证（build/lint/test/bench）由 gate 负责：Go 项目用 go-gate/scripts/gate.sh，
#   其他语言由编排层直接跑命令出指标。指标怎么来得不归这里管，怎么比归这里管。
#   这样同一个账本能服务任何语言，不会因为换技术栈就要重写判定逻辑。
#
# 设计约束：
#   1. 配置用 shell 而非 JSON —— 不引入 jq 等外部解析依赖
#   2. 不隐式执行破坏性 git 操作 —— keep/revert 必须显式调用
#   3. 无度量时性能结论一律不成立 —— 拒绝把"没测"写成"没变差"
#
# 子命令：
#   init [dir]                            生成 .dev/loop.conf（不覆盖已有）
#   baseline <metric|NA>                  写基线（iter=0）
#   decide <metric> [--goal=perf]         与历史最优比，输出 KEEP / REVERT / INVALID
#   record <iter> <verdict> <metric> <gate> <goal> <note>
#   keep <iter> <metric> <note> [goal]    提交本轮改动并记账
#   revert                                回到上一个 keep 状态
#   next                                  输出 CONTINUE <n> 或 STOP:<reason>
#   report                                生成 .dev/REPORT.md
#   status                                当前进度与最优值
#
# 项目定位：LOOP_PROJECT=/path/to/repo；未设置时从 $PWD 向上查找 .dev

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT=""
STATE_DIR=""

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }
rule() { printf '%s\n' "------------------------------------------------------------"; }

# ---------------------------------------------------------------- 项目与配置
resolve_project() {
  local p="${LOOP_PROJECT:-}"
  if [ -n "$p" ]; then
    PROJECT_ROOT="$(cd "$p" 2>/dev/null && pwd)" || die "项目路径不存在: $p"
  else
    local d="$PWD"
    while [ "$d" != "/" ] && [ -n "$d" ]; do
      if [ -d "$d/.dev" ]; then PROJECT_ROOT="$d"; break; fi
      d="$(dirname "$d")"
    done
    [ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$PWD"
  fi
  STATE_DIR="$PROJECT_ROOT/.dev"
}

cfg_load() {
  local cfg="$STATE_DIR/loop.conf"
  [ -f "$cfg" ] || die "未找到配置 $cfg，先运行: loop.sh init"
  # 去 CRLF：Windows + core.autocrlf=true 会在 checkout 注入 \r，导致 source 失败
  local tmp
  tmp=$(mktemp 2>/dev/null || echo "$STATE_DIR/.cfgload.$$")
  tr -d '\r' < "$cfg" > "$tmp"
  # shellcheck disable=SC1090
  . "$tmp"
  rm -f "$tmp"
  : "${METRIC_NAME:=metric}"
  : "${METRIC_DIRECTION:=lower}"
  : "${METRIC_EPSILON_PCT:=1.0}"
  : "${METRIC_TARGET:=}"
  : "${MAX_ITERATIONS:=5}"
  : "${MAX_NO_IMPROVE:=2}"
  : "${MAX_GATE_FAILURES:=3}"
  : "${KEEP_ON_FLAT:=1}"
}

results_file() { echo "$STATE_DIR/results.tsv"; }

ensure_results_header() {
  local f; f="$(results_file)"
  if [ ! -f "$f" ]; then
    printf 'iter\tverdict\tmetric\tdelta_pct\tgate\tgoal\tnote\tts\n' > "$f"
  fi
}

is_number() { printf '%s' "$1" | grep -qE '^\-?[0-9]+\.?[0-9]*$'; }

best_metric() {
  # 历史最优：verdict 属于 baseline/keep 且指标为数值的行，按方向取极值
  local f; f="$(results_file)"
  [ -f "$f" ] || { echo ""; return; }
  awk -F'\t' -v dir="$METRIC_DIRECTION" '
    NR > 1 && ($2 == "baseline" || $2 == "keep") && $3 ~ /^-?[0-9.]+$/ {
      if (best == "") { best = $3+0; it = $1 }
      else if (dir == "lower" && $3+0 < best) { best = $3+0; it = $1 }
      else if (dir == "higher" && $3+0 > best) { best = $3+0; it = $1 }
    }
    END { if (best != "") printf "%.6g\n", best }
  ' "$f"
}

best_iter() {
  local f; f="$(results_file)"
  [ -f "$f" ] || { echo ""; return; }
  awk -F'\t' -v dir="$METRIC_DIRECTION" '
    NR > 1 && ($2 == "baseline" || $2 == "keep") && $3 ~ /^-?[0-9.]+$/ {
      if (best == "") { best = $3+0; it = $1 }
      else if (dir == "lower" && $3+0 < best) { best = $3+0; it = $1 }
      else if (dir == "higher" && $3+0 > best) { best = $3+0; it = $1 }
    }
    END { if (it != "") print it }
  ' "$f"
}

delta_pct() {
  awk -v n="$1" -v o="$2" 'BEGIN{
    if (o+0 == 0) { printf "0.00"; exit }
    printf "%.2f", (n-o)/o*100
  }'
}

is_improved() {
  # 依据方向与 epsilon 判定是否达到"可归因的改善"
  awk -v n="$1" -v b="$2" -v dir="$METRIC_DIRECTION" -v eps="$METRIC_EPSILON_PCT" 'BEGIN{
    if (dir == "lower") { th = b * (1 - eps/100); exit (n <= th) ? 0 : 1 }
    else                { th = b * (1 + eps/100); exit (n >= th) ? 0 : 1 }
  }'
}

rounds_done() {
  local f; f="$(results_file)"
  [ -f "$f" ] || { echo 0; return; }
  awk -F'\t' 'NR>1 && $1 ~ /^[0-9]+$/ { if ($1+0 > m) m = $1+0 } END { print m+0 }' "$f"
}

consecutive() {
  # 末尾连续出现 verdict=$1 的次数（baseline 行天然打断连续）
  local f; f="$(results_file)"
  [ -f "$f" ] || { echo 0; return; }
  awk -F'\t' -v t="$1" '
    { v[NR] = $2 }
    END {
      c = 0
      for (i = NR; i >= 2; i--) { if (v[i] == t) c++; else break }
      print c
    }' "$f"
}

# ---------------------------------------------------------------- 子命令
cmd_init() {
  local target="${1:-$PWD}"
  target="$(cd "$target" 2>/dev/null && pwd)" || die "路径不存在: ${1:-$PWD}"
  # 注意：不能写成 local dir=... cfg="$dir/..."，local 会先展开参数再赋值
  local dir
  dir="$target/.dev"
  local cfg="$dir/loop.conf"
  if [ -f "$cfg" ]; then info "配置已存在，跳过: $cfg"; return 0; fi
  mkdir -p "$dir"
  cat > "$cfg" <<'EOF'
# loop 配置 —— 由 loop.sh init 生成
# 本文件只描述「怎么判定」，不描述「怎么验证」。验证命令由 gate 负责。

# --- 指标定义（无 benchmark 的项目把 METRIC_NAME 留空，全流程禁止出现性能结论）---
METRIC_NAME="ns_per_op"
METRIC_DIRECTION="lower"      # lower | higher
METRIC_EPSILON_PCT=1.0        # 相对改善小于该百分比视为「无改善」，防止噪声冒充优化
METRIC_TARGET=""              # 可选：达到此值即停止（STOP:target）

# --- 循环控制 ---
MAX_ITERATIONS=5              # 轮数上限
MAX_NO_IMPROVE=2              # 连续 revert 轮数上限（进入噪声区或方向耗尽）
MAX_GATE_FAILURES=3           # 连续门禁失败上限（说明假设方向错误，换参数无用）
KEEP_ON_FLAT=1                # 指标持平时的默认处置：1=保留（feature 轮）0=回滚（perf 轮）
EOF
  printf 'results.tsv\nREPORT.md\ngate/\ntasks/\nrun.json\n' > "$dir/.gitignore"
  info "已生成: $cfg"
}

cmd_baseline() {
  local metric="${1:-NA}"
  ensure_results_header
  if [ "$metric" != "NA" ] && ! is_number "$metric"; then
    die "基线指标必须是数值或 NA，收到: $metric"
  fi
  # iter=0 表示基线；重复执行会追加新基线，历史最优自动采纳更优者
  printf '0\tbaseline\t%s\t0.00\tPASS\tbaseline\tbaseline\t%s\n' \
    "$metric" "$(date '+%Y-%m-%dT%H:%M:%S')" >> "$(results_file)"
  info "基线已记录: $METRIC_NAME = $metric"
}

cmd_decide() {
  local metric="" goal=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --goal=*) goal="${1#*=}" ;;
      -*) die "未知选项: $1" ;;
      *) metric="$1" ;;
    esac
    shift
  done

  # 非数值且非 NA/SKIP → 拒绝判定。把解析失败当成"无变化"是最危险的一类假通过。
  if [ "$metric" != "NA" ] && [ "$metric" != "SKIP" ] && ! is_number "$metric"; then
    echo "INVALID"
    echo "  [错误] 指标 '$metric' 不是数值。检查 gate 的指标抽取逻辑，不要重试同一条命令。" >&2
    return 2
  fi

  local best; best=$(best_metric)
  if [ -z "$best" ]; then echo "BASELINE"; return 0; fi

  # 无度量：性能结论不成立，只能由门禁决定去留
  if [ "$metric" = "NA" ] || [ "$metric" = "SKIP" ]; then
    echo "KEEP"; return 0
  fi

  # 达标即停止条件，优先于 epsilon
  if [ -n "$METRIC_TARGET" ] && [ "$METRIC_DIRECTION" = "lower" ] \
     && awk -v m="$metric" -v t="$METRIC_TARGET" 'BEGIN{exit (m<=t)?0:1}'; then
    echo "KEEP"; return 0
  fi

  if is_improved "$metric" "$best"; then
    echo "KEEP"
  elif [ "$goal" = "perf" ] && [ "$KEEP_ON_FLAT" = "1" ]; then
    # perf 轮的持平不算成绩：目标就是变快，没变快就该回滚
    echo "REVERT"
  elif [ "$KEEP_ON_FLAT" = "1" ]; then
    echo "KEEP"
  else
    echo "REVERT"
  fi
}

cmd_record() {
  local iter="${1:-0}" verdict="${2:-unknown}" metric="${3:-NA}"
  local gate="${4:-PASS}" goal="${5:-feature}" note="${6:-}"
  local f; f="$(results_file)"
  ensure_results_header
  local delta="-"
  local best; best=$(best_metric)
  if [ -n "$best" ] && [ "$metric" != "NA" ] && [ "$metric" != "SKIP" ] && is_number "$metric"; then
    delta=$(delta_pct "$metric" "$best")
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$iter" "$verdict" "$metric" "$delta" "$gate" "$goal" "$note" \
    "$(date '+%Y-%m-%dT%H:%M:%S')" >> "$f"
  info "已记录 iter=$iter verdict=$verdict metric=$metric delta=${delta}% goal=$goal"
}

cmd_keep() {
  local iter="${1:-0}" metric="${2:-NA}" note="${3:-}" goal="${4:-feature}"
  ( cd "$PROJECT_ROOT" \
    && git add -A \
    && git commit -q -m "dev(round $iter): ${note:-无描述} [${METRIC_NAME}=${metric}]" ) \
    || die "commit 失败（工作树可能无改动）"
  cmd_record "$iter" "keep" "$metric" "PASS" "$goal" "$note"
}

cmd_revert() {
  # -e .dev 保护账本自身：回滚代码但保留记录，否则审计链断裂
  ( cd "$PROJECT_ROOT" \
    && git reset -q --hard HEAD \
    && git clean -qfd -e .dev ) || die "revert 失败"
  info "已回滚到上一个 keep 状态（工作树干净，.dev 保留）"
}

cmd_next() {
  # 把 SKILL.md 里的停止条件变成确定性输出，而不是靠 agent 自觉
  local f; f="$(results_file)"
  if [ ! -f "$f" ]; then echo "CONTINUE 1"; return 0; fi

  local best; best=$(best_metric)

  # 1) 达标即停
  if [ -n "$METRIC_TARGET" ] && [ -n "$best" ]; then
    if [ "$METRIC_DIRECTION" = "lower" ] \
       && awk -v b="$best" -v t="$METRIC_TARGET" 'BEGIN{exit (b<=t)?0:1}'; then
      echo "STOP:target"; return 0
    fi
  fi

  # 2) 连续 revert 达到上限 → 方向耗尽或噪声区
  local rv; rv=$(consecutive "revert")
  if [ "$rv" -ge "$MAX_NO_IMPROVE" ]; then echo "STOP:no_improve"; return 0; fi

  # 3) 连续门禁失败达到上限 → 假设方向错误
  local gf; gf=$(consecutive "gatefail")
  if [ "$gf" -ge "$MAX_GATE_FAILURES" ]; then echo "STOP:gate_failures"; return 0; fi

  # 4) 轮数用尽
  local done_n; done_n=$(rounds_done)
  if [ "$done_n" -ge "$MAX_ITERATIONS" ]; then echo "STOP:max_rounds"; return 0; fi

  echo "CONTINUE $((done_n + 1))"
}

cmd_report() {
  local f; f="$(results_file)"
  [ -f "$f" ] || die "无 results.tsv，先建立基线"
  local out="$STATE_DIR/REPORT.md"
  local best; best=$(best_metric)
  {
    echo "# 迭代报告"
    echo
    echo "- 项目: \`$PROJECT_ROOT\`"
    echo "- 指标: ${METRIC_NAME}（${METRIC_DIRECTION} is better，epsilon=${METRIC_EPSILON_PCT}%）"
    echo "- 最优: ${best:-未度量}（来自 iter $(best_iter)）"
    echo "- 已用轮次: $(rounds_done) / ${MAX_ITERATIONS}"
    echo "- 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "## 每轮结果"
    echo
    echo "| iter | 判决 | 指标 | 相对最优 | 目标 | 说明 |"
    echo "|---:|---|---:|---:|---|---|"
    awk -F'\t' 'NR>1 {
      d = ($4 == "-" || $4 == "") ? "—" : $4 "%"
      printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, d, $6, $7
    }' "$f"
    echo
    echo "## 结论"
    echo
    local keeps reverts fails
    keeps=$(awk -F'\t' 'NR>1 && $2=="keep"' "$f" | wc -l | tr -d ' ')
    reverts=$(awk -F'\t' 'NR>1 && $2=="revert"' "$f" | wc -l | tr -d ' ')
    fails=$(awk -F'\t' 'NR>1 && $2=="gatefail"' "$f" | wc -l | tr -d ' ')
    echo "- 保留 ${keeps} 轮，回滚 ${reverts} 轮，门禁失败 ${fails} 轮"
    if [ -z "$best" ] || [ "$best" = "NA" ]; then
      echo "- **本轮无有效度量，性能结论不成立**（仅功能性改动）"
    else
      echo "- 最优值 ${best}（来自 iter $(best_iter)）"
      if [ "$reverts" -gt 0 ]; then
        echo "- 有 ${reverts} 轮因未达改善被判回滚，其指标不得作为结论引用"
      fi
    fi
  } > "$out"
  info "已生成: $out"
}

cmd_status() {
  rule; info "项目: $PROJECT_ROOT"
  local f; f="$(results_file)"
  if [ -f "$f" ]; then
    info "已用轮次: $(rounds_done) / ${MAX_ITERATIONS}"
    awk -F'\t' 'NR>1 {
      d = ($4 == "-" || $4 == "") ? "—" : $4 "%"
      printf "  %-3s %-9s %-12s %8s  %s\n", $1, $2, $3, d, $7
    }' "$f"
  else
    info "尚未建立基线"
  fi
  info "历史最优: $(best_metric)（来自 iter $(best_iter)）"
  info "下一步: $(cmd_next)"
  rule
}

usage() {
  sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

# ---------------------------------------------------------------- 入口
SUB="${1:-}"; shift || true
case "$SUB" in
  init)     cmd_init "${1:-$PWD}" ;;
  baseline) resolve_project; cfg_load; cmd_baseline "${1:-NA}" ;;
  decide)   resolve_project; cfg_load; cmd_decide "$@" ;;
  record)   resolve_project; cfg_load; cmd_record "${1:-0}" "${2:-unknown}" "${3:-NA}" "${4:-PASS}" "${5:-feature}" "${6:-}" ;;
  keep)     resolve_project; cfg_load; cmd_keep "${1:-0}" "${2:-NA}" "${3:-}" "${4:-feature}" ;;
  revert)   resolve_project; cfg_load; cmd_revert ;;
  next)     resolve_project; cfg_load; cmd_next ;;
  report)   resolve_project; cfg_load; cmd_report ;;
  status)   resolve_project; cfg_load; cmd_status ;;
  "")       usage ;;
  *)        echo "未知子命令: $SUB" >&2; usage ;;
esac
