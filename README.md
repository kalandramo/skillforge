# skillforge

个人技能合集。给 AI 编码代理用的可执行工作流，主力场景是 Go 后端。

不是又一个 prompt 集合——每个技能都配套一个**能返回退出码的脚本**，判定不靠模型自述。

## 三个技能

| 技能 | 层 | 一句话 | 判据来源 |
|---|---|---|---|
| [`dev`](skills/dev/SKILL.md) | 编排 | 一条需求进来，走完判据→设计→切片→实现→门禁→审阅→判定→收尾 | 调用下面两个 |
| [`go-gate`](skills/go-gate/SKILL.md) | 验证 | Go 门禁：`mod_guard`/`build`/`vet`/`test`/`race`/`lint`/`bench` | 进程退出码 + bench 中位数 |
| [`loop`](skills/loop/SKILL.md) | 判定 | 记账、epsilon 比较、keep/revert、确定性停止条件 | 指标数值 |

三者职责不能互相替代：`go-gate` 答"这版对不对"，`loop` 答"这版要不要留、还继续吗"，`dev` 答"接下来做什么"。**换语言只需替换 `go-gate`，判定逻辑不动。**

## 三条设计原则

1. **判据必须是机器可读的。** 不用"评分 85/100"这类自然语言打分——格式一漂移就误判。门禁看退出码，性能看 bench 中位数。
2. **没有度量就不许出性能结论。** 无 benchmark 时性能阶段显式关闭并在报告里写明"结论不成立"。产生假结论比不产生结论危险得多。
3. **每轮只允许一个可证伪的假设。** 一轮里同时重构加修 bug 加调优，事后无法归因，指标变化说明不了任何事。

## 安装

```bash
git clone https://github.com/kalandramo/skillforge.git ~/code/skillforge
bash ~/code/skillforge/install.sh
```

脚本会把 `skills/*` 挂到 `~/.workbuddy/skills/` 与 `~/.claude/skills/`（存在的那个或多个）。优先符号链接，Windows 下自动回退到目录联接，再失败才复制。

**装完需新开会话**，技能列表在会话启动时加载。

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
├── results.tsv           每轮记录
└── REPORT.md             人读报告
```

脚本刻意**不依赖 `jq`**：配置用 shell 变量，直接 `source`。少一个隐式依赖就少一类"装完不报错但行为诡异"的故障。

## 与 goal-workflow 的关系

本仓库的 `dev` 与 `go-gate` 最初在 [smallnest/goal-workflow](https://github.com/smallnest/goal-workflow) 的框架上改造而来，现独立维护：

- 上游的 `review-it` 依赖宿主内置 `/review`、`codex review`，在无这些命令的环境不可用 → 本仓库改为 `dev` 阶段 5 的自包含子代理审阅
- 上游的判定分散在提示词里 → 本仓库抽成 `loop` 脚本，停止条件有确定性输出
- 上游 23 个技能同时启用会让上下文在第一步就吃紧 → 本仓库按需增加，只收录自己真正在用的

需要上游的 `modern-go`、`refactor`、`smell` 等能力时，把上游加成 remote 后按需取用，而不是整体合并：

```bash
git remote add upstream https://github.com/smallnest/goal-workflow.git
git fetch upstream
git checkout upstream/master -- skills/modern-go    # 单独取一个，审视后提交
```

## License

MIT
