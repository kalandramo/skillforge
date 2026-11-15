---
name: writing
display_name: "写作与去 AI 味（Writing）"
description: "写作、去 AI 味与设计判断：技术写作标准、去 AI 腔的 Unslop 清单、Impeccable UI 检测器、设计方向、复刻保真档位与 UI 验收。当用户说「写 README」「写 PR 描述」「润色一下」「去 AI 味」「这段太机器味」「界面收尾」「这个设计好不好」「配色」「帮我改稿」「设计方向怎么定」「照这个截图复刻」「界面验收」时使用。不适用于讲解代码原理（用 explain）。"
user-invocable: true
---

# Writing — 写作、去 AI 味与设计判断

四层规范，覆盖从文档到界面的所有产物：

1. **§1 技术写作标准** — 写文档 / RFC / README / PR 描述 / 提交信息的结构与句法。
2. **§2 Unslop 模式清单** — 文本里要扫描并清除的 AI 写作痕迹（§1 引用本清单）。
3. **§3 Impeccable UI 去 AI 味** — 前端 / UI 的确定性检测器封装（`npx impeccable`），管"不要什么"。
4. **§4 设计判断** — 方向未定时怎么帮使用者把判断做出来，管"要什么由谁定"；含复刻保真档位与 UI 验收记录的写法。

§1–§3 有明确判据（可核对的结构、可扫描的模式、可返回退出码的检测器）。§4 没有退出码——它的判据是使用者本人的选择，见该节开头。

---

## §1 技术写作标准（Technical Writing）

写，让一个疲惫的工程师第一遍就读懂。四层全部应用。

三条总则高于一切：

- **删掉每一个不干活的词。** 句子去掉某个词仍成立，那词就删。"In order to" 就是 "to"。"It is important to note that" 什么都不是。
- **用短平实词。** "Use" 而非 "utilize"，"Help" 而非 "facilitate"，"Do" 而非 "perform"。长词得用精度来买它的长度。
- **一条规则把句子写糟了，就换种写法或干脆留着。** 每条都对、读起来却像机器写的，那是失败。

代码库本身就是词表。写真实的符号、文件、flag、命令名，别写它的同义词或描述。

别发明行话。用开发者会念出声的词："move"、"delete"、"a budget that only decreases"，而非 "evacuate"、"ratchet"、"endgame"。命名模式可以保留，但文档第一次要说清它指什么。发现新的冒犯词及其替换，作为对 §2 抽象隐喻规则的补充提议（附 diff），不要直接改 §2。

### 变换节奏

一篇文档可以 obey 每一层却仍像机器写的：每句都截得短、无处见观点、没有 specifics。

- 刻意混用句长。短句落点，长句承载带条件或后果的事实。
- 一句一意不等于一句一长。把载着两个意思的句子拆开；把载着一个意思的长句留下。
- 在模式允许处给出观点。Explanation 权衡取舍，所以说出你的判断，而非只列 pros/cons。Reference 保持干爽。
- 具体胜过 sterile。不是 "schema changes can cause issues"，而是 "a column rename fails the build"。

### 先选模式（Diátaxis）

一篇文档，一种模式。两个问题定位：内容驱动行动（做）还是理解（想），服务学习还是工作？

- 行动 + 学习：**tutorial**
- 行动 + 工作：**how-to**
- 理解 + 工作：**reference**
- 理解 + 学习：**explanation**

整篇文档或一个句子都能用这个罗盘。

- **Tutorial：做中学。** 学习者的成功是你的责任，不是他们的。开头说要 build 什么，而非要 "learn" 什么。每步产出可见结果，早且频。把解释压到一句加一个链接。具体。用 "we"、用命令："First, do x. Now, do y."
- **How-to：达成目标的步骤。** 解决人有的问题，而非机器能做的操作。假定胜任、跳过教学。只行动：不跑题、不铺垫、不为完整而完整。允许分叉与判断："If you want x, do y." 用任务命名指南："How to calibrate the radar array"，而非 "Radar array calibration"。
- **Reference：供查的事实。** 只描述。不指令、不说服、不表态。干爽、完整、笃定。无 hedging 地陈述事实、选项、限制、错误，镜像被描述物的结构，让代码与文档可一起导航。尽量从代码生成。
- **Explanation：理解与为什么。** 一个有限主题，脱离产品也能读。每个标题都能容忍前缀 "About…"。锚定一个真实的 why 问题。给上下文：设计决策、历史、约束、替代方案。此处允许观点，别处不允许。

不要混模式：tutorial 里不放 reference 表，reference 里不夹 tutorial 手把手，how-to 里不辩论。拆开并链接。

### 对读者写句子（Google 开发者风格）

- 用 "you"、现在时对话。"Will" 只用于真正稍后发生的事。
- 说清谁做什么："the compiler checks"，而非 "is checked"。被动仅当施动者未知或无关。
- 指令写成命令："Click Submit." 平实陈述事实。绝不用 "should be done"。
- 条件放在指令前："To delete the document, click Delete."
- 常见情形在前，例外在后。
- 像博学的朋友。无 buzzwords、无比喻语言、指令里无 "please"、流程里绝不用 "simply" / "easy" / "quickly"。若真简单，读者不会来。
- 不预告（"we will soon support…"），不连续用相同短语开头。
- 用指向去向的词做链接：页面标题或简短描述。绝不用 "click here"。优先页面内的上下文句，而非链到站外。
- 标题承载观点，而非仅话题（"Pick the mode first" 而非 "Modes"）。sentence case。任务标题是光杆动词短语（"Create an instance"），概念标题是名词短语。每页一个 h1，不跳级。
- 序列用编号列表，其余用项目符号。用完整句子引出列表。条目保持平行。
- 代码进 code font，UI 元素进粗体。用 serial comma。丢掉 "etc."，开头就说明列表是部分的。
- 在代码字体里写真实的符号、文件、flag、命令名。

### 让每句只负载一件事（STE 规则）

- 一句一指令。其余句子一句一意。
- 长于约 20 词的指令、长于约 25 词的其他句子，拆开。
- 把警告或条件放在它所守护的步骤前："If hot oil touches your skin, injuries can occur."
- 保留 "the" 与 "a"："Remove backup file" 有两种读法，"Remove the backup file" 只有一种。
- 给每个词一个含义一个职责，然后守住。若 "check" 指 inspect，就别又拿它表示 restrain。
- 每个动作固定一个词并守住："start"，而非此处 "start" 彼处 "initiate"。
- 流程写成直接命令，绝不叙事、绝不被动："Install the component"，而非 "the component must be installed"。
- 能不用 "-ing" 就不用。

### 不留句子给两种解读（Global English）

- 把 "only"、"not" 这类词贴在它们修饰的词旁："only fails on growth" 与 "fails only on growth" 意思不同。
- 拆开长名词串："the proto import budget check script" 变成 "the script that checks the proto-import budget"。
- 让每个 "it"、"they"、"this" 指向一个明显的东西。拿不准就重复名词。绝不用 "this" 或 "which" 指向整个从句。
- 不丢动词："Phase 1 moves the converters and Phase 2 the runtime" 让 Phase 2 没了动词。补上。
- 保留显示结构的小词，如 "Ensure that the switch is off" 里的 "that"。绝不为字数牺牲清晰。
- 系列里重复冠词以防误读：两样东西时说 "the client and the host"，而非 "the client and host"。
- 当句子能以两种方式分组时，说清 "and" / "or" 连接的是哪些。"Both…and"、"either…or"、"if…then" 是免费的消歧器。
- 用句号，不用分号。破折号换成新句子。
- 括号里的文字要么是个完整语法单元，要么自成一句。绝不用 "(s)" 造复数。
- 不用斜杠：写 "a, b, or both"，而非 "a/b" 或 "and/or"。
- 每个东西在全文档叫一个名字。把一件事叫成 "the gate"、"the ratchet"、"the budget check" 等于教了三件事。别折腾没变的东西。
- 跳过习语、口语、拉丁缩写、隐喻。

### 声线与仓库 specifics

- 本技能接触的每篇文档都应用 **§2（Unslop）**。那一层持有 slop 模式清单：AI 词汇、filler、hedging、排版痕迹。
- PR 描述与提交信息也是写作。除 Diátaxis 外的每一层都适用它们。PR 正文是 reviewer 一分钟内能读完的简报。不要贴 swarm 日志、SHA 列表或 metric 表，链接它们。
- 产品 UI 文案不是文档。用你产品的文案规范。
- 代码片用 tab 缩进。写真实路径。每个计数或目录树声明在该 commit 落地时为真，并附上能重新生成它的命令。

### 例子

改前：

> Configuration of the proto import ratchet budget script parameters is performed via budget.json. Note that it's important to remember that running with --write, which updates the committed budget to reflect the current count, should only be done when lowering it. If exceeded, CI fails.

改后：

> `budget.mjs` reads the committed budget from `budget.json` and counts the files that import protos. If the count exceeds the budget, CI fails. Run `budget.mjs --write` only to lower the budget.

---

## §2 Unslop 模式清单

编辑文本以去除 AI 模式。扫描下面的模式，然后重写。保留原意，贴合目标语气。

规则编号是其它技能引用的稳定 id。删掉一条规则会留下空隙。

### 内容

- **3. 浮浅的 -ing 短语。** "highlighting…"、"ensuring…"、"reflecting…"、"showcasing…"、"fostering…"。删掉，或补上真实来源。
- **5. 含糊归因。** "Experts believe"、"Industry reports suggest"、"Some critics argue"。点名来源，或删掉。

### 语言

- **7. AI 词汇。** additionally, crucial, delve, enduring, enhance, fostering, garner, interplay, intricate, landscape（抽象）, pivotal, showcase, tapestry（抽象）, testament, underscore, vibrant。换成平实词。
- **8. 花式说 "is"。** "serves as"、"stands as"、"boasts"、"features"。说 "is" 或 "has"。
- **9. "Not just X, but Y."** 直接说重点。
- **10. 三项法则。** 别硬把想法塞进三个一组。用自然的数量。
- **11. 同义轮替。** protagonist、main character、central figure、hero 挤一段。挑一个，反复用。
- **12. 假范围。** "from X to Y" 里 X、Y 不在有意义的坐标轴上。直接列主题。

### 风格

- **13. 破折号滥用。** 完全避免 em dash。只用句号或逗号（不用括号、en dash、连字符代破折号）。一个想法要分隔，就结束句子或用逗号。
- **14. 冒号滥用。** 冒号在列表或例子前可用，不作句中连接词。"If you're coming from traditional automation: instead of registering event handlers, you describe conditions" 加冒号毫无增益。改成让重点自立，不用对比框架。"Describing when the scheduler should fire works best as plain English." 同义，无拐杖标点。
- **15. 粗体滥用。** 别给每个专有名词或缩写加粗。
- **16. 行内标题列表。** 痕迹是粗体标签加冒号重述本行："**Performance:** Performance improved…"。转成散文。粗体引导以句号结尾、点出条目名、后接真正新信息（"**Schema in TypeScript.** Tables live in one file."）可以，不算痕迹。
- **17. 标题句首大写（Title Case）。** 用 sentence case。
- **18. 装饰性 emoji。** 从标题和项目符号中移除。
- **19. 弯引号。** 用直引号。

### 交流痕迹

- **20. 聊天腔短语。** "I hope this helps!"、"Let me know if…"、"Of course!"、"Certainly!"、"Found the smoking gun!" 删掉。
- **22. 谄媚语气。** "Great question! You're absolutely right!" 直接回应。

### 填充

- **23. 填充短语。** "In order to" 变 "To"。"Due to the fact that" 变 "Because"。删掉 "It is important to note that"。
- **24. 过度 hedging。** "could potentially possibly be argued that it might" 变 "may"。
- **25. 泛泛结语。** "The future looks bright." 说具体的计划或事实。

### 行话

- **26. 抽象隐喻名词。** substrate（base）、wedge、wedge in（add）、vector（way, method）、locus、vantage、nexus、作名词的 primitive、隐喻的 harness、作 "API surface" 的 surface、bedrock、隐喻的 scaffolding、modality、paradigm、gold-plating（超过所需）、隐喻的 ratchet（机制的实名，或只会收紧的限制）、evacuate（搬代码用 move out）、endgame（最后阶段）、north star、flywheel。这些读起来技术，但通常有更具体的平实词。挑具体的词。

### 平实表达

- **27. 说它做什么，而非它感觉如何。** "the database stays close at hand"、"SQL you can read"、"types that follow your schema" 点了个感觉。修法点出机制或数字：".toSQL() returns the exact string sent to the database"、"a column rename fails the build"。问这句告诉读者去做或去知道什么，然后写那个。若你不能把它重述成具体指令、事实或数字，就砍了它。再查一遍：若这句原样出现在别的项目文档里也成立，那它没说任何关于本项目的事。砍了。
- **28. 缩短或拆开稠密句子。** 读者要往回读才能解析一句，就拆成两句或丢 clause。一句一意。
- **29. 主动语态。** 优先。抓 "is/are/was/were + 过去分词" 并点出施动者："queries are validated" 变 "the compiler validates queries"、"the file is parsed by the loader" 变 "the loader parses the file"。仅当施动者未知或确实无关时才用被动。
- **30. 砍副词，或换更强的动词。** "runs quickly" 变 "is fast" 或那个数字，"significantly improves" 变测得的 delta。副词撑着弱动词，说明动词错了。
- **31. 用平实词。** "utilize"、"leverage" 变 "use"，"facilitate" 变 "help"，"numerous" 变 "many"，"in the event that" 变 "if"。花哨同义词很少更清晰。
- **32. 做作的散文。** 存在直白短语处的隐喻或辞藻：aphorism（"wire it or delete it"）、为效果造的修辞碎片、拟人化代码（"the plan holds it"）、比喻动词（"rides along"、"stands on"）、套路框架短语。"A dial worth turning" 变 "a parameter worth varying"。说你想说的。规则 26 覆盖隐喻名词。
- **33. 过度压缩。** 丢掉的冠词、无动词碎片、符号话、让读者解码而非阅读的缩写。"Parser rejects bad date → exit 2, no write" 变 "The parser rejects a bad date, exits with code 2, and writes nothing." 写带冠词和动词的完整句子，拼出箭头和缩写。

---

## §3 Impeccable — UI 去 AI 味

Impeccable（[pbakaus/impeccable](https://github.com/pbakaus/impeccable)，Apache-2.0）的**确定性检测器**封装。它扫描 HTML / 目录 / URL，按 62 条规则（Rust 编译，无 LLM、无 API key）标记 "AI 设计味" 与排版质量问题。这是 §2（文字层）在 **UI 层** 的等价物——生成或改动任何前端界面时用来当最后一道闸。

### 何时用

任何涉及**前端 / UI / 网页 / H5 / 组件**生成或改动的场景：

- 生成落地页、dashboard、组件、营销页
- 审阅或改写别人（或模型）写的页面
- 作为前端生成流程的收尾闸门

不要把它当万能设计器——它只负责"**不要什么**"（负面清单），"要什么"由 §4 处理。

### 调用方式（跨 harness 的 CLI，无需装进任何编码器）

```bash
# 扫描文件 / 目录 / URL；退出码 2=有 findings，0=干净，1=无法扫描
npx impeccable detect <path|dir|url>

# 机器可读
npx impeccable detect --json .

# 输出 GitHub Actions 标注（挂 CI 用）
npx impeccable detect --github src/

# 列出全部 62 条规则及 id / 描述
npx impeccable detect --list-rules

# 渲染后检测（低对比度、字号、滚动动画失败等运行时问题；需本机 Chrome/Edge）
npx impeccable detect http://localhost:5173
```

### 关键规则族（slop 类，最可识别的 AI UI 标志）

- **side-tab** — 卡片单侧粗色边。规则原文称其为"AI 生成 UI 最可识别的标志"。
- **icon-tile-stack** — 圆角小方块图标叠在标题正上方。
- **cream-palette** — 奶油色 / 米色页面背景（"反射式伸手就来的有品味 AI 底色"）。
- **overused-font** — Inter / Arial / 系统默认字体。
- **em-dash-overuse** — 破折号（—）饱和（约每 500 字符一个、≥8 个）才报；属 advisory，不拦 CI。
- **aphoristic-cadence** — "X. No Y." 这类对仗短句出现 ≥3 次。
- 其它：`flat-type-hierarchy`（层级未拉开）、`cramped-padding`（贴边内边距）、`marketing-buzzword`、`radial-halo`（径向光晕）等。
- **Quality 类**：低对比度（WCAG 硬指标，算失败）、跳级标题、tiny text。

完整清单以 `npx impeccable detect --list-rules` 为准（规则数随版本浮动，4.8.0 约 62 条）。

### 工作流（与生成配合）

1. 生成 / 改动 UI。
2. 跑 `npx impeccable detect <target>`。
3. 按 findings 修正：去掉单侧色边、换掉 Inter、拉开字号层级、去奶油底、收敛破折号、去营销套话。
4. 复扫直到 **0 findings**（或仅剩有正当理由的 advisory）。

### 边界与注意

- **这是 CLI 封装，需要本机有 Node 且能访问 npm registry。** 首次运行会下载自检二进制到 `~/.impeccable/bin/`（一次性）。
- **隐私 / telemetry**：impeccable 的 `init` 与"视觉世界抽取"会向 `impeccable.style` 发匿名记录。我们**只用 `detect`**（纯规则、无网络请求），但保险起见调用前先设：
  ```bash
  export DO_NOT_TRACK=1          # 或 IMPECCABLE_NO_TELEMETRY=1
  ```
- `detect` 对源码（HTML/JSX/TSX）只跑 pattern 规则；低对比度 / 字号等需渲染的规则只对 **URL** 生效——要查运行时问题就指向你的 dev server。
- **合理误报**用 ignore 机制处理：`npx impeccable ignores add-value overused-font Inter --reason "Brand font"`；单文件行内注释可豁免单条规则。

### 与其它层的关系

- §2（Unslop）：文字 / 写作层的去 AI 味 → 本层是 **UI / 视觉层** 的对应物。
- §1（技术写作）：文档规范，互补。
- §4（设计判断）：本层扫描产物里"不该有的"，§4 决定产物里"该有什么"。顺序是先 §4 后本层：方向定了才有东西可扫。

---

## §4 设计判断 — 「要什么」由谁定

§3 是负面清单，管"不要什么"。本节管另一半：**方向还没定时，怎么帮使用者把判断做出来，而不是替他做**。

> 本节**没有退出码**。判据是使用者本人的选择，不是程序——不要在这里声称有确定性判定。

### 立场

- 不附带任何画风，也不承诺装上就有审美。预设在系列产出上省事，但审美结论不能由预设代替。
- 流行度、安装量、出自哪位大师，都不是"适合眼前这个项目"的证据。风格是可选的表达方式，选不选它取决于当前设计目的。
- 使用者手里往往已经有稿子和主意。默认从那里接着做，而不是从零开始另给一套。

### 1. 判断分三档，逐条标来源

给出任何与"好不好 / 该不该这样"有关的判断时，标明依据属于哪一档：

| 档 | 标注 | 依据是什么 |
|---|---|---|
| 偏好 | （来自你的偏好） | 使用者已明说，或稿子里已体现的选择 |
| 场景 | （来自内容与场景） | 受众、使用环境、信息层级、可读性、技术约束 |
| 主观 | （我的主观建议） | 以上都不成立，只是模型倾向 |

把主观档说成偏好档（"你想要的是……"）或场景档（"现在业界都这样"）是本节最主要的失败方式。

示例：

> 标题压到 2.4rem 更接近你原稿的克制感（来自你的偏好）；正文我建议 17px——这页主要给手机看，14px 在小屏上偏挤（来自内容与场景）；右侧那块留白是我自己的偏好，去掉不影响（我的主观建议）。

### 2. 值得比较时，把候选做成能打开的东西

口头描述两个方案，使用者无法判断。给可打开的文件、截图或能跑的页面，各自说清取舍；可编辑的成果优于图片。

但不要为展示能力硬凑方案。方向已经清楚时，做一版做完，比摆三个半成品有用。判据见 `principles` 的 `exhaust-the-design-space`：无先例的新决策才建 2–3 个竞争原型。

### 3. 批评要具体，赞美要克制

支持使用者的品味，不等于无条件认可产物。发现会影响表达或使用的问题，说清**具体哪里、影响到什么**：

- 空话："这个排版有点问题，建议优化一下。"
- 可行动："这张插画抢了作品的注意力，标题读到一半会被拉走。缩小，或换成低对比的背景。（来自内容与场景）"

反过来，不要用"很棒""很有设计感"给批评做缓冲——那会把上一句抵消掉。

### 4. 工具优先，但不谎报完成

能交给工具做的重复操作（批量改尺寸、导出多规格、跑对比截图）就做掉，保留可编辑的成果，检查结果。工具不可用时说明限制，**不把"建议这么做"说成"已经改好了"**。

产出的记录方式见 `show-me-your-work`：what 做了什么、why 为什么、evidence 实际执行结果。

### 5. 复刻已有设计时，先定保真档位

按参考图 / 截图 / 现存页面复刻时，先确认要哪一档。问一次，之后不要每次调用都重问：

| 档位 | 交付标准 | 适合 |
|---|---|---|
| 快速草稿 | 大结构、层级、近似配色，细节可略 | 先看方向对不对 |
| 均衡复刻（未说明时的默认） | 比例、颜色、关键组件接近，不逐像素抠 | 大多数实际需求 |
| 精细复刻 | 间距、字号、图标细节都对得上 | 有设计稿验收要求时 |

规矩：

- 先做大结构、字号层级和主色，只在约定档位需要、或观察到明显偏差时才去量细节。
- **任何档位都要真的看一眼产物**——截图、渲染结果或可打开的文件。没看过就说"已完成"是最常见的谎报。
- 不承诺"95% 保真"这类百分比，也不承诺像素级一致或固定工时。做不到的量化承诺比模糊描述更糟：用户会拿它当验收标准。

### 6. UI 验收：按六类列发现，写明验证边界

交一份界面完成报告时，不要写"整体效果良好"。按六类各写一行，有问题写具体问题，没问题写"已核对"：

| 类 | 看什么 |
|---|---|
| 排版 | 字号层级、行高、长文本截断 |
| 间距 | 内容内边距、控件高度、溢出 |
| 颜色 | 底色与前景对比、状态色、键盘焦点可见性 |
| 素材 | 图标来源与许可、图片清晰度、有无外链请求 |
| 文案 | 语言一致、错误提示是否可理解 |
| 交互 | 点击后的状态变化、禁用态、键盘可达 |

末尾必须单独写**验证边界**：哪些在真实环境验过，哪些只在本机模拟或浏览器里看过。没验的部分写"未验"，不许并进"通过"。

> 验证边界：浏览器内点过设置开合与暂停/恢复；真实桌面端安装与原生窗口缩放未验；控制台错误未采集。

多轮记录（首轮 + 修正轮）里保留首轮漏掉的缺陷说明——那是整份记录里唯一有信息量的部分，删掉就只剩自我表扬。

### 边界

- 只做判断辅助与试做，不代替使用者定稿。最后选哪一版由他定。
- 与 `arena` 的分工：`arena` 并行做候选后**按工程判据选一个**；本节做候选是为了**让人自己选**。
- 与 `smell` 的分工：`smell` 诊断代码结构；本节只管视觉与表达，不改代码。
- 本节不绑定任何设计工具。有 Figma MCP 时用它读稿，没有时按截图和产物本身判断；本节不要求装特定插件。

### 来源

- **§4 立场（1–4 条）**：提炼自 [Duoasa/Duoasa-skill](https://github.com/Duoasa/Duoasa-skill)（MIT，© 2026 Duoasa）的「做自己」——原文是一份 21 行的态度声明，无步骤与判据。本节按本仓库的分工（§3 管负面清单、§4 管正向意图）重写为可执行条款，并补上原文没有的三件事：依据分档、候选形态要求、批评的具体写法。
- **§4 第 5–6 条（保真档位、六类验收）**：改写自 [Duoasa/DSH-to-Figma](https://github.com/Duoasa/DSH-to-Figma)（MIT，© 2026 Duoasa）内置技能中的复刻保真度约定与验收记录写法。那是一个 DSH 原生插件（43 个工具 + Figma 配套插件），工具层不可移植；这里只取其与宿主无关的方法部分，并按本仓库习惯改写为不依赖具体工具的条款。
