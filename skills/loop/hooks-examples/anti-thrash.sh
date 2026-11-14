#!/usr/bin/env bash
# anti-thrash — 防打转提示。连续多轮非 keep 时建议结构性反思。
# 来源：autoresearch hooks/examples/before/anti-thrash.sh，适配 loop.sh 的
# LOOP_* 环境变量协议与 results.tsv 账本。
# 安装：复制到被管理仓库的 .dev/hooks/after.sh（fail-open，失败不影响循环）。
set -euo pipefail

STREAK_THRESHOLD=3
WINDOW=5

tsv="${LOOP_STATE_DIR:-}/results.tsv"
[ -f "$tsv" ] || exit 0

streak=$(awk -F'\t' -v w="$WINDOW" '
  NR > 1 { v[NR] = $2 }
  END {
    c = 0
    for (i = NR; i >= 2 && (NR - i) < w; i--) {
      if (v[i] == "keep" || v[i] == "baseline") break
      c++
    }
    print c
  }' "$tsv")

[ "$streak" -ge "$STREAK_THRESHOLD" ] || exit 0

printf '⚠️ 最近 %s 轮连续非 keep（含本轮 iter=%s %s）。建议：\n' \
  "$streak" "${LOOP_ITER:-?}" "${LOOP_VERDICT:-?}"
printf '  - 重读本轮假设（%s）与基准脚本，确认度量对象没偏移\n' "${LOOP_HYPOTHESIS:-未声明}"
printf '  - 换一个结构性不同的方向，而不是同一思路再换参数\n'
printf '  - 先做性能剖析定位热点，再提下一个假设\n'
