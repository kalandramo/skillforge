#!/usr/bin/env bash
# ts_gate.sh — TypeScript / JavaScript 项目的确定性质量门禁
#
# 与 go-gate 的 gate.sh 同构：只产出 pass / fail / skip 与退出码，不打分。
# 不自带规则集——把项目自身的 tsc / eslint / test 脚本当作判据来源，
# 因此"这个仓库的规矩"永远由这个仓库自己定义。

set -uo pipefail

ROOT="."
JSON=0
BASE=""
ALLOW_DEP=0
SKIP=""
DO_BUILD=0
DO_BENCH=0

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'EOF'
用法: ts_gate.sh [选项]

  --root DIR              项目根目录（默认当前目录），须含 package.json
  --json                  输出机器可读 JSON
  --base REV              lint 增量比较的基线（默认自动探测 origin/main、origin/master）
  --allow-dep-changes     package.json / lockfile 变更时显式放行
  --build                 额外跑 package.json 的 build 脚本（默认不跑）
  --bench                 额外跑 package.json 的 bench 脚本（默认不跑）
  --skip a,b,c            跳过指定阶段：dep_guard,typecheck,lint,test,build,bench
  -h, --help              显示本帮助

阶段：dep_guard / typecheck / lint（只查本次改动）/ test，可选 build、bench。
退出码：0 = 全部通过（skip 不算失败），1 = 有阶段失败，2 = 参数或环境错误。
EOF
  exit "${1:-2}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)  ROOT="${2:-}"; [ -n "$ROOT" ] || die "--root 需要参数"; shift ;;
    --json)  JSON=1 ;;
    --base)  BASE="${2:-}"; [ -n "$BASE" ] || die "--base 需要参数"; shift ;;
    --allow-dep-changes) ALLOW_DEP=1 ;;
    --skip)  SKIP="${2:-}"; [ -n "$SKIP" ] || die "--skip 需要参数"; shift ;;
    --build) DO_BUILD=1 ;;
    --bench) DO_BENCH=1 ;;
    -h|--help) usage 0 ;;
    *) die "未知参数: $1" ;;
  esac
  shift
done

[ -d "$ROOT" ] || die "目录不存在: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"
[ -f "$ROOT/package.json" ] || die "$ROOT 下没有 package.json，不是 Node/TS 项目"

STAMP="$(date '+%Y%m%d-%H%M%S')"
OUT_DIR="$ROOT/.dev/ts-gate/$STAMP"
mkdir -p "$OUT_DIR" || die "无法创建日志目录 $OUT_DIR"

now_ms() {
  local t
  t=$(date +%s%N 2>/dev/null || echo "")
  if [ -n "$t" ] && [ "${#t}" -gt 10 ]; then echo $(( t / 1000000 )); else echo $(( $(date +%s) * 1000 )); fi
}

RESULT_NAMES=""; RESULT_STATUS=""; RESULT_RC=""; RESULT_MS=""
FAILED=0

record() {
  RESULT_NAMES="$RESULT_NAMES $1"
  RESULT_STATUS="$RESULT_STATUS $2"
  RESULT_RC="$RESULT_RC $3"
  RESULT_MS="$RESULT_MS $4"
}

skipped() {
  case ",$SKIP," in *",$1,"*) return 0 ;; esac
  return 1
}

run_stage() {
  local name="$1"; shift
  local log="$OUT_DIR/$name.log" t0 t1 rc
  t0=$(now_ms)
  ( cd "$ROOT" && "$@" ) >"$log" 2>&1
  rc=$?
  t1=$(now_ms)
  if [ "$rc" -eq 0 ]; then
    printf '  [ OK ] %s (%sms)\n' "$name" "$((t1 - t0))"
    record "$name" pass 0 $((t1 - t0))
    return 0
  fi
  printf '  [FAIL] %s (rc=%s, %sms)  日志: %s\n' "$name" "$rc" "$((t1 - t0))" "$log"
  tail -12 "$log" | sed 's/^/         | /'
  record "$name" fail "$rc" $((t1 - t0))
  FAILED=1
  return 1
}

pass_stage() { printf '  [ OK ] %s (%s)\n' "$1" "$2"; record "$1" pass 0 0; }
skip_stage() { printf '  [SKIP] %s (%s)\n' "$1" "$2"; record "$1" skip 0 0; }
fail_stage() { printf '  [FAIL] %s: %s\n' "$1" "$2"; record "$1" fail 1 0; FAILED=1; }

# ---------------------------------------------------------------- 环境探测
PM="npm"
LOCKFILE=""
for candidate in pnpm-lock.yaml yarn.lock bun.lockb bun.lock package-lock.json; do
  if [ -f "$ROOT/$candidate" ]; then LOCKFILE="$candidate"; break; fi
done
case "$LOCKFILE" in
  pnpm-lock.yaml) PM="pnpm" ;;
  yarn.lock)      PM="yarn" ;;
  bun.lockb|bun.lock) PM="bun" ;;
  *)              PM="npm" ;;
esac

has_script() {
  # 不依赖 jq/node：在 package.json 的 scripts 段里找 "name":
  node -e 'const p=require(process.argv[1]); process.exit(p.scripts&&p.scripts[process.argv[2]]?0:1)' \
    "$ROOT/package.json" "$1" 2>/dev/null
}

bin_path() { [ -x "$ROOT/node_modules/.bin/$1" ] && printf '%s' "$ROOT/node_modules/.bin/$1"; }

has_eslint_config() {
  for f in eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts \
           .eslintrc .eslintrc.js .eslintrc.cjs .eslintrc.json .eslintrc.yml .eslintrc.yaml; do
    [ -f "$ROOT/$f" ] && return 0
  done
  node -e 'const p=require(process.argv[1]); process.exit(p.eslintConfig?0:1)' "$ROOT/package.json" 2>/dev/null
}

echo "=== ts-gate @ $ROOT ==="
# 不用 ${VAR:+（$VAR）}：bash 3.2 在 set -u 下会把紧贴全角括号的变量名多吞一个字节，
# 报 unbound variable。printf 把格式串与参数分开，绕开这个解析歧义。
if [ -n "$LOCKFILE" ]; then
  printf '  包管理器: %s（%s）\n' "$PM" "$LOCKFILE"
else
  printf '  包管理器: %s（无 lockfile）\n' "$PM"
fi
printf '  日志目录: %s\n' "$OUT_DIR"

# ---------------------------------------------------------------- 1. 依赖守卫
if skipped dep_guard; then
  skip_stage dep_guard "按 --skip"
elif [ "$ALLOW_DEP" -eq 1 ]; then
  pass_stage dep_guard "已显式放行 --allow-dep-changes"
elif git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  DEP_PATHS=(package.json)
  [ -n "$LOCKFILE" ] && DEP_PATHS+=("$LOCKFILE")
  if git -C "$ROOT" diff --quiet -- "${DEP_PATHS[@]}" 2>/dev/null; then
    pass_stage dep_guard "依赖文件未变更"
  else
    printf '  [FAIL] dep_guard: 依赖文件发生变更\n'
    git -C "$ROOT" diff --stat -- "${DEP_PATHS[@]}" | sed 's/^/         | /'
    printf '         如属预期，加 --allow-dep-changes 重跑\n'
    record dep_guard fail 1 0
    FAILED=1
  fi
else
  skip_stage dep_guard "非 git 仓库"
fi

# ---------------------------------------------------------------- 2. 类型检查
TSC="$(bin_path tsc)"
if skipped typecheck; then
  skip_stage typecheck "按 --skip"
elif [ ! -f "$ROOT/tsconfig.json" ]; then
  skip_stage typecheck "无 tsconfig.json"
elif [ -z "$TSC" ]; then
  skip_stage typecheck "未安装 typescript"
else
  run_stage typecheck "$TSC" --noEmit || true
fi

# ---------------------------------------------------------------- 3. lint（只查改动）
ESLINT="$(bin_path eslint)"
if skipped lint; then
  skip_stage lint "按 --skip"
elif [ -z "$ESLINT" ]; then
  skip_stage lint "未安装 eslint"
elif ! has_eslint_config; then
  skip_stage lint "无 eslint 配置"
elif ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  skip_stage lint "非 git 仓库，无法确定改动范围"
else
  LINT_BASE="$BASE"
  if [ -z "$LINT_BASE" ]; then
    # 只认远端引用。本地 main/master 通常就是当前分支，拿它做基线会让 diff 恒为空，
    # 于是 lint 变成"什么都没查"却报 pass。
    for ref in origin/main origin/master upstream/main upstream/master; do
      if git -C "$ROOT" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
        LINT_BASE="$(git -C "$ROOT" merge-base "$ref" HEAD 2>/dev/null)" && [ -n "$LINT_BASE" ] && break
      fi
    done
  fi
  RANGE="HEAD"
  [ -n "$LINT_BASE" ] && RANGE="$LINT_BASE...HEAD"

  CHANGED="$(
    { git -C "$ROOT" diff --name-only --diff-filter=ACMR "$RANGE" -- \
        '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs'
      git -C "$ROOT" ls-files --others --exclude-standard -- \
        '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs'
    } 2>/dev/null | sort -u
  )"

  LINT_FILES=()
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$ROOT/$f" ] && LINT_FILES+=("$f")
  done <<CHANGED_EOF
$CHANGED
CHANGED_EOF

  if [ "${#LINT_FILES[@]}" -eq 0 ]; then
    skip_stage lint "基线 $RANGE 之后没有改动的前端文件"
  else
    printf '  lint 范围: %s 个改动文件（基线 %s）\n' "${#LINT_FILES[@]}" "$RANGE"
    run_stage lint "$ESLINT" "${LINT_FILES[@]}" || true
  fi
fi

# ---------------------------------------------------------------- 4. 测试
if skipped test; then
  skip_stage test "按 --skip"
elif ! has_script test; then
  skip_stage test "package.json 无 test 脚本"
else
  run_stage test env CI=1 "$PM" test || true
fi

# ---------------------------------------------------------------- 5. 构建（可选）
if [ "$DO_BUILD" -eq 1 ]; then
  if skipped build; then
    skip_stage build "按 --skip"
  elif ! has_script build; then
    skip_stage build "package.json 无 build 脚本"
  else
    run_stage build env CI=1 "$PM" run build || true
  fi
fi

# ---------------------------------------------------------------- 6. 性能（可选）
METRIC_VALUE=""
if [ "$DO_BENCH" -eq 1 ]; then
  if skipped bench; then
    skip_stage bench "按 --skip"
  elif ! has_script bench; then
    skip_stage bench "package.json 无 bench 脚本"
  else
    printf '  注意: TS 侧不统计中位数，bench 只作回归参考，metric 恒为空\n'
    run_stage bench env CI=1 "$PM" run bench || true
  fi
fi

# ---------------------------------------------------------------- 汇总
echo "=== 汇总 ==="
set -- $RESULT_NAMES; names="$*"
set -- $RESULT_STATUS; statuses="$*"
set -- $RESULT_MS; times="$*"
idx=1
for n in $names; do
  s=$(printf '%s' "$statuses" | cut -d' ' -f"$idx")
  ms=$(printf '%s' "$times" | cut -d' ' -f"$idx")
  printf '  %-11s %-5s %6sms\n' "$n" "$s" "$ms"
  idx=$((idx + 1))
done

if [ "$JSON" -eq 1 ]; then
  j="{"
  j="$j\"root\":\"$(printf '%s' "$ROOT" | sed 's/\\/\\\\/g')\","
  j="$j\"ok\":$([ "$FAILED" -eq 0 ] && echo true || echo false),"
  j="$j\"metric\":{\"name\":\"\",\"value\":\"$METRIC_VALUE\"},"
  j="$j\"stages\":["
  idx=1; first=1
  for n in $names; do
    s=$(printf '%s' "$statuses" | cut -d' ' -f"$idx")
    ms=$(printf '%s' "$times" | cut -d' ' -f"$idx")
    [ "$first" -eq 0 ] && j="$j,"
    j="$j{\"name\":\"$n\",\"status\":\"$s\",\"ms\":$ms}"
    first=0; idx=$((idx + 1))
  done
  j="$j],\"log_dir\":\"$(printf '%s' "$OUT_DIR" | sed 's/\\/\\\\/g')\"}"
  printf '%s\n' "$j"
fi

if [ "$FAILED" -eq 0 ]; then exit 0; else exit 1; fi
