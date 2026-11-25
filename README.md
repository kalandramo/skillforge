# skillforge

给 AI 编码助手装的一套工作方法。主力场景是 Go 后端。带语言绑定的只有四个：`go-gate`、`modern-go` 管 Go，`ts-gate`、`typescript` 管 TS/JS；其余技能与技术栈无关。

装好之后**你不需要记命令，也不用背技能名**——正常说人话就行，助手会自己挑该用哪个。判定类技能（`go-gate`、`ts-gate`、`loop`）都配有能返回退出码的脚本，所以"做完没做完"由程序判定，不由模型自己声称；`writing`、`explain` 这类产出型技能没有退出码，判据是人。

- 第一次用 → [三分钟上手](#三分钟上手)
- 不知道该怎么说 → [常用台词速查](#常用台词速查)
- 装不上 / 不生效 → [常见困惑](#常见困惑)
- 22 个技能分别干什么 → [技能速查](#技能速查)

## 三分钟上手

下面以 WorkBuddy 为例。ZCode、Qoder 用法完全一样，只是技能目录不同，见[安装](#安装)。

### 第 1 步：挂载技能

```bash
git clone https://github.com/kalandramo/skillforge.git ~/code/skillforge
bash ~/code/skillforge/install.sh
```

脚本会自己找到你机器上装了的客户端（WorkBuddy / ZCode / Qoder），把 22 个技能链接进它们的技能目录。输出里出现 22 行 `[link]`（Windows 上是 `[junction]`）就是成功，不需要你做别的。若有个别技能被标成 `[skip]`，说明那个名字你已经装了别的东西，脚本不肯覆盖——先看[常见困惑](#常见困惑)。

Windows 且只有 PowerShell 的话，第二条命令换成 `& "$env:USERPROFILE\code\skillforge\install.ps1"`，其余不变，细节见[安装](#安装)。

### 第 2 步：新开一个会话

技能列表**只在会话启动时读一次**。装完不重开，助手看不见它们——这是最常见的"装了没反应"。

### 第 3 步：确认助手看得见

在新会话里问一句：

> 你现在有哪些技能？

应该能看到 `dev`、`go-gate`、`loop` 这些名字。看不到就跳去看[常见困惑](#常见困惑)。

### 第 4 步：说第一句人话

随便进一个 Go 仓库，在会话里说：

> 帮我实现一个按 ID 查用户的接口，要有测试

助手会自动加载 `dev`，然后一路做下去：问清验收标准 → 看现有代码 → 切小步 → 写实现 → 跑 `go-gate` 门禁 → 派子代理独立审阅 → 告诉你结论。全程你不用打任何命令。

这就是它的正常形态：**你说需求，它走流程，判定交给脚本。**

实际过程大致是这个节奏（措辞每次都会变，骨架不变）：

> **你**：帮我实现一个按 ID 查用户的接口，要有测试
> **助手**：先确认验收标准——查不到时返回 404 还是空结果？性能有要求吗？
> **你**：404，性能没要求
> **助手**：（列出入手点、要改的文件、怎么验证）按这个顺序做，可以吗？
> **你**：可以
> **助手**：做完了。门禁通过（退出码 0），审阅意见和每条的处置都列在下面。

你在中间只需要做两件事：**回答它一次澄清**、**点头一次开工**。

## 三种用法，按省事程度排

| 方式 | 你怎么做 | 什么时候用 |
|---|---|---|
| **说人话** | 直接把要做的事说出来，话里带上触发词 | 日常首选，九成场景 |
| **点名** | 输入 `/` 从列表里挑，或直接说「用 dev 做这个」 | 助手挑错了技能；或你很清楚要走哪套流程，想跳过判断 |
| **不经过对话** | 终端里直接跑脚本，如 `bash ~/code/skillforge/skills/go-gate/scripts/gate.sh` | CI、定时任务，或只想看门禁结果不想聊天（见[直接在终端跑脚本](#直接在终端跑脚本)） |

点名时写的是斜杠加技能名：`/dev`、`/go-gate`、`/explain`……22 个都支持。

## 常用台词速查

不知道该怎么开口时，查这张表。左列是你的目的，中列是能触发的话（换成你自己的说法也行，关键是那个词），右列是会被加载的技能。

| 我想… | 这么说 | 用到 |
|---|---|---|
| 从头做完一个需求 | 端到端实现这个需求 / 做个功能 / 一条龙做完 | `dev` |
| 只生成设计文档，不写代码 | 只做设计 / 出个设计文档就停 / 写设计文档 / 生成 spec | `dev`（`stop_after=design`，见[只生成设计文档](#只生成设计文档)） |
| 跑完核对设计与实现是否一致 | 同步设计文档 / 文档和代码对一下 | `dev`（完整收尾强制执行，见[收尾的文档同步](#收尾的文档同步)） |
| 第二次优化后回写第一次的功能文档 | 优化这个性能并同步原设计文档 / 更新之前的文档 | `dev`（需求里指定 `doc_path`，见[收尾的文档同步](#收尾的文档同步)） |
| 跑完顺手沉淀踩坑经验 | 这条坑记到 AGENTS.md / 跑完顺手记一下 | `dev`（完整收尾强制执行，见[收尾的经验沉淀](#收尾的经验沉淀)） |
| 只跑质量检查 | 跑门禁 / 验证这个 Go 改动 / Go 质量检查 | `go-gate` |
| 跑 TS 的门禁 | 跑 TS 门禁 / TypeScript 类型检查 / 前端质量检查 | `ts-gate` |
| 确认性能有没有变差 | 性能有没有变差 / bench 对比 | `go-gate`（`loop` 记账） |
| 决定这版要不要留 | 这版要不要回滚 / 循环什么时候该停 | `loop` |
| 先看看代码有什么毛病 | 闻一下这代码 / 有什么坏味道 / 架构哪里不对 | `smell` |
| 只审不改 | 对抗审查一下 / 挑挑这改动的毛病 / 找找漏洞 | `interrogate` |
| 整理烂代码但不改行为 | 重构一下 / 这段代码太乱 / 提取个方法 | `refactor` |
| 换成更现代的 Go 写法 | 现代化这段 Go / 更地道的写法 / modernize | `modern-go` |
| 弄懂一段代码 | 这段代码怎么跑的 / 讲清楚这个 / 为什么这么写 | `explain` |
| 写文档或提交信息 | 写 README / 写 PR 描述 / 写提交信息 / 去 AI 味 | `writing` |
| 定设计方向 / 判断这版好不好 | 这个设计好不好 / 配色 / 帮我改稿 / 设计方向怎么定 | `writing`（§4） |
| 照截图复刻一个界面 / 验收 | 照这个截图复刻 / 按参考图做一版 / 界面验收 | `writing`（§4） |
| 几个方案挑一个 | 多做几版比比 / 几个方案挑一个 / 并行试几种做法 | `arena` |
| 分头并行地查 | 分头查 / 并行覆盖一下 / 多切片扫一遍 | `swarm` |
| 事后复盘沉淀 | 复盘一下 / 总结经验 / 沉淀成技能 | `reflect` |
| 画状态图 / 形式化验证 | 画状态图 / 这个流程有哪些状态 / TLA+ | `statechart` |
| 留一份能审的决策记录 | 留个决策日志 / 记一下决策 / 我事后要能审 | `show-me-your-work` |
| 把任务想得更深 | 这任务怎么做得更深 / 重写我的提示词 / 专家会怎么做 | `sharpen` |
| 把我的习惯变成技能 | 把我习惯固化下来 / 做个我的工作模式 | `automate-me` |
| 没有现成流程可套 | 自己编排一下 / 你看着办但要能查 | `figure-it-out` |
| 不知道用哪个，让它自己挑 | poteto / 用这个风格工作 | `poteto-mode` |
| 核实一条结论 | 用 jev 判断 / 核实这条结论 | `jev-judgment`（需先配 MCP） |

## 只生成设计文档

`dev` 默认一条龙跑到实现，但只要你在需求里声明"只做设计"，它会在设计阶段产出文档后停下，不进入实现。

**怎么说**（任选一句）：

- `只做设计，帮我给 XXX 功能出一份设计文档`
- `出个设计文档就停，不要写代码`
- `设计加切片先别实现`（这样会连纵向切片一起产出，再停）

**它会做什么**：

1. **先提问**：按复杂度问 2–8 个选择题（可"1A, 2C"速答），把需求问清楚才动笔。你说"你定"可跳过，但所有自行做的假设会记进文档的"待解问题"。涉及破坏性变更的方向必须你点头。
2. **写一份文档**：`tasks/<id>-design.md`，一个功能一份，开头是**术语表**（中文 / 英文缩写 / 英文全称三列，覆盖产品技术缩写、领域业务术语、项目工作流术语），正文内含三部分——**产品需求**（做什么）、**设计取舍**（为什么选这条，必含一个被弃方案及原因）、**实现契约**（怎么建，简单功能几段带过，复杂功能给到 API/SQL/测试用例映射的字段级精度）。英文专有名词首次出现必带中文译文，格式为"中文（English 缩写, English 全称）"，如"产品需求文档（PRD, Product Requirements Document）"；后文可直接用缩写，随时回查术语表。简版文档只要有专有名词也要建术语表。
3. **等你确认**：文档写完会呈现给你。配 `只做设计` 时确认的是文档写得对不对，确认后直接停在收尾；未配置停止时，说"继续"才放行进入实现。你说"你定"可跳过确认，但所有自行做的假设会记进"待解问题"。

**文档放哪、要不要提交**：`tasks/` 在仓库根目录下，不在 `.dev/` 里，所以**天然被 git 跟踪**，团队能看到、能 review。不要搬到 `docs/`——那是稳定发布物的位置，设计文档会随实现反复修订。需要归档时由你决定，且是移动不是复制，避免两份副本漂移。

**恢复实现**：确认设计文档后，再发一句"按这份设计继续实现"，`dev` 会从设计的下一阶段接着走，阶段 0 定的验收标准保持有效。

## 收尾的文档同步

完整跑完 `dev` 后，阶段 7 会**强制对照设计文档与实际实现**，不需要你提醒，也不会静默跳过。

- 核对 `tasks/<id>-design.md` 第三部分（实现契约）：API、数据模型、错误码、字段、测试映射等，逐条比对设计值与实际值。
- 偏差清单写进 `.dev/REPORT.md`，一次性问你"是否回写？"——事实性修正建议回写，方向性变更（架构、被弃方案、新增模块）必须你明确确认；你说"你定"时**默认不回写**。
- 确认后只改偏差涉及的条目，**不重写全文**，并在文末追加同步记录；不自动提交、不推送。
- 偏差数为 0 也要在报告里写明；无对账文档（本次未产出、也未指定）时写"无设计文档可核对"，不省略章节。

**第二次 dev 回写第一次的功能文档**：每次 `dev` 都会重写自己的 `.dev/run.json`，所以第一次记下的 `doc_path` **不会自动继承**。第二次做性能优化且没重跑阶段 1 时，在需求里写明要同步哪份文档即可，例如：`优化这个功能的性能，同步 tasks/rate-limiter-design.md`。`dev` 会校验路径、列出偏差清单，仍经你确认后才回写；只改本次触及的条目，不把历史欠账一起补进去。若只说"同步文档"未指定路径，`dev` 会列出 `tasks/*.md` 让你选，不自行推断。

## 收尾的经验沉淀

同样是阶段 7 的**强制步骤**。先扫描六类证据源（回滚账本、门禁失败日志、停止原因、被拒的审阅发现、待解问题变更、环境工具异常），逐项写结论——**只写"无"视为未执行**。

- 候选写进 `.dev/REPORT.md` 的"经验候选"表（现象 / 根因 / 规避动作 / 适用范围 / 归属），一次性问你"是否写入项目 `AGENTS.md`？"，答复记入表里。
- 只写项目特有的**规则化条目**（"约束——一句理由"），不写"某天遇到…"的流水账；写入前语义去重，不自动提交。
- 归属为"skill 改进"的坑不写进 AGENTS.md，只在报告里提示改对应 skill；"一次性偶发"的坑标注后不落盘。
- 你说"你定"或否决时**默认不写入**，候选仍留在报告里供事后决定。
- 只做设计（`stop_after=design`）或设计加切片时跳过本节——没跑实现与门禁，没有真实踩坑可提炼。
- 需要系统性复盘或产出新技能时用 `reflect`；这里不展开多角色评审。

## 第一次用，按这个顺序

不要一上来就用 `dev`（它会跑很久）或 `poteto-mode`、`swarm`（会一次拉起好几个子代理，又慢又吵）。建议：

1. **`explain`** —— 零风险，随便挑一段代码说「这段代码怎么跑的」，先感受一下"技能被加载"是什么样。
2. **`go-gate`** —— 一句话，几秒出结果，看退出码和 JSON 报告（TS 项目换成 `ts-gate`）。
3. **`dev`** —— 有了前两步的体感，再让它跑完整流程。

## 常见困惑

**安装时某个技能显示 `[skip]`？**
那个名字下已经有别的东西（通常是早先装过的旧版技能），脚本默认不覆盖别人的东西。确认它确实该被替换后，把旧目录改名再重跑：`mv ~/.workbuddy/skills/interrogate ~/.workbuddy/skills/interrogate.bak`，然后重跑一次 `install.sh`。升级场景更省事的做法是在仓库目录下跑 `bash install.sh --prune`，它会按 `retired.txt` 把已废弃的旧技能挪进备份目录。

**说了话但助手没加载对应技能？**
两种可能：一是没重开会话（技能列表在启动时才读）；二是那句话里没有触发词——触发靠模型判断，不是硬字符串匹配。直接点名最快：说「用 dev 做这个」，或输入 `/` 从列表里挑。

**感觉它读了很多东西、变慢了？**
技能文档加起来几千行，但设计上**从不整份加载**：`dev` 按阶段只读当下需要的部分，`modern-go` 用一个索引脚本按 Go 版本切片，只抽命中的那一节。如果还是嫌慢，改用单点技能（`go-gate`、`explain`）替掉 `dev`。

**我不写 Go，能用吗？**
能。带语言绑定的只有 `go-gate`、`modern-go`（Go）和 `ts-gate`、`typescript`（TS/JS），其余都是通用技能，不写 Go 自然也不会触发到那四个。`dev` 里把"门禁"换成你语言对应的检查即可——流程、记账、判定逻辑都不用动。

**`jev-judgment` 一直说不可用？**
它是唯一依赖外部服务的技能：需要宿主配置 jev MCP 服务和 `TYPESAFE_API_KEY`。没配就跳过，其余 20 个技能不受影响。

**怎么卸载或回退？**
链接模式直接删对应目录即可，比如 `rm ~/.workbuddy/skills/dev`——删的是链接，仓库里的东西不受影响。`--prune` 清理掉的旧副本都留在 `~/.skillforge-backup/`，原样搬回去就能恢复。

**Windows 上怎么装？**
用 `install.ps1`（建目录联接，不需要管理员权限），或在 Git Bash 里跑 `install.sh`。细节见[安装](#安装)。

## 技能速查

这张表是查手册用的，**用起来不需要背**。技能分两层：

**流程层** 决定做什么、做到什么程度，四个脚本各有唯一职责：

| 技能 | 一句话 | 判据来源 |
|---|---|---|
| [`dev`](skills/dev/SKILL.md) | 一条需求进来，走完判据→诊断→设计→切片→实现→门禁→审阅→判定→收尾（强制核对文档同步、按需沉淀踩坑到 AGENTS.md），内层循环 N 轮 | 调用下面三个 |
| [`go-gate`](skills/go-gate/SKILL.md) | Go 门禁：`mod_guard`/`build`/`vet`/`test`/`race`/`lint`/`bench` | 进程退出码 + bench 中位数 |
| [`ts-gate`](skills/ts-gate/SKILL.md) | TS/JS 门禁：`dep_guard`/`typecheck`/`lint`（只查改动）/`test`，可选 `build`/`bench` | 进程退出码 |
| [`loop`](skills/loop/SKILL.md) | 记账、epsilon 比较、keep/revert、账本不变量审计、基准漂移检测、确定性停止条件（含震荡检测） | 指标数值 + 账本不变量 |

四者职责不能互相替代：`go-gate` / `ts-gate` 答"这版对不对"（按改动语言择一，不要两个都跑），`loop` 答"这版要不要留、还继续吗"，`dev` 答"接下来做什么"。**加一门语言只需照同一份 JSON + 退出码契约再写一个门禁脚本，判定逻辑不动。**

**能力层** 只被按需调用，不参与流程决策：

| 技能 | 行数 | 用在 | 加载方式 |
|---|---:|---|---|
| [`modern-go`](skills/modern-go/SKILL.md) | 1162 | `dev` 阶段 3，改动含 `.go` 时 | **索引脚本**：先取 30–46 行清单，命中后再抽单节 |
| [`refactor`](skills/refactor/SKILL.md) | 716 | `dev` 阶段 5，结构性 blocking 或 `refactor` 轮次 | `grep '^### '` 定位手法，抽一节 |
| [`smell`](skills/smell/SKILL.md) | 750 | `dev` 阶段 0.5（仅存量改造），每需求最多 1 次 | 全量读一次，报告落地后即卸载 |
| [`jev-judgment`](skills/jev-judgment/SKILL.md) | 见文件 | 按需：筛查不可信文本、对照证据核实、语义选优/分类、完成门禁 | 全量读；**需宿主配置 jev MCP + TypeSafe API key**，未配置时不可用 |
| [`principles`](skills/principles/SKILL.md) | ~100 | dev/loop/go-gate/refactor/writing 在相应阶段引用 | 按需读（参考型，非单独触发）；由 pstack 的 24 条 principle-* 合并而来，另新增 2 条 |
| [`figure-it-out`](skills/figure-it-out/SKILL.md) | ~90 | 无更窄剧本时的通用兜底编排（/figure-it-out） | 全量读；改编并合并自 pstack 的 figure-it-out |
| [`writing`](skills/writing/SKILL.md) | ~345 | 写 / 审文档、PR 描述、提交信息；润色去 AI 味；前端 UI 收尾闸门；设计方向判断、照稿复刻、界面验收（§4） | 全量读；由 pstack 的 technical-writing + unslop + impeccable 合并而来，另加设计判断一节（源自 Duoasa-skill 与 DSH-to-Figma） |
| [`explain`](skills/explain/SKILL.md) | ~200 | 讲解 / 走查代码（how）、追溯设计动机（why）、大白话传授（teach）、复述目标 | 全量读；由 pstack 的 bro + in-your-own-words + how + why + teach 合并而来 |
| [`statechart`](skills/statechart/SKILL.md) | 见文件 + scripts/ | 用 TLA+ 画状态图并对运行结果做形式化检查 / 可视化 | 全量读；自带 TypeScript 工程（scripts/），需 Node |
| [`automate-me`](skills/automate-me/SKILL.md) | 见文件 | 把用户工作习惯提炼成专属 -mode 技能 | 全量读；改编并合并自 pstack 的 automate-me |
| [`typescript`](skills/typescript/SKILL.md) | 见文件 | 读 / 改 `.ts`/`.tsx` 时的类型纪律；已接入 `dev` 阶段 3 | 全量读；改编自 pstack 的 typescript-best-practices |
| [`arena`](skills/arena/SKILL.md) | 见文件 | 就同一任务并行派 N 个候选，选基版并嫁接落败者最强部分 | 全量读；改编并合并自 pstack 的 arena |
| [`swarm`](skills/swarm/SKILL.md) | 见文件 | 并行多切片扇出覆盖（覆盖矩阵 / 竞速 / 夹击 / 探索分区） | 全量读；改编并合并自 pstack 的 swarm |
| [`sharpen`](skills/sharpen/SKILL.md) | 见文件 | 把任务做深而非做大，再重写提示词 | 全量读；改编自 pstack 的 sharpen |
| [`interrogate`](skills/interrogate/SKILL.md) | 见文件 | 多模型对抗审查改动 / 设计，只报告发现不自行改 | 全量读；改编自 pstack 的 interrogate |
| [`reflect`](skills/reflect/SKILL.md) | 见文件 | 把长任务经验沉淀成新技能 / 可复用教训，多评审角色协同 | 全量读；改编自 pstack 的 reflect |
| [`show-me-your-work`](skills/show-me-your-work/SKILL.md) | 见文件 | 长任务 / 无人值守决策留痕（TSV：what/why/evidence/result） | 全量读；改编自 pstack 的 show-me-your-work |
| [`poteto-mode`](skills/poteto-mode/SKILL.md) | 见文件 + scripts/ | 总路由元技能：按任务类型自动选剧本并编排子代理；agent 风格与触发规范 | 全量读；改编自 pstack 的 poteto-mode，自带 TypeScript 工程（scripts/）与 24 个 playbook |

前三者合计约 2600 行 / 35k tokens。**任何一轮循环都不整份加载**——读进去却只用上一条规则，等于把后续轮次的上下文预算提前烧掉。这是 `dev` 里"上下文预算"一节的来源。`jev-judgment` 是例外：它没有规则库，只有一份使用协议，且依赖外部服务（宿主未配置 jev MCP 时整体不触发）。`writing` / `explain` / `statechart` / `automate-me` / `typescript` 为沟通与写作类技能；`arena` / `swarm` / `interrogate` / `reflect` / `show-me-your-work` / `sharpen` 为并行探索与评审类技能。二者均不参与 `dev` 内层循环，按用户显式触发或 `dev` 阶段 3 的 TS 分支加载。`poteto-mode` 是元路由：按任务自动选剧本并编排上述技能，自身不干活。

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

以下三节（设计原则、描述即触发条件、modern-go 索引）是**改技能时才需要看**的，只想用的话可以直接跳到[安装](#安装)。

1. **判据必须是机器可读的。** 不用"评分 85/100"这类自然语言打分——格式一漂移就误判。门禁看退出码，性能看 bench 中位数。表达与判断类内容（`writing` §1–§4）本就没有机器判据，只能由人核；这类内容不声称确定性判定，也不用"建议优化"这类假分数充数。
2. **没有度量就不许出性能结论。** 无 benchmark 时性能阶段显式关闭并在报告里写明"结论不成立"。产生假结论比不产生结论危险得多。
3. **每轮只允许一个可证伪的假设。** 一轮里同时重构加修 bug 加调优，事后无法归因，指标变化说明不了任何事。

## 描述即触发条件

技能只有在描述写对的时候才会被自动加载。宿主拿到的是每条 `description`，模型据此判断这一轮该不该读它。所以描述按三段写，缺一段就会退化：

1. **能力**：一句话说清它做什么。
2. **触发**：`当用户说「…」「…」时使用`。触发词用用户真实会说的口语，不要用技能自己的名字——没人会说"帮我 sharpen 一下"。
3. **边界**：`不适用于…（用另一个技能）`。这是防误触发的唯一手段，重叠的几组技能（dev / poteto-mode / figure-it-out、arena / swarm）尤其需要。

三条硬约束：

- **只用一个 `description` 字段**，中英触发词都放进去。不写 `description_zh` / `description_en`——不确定宿主读哪个字段，单字段最稳，而且省掉 2/3 的描述体积。
- **不写来源说明**。"合并自 xxx 项目（MIT）"对触发零贡献，却占着每次会话都要加载的预算。来源统一记在本文件的来源章节。
- **控制在 480 字节内**。描述越长，关键触发词的权重越低。当前 22 条合计约 7.1KB。

新增技能或改描述后跑一次校验：

```bash
ruby -ryaml -e 'Dir.glob("skills/*/SKILL.md").each { |f| YAML.safe_load(File.read(f)[/\A---\n(.*?)\n---\n/m, 1]) }' && echo ok
```

## 安装

支持四个客户端：**WorkBuddy**（国内/国际版）、**ZCode**、**Qoder**、**Trae CN**。技能目录与插件清单各按各家自己的约定放置：

| 客户端 | 用户级技能目录 | 项目级技能目录 | 插件清单 |
|---|---|---|---|
| WorkBuddy | `~/.workbuddy/skills/`（国际版 `~/.workbuddy-ai/skills/`） | `.workbuddy/skills/` | `.workbuddy-plugin/plugin.json` |
| ZCode | `~/.zcode/skills/` | `.zcode/skills/` | `.zcode-plugin/plugin.json` |
| Qoder | `~/.qoder-cn/skills/`（国际版 `~/.qoder/skills/`） | `.qoder/skills/` | `.qoder-plugin/plugin.json` |
| Trae CN | `~/.trae-cn/skills/` | `.trae/skills/` | —（无插件清单，仅目录挂载） |

挂载脚本是主要安装方式；三份插件清单供按插件形式分发时用（自己用不需要管它），字段各自贴合三家的清单格式。

**首次安装**就是[三分钟上手](#三分钟上手)第 1 步那两条命令（需要 bash，macOS / Linux / Git Bash 自带），这里不再重复。Windows 且只有 PowerShell 时，改用等价的原生脚本（推荐，能建 Junction，改动自动同步）：

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

两个脚本都探测**宿主主目录**（装过客户端才有）：`~/.workbuddy`（WorkBuddy 国内版）、`~/.workbuddy-ai`（WorkBuddy 国际版）、`~/.zcode`（ZCode）、`~/.qoder`（Qoder 国际版）、`~/.qoder-cn`（Qoder 中国版）、`~/.trae-cn`（Trae CN），并在其下 `skills/` 挂载，`skills/` 不存在时自动创建——装了几个客户端就挂几个。目标已有同名目录但**不带 `.skillforge-origin` 标记**时一律跳过，不覆盖别人的技能。

检查本地安装是否落后于仓库：

```bash
bash install.sh --check
```
```powershell
.\install.ps1 -Check
```

从旧版升级时，早先单独装过、后来被合并或删除的技能会留在宿主目录里，与新技能争抢触发条件（例如旧的 `how` / `why` 与 `explain` 描述重叠）。`--prune` 会把 `retired.txt` 里列出的名字移入备份目录：

```bash
bash install.sh --prune
```
```powershell
.\install.ps1 -Prune
```

只搬不删，落点 `~/.skillforge-backup/<父目录>-skills-pruned-<时间戳>/`，需要时原样取回。仓库 `skills/` 下仍存在的同名技能一律不动——把一个技能加回仓库后，清单里的旧条目不会误伤它。

**装完需新开会话**，技能列表在会话启动时加载。

> Windows 上不必强求 Junction：`install.sh` 在无开发者模式时会退化为复制，功能完全正常，只是改完仓库要再跑一次脚本。`install.ps1` 用 Junction 避免这一步。

## 直接在终端跑脚本

上面两种用法都在会话里。如果你的目的只是"跑一下判定"——接 CI、写定时任务、或者不想聊天——脚本可以完全脱离 AI 单独跑。

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

## 来源与关系

### goal-workflow

本仓库的 `dev` 与 `go-gate` 最初在 [smallnest/goal-workflow](https://github.com/smallnest/goal-workflow) 的框架上改造而来，现独立维护：

- 上游的 `review-it` 依赖宿主内置 `/review`、`codex review`，在无这些命令的环境不可用 → 本仓库改为 `dev` 阶段 5 的自包含子代理审阅
- 上游的判定分散在提示词里 → 本仓库抽成 `loop` 脚本，停止条件有确定性输出
- 上游 23 个技能同时启用会让上下文在第一步就吃紧 → 本仓库只收录 Go 后端链路真正用得上的九个，其余留在上游
- `modern-go` 原样搬入会一次吃掉 15k tokens → 本仓库配了 `modern_index.sh` 做版本切片，按需加载单节

`modern-go`、`refactor`、`smell` 原文来自上游，本仓库只对 `modern-go` 增加了索引脚本与开头使用说明，规则内容未改动。

需要其它能力（`prd`、`to-design`、`to-issues` 等）时，把上游加成 remote 按需取用，不整体合并：

```bash
git remote add upstream https://github.com/smallnest/goal-workflow.git
git fetch upstream
git checkout upstream/master -- skills/prd    # 单独取一个，审视后提交
```

### autoresearch / jev-decisions

`loop` 的账本不变量审计、ASI 记忆（假设/下一步/弃用理由）、基准漂移检测、震荡检测与迭代钩子借鉴了 [karpathy/autoresearch](https://github.com/karpathy/autoresearch) 思路的 zcode 官方 `autoresearch` 插件，按本仓库「零依赖 bash + 退出码判定」原则重写进 `loop.sh`——未引入其 MCP server、宿主 hooks 与 dashboard，护栏智能保留，载体不搬。

`jev-judgment` 改编自 zcode 官方 `jev-decisions` 插件内置技能，原文来自 [`@jkudish/jev-mcp`](https://github.com/jkudish/jev-mcp)（MIT）。宿主绑定（ZCode userConfig）换成了通用 MCP 配置说明，协议内容未改动。它是本仓库唯一依赖外部服务的技能：无脚本、无退出码，定位是"按需读取的判断工具使用协议"，与 dev/loop 的机器可读判据互不替代。

### pstack

`principles` 与 `figure-it-out` 改编并合并自作者本人的 [`kalandramo/pstack`](https://github.com/kalandramo/pstack) 技能集合（同作者，MIT）。`principles` 把原 24 条独立的 `principle-*` 技能聚合为单篇参考（避免 24 个技能同时占表面积），供 dev/loop/go-gate/refactor 在相应阶段按名引用；`figure-it-out` 是去掉对 pstack 其它技能（poteto-mode / architect / show-me-your-work）依赖后的通用兜底编排剧本，跨引用改为指向本仓库的 `principles` 与 `loop`。

另有五组技能同样合并自 pstack（同作者，MIT），把原分散的独立技能聚合成单篇、并解开对 pstack 其它技能（poteto-mode 等）的硬依赖：`writing`（technical-writing + unslop + impeccable 合并，覆盖文档规范 / 去 AI 味 / 前端 UI 去 AI 味）、`explain`（bro + in-your-own-words + how + why + teach 合并，覆盖讲解 / 走查 / 动机追溯 / 传授，子代理模型改为由宿主自动选定）、`automate-me`（提炼专属 -mode 技能，unslop 引用改为指向本仓库 `writing`）、`typescript`（TS 类型纪律，原 `type-system-discipline` / `boundary-discipline` 原则引用改为指向本仓库 `principles`）、`statechart`（TLA+ 状态图形式化验证，原样迁入并保留自带 TypeScript 工程）。`typescript` 已接入 `dev` 阶段 3 的 `.ts`/`.tsx` 实现分支。

另有七个技能同样迁移自 pstack（同作者，MIT），作为独立技能收编，解开对 pstack 其它技能的硬依赖并把跨引用改写指向本仓库内部技能与 `principles`：`arena`（多候选竞技嫁接）、`swarm`（并行扇出覆盖）、`sharpen`（深化任务重写提示词）、`interrogate`（多模型对抗审查）、`reflect`（复盘沉淀）、`show-me-your-work`（决策留痕）、`poteto-mode`（总路由元技能，自带 scripts/ 工程与 24 个 playbook，跨引用改写指向 dev / loop / go-gate / writing / explain / principles 等）。这批内容原为 pstack 的 Cursor 版，收编时按三客户端重写：各 playbook 中对 `architect`（→ `dev` 设计阶段）、`unslop`/`deslop`/`impeccable`（→ `writing` 的 Unslop / Impeccable 章节）、`principle-*`（→ `principles` 对应条目）的引用已统一改写为本仓库技能；模型选择一律交给宿主自动选型（删掉了 `~/.cursor/rules/pstack-models.mdc` 这类配置文件与 `claude-opus-5-5-xhigh` / `grok-4.7-xhigh-fast` 这类硬编码 slug）；Cursor 专有的 cloud agent、`control-cli`/`control-ui`、`create-skill` 等引用改为三家各自可行的替代（浏览器自动化、`skill-creator`、Agent Skills 格式）；子代理工具名按 WorkBuddy `Agent` / ZCode 与 Qoder `Task` 区分。

### Duoasa-skill

`writing` §4（设计判断）与 `principles` 的 `label-the-provenance`、`no-soft-praise` 两条源自 [Duoasa/Duoasa-skill](https://github.com/Duoasa/Duoasa-skill)（MIT，© 2026 Duoasa）的「做自己」。

上游是一个 21 行 / 1551 字节的态度声明：7 条协作准则，无步骤、无判据、无脚本、无产物模板。它主张"不要把审美打包成预设交出去"——这个立场本仓库确实缺，但它本身不构成一个可判定技能。原样收录就是第 23 个纯提醒型技能，与"判定由程序给出"的定位冲突。因此不新增技能，只做两件事：

- 把立场落进 `writing` §4，与 §3（Impeccable 负面清单）配成"不要什么 / 要什么由谁定"的一对；原文缺的依据分档、候选形态、批评写法按本仓库习惯补齐
- 把其中可命名的两条抽成 `principles` 条目（`label-the-provenance`、`no-soft-praise`），供其它技能按名引用

未采纳的部分：上游 README 主张"把时间投在基础设施而非短流程 skill"——那是给工具作者的路线建议，不是给模型的行为约束，搬进来只会变成空话。

### DSH-to-Figma

[Duoasa/DSH-to-Figma](https://github.com/Duoasa/DSH-to-Figma)（MIT，© 2026 Duoasa）是 DSH 原生插件：注册 43 个本地工具，经 `127.0.0.1:3055` 的 HTTP 长轮询队列驱动一个 Figma 配套插件，在 Figma Desktop 的沙箱里执行 Plugin API 读写画布。**代码没有收编，也不建议这么做**：

- 它不是技能，是工具。本仓库是 markdown + bash 的方法集、靠符号链接挂载；这个是 184 个文件的 Node 插件，peer 依赖 `@deepseek-ai/cordis`，只有 DSH 能加载，WorkBuddy / ZCode / Qoder 都不认它的注册协议。
- 它自带的 `skills/figma-workbench`（40 行 + 17 个 reference）是那 43 个工具的说明书，不是独立方法论。单独挂进来等于让助手去调 43 个不存在的工具——比「悬空技能名」严重得多。
- 桥接协议本身是干净的（`/connect`、`/poll`、`/result` 的 HTTP 队列），理论上可以包成 MCP server 给三家客户端用，但要自己承担 session/workspace 重映射、`.figma/` 工作目录、companion 打包与全套测试；上游在快速迭代（featureVersion 已到 7），fork 必然漂移。

只吸收了与宿主无关的两块方法，写进 `writing` §4 第 5–6 条：

- **复刻保真档位**——快速草稿 / 均衡复刻 / 精细复刻，开头确认一次，任何档位都必须真看一眼产物，不承诺百分比保真
- **UI 验收六类**（排版 / 间距 / 颜色 / 素材 / 文案 / 交互）+ 单独写明验证边界，未验的不并进「通过」

真要用 Figma 时：读设计稿直连官方 Dev Mode MCP（`http://127.0.0.1:3845/mcp`，只读，配进客户端 MCP 配置即可）；写画布只能走 DSH 插件本体。

## License

MIT
