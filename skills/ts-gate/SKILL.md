---
name: ts-gate
display_name: "TypeScript 质量门禁（TS Gate）"
description: "TypeScript / JavaScript 项目的确定性质量门禁：dep_guard、typecheck（tsc --noEmit）、lint（只查本次改动文件）、test，可选 build 与 bench，输出 JSON 与退出码。当用户说「跑 TS 门禁」「TypeScript 类型检查」「前端质量检查」「验证这个 TS 改动」时使用。非 TS/JS 项目不适用（Go 用 go-gate）。"
user-invocable: true
---

# ts-gate — TypeScript / JavaScript 质量门禁

与 `go-gate` 同一份契约：**只有两种结果**，通过（exit 0）或失败（exit 1）。不打分、不给建议、不产生需要二次解释的中间态。

## 为什么需要它

`dev` 的阶段 4 原本只有 `go-gate` 一条命令——那是 Go 工具链。做 TS 项目时，阶段 4 会没有判据可用：要么助手自己临场敲 `npx tsc`（每次敲法不同，无法比较），要么直接跳过门禁（等于没有判定）。本技能把同一套判据纪律落到 tsc / eslint / test 上，让 `dev` 在 TS 仓库里也能"做完没做完由程序回答"。

## 门禁清单

| 阶段 | 命令 | 存在理由 |
|---|---|---|
| `dep_guard` | `git diff --quiet -- package.json <lockfile>` | 依赖变更必须显式批准；随手装包是前端项目最常见的隐性破坏 |
| `typecheck` | `node_modules/.bin/tsc --noEmit` | 类型错误是 TS 的主要 bug 来源，且只有编译器是权威 |
| `lint` | `eslint <本次改动的文件>` | **只查新增**，见下 |
| `test` | `CI=1 <包管理器> test` | 行为契约 |
| `build` | `<包管理器> run build`（仅 `--build`） | 能打包 = 入口与导出没断 |
| `bench` | `<包管理器> run bench`（仅 `--bench`） | 只作回归参考，**不产出 metric** |

包管理器按 lockfile 自动判定：`pnpm-lock.yaml` → pnpm，`yarn.lock` → yarn，`bun.lockb` → bun，`package-lock.json` → npm。

### lint 为什么只传改动文件

ESLint 没有 `golangci-lint --new-from-rev` 这样的增量开关。等价做法是把 `git diff --name-only` 与未跟踪文件合成清单，只把这些文件交给 eslint——天然只覆盖新增问题，存量欠账不参与判定。

代价要认：跨文件规则（import 循环、依赖边界）只能看到改动文件这一侧。这个代价比"存量欠账让门禁永远红、循环第一轮就耗尽失败预算"小得多，取前者。

基线默认探测 `origin/main`、`origin/master`、`upstream/main`、`upstream/master`，**不认本地 main/master**——本地分支通常就是当前 HEAD，拿它做基线会让 diff 恒为空，lint 变成"什么都没查"却报 pass。无远端引用时退回 `HEAD`，即只查工作区未提交改动。

### bench 为什么不给 metric

Go 侧靠多次取样取中位数，TS 生态没有同级工具。与其编一个数字，不如明确标注"未度量"。因此 `--bench` 只回答"bench 脚本还跑得动吗"，**不能**用它支撑性能结论。

## 与 `typescript` 技能的分工

| | 负责 | 何时用 |
|---|---|---|
| `typescript` | 纪律：怎么写才不给自己挖坑（判别联合、品牌类型、边界校验） | `dev` 阶段 3 写代码前 |
| `ts-gate` | 判据：写完到底对不对 | `dev` 阶段 4 判定，或单独跑 |

前者是知识，后者是执行器。两者不互相替代，也不重复。

## 用法

```bash
# 常规门禁（类型 + lint 增量 + 测试）
bash scripts/ts_gate.sh

# 机器可读
bash scripts/ts_gate.sh --json

# 迭代时快速反馈（跳过慢的测试）
bash scripts/ts_gate.sh --skip test

# 确实是本次需求要加依赖
bash scripts/ts_gate.sh --allow-dep-changes

# 发布前额外验证打包
bash scripts/ts_gate.sh --build

# 指定基线
bash scripts/ts_gate.sh --base origin/develop

# monorepo
bash scripts/ts_gate.sh --root packages/web
```

参数：`--root DIR`、`--json`、`--base REV`、`--allow-dep-changes`、`--build`、`--bench`、`--skip a,b,c`。

退出码：`0` 通过（skip 不算失败）、`1` 有阶段失败、`2` 参数或环境错误（如目录下没有 `package.json`）。

## JSON 契约

```json
{
  "root": "/path/to/repo",
  "ok": false,
  "metric": { "name": "", "value": "" },
  "stages": [
    { "name": "dep_guard", "status": "pass", "ms": 0 },
    { "name": "typecheck", "status": "pass", "ms": 107 },
    { "name": "lint", "status": "skip", "ms": 0 },
    { "name": "test", "status": "fail", "ms": 539 }
  ],
  "log_dir": "/path/to/repo/.dev/ts-gate/20261115-171909"
}
```

- `status` 取值：`pass` | `fail` | `skip`；`ok=false` 时一定存在 `fail`。
- `metric` 恒为空字符串——TS 侧不做中位数统计，见上。
- 每个阶段的完整输出在 `log_dir/<stage>.log`，失败时终端已打印尾部 12 行。

## 判定规则

1. **任一阶段 `fail`，本轮改动不得保留。** 不存在"测试挂了但代码更好"的空间。
2. **`skip` 必须可解释。** 工具缺失（未装 eslint、无 tsconfig）导致的 skip 应在报告里写明；参数导致的 skip 由编排层记录。
3. **不产出性能结论。** `bench` 通过只说明脚本能跑，不代表没变慢。

## 常见调整

| 情况 | 处理 |
|---|---|
| 仓库有存量 lint 欠账 | 保持默认的改动文件范围，不要改成全量 `eslint .` |
| 未装 eslint | 自动 skip；需要时 `pnpm add -D eslint` 并加配置 |
| 无 `tsconfig.json` | typecheck 自动 skip；这不是 TS 严格项目，别硬造一个 |
| 测试很慢 | 迭代时 `--skip test`，收尾前必须跑全量 |
| monorepo | `--root packages/<name>` 指向子包，而不是仓库根 |
| 想同时要 Go 门禁 | 两个技能各自跑，`dev` 按改动文件类型分派 |

## 反模式

- 为了变绿加 `// @ts-expect-error`、`eslint-disable`、或把断言改成 `as any`。
- 把 `--skip test` 写进 CI 配置（等于取消门禁）。
- 把 `--allow-dep-changes` 设为默认值（等于取消依赖守卫）。
- 用 `--bench` 的通过来宣称"性能没退化"。
- 在无 `tsconfig.json` 的项目里手写一个宽松配置来"让 typecheck 通过"。
