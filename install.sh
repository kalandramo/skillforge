#!/usr/bin/env bash
# install.sh — 把本仓库的 skills/* 挂载到宿主的技能目录
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
MODE="link"
ACTION="install"
TARGETS=()

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: install.sh [选项]

  --target <dir>   指定技能目录（可多次；默认自动探测 ~/.workbuddy/skills 与 ~/.claude/skills）
  --link           优先符号链接（默认）
  --copy           强制复制
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
    --check)  ACTION="check" ;;
    -h|--help) usage ;;
    *) die "未知参数: $1" ;;
  esac
  shift
done

[ -d "$SRC_DIR" ] || die "未找到 $SRC_DIR"
REPO_REV="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"

if [ ${#TARGETS[@]} -eq 0 ]; then
  for d in "$HOME/.workbuddy/skills" "$HOME/.claude/skills"; do
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
            echo "  [ ok ]  $name — 已同步 ($REPO_REV)"
          else
            echo "  [stale] $name — 已安装 ${installed:-?}，仓库 $REPO_REV，需重跑 install"
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

ok=0; skipped=0; failed=0

for target in "${TARGETS[@]}"; do
  mkdir -p "$target" || { echo "  [FAIL] 无法创建 $target" >&2; failed=$((failed+1)); continue; }
  echo "==> $target"

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
        echo "         如需接管：mv \"$dst\" \"$dst.bak\" 后重跑"
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
    if cp -r "$src" "$dst"; then
      write_marker "$dst"
      echo "  [copy] $name（改动后需重跑本脚本）"
      ok=$((ok+1))
    else
      echo "  [FAIL] $name 复制失败" >&2
      failed=$((failed+1))
    fi
  done
done

echo
echo "完成：挂载 $ok，跳过 $skipped，失败 $failed（rev $REPO_REV）"
[ "$failed" -eq 0 ] || exit 1
echo "提示：技能列表在会话启动时加载，新挂载的技能需新开会话才可见。"
