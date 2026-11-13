#!/usr/bin/env bash
# gate.sh — Go 项目的确定性质量门禁
#
# 设计约束：
#   1. 零外部依赖（不需要 jq）；只用 go / git / grep / awk / sort
#   2. 每道门禁只有两种结果：退出码 0 或非 0 —— 不产生"评分"
#   3. lint 默认只检查相对基线的**新增**问题（--new-from-rev），避免存量告警卡死循环
#   4. 依赖文件变更默认视为门禁失败，需 --allow-mod-changes 显式放行
#
# 用法：
#   gate.sh [--root DIR] [--json] [--race] [--bench[=PATTERN]]
#           [--base REV] [--allow-mod-changes] [--skip a,b,c]
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
SKIP=""
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
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# ---- 4. 单元测试 ----
run_stage test go test ./... || true

# ---- 5. 竞态检测（显式开启；比默认测试慢 2-5 倍）----
if [ "$RACE" -eq 1 ]; then
  run_stage race go test -race ./... || true
fi

# ---- 6. lint（仅针对基线之后的新增代码）----
if skipped lint; then
  echo "  [SKIP] lint"; record lint skip 0 0
elif ! command -v golangci-lint >/dev/null 2>&1; then
  echo "  [SKIP] lint (未安装 golangci-lint)"
  record lint skip 0 0
else
  if [ -z "$BASE_REV" ]; then
    if git rev-parse --verify -q origin/main >/dev/null 2>&1; then BASE_REV="origin/main"
    elif git rev-parse --verify -q origin/master >/dev/null 2>&1; then BASE_REV="origin/master"
    fi
  fi
  if [ -n "$BASE_REV" ]; then
    echo "  [info] lint 仅检查 $BASE_REV 之后的新增问题"
    run_stage lint golangci-lint run --new-from-rev="$BASE_REV" ./... || true
  else
    echo "  [warn] 未找到基线分支，lint 将全量检查（存量告警可能阻断）"
    run_stage lint golangci-lint run ./... || true
  fi
fi

# ---- 7. 性能度量（唯一能支撑"优化"结论的证据）----
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
      echo "  [FAIL] bench 未匹配到 ns/op（pattern=$BENCH_PATTERN）"; bench_ok=0; break
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
