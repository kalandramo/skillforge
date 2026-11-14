#!/usr/bin/env bash
# learnings-journal — 把每轮假设与结局追加到 .dev/learnings.md，沉淀试验史。
# 回滚后代码不保留，但"为什么放弃"在这里存活——下一轮选假设前先看它。
# 来源：autoresearch hooks/examples/after/learnings-journal.sh，适配 LOOP_* 协议。
# 安装：复制到被管理仓库的 .dev/hooks/after.sh（fail-open，失败不影响循环）。
set -euo pipefail

dir="${LOOP_STATE_DIR:-.dev}"
journal="$dir/learnings.md"

[ -f "$journal" ] || printf '# 试验日志（由 .dev/hooks/after.sh 自动追加）\n' > "$journal"

{
  printf '%s | iter=%s | %s | metric=%s | ' \
    "$(date '+%Y-%m-%d %H:%M')" \
    "${LOOP_ITER:-?}" \
    "${LOOP_VERDICT:-unknown}" \
    "${LOOP_METRIC:-NA}"
  if [ -n "${LOOP_ROLLBACK:-}" ]; then
    printf '弃用理由：%s\n' "$LOOP_ROLLBACK"
  elif [ -n "${LOOP_HYPOTHESIS:-}" ]; then
    printf '假设：%s\n' "$LOOP_HYPOTHESIS"
  else
    printf '%s\n' "${LOOP_NOTE:-（无描述）}"
  fi
} >> "$journal"
