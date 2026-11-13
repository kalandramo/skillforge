#!/usr/bin/env bash
# modern_index.sh — 按项目 Go 版本切片 modern-go 规则目录
#
# 为什么需要它：SKILL.md 有 1100+ 行 / 46 条规则。整份加载约 15k tokens，
# 放进每轮开发循环会吃光上下文，而单个项目实际可用的往往只是其中一部分。
# 本脚本只输出「标题 + 行号范围」，让调用方按需抽取真正需要的那一节。
#
# 用法：
#   modern_index.sh [--root <dir>]           输出索引（默认读 <dir>/go.mod）
#   modern_index.sh [--root <dir>] --version 1.22   覆盖版本
#   modern_index.sh --section 313            抽取指定起始行所在的那一节
#   modern_index.sh --list-all               列出全部规则含不可用的（默认行为）
#   modern_index.sh --json                   输出 JSON（便于程序消费）
#
# 退出码：0 成功；2 找不到 go.mod 且未指定 --version；3 参数错误

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"

die() { echo "modern_index: $*" >&2; exit 3; }
[ -f "$SKILL_MD" ] || die "找不到 $SKILL_MD"

ROOT="$PWD"
VER=""
SECTION=""
JSON=0
BLOCKED_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --root)       ROOT="${2:-}"; shift 2 || die "--root 缺少参数" ;;
    --version)    VER="${2:-}"; shift 2 || die "--version 缺少参数" ;;
    --section)    SECTION="${2:-}"; shift 2 || die "--section 缺少参数" ;;
    --json)       JSON=1; shift ;;
    --blocked)    BLOCKED_ONLY=1; shift ;;
    -h|--help)    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "未知参数: $1" ;;
  esac
done

# ---------- --section：抽单节正文（不依赖 go.mod，先于版本探测） ----------
if [ -n "$SECTION" ]; then
  case "$SECTION" in ''|*[!0-9]*) die "--section 需要行号整数" ;; esac
  # 从起始行打印到下一个 "### " 之前
  awk -v s="$SECTION" 'NR >= s { if (NR > s && /^### /) exit; print }' "$SKILL_MD"
  exit 0
fi

# ---------- 版本探测 ----------
if [ -z "$VER" ]; then
  MOD=""
  if [ -f "$ROOT/go.mod" ]; then
    MOD="$ROOT/go.mod"
  elif [ -f "$ROOT" ]; then
    MOD="$ROOT"          # 允许直接传 go.mod 路径
  fi
  [ -n "$MOD" ] || { echo "modern_index: 在 $ROOT 下找不到 go.mod，请用 --version 指定（如 --version 1.22）" >&2; exit 2; }
  # go 指令可能在 require 块之后，取第一处
  VER=$(sed -n 's/^go[[:space:]]\{1,\}\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$MOD" | head -1)
  [ -n "$VER" ] || { echo "modern_index: $MOD 中没有 go 指令" >&2; exit 2; }
fi

case "$VER" in
  [0-9]*.[0-9]*) : ;;
  *) echo "modern_index: 版本格式非法 '$VER'（应为 1.22 这种）" >&2; exit 3 ;;
esac

# ---------- 抽取章节 ----------
# 规则标题统一为 "### Go X.Y+ — 标题"，末尾有 4 个不带版本的 ### Phase N
# 只输出「起始行 \t 结束行 \t 最低版本 \t 原始标题行」。
# 标题的清理交给 bash 固定串匹配完成 —— awk 的 substr 在 UTF-8 的 "—" 上
# 会因 locale 差异多跳或少跳一个字符（实测丢了开头的反引号）。
extract_sections() {
  awk '
    /^### Go [0-9]+\.[0-9]+\+/ {
      if (start) print start "\t" end "\t" req "\t" raw
      raw = $0
      req = $0
      sub(/^### Go /, "", req)
      sub(/\+.*$/, "", req)
      start = NR; end = NR
      next
    }
    /^## / { if (start) { print start "\t" end "\t" req "\t" raw; start = 0 } }
    { if (start) end = NR }
    END { if (start) print start "\t" end "\t" req "\t" raw }
  ' "$SKILL_MD"
}

# 从 "### Go 1.21+ — `min` / `max`" 取 "`min` / `max`"
# 注意：不要改成 awk 的 substr —— "—" 是 3 字节，substr 在 UTF-8 locale 下
# 按字符计数会多跳一位（实测丢掉开头的反引号）。bash 的 # 是固定串匹配，稳。

# ---------- 版本比较：a >= b ----------
# 纯 bash 算术，不用 awk。原因有两条，都实测过：
#   1. `awk 'BEGIN{...}'` 没有文件参数时会继续读 stdin。而它是在
#      `while read ... done <<EOF` 循环里被调用的，stdin 就是那个 here-doc，
#      awk 会把剩余行全部吞掉，导致循环提前结束、结果静默错误（不是报错）。
#   2. 46 条规则 × 4 个循环 = 184 次 fork，纯 shell 比较零开销。
ver_gte() {
  local a="$1" b="$2"
  local am="${a%%.*}" an="${a#*.}" bm="${b%%.*}" bn="${b#*.}"
  [ "$an" = "$a" ] && an=0        # 无小数部分视为 .0
  [ "$bn" = "$b" ] && bn=0
  [ "$am" -gt "$bm" ] && return 0
  [ "$am" -lt "$bm" ] && return 1
  [ "$an" -ge "$bn" ]
}

# ---------- 输出 ----------
# 全部零 fork：Windows/Git Bash 下每次命令替换约 100-200ms，46 条规则逐行
# 做 $(clean_title ...) 会累计十几秒（实测超时）。这里统一用内建参数展开。
SECTIONS=$(extract_sections)
[ -n "$SECTIONS" ] || die "未解析到任何版本规则，SKILL.md 结构可能已变"

TAB=$'\t'
avail=0; blocked=0
total=0
while IFS= read -r _l; do [ -n "$_l" ] && total=$((total+1)); done <<EOF
$SECTIONS
EOF

if [ "$JSON" -eq 1 ]; then
  printf '{"project_version":"%s","available":[' "$VER"
  first=1
  while IFS="$TAB" read -r s e req raw; do
    ver_gte "$VER" "$req" || continue
    t="${raw#*+ }"; t="${t#— }"; t="${t//\"/\\\"}"
    [ "$first" -eq 0 ] && printf ','
    printf '{"start":%s,"end":%s,"min_go":"%s","title":"%s"}' "$s" "$e" "$req" "$t"
    first=0; avail=$((avail+1))
  done <<EOF
$SECTIONS
EOF
  printf '],"blocked":['
  first=1
  while IFS="$TAB" read -r s e req raw; do
    ver_gte "$VER" "$req" && continue
    t="${raw#*+ }"; t="${t#— }"; t="${t//\"/\\\"}"
    [ "$first" -eq 0 ] && printf ','
    printf '{"min_go":"%s","title":"%s"}' "$req" "$t"
    first=0; blocked=$((blocked+1))
  done <<EOF
$SECTIONS
EOF
  printf ']}\n'
  exit 0
fi

echo "项目 Go 版本: $VER"
echo "规则总数: $total"
echo

if [ "$BLOCKED_ONLY" -eq 1 ]; then
  echo "不可用（需更高版本）:"
  while IFS="$TAB" read -r s e req raw; do
    ver_gte "$VER" "$req" && continue
    t="${raw#*+ }"; t="${t#— }"
    printf "  需 %-5s %s\n" "$req+" "$t"
    blocked=$((blocked+1))
  done <<EOF
$SECTIONS
EOF
  [ "$blocked" -eq 0 ] && echo "  （无，当前版本可用全部规则）"
  exit 0
fi

echo "可用规则（抽正文: modern_index.sh --section <起始行>）:"
while IFS="$TAB" read -r s e req raw; do
  ver_gte "$VER" "$req" || continue
  t="${raw#*+ }"; t="${t#— }"
  printf "  %4s-%-4s  %-6s %s\n" "$s" "$e" "${req}+" "$t"
  avail=$((avail+1))
done <<EOF
$SECTIONS
EOF

echo
echo "不可用（需升级 go.mod）:"
while IFS="$TAB" read -r s e req raw; do
  ver_gte "$VER" "$req" && continue
  t="${raw#*+ }"; t="${t#— }"
  printf "  %-6s %s\n" "需 ${req}+" "$t"
  blocked=$((blocked+1))
done <<EOF
$SECTIONS
EOF
[ "$blocked" -eq 0 ] && echo "  （无）"

echo
echo "汇总: 可用 $avail / 不可用 $blocked"
