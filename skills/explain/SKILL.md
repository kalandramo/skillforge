---
name: explain
description: "讲解与沟通技能集：用大白话说清楚（bro）、复述用户目标确认理解（in-your-own-words）、代码走查讲解运行机理（how）、追溯代码背后的设计动机与权衡（why）、把工作编织成一份易懂讲解（teach）。适用于「讲清楚这个」「帮我真正理解 X」「这段代码为什么这么写」「改之前先走查一下」。合并自 kalandramo/pstack 的 bro、in-your-own-words、how、why、teach 五个技能（同作者，MIT）。"
user-invocable: true
allowed-tools:
  - Read
  - Bash(git:*)
  - Bash(gh:*)
  - Agent
---

# Explain — 讲解与沟通

五个相互协作的讲解技能。简单问题直接动手，复杂问题按下面的剧本派子代理深挖。

- **§1 Bro** — 把上一条消息用大白话说一遍。
- **§2 In Your Own Words** — 复述你认为用户的目标，确认理解一致再动手。
- **§3 How** — 讲解代码怎么运作（架构 / 运行时流程 / 心智模型）。
- **§4 Why** — 追溯代码背后的动机与权衡（并行查证据源）。
- **§5 Teach** — 把 how + why 的产出编织成一份统一讲解。

---

## §1 Bro — 大白话说清楚

把上一条消息用大白话重述一遍。去掉术语和黑话，像一个人跟另一个人聊天那样简洁明了。陈述得更简单、更直接。

---

## §2 In Your Own Words — 复述目标

用你自己的话复述你认为用户的目标是什么、想解决什么问题，确认理解一致后再动手。

---

## §3 How — 代码走查讲解

探索代码库回答 "how does X work?"。产出 senior 工程师上手一个子系统时的架构讲解——足够建立可用的心智模型，又不至于读起来像带注释的源码。

每个派出的 explorer / explainer 都是一个子代理（Cursor 用 `Task`、Claude Code 用 `Agent`、OpenCode 用 `task`、Codex 用 `spawn_agent`）。explorer 用 `readonly: true`，explainer 默认 `grok-4.7-xhigh-fast` / `claude-opus-5-5-xhigh`（取你宿主模型配置里的对应行，缺省则用默认）。每个子代理的推理档位与快慢按任务自定。若你的子代理工具拒绝某个 slug，用默认并说明；默认也被拒，就用它报错信息里同族最接近的合法 slug。若宿主没有子代理工具，就自己依次跑每个角色。

### 1. 评估复杂度

若范围模糊，先陈述你的理解再探索，用户可纠正。

- **简单**（单个模块、小工具、窄问题如 "how does function X work"）：不派 explorer，直接派一个 explainer 一步到位（基于 `references/explainer-prompt.md`，省略 explorer-findings 段）。跳到步骤 4。
- **复杂**（跨多文件 / 服务的子系统、横切特性、完整架构总览）：进入步骤 2。

拿不准就走简单路径。

### 2. 探索（仅复杂）

把问题拆成 2–4 个角度，每个是子系统的一个切片。一条消息里并发派出所有 explorer，各带 `references/explorer-prompt.md` 并填好角度。

### 3. 综合（仅复杂）

所有 explorer 返回后，派一个 explainer，带 `references/explainer-prompt.md` 与每个 explorer 的发现。

### 4. 呈现

呈现 explainer 的输出。为清晰或补上下文做轻微编辑，不要大幅重写。

### 输出格式

讲解使用 `references/explainer-prompt.md` 里定义的段落：Overview、Key Concepts、How It Works、Where Things Live、Gotchas，不适用的段可省。

---

## §4 Why — 追溯设计动机

调查代码背后的动机与意图。配套技能 **How（§3）** 回答代码做什么、怎么运作；**Why** 回答什么力量塑造了它的形态。

每个派出的 investigator / synthesizer 都是 `generalPurpose` 子代理（`readonly: false`，agent 模式）。**不要用 readonly / Ask 模式**——它会剥掉 MCP 访问，使 MCP 支撑的 investigator 与 synthesizer 的引用核查失效。investigator 仍不应写出任何东西。

每个子代理的模型取你宿主模型配置里的对应行（如 `~/.cursor/rules/pstack-models.mdc` in Cursor、`~/.claude/rules/pstack-models.md` in Claude Code、`~/.agents/pstack-models.md` in other harnesses），缺省则用默认；值为 `auto` 或 `inherit-parent` 时把 `model` 留空。若工具拒绝某 slug，用默认并说明。

### 操作姿态

做一个**谨慎、精确的调查者**。诚实区分已知与推断。读 `references/epistemics.md` 获取完整置信框架与措辞指南，synthesizer 必须遵守。

### 步骤 1. 理解目标与问题

**目标**通常是某段代码、某模式、某特性，或某个具名的设计决策。**问题**通常是设计理由、权衡、催生它的边界情形、外部约束、死代码，或一段广泛的历史梳理。

目标模糊时（"why do we do it this way?" 无明确指称），从对话上下文（打开的文件、近期编辑、光标位置、刚讨论的内容）做最佳猜测，简短陈述以便用户纠正，然后继续。

### 步骤 2. 建立代码锚点

派 investigator 前，先内联建好种子上下文：文件路径与行范围、关键符号（函数、类、常量）、触碰目标的最后几次提交、merge commit 里的 PR 号（subject 里的 `(#1234)` 模式）、任何关联 ticket id。跑：

- `git blame -L <start>,<end> <file>` 取最后触碰的提交
- `git log --follow -p -- <file>` 取穿越重命名的完整历史含 patch
- `git log --oneline -20 -- <file>` 取近期含 PR 号的提交
- `git log -1 --format=%B <commit>` 抽取 PR 号

再拉取任何实质提交对应的 PR 正文与讨论：`gh pr view <number> --json title,body,author,createdAt,mergedAt,labels,closingIssuesReferences,comments,reviews`。这个锚点送往每个 investigator 与 synthesizer。

### 步骤 3. 并发派 investigator

**默认走完整并发调查**，目标是完整覆盖图而非最小覆盖。证伪也要记录，不跳过搜索。

**发现**：派 investigator 前，列出宿主连上的 MCP 服务器（Claude Code 里工具名通常形如 `mcp__<server>__<tool>`）。把每个可用 MCP 映射到一类证据：

1. 源码历史（source control）
2. 问题 / ticket 追踪
3. 长文文档
4. 实时团队聊天
5. 基础设施可观测性
6. 错误 / 异常追踪
7. 产品分析数仓

源码历史永远通过 git 与 `gh` 可用。其余六类按 MCP 名、服务器说明、工具名、资源描述归类；一个 MCP 能归多类时取其主要证据类。模棱两可的记进覆盖图。

每类有匹配 MCP 就派一个 investigator，全部在一条消息里并发，每个独占一个工具 / MCP。不要令一个 agent 覆盖多个 MCP。`model`：取你宿主配置里的对应行，默认 `grok-4.7-xhigh-fast`。

每个 investigator 的 prompt 是 `references/investigator-prompt.md` 填好，外加：

- 该类剧本 `references/sources/<source>.md`（从 `references/source-playbook.md` 的示例改造）
- 若目标代码**看起来防御性**（null check、retry、timeout、rate limit、feature flag、出向守卫、OOM handler），加 `references/sources/incident-postmortem.md`
- 代码锚点与用户原问题

**investigator 名单（每类一个，按可用证据类派）**：

1. **Source control**（git 历史、`gh` 查 PR、代码注释、测试）。总是派，唯一 guaranteed 来源。最强：*review 时捕获的实现期理由*。
2. **Issue / ticket tracker**（Linear、Jira、GitHub Issues、Plane、Shortcut 等）。最强：*产品或商业的 forcing function*，当 why 来自工程之外时最强。
3. **Long-form documents**（Notion、Confluence、Google Docs、Coda 等）。最强：*写于成码之前的长期设计理由*。
4. **Real-time team chat**（Slack、Discord、Teams、Mattermost 等）。最强：*从未进文档的实时 deliberation*，当源码 / ticket / 文档线索稀薄时尤其重要。
5. **Infrastructure observability**（Datadog、New Relic、Honeycomb、Grafana、Splunk 等）。最强：*催生代码的基础设施与运行时现实*，目标对某个 infra 信号起反应时（timeout、retry、rate limit、circuit breaker）最强。
6. **Error / exception tracking**（Sentry、Rollbar、Bugsnag、Airbrake 等）。最强：*催生防御性或纠正性代码的特定异常与错误轨迹*，catch、null guard、type check、retry 及其它防御代码最强。
7. **Product analytics warehouse**（Databricks、Snowflake、BigQuery、ClickHouse、dbt、Redshift 等）。最强：*塑造代码的产品与数据现实*，flag-gated 代码、实验驱动 ship、数据迁移、"这个数字哪来的" 类问题最强。

**何时跳过某 investigator**：仅当有**显式书面理由**写进最终 Sources Consulted。两条有效理由：

- 本环境无该类的可用 MCP。标记为缺口而非选择："Real-time team chat skipped. No matching MCP available, so the conversational record was not searchable."
- 来源被证伪为无关，而非"可能无关"。高门槛："Error / exception tracking skipped. Target is a build-time script with no runtime code path."

若范围评估表明目标是单次提交、PR 描述已含完整答案，你可**仅在确认全部七类可用搜索都会冗余后**内联回答，并显式说明。应属罕见。

### 步骤 4. 综合

派一个 synthesizer（`model` 取对应行，默认 `claude-opus-5-5-xhigh`），给它：

1. investigator 的发现（含 null 结果与带理由跳过的类）
2. 代码锚点
3. 用户原问题
4. `references/epistemics.md` 的置信框架
5. `references/synthesizer-prompt.md` 的模板

### 步骤 5. 呈现

呈现 synthesizer 的输出。可为清晰轻改或补上下文，但**不要重写置信语言**。

### 输出格式

结构见 `references/synthesizer-prompt.md`：The Question、The Code in Question、What We Found、What We Can Reasonably Infer、Competing Hypotheses、What We Don't Know、Sources Consulted、Confidence Summary。按需调整，但保留置信分层，且 Sources Consulted 每行一个 investigator（含返回空与被跳过的，附理由）。

Sources Consulted 之后，若用户的 why 问题是要改这段代码的前奏，把 lineage 发现转成 Preserve / Change / Avoid / Risk 约束集，用于规划改动。

### 常见失败模式

- **近因偏差**。假定最近一次提交就是权威。当前形态常是许多更早决策的积淀，往回追。

---

## §5 Teach — 讲解传授

你解释一个东西是什么、怎么运作、为什么这么造，用一份符合对方节奏的大白话。目标是让他**理解**，不是改任何东西。

Teach 架在 **How（§3）** 与 **Why（§4）** 之上。先弄清这项工作是什么、碰什么，再跑 How 看它怎么运作、Why 看为什么这样。这些是真实的技能调用，各自深挖。把发现编织成一份平实讲解，从对方在意处入手，他追问时再深入。为教学可自由改写，唯独一处例外：保留 **Why** 的置信语言（它的 hedging 是发现，不是风格）。

1. **定下他该带走的那几件事。** 从"他为什么问"（要改它 / 在审它 / 在 debug / 刚接触）和他已知什么（都从对话读，别考他）里选。跳过他显然已知的。深度放在他问题的地方。
2. **让 How 和 Why 干活，别重做。** 自己读代码找方向，再跑 How 看运作、Why 看理由。并行跑、合并结果。按问题定规模：子系统两个都跑，小改动可能一个就够。Why 默认收窄（它的全扫描很慢），把收窄写进 ask 本身（一个 scope 问题、git 加一两个源）让 Why 按自己的契约记录跳过的类，只在理由本身就是重点时放宽。
3. **用平实定义开头。** 点名这个东西、用 general terms 说它是什么（像 senior 工程师念出声那样），有俗称就用俗称。再系到眼前的案例（"in X, we use this to …"）由此建起：怎么运作、更深的理由、边界情形。每部分解释到"咔嗒"一下懂了：它解决什么问题、实际怎么运作。当对方做某件事（开长聊天、往上滚）能让它落地时，就走那条。列函数和常量是 reference，不是 teaching。别打印框架标签（"the one idea to hold onto"、"the key insight"、"TL;DR"）。先给最小完整答案（一两句，不是稠密段落），然后停。他追问时再加层。绝不当墙 of text。
4. **保持对话，不是 lecture 或表演。** 主动提出深入或换话题，跟他的节奏。不考。不 pacing 表演。别打印 "Pause"、别让他复述、别宣布 "the sentence to nail"、别把某部分标重要或难（"here is the part worth slowing down on"）。就说。该停时停，让他回应。无真人实时跑时，干净交付，把"可深入"的邀请放最后。
5. **Show, don't only tell，一张一张图搭起来。** 开 diff、代码或 debugger 当最快落地时用。要画图当图比字快时用图。任何三个及以上活动部件，别一次画全，画一系列：每张重画上一张并加一个部件，让读者看系统组装。给最终一张全图是 reference 不是 teaching。具体说，教 A→B→C 的流程，画三次：先 A→B，再重画加 C，再重画加回边或下一块。媒介配想法，两类都帮忙时用两类。flow 或 structure 且标签承载语义用 mermaid。想法是空间的（layout、overlap、scroll 位置、before/after）用图像生成工具画白板 marker 风、少量短标签（图像模型会搞乱长文本）。构建规则对生成图同样有效。一个简单点不需要图。

经 **§2（Unslop）** 的规矩写每个回复：平实口语、像对同事解释。紧不 ters。砍 filler 与 hedging，留"咔嗒"那一下。说具体机制，不隐喻、不框架、不预告。目标密度："Virtualization runs in two parts, one for rendering and one for loading from disk. When an item scrolls out past the buffer, both its DOM node and its in-memory data are evicted." sentence case，不全小写。无 em dash。句号优于逗号。每句一到两个逗号。clause 堆起就拆成独立句。每个概念一个名字守住。避 mirror sentence（"A without B, or B without A"）与 tidy closer（"the rest follows"、"it all falls out"）。这些步骤里的词是对你的指示，不是要打印的标签。别把结构当 header 或套话回声。

**回复**：讲解本身，绝不是关于你做了 / 交付了什么的报告。先抛重点，再平实讲它是什么、怎么运作、为什么，以及值得用 How / Why 追的线头。
