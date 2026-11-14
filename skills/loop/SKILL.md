---
name: loop
description: "迭代账本与判定引擎：记录每轮指标、按 epsilon 判定 keep/revert、执行回滚、账本不变量审计、按确定性规则决定是否停止（含震荡检测）。被 dev 等编排技能调用，也可单独用于任何「改一版→量一次→决定留不留」的场景。不负责跑验证（build/test/bench 由 go-gate 或其他门禁提供），不负责写业务代码。适用于用户说「把这几轮的指标记下来」「判断这版要不要回滚」「循环什么时候该停」。不适用于一次性任务（无需循环）与纯代码审查（用 dev 阶段5）。"
user-invocable: true
allowed-tools:
  - Bash(git:*)
  - Bash(bash:*)
  - Bash(grep:*)
  - Bash(cksum:*)
  - Read
  - Write
---

# loop — 迭代账本与判定引擎

一句话定位：**它不知道你的代码怎么跑，只知道这版比历史最好的是好了还是差了，该不该留、还继续吗——而且账本本身可审计。**

## 为什么单独拆出来

原先把「跑门禁」「算中位数」「判定」「回滚」写在一个脚本里，结果是**换语言就得重写整套判定逻辑**。拆开后：

| 层 | 技能 | 负责 | 不负责 |
|---|---|---|---|
| 验证 | `go-gate` | build/vet/test/race/lint/bench，输出 JSON 与退出码 | 不判定要不要保留 |
| 判定 | `loop`（本技能） | 记录、epsilon 比较、keep/revert、审计、停止条件 | 不知道 Go 是什么 |
| 编排 | `dev` | 决定调谁、调几次、失败怎么办 | 不自己算指标 |

因此非 Go 项目也能用：度量脚本只需打印 `METRIC 名=值` 行，用 `loop metric` 抽值喂给 `loop record` 即可（见下文"任意语言接入"）。

## 四条不可让渡的规则

1. **无度量不得出性能结论。** 指标为 `NA` 时判定一律 `KEEP`（功能性改动），但报告里必须写明"性能结论不成立"。把"没测"写成"没变差"是本领域最常见的造假。
2. **非数值指标必须报错，不得当成 0。** `decide 79.5.0` 返回 `INVALID` 且 rc=2。若静默按 0 处理，会把解析失败伪装成通过——这是最危险的一类假绿。
3. **回滚保留账本。** `revert` 用 `git reset --hard && git clean -fd -e .dev`，代码回到上一个 keep，记录一条不丢。账本被回滚掉，审计链就断了。
4. **写入账本前过审计。** keep 必须真的改善、轮次必须连续、非 keep 行不得带 commit——违反不变量的记录被拒绝写入，而不是污染账本后再靠人眼发现。审计把"手工编辑 results.tsv 修正结论"从文档禁忌变成机器强制。

## 用法

```bash
LOOP=/path/to/skills/loop/scripts/loop.sh

# 1) 初始化（生成 .dev/loop.conf，不覆盖已有）
bash $LOOP init

# 2) 写基线（指标由 gate 提供；无 benchmark 传 NA）
#    若配置了 MEASURE_CMD/MEASURE_FILES，此处同时锁定基准指纹（drift 检测起点）
bash $LOOP baseline 49.01          # 或 baseline NA

# 3) 每轮：先跑验证拿指标，再判定
M=$(bash /path/to/go-gate/scripts/gate.sh --json --bench | tail -1 | <抽 metric>)
V=$(bash $LOOP decide "$M" --goal=perf)   # KEEP | REVERT | INVALID | BASELINE
case "$V" in
  KEEP)   bash $LOOP keep "$ROUND" "$M" "本轮假设" perf \
            --hyp="strings.Join 替换手写拼接" --next="试 bufio 复用" ;;
  REVERT) bash $LOOP revert
          bash $LOOP record "$ROUND" revert "$M" PASS perf "本轮描述" \
            --hyp="扩大缓冲区能降延迟" --rollback="延迟不降反升 1%，方向错误" ;;
  INVALID) echo "指标解析失败，停止" >&2; exit 2 ;;
esac

# 4) 每轮结束问一次要不要继续
bash $LOOP next   # CONTINUE 3 | STOP:max_rounds | STOP:doom_loop | ...
```

`--goal` 决定持平时的处置：`perf` 轮持平算没达成（回滚），`feature`/`coverage`/`robustness` 轮持平正常保留（默认）。

## ASI：回滚后唯一存活的记忆

`keep`/`record` 支持三个可选标志，写入账本第 9 列（`asi`）：

| 标志 | 含义 | 什么时候给 |
|---|---|---|
| `--hyp=` | 本轮假设（一句话，可证伪） | 每轮都给 |
| `--next=` | 给下一轮的提示 | 有明确下一步时 |
| `--rollback=` | 为什么放弃这个方向 | revert / gatefail 行 |

代码会被回滚，但"为什么放弃"写在账本里存活下来。下一轮选假设前先读它（`report` 的"弃用方向与理由"一节自动汇总）。震荡检测也优先读 `--hyp`。

## 账本审计（不变量）

`keep`/`record` **写入前**校验整本账本加上候选行；`loop audit` 可随时单独校验。不变量：

| 不变量 | 含义 |
|---|---|
| `event_order` | 非基线行轮次必须连续；允许同轮重记（门禁失败后重试同一轮），倒退与跳号拒绝 |
| `no_baseline` | iter≥1 的行不得先于基线出现（iter=0 的 round-0 修复行豁免） |
| `keep_without_improvement` | `perf` 轮的 keep 指标必须优于保留最优（epsilon 感知；feature 轮豁免——功能性收益不受指标约束） |
| `metric_format` | keep 行指标非数值即拒绝（NA/SKIP 豁免） |
| `discarded_improvement` | gate=PASS 却丢弃了超出 epsilon 的真实改善 → 拒绝；gatefail（守门失败）豁免 |
| `commit_field` | keep 行必须带 commit；非 keep 行不得带 commit（8 列旧账本豁免） |

审计拒绝时 `keep` 不产生 git commit——账本脏了比少一轮实验严重得多。绕过审计：`loop.conf` 设 `AUDIT_BYPASS=1`（不推荐；等于放弃"记录即证据"）。

## 基准漂移检测（drift）

`loop.conf` 配置后，`baseline` 会锁定基准指纹（`cksum`），之后每轮 `decide`/`keep`/`record` 自动比对：

```bash
# loop.conf
MEASURE_CMD="go test -bench=. -run=^$"   # 产生指标的命令
MEASURE_FILES="concat_bench_test.go"      # 基准相关源文件（内容变化视为漂移）
```

- 指纹不一致 → stderr 警告"新旧指标不可比"，不阻断（是否开新段由编排层决定）。
- 显式检查：`loop drift`（输出 `OK` / `DRIFT` / `NOTRACK`，DRIFT 时 rc=1）。
- 有意变更基准：`loop drift --set` 重新锁定；或重记 `baseline` 开新段。
- **中途改基准再比数字 = 造假。** drift 警告出现后，先处理漂移再谈结论。

## 停止条件（`next` 的确定性输出）

按序检查，命中即返回，不再让模型自行判断：

```
STOP:target         最优值已达 METRIC_TARGET
STOP:no_improve     连续 MAX_NO_IMPROVE 轮 revert（默认 2，方向耗尽或噪声区）
STOP:gate_failures  连续 MAX_GATE_FAILURES 轮 gatefail（默认 3，假设方向错误）
STOP:doom_loop      窗口内同一假设原文重复（原地打转或 A→B→A 震荡），换结构性方向
STOP:max_rounds     已用轮次达到 MAX_ITERATIONS（默认 5）
CONTINUE <n>        可继续，下一轮编号为 n
```

**"连续"是严格的尾部连续**：中间插入一次 keep 就重新计数。**震荡检测**读最近 6 个非 keep 行的假设（优先 `--hyp`，回退 note），同一假设出现两次即触发——所以假设描述要具体，"又调了下参数"这种通用 note 连续出现会误触发。详细原因走 stderr，stdout 只输出停止令牌。

## 任意语言接入（METRIC 协议）

度量脚本只负责往 stdout 打 `METRIC 名=值` 行，抽值交给 `loop metric`：

```bash
M=$(bash my_measure.sh | bash $LOOP metric)             # 取 METRIC_NAME 指定的指标
M=$(bash my_measure.sh | bash $LOOP metric --name=p99)  # 或显式指定
```

- 找不到对应行 → rc=2 并列出可用指标名，**不会静默给 0**。
- 同名多行取最后一行；`Windows` 输出自带 `\r` 会被清理。

## 迭代钩子（可选）

`.dev/hooks/after.sh` 在每次 `keep`/`record` 记账后运行：fail-open（失败不阻断，rc 记入提示），stdout 作为 `after_steer` 回给调用方。用于 agent 不该自己做的事：通知、防打转、试验日志。钩子应尽快退出（<30s）。

协议：环境变量 `LOOP_EVENT`（keep/record）、`LOOP_ITER`、`LOOP_VERDICT`、`LOOP_METRIC`、`LOOP_GOAL`、`LOOP_NOTE`、`LOOP_HYPOTHESIS`、`LOOP_NEXT_HINT`、`LOOP_ROLLBACK`、`LOOP_BEST`、`LOOP_ROUNDS_DONE`、`LOOP_STATE_DIR`、`LOOP_PROJECT`。

现成示例在 `skills/loop/hooks-examples/`（anti-thrash 防打转提示、macos-notify 系统通知、learnings-journal 试验日志）：复制到被管仓库的 `.dev/hooks/after.sh` 即生效，钩子应提交到版本控制。

## 判定矩阵

| 情况 | 输出 | 理由 |
|---|---|---|
| 尚无最优值 | `BASELINE` | 第一轮需先建立基线 |
| 改善 ≥ epsilon | `KEEP` | 达到可归因门槛 |
| 改善 < epsilon 且 `--goal=perf` | `REVERT` | 噪声不算成绩 |
| 改善 < epsilon 且非 perf | `KEEP` | 功能性收益不应因"没变快"被丢弃 |
| 劣于最优 | `REVERT` | 退化不保留，除非用户显式要求 |
| 指标 = `NA`/`SKIP` | `KEEP` | 无度量时由门禁单独决定 |
| 指标非数值 | `INVALID`（rc=2） | 拒绝把解析失败当成结论 |

## 状态文件

```
.dev/
├── loop.conf        判定参数（应提交，团队共享）
├── results.tsv      每轮记录（gitignore）
├── measure.cksum    基准指纹（gitignore，由 baseline/drift --set 写入）
├── hooks/after.sh   迭代钩子（应提交）
├── learnings.md     试验日志（钩子产出，按需提交）
├── REPORT.md        人读报告（gitignore）
└── gate/<ts>/       门禁日志（由 gate 写入，gitignore）
```

`results.tsv` 列：`iter / verdict / metric / delta_pct / gate / goal / note / ts / asi / commit`。`iter=0` 为基线；`asi` 是 `hyp=..|next=..|rollback=..` 编码；`commit` 仅 keep 行有（短 hash）。8 列旧格式行可被审计兼容读取。

## 反模式

- 用 `decide` 的输出替代门禁。判定只在门禁 pass 之后进行一次；门禁失败时**不要**调 `decide`，直接记 `gatefail`。
- 为了"让结果好看"降低 `METRIC_EPSILON_PCT`。epsilon 的作用就是挡住噪声，调它等于自欺。
- 指标抖动时改 `BENCH_RUNS` 之外的东西。正确做法是增加重复次数取中位数，而不是放宽判据。
- 把 `MAX_ITERATIONS` 调大来"多试几次"。轮数不是收敛手段，判据才是。
- 手工编辑 `results.tsv` 修正结论。审计会拒绝与历史矛盾的写入；绕过审计（AUDIT_BYPASS=1）等于宣布记录不再是证据。
- **revert 后不带 `--rollback` 就 record。** 弃用理由是唯一能在回滚后存活的记忆，丢了它下一轮就会重蹈覆辙。
- **基准变了却不 `drift --set` 也不重记 baseline，继续比数字。** 那是在拿两把尺子量出来的数比大小。
- 假设描述写"再试一下""调参数"。震荡检测按原文判重，通用措辞要么漏检真打转、要么误伤正常轮次。

## 与 `dev` 的关系

`dev` 的阶段 6（判定与结算）与"停止条件"两节直接调用本技能，不再由模型自由判断。`dev` 负责说明本轮假设与目标，`loop` 只回答三个问题：留不留、为什么不要（rollback）、还继续吗。
