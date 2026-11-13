---
name: go-gate
description: "Go 项目的确定性质量门禁：go build / go vet / go test / go test -race / golangci-lint（仅检查基线后新增问题）/ benchmark（多次取中位数）/ go.mod 依赖守卫，输出 JSON 与退出码供编排层消费。触发：go-gate、跑门禁、Go 质量检查、验证 Go 改动、bench 对比、性能有没有变差。"
user-invocable: true
allowed-tools:
  - Bash(go:*)
  - Bash(git:*)
  - Bash(golangci-lint:*)
  - Bash(bash:*)
---

# go-gate — Go 质量门禁

为 Go 项目提供**只有两种结果**的质量判定：通过（exit 0）或失败（exit 1）。不产生评分，不产生"建议"，不产生需要二次解释的中间态。

## 为什么不用"打分"

LLM 打分制门禁有三个结构性缺陷：解析自由文本容易误判（正则漂移）、分数与真实质量无稳定映射、Agent 可以通过措辞抬高分数。Go 生态已经提供了确定性判据——编译器、vet、test、benchmark 的退出码与数值。本技能只消费这些判据。

## 门禁清单

| 阶段 | 命令 | 存在理由 |
|---|---|---|
| `mod_guard` | `git diff --quiet -- go.mod go.sum` | 依赖变更必须显式批准；Agent 随手加依赖是 Go 项目最常见的隐性破坏 |
| `build` | `go build ./...` | 编译不过，后续全部无意义 |
| `vet` | `go vet ./...` | 捕获 printf 参数错配、锁值拷贝、不可达代码等编译器不报的真 bug |
| `test` | `go test ./...` | 行为契约 |
| `race` | `go test -race ./...` | 并发正确性；默认关闭（慢 2–5 倍），有并发改动时必须开 |
| `lint` | `golangci-lint run --new-from-rev=<base> ./...` | **只查新增**，见下 |
| `bench` | `go test -run='^$' -bench=... -benchmem` × K 次取中位数 | 性能结论的唯一合法证据 |

### lint 为什么必须限定基线

全量 `golangci-lint` 在有历史欠账的仓库上必然失败。若把它作为门禁，循环会在第一轮就耗尽失败预算，Agent 随后会开始"修复"与本次需求无关的存量问题——这是范围失控的典型起点。`--new-from-rev` 把判据限定为"本次改动引入的问题"，与需求的边界一致。

## 用法

```bash
# 常规门禁（含并发检测与性能度量）
bash scripts/gate.sh --race --bench='^BenchmarkParse$'

# 只做编译与测试（快速反馈）
bash scripts/gate.sh --skip lint,bench

# 机器可读输出
bash scripts/gate.sh --bench --json

# 确实需要改依赖时，显式放行（会在结果中可见）
bash scripts/gate.sh --allow-mod-changes

# 指定基线（默认自动探测 origin/main 或 origin/master）
bash scripts/gate.sh --base origin/develop
```

参数：`--root DIR`、`--json`、`--race`、`--bench[=PATTERN]`、`--base REV`、`--allow-mod-changes`、`--skip a,b,c`。

环境变量：`BENCH_RUNS`（默认 3）、`BENCH_PKG`（默认 `./...`）。

## JSON 契约

```json
{
  "root": "/path/to/repo",
  "ok": true,
  "metric": { "name": "ns_per_op", "value": "28.96" },
  "stages": [
    { "name": "mod_guard", "status": "pass", "ms": 0 },
    { "name": "bench",     "status": "pass", "ms": 0 }
  ],
  "log_dir": "/path/to/repo/.dev/gate/20261113-165953"
}
```

- `status` 取值：`pass` | `fail` | `skip`。
- `ok` 为 `false` 时一定存在 `fail` 阶段；`skip` 不影响 `ok`。
- `metric.value` 为空字符串表示本次未度量。
- 每个阶段的完整输出在 `log_dir/<stage>.log`，失败时终端已打印尾部 12 行。

## 判定规则

1. **只要有任一阶段 `fail`，本轮改动不得保留。** 不存在"测试挂了但代码更好"的判定空间。
2. **`skip` 必须可解释。** 因工具缺失导致的 skip（如未装 golangci-lint）应在报告中列出；因参数导致的 skip 由编排层记录。
3. **性能结论只在 `bench` 阶段 `pass` 且 `metric.value` 非空时成立。** 否则只能说"未度量"，不能说"没有变差"。
4. **`mod_guard` 失败不是错误，是提示。** 若需求本身就要加依赖，用 `--allow-mod-changes` 重跑并在交付说明中写明新增依赖及理由。

## 常见调整

| 情况 | 处理 |
|---|---|
| 仓库有存量 lint 欠账 | 保持默认 `--new-from-rev`；不要改成全量 |
| 未安装 golangci-lint | 自动 skip；需 lint 时先 `go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest` |
| 测试很慢（>5 分钟） | 先 `--skip test,race` 迭代实现，收尾前跑全量；不要长期跳过 |
| monorepo / 多模块 | 用 `--root` 指向目标模块目录，而非仓库根 |
| 无 benchmark | 不传 `--bench`；性能阶段由编排层标记为"未度量" |
| benchmark 抖动大 | 提高 `BENCH_RUNS`（如 7），或用 `-benchtime=2s` 提高单次稳定性 |

## 反模式

- 为了通过门禁而 `t.Skip()`、放宽断言、删除测试用例。
- 用 `--skip` 长期绕开 test/race，只在收尾时补跑一次。
- 把 `--allow-mod-changes` 写进脚本默认值（等于取消依赖守卫）。
- 用单次 benchmark 结果下结论（Go benchmark 单次抖动可达 ±20%）。
- 把 `go test` 的缓存命中当成"刚跑过"（关键轮次加 `-count=1`）。
