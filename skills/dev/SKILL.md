---
name: dev
description: "统一开发入口：一条需求进来，自动完成判据制定、按需设计、切片、实现、Go 门禁、独立子代理审阅、度量判定与收尾，内层循环迭代 N 轮直到验收标准满足或性能指标达标；产物停在分支等人工评审。适用于用户说「dev」「一条龙做完」「端到端实现这个需求」「自动实现并循环 N 次」「把这个接口性能压到 X 以内」。不适用于批量多任务（用 loop-it）与并行任务（用 graph）。"
user-invocable: true
allowed-tools:
  - Bash(git:*)
  - Bash(go:*)
  - Bash(gh:*)
  - Bash(bash:*)
  - Bash(grep:*)
  - Bash(mkdir:*)
  - Read
  - Write
  - Edit
---

# dev — 单一入口的受控开发循环

一条需求进来，一路走到"可评审的分支"。用户不再需要在 `/prd`、`/to-issues`、`/loop-it`、`/review-it`、`/ship-it` 之间手动接力。

## 三个承诺

1. **一个入口，自适应跳过。** 有 PRD 就跳过设计阶段；需求一句话且单文件就跳过切片阶段。不做"每次都走满六步"的形式主义。
2. **一个状态源，两本账各司其职。** `.dev/run.json` 记**流程状态**（走到哪个阶段、验收标准、本轮假设），`.dev/results.tsv` 记**判定账本**（每轮指标与判决，由 `loop` 维护）。恢复时读 `run.json`，引用指标时读 `results.tsv`，两者不互相覆盖。
3. **内层循环，不是批量队列。** 本技能对**同一个需求**迭代 N 轮（实现 → 门禁 → 审阅 → 判定）。批量处理多个任务用 `loop-it`，并行用 `graph`。三者不重叠。

## 与现有技能的关系

**编排层（本技能）** 决定"做什么、做到什么程度"；**能力层** 只被按需调用，不参与流程决策。

```
dev（本技能，内层循环）
  ├─ 阶段0.5 诊断   → smell（仅存量模块改造，每需求最多 1 次）
  ├─ 阶段1 设计     → 按需调用 prd / to-design / prd-to-spec
  ├─ 阶段2 切片     → 按需调用 to-issues（产出直接写入 .dev/tasks/，不强制建 Issue）
  ├─ 阶段3 实现     → modern-go 索引（只读索引，命中再抽单节）
  ├─ 阶段4 门禁     → go-gate（验证与指标的唯一来源）
  ├─ 阶段5 审阅     → 独立子代理读 diff + refactor 手法（仅结构性 blocking）
  ├─ 阶段6 判定     → loop（epsilon 比较、keep/revert、停止条件）
  └─ 阶段7 收尾     → 默认停分支；用户明确要求时才调用 ship-it
```

三者职责严格分离，任何一种都不能替代另一种：`go-gate` 回答"这版对不对"，`loop` 回答"这版要不要留、还继续吗"，`dev` 回答"接下来做什么"。判据与验证分离后，换语言只需替换 `go-gate`，判定逻辑不动。

`review-it` 依赖宿主内置的 `/review`、`codex review` 等命令，在无该命令的环境中不可用。本技能因此内置"自包含审阅"（阶段 5），不调用 `review-it`。

### 上下文预算：能力层必须按需加载

`modern-go` 1139 行、`smell` 750 行、`refactor` 716 行，合计约 35k tokens。**任何一轮循环都不允许全量加载它们**，否则第一轮就会耗尽上下文，后续轮次只能靠猜。

| 技能 | 何时读 | 读多少 | 怎么读 |
|---|---|---|---|
| `modern-go` | 阶段 3，且本轮改动含 `.go` 文件 | 只读索引（30–46 行） | `modern_index.sh --root <repo>`；命中后 `--section <起始行>` 抽那一节（约 30 行） |
| `refactor` | 阶段 5，且审阅提出结构性 blocking | 只读对应手法一节 | `grep -n '^### ' refactor/SKILL.md` 定位，再按行号抽节 |
| `smell` | 阶段 0.5（仅存量改造）；或阶段 7 收尾体检 | 全量，但**每需求最多 1 次** | 一次读完，产出报告后即卸载，不留在后续轮次的上下文中 |

判断标准很简单：**本轮的假设用不到某技能，就不要读它。** 读进来却没用上，等于用上下文预算买了一份没看的说明书。

## 阶段 0：把需求变成判据

在任何编辑之前完成，产出写入 `.dev/run.json` 并向用户复述一次。

```json
{
  "version": 1,
  "requirement": "原始需求原文",
  "carrier": "local",
  "base_branch": "master",
  "branch": "dev/add-lru-cache",
  "rounds_max": 5,
  "rounds_done": 0,
  "phase": "criteria",
  "metric": {
    "name": "ns_per_op",
    "direction": "lower",
    "baseline": null,
    "best": null,
    "target": null,
    "epsilon_pct": 1.0
  },
  "criteria": [
    { "id": "C1", "text": "命中率 ≥ 80%", "verify": "go test -run TestHitRate", "done": false },
    { "id": "C2", "text": "现有测试全绿", "verify": "go test ./...", "done": false }
  ],
  "history": [],
  "updated_at": "2026-11-13T16:00:00+08:00"
}
```

规则：

- **每条验收标准必须绑定一个可执行验证方式。** 写不出 `verify` 的条目退回给用户澄清，不得留空冒充。
- **`rounds_max` 默认 5。** 用户明确指定时以其为准。
- **`metric` 可为空对象**（无 benchmark 的项目）；此时 `metric.baseline` 保持 `null`，全流程不得出现"性能提升"的表述。
- **任务载体自动探测**：`gh auth status` 成功且有 `origin` 远程 → 需求可能来自 GitHub Issue（`gh issue view <N>`）；否则从 `.dev/tasks/*.md` 或用户输入读取。写回 `carrier` 字段。

向用户复述的格式：

```
需求：<一句话>
验收：C1 <...> → <verify>；C2 ...
门禁：go-gate（race=<是/否>, bench=<pattern 或 关闭>）
循环：N=5 轮，指标 <name> 方向 <lower/higher> 基线 <值或"未度量">
出口：dev/<slug> 分支，不推送不合并
```

## 阶段 0.5：存量模块诊断（可选，仅改造类需求）

**触发条件**（须同时满足）：需求是对**已有模块**做改造/重构，且该模块文件数 > 5。

**不触发**：新功能、单文件修改、纯 bug 修复。跑一次 `smell` 要通读模块，代价远高于本轮收益。

触发时调用 `smell`，产出写入 `.dev/smell.md`，只取其中两样：

1. **轮次候选清单**：把报告里的 Critical 与 Immediate Actions 转成"每轮一个假设"的候选，写进 `run.json` 的 `history` 预排。
2. **不可在本需求内修的项**：明确列入阶段 7 报告的"未解决"，避免循环跑到一半才发现方向超出范围。

**约束**：每需求最多诊断 1 次。报告落地文件后即视为已消费，后续轮次**不得重新通读源码复述坏味道**——需要时读 `.dev/smell.md`。

架构坏味道通常不是单轮能消除的，所以本阶段的作用是**定位与排序**，不是"一次性修完"。

## 阶段 1：设计（可跳过）

**跳过条件**（满足任一）：需求已在 PRD/SPEC 中存在；改动预计 ≤ 2 个文件；用户在需求里已给出实现方案。

否则按规模选择：

| 情况 | 调用 |
|---|---|
| 需要产品视角的需求梳理 | `prd` |
| 需要技术方案（架构/API/数据模型/错误处理） | `prd-to-spec` |
| 需要 Go proposal 风格的决策记录 | `to-design` |

产出写入 `tasks/`，并在 `run.json` 中记录路径。**不要**在阶段 1 写业务代码。

## 阶段 2：切片（可跳过）

**跳过条件**：整个需求能在一个上下文窗口内完成，且验收标准 ≤ 5 条。

否则调用 `to-issues`，要求纵向切片（tracer bullet）：每片落地即可演示，而不是"先建表、再写 API、再做界面"。产出写入 `.dev/tasks/<id>.md`，每片带 `verify` 命令。`rounds_max` 分配给各片时，单片至少 1 轮。

## 阶段 3-6：内层循环

对 `round = 1..rounds_max` 重复。**每轮只允许一个可判定的目标**，写在 `run.json` 的 `history[round].goal`。

| 轮次 | 默认目标 | 判据 | 说明 |
|---|---|---|---|
| 1 | `feature` | 全部验收标准达成 | 实现阶段 0 定义的功能 |
| 2..N | `perf` | 指标优于最优 ≥ epsilon | 需 `--bench`，否则不得标记为本目标 |
| 2..N | `coverage` | 覆盖率上升且测试全绿 | 覆盖率的"上升"必须是新增真实断言，不是加 `if true {}` |
| 2..N | `robustness` | 新增的失败用例从红转绿 | 先写能复现问题的测试，再修 |
| 2..N | `refactor` | 测试全绿**且**指标不退化 | 行为不变，只改结构 |

`refactor` 目标的特殊性：它**不产生新能力**，价值在于降低下一轮的修改成本。因此它的判据里没有"改善"要求，只有"不退化 + 测试守住行为"。若 refactor 后指标劣化超过 epsilon，照常 `REVERT`——"结构更好所以要容忍变慢"不成立，两者分开记账。

### 3a. 声明本轮假设

一句话，可证伪：`"热点在 Concat 的字符串拼接，改用 strings.Join 可降 30% 以上"`。写不出单一假设 → 停止循环，说明需求应拆分为多个任务。

### 3b. 实现

- 只改与该假设相关的代码；不改无关代码、不顺手重构、不改测试断言。
- 改动文件数 > 5 时停下来复核假设粒度，通常意味着应该退回阶段 2 切片。

**涉及 `.go` 文件时，先看索引再动手**，不要把 1139 行规则整份读进来：

```bash
bash <plugin_root>/skills/modern-go/scripts/modern_index.sh --root <repo>
# 输出：项目 Go 版本、46 条规则中当前版本可用/不可用的清单（含行号范围），约 40 行
# 命中某条后只抽那一节：
bash <plugin_root>/skills/modern-go/scripts/modern_index.sh --section <起始行>
```

规则：
- **版本门控是硬约束。** 索引里列在"不可用"的规则一律不得使用——那会让代码在项目声明的 Go 版本上编译失败。
- **只应用与本轮假设相关的规则。** 顺手把整个文件现代化会污染 diff，让下一轮无法归因。
- **语义变更类规则只建议不自动应用**：`math/rand/v2`（随机流改变）、`iter.Seq`（API 形状改变）、`os.Root`（错误路径改变）。在报告里列出，由用户决定。
- 若项目无 `go.mod`，索引脚本会返回 rc=2，此时向用户确认目标版本，不要默认按最新版改。

### 4. 门禁

```bash
bash <plugin_root>/skills/go-gate/scripts/gate.sh --root <repo> --json [--race] [--bench='^BenchmarkX$']
```

- `ok=false` → 读 `log_dir/<stage>.log` 尾部，回到 3b 修复。**不得通过修改或删除测试来变绿。**
- 连续 3 轮门禁失败 → 停止循环，报告"方向假设错误"，不要继续换参数重试。
- 阶段 0 声明要做性能优化时，`--bench` 是强制的；否则本轮不得标记为 `perf`。

### 5. 审阅（独立子代理）

派发一个**独立上下文**的子代理，输入仅三样：`git diff <base>...HEAD`、验收标准清单、本轮假设。要求其输出 JSON：

```json
{
  "blocking": [{"file":"x.go","line":42,"issue":"...","why_it_breaks":"..."}],
  "advisory": [{"file":"x.go","line":88,"suggestion":"..."}],
  "clean": false
}
```

主会话必须**逐条验证** `blocking` 是否真实（读对应代码路径），再决定是否修。规则：

- 只接受能指出具体文件与行、且能说明"在什么输入下会错"的发现。
- 拒绝：推测性风险、要求大范围重写、与需求无关的改进建议。
- `blocking` 修完必须重跑门禁（阶段 4），修改后不重跑等于没修。

**区分 blocking 的两种性质**，处置方式完全不同：

| 性质 | 例子 | 处置 |
|---|---|---|
| **缺陷**：当前输入下会出错 | 边界未处理、错误未传播、并发竞争 | 本轮修，重跑门禁 |
| **结构**：现在不错，但改下去会变难 | 函数过长、条件嵌套 5 层、同一逻辑散落三处 | **本轮不修**，登记为下一轮 `refactor` 目标候选 |

把结构问题塞进当前轮修，会同时违反"每轮一个假设"和"只改与该假设相关的代码"两条——事后指标变了无法归因。若结构问题严重到本轮无法在此基础上实现，正确动作是**作废本轮**（不记 keep/revert），退回阶段 2 重新切片。

确需在本轮做结构改进时（即本轮目标本就是 `refactor`），按需抽取 `refactor` 的对应手法，不要整份读：

```bash
grep -n '^### ' <plugin_root>/skills/refactor/SKILL.md    # 定位手法章节（Composing Methods / Simplifying Conditionals …）
# 再按行号抽那一节，约 30-80 行
```

`refactor` 的"行为不变 + 小步 + 测试守门"原则与本循环的判定机制一致：结构改动的正确性由 `go-gate` 的测试结果证明，而不是由审阅者声称"改完更清晰了"。

### 6. 判定与结算

**判定必须由 `loop` 技能给出，不由本会话自行裁定。** 编排层只提供输入：指标值与本轮目标。

```bash
LOOP=<plugin_root>/skills/loop/scripts/loop.sh
V=$(bash $LOOP decide "$METRIC" --goal="$GOAL")   # KEEP | REVERT | INVALID | BASELINE
```

| 门禁 | 审阅 blocking | loop decide 输出 | 动作 |
|---|---|---|---|
| fail | 任意 | 不调用 | 记 `gatefail`，回 3b（不判定） |
| pass | >0 | 不调用 | 未完成，回 3b |
| pass | 0 | `KEEP` | `loop keep <round> <metric> "<假设>" <goal>` |
| pass | 0 | `REVERT` | `loop revert`，并 `loop record <round> revert <metric> PASS <goal> "<假设>"` |
| pass | 0 | `INVALID` | **停止循环**，报告"指标抽取失败"，不得重试同一命令 |

commit message 由 `loop keep` 生成：`dev(round N): <假设> [<metric>=<value>]`。

每次结算后同步写 `run.json` 的 `rounds_done`、`history`、`metric.best`、`updated_at`——它记录**流程走到了哪**，指标账本以 `.dev/results.tsv` 为准，两者不得互相覆盖。

### 停止条件（由脚本判定，不由模型判断）

每轮结算后执行一次：

```bash
bash $LOOP next     # CONTINUE <n> | STOP:target | STOP:no_improve | STOP:gate_failures | STOP:max_rounds
```

收到 `STOP:*` 即进入阶段 7，把停止原因原样写进报告。另有两条脚本无法判断、需人工确认的停止条件：全部 `criteria.done=true`（编排层检查），以及用户中断。

## 阶段 7：收尾

1. 确认工作树干净：`git status --porcelain` 为空（`.dev/` 除外）。
2. **不推送、不合并、不创建 PR**，除非用户明确要求。
3. 生成 `.dev/REPORT.md`：

```markdown
# dev 报告：<需求>

## 验收标准
- [x] C1 <...> — 证据：<命令与输出摘要>
- [ ] C2 <...> — 未完成原因：<...>

## 指标
| 轮次 | 指标 | 相对基线 |
|---:|---:|---:|

## 每轮
| 轮次 | 目标 | 假设 | 门禁 | 判决 | commit |
|---:|---|---|---|---|---|

## 审阅处置
- 采纳 N 条 blocking（已验证），拒绝 M 条（理由）

## 未解决
- <问题 + 建议下一步>
```

4. 向用户交付时按此顺序：验收逐条结果 → 指标表 → 回滚轮次及原因 → 未解决问题 → 下一步建议。

## 失败处理

| 现象 | 处理 |
|---|---|
| 起始工作树不干净 | 停止，请用户 stash 或提交；不得在脏树上开始 |
| 起始门禁就失败 | 先修复到全绿再进入 round 1，作为 `round 0` 记录，不占 `rounds_max` |
| go-gate 返回 rc=2 | 环境问题（无 go / 非 Go 模块），停止并报告 |
| benchmark 抖动导致判定摇摆 | 提高 `BENCH_RUNS` 到 7；不要降低 epsilon 来"稳定"结论 |
| 需求需要改依赖 | 用 `--allow-mod-changes`，并在报告"未解决"中列明新增依赖及理由 |
| 子代理审阅返回空 | 视为 `clean`，但记录"审阅未产出发现"，不要伪造审阅结论 |

## 反模式

- 宣称"性能优化完成"但从未运行 `--bench`。
- 一轮内同时做重构 + 修 bug + 调优，事后无法归因。
- 指标退化仍保留改动（"虽然慢了但更清晰"）——清晰度应作为独立轮次的 `refactor` 目标。
- 用子代理的审阅结论直接替代验证（子代理也会臆断；blocking 必须逐条验真）。
- 循环末尾"抢救"部分被 revert 的代码，导致工作树与 `run.json` 不一致。
- 把 `rounds_max` 设成 20 期待"跑满就好"——收敛靠判据，不靠轮数。
- **每轮开头把 `modern-go` / `refactor` / `smell` 整份读进上下文。** 35k tokens 读进去却只用上一条规则，等于把后续轮次的预算提前烧掉。
- **以 `refactor` 为名夹带行为变更。** 该目标的判据只有"测试全绿 + 指标不退化"，测试覆盖不到的行为改动会静默通过。
- **在 `feature` 轮里顺手执行 `smell` 报告中的架构改造。** 那不是本轮假设的一部分，混进去就无法判断指标变化由谁造成。
- **使用 `modern-go` 索引中标为"不可用"的规则。** 会在项目声明的 Go 版本上直接编译失败，而门禁只会说"编译错了"，不会说"用错了版本"。

## 交付物

```
.dev/
├── run.json          流程状态（阶段、验收标准、每轮假设；可 gitignore）
├── loop.conf         判定参数（epsilon / 轮数上限 / 目标；应提交）
├── results.tsv       判定账本（每轮指标与判决，由 loop 维护）
├── smell.md          存量诊断报告（可选，仅阶段 0.5；后续轮次读它而非重读源码）
├── tasks/<id>.md     切片（可选）
├── gate/<ts>/        每轮门禁日志（由 go-gate 写入）
└── REPORT.md         人读报告
dev/<slug> 分支       N 个（或更少）round commit
```

`run.json` 中的 `metric.epsilon_pct` / `target` / `rounds_max` 是 `loop.conf` 的**镜像**，用于让人在流程状态里一眼看到判据；实际判定一律以 `loop.conf` 为准，改判据只改那一处。
