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

## 后期存档：分帧观测的剩余开销

网关现在通过 `ObservationBuilder.build_budgeted` 分帧准备观测，每帧预算 4 ms，到检查点就让出一帧（见 [多单位、城墙与 AI 场景性能优化](dense_ai_performance.md#gateway-观测与规划分帧)）；大型请求的 `json_safe` 和 `JSON.stringify` 在后台线程完成。单帧卡顿因此取决于两个检查点之间不可打断的一段，以及发送前在主线程上完成的检查（`_inspect_json_value`）和深拷贝（`duplicate(true)`）。

使用一局 27 分钟的单机存档（1447 个实体：243 块木栅栏、4 座城门、81 个单位，双方均由外部 AI 托管）测量，每个 tick 玩家方约 159 ms、AI 方约 96 ms 的主线程工作，分摊在十多帧里。其中城墙规划和建造选址各是一整段，三次测量中最长的一段为 32～52 ms；发送前那一帧约 37 ms。

### 改动

以下改动均不改变发送内容：

- **科技可用性**：`TechnologyProgression.available` 原先对每座建筑（包括每块墙）遍历整张科技表，循环内还重复取表，`blocked_reason` 又对每项再调用一次。现在按 `research_at` 预先分组（保持科技表原顺序），只检查该建筑能研究的科技；科技表字典被替换时重建分组。
- **岸线检查**：`ShoreGeometry.intersects_rect_within` 先排除与岸线外包矩形不相交的矩形，再调用原 `intersects_rect`。原函数的三项判断（角点在多边形内、轮廓点严格在矩形内、边相交）都需要矩形触及外包矩形，因此结果相同。城墙场景索引和建造选址索引在建立时为每片水域计算一次外包矩形。
- **编码前检查**：`_inspect_json_value` 对容器内的叶子值（数字、布尔、文本）直接在循环中计数、累计文本长度、判断引用类型，只对子容器递归；判断规则与顺序不变，出错后不再计数。
- **规划导航的迷雾过滤**：观测用导航网格对每个碰撞半径层，按格检查障碍物及其净空范围是否完全可见。改为 `FogOfWarService.footprints_fully_visible` 一次处理整层，格子换算与 `footprint_cells`、`rect_visible` 相同。
- **城墙规划和建造选址分段**：`_defense_planning` 拆为 `_defense_setup`、逐批的 `_defense_batch` 和 `_defense_finish`；`_construction_options` 拆为 `_construction_setup` 和逐个建筑的 `_construction_for_record`。同步入口按原顺序依次调用，结果不变；分帧入口在批次或建筑之间到达预算时让出一帧，让出后剔除已死亡或待删除的村民。城墙场景索引在跨帧使用时跳过已释放或待删除的节点。

### 验证

- 存档加载后立即暂停场景树，使两个版本面对完全相同的局面。两队发送的数据与修改前逐字节一致（249,496 和 120,996 字节），编码前检查的计数与标志也相同。不暂停时，加载后的前几十帧模拟会因实例 ID 不同而略有分叉（见上文“模拟轨迹与对象 ID”），无法逐字节比较。
- `run_budgeted_decision_context`、`run_budgeted_observation`、`run_budgeted_gateway`（冻结世界中分帧结果与同步结果逐字节一致，并覆盖取消、列表生命周期和单位删除）、`run_http_json_encoding` 全部通过。
- 新增 `tests/run_fog_batch_visibility.gd`：在默认地图的真实迷雾上，对 3 个队伍、7 种尺寸共 31,500 个点（包括地图边缘、越界点和格子边界）逐点比较批量结果与 `footprint_visible`，全部一致；人为去掉右下边界的排除余量后报告差异。
- `tests/` 下原有 113 个 `run_*` 测试在修改前后各运行一次：92 个两边都通过；21 个两边都失败，退出码、失败数和错误信息完全相同；没有结果不同的测试。

### 测量

同样在云端 Linux 容器（2 vCPU，Godot 4.7.2 headless）上测得。逐帧切片使用暂停的存档，按网关的真实分帧路径（4 ms 预算）构建，三轮取平均：

| | 玩家方 修改前 → 后 | AI 方 修改前 → 后 |
| --- | ---: | ---: |
| 一次 tick 主线程合计 | 159 → 132 ms | 96 → 82 ms |
| 分帧准备（不含采样和编码） | 114 → 93 ms | 75 → 64 ms |
| 最长单段 | 平均 37 ms、最长 45 ms → 平均 12 ms、最长 13 ms | 平均 35 ms、最长 52 ms → 平均 13 ms、最长 14 ms |
| 发送前检查加深拷贝（单帧） | 37 → 32 ms | 18 → 15 ms |
| 状态采样（单帧） | 7.5 → 6.9 ms | 3.4 → 3.5 ms |

存档正常运行，并模拟两个网关各自每 1 秒游戏时间完成一次“采样、分帧准备、`_encode_payload`”。按 60 FPS 固定帧长运行 900 帧，两轮取平均：

| | 修改前 | 修改后 |
| --- | ---: | ---: |
| 平均帧耗时 | 25.9 ms | 24.6 ms |
| P95 | 70.5 ms | 62.0 ms |
| 超过 50 ms 的帧 | 111、113 | 98、77 |
| 不运行观测时的平均帧耗时（对照） | 17.0 ms | 17.3 ms |

AI 观测平均每帧约占 8.8 ms，修改后约 7.3 ms。这个存档后期的帧耗时大部分来自 AI 以外的系统：迷雾重建、单位移动、小地图刷新，以及资源耗尽时的导航全量重建。

### 剩余开销

- **发送前那一帧**：玩家方约 32 ms（检查约 18 ms、深拷贝约 10 ms），是 AI 带来的最大单帧开销。耗时与发送值的数量成正比：玩家方约 2.96 万个值，其中 149 块己方墙体按完整建筑序列化，每块 71 个值，合计 10,579 个，占 36%。已按下一节精简城墙和城门的记录。
- **频率**：两个网关各自每 1 秒游戏时间准备一次完整观测。`fast_tick_interval_sec` 调到 2.0 可以使这部分平均开销减半，但 Python 端的快速决策也随之减半。

## 城墙与城门的精简记录

### 原因

城墙和城门原先与其他建筑一样序列化：生产队列、训练进度、可训练兵种及受阻原因、研究状态、科技列表、可交付资源、建造时间和规划占地。它们不能生产、研究或接收资源，这些值每块都是相同的空列表、零或 `idle`；建造时间和规划占地是类型常量，`decision_context.catalog.buildings` 已按类型列出。上述存档中，每块己方墙体的 JSON 约 593 字节，其中大部分是这些固定值。

### 改动

`ObservationBuilder._fill_building` 对 `WallSystem.is_fortification` 判定的建筑（三种墙体和城门）改用 `_fill_fortification`，也不再为它们调用可训练兵种、生产状态和科技可用性的查询：

| | 字段 |
| --- | --- |
| 墙体和城门 | `id`、`kind`、`def_id`、`team`、`pos`、`hp`、`max_hp`、`is_complete`、`build_progress`、`footprint`、`orientation`、`blocks_movement` |
| 城门另有 | `gate_open`；己方城门还有 `gate_state`（敌方城门原本就不提供） |
| 不再提供 | `build_time`、`planning_footprint`、`drop_off_resources`、`train_queue_empty`、`train_queue`、`train_progress`、`production`、`research`、`is_researching`、`trainable`、`train_blocked_reasons`、`technologies`；墙体也不再有 `gate_state`、`gate_open`（原值恒为 `"auto"`、`false`） |

这些键直接省略，不保留空值。其他建筑的记录不变。事件中的实体记录（如新建筑出现时）使用同一个序列化函数，也随之精简。

### 使用方检查

修改前逐一检查了读取实体记录的代码：

- **Python 多智能体服务（v3）**：防御角色的 `fortifications` 列表读取 `id`、`def_id`、`pos`、`hp`、`max_hp`、`is_complete`、`build_progress`、`orientation`、`gate_state`、`gate_open`；攻城突破逻辑读取敌方墙体的 `footprint`、`blocks_movement`、`gate_open`。这些都保留。生产和研究字段都通过 `.get(键, 默认值)` 或 `键 in 记录` 读取，默认值与原来的空值效果相同；缺少 `drop_off_resources` 时按建筑类型查表，表中没有墙体。
- **Python 规则导演（v1）和 LLM 指挥官（v2）**：同样只用带默认值的读取。唯一可见的差异是，模型要求在墙体或城门训练单位时，拒绝原因由 `unit_not_trainable` 变为 `wrong_training_building`，两者都会拒绝。
- **Godot**：`DecisionContextBuilder` 只读取实体的编号、类型、队伍、位置、生命值、完成状态和资源字段；`PromptAssembler` 把建筑记录原样写入提示，墙体条目随之变短。

### 验证

- 在同一次运行中，用修改前观测构建器的副本和新版本，在存档的 6 个时刻分别构建两队的观测。中途加入了地基、常开和锁闭的城门、受损墙体，以及位于对方视野内的石墙和城门。所有非城防实体的记录、`decision_context` 和其他顶层字段完全相同；城防记录等于原记录去掉上表的键，被去掉的值都是上面所说的常量。共 9,382 项检查。
- 把这 12 组完整观测和精简观测分别交给 Python 端三种使用方，按时刻连续运行：v3 执行器每个 tick 的命令完全相同；v1 规则导演的输出、v2 指挥官的决策简报（去掉上表的键后比较）和无模型时的兜底命令完全相同。v3 七个角色的规划上下文中有六个完全相同；防御角色的上下文受 14,000 字符上限约束，精简后多容纳 2～4 块城防样本，有时多 1 座建筑，与原来共有的部分完全相同。
- 新增 `tests/run_fortification_observation.gd`：在默认地图上放置己方墙体、城门（常开、锁闭）、地基和敌方墙体、城门，检查每类记录的键集合与上表完全一致、数值与实体一致，房屋和城镇中心仍包含全部生产字段。在修改前的代码上运行时报告 39 项失败。
- `tests/` 下原有 114 个 `run_*` 测试在修改前后各运行一次：93 个两边都通过；21 个两边都失败，退出码和错误信息完全相同；没有结果不同的测试。

### 测量

同一个暂停的存档，云端 Linux 容器（2 vCPU，Godot 4.7.2 headless）。发送的数据：

| | 玩家方 | AI 方 |
| --- | ---: | ---: |
| JSON 大小 | 249,496 → 184,982 字节（−26%） | 120,996 → 83,560 字节（−31%） |
| 值的数量 | 29,632 → 22,530 | 14,516 → 10,400 |

分项计时（同步构建各阶段，四轮交替运行取平均；与上一节按切片统计的数字口径不同）：

| | 玩家方 修改前 → 后 | AI 方 修改前 → 后 |
| --- | ---: | ---: |
| 实体序列化（分帧进行） | 26.7 → 19.4 ms | 19.5 → 13.3 ms |
| 发送前检查 | 21.7 → 15.9 ms | 11.0 → 7.9 ms |
| 深拷贝 | 11.5 → 8.9 ms | 5.9 → 4.5 ms |
| 后台编码（`json_safe` 与 `JSON.stringify`） | 43.9 → 33.3 ms | 20.9 → 15.2 ms |

按网关的真实分帧路径（两轮），发送前那一帧（检查加深拷贝）玩家方从 29.2 ms 降至 20.5 ms，AI 方从 13.5 ms 降至 9.5 ms；最长切片没有变化（8～11 ms），因为城防序列化原本就分散在各个切片里。

Python 端（云端 Python 3.13，15 次取中位数）：请求解析与校验，玩家方 3.7 → 2.8 ms，AI 方 1.8 → 1.2 ms；新会话第一次 v3 tick，玩家方 68.8 → 61.1 ms，AI 方 18.0 → 13.4 ms。

存档正常运行并模拟两个网关时（与上一节同一方法，两轮），帧耗时统计的变化小于两轮之间的波动：平均 27.1、28.0 ms → 26.1、28.2 ms，P95 64.7、69.9 ms → 66.8、70.8 ms。这个存档的帧耗时主要来自 AI 以外的系统，本次改动降低的是每个 tick 发送前那一帧的尖峰，以及后台线程和 Python 端的负担。

精简后，玩家方每块己方墙体的 JSON 从约 593 字节降至约 212 字节。房屋等其他不生产的建筑仍使用完整记录，数量少，暂未处理。
