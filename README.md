# skillforge

个人技能合集。给 AI 编码代理用的可执行工作流，主力场景是 Go 后端。

不是又一个 prompt 集合——每个技能都配套一个**能返回退出码的脚本**，判定不靠模型自述。

## 七个技能，两层

**流程层** 决定做什么、做到什么程度，三个脚本各有唯一职责：

| 技能 | 一句话 | 判据来源 |
|---|---|---|
| [`dev`](skills/dev/SKILL.md) | 一条需求进来，走完判据→诊断→设计→切片→实现→门禁→审阅→判定→收尾，内层循环 N 轮 | 调用下面两个 |
| [`go-gate`](skills/go-gate/SKILL.md) | Go 门禁：`mod_guard`/`build`/`vet`/`test`/`race`/`lint`/`bench` | 进程退出码 + bench 中位数 |
| [`loop`](skills/loop/SKILL.md) | 记账、epsilon 比较、keep/revert、账本不变量审计、基准漂移检测、确定性停止条件（含震荡检测） | 指标数值 + 账本不变量 |

三者职责不能互相替代：`go-gate` 答"这版对不对"，`loop` 答"这版要不要留、还继续吗"，`dev` 答"接下来做什么"。**换语言只需替换 `go-gate`，判定逻辑不动。**

**能力层** 只被按需调用，不参与流程决策：

| 技能 | 行数 | 用在 | 加载方式 |
|---|---:|---|---|
| [`modern-go`](skills/modern-go/SKILL.md) | 1162 | `dev` 阶段 3，改动含 `.go` 时 | **索引脚本**：先取 30–46 行清单，命中后再抽单节 |
| [`refactor`](skills/refactor/SKILL.md) | 716 | `dev` 阶段 5，结构性 blocking 或 `refactor` 轮次 | `grep '^### '` 定位手法，抽一节 |
| [`smell`](skills/smell/SKILL.md) | 750 | `dev` 阶段 0.5（仅存量改造），每需求最多 1 次 | 全量读一次，报告落地后即卸载 |
| [`jev-judgment`](skills/jev-judgment/SKILL.md) | 见文件 | 按需：筛查不可信文本、对照证据核实、语义选优/分类、完成门禁 | 全量读；**需宿主配置 jev MCP + TypeSafe API key**，未配置时不可用 |

前三者合计约 2600 行 / 35k tokens。**任何一轮循环都不整份加载**——读进去却只用上一条规则，等于把后续轮次的上下文预算提前烧掉。这是 `dev` 里"上下文预算"一节的来源。`jev-judgment` 是例外：它没有规则库，只有一份使用协议，且依赖外部服务（宿主未配置 jev MCP 时整体不触发）。

### modern-go 为什么要索引脚本

它有 46 条规则，每条带 Go 版本门控（从 1.0 到 1.27）。原技能假设"一次性现代化整个项目"，而循环里每次只需要改一处。所以配了 `scripts/modern_index.sh`：

```bash
bash skills/modern-go/scripts/modern_index.sh --root <repo>
# 项目 Go 版本: 1.22
# 规则总数: 46
# 可用规则（抽正文: --section <起始行>）:
#    49-61    1.0+   `time.Since`
#   ...
# 汇总: 可用 32 / 不可用 14

bash skills/modern-go/scripts/modern_index.sh --section 391    # 只抽 slices 那一节
```

行号每次运行时从 SKILL.md 现算，**不做硬编码**——在文档里插入内容不会让索引失效。

## 三条设计原则

1. **判据必须是机器可读的。** 不用"评分 85/100"这类自然语言打分——格式一漂移就误判。门禁看退出码，性能看 bench 中位数。
2. **没有度量就不许出性能结论。** 无 benchmark 时性能阶段显式关闭并在报告里写明"结论不成立"。产生假结论比不产生结论危险得多。
3. **每轮只允许一个可证伪的假设。** 一轮里同时重构加修 bug 加调优，事后无法归因，指标变化说明不了任何事。

## 安装

需要 **bash**（macOS/Linux 自带；Windows 用 Git Bash 或 WSL）：

```bash
git clone https://github.com/kalandramo/skillforge.git ~/code/skillforge
bash ~/code/skillforge/install.sh
```

Windows 且只有 PowerShell 时，用等价的原生脚本（推荐，能建 Junction，改动自动同步）：

```powershell
git clone https://github.com/kalandramo/skillforge.git "$env:USERPROFILE\code\skillforge"
& "$env:USERPROFILE\code\skillforge\install.ps1"
```

### 平台差异

| 环境 | 脚本 | 挂载方式 | 仓库改动后 |
|---|---|---|---|
| macOS / Linux | `install.sh` | 符号链接 | 自动生效 |
| Windows + Git Bash | `install.sh` | 符号链接（需开发者模式），失败则复制 | 复制模式下需重跑脚本 |
| Windows + PowerShell | `install.ps1` | 目录联接 Junction（免管理员） | 自动生效 |

两个脚本都挂到 `~/.workbuddy/skills/` 与 `~/.claude/skills/`（存在的那些）。目标已有同名目录但**不带 `.skillforge-origin` 标记**时一律跳过，不覆盖别人的技能。

检查本地安装是否落后于仓库：

```bash
bash install.sh --check
```
```powershell
.\install.ps1 -Check
```

**装完需新开会话**，技能列表在会话启动时加载。

> Windows 上不必强求 Junction：`install.sh` 在无开发者模式时会退化为复制，功能完全正常，只是改完仓库要再跑一次脚本。`install.ps1` 用 Junction 避免这一步。

## 快速开始

在任意 Git 仓库（干净工作树）：

```bash
GATE=~/code/skillforge/skills/go-gate/scripts/gate.sh
LOOP=~/code/skillforge/skills/loop/scripts/loop.sh

bash $LOOP init                      # 生成 .dev/loop.conf，按需改 epsilon / 轮数
bash $GATE --race --bench='^BenchmarkX$' --json   # 基线
# → {"ok":true,"metric":{"name":"ns_per_op","value":49.01},...}
bash $LOOP baseline 49.01

# 改一版代码后
bash $GATE --race --bench='^BenchmarkX$' --json   # → 28.96
bash $LOOP decide 28.96 --goal=perf                # → KEEP
bash $LOOP keep 1 28.96 "改用 strings.Join" perf
bash $LOOP next                                    # → CONTINUE 2
```

完整流程（含审阅与报告）用 `/dev`。脚本层可单独用，适合接进 CI 或自动化任务。

## 目录结构

```
skills/<name>/
├── SKILL.md              协议：何时用、怎么用、反模式
└── scripts/*.sh          执行器：输出 JSON + 退出码，零外部依赖
.dev/                     每个被管理的仓库里的状态目录
├── loop.conf             判定参数（提交到版本控制）
├── results.tsv           每轮记录（gitignore）
├── measure.cksum         基准指纹（gitignore，drift 检测）
├── hooks/after.sh        迭代钩子（可选，提交）
└── REPORT.md             人读报告（gitignore）
```

脚本刻意**不依赖 `jq`**：配置用 shell 变量，直接 `source`。少一个隐式依赖就少一类"装完不报错但行为诡异"的故障。

## 与 goal-workflow 的关系

本仓库的 `dev` 与 `go-gate` 最初在 [smallnest/goal-workflow](https://github.com/smallnest/goal-workflow) 的框架上改造而来，现独立维护：

- 上游的 `review-it` 依赖宿主内置 `/review`、`codex review`，在无这些命令的环境不可用 → 本仓库改为 `dev` 阶段 5 的自包含子代理审阅
- 上游的判定分散在提示词里 → 本仓库抽成 `loop` 脚本，停止条件有确定性输出
- 上游 23 个技能同时启用会让上下文在第一步就吃紧 → 本仓库只收录 Go 后端链路真正用得上的六个，其余留在上游
- `modern-go` 原样搬入会一次吃掉 15k tokens → 本仓库配了 `modern_index.sh` 做版本切片，按需加载单节

`modern-go`、`refactor`、`smell` 原文来自上游，本仓库只对 `modern-go` 增加了索引脚本与开头使用说明，规则内容未改动。

需要其它能力（`prd`、`to-design`、`to-issues` 等）时，把上游加成 remote 按需取用，不整体合并：

```bash
git remote add upstream https://github.com/smallnest/goal-workflow.git
git fetch upstream
git checkout upstream/master -- skills/prd    # 单独取一个，审视后提交
```

## 与 autoresearch / jev-decisions 的关系

`loop` 的账本不变量审计、ASI 记忆（假设/下一步/弃用理由）、基准漂移检测、震荡检测与迭代钩子借鉴了 [karpathy/autoresearch](https://github.com/karpathy/autoresearch) 思路的 zcode 官方 `autoresearch` 插件，按本仓库「零依赖 bash + 退出码判定」原则重写进 `loop.sh`——未引入其 MCP server、宿主 hooks 与 dashboard，护栏智能保留，载体不搬。

`jev-judgment` 改编自 zcode 官方 `jev-decisions` 插件内置技能，原文来自 [`@jkudish/jev-mcp`](https://github.com/jkudish/jev-mcp)（MIT）。宿主绑定（ZCode userConfig）换成了通用 MCP 配置说明，协议内容未改动。它是本仓库唯一依赖外部服务的技能：无脚本、无退出码，定位是"按需读取的判断工具使用协议"，与 dev/loop 的机器可读判据互不替代。

## License

MIT
