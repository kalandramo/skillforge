---
name: go-gate
display_name: "Go 质量门禁（Go Gate）"
description: "Go 项目的确定性质量门禁：mod_guard、build、vet、arch（分层依赖，读 .arch.json）、构建标签门禁（注册表+编译矩阵）、test、race、lint（只查基线后新增问题）与 bench（多次取中位数），输出 JSON 与退出码。当用户说「跑门禁」「Go 质量检查」「验证这个 Go 改动」「bench 对比」「性能有没有变差」「检查分层依赖」「架构有没有被改坏」时使用。非 Go 项目不适用。"
user-invocable: true
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
| `arch` | `python3 check-arch.py --config .arch.json`（先 `--verify` 自检契约） | **分层依赖越界**：build / vet / test 全都不会因为"domain import 了 infra"变红，架构违规在测试判据里是零信号。仓库无 `.arch.json` 则 skip；有则只查基线之后改动的包 |
| `buildtags` | `python3 scripts/check-build-tags.py` | 自定义构建标签必须在 CI 与 Taskfile 双向登记；仓库无此脚本则 skip |
| `buildtags_compile` | `python3 scripts/check-build-tags.py --compile` | **编译矩阵**：按标签定位 test-only 包并只编译。`./...` 看不见 `-tags=integration/soak` 后面的包，接口变更只有它能抓到（真实案例：F-01 Observer 化后 `soak_test.go` 传裸 Provider，本地全量测试全绿、CI 编译矩阵红） |
| `test` | `go test ./...` | 行为契约 |
| `race` | `go test -race ./...` | 并发正确性；默认关闭（慢 2–5 倍），有并发改动时必须开 |
| `lint` | `golangci-lint run --new-from-rev=<base> ./...` | **只查新增**，见下 |
| `bench` | `go test -run='^$' -bench=... -benchmem` × K 次取中位数 | 性能结论的唯一合法证据 |

### lint 为什么必须限定基线

全量 `golangci-lint` 在有历史欠账的仓库上必然失败。若把它作为门禁，循环会在第一轮就耗尽失败预算，Agent 随后会开始"修复"与本次需求无关的存量问题——这是范围失控的典型起点。`--new-from-rev` 把判据限定为"本次改动引入的问题"，与需求的边界一致。

### arch 为什么必须由 import 图判定

分层规则（"domain 不得 import infra"）在 build / vet / test 里**没有任何信号**：测试全绿、编译通过、指标不动，依赖方向却已经反转。这类退化只能靠 import 图判出来，且必须由项目自己的契约文件说了算——门禁不该猜项目分几层。

`.arch.json` 放仓库根（**不要放 `.dev/`**：那里被 gitignore，只用于单次需求的临时状态，CI 与其它机器拿不到契约），示意：

```json
{
  "layers": {
    "domain":    ["example.com/proj/internal/domain"],
    "app":       ["example.com/proj/internal/app"],
    "infra":     ["example.com/proj/internal/infra"],
    "transport": ["example.com/proj/internal/transport"]
  },
  "allow": {
    "domain":    [],
    "app":       ["domain"],
    "infra":     ["domain", "app"],
    "transport": ["app", "domain"]
  },
  "forbid": [
    {"from": "domain", "to": ["database/sql", "gorm.io/*"]}
  ],
  "ignore": ["example.com/proj/internal/generated"],
  "strict": {"require_layer_under": ["example.com/proj/internal"]}
}
```

语义（刻意最小，避免变成配置语言）：

- 包归属某层 = `layers` 前缀的最长匹配，且按路径段对齐（`internal/transport` 不匹配 `internal/transport2`）。
- `layers` 前缀支持 `*`，只吃**一个**路径段：`internal/*/domain` 覆盖所有业务切片的 domain 及其子包，新切片自动纳管（垂直切片项目靠这个，不必逐个枚举）。
- 层 → 层：只有 `allow[from]` 里列出的层可依赖；同层依赖恒允许；某层不在 `allow` 里 = 不得依赖任何其它层。
- 非层目标（标准库、第三方）：只受 `forbid` 约束，`forbid.from` 可写层名或包路径前缀。
- `strict.require_layer_under` 下出现**不属于任何层**的新包即违规——新包不声明层，是架构漂移最常见的起点。
- 只统计非测试 import：测试包可以自由 import 基础设施，不被这条规则绑架。
- 没有 `.arch.json` 就 skip，不猜项目结构。

**契约从哪来：不要手写，也不要让 Agent 凭想象编层表。** 先看项目属于哪种形态：

| 项目形态 | 用什么 | 为什么 |
|---|---|---|
| 目录即层：`internal/{domain,app,infra,transport}` | `--init` | 目录名到层是确定性映射，不需要判断 |
| 目录是业务切片：`internal/<模块>/{domain,app,infra}`、按业务分包、多模块 | `--evidence` → 模型/人写 → `--verify` | 第一段是模块不是层；名字重复出现在多个父路径下，才是"层" |
| 分层只写在文档或团队约定里，代码结构完全自由 | 同上 | 目录推不出层，文档往往是唯一写清方向的地方 |

```bash
S=<plugin>/skills/go-gate/scripts/check-arch.py
python3 $S --root . --init                    # 目录即层：打印初稿 + 反向依赖清单
python3 $S --root . --init --write            # 落盘
python3 $S --root . --evidence                # 目录不按层切：摊事实，交给模型写
python3 $S --root . --evidence --depth 1      # 改聚合深度
python3 $S --root . --verify                  # 写完自检，必须过
```

**`--init`**：按目录惯例分层（`internal` / `pkg` / `src` 的后一段为层名，否则首段为层名），按惯例定序（domain < app < infra < transport < cmd），`allow` 只写"外层→内层"。

**代码里现有的反向依赖不会进 `allow`**——写进去等于把漂移固化成规范。它们会列成"需人工定夺"清单（带文件:行号），由人决定清理还是显式放行。同样地，无法按惯例定序的层名（`platform`、`shared` 之类）先置为可依赖任意层并在清单里点名，避免一上手就刷一屏无意义告警。

**`--evidence`** 不下任何结论，只把判断所需的事实摊开：

1. 按前 N 段（默认 2）聚合的分组与包数，末段是惯例层名时标注 rank（越小越内层）
2. 跨分组的实际 import 方向；两侧末段都是惯例层名、方向又是"内层→外层"时标 `← 疑似反向`
3. **在多个父路径下重复出现的目录名**——垂直切片项目的层名就长这样（`domain` 出现在 `order/`、`user/` 下），脚本会直接给出可用的通配前缀写法
4. `README` / `AGENTS.md` / `docs/**/*.md` 里提到分层或依赖方向的行（带 `文件:行号`）
5. 下一步命令

拿到这份清单，模型可以把契约写对；但**允许模型写，不等于让模型直接生效**——见下。

**`--verify`** 是模型生成契约的准入门槛。前缀拼错时规则永不触发，门禁会长期全绿，**比没有门禁更危险**（没有门禁时人知道自己在裸奔，假契约让人以为有保护）。硬判定四条：

- 某层前缀匹配不到任何包 → FAIL：规则永不触发，多半路径写错
- 一个包同时命中多个层 → FAIL：`layer_of` 取最长前缀，但语义已经含糊
- `strict.require_layer_under` 的路径下没有任何包 → FAIL：路径写错
- 有包不属于任何层、`forbid.to` 在现有 import 里一个都没命中 → WARN

`arch` 阶段默认先跑 `arch_verify` 再跑增量判定（契约自检与本次改动无关，不做增量）；`ARCH_VERIFY=0` 或 `--skip arch_verify` 可关。

`--changed-only` + 基线（走 `git diff base...HEAD`、工作树、未跟踪文件三源并集）把检查范围限定到本次改动的包，与 lint 同一套取舍。base 探测：`--base` → 当前分支 upstream → `origin/main` → `origin/master`；**刻意不用本地 `main`/`master`**（本地分支就是当前工作，拿它当基线等于静默放过）。探测不到基线则全量检查，此时存量违规会如实报出来。

**覆盖度（`--blind-spots`）——第二种假判据。**

`--verify` 管的是"规则写了但永不触发"（前缀拼错）；它管不到另一种：**这次改的包根本不在任何规则的 source 集合里**。原生契约尤其容易这样——`internal/archgate` 的 `forbiddenImports` 只有 5 个 key，而模块有 91 个包，其中 73 个没有任何 source 规则。改那些包时 `arch` 门禁是绿的，但绿的不是它。

```bash
python3 .../check-arch.py --root . --blind-spots --governed session,kernel,agent,runner,channel
python3 .../check-arch.py --root . --blind-spots --governed @config          # 从 layers 自动取
python3 .../check-arch.py --root . --blind-spots --governed @config --changed-only
```

它**只做集合运算，不反推分层**：受约束范围必须由 `--governed` 显式给出（原生契约从规则 key 读，`.arch.json` 用 `@config`）。main 包自动排除——装配根不可被 import，没有"它能否依赖谁"的问题。有盲区返回 1。

输出按顶层分组聚合，因为盲区几乎总是成组出现（整层没规则，而不是零散几个包）。

**层内方向（`--intra`）——七层管不到的地方。**

"依赖只向下"在**同一层内部**没有定义。而 Go 的 import cycle 由编译器兜住（`go list` 遇环直接失败），所以"查环"在 Go 里是死判据——真正的问题是**没有环、方向却互不一致**：

```bash
python3 .../check-arch.py --root . --intra --within telemetry,controlplane,host
```

`--within` 按**包里真实的模块相对路径**写：层在顶层写 `host`，层在 `internal/` 下写 `internal/host`。写错会报"范围内没有任何包"并给出可复制的正确前缀。分组键会跳过 `internal`/`pkg`/`src` 这类容器目录——否则所有包都落进同一个 "internal" 组，单向链的中间层会被误判成"与同一组双向相连"。

```
  方向不一致 2 处（同一个包对同一组包既在上又在下）：
    controlplane  ⇄  host 组
        → host/audience, host/membership, host/receipts, host/routing
        ← host/authz, host/channelops, host/dispatch, host/sessionops
```

刻意**不**把"既出又入"当信号：正常分层链 `top→mid→leaf` 里的 mid 也是既出又入，拿它判定会满屏假阳性。真信号是"同一个包对**同一组**包双向相连"，分组键取模块相对路径首段，所以平铺模块不会互相误判。

输出是事实不是判决（退出码恒 0，除非范围内根本没有包）：谁该在上是团队约定，脚本不裁决。已有裁决的（例："host/* 之间允许互相 import，设墙会让装配根退化成上帝对象"）登记出处即可，不必改代码。

替代方案：仓库已配 `golangci-lint` 的 `depguard` 也能判，两者**只留一个**——两套规则并存必然漂移。`depguard` 适合只要 deny 列表的简单项目；需要"层 + 允许矩阵 + 未分层新包"这类结构表达时用 `.arch.json`。

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

# 指定基线（默认自动探测 upstream / origin/main / origin/master）
bash scripts/gate.sh --base origin/develop

# 自定义架构契约文件位置（默认仓库根 .arch.json）
bash scripts/gate.sh --arch-config docs/arch/rules.json

# 契约覆盖度：本次改动的包是否在规则里（不进门禁，是开工前的体检）
python3 scripts/check-arch.py --blind-spots --governed @config --changed-only

# 层内方向：某一层内部谁对同一组包既在上又在下
python3 scripts/check-arch.py --intra --within telemetry,controlplane,host
```

参数：`--root DIR`、`--json`、`--race`、`--bench[=PATTERN]`、`--base REV`、`--allow-mod-changes`、`--skip a,b,c`、`--arch-config FILE`、`--require-arch`。

`check-arch.py` 除了分层判定本身，还有四类"写契约 / 查契约"的模式：`--init`（生成初稿）、`--evidence`（摊事实供人/模型写契约）、`--verify`（契约自检）、`--blind-spots --governed SPEC`（覆盖度）、`--intra --within SPEC`（层内方向）——后两者配 `--exclude SPEC` 排除生成目录。**它们都不进 `gate.sh` 的常规链路**：日常提交要过的是"代码守不守契约"，而这几项回答的是"契约本身够不够用"。唯一例外是 `arch_verify`——它挡的是假契约，属于门禁本身。

`--require-arch` 把"缺 `.arch.json`"从 skip 变成 fail（退出码 1）。默认不加，是为了让未接契约的老项目仍能跑门禁；`dev` 循环会带上它，因为那一侧已经规定"无契约就当场生成"——没有契约还报绿，等于把没做的判定说成做过了。

环境变量：`BENCH_RUNS`（默认 3）、`BENCH_PKG`（默认 `./...`）、`ARCH_CONFIG`（默认 `.arch.json`）、`ARCH_VERIFY`（默认 1，设 0 关掉契约自检）。

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
5. **`arch` 失败是结构性越界，不是可以商量的建议。** 唯一合法修法是把依赖方向倒过来（下层定义接口、上层实现）或把跨界代码挪到允许该方向的层。放宽 `allow`、往 `ignore` 里塞路径来"变绿"，等于当场删除判据。

## 常见调整

| 情况 | 处理 |
|---|---|
| 仓库有存量 lint 欠账 | 保持默认 `--new-from-rev`；不要改成全量 |
| 未安装 golangci-lint | 自动 skip；需 lint 时先 `go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest` |
| 仓库无 `scripts/check-build-tags.py` 或无 python | buildtags/buildtags_compile 自动 skip（其他项目不受影响）；有构建标签的仓库应提供该脚本 |
| 仓库无 `.arch.json` | arch 自动 skip 并打印 `--init` / `--evidence` 提示；接入了 dev 循环的仓库应加 `--require-arch`，让"没契约"直接失败。首次落契约先看项目形态选路径，别手写一份把现状全放行的空契约 |
| `arch_verify` 失败 | 契约本身写错了（前缀不匹配任何包 / 包多命中）。改契约，不改代码。这类错不会让 `arch` 变红，只会让它永久静默通过 |
| `--blind-spots` 报大批盲区 | 正常——多数契约只覆盖主链路几层。按组看：本次改到的组必须处置，没改到的只记总数。**不要为了消掉告警给无关组补规则**，那会把契约变成一份谁都不敢改的清单 |
| 盲区看起来「本来就该自由」 | 那是裁决，不是默认。写进 `AGENTS.md` 或契约出处再按 `decided` 登记；只在对话里说一句等于没裁决，下一轮还会重新发现 |
| `--intra` 报一组方向不一致 | 先查该组有没有「内部不设墙」的既有裁决。有 → 登记出处；没有 → 这是真的结构问题（同一个包从两个方向穿过同一组包），拿人拍板定方向，别用「务实取舍」糊过去 |
| 存量分层违规 | 不要放宽 `allow` 抹平；用 `--all` 出一份全量清单登记为技术债，日常门禁保持"只查改动"，清理走独立 `refactor` 轮次 |
| 已配 `depguard` 或项目自带 `internal/archgate` 之类 | 与 `.arch.json` **二选一**，优先保留项目原生那份；两套分层规则并存必然漂移，且失败日志会互相矛盾 |
| 测试很慢（>5 分钟） | 先 `--skip test,race` 迭代实现，收尾前跑全量；不要长期跳过 |
| monorepo / 多模块 | 用 `--root` 指向目标模块目录，而非仓库根 |
| 无 benchmark | 不传 `--bench`；性能阶段由编排层标记为"未度量" |
| benchmark 抖动大 | 提高 `BENCH_RUNS`（如 7），或用 `-benchtime=2s` 提高单次稳定性 |

## 反模式

- 为了通过门禁而 `t.Skip()`、放宽断言、删除测试用例。
- 用 `--skip` 长期绕开 test/race，只在收尾时补跑一次。
- 把 `--allow-mod-changes` 写进脚本默认值（等于取消依赖守卫）。
- 用 `--skip arch` 让越界改动过关，或放宽 `allow` / 往 `ignore` 加路径来消除违规——这是删掉判据，不是修好代码。
- 同时维护 `depguard` 与 `.arch.json` 两套分层规则。
- 把 `--init` 的输出直接提交而跳过那份"反向依赖"复核清单——初稿只是把目录惯例翻译成配置，它不知道你们的约定。
- 让模型或 Agent 直接生成 `.arch.json` 就提交，不跑 `--verify`——前缀拼错时规则永不触发，门禁长期全绿，是买了个假保险。
- 把「`arch` 门禁绿」当成「本次改动没架构问题」。绿只说明**被规则覆盖的那部分包**没越界；改到规则外的包（`--blind-spots` 能算出来）时，那条绿与改动无关。这是比假契约更隐蔽的一类：契约是真的，判据也是真的，只是判的不是你。
- 用「没有环」论证层内方向没问题。Go 编译器本来就禁止 import cycle，环永远查不到——L6 这类混杂层的问题是**没环、但同一个包从两个方向穿过同一组包**，只有 `--intra` 那种分组比对才看得见。
- 把「既出又入」当层内问题的信号。正常分层链的中间层就是既出又入，不分组直接报只会制造假阳性，最后所有人都学会忽略这条告警。
- 层内结论只在对话里裁决、不落文字。没有出处的 `decided` 等价于没裁决：下一轮重新发现同一问题，结论还会随轮次漂移。
- 目录不按层切（垂直切片、按业务分包）却硬套 `--init`——它会把模块名（`order`、`user`）当层名，产出一份判不到任何边界的契约。
- 手写一份 `allow` 把现状所有依赖方向全放行的 `.arch.json`——那不是契约，是把漂移盖章认证。
- 在 `feature` 轮里顺手"把依赖方向理顺"——那属于独立 `refactor` 轮次，混进来会让指标变化无法归因。
- 用单次 benchmark 结果下结论（Go benchmark 单次抖动可达 ±20%）。
- 把 `go test` 的缓存命中当成"刚跑过"（关键轮次加 `-count=1`）。
