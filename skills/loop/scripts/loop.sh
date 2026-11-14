#!/usr/bin/env bash
# loop.sh — 迭代账本与判定引擎（语言无关，零外部依赖）
#
# 职责边界（这是本脚本存在的唯一理由）：
#   只做「记录 / 判定 / 回滚 / 审计」，不做「验证」。
#   验证（build/lint/test/bench）由 gate 负责：Go 项目用 go-gate/scripts/gate.sh，
#   其他语言由编排层直接跑命令出指标。指标怎么来得不归这里管，怎么比归这里管。
#   这样同一个账本能服务任何语言，不会因为换技术栈就要重写判定逻辑。
#
# 设计约束：
#   1. 配置用 shell 而非 JSON —— 不引入 jq 等外部解析依赖
#   2. 不隐式执行破坏性 git 操作 —— keep/revert 必须显式调用
#   3. 无度量时性能结论一律不成立 —— 拒绝把"没测"写成"没变差"
#   4. 账本是可回放的状态机 —— 写入前过不变量审计（借鉴 autoresearch validate.ts）
#
# 子命令：
#   init [dir]                 生成 .dev/loop.conf（不覆盖已有）
#   baseline <metric|NA>       写基线（iter=0），并锁定基准指纹（drift 检测起点）
#   decide <metric> [--goal=perf]   与历史最优比，输出 KEEP / REVERT / INVALID
#   metric [--name=X]          从 stdin 的 'METRIC 名=值' 行抽取指标值（任意语言接入）
#   record <iter> <verdict> <metric> <gate> <goal> <note>
#       [--hyp= --next= --rollback=]   写一行账本（写入前过审计）
#   keep <iter> <metric> <note> [goal]
#       [--hyp= --next= --rollback=]   git 提交本轮改动并记账（先过审计）
#   revert                     回到上一个 keep 状态（账本保留）
#   next                       输出 CONTINUE <n> 或 STOP:<reason>（含震荡检测）
#   audit                      校验整个账本的不变量（无需候选行）
#   drift [--set]              基准漂移检测；--set 在有意变更后重新锁定指纹
#   report                     生成 .dev/REPORT.md
#   status                     当前进度与最优值
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
  [ -f "$cfg" ] || die "未找到配置 ${cfg}，先运行: loop.sh init"
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
  : "${MEASURE_CMD:=}"
  : "${MEASURE_FILES:=}"
  : "${AUDIT_BYPASS:=0}"
}

results_file() { echo "$STATE_DIR/results.tsv"; }

ensure_results_header() {
  local f; f="$(results_file)"
  if [ ! -f "$f" ]; then
    printf 'iter\tverdict\tmetric\tdelta_pct\tgate\tgoal\tnote\tts\tasi\tcommit\n' > "$f"
  fi
}

is_number() { printf '%s' "$1" | grep -qE '^\-?[0-9]+\.?[0-9]*$'; }

# 清理字段：TSV 单行字段不得含 tab/换行/CR
clean_field() { printf '%s' "${1:-}" | tr '\t\n\r' '   '; }

# ASI 编码：hyp=..|next=..|rollback=..（内容中的 | 会被替换为 /，避免破坏编码）
asi_encode() {
  local parts=""
  local h; h=$(printf '%s' "${1:-}" | tr '|' '/')
  local n; n=$(printf '%s' "${2:-}" | tr '|' '/')
  local r; r=$(printf '%s' "${3:-}" | tr '|' '/')
  [ -n "$h" ] && parts="hyp=$h"
  [ -n "$n" ] && parts="${parts:+$parts|}next=$n"
  [ -n "$r" ] && parts="${parts:+$parts|}rollback=$r"
  printf '%s' "$parts"
}

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
  awk -F'\t' 'NR>1 && $1 ~ /^[0-9]+$/ && $2 != "baseline" { if ($1+0 > m) m = $1+0 } END { print m+0 }' "$f"
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

# ---------------------------------------------------------------- 账本审计
# 不变量（借鉴 autoresearch validate.ts，适配 skillforge 的 TSV 账本）：
#   event_order          非基线行轮次必须连续（允许同轮重记，如门禁失败后重试同一轮）
#   no_baseline          轮次记录（iter>=1）不得先于基线出现（iter=0 修复行豁免）
#   keep_without_improvement   perf 轮的 keep 指标必须优于保留最优（epsilon 感知）
#   metric_format        keep 行指标非数值（NA/SKIP 豁免）
#   discarded_improvement      gate=PASS 的 revert 不得丢弃真实改善（epsilon 内噪声豁免）
#   commit_field         keep 行必须带 commit；非 keep 行不得带 commit（8 列旧账本豁免）
# 旧版 8 列账本（无 asi/commit 列）跳过 commit_field 检查。
audit_check() {
  # 参数（候选行，可为空串 = 只审计既有账本）: iter verdict metric gate goal commit
  local c_iter="${1:-}" c_verdict="${2:-}" c_metric="${3:-}" c_gate="${4:-}" c_goal="${5:-}" c_commit="${6:-}"
  local f; f="$(results_file)"
  [ -f "$f" ] || return 0
  local out rc
  out=$(awk -F'\t' \
    -v dir="$METRIC_DIRECTION" -v eps="$METRIC_EPSILON_PCT" \
    -v c_iter="$c_iter" -v c_verdict="$c_verdict" -v c_metric="$c_metric" \
    -v c_gate="$c_gate" -v c_goal="$c_goal" -v c_commit="$c_commit" '
    function isnum(s) { return s ~ /^-?[0-9]+\.?[0-9]*$/ }
    function better(n, b) {
      if (dir == "lower") return (n+0) <= (b+0) * (1 - eps/100)
      return (n+0) >= (b+0) * (1 + eps/100)
    }
    function bad(code, src, msg) {
      n_bad++
      printf "  [审计] %s (%s): %s\n", code, src, msg > "/dev/stderr"
    }
    function adopt(m) { if (isnum(m) && (retained == "" || better(m, retained))) retained = m }
    function check(iter, verdict, metric, gate, goal, commit, have_commit, src) {
      if (verdict == "baseline") { saw_base = 1; adopt(metric); return }
      if (iter == 0) { adopt(metric); return }   # round-0 修复行：不要求基线已存在
      if (iter !~ /^[0-9]+$/) {
        bad("event_order", src, "轮次编号非数字: " iter)
      } else if (iter != expected && iter != expected - 1) {
        bad("event_order", src, "轮次不连续: 期望 " expected "（或同轮重记 " expected - 1 "），实际 " iter)
      } else if (iter == expected) {
        expected = iter + 1
      }
      if (!saw_base) bad("no_baseline", src, "iter " iter " 先于基线出现，先 loop baseline")
      if (verdict == "keep") {
        if (metric == "NA" || metric == "SKIP") {
          # 无度量：性能结论不成立，功能性保留，不算违规
        } else if (!isnum(metric)) {
          bad("metric_format", src, "keep 指标非数值: " metric)
        } else if (goal == "perf" && retained != "" && !better(metric, retained)) {
          bad("keep_without_improvement", src, "iter " iter " keep 指标 " metric " 未优于保留最优 " retained "（方向 " dir "，epsilon " eps "%）")
        }
        adopt(metric)
        if (have_commit && commit == "") bad("commit_field", src, "iter " iter " keep 行缺少 commit")
      } else if (verdict == "revert" || verdict == "gatefail") {
        if (metric != "NA" && metric != "SKIP" && isnum(metric) && gate == "PASS" \
            && retained != "" && better(metric, retained)) {
          bad("discarded_improvement", src, "iter " iter " 指标 " metric " 优于保留最优 " retained " 却被判 " verdict "（若为噪声区丢弃应发生在 epsilon 内）")
        }
        if (have_commit && commit != "") bad("commit_field", src, "iter " iter " 非 keep 行携带 commit")
      }
    }
    BEGIN { expected = 1; saw_base = 0; n_bad = 0 }
    NR == 1 { next }
    {
      have_commit = (NF >= 10)
      check($1, $2, $3, $5, $6, (have_commit ? $10 : ""), have_commit, "row " NR - 1)
    }
    END {
      if (c_verdict != "")
        check(c_iter, c_verdict, c_metric, c_gate, c_goal, c_commit, (c_commit != ""), "候选行")
      exit (n_bad > 0) ? 1 : 0
    }' "$f")
  rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" >&2
  return "$rc"
}

cmd_audit() {
  if audit_check; then
    info "账本审计通过：无不变量违规"
    return 0
  fi
  die "账本审计发现违规。修复方式：修正记录流程，不要手工改写历史行——审计的价值就在于记录不可信时能被发现。确要绕过（不推荐）：loop.conf 设 AUDIT_BYPASS=1"
}

# ---------------------------------------------------------------- 基准漂移
# 借鉴 autoresearch 的 benchmark drift：基准（命令 + 相关文件内容）在基线之后
# 发生变化，则新旧指标不可比。指纹用 cksum（macOS/Linux 均自带、结果稳定）。
measure_fingerprint() {
  {
    [ -n "$MEASURE_CMD" ] && printf 'cmd:%s\n' "$MEASURE_CMD"
    local f
    for f in $MEASURE_FILES; do
      if [ -f "$PROJECT_ROOT/$f" ]; then
        printf 'file:%s\n' "$f"
        cat "$PROJECT_ROOT/$f"
      fi
    done
  } | cksum | awk '{print $1 "/" $2}'
}

drift_status() {
  if [ -z "$MEASURE_CMD" ] && [ -z "$MEASURE_FILES" ]; then
    echo "NOTRACK"; return 0
  fi
  local f="$STATE_DIR/measure.cksum"
  [ -f "$f" ] || { echo "UNSET"; return 0; }
  if [ "$(measure_fingerprint)" = "$(cat "$f")" ]; then
    echo "OK"
  else
    echo "DRIFT"
  fi
}

drift_warn() {
  local st; st=$(drift_status)
  [ "$st" = "DRIFT" ] || return 0
  printf '  ⚠️ 基准漂移：MEASURE_CMD/MEASURE_FILES 相对基线已变化，新旧指标不可比。\n' >&2
  printf '     确认是有意变更：loop drift --set 重新锁定；否则恢复基准或重记 baseline 开新段。\n' >&2
}

cmd_drift() {
  if [ "${1:-}" = "--set" ]; then
    if [ -z "$MEASURE_CMD" ] && [ -z "$MEASURE_FILES" ]; then
      die "loop.conf 未配置 MEASURE_CMD/MEASURE_FILES，无指纹可锁定"
    fi
    measure_fingerprint > "$STATE_DIR/measure.cksum"
    info "基准指纹已重新锁定: $(cat "$STATE_DIR/measure.cksum")"
    return 0
  fi
  local st; st=$(drift_status)
  case "$st" in
    OK)     echo "OK"; info "基准指纹一致"; return 0 ;;
    DRIFT)  echo "DRIFT"; die "基准漂移：当前指纹 $(measure_fingerprint)，锁定值 $(cat "$STATE_DIR/measure.cksum")" ;;
    *)      echo "$st"; info "未跟踪基准（loop.conf 的 MEASURE_CMD/MEASURE_FILES 为空，或尚未 baseline）"; return 0 ;;
  esac
}

# ---------------------------------------------------------------- 震荡检测
# 借鉴 autoresearch 的 doom-loop：窗口内重复出现同一假设（原文精确重复）说明
# 在原地打转。优先取 ASI 的 hyp 字段，缺省回退到 note。
doom_detect() {
  local f; f="$(results_file)"
  [ -f "$f" ] || return 0
  awk -F'\t' '
    NR > 1 && $2 != "keep" && $2 != "baseline" {
      key = $7
      if (NF >= 9 && $9 ~ /^hyp=/) { key = substr($9, 5); sub(/\|.*/, "", key) }
      gsub(/^[ \t]+/, "", key); gsub(/[ \t]+$/, "", key); gsub(/[ \t]+/, " ", key)
      if (key == "") next
      n++; keys[n] = key
    }
    END {
      start = (n > 6) ? n - 5 : 1
      for (i = start; i <= n; i++)
        for (j = i + 1; j <= n; j++)
          if (keys[i] == keys[j]) {
            if (j == i + 1) print "repeat\t" keys[i]
            else            print "oscillate\t" keys[i]
            exit 0
          }
    }' "$f"
}

# ---------------------------------------------------------------- 迭代钩子
# 借鉴 autoresearch 的 iteration hooks：.dev/hooks/after.sh 在每次记账后运行，
# fail-open（失败不阻断循环），stdout 作为 after_steer 回给调用方。
# 协议：环境变量 LOOP_EVENT/ITER/VERDICT/METRIC/GOAL/NOTE/HYPOTHESIS/NEXT_HINT/
#       ROLLBACK/BEST/ROUNDS_DONE/STATE_DIR/PROJECT。钩子应尽快退出（<30s）。
run_after_hook() {
  local event="$1" iter="$2" verdict="$3" metric="$4" goal="$5" note="$6"
  local hk="$STATE_DIR/hooks/after.sh"
  [ -f "$hk" ] || return 0
  local out rc
  out=$(LOOP_EVENT="$event" \
        LOOP_ITER="$iter" LOOP_VERDICT="$verdict" LOOP_METRIC="$metric" \
        LOOP_GOAL="$goal" LOOP_NOTE="$note" \
        LOOP_HYPOTHESIS="${7:-}" LOOP_NEXT_HINT="${8:-}" LOOP_ROLLBACK="${9:-}" \
        LOOP_BEST="$(best_metric)" LOOP_ROUNDS_DONE="$(rounds_done)" \
        LOOP_STATE_DIR="$STATE_DIR" LOOP_PROJECT="$PROJECT_ROOT" \
        bash "$hk")
  rc=$?
  [ "$rc" -ne 0 ] && info "钩子 after.sh 退出 rc=${rc}（fail-open，继续）"
  if [ -n "$out" ]; then
    printf '  [after_steer]\n'
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
  return 0
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

# --- 基准漂移检测（baseline 时锁定指纹，之后每轮比对）---
# 产生指标的命令（示意：go-gate 的调用行或其他语言自己的度量命令）
MEASURE_CMD=""
# 空格分隔的基准相关文件（相对项目根；内容变化视为漂移，如被测的 bench 源文件）
MEASURE_FILES=""

# --- 账本审计 ---
AUDIT_BYPASS=0                # 1=关闭写入前审计（不推荐；等于放弃"记录即证据"）
EOF
  printf 'results.tsv\nREPORT.md\ngate/\ntasks/\nrun.json\nmeasure.cksum\n' > "$dir/.gitignore"
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
  # 锁定基准指纹：之后每一轮都与之比对（drift 检测起点）
  if [ -n "$MEASURE_CMD" ] || [ -n "$MEASURE_FILES" ]; then
    measure_fingerprint > "$STATE_DIR/measure.cksum"
    info "基准指纹已锁定: $(cat "$STATE_DIR/measure.cksum")"
  fi
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

  drift_warn

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

# metric 子命令：从任意命令输出中抽取 'METRIC 名=值' 行的指标值。
# 这是非 Go 项目接入 loop 的标准方式：度量脚本只负责打印 METRIC 行，
# 抽值交给这里——输出端格式漂移会在这里被拒绝，而不是伪装成结论。
cmd_metric() {
  local want=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --name=*) want="${1#*=}" ;;
      *) die "用法: loop.sh metric [--name=<指标名>] < <命令输出>" ;;
    esac
    shift
  done
  [ -z "$want" ] && want="${METRIC_NAME:-}"
  local tmp
  tmp=$(mktemp 2>/dev/null || echo "$STATE_DIR/.metric.$$")
  tr -d '\r' | sed -n 's/^[[:space:]]*METRIC[[:space:]]\{1,\}//p' > "$tmp"
  local found="" names="" line name value
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      *=*) : ;;
      *) continue ;;
    esac
    name="${line%%=*}"
    value="${line#*=}"
    name=$(printf '%s' "$name" | tr -d ' \t')
    value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$name" ] && continue
    names="$names $name"
    if [ -z "$want" ] || [ "$name" = "$want" ]; then found="$value"; fi
  done < "$tmp"
  rm -f "$tmp"
  if [ -z "$found" ]; then
    echo "ERROR: 输出中没有 METRIC ${want:-(任意名)} 行。可用指标:${names:- 无}。度量脚本须打印 'METRIC 名=值' 行。" >&2
    exit 2
  fi
  printf '%s\n' "$found"
}

# 解析 ASI 选项：--hyp= --next= --rollback=（位置参数留在 pos 数组中）
parse_asi_flags() {
  ASI_HYP=""; ASI_NEXT=""; ASI_RB=""
  POS=()
  local a
  for a in "$@"; do
    case "$a" in
      --hyp=*)      ASI_HYP="${a#--hyp=}" ;;
      --next=*)     ASI_NEXT="${a#--next=}" ;;
      --rollback=*) ASI_RB="${a#--rollback=}" ;;
      *) POS+=("$a") ;;
    esac
  done
}

cmd_record() {
  parse_asi_flags "$@"
  local iter="${POS[0]:-0}" verdict="${POS[1]:-unknown}" metric="${POS[2]:-NA}"
  local gate="${POS[3]:-PASS}" goal="${POS[4]:-feature}" note="${POS[5]:-}"
  note=$(clean_field "$note")
  local f; f="$(results_file)"
  ensure_results_header
  if [ "$AUDIT_BYPASS" != "1" ]; then
    audit_check "$iter" "$verdict" "$metric" "$gate" "$goal" "" \
      || die "账本审计未通过，拒绝写入。审计输出见上；若确属有意为之，修正流程而不是绕过审计。"
  fi
  local delta="-"
  local best; best=$(best_metric)
  if [ -n "$best" ] && [ "$metric" != "NA" ] && [ "$metric" != "SKIP" ] && is_number "$metric"; then
    delta=$(delta_pct "$metric" "$best")
  fi
  local asi; asi=$(asi_encode "$ASI_HYP" "$ASI_NEXT" "$ASI_RB")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\n' \
    "$iter" "$verdict" "$metric" "$delta" "$gate" "$goal" "$note" \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$asi" >> "$f"
  info "已记录 iter=$iter verdict=$verdict metric=$metric delta=${delta}% goal=$goal"
  run_after_hook record "$iter" "$verdict" "$metric" "$goal" "$note" "$ASI_HYP" "$ASI_NEXT" "$ASI_RB"
}

cmd_keep() {
  parse_asi_flags "$@"
  local iter="${POS[0]:-0}" metric="${POS[1]:-NA}" note="${POS[2]:-}" goal="${POS[3]:-feature}"
  note=$(clean_field "$note")
  # 写账本前先过审计（commit 尚未产生，用占位符通过 commit_field 检查）；
  # 审计拒绝时不产生 git commit——账本脏了比少一轮实验严重得多。
  if [ "$AUDIT_BYPASS" != "1" ]; then
    audit_check "$iter" "keep" "$metric" "PASS" "$goal" "PENDING" \
      || die "账本审计未通过，拒绝 keep（未产生 git commit）。审计输出见上。"
  fi
  ( cd "$PROJECT_ROOT" \
    && git add -A \
    && git commit -q -m "dev(round $iter): ${note:-无描述} [${METRIC_NAME}=${metric}]" ) \
    || die "commit 失败（工作树可能无改动）"
  local cmt
  cmt=$(cd "$PROJECT_ROOT" && git rev-parse --short HEAD)
  local f; f="$(results_file)"
  ensure_results_header
  local delta="-"
  local best; best=$(best_metric)
  if [ -n "$best" ] && [ "$metric" != "NA" ] && [ "$metric" != "SKIP" ] && is_number "$metric"; then
    delta=$(delta_pct "$metric" "$best")
  fi
  local asi; asi=$(asi_encode "$ASI_HYP" "$ASI_NEXT" "$ASI_RB")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$iter" "keep" "$metric" "$delta" "PASS" "$goal" "$note" \
    "$(date '+%Y-%m-%dT%H:%M:%S')" "$asi" "$cmt" >> "$f"
  info "已记录 iter=$iter verdict=keep metric=$metric delta=${delta}% goal=$goal commit=$cmt"
  run_after_hook keep "$iter" "keep" "$metric" "$goal" "$note" "$ASI_HYP" "$ASI_NEXT" "$ASI_RB"
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

  # 4) 震荡/重复假设（doom loop）→ 窗口内同一假设原文重复，说明在原地打转
  local doom; doom=$(doom_detect)
  if [ -n "$doom" ]; then
    local kind="${doom%%$'\t'*}" key="${doom#*$'\t'}"
    if [ "$kind" = "repeat" ]; then
      printf '  [doom] 同一假设重复出现：%s。停止重复，换结构性不同的方向。\n' "$key" >&2
    else
      printf '  [doom] 假设震荡（A→B→A）：%s。停止往返，换结构性不同的方向。\n' "$key" >&2
    fi
    echo "STOP:doom_loop"; return 0
  fi

  # 5) 轮数用尽
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
    echo "- 账本审计: $(audit_check >/dev/null 2>&1 && echo 通过 || echo **存在违规**)"
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
    echo "## 弃用方向与理由（来自 ASI rollback）"
    echo
    awk -F'\t' 'NR>1 && ($2=="revert" || $2=="gatefail") && $9 ~ /rollback=/ {
      r = $9; sub(/^.*rollback=/, "", r); sub(/\|.*/, "", r)
      if (r != "") printf "- iter %s：%s\n", $1, r
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
  info "基准指纹: $(drift_status)"
  info "下一步: $(cmd_next)"
  rule
}

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

# ---------------------------------------------------------------- 入口
SUB="${1:-}"; shift || true
case "$SUB" in
  init)     cmd_init "${1:-$PWD}" ;;
  baseline) resolve_project; cfg_load; cmd_baseline "${1:-NA}" ;;
  decide)   resolve_project; cfg_load; cmd_decide "$@" ;;
  metric)   resolve_project; [ -f "$STATE_DIR/loop.conf" ] && cfg_load; cmd_metric "$@" ;;
  record)   resolve_project; cfg_load; cmd_record "$@" ;;
  keep)     resolve_project; cfg_load; cmd_keep "$@" ;;
  revert)   resolve_project; cfg_load; cmd_revert ;;
  next)     resolve_project; cfg_load; cmd_next ;;
  audit)    resolve_project; cfg_load; cmd_audit ;;
  drift)    resolve_project; cfg_load; cmd_drift "$@" ;;
  report)   resolve_project; cfg_load; cmd_report ;;
  status)   resolve_project; cfg_load; cmd_status ;;
  "")       usage ;;
  *)        echo "未知子命令: $SUB" >&2; usage ;;
esac
