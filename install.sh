#!/usr/bin/env bash
# install.sh — 把本仓库的 skills/* 挂载到宿主技能目录
#
# 支持的宿主：WorkBuddy（国内/国际版）、ZCode、Qoder、Trae CN。各自的技能目录：
#   WorkBuddy      ~/.workbuddy/skills（国内版）或 ~/.workbuddy-ai/skills（国际版）
#   ZCode          ~/.zcode/skills
#   Qoder          ~/.qoder/skills（国际版）或 ~/.qoder-cn/skills（中国版）
#   Trae CN        ~/.trae-cn/skills
#
# 为什么需要它：技能靠"目录出现在宿主扫描路径下"生效。手工复制会在上游改动后
# 悄悄失同步，所以优先用符号链接。Windows 下 ln -s 常因权限失败（需开发者模式），
# 此时退为复制并写入 .skillforge-origin 标记，`--check` 可检测是否已漂移。
#
# 注意：不调用 cmd.exe 创建 junction。原因：在受限 shell 中调用 cmd 会被安全策略
# 拦截，而"看起来能跑但实际被拦"比"明确回退到复制"更难排查。

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$REPO/skills"
RETIRED="$REPO/retired.txt"
MODE="link"
ACTION="install"
PRUNE=0
TARGETS=()

die() { echo "ERROR: $*" >&2; exit 1; }

# retired.txt 里"已退役"的名字，一行一个，`#` 后为注释。
# 用 while read 而不是 for 循环，避免中文注释里的空格被当成字段分隔。
retired_names() {
  [ -f "$RETIRED" ] || return 0
  local line name
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    name="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$name" ] && printf '%s\n' "$name"
  done < "$RETIRED"
}

usage() {
  cat <<'EOF'
用法: install.sh [选项]

  --target <dir>   指定技能目录（可多次）
                   缺省自动探测已存在的 ~/.workbuddy/skills、~/.workbuddy-ai/skills、
                   ~/.zcode/skills、~/.qoder/skills、~/.qoder-cn/skills、
                   ~/.trae-cn/skills
  --link           优先符号链接（默认）
  --copy           强制复制
  --prune          顺带清理宿主目录里已退役技能的旧副本（清单见 retired.txt）
                   只移入备份目录，不删除；可用 SKILLFORGE_BACKUP 指定落点
  --check          只检查已安装版本是否落后于本仓库，不做改动
  -h, --help       显示本帮助

复制模式说明：改动本仓库后需重跑本脚本才会同步，用 --check 可先确认是否落后。
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) [ -n "${2:-}" ] || die "--target 需要参数"; TARGETS+=("$2"); shift ;;
    --copy)   MODE="copy" ;;
    --link)   MODE="link" ;;
    --prune)  PRUNE=1 ;;
    --check)  ACTION="check" ;;
    -h|--help) usage ;;
    *) die "未知参数: $1" ;;
  esac
  shift
done

[ -d "$SRC_DIR" ] || die "未找到 $SRC_DIR"
REPO_REV="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"

if [ ${#TARGETS[@]} -eq 0 ]; then
  for d in "$HOME/.workbuddy/skills" "$HOME/.workbuddy-ai/skills" \
           "$HOME/.zcode/skills" "$HOME/.qoder/skills" "$HOME/.qoder-cn/skills" \
           "$HOME/.trae-cn/skills"; do
    [ -d "$d" ] && TARGETS+=("$d")
  done
  if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "未探测到技能目录。用 --target 指定，例如：" >&2
    echo "  bash install.sh --target \"\$HOME/.workbuddy/skills\"" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------- check
if [ "$ACTION" = "check" ]; then
  drift=0
  for target in "${TARGETS[@]}"; do
    echo "==> $target"
    [ -d "$target" ] || { echo "  （目录不存在）"; continue; }
    for src in "$SRC_DIR"/*/; do
      name="$(basename "${src%/}")"
      dst="$target/$name"
      if [ -L "$dst" ]; then
        echo "  [link]  $name — 链接模式，始终与仓库一致"
      elif [ -d "$dst" ]; then
        marker="$dst/.skillforge-origin"
        if [ -f "$marker" ]; then
          installed="$(sed -n 's/^rev=//p' "$marker" | head -1)"
          if [ "$installed" = "$REPO_REV" ]; then
            printf '  [ ok ]  %s — 已同步 (%s)\n' "$name" "$REPO_REV"
          else
            printf '  [stale] %s — 已安装 %s，仓库 %s，需重跑 install\n' "$name" "${installed:-?}" "$REPO_REV"
            drift=1
          fi
        else
          echo "  [ ?  ]  $name — 存在但不是本脚本安装的（无来源标记）"
          drift=1
        fi
      else
        echo "  [miss]  $name — 未安装"
        drift=1
      fi
    done
    # 已退役技能的残留：不算"没装好"，但会与新技能争抢触发，值得提示
    while IFS= read -r rname; do
      [ -n "$rname" ] || continue
      if [ -e "$target/$rname" ] || [ -L "$target/$rname" ]; then
        printf '  [old]   %s — 已退役技能的残留副本，可用 install.sh --prune 清理\n' "$rname"
        drift=1
      fi
    done <<RETIRED_EOF
$(retired_names)
RETIRED_EOF
  done
  [ "$drift" -eq 0 ] && echo && echo "全部已同步" || { echo; echo "存在未同步项，运行不带 --check 的 install.sh 同步"; exit 1; }
  exit 0
fi

# ---------------------------------------------------------------- install
write_marker() {
  local dst="$1"
  {
    echo "source=$REPO/skills/$(basename "$dst")"
    echo "rev=$REPO_REV"
    echo "installed_at=$(date '+%Y-%m-%dT%H:%M:%S')"
  } > "$dst/.skillforge-origin"
}

ok=0; skipped=0; failed=0; pruned=0

for target in "${TARGETS[@]}"; do
  mkdir -p "$target" || { echo "  [FAIL] 无法创建 $target" >&2; failed=$((failed+1)); continue; }
  echo "==> $target"

  # 退役技能残留清理：移入备份目录而不是删除，回退成本最低。
  # 仓库里仍存在的同名目录一律跳过——防止把刚加回仓库的技能误清掉。
  if [ "$PRUNE" -eq 1 ]; then
    # 备份目录名带上父目录：三家技能目录都叫 skills，只取 basename 会在同一秒内撞名
    prune_parent="$(basename "$(dirname "$target")")"
    prune_parent="${prune_parent#.}"
    backup_root="${SKILLFORGE_BACKUP:-$HOME/.skillforge-backup}/${prune_parent}-$(basename "$target")-pruned-$(date '+%Y%m%d-%H%M%S')"
    while IFS= read -r rname; do
      [ -n "$rname" ] || continue
      [ -d "$SRC_DIR/$rname" ] && continue
      [ -e "$target/$rname" ] || [ -L "$target/$rname" ] || continue
      if [ ! -d "$backup_root" ]; then
        mkdir -p "$backup_root" || { echo "  [WARN] 无法创建备份目录 $backup_root" >&2; break; }
      fi
      if mv "$target/$rname" "$backup_root/$rname" 2>/dev/null; then
        echo "  [prune] $rname → $backup_root"
        pruned=$((pruned+1))
      else
        echo "  [WARN] 无法移走 $rname，请手工处理" >&2
      fi
    done <<RETIRED_EOF
$(retired_names)
RETIRED_EOF
    if [ "$pruned" -gt 0 ]; then
      echo "  （退役副本已备份，需要时从上面目录取回）"
    fi
  fi

  for src in "$SRC_DIR"/*/; do
    src="${src%/}"
    name="$(basename "$src")"
    dst="$target/$name"

    if [ -L "$dst" ]; then
      # 只删除链接本身，绝不触碰链接指向的源目录
      rm -f "$dst" || { echo "  [FAIL] 无法移除旧链接 $dst" >&2; failed=$((failed+1)); continue; }
    elif [ -d "$dst" ]; then
      if [ -f "$dst/.skillforge-origin" ]; then
        rm -rf "$dst"   # 本脚本此前复制的产物，可安全替换
      else
        echo "  [skip] $name — 已存在且非本脚本安装，不覆盖"
        printf '         如需接管：mv "%s" "%s.bak" 后重跑\n' "$dst" "$dst"
        skipped=$((skipped+1))
        continue
      fi
    elif [ -e "$dst" ]; then
      echo "  [skip] $name — 同名文件已存在，不覆盖"
      skipped=$((skipped+1))
      continue
    fi

    if [ "$MODE" = "link" ] && ln -s "$src" "$dst" 2>/dev/null; then
      echo "  [link] $name"
      ok=$((ok+1))
      continue
    fi

    if [ "$MODE" = "link" ]; then
      echo "  [info] $name 无法创建符号链接（Windows 需开发者模式），改为复制"
    fi
    # ln -s 失败时 Git Bash 可能留下一个空目录占位；不清掉会导致 cp -r 把源
    # 复制进空壳里，形成 <name>/<name>/ 的嵌套（且脚本仍返回成功）。只删空目录。
    if [ -d "$dst" ] && [ -z "$(ls -A "$dst" 2>/dev/null)" ]; then
      rmdir "$dst" 2>/dev/null || true
    fi
    if [ -e "$dst" ]; then
      echo "  [FAIL] $name 目标仍存在，跳过以避免嵌套复制" >&2
      failed=$((failed+1))
      continue
    fi
    if cp -r "$src" "$dst"; then
      write_marker "$dst"
      echo "  [copy] ${name}（改动后需重跑本脚本）"
      ok=$((ok+1))
    else
      echo "  [FAIL] $name 复制失败" >&2
      failed=$((failed+1))
    fi
  done
done

echo
printf '完成：挂载 %s，跳过 %s，失败 %s' "$ok" "$skipped" "$failed"
[ "$PRUNE" -eq 1 ] && printf '，清理退役 %s' "$pruned"
printf '（rev %s）\n' "$REPO_REV"
[ "$failed" -eq 0 ] || exit 1
echo "提示：技能列表在会话启动时加载，新挂载的技能需新开会话才可见。"
