#!/usr/bin/env python3
"""check-arch.py — 分层依赖门禁。

判定"包的 import 是否越过分层边界"，只输出 pass/fail，不打分。
零外部依赖：只用 python3 stdlib + `go list`。

用法：
  python3 scripts/check-arch.py [--root DIR] [--config .arch.json]
                                [--base REV] [--changed-only] [--all]

退出码：0 = 无违规；1 = 有违规；2 = 配置或环境不可用。

配置（默认 .arch.json，放仓库根）：
{
  "layers": {
    "domain":    ["example.com/proj/internal/domain"],
    "app":       ["example.com/proj/internal/app"],
    "infra":     ["example.com/proj/internal/infra"],
    "transport": ["example.com/proj/internal/transport"]
  },
  "allow": {
    "domain":    [],
    "app":       ["domain"],
    "infra":     ["domain", "app"],
    "transport": ["app", "domain"]
  },
  "forbid": [
    {"from": "domain", "to": ["gorm.io/*", "database/sql"]}
  ],
  "ignore": ["example.com/proj/internal/generated"],
  "strict": {"require_layer_under": ["example.com/proj/internal"]}
}

语义（刻意保持最小）：
  - 包归属哪个层：在 layers 的 prefix 里取最长匹配（按路径段对齐，不匹配半截）。
  - 层 -> 层：只有 allow[from] 里列出的层可依赖；**同层依赖恒允许**；
    某层未出现在 allow 里 = 该层不得依赖任何其它层。
  - 非层目标（标准库、第三方库）：只受 forbid 约束。
  - forbid 的 from 可以是层名，也可以是包路径前缀；to 支持尾部 `*` 通配。
  - ignore 里的包不检查、也不作为违规目标。
  - strict.require_layer_under 里的路径前缀下，任何**不属于任何层**的新包都算违规
    （架构漂移最常见的起点是"又加了一个没人分层的新包"）。该键可选。
  - 只统计非测试 import（go list .Imports），测试包可自由 import 基础设施。
"""

import argparse
import json
import os
import subprocess
import sys


def die(msg, code=2):
    sys.stderr.write("check-arch: %s\n" % msg)
    sys.exit(code)


def load_config(root, path):
    full = path if os.path.isabs(path) else os.path.join(root, path)
    if not os.path.isfile(full):
        die("找不到配置文件: %s" % full)
    try:
        with open(full, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception as exc:  # noqa: BLE001 - 配置错误即环境错误
        die("配置不是合法 JSON (%s): %s" % (full, exc))
    if not isinstance(cfg.get("layers"), dict) or not cfg["layers"]:
        die("配置缺 layers（对象：层名 -> 包路径前缀数组）")
    for name, prefixes in cfg["layers"].items():
        if not isinstance(prefixes, list) or not prefixes:
            die("layers.%s 必须是非空数组" % name)
    allow = cfg.get("allow", {})
    if not isinstance(allow, dict):
        die("allow 必须是对象：层名 -> 允许依赖的层名数组")
    for name, deps in allow.items():
        if not isinstance(deps, list):
            die("allow.%s 必须是数组" % name)
        for dep in deps:
            if dep not in cfg["layers"]:
                die("allow.%s 引用了未定义的层: %s" % (name, dep))
    for rule in cfg.get("forbid", []):
        if "from" not in rule or "to" not in rule:
            die("forbid 条目必须同时有 from 与 to")
        if not isinstance(rule["to"], list):
            die("forbid.to 必须是数组")
        if rule["from"] in cfg["layers"]:
            continue
        # from 也可以是包路径前缀，但必须能被任何 layers 前缀/ignore 覆盖的可能性无从校验，放行
    return cfg


def in_prefix(path, prefix):
    """按路径段对齐匹配：pkg == prefix 或 pkg 以 prefix + '/' 开头。"""
    return path == prefix or path.startswith(prefix + "/")


def layer_of(pkg, layers):
    best, best_len = None, -1
    for name, prefixes in layers.items():
        for prefix in prefixes:
            if in_prefix(pkg, prefix) and len(prefix) > best_len:
                best, best_len = name, len(prefix)
    return best


def glob_match(path, pattern):
    if pattern.endswith("/*"):
        return in_prefix(path, pattern[:-2]) or path == pattern[:-2]
    if pattern.endswith("*"):
        return path.startswith(pattern[:-1])
    return path == pattern or in_prefix(path, pattern)


def go_list(root):
    cmd = ["go", "list", "-f", "{{.ImportPath}}\t{{.Dir}}\t{{join .Imports \" \"}}", "./..."]
    try:
        proc = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
    except FileNotFoundError:
        die("未安装 go")
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.strip() + "\n")
        die("go list 失败（rc=%d）：包无法解析时分层检查无从进行" % proc.returncode)
    pkgs = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        pkg = parts[0]
        pkg_dir = parts[1]
        imports = parts[2].split() if len(parts) > 2 and parts[2] else []
        pkgs.append((pkg, pkg_dir, imports))
    return pkgs


def changed_dirs(root, base):
    """返回本次改动涉及的 .go 文件所在目录集合；探测失败返回 None（=不限制）。

    三个来源取并集，避免漏判：分支提交（base...HEAD）、工作树已跟踪改动（HEAD）、
    未跟踪新文件。任一路径来源可用即视为探测成功；base 本身无效则退化为不限制。
    """
    probe = subprocess.run(
        ["git", "rev-parse", "--verify", "-q", base],
        cwd=root, capture_output=True, text=True,
    )
    if probe.returncode != 0:
        return None
    specs = [
        ["diff", "--name-only", "%s...HEAD" % base, "--", "*.go"],
        ["diff", "--name-only", "HEAD", "--", "*.go"],
        ["ls-files", "--others", "--exclude-standard", "--", "*.go"],
    ]
    files, ok = set(), False
    for spec in specs:
        proc = subprocess.run(["git"] + spec, cwd=root, capture_output=True, text=True)
        if proc.returncode == 0:
            ok = True
            files.update(p.strip() for p in proc.stdout.splitlines() if p.strip())
    if not ok:
        return None
    return {os.path.abspath(os.path.join(root, os.path.dirname(rel))) for rel in files}


def autodetect_base(root):
    for cand in ("origin/main", "origin/master", "main", "master"):
        proc = subprocess.run(
            ["git", "rev-parse", "--verify", "-q", cand],
            cwd=root, capture_output=True, text=True,
        )
        if proc.returncode == 0:
            return cand
    return None


def find_import_site(pkg_dir, imp):
    """在包目录的非测试 .go 文件里定位 import 出现处，返回 (文件, 行号) 或 None。"""
    needle = '"%s"' % imp
    try:
        names = sorted(n for n in os.listdir(pkg_dir) if n.endswith(".go") and not n.endswith("_test.go"))
    except OSError:
        return None
    for name in names:
        full = os.path.join(pkg_dir, name)
        try:
            with open(full, "r", encoding="utf-8", errors="replace") as fh:
                for idx, line in enumerate(fh, 1):
                    if needle in line:
                        return full, idx
        except OSError:
            continue
    return None


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", default=os.getcwd())
    ap.add_argument("--config", default=".arch.json")
    ap.add_argument("--base", default=None)
    ap.add_argument("--changed-only", action="store_true")
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        die("目录不存在: %s" % root)
    if not os.path.isfile(os.path.join(root, "go.mod")):
        die("不是 Go 模块（缺 go.mod）: %s" % root)

    cfg = load_config(root, args.config)
    layers = cfg["layers"]
    allow = cfg.get("allow", {})
    forbid = cfg.get("forbid", [])
    ignore = cfg.get("ignore", [])
    strict = cfg.get("strict", {}) or {}
    require_layer_under = strict.get("require_layer_under", [])
    if not isinstance(require_layer_under, list):
        die("strict.require_layer_under 必须是数组")

    pkgs = go_list(root)

    restrict = None
    if args.changed_only and not args.all:
        base = args.base or autodetect_base(root)
        if base:
            restrict = changed_dirs(root, base)
            if restrict is None:
                print("[warn] 无法计算 %s 之后的变更，退化为全量检查" % base)
    if args.all:
        restrict = None

    def ignored(path):
        return any(in_prefix(path, p) for p in ignore)

    violations = []
    scanned = 0
    for pkg, pkg_dir, imports in pkgs:
        if ignored(pkg):
            continue
        if restrict is not None and os.path.abspath(pkg_dir) not in restrict:
            continue
        scanned += 1
        src_layer = layer_of(pkg, layers)
        allowed_layers = set(allow.get(src_layer, [])) if src_layer else set()

        # 0) 未分层的新包（仅在 strict.require_layer_under 覆盖的范围内判定）
        if src_layer is None and any(in_prefix(pkg, p) for p in require_layer_under):
            violations.append({
                "pkg": pkg, "dir": pkg_dir, "imp": "",
                "rule": "未分层：%s 不归属任何已声明的层，需先在 .arch.json 里给它定层与允许的依赖方向" % pkg,
            })
            continue

        for imp in imports:
            if imp.startswith("vendor/") or ignored(imp):
                continue
            tgt_layer = layer_of(imp, layers)

            # 1) 层 -> 层 越界
            if src_layer and tgt_layer and tgt_layer != src_layer and tgt_layer not in allowed_layers:
                violations.append({
                    "pkg": pkg, "dir": pkg_dir, "imp": imp,
                    "rule": "层依赖越界：%s 不允许依赖 %s（allow[%s]=%s）"
                            % (src_layer, tgt_layer, src_layer, sorted(allowed_layers) or "空"),
                })
                continue
            # 2) 从某层/某前缀出发的显式禁止
            for rule in forbid:
                frm = rule["from"]
                hit_from = (frm == src_layer) if frm in layers else in_prefix(pkg, frm)
                if not hit_from:
                    continue
                if any(glob_match(imp, pat) for pat in rule["to"]):
                    violations.append({
                        "pkg": pkg, "dir": pkg_dir, "imp": imp,
                        "rule": "显式禁止：%s 不得 import %s" % (frm, " 或 ".join(rule["to"])),
                    })
                    break

    mode = "changed-only" if restrict is not None else "all"
    print("check-arch: %d 个层, 扫描 %d/%d 个包 (mode=%s)"
          % (len(layers), scanned, len(pkgs), mode))

    if not violations:
        print("  [ OK ] 无分层依赖违规")
        return 0

    for v in violations:
        print("  [FAIL] %s" % v["rule"])
        if v["imp"]:
            site = find_import_site(v["dir"], v["imp"])
            where = "%s:%d" % (site[0], site[1]) if site else v["pkg"]
            print("         %s -> %s" % (where, v["imp"]))
    print("  违规 %d 条。修方向：把依赖倒过来（下层定义接口、上层实现），"
          "或把跨界代码挪到允许该方向的层；不要放宽 allow 来消除违规。"
          % len(violations))
    return 1


if __name__ == "__main__":
    sys.exit(main())
