---
name: loop
description: "迭代账本与判定引擎：记录每轮指标、按 epsilon 判定 keep/revert、执行回滚、按确定性规则决定是否停止。被 dev 等编排技能调用，也可单独用于任何「改一版→量一次→决定留不留」的场景。不负责跑验证（build/test/bench 由 go-gate 或其他门禁提供），不负责写业务代码。适用于用户说「把这几轮的指标记下来」「判断这版要不要回滚」「循环什么时候该停」。不适用于一次性任务（无需循环）与纯代码审查（用 dev 阶段5）。"
user-invocable: true
allowed-tools:
  - Bash(git:*)
  - Bash(bash:*)
  - Bash(grep:*)
  - Read
  - Write
---

# loop — 迭代账本与判定引擎

一句话定位：**它不知道你的代码怎么跑，只知道这版比历史最好的是好了还是差了，以及该不该继续。**

## 为什么单独拆出来

原先把「跑门禁」「算中位数」「判定」「回滚」写在一个脚本里，结果是**换语言就得重写整套判定逻辑**。拆开后：

| 层 | 技能 | 负责 | 不负责 |
|---|---|---|---|
| 验证 | `go-gate` | build/vet/test/race/lint/bench，输出 JSON 与退出码 | 不判定要不要保留 |
| 判定 | `loop`（本技能） | 记录、epsilon 比较、keep/revert、停止条件 | 不知道 Go 是什么 |
| 编排 | `dev` | 决定调谁、调几次、失败怎么办 | 不自己算指标 |

因此非 Go 项目也能用：只要有个命令能吐出一个数字，喂给 `loop record` 即可。

## 三条不可让渡的规则

1. **无度量不得出性能结论。** 指标为 `NA` 时判定一律 `KEEP`（功能性改动），但报告里必须写明"性能结论不成立"。把"没测"写成"没变差"是本领域最常见的造假。
2. **非数值指标必须报错，不得当成 0。** `decide 79.5.0` 返回 `INVALID` 且 rc=2。若静默按 0 处理，会把解析失败伪装成通过——这是最危险的一类假绿。
3. **回滚保留账本。** `revert` 用 `git reset --hard && git clean -fd -e .dev`，代码回到上一个 keep，记录一条不丢。账本被回滚掉，审计链就断了。

## 用法

```bash
LOOP=/path/to/skills/loop/scripts/loop.sh

# 1) 初始化（生成 .dev/loop.conf，不覆盖已有）
bash $LOOP init

# 2) 写基线（指标由 gate 提供；无 benchmark 传 NA）
bash $LOOP baseline 49.01          # 或 baseline NA

# 3) 每轮：先跑验证拿指标，再判定
M=$(bash /path/to/go-gate/scripts/gate.sh --json --bench | tail -1 | <抽 metric>)
V=$(bash $LOOP decide "$M" --goal=perf)   # KEEP | REVERT | INVALID | BASELINE
case "$V" in
  KEEP)   bash $LOOP keep   "$ROUND" "$M" "本轮假设" perf ;;
  REVERT) bash $LOOP revert ;;
  INVALID) echo "指标解析失败，停止" >&2; exit 2 ;;
esac

# 4) 每轮结束问一次要不要继续
bash $LOOP next                    # CONTINUE 3 | STOP:max_rounds | ...
```

`--goal` 决定持平时的处置：`perf` 轮持平算没达成（回滚），`feature`/`coverage`/`robustness` 轮持平正常保留（默认）。

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

## 停止条件（`next` 的确定性输出）

按序检查，命中即返回，不再让模型自行判断：

```
STOP:target         最优值已达 METRIC_TARGET
STOP:no_improve     连续 MAX_NO_IMPROVE 轮 revert（默认 2，方向耗尽或噪声区）
STOP:gate_failures  连续 MAX_GATE_FAILURES 轮 gatefail（默认 3，假设方向错误）
STOP:max_rounds     已用轮次达到 MAX_ITERATIONS（默认 5）
CONTINUE <n>        可继续，下一轮编号为 n
```

**"连续"是严格的尾部连续**：中间插入一次 keep 就重新计数。这样"改了 10 轮终于成功"不会被误判为方向耗尽。

## 状态文件

```
.dev/
├── loop.conf        判定参数（应提交，团队共享）
├── results.tsv      每轮记录（gitignore）
├── REPORT.md        人读报告（gitignore）
└── gate/<ts>/       门禁日志（由 gate 写入，gitignore）
```

`results.tsv` 列：`iter / verdict / metric / delta_pct / gate / goal / note / ts`。`iter=0` 为基线。

## 反模式

- 用 `decide` 的输出替代门禁。判定只在门禁 pass 之后进行一次；门禁失败时**不要**调 `decide`，直接记 `gatefail`。
- 为了"让结果好看"降低 `METRIC_EPSILON_PCT`。epsilon 的作用就是挡住噪声，调它等于自欺。
- 指标抖动时改 `BENCH_RUNS` 之外的东西。正确做法是增加重复次数取中位数，而不是放宽判据。
- 把 `MAX_ITERATIONS` 调大来"多试几次"。轮数不是收敛手段，判据才是。
- 手工编辑 `results.tsv` 修正结论。记录被改过，报告就不再是证据。

## 与 `dev` 的关系

`dev` 的阶段 6（判定与结算）与"停止条件"两节直接调用本技能，不再由模型自由判断。`dev` 负责说明本轮假设与目标，`loop` 只回答两个问题：留不留、还继续吗。
