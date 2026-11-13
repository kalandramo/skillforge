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

```
dev（本技能，内层循环）
  ├─ 阶段1 设计     → 按需调用 prd / to-design / prd-to-spec
  ├─ 阶段2 切片     → 按需调用 to-issues（产出直接写入 .dev/tasks/，不强制建 Issue）
  ├─ 阶段3 实现     → 内联；Go 代码遵循 modern-go 规则
  ├─ 阶段4 门禁     → go-gate（验证与指标的唯一来源）
  ├─ 阶段5 审阅     → 独立子代理读 diff（自包含，不依赖宿主的 /review 命令）
  ├─ 阶段6 判定     → loop（epsilon 比较、keep/revert、停止条件）
  └─ 阶段7 收尾     → 默认停分支；用户明确要求时才调用 ship-it
```

三者职责严格分离，任何一种都不能替代另一种：`go-gate` 回答"这版对不对"，`loop` 回答"这版要不要留、还继续吗"，`dev` 回答"接下来做什么"。判据与验证分离后，换语言只需替换 `go-gate`，判定逻辑不动。

`review-it` 依赖宿主内置的 `/review`、`codex review` 等命令，在无该命令的环境中不可用。本技能因此内置"自包含审阅"（阶段 5），不调用 `review-it`。

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

| 轮次 | 默认目标 | 说明 |
|---|---|---|
| 1 | `feature` | 实现阶段 0 定义的全部验收标准 |
| 2..N | `perf` / `coverage` / `robustness` | 由阶段 0 的指标与缺口决定；每轮只挑一个 |

### 3a. 声明本轮假设

一句话，可证伪：`"热点在 Concat 的字符串拼接，改用 strings.Join 可降 30% 以上"`。写不出单一假设 → 停止循环，说明需求应拆分为多个任务。

### 3b. 实现

- 只改与该假设相关的代码；不改无关代码、不顺手重构、不改测试断言。
- Go 代码遵循 `modern-go` 的版本适配规则（按 `go.mod` 的 Go 版本选择惯用法）。
- 改动文件数 > 5 时停下来复核假设粒度，通常意味着应该退回阶段 2 切片。

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
- 指标退化仍保留改动（"虽然慢了但更清晰"）——清晰度应作为独立轮次的 feature 目标。
- 用子代理的审阅结论直接替代验证（子代理也会臆断；blocking 必须逐条验真）。
- 循环末尾"抢救"部分被 revert 的代码，导致工作树与 `run.json` 不一致。
- 把 `rounds_max` 设成 20 期待"跑满就好"——收敛靠判据，不靠轮数。

## 交付物

```
.dev/
├── run.json          流程状态（阶段、验收标准、每轮假设；可 gitignore）
├── loop.conf         判定参数（epsilon / 轮数上限 / 目标；应提交）
├── results.tsv       判定账本（每轮指标与判决，由 loop 维护）
├── tasks/<id>.md     切片（可选）
├── gate/<ts>/        每轮门禁日志（由 go-gate 写入）
└── REPORT.md         人读报告
dev/<slug> 分支       N 个（或更少）round commit
```

`run.json` 中的 `metric.epsilon_pct` / `target` / `rounds_max` 是 `loop.conf` 的**镜像**，用于让人在流程状态里一眼看到判据；实际判定一律以 `loop.conf` 为准，改判据只改那一处。
