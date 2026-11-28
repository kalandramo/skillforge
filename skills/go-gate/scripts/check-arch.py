#!/usr/bin/env python3
"""check-arch.py — 分层依赖门禁。

判定"包的 import 是否越过分层边界"，只输出 pass/fail，不打分。
零外部依赖：只用 python3 stdlib + `go list`。

用法：
  python3 scripts/check-arch.py [--root DIR] [--config .arch.json]
                                [--base REV] [--changed-only] [--all]
  python3 scripts/check-arch.py --init [--write] [--force] [--config FILE]
  python3 scripts/check-arch.py --evidence [--depth N]
  python3 scripts/check-arch.py --verify [--config FILE]

退出码：0 = 无违规（或初稿/证据生成成功、契约自检通过）；1 = 有违规或契约有错；
        2 = 配置或环境不可用。

三种"写契约"的路径，选一条：
  --init       目录按惯例分层（domain/app/infra/transport），机械可推导，零猜测。
  --evidence   目录不按层切（垂直切片 internal/<模块>/{domain,app,infra}、按业务分包、
               层名写在文档里）时用这个：把包图 + 重复目录名 + 文档里的分层陈述
               摊成事实清单，交给模型（或人）据此写 .arch.json。
  --verify     契约写完后自检：前缀是否匹配到包、包是否都归了层、多命中、forbid 是否
               永不触发。**模型生成的契约必须过这一关**——前缀写错时规则永不触发，
               门禁长期全绿，比没有门禁更危险。

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

初稿生成（--init）：
  按目录惯例分层（容器目录 internal / pkg / src 的后一段为层名，否则首段为层名），
  再按惯例定序（domain < app < infra < transport < cmd），allow 只写"外层依赖内层"。
  **代码里现有的反向依赖不会写进 allow**——那等于把漂移固化成规范。它们会被列进
  "需人工定夺"清单，由人决定清理还是显式放行。去掉这一步人工作业，等于让门禁
  抄一份现状当标准。
"""

import argparse
import json
import os
import re
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


def layer_prefix_match(pkg, prefix):
    """层前缀匹配：不含 * 按路径段前缀；含 * 时 * 只吃一个路径段（支持 internal/*/domain，
    且仍覆盖其子包），用于垂直切片/按业务分包的仓库。"""
    if "*" not in prefix:
        return in_prefix(pkg, prefix)
    psegs = pkg.split("/")
    pat = prefix.split("/")
    if len(psegs) < len(pat):
        return False
    for seg, want in zip(psegs, pat):
        if want == "*":
            continue
        if seg != want:
            return False
    return True


def layer_of(pkg, layers):
    best, best_len = None, -1
    for name, prefixes in layers.items():
        for prefix in prefixes:
            if layer_prefix_match(pkg, prefix) and len(prefix) > best_len:
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


def module_path(root):
    try:
        with open(os.path.join(root, "go.mod"), "r", encoding="utf-8") as fh:
            for line in fh:
                s = line.strip()
                if s.startswith("module "):
                    return s.split(None, 1)[1].strip().strip('"')
    except OSError:
        pass
    return ""


# 目录惯例：层名 -> 由内到外的序号（0 最内）。只用于"给初稿定序"，不参与判定。
LAYER_RANKS = {
    "domain": 0, "domainmodel": 0, "entity": 0, "entities": 0, "model": 0, "models": 0, "core": 0,
    "app": 1, "application": 1, "usecase": 1, "usecases": 1, "service": 1, "services": 1,
    "port": 1, "ports": 1, "biz": 1, "logic": 1,
    "infra": 2, "infrastructure": 2, "adapter": 2, "adapters": 2, "repo": 2, "repos": 2,
    "repository": 2, "repositories": 2, "store": 2, "storage": 2, "persistence": 2, "dao": 2,
    "transport": 3, "handler": 3, "handlers": 3, "api": 3, "http": 3, "grpc": 3, "server": 3,
    "delivery": 3, "controller": 3, "controllers": 3, "web": 3, "rpc": 3,
    "cmd": 4, "main": 4,
}

CONTAINERS = ("internal", "pkg", "src")
GENERATED_NAMES = ("generated", "gen", "mock", "mocks", "pb", "proto", "third_party")

# 最内层不该出现的实现依赖（只提出"代码里真的在用"的那些）
INNER_FORBIDDEN = (
    "database/sql", "gorm.io/", "entgo.io/", "github.com/jackc/pgx/", "github.com/lib/pq",
    "github.com/go-redis/", "github.com/redis/go-redis/", "net/http", "github.com/gin-gonic/",
    "github.com/labstack/", "github.com/gofiber/", "github.com/segmentio/kafka-go",
)


def rel_segments(pkg, mod):
    mp = mod.split("/") if mod else []
    parts = pkg.split("/")
    if mp and parts[:len(mp)] == mp:
        return parts[len(mp):], True
    return parts, False


def infer_layer(pkg, mod):
    """按目录惯例推层：容器目录（internal/pkg/src）后一段为层名，否则首段为层名。"""
    rest, under_mod = rel_segments(pkg, mod)
    if not rest:
        return None, None
    if rest[0] in CONTAINERS and len(rest) > 1:
        name, depth = rest[1], 2
    else:
        name, depth = rest[0], 1
    head = (mod.split("/") + rest[:depth]) if under_mod else rest[:depth]
    return name, "/".join(head)


def find_generated_prefixes(root, mod):
    out = []
    for container in CONTAINERS:
        for name in GENERATED_NAMES:
            if os.path.isdir(os.path.join(root, container, name)):
                out.append("/".join([p for p in (mod,) if p] + [container, name]))
    for name in GENERATED_NAMES:
        if os.path.isdir(os.path.join(root, name)):
            out.append("/".join([p for p in (mod,) if p] + [name]))
    return sorted(set(out))


SKIP_DIRS = {".git", ".dev", ".idea", ".vscode", "node_modules", "vendor", "dist", "build", "testdata"}

# 文档里表达"分层/依赖方向"的句子。只用来挑候选行，不做语义判断。
DOC_LAYER_RE = re.compile(
    r"分层|层次结构|架构|依赖|不得|禁止|只允许|只能|单向|反向|向上|向下|不依赖|解耦"
    r"|layer|layering|architect|depend|must not|may not|cannot import|boundar",
    re.IGNORECASE,
)


def logical_segments(pkg, mod):
    """去掉模块前缀与容器目录（internal/pkg/src）后的逻辑路径段。"""
    rest, _ = rel_segments(pkg, mod)
    if rest and rest[0] in CONTAINERS and len(rest) > 1:
        return rest[1:]
    return rest


def group_key(pkg, mod, depth):
    segs = logical_segments(pkg, mod)
    return "/".join(segs[:depth]) if segs else ""


def doc_files(root):
    """根级 md + docs/ 下两层 md + 任意 architect*.md；总量封顶 15 个。"""
    out = []
    try:
        for name in sorted(os.listdir(root)):
            full = os.path.join(root, name)
            if os.path.isfile(full) and name.lower().endswith((".md", ".markdown")):
                out.append(full)
    except OSError:
        pass
    docs = os.path.join(root, "docs")
    if os.path.isdir(docs):
        for dirpath, dirnames, filenames in os.walk(docs):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            if os.path.relpath(dirpath, docs).count(os.sep) > 1:
                dirnames[:] = []
                continue
            for name in sorted(filenames):
                if name.lower().endswith((".md", ".markdown")):
                    out.append(os.path.join(dirpath, name))
    return out[:15]


def doc_excerpts(root, per_file=6, total=60):
    """抽出文档里讲分层/依赖方向的行，带上 文件:行号，供模型判断，不做结论。"""
    picked, seen = [], set()
    for full in doc_files(root):
        if full in seen:
            continue
        seen.add(full)
        rel = os.path.relpath(full, root)
        try:
            with open(full, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        n = 0
        for idx, line in enumerate(lines, 1):
            text = line.strip()
            if not text or len(text) > 240:
                continue
            hit = bool(DOC_LAYER_RE.search(text)) or (
                text.startswith("#") and ("architect" in rel.lower() or "架构" in rel)
            )
            if not hit:
                continue
            picked.append((rel, idx, text))
            n += 1
            if n >= per_file or len(picked) >= total:
                break
        if len(picked) >= total:
            break
    return picked


def group_rank(key):
    """分组名按"最后一段"查惯例层序（order/domain -> domain -> 0），未知返回 None。"""
    return LAYER_RANKS.get(key.rsplit("/", 1)[-1].lower())


def do_evidence(root, depth):
    """把"这个项目的层在哪"摊成事实清单，交给模型/人写契约。本身不下判定。"""
    mod = module_path(root)
    if not mod:
        die("go.mod 里没有 module 行，无法推断包结构")
    pkgs = go_list(root)
    ignores = find_generated_prefixes(root, mod)

    def ignored(pkg):
        return any(in_prefix(pkg, p) for p in ignores)

    live = [p for p, _d, _i in pkgs if not ignored(p)]
    pkg_group = {}
    groups = {}
    for pkg in live:
        k = group_key(pkg, mod, depth)
        pkg_group[pkg] = k
        groups.setdefault(k, []).append(pkg)

    print("check-arch --evidence：模块 %s，%d 个包（已排除生成目录 %s）"
          % (mod, len(live), ", ".join(ignores) or "无"))
    print("\n[1] 目录分组（逻辑路径 = 去掉 internal/pkg/src 容器，按前 %d 段聚合）" % depth)
    for k in sorted(groups):
        r = group_rank(k)
        tag = "  [惯例层%s]" % (" rank=%d" % r if r is not None else "") if r is not None else ""
        print("    %-34s %2d 个包   例：%s%s" % (k, len(groups[k]), groups[k][0], tag))

    edges = {}
    for pkg, _dir, imports in pkgs:
        if ignored(pkg):
            continue
        frm = pkg_group.get(pkg)
        for imp in imports:
            to = pkg_group.get(imp)
            if not frm or not to or frm == to:
                continue
            edges.setdefault((frm, to), []).append((pkg, imp, _dir))
    print("\n[2] 实际 import 方向（同分组内不计；\"疑似反向\" = 两侧的末段都是惯例层名，")
    print("    且方向是\"内层 -> 外层\"，这正是需要人工确认的边）")
    if not edges:
        print("    （无跨分组依赖，各分组互相独立）")
    for (frm, to), hits in sorted(edges.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        rf, rt = group_rank(frm), group_rank(to)
        mark = "  ← 疑似反向" if (rf is not None and rt is not None and rt > rf) else ""
        print("    %-32s -> %-32s %2d 处%s" % (frm, to, len(hits), mark))

    name_parents = {}
    for pkg in live:
        segs = logical_segments(pkg, mod)
        # 末段也要算：垂直切片里"层目录自己就是一个包"，层名只会出现在最后一段
        for idx, seg in enumerate(segs):
            name_parents.setdefault(seg, set()).add("/".join(segs[:idx]) or ".")
    repeated = [(n, ps) for n, ps in name_parents.items() if len(ps) >= 2]
    repeated.sort(key=lambda kv: (-len(kv[1]), kv[0]))
    print("\n[3] 在多个父路径下重复出现的目录名（这是垂直切片项目的典型特征：")
    print("    名字不是\"模块\"而是\"层\"，层在深度 2 而不在深度 1）")
    if not repeated:
        print("    （无重复名，层名应当就在第 1 段）")
    for name, parents in repeated[:12]:
        hint = "（惯例层名）" if name.lower() in LAYER_RANKS else ""
        print("    %-14s %d 个父路径：%s %s"
              % (name, len(parents), ", ".join(sorted(parents)[:5]) + ("…" if len(parents) > 5 else ""), hint))
    if repeated:
        cand = [n for n, ps in repeated if n.lower() in LAYER_RANKS]
        if cand:
            print("    → 若确认是层，layers 里可用通配前缀，新切片自动纳管，无需逐个枚举：")
            for n in sorted(cand)[:4]:
                print("       \"%s\": [\"%s/*/%s\"]" % (n, mod + "/internal", n))

    print("\n[4] 文档里的分层陈述（只摘候选行，语义由模型/人判断）")
    excerpts = doc_excerpts(root)
    if not excerpts:
        print("    （README/AGENTS/docs 里没有提到分层或依赖方向的行）")
    for rel, idx, text in excerpts:
        print("    %s:%d  %s" % (rel, idx, text))

    print("\n[5] 下一步")
    print("    按上面的事实写 %s（层名 -> 包路径前缀；allow 只写允许的方向）。" % ".arch.json")
    print("    写完必须自检：python3 %s --root %s --verify" % (os.path.basename(__file__), root))
    return 0


def do_verify(root, config_path):
    """契约自检：写在契约里但永不触发的规则、漏归层的包、多命中，都要在这里暴露。"""
    mod = module_path(root)
    cfg = load_config(root, config_path)
    layers = cfg["layers"]
    ignores = cfg.get("ignore", [])
    pkgs = go_list(root)
    all_pkgs = [p for p, _d, _i in pkgs]
    all_imports = {imp for _p, _d, imps in pkgs for imp in imps}

    def ignored(pkg):
        return any(in_prefix(pkg, p) for p in ignores)

    live = [p for p in all_pkgs if not ignored(p)]
    errors, warns = [], []

    covered = {}
    for pkg in live:
        name = layer_of(pkg, layers)
        if name:
            covered.setdefault(name, []).append(pkg)

    for name in sorted(layers):
        for prefix in layers[name]:
            n = sum(1 for pkg in live if layer_prefix_match(pkg, prefix))
            if n == 0:
                errors.append("layers.%s 的前缀 %s 匹配不到任何包 —— 该规则永不触发（多半路径写错）"
                              % (name, prefix))

    multi = {}
    for pkg in live:
        hits = [n for n, pres in layers.items() if any(layer_prefix_match(pkg, x) for x in pres)]
        if len(hits) > 1:
            multi[pkg] = sorted(hits)
    for pkg, hits in sorted(multi.items())[:10]:
        errors.append("包 %s 同时命中多个层: %s（判定取最长前缀，但语义已含糊，应收窄）"
                      % (pkg, ", ".join(hits)))
    if len(multi) > 10:
        errors.append("… 另有 %d 个包多命中未列出" % (len(multi) - 10))

    uncovered = [p for p in live if not layer_of(p, layers)]
    if uncovered:
        warns.append("%d/%d 个包不属于任何层（新包会绕过分层判定）" % (len(uncovered), len(live)))
        for pkg in uncovered[:8]:
            warns.append("  未归层：%s" % pkg)
        if len(uncovered) > 8:
            warns.append("  … 另有 %d 个" % (len(uncovered) - 8))

    for rule in cfg.get("forbid", []):
        frm = rule["from"]
        srcs = [p for p in live if (p == frm or in_prefix(p, frm) or layer_of(p, layers) == frm)]
        if not srcs:
            warns.append("forbid 的 from=%s 匹配不到任何包（规则永不触发）" % frm)
        for pat in rule["to"]:
            if not any(glob_match(imp, pat) for imp in all_imports):
                warns.append("forbid 的 to=%s 在现有 import 里不存在（可能写错，或被清理后失效）" % pat)

    under = (cfg.get("strict") or {}).get("require_layer_under") or []
    for prefix in under:
        if not any(in_prefix(p, prefix) for p in live):
            errors.append("strict.require_layer_under 的 %s 下没有任何包（路径写错）" % prefix)

    total = len(live) or 1
    print("check-arch --verify：%s（模块 %s）" % (config_path, mod or "?"))
    print("  层覆盖：%d/%d 层有包；%d/%d 个包已归层（%d%%）"
          % (len(covered), len(layers), len(live) - len(uncovered), len(live),
             round(100.0 * (len(live) - len(uncovered)) / total)))
    for name in sorted(layers):
        print("    %-14s %3d 个包  ← %s" % (name, len(covered.get(name, [])), ", ".join(layers[name])))
    for msg in errors:
        print("  [FAIL] %s" % msg)
    for msg in warns:
        print("  [WARN] %s" % msg)
    if errors:
        print("  结论：契约有 %d 处必须修正 —— 这类错误不会让门禁变红，只会让它永久静默通过。" % len(errors))
        return 1
    print("  结论：契约可用%s" % ("（仍有见上 WARN，可接受但不建议长期保留）" if warns else ""))
    return 0


def do_init(root, config_path, write, force):
    mod = module_path(root)
    if not mod:
        die("go.mod 里没有 module 行，无法推断层前缀")
    ignores = find_generated_prefixes(root, mod)
    pkgs = go_list(root)

    def is_ignored(pkg):
        return any(in_prefix(pkg, p) for p in ignores)

    layer_prefixes, layer_count, pkg_layer = {}, {}, {}
    for pkg, _dir, _imports in pkgs:
        if is_ignored(pkg):
            continue
        name, prefix = infer_layer(pkg, mod)
        if not name:
            continue
        layer_prefixes.setdefault(name, set()).add(prefix)
        layer_count[name] = layer_count.get(name, 0) + 1
        pkg_layer[pkg] = name

    if not layer_prefixes:
        die("没能从目录结构推断出任何层，请手工编写 .arch.json")

    ranks = {n: LAYER_RANKS.get(n.lower()) for n in layer_prefixes}
    known_ranks = [r for r in ranks.values() if r is not None]

    edges = {}
    for pkg, _dir, imports in pkgs:
        src = pkg_layer.get(pkg)
        if not src:
            continue
        for imp in imports:
            tgt = pkg_layer.get(imp)
            if not tgt or tgt == src:
                continue
            edges.setdefault((src, tgt), []).append((pkg, imp, _dir))

    allow, pending = {}, []
    for name, rank in ranks.items():
        if rank is None:
            # 未识别层的名字无法定序：先放开（可依赖任意层），并在复核清单里点名
            allow[name] = sorted(n for n in layer_prefixes if n != name)
            continue
        allow[name] = sorted(n for n, r in ranks.items()
                             if n != name and r is not None and r < rank)
    for (src, tgt), hits in sorted(edges.items()):
        if tgt not in allow.get(src, []):
            pending.append((src, tgt, hits))

    # 最内层：对"代码里真的在 import 的实现依赖"提 forbid
    innermost = {n for n, r in ranks.items() if r is not None and r == min(known_ranks)} if known_ranks else set()
    forbid = []
    for layer in sorted(innermost):
        hits = set()
        for pkg, _dir, imports in pkgs:
            if pkg_layer.get(pkg) != layer:
                continue
            for imp in imports:
                for bad in INNER_FORBIDDEN:
                    if imp == bad.rstrip("/") or imp.startswith(bad):
                        hits.add(bad)
        for bad in sorted(hits):
            forbid.append({"from": layer, "to": [bad + "*" if bad.endswith("/") else bad]})

    containers_used = set()
    mod_parts = mod.split("/")
    for prefixes in layer_prefixes.values():
        for p in prefixes:
            parts = p.split("/")
            if parts[:len(mod_parts)] != mod_parts:
                continue
            rest = parts[len(mod_parts):]
            if rest and rest[0] in CONTAINERS:
                containers_used.add(rest[0])
    require_under = [mod + "/" + c for c in sorted(containers_used) if os.path.isdir(os.path.join(root, c))]

    cfg = {"_note": "由 check-arch.py --init 生成；allow 是按目录惯例的初稿，需人工复核后再提交"}
    cfg["layers"] = {n: sorted(v) for n, v in sorted(layer_prefixes.items())}
    cfg["allow"] = {n: allow[n] for n in sorted(allow)}
    cfg["forbid"] = forbid
    if ignores:
        cfg["ignore"] = ignores
    if require_under:
        cfg["strict"] = {"require_layer_under": require_under}

    print("check-arch --init：模块 %s，推断出 %d 层、%d 个包" % (mod, len(layer_prefixes), len(pkg_layer)))
    print("  层（按目录惯例由内到外）：")
    for name in sorted(layer_prefixes, key=lambda n: (ranks[n] is None, ranks[n] if ranks[n] is not None else 0, n)):
        r = ranks[name]
        print("    %-12s %2d 个包  %-8s %s"
              % (name, layer_count[name], "内层" if r == 0 else ("未定序" if r is None else "rank=%d" % r),
                 ", ".join(sorted(layer_prefixes[name]))))
    print("  allow 矩阵（外层可依赖内层；同层恒允许）：")
    for name in sorted(allow):
        print("    %-12s -> %s" % (name, ", ".join(allow[name]) or "（无）"))

    if pending:
        print("  ⚠ 现有代码里有 %d 组反向依赖，**未**写入 allow（需人工定夺）：" % len(pending))
        for src, tgt, hits in pending:
            site = find_import_site(hits[0][2], hits[0][1])
            where = "%s:%d" % (site[0], site[1]) if site else hits[0][2]
            print("    %s -> %s  (%d 处)  例：%s" % (src, tgt, len(hits), where))
        print("    处置：确认是历史欠账就清理；确认是合法方向，就把该边加进 allow 并写明理由。")
    unranked = sorted(n for n, r in ranks.items() if r is None)
    if unranked:
        print("  ⚠ 无法按惯例定序的层：%s（已置为可依赖任意层，请人工收紧）" % ", ".join(unranked))
    if forbid:
        print("  已为最内层 %s 提出 forbid：%s"
              % (", ".join(sorted(innermost)), "; ".join("%s→%s" % (r["from"], ",".join(r["to"])) for r in forbid)))
    if ignores:
        print("  已忽略生成目录：%s" % ", ".join(ignores))

    body = json.dumps(cfg, indent=2, ensure_ascii=False, sort_keys=False) + "\n"
    target = config_path if os.path.isabs(config_path) else os.path.join(root, config_path)
    if write:
        if os.path.exists(target) and not force:
            die("%s 已存在；确认要覆盖请加 --force" % target)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(body)
        print("  已写入 %s —— 请复核 allow 矩阵与上面列出的反向依赖，确认后再提交。" % target)
    else:
        print("  （未写入文件。确认无误后加 --write 落盘，或用 --config 指定别的位置）")
        print(body)
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--root", default=os.getcwd())
    ap.add_argument("--config", default=".arch.json")
    ap.add_argument("--base", default=None)
    ap.add_argument("--changed-only", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--init", action="store_true", help="从目录结构推断分层，生成 .arch.json 初稿")
    ap.add_argument("--write", action="store_true", help="配合 --init：把初稿写入 --config 指定的文件")
    ap.add_argument("--force", action="store_true", help="配合 --init --write：允许覆盖已存在的配置文件")
    ap.add_argument("--evidence", action="store_true",
                    help="目录不按层切时用：打印包图、重复目录名与文档里的分层陈述，供模型/人写契约")
    ap.add_argument("--depth", type=int, default=2, help="配合 --evidence：按逻辑路径前 N 段聚合（默认 2）")
    ap.add_argument("--verify", action="store_true",
                    help="契约自检：前缀是否匹配到包、包是否都归层、多命中、forbid 是否永不触发")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        die("目录不存在: %s" % root)
    if not os.path.isfile(os.path.join(root, "go.mod")):
        die("不是 Go 模块（缺 go.mod）: %s" % root)
    if args.init:
        return do_init(root, args.config, args.write, args.force)
    if args.evidence:
        if args.depth < 1 or args.depth > 3:
            die("--depth 只能是 1、2、3")
        return do_evidence(root, args.depth)
    if args.verify:
        return do_verify(root, args.config)

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
