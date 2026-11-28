#!/usr/bin/env bash
# gate.sh — Go 项目的确定性质量门禁
#
# 设计约束：
#   1. 零外部依赖（不需要 jq）；只用 go / git / grep / awk / sort（arch 段需 python3，缺则 skip）
#   2. 每道门禁只有两种结果：退出码 0 或非 0 —— 不产生"评分"
#   3. lint 默认只检查相对基线的**新增**问题（--new-from-rev），避免存量告警卡死循环
#   4. 依赖文件变更默认视为门禁失败，需 --allow-mod-changes 显式放行
#   5. arch 只在仓库提供 .arch.json 时启用；同样只查基线之后改动的包
#
# 用法：
#   gate.sh [--root DIR] [--json] [--race] [--bench[=PATTERN]]
#           [--base REV] [--allow-mod-changes] [--skip a,b,c]
#           [--arch-config FILE] [--require-arch]
#
# 环境变量：BENCH_RUNS、BENCH_PKG、ARCH_CONFIG（默认 .arch.json）、ARCH_VERIFY（默认 1）
# --require-arch：缺契约直接判失败（dev 循环默认带；无契约就不该声称架构没问题）
#
# 退出码：0 = 全部门禁通过（或跳过）；1 = 有门禁失败；2 = 环境不可用

set -uo pipefail

ROOT="$PWD"
JSON=0
RACE=0
BENCH=0
BENCH_PATTERN="."
BASE_REV=""
ALLOW_MOD=0
REQUIRE_ARCH=0
SKIP=""
ARCH_CONFIG="${ARCH_CONFIG:-.arch.json}"
BENCH_RUNS="${BENCH_RUNS:-3}"
BENCH_PKG="${BENCH_PKG:-./...}"

while [ $# -gt 0 ]; do
  case "$1" in
    --root)   ROOT="$2"; shift 2 ;;
    --json)   JSON=1; shift ;;
    --race)   RACE=1; shift ;;
    --bench)  BENCH=1; shift ;;
    --bench=*) BENCH=1; BENCH_PATTERN="${1#--bench=}"; shift ;;
    --base)   BASE_REV="$2"; shift 2 ;;
    --allow-mod-changes) ALLOW_MOD=1; shift ;;
    --skip)   SKIP="$2"; shift 2 ;;
    --arch-config) ARCH_CONFIG="$2"; shift 2 ;;
    --require-arch) REQUIRE_ARCH=1; shift ;;
    -h|--help) awk 'NR>1 { if ($0 == "") exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

cd "$ROOT" 2>/dev/null || { echo "路径不存在: $ROOT" >&2; exit 2; }
[ -f go.mod ] || { echo "不是 Go 模块（缺 go.mod）: $ROOT" >&2; exit 2; }
command -v go >/dev/null 2>&1 || { echo "未安装 go" >&2; exit 2; }

OUT_DIR="$ROOT/.dev/gate/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

skipped() { case ",$SKIP," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# 结果累积：用于最终 JSON 与汇总表
RESULT_NAMES=""; RESULT_STATUS=""; RESULT_RC=""; RESULT_MS=""
METRIC_VALUE=""
FAILED=0

now_ms() {
  local t; t=$(date +%s%3N 2>/dev/null)
  if [[ "$t" =~ ^[0-9]+$ ]] && [ "${#t}" -gt 10 ]; then echo "$t"; else echo $(( $(date +%s) * 1000 )); fi
}

record() {
  RESULT_NAMES="$RESULT_NAMES $1"
  RESULT_STATUS="$RESULT_STATUS $2"
  RESULT_RC="$RESULT_RC $3"
  RESULT_MS="$RESULT_MS $4"
}

# run_stage <name> <command...>
run_stage() {
  local name="$1"; shift
  if skipped "$name"; then
    echo "  [SKIP] $name"
    record "$name" skip 0 0
    return 0
  fi
  local log="$OUT_DIR/$name.log" t0 t1 rc
  t0=$(now_ms)
  ( "$@" ) >"$log" 2>&1
  rc=$?
  t1=$(now_ms)
  if [ "$rc" -eq 0 ]; then
    echo "  [ OK ] $name ($((t1-t0))ms)"
    record "$name" pass 0 $((t1-t0))
    return 0
  fi
  echo "  [FAIL] $name (rc=$rc, $((t1-t0))ms)  日志: $log"
  tail -12 "$log" | sed 's/^/         | /'
  record "$name" fail "$rc" $((t1-t0))
  FAILED=1
  return 1
}

median_of() { grep -E '^-?[0-9]+\.?[0-9]*$' | sort -g | awk '{a[NR]=$1} END{ if (NR==0) exit 1; print a[int((NR+1)/2)] }'; }

# 基线探测（lint 与 arch 共用）：--base 优先，其次当前分支的 upstream、origin/main、origin/master。
# 刻意不用本地 main/master：本地分支就是当前工作，拿它当基线等于"什么都没改"，门禁会静默放过。
detect_base() {
  [ -n "$BASE_REV" ] && return 0
  git rev-parse --git-dir >/dev/null 2>&1 || return 1
  local up
  up=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || up=""
  for cand in "$up" origin/main origin/master; do
    [ -n "$cand" ] || continue
    if git rev-parse --verify -q "$cand" >/dev/null 2>&1; then BASE_REV="$cand"; return 0; fi
  done
  return 1
}

# python 解释器探测（arch 与 buildtags 共用）
detect_py() {
  GATE_PY=""
  if command -v python3 >/dev/null 2>&1; then GATE_PY=python3
  elif command -v python >/dev/null 2>&1; then GATE_PY=python
  elif command -v py >/dev/null 2>&1; then GATE_PY=py
  fi
}

echo "=== go-gate @ $ROOT ==="
echo "  日志目录: $OUT_DIR"

# ---- 1. 依赖守卫：go.mod / go.sum 变更需显式批准 ----
if skipped mod_guard; then
  echo "  [SKIP] mod_guard"; record mod_guard skip 0 0
elif [ "$ALLOW_MOD" -eq 1 ]; then
  echo "  [ OK ] mod_guard (已显式放行 --allow-mod-changes)"; record mod_guard pass 0 0
else
  if git rev-parse --git-dir >/dev/null 2>&1; then
    if git diff --quiet -- go.mod go.sum 2>/dev/null; then
      echo "  [ OK ] mod_guard (依赖文件未变更)"; record mod_guard pass 0 0
    else
      echo "  [FAIL] mod_guard: go.mod / go.sum 发生变更"
      git diff --stat -- go.mod go.sum | sed 's/^/         | /'
      echo "         如属预期，加 --allow-mod-changes 重跑"
      record mod_guard fail 1 0
      FAILED=1
    fi
  else
    echo "  [SKIP] mod_guard (非 git 仓库)"; record mod_guard skip 0 0
  fi
fi

# ---- 2. 编译 ----
run_stage build go build ./... || true

# ---- 3. 静态检查（vet 永远是全量，速度快且基线干净的项目应全绿）----
run_stage vet go vet ./... || true

# ---- 4. 分层依赖门禁（仓库提供 .arch.json 时启用）----
# build / vet / test 都不会因为"domain import 了 infra"而变红——架构违规在测试判据里是零信号，
# 只能靠 import 图判定。检查范围与 lint 对齐：只查基线之后改动的包，存量欠账不阻断循环。
detect_py
ARCH_SCRIPT="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/check-arch.py"
case "$ARCH_CONFIG" in
  /*) ARCH_CONFIG_ABS="$ARCH_CONFIG" ;;
  *)  ARCH_CONFIG_ABS="$ROOT/$ARCH_CONFIG" ;;
esac
if skipped arch; then
  echo "  [SKIP] arch"; record arch skip 0 0
  echo "  [SKIP] arch_verify"; record arch_verify skip 0 0
elif [ ! -f "$ARCH_CONFIG_ABS" ]; then
  if [ "$REQUIRE_ARCH" -eq 1 ]; then
    echo "  [FAIL] arch (缺少 ${ARCH_CONFIG}，且已声明 --require-arch：本项目必须先落契约)"
    echo "         目录按层切:  python3 $ARCH_SCRIPT --root $ROOT --init --write"
    echo "         目录不按层切: python3 $ARCH_SCRIPT --root $ROOT --evidence  # 据此写，再 --verify"
    record arch fail 2 0; record arch_verify fail 2 0; FAILED=1
  else
    echo "  [SKIP] arch (仓库无 ${ARCH_CONFIG}，无架构契约可判)"
    echo "         目录按层切:  python3 $ARCH_SCRIPT --root $ROOT --init          # 打印初稿（含反向依赖清单）"
    echo "         目录不按层切: python3 $ARCH_SCRIPT --root $ROOT --evidence    # 包图+重复目录名+文档分层陈述，交给模型写契约"
    echo "         落盘后自检:   python3 $ARCH_SCRIPT --root $ROOT --verify"
    record arch skip 0 0; record arch_verify skip 0 0
  fi
elif [ -z "$GATE_PY" ]; then
  echo "  [SKIP] arch (未找到 python3/python/py)"; record arch skip 0 0; record arch_verify skip 0 0
elif [ ! -f "$ARCH_SCRIPT" ]; then
  echo "  [SKIP] arch (缺 check-arch.py，应与 gate.sh 同目录)"; record arch skip 0 0; record arch_verify skip 0 0
else
  ARCH_ARGS=(--root "$ROOT" --config "$ARCH_CONFIG_ABS")
  if detect_base; then
    echo "  [info] arch 仅检查 $BASE_REV 之后改动的包"
    ARCH_ARGS+=(--changed-only --base "$BASE_REV")
  else
    echo "  [info] arch 未探测到基线，全量检查"
  fi
  # 契约自检：前缀写错/包漏归层时，判定会静默全绿——比没有门禁更危险。
  # 校验的是"规则能不能真的触发"，与本次改动无关，所以不做增量。
  VERIFY_FAIL=0
  if skipped arch_verify; then
    echo "  [SKIP] arch_verify"
    record arch_verify skip 0 0
  elif [ "${ARCH_VERIFY:-1}" != "1" ]; then
    echo "  [SKIP] arch_verify (ARCH_VERIFY=$ARCH_VERIFY)"
    record arch_verify skip 0 0
  elif "$GATE_PY" "$ARCH_SCRIPT" --root "$ROOT" --config "$ARCH_CONFIG_ABS" \
        --verify >"$OUT_DIR/arch_verify.log" 2>&1; then
    echo "  [ OK ] arch_verify"
    record arch_verify pass 0 0
  else
    VERIFY_FAIL=1
    echo "  [FAIL] arch_verify (契约本身有错)  日志: $OUT_DIR/arch_verify.log"
    tail -12 "$OUT_DIR/arch_verify.log" | sed 's/^/         | /'
    record arch_verify fail 1 0
  fi
  run_stage arch "$GATE_PY" "$ARCH_SCRIPT" "${ARCH_ARGS[@]}" || true
  if [ "$VERIFY_FAIL" -eq 1 ]; then FAILED=1; fi
fi

# ---- 5. 构建标签门禁（仓库提供 scripts/check-build-tags.py 时启用）----
# 带 -tags 的 test-only 包（integration/soak 之类）不在 ./... 的视野里：
# build/vet/test 全都看不见它们，接口变更只有编译矩阵能抓到（与 CI 对齐）。
# 两层判定：注册表一致性（自定义标签双向登记）+ 按标签只编译 test-only 包。
# GATE_PY 已由第 4 段的 detect_py 探测。
if [ ! -f scripts/check-build-tags.py ]; then
  echo "  [SKIP] buildtags (仓库无 scripts/check-build-tags.py)"; record buildtags skip 0 0
  echo "  [SKIP] buildtags_compile (仓库无 scripts/check-build-tags.py)"; record buildtags_compile skip 0 0
elif [ -z "$GATE_PY" ]; then
  echo "  [SKIP] buildtags (未找到 python3/python/py)"; record buildtags skip 0 0
  echo "  [SKIP] buildtags_compile (未找到 python3/python/py)"; record buildtags_compile skip 0 0
else
  run_stage buildtags "$GATE_PY" scripts/check-build-tags.py || true
  run_stage buildtags_compile "$GATE_PY" scripts/check-build-tags.py --compile || true
fi

# ---- 6. 单元测试 ----
run_stage test go test ./... || true

# ---- 7. 竞态检测（显式开启；比默认测试慢 2-5 倍）----
if [ "$RACE" -eq 1 ]; then
  run_stage race go test -race ./... || true
fi

# ---- 8. lint（仅针对基线之后的新增代码）----
if skipped lint; then
  echo "  [SKIP] lint"; record lint skip 0 0
elif ! command -v golangci-lint >/dev/null 2>&1; then
  echo "  [SKIP] lint (未安装 golangci-lint)"
  record lint skip 0 0
else
  if [ -n "$BASE_REV" ] || detect_base; then
    echo "  [info] lint 仅检查 $BASE_REV 之后的新增问题"
    run_stage lint golangci-lint run --new-from-rev="$BASE_REV" ./... || true
  else
    echo "  [warn] 未找到基线分支，lint 将全量检查（存量告警可能阻断）"
    run_stage lint golangci-lint run ./... || true
  fi
fi

# ---- 9. 性能度量（唯一能支撑"优化"结论的证据）----
if [ "$BENCH" -eq 1 ] && ! skipped bench; then
  log="$OUT_DIR/bench.log"; : > "$log"
  vals=""
  bench_ok=1
  for ((i=1; i<=BENCH_RUNS; i++)); do
    out=$(go test -run='^$' -bench="$BENCH_PATTERN" -benchmem -count=1 "$BENCH_PKG" 2>&1)
    rc=$?
    echo "$out" >> "$log"
    if [ "$rc" -ne 0 ]; then
      echo "  [FAIL] bench 第 $i 次执行失败 (rc=$rc)"; echo "$out" | tail -8 | sed 's/^/         | /'
      bench_ok=0; break
    fi
    v=$(echo "$out" | grep -Eo '[0-9.]+ ns/op' | head -1 | grep -Eo '[0-9.]+')
    if [ -z "$v" ]; then
      echo "  [FAIL] bench 未匹配到 ns/op（pattern=${BENCH_PATTERN}）"; bench_ok=0; break
    fi
    echo "  bench run $i/$BENCH_RUNS: $v ns/op"
    vals="$vals$v"$'\n'
  done
  if [ "$bench_ok" -eq 1 ]; then
    med=$(printf '%s' "$vals" | median_of)
    if [ -n "$med" ]; then
      METRIC_VALUE="$med"
      echo "  [ OK ] bench median = $med ns/op"
      record bench pass 0 0
    else
      echo "  [FAIL] bench 中位数解析失败"; record bench fail 1 0; FAILED=1
    fi
  else
    record bench fail 1 0; FAILED=1
  fi
fi

# ---- 汇总 ----
echo "=== 汇总 ==="
i=0
set -- $RESULT_NAMES
names="$*"; set -- $RESULT_STATUS; statuses="$*"; set -- $RESULT_MS; times="$*"
idx=1
for n in $names; do
  s=$(echo "$statuses" | cut -d' ' -f"$idx")
  ms=$(echo "$times" | cut -d' ' -f"$idx")
  printf "  %-10s %-5s %6sms\n" "$n" "$s" "$ms"
  idx=$((idx+1))
done

if [ "$JSON" -eq 1 ]; then
  # 手写 JSON，避免依赖 jq
  j="{"
  j="$j\"root\":\"$(printf '%s' "$ROOT" | sed 's/\\/\\\\/g')\","
  j="$j\"ok\":$([ "$FAILED" -eq 0 ] && echo true || echo false),"
  j="$j\"metric\":{\"name\":\"ns_per_op\",\"value\":\"$METRIC_VALUE\"},"
  j="$j\"stages\":["
  idx=1; first=1
  for n in $names; do
    s=$(echo "$statuses" | cut -d' ' -f"$idx")
    ms=$(echo "$times" | cut -d' ' -f"$idx")
    [ "$first" -eq 0 ] && j="$j,"
    j="$j{\"name\":\"$n\",\"status\":\"$s\",\"ms\":$ms}"
    first=0; idx=$((idx+1))
  done
  j="$j],\"log_dir\":\"$(printf '%s' "$OUT_DIR" | sed 's/\\/\\\\/g')\"}"
  echo "$j"
fi

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
