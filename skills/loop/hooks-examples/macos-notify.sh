#!/usr/bin/env bash
# macos-notify — 每轮记账后发一条 macOS 通知（agent 自己看不到的反馈通道）。
# 来源：autoresearch hooks/examples/after/macos-notify.sh，适配 LOOP_* 协议。
# 安装：复制到被管理仓库的 .dev/hooks/after.sh（fail-open，失败不影响循环）。
set -uo pipefail

verdict="${LOOP_VERDICT:-unknown}"
metric="${LOOP_METRIC:-NA}"
best="${LOOP_BEST:-}"
round="${LOOP_ITER:-?}"

title="loop iter=$round $verdict"
if [ -n "$best" ]; then
  msg="metric=$metric best=$best"
else
  msg="metric=$metric"
fi

osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1 || exit 0
