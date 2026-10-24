# AI 决策 tick 的主线程开销

## 卡顿的原因

开启 AI 后，AI Gateway 每个决策 tick 都在主线程同步准备观测：采样本队状态、遍历实体生成 `observation`、计算 `decision_context` 规划提示，再编码 JSON。HTTP 请求本身是异步的，等待模型不会卡帧；卡顿来自这段同步计算。v3 fast tick 默认间隔为 1.0 模拟秒，`game_settings.cfg` 中 `speed=2.0` 时相当于每 0.5 实际秒执行一次。

最大的热点是 `DecisionContextBuilder._defense_planning` 的基地城墙规划。每个 tick 都要检查整圈 200～280 块墙。原先 `WallSystem.existing_segment` 每次调用遍历实体容器的全部子节点，`validate_plan` 对每块墙还会再做两次全表扫描。默认 480 × 480 地图约有 1100 个实体子节点，其中约 980 棵树，所以开销与“墙块数 × 实体数”成正比。基地扩大、周边进入视野后，可见的墙段都要做完整的占地校验，这一项单独就要 1.7 秒左右。

玩家拖动城墙预览也走同一条路径：每次刷新都要整段校验、逐块校验，再重复计算费用，同样是“墙块数 × 实体数”的规模。

其次是建造选址 `_construction_options`。它为每种可建建筑在基地周围多个半径、16～32 个方向上生成候选点，中期一次约 860 个；每个点都要遍历全部已观察到的建筑和地形块，做规划间距检查 `_planning_clear` 和占地检查 `Build.can_place`，还要重新生成四条预留墙带。同一 tick 内这些阻挡物不会变化，却被重复读取上千次。相比之下，选址中的寻路只有十几次，合计不到 2 ms。

## 实现方式

### 城墙规划

`WallSystem.scene_index(ctx)` 一次遍历实体容器，建立本次校验共用的快照：

- 本队存活建筑按位置建表，用于判断墙段是否已存在。仍按子节点顺序选取第一个匹配项，与全表扫描结果相同；
- 建筑、地形块和仍有存量的资源写入 8 × 8 模拟单位的空间桶，单块墙只检查覆盖到的桶；
- 水域单独列出，仍用原来的岸线相交检查；
- 同一种建筑的建造条件只计算一次。

`existing_segment`、`cost` 和 `validate_plan` 新增可选的 `index` 参数。未传入时，`validate_plan` 和多块墙的 `cost` 会自己建一次索引，`existing_segment` 仍使用原来的全表扫描，因此 AI 命令校验和其他调用方的结果不变。快照不会随实体生成、移动、死亡或资源耗尽更新，只能在同一次计算内复用。

城墙规划在一次 tick 内共用一个索引；玩家城墙预览每次刷新共用一个索引（放置预览本身已按幽灵对象排除）。

实体容器里不只有游戏对象。迷雾为玩家视野外已见过的树木、建筑留下的灰色残影（`FogMemory`）也挂在同一个容器下，它们是普通 `Node2D`，没有 `sim_pos`、`def` 等模拟字段；侦察兵离开后，开局几十秒就会出现几百个。`scene_index` 与原全表扫描一样先按类型分类，只读取建筑、地形块和仍有存量的资源的位置，其余子节点直接跳过。最初版本对每个子节点先读 `sim_pos`，实际对局中遇到残影即报错（`Trying to assign value of type 'Nil' to a variable of type 'Vector2'`，`wall_system.gd:72`），AI 城墙规划和玩家城墙预览都会中断。

### 建造选址

`_construction_options` 开始时调用 `_site_index(blockers)`，把本次传入的阻挡物一次转换成纯几何数据，写入 16 × 16 模拟单位的空间桶：

- 规划间距：建筑的规划占地矩形，以及兵营类建筑东侧出口矩形，与原 `_planning_clear` 的计算相同；
- 实际占地：与 `Build.can_place` 读取的占地尺寸相同（`get_placement_footprint`、地形块 `block_size`，否则 1 × 1）；
- 水域：单独列出，仍对每个候选点做原来的岸线相交检查。

每个候选点只检查与自身范围相交的桶。两项检查都是“任一阻挡物命中即不可用”，同一阻挡物出现在多个桶里不会改变结果；查询范围额外外扩 0.01，避免浮点误差恰好落在桶边界时漏掉阻挡物。四条预留墙带改由 `Perimeter.wall_strips(plan)` 预先算好，再用 `strips_clear` 逐点判断；原 `keeps_wall_strip_clear` 改为调用这两个函数，行为不变。`Build.can_place` 本身未修改，玩家放置和规则 AI 仍使用原函数。

## 测量与复现

```powershell
godot --headless --path . --script res://tests/benchmark_ai_tick.gd
godot --headless --path . --script res://tests/run_construction_site_index.gd
godot --headless --path . --script res://tests/run_wall_scene_index.gd
```

基准加载默认地图，先测开局，再为 AI 方补充约 15～20 分钟规模的基地（55 个村民、30 个军事单位、24 座建筑和 10 块农田），并标记约一半地图为已探索后测中期。每个场景预热 1 次，计时 8 次，分别统计 `sample_owned_state`、`ObservationBuilder.build` 及 `decision_context` 各子项和 JSON 编码。第二次计时时把规划提示写入 `.godot/ai-tick-hints-<场景>.json`，用于前后结果对比。

`run_wall_scene_index` 让玩家侦察兵在默认地图上跑过几片森林再返回，按真实流程生成迷雾残影（约 550 个），另加一个不带任何模拟字段的 `Node2D`；对双方各自的基地城墙（共 432 块）比较残影出现前后的 `validate_plan`、`cost`、`existing_segment` 结果和 AI 规划提示，要求完全相同且 `scene_index` 正常返回。修复前该测试复现了上述报错。

`run_construction_site_index` 在默认地图（含湖泊和悬崖）上加入兵营、靶场、马厩、城门、城墙和农田，用固定随机种子生成 7238 个点（包括恰好贴边和差 0.001 重叠的点），逐点比较新旧实现：索引版占地检查对照 `Build.can_place`，规划间距检查对照原逐个阻挡物遍历的实现，预算墙带对照原逐点计算。

以下数据来自云端 Linux 容器（2 vCPU，Godot 4.7.2 headless），每组版本交替运行两轮后取平均。绝对耗时随机器变化，应在同一台机器上比较前后结果。

**城墙规划优化（原始代码 → 第一步）**

| 场景 | 原 tick 平均 | 新 tick 平均 | 原城墙规划 | 新城墙规划 |
| --- | ---: | ---: | ---: | ---: |
| 开局 | 211.9 ms | 56.4 ms | 176.6 ms | 20.2 ms |
| 中期 | 1919.5 ms | 193.1 ms | 1766.7 ms | 61.1 ms |

两轮中的单次最大值：开局从 323.5 ms 降至 91.3 ms，中期从 2426.3 ms 降至 266.7 ms。

**建造选址优化（第一步 → 第二步，另一次测量）**

| 场景 | 原 tick 平均 | 新 tick 平均 | 原建造选址 | 新建造选址 |
| --- | ---: | ---: | ---: | ---: |
| 开局 | 50.8 ms | 47.4 ms | 5.5 ms | 3.6 ms |
| 中期 | 188.7 ms | 160.0 ms | 47.3 ms | 12.9 ms |

中期建造选址的单次最大值从 69.0 ms 降至 18.2 ms。两次测量中第一步版本的数据（开局 56.4 / 50.8 ms，中期 193.1 / 188.7 ms）有正常的运行间波动；同一张表内的前后数据为同一次交替运行。

同一局面下，两步优化后的规划提示 JSON 与原始代码逐字节一致（开局 16,648 字节，中期 36,913 字节）。`run_construction_site_index` 的 7238 个点全部一致；人为改成每次只查询一个桶后，该测试报告 391 处规划间距和 61 处占地不一致，说明它能发现覆盖范围错误。

现有测试中 `run_wall_system`、`run_defense_perimeter`、`run_wall_controls`、`run_multi_agent_mechanics`、`run_external_ai_visibility`、`run_siege_ai_mechanics`、`run_ai_siege_strategy`、`run_ai_production_strategy`、`run_fog_of_war`、`run_ranged_combat` 全部通过。以下失败在原始代码中同样存在：`run_external_ai_context` 与 `run_settlement_spacing` 各 1 项，`run_ai_scouting` 1 项（400 秒内未交付石料），`run_tests` 单元测试集 20 项（错误列表与原始代码相同）。需要外部 Python 服务的对局测试（`run_ai_duel_match` 等）未在此环境运行。

### 模拟轨迹与对象 ID

`run_ai_scouting` 的逐步模拟在原始代码与第一步之间完全一致；第二步后，前 255 秒所有单位和建筑的状态仍逐步一致，此后侦察骑兵攻击同一目标时选了不同的接近点。原因不在规划逻辑：近战接近点按 `get_instance_id() % MELEE_ATTACK_SLOTS` 选择环绕位置（`unit_agent.gd`，绕路冷却也用 `get_instance_id() % 7` 错开）。Godot 的实例 ID 含有全局对象计数，脚本内容变化会改变启动时创建的对象数量，使同一单位得到不同 ID。第二步后侦察骑兵 ID 的计数部分比第一步多 7，接近位从 0 号变为 4 号。对照实验：在第一步代码的测试开头额外创建并释放 7 个对象，侦察骑兵的 ID、目标和接近点与第二步完全相同。

因此，任何代码改动都可能让同一局面的 AI 对局在某一时刻后分叉。跨版本比较模拟结果（例如 AI 对战 A/B）时，应把这类差异视为随机种子不同，而不是行为回归。

## 剩余开销

两步优化后，中期一次 tick 平均约 160 ms，主要分布如下：

| 项目 | 平均 |
| --- | ---: |
| 城墙规划 `_defense_planning` | 62 ms |
| 侦察前沿 `_scouting` | 23 ms |
| JSON 编码（约 118 KB） | 21 ms |
| 建造选址 `_construction_options` | 13 ms |
| `decision_context` 实体收集 | 12 ms |

这仍是周期性的单帧峰值。后续可选方向：`construction_options`、`defense_options` 不必每个 tick 全量重算（Python 执行器每个 fast tick 都会读取，降频需确认过期提示的影响）；或在主线程只做数据快照，把规划计算交给 `WorkerThreadPool`。
