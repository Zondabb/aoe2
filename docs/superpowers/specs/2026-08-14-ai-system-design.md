# AI System Design

**Date:** 2026-08-14  
**Engine:** Godot 4.7  
**Status:** Implemented — P0/P1 + ai_vs_ai verification scene  

## Goal

为正式对局（`match.tscn`）提供 **AoE2 风格的简单 AI**：先发展经济 → 训练军队 → 集结进攻敌方城镇中心。AI 只负责 **高层决策与命令下发**；单位移动、寻路、碰撞、战斗动画仍由现有 `UnitAgent` 与仿真层完成。

同时与竞技场模式（`AutoCombatDirector`）共用 **战术层（接战 / 选目标）**，避免两套战斗逻辑分叉。

## Context（现状）

| 已有 | 局限 |
|------|------|
| `AiController`（`scripts/systems/ai_controller.gd`） | 规则与魔法数字写死在单文件；三阶段 ECO / MILITARY / ATTACK |
| `AutoCombatDirector`（竞技场自动寻敌） | 只管战斗，不管经济；与 `AiController._attack_actions` 逻辑重复 |
| `UnitAgent.command_*` | 移动 / 采集 / 建造 / 攻击命令已完备 |
| `MatchState` | 资源、人口、胜负 |
| `BuildSystem.can_place` | 建筑 footprint AABB 放置检测 |
| `NavGridService` | 建筑完工后全量重建寻路网格 |
| `test_ai_controller.gd` | 覆盖 ECO → MILITARY → ATTACK 与胜负停止 |

### 当前 `AiController` 行为摘要

```
每 0.5s tick:
  1. 更新阶段（ECO → MILITARY → ATTACK）
  2. 分配建造中的村民（command_build）
  3. 分配空闲村民采集（50/30/20 食物/木/金）
  4. 按阶段：训练村民 / 盖军事建筑 / 训练兵种 / 攻击
```

**阶段切换条件（硬编码）：**

| 阶段 | 进入条件 |
|------|----------|
| `MILITARY` | 村民 ≥ 8 **或** 食物 ≥ 400 |
| `ATTACK` | 军事单位 ≥ 6 **或** 对局时间 ≥ 180s |

**攻击行为：** 军事单位 8 格内遇敌则 `command_attack` 最近敌人；否则攻击玩家 TC；无 TC 则向 `(-40, -40)` 移动。

**挂载方式：** `match_bootstrap.gd` → `_setup_ai_controller()` 在 `Match` 根下创建/配置 `AiController` 节点。

**竞技场：** `combat_arena_bootstrap.gd` 禁用 `AiController`，改用 `AutoCombatDirector`（aggro 40 格，0.5s tick）。

## Decisions Locked

| 项 | 选择 |
|---|---|
| 架构 | **分层**：战略 / 运营 / 战术 / 执行 |
| Tick 频率 | **0.5s**（与现有一致，避免每帧全图扫描） |
| 命令出口 | 仅调用 `UnitAgent` / `BuildingAgent` 已有 API |
| 数据驱动 | 文明与难度通过 **`CivAiProfile` Resource**（`.tres`）配置 |
| 战斗 micro | **`CombatManager` 包装 `AutoCombatDirector`**，正式局与竞技场共用选目标逻辑 |
| 作弊级别（Phase 1） | 已知敌方 TC 出生点；全图资源节点可见（与现有一致） |
| 视野限制（Phase 2） | `ScoutManager` + Blackboard `enemy_visible` |
| 与玩家对称 | AI 使用同一套 `MatchState.can_afford` / `can_train` / `spend` |
| 胜负 | `match_state.winner != -1` 时 AI 停止（已实现） |

## Non-Goals（本设计不包含）

- 对标 AoE2 原版 DE 难度（多线 micro、风筝、阵型）
- 完整科技树 / 时代升级
- 联机同步 AI
- 每帧行为树或 GOAP 全图推理
- AI 直接修改 `sim_pos`（必须走 `command_*`）

## Architecture

### 分层总览

```text
┌─────────────────────────────────────────────────────────┐
│  AiDirector          战略层：阶段机、目标、tick 调度      │
├─────────────────────────────────────────────────────────┤
│  AiBlackboard        感知层：资源、人口、威胁、可见敌人    │
├──────────────┬──────────────┬───────────────────────────┤
│ EconomyMgr   │ BuildMgr     │ ProductionMgr   运营层    │
│ ArmyMgr      │ CombatMgr    │ ScoutMgr        战术层    │
├──────────────┴──────────────┴───────────────────────────┤
│  UnitAgent / BuildingAgent / MatchState / NavGrid  执行层 │
└─────────────────────────────────────────────────────────┘
```

**原则：** AI 模块只产出 **意图（Intent）**，不重复实现移动与战斗物理。

### 模块职责

| 模块 | 职责 | 输出 |
|------|------|------|
| `AiDirector` | 唯一 `_process` 入口；维护阶段；调用各 Manager | 调度顺序 |
| `AiBlackboard` | 每 tick 刷新共享状态 | 只读快照供各 Manager 查询 |
| `EconomyManager` | 村民分配、采集比例、阶段权重 | `command_gather` / 空闲标记 |
| `BuildManager` | 建造计划、选址、派工 | `command_build`、放置 foundation |
| `ProductionManager` | 训练队列、人口满则 house | `enqueue_train` |
| `ArmyManager` | 军队规模、集结点、波次 | `command_move` 到 rally |
| `CombatManager` | 接战半径、集火、默认攻击 TC | `command_attack` |
| `ScoutManager` | Phase 2：侦查象限、更新可见列表 | `command_move` scout |

### 与现有类的映射

| 新模块 | 迁移来源 |
|--------|----------|
| `EconomyManager` | `AiController._assign_idle_villagers`、`_assign_builders`、`_underfilled_resource_type` |
| `BuildManager` | `_ensure_building`、`_next_build_position`、`_ensure_house_if_pop_blocked` |
| `ProductionManager` | `_train_villagers`、`_train_military`、`_try_enqueue` |
| `CombatManager` | `_attack_actions` + `AutoCombatDirector.pick_target_for_unit` |
| `AiDirector` | `_update_phase`、`evaluate`、常量与 `setup` / `stop` |

## Phase Machine（阶段机）

在现有三阶段上扩展，**Phase 1 可保持与旧枚举兼容**：

```gdscript
enum Phase { OPENING, ECO, BOOM, ATTACK, DEFEND }
```

| 阶段 | 含义 | 典型行为 |
|------|------|----------|
| `OPENING` | 开局前 2 分钟 | 固定 build order：house → 军事建筑；前 4 村民采食 |
| `ECO` | 缺人口或资源 | 补村民至目标；平衡 50/30/20 采集 |
| `BOOM` | 食物/木材达标 | 连续盖 barracks / archery；双线训练 |
| `ATTACK` | 军力或时间达标 | 集结 → 推 TC；CombatManager 接管 micro |
| `DEFEND` | Phase 2 | 基地受威胁时部分兵力回防 |

**Phase 1 兼容映射：**

```text
AiController.ECO      → OPENING + ECO
AiController.MILITARY → BOOM
AiController.ATTACK   → ATTACK
```

### 阶段切换（默认参数，可写入 Profile）

| 转换 | 条件 |
|------|------|
| → `BOOM` | `villager_count >= profile.villager_target` **或** `food >= profile.high_food_stockpile` |
| → `ATTACK` | `military_count >= profile.military_attack_count` **或** `match_time >= profile.attack_time_seconds` |
| → `DEFEND` | 敌人距己方 TC < `profile.defend_radius`（Phase 2） |
| 停止 | `match_state.winner != -1` → `AiDirector.stop()` |

## AiBlackboard（黑板）

每 tick 开始时由 `AiDirector` 调用 `refresh()`，从 `MatchState` 与 `Entities` 子节点聚合：

```gdscript
class_name AiBlackboard
extends RefCounted

var match_time: float
var ai_team: Enums.Team
var enemy_team: Enums.Team

# 资源与人口
var food: int
var wood: int
var gold: int
var pop_used: int
var pop_cap: int

# 实体计数
var villager_count: int
var military_count: int
var incomplete_buildings: int

# 位置（Phase 1：出生点已知）
var own_tc_pos: Vector2
var enemy_tc_pos: Vector2

# Phase 2
var threat_near_base: bool
var enemy_visible: Array[Node]   # 最近 N 秒内看到的单位/建筑
var scout_coverage: float        # 0.0 ~ 1.0
```

**刷新策略：** 计数与资源 O(n) 扫描 `Entities` 一次；避免各 Manager 重复遍历。

## CivAiProfile（数据驱动）

新建 `scripts/data/civ_ai_profile.gd` + `data/ai/*.tres`：

```gdscript
class_name CivAiProfile
extends Resource

@export var civ_id: StringName
@export var villager_target := 8
@export var high_food_stockpile := 400
@export var military_attack_count := 6
@export var attack_time_seconds := 180.0
@export var food_ratio := 0.5
@export var wood_ratio := 0.3
@export var gold_ratio := 0.2
@export var retarget_radius := 8.0
@export var build_order: Array[StringName] = [&"house", &"barracks", &"archery_range"]
@export var army_composition: Dictionary = {&"swordsman": 4, &"archer": 2}
@export var unique_unit_priority := true
@export var opening_seconds := 120.0
@export var defend_radius := 20.0
```

示例：`data/ai/chinese.tres` 优先诸葛弩；`data/ai/teutons.tres` 优先条顿骑士 + stable。

`CivDef` 可增字段 `ai_profile: CivAiProfile`，或在 `AiDirector.setup` 时按 `civ_id` 加载。

## Tick 流程（每 0.5s）

```text
AiDirector.evaluate():
  if match_state.winner != -1: stop(); return

  blackboard.refresh(match_state, entities, ai_team, enemy_team)
  _update_phase(blackboard, profile)

  economy.assign_builders(blackboard)      # 未完成建筑 → command_build
  economy.assign_gatherers(blackboard, profile)

  build.tick(blackboard, profile)          # build_order → foundation + 派工
  production.tick(blackboard, profile)     # 村民 / 军事训练 + house

  match phase:
    OPENING, ECO, BOOM:
      (above sufficient)
    ATTACK:
      army.rally(blackboard)               # 向集结点 command_move
      combat.tick_army(blackboard, profile)  # retarget + command_attack
    DEFEND:                                 # Phase 2
      combat.defend_base(blackboard)

  scout.tick(blackboard)                   # Phase 2
```

**与 `UnitAgent` 的边界：**

| AI 调用 | UnitAgent 负责 |
|---------|----------------|
| `command_move(pos)` | 寻路、卡住重算、碰撞侧滑 |
| `command_gather(node)` | 走到资源、extract、送 drop-off |
| `command_build(building)` | 走近工地、建造进度 |
| `command_attack(target)` | 追击、射程、攻击动画、伤害 |

AI **不应** 每帧改命令；同一 tick 内对同一单位只发一次意图，避免与玩家指令打架（正式局 AI 单位不会被玩家选中控制）。

## EconomyManager 原理

### 村民分配（沿用现有算法）

1. 统计已在 `GATHER` 且目标有效的村民 → 按 `resource_type` 计数  
2. 空闲村民（`order == NONE`）按 **缺口最大** 的资源类型分配：  
   `deficit = target_ratio - actual_ratio`  
3. `_nearest_resource(villager, type)` / `_nearest_any_resource`  
4. 调用 `command_gather`

### 阶段权重（Profile 扩展）

| 阶段 | 食物 | 木材 | 黄金 |
|------|------|------|------|
| OPENING / ECO | 0.6 | 0.3 | 0.1 |
| BOOM | 0.4 | 0.35 | 0.25 |
| ATTACK | 0.3 | 0.3 | 0.4 |

### 建造派工

扫描 `team == ai_team` 且 `is_complete == false` 的建筑；若无村民 `BUILD` 该目标，取 idle villager → `command_build`。

## BuildManager 原理

### 建造计划

按 `profile.build_order` 顺序检查：若尚未存在 **完成** 或 **施工中** 的该 id，且 `match_state.can_afford`，则尝试放置。

### 选址（现有 + 改进）

**Phase 1：** 保留 `_next_build_position`：以 TC 为原点，固定 offset 列表 + `BuildSystem.can_place(footprint, center, existing)`。

**Phase 2：** 螺旋 / 网格扫描 TC 周围半径 R，跳过 blocked cell（可选读 NavGrid）。

### 放置流程

```text
match_state.spend(cost)
  → instantiate building_view
  → start_construction()
  → entities.add_child()
  → villager.command_build(foundation)
  → NavGrid 在 is_complete 时由 building_agent 触发 rebuild
```

### 人口阻塞

`production` 想训练但 `!match_state.can_train` 且资源够 → 优先 `ensure_building(HOUSE)`。

## ProductionManager 原理

### 训练优先级

1. OPENING/ECO：TC 训练 villager 至 `villager_target`  
2. BOOM/ATTACK：按 `army_composition` 缺口训练；若 `unique_unit_priority` 且文明有特色兵，优先对应建筑  
3. 每个建筑 **队列空** 才 `enqueue_train`（与现 `_try_enqueue` 一致）

### 文明映射

| 单位 id | 训练建筑 |
|---------|----------|
| `villager` | town_center |
| `swordsman` | barracks |
| `archer`, `chu_ko_nu` | archery_range |
| `teutonic_knight` | stable |

## ArmyManager 原理

### 集结（ATTACK 阶段）

**问题：** 当前 `_attack_actions` 各单位直接冲向 TC，容易在兵营门口散开。

**方案：**

1. 计算 `rally_point`：己方 TC 与敌方 TC 连线中点，或己方 TC 外 8 格朝向敌方  
2. 距 rally > `rally_radius` 的单位 → `command_move(rally_point)`  
3. 已进入集结区或已在接战 → 交给 `CombatManager`

```text
rally_point = lerp(own_tc, enemy_tc, 0.35)
```

## CombatManager 原理

### 统一 AutoCombatDirector

将 `AutoCombatDirector` 作为 **无 Node 的 RefCounted 服务**：

- 竞技场：`combat_arena_bootstrap` 每帧 `director.tick(delta)`  
- 正式局 ATTACK：`CombatManager` 内部对 AI 军事单位调用 `pick_target_for_unit` 或等价逻辑  

**参数差异：**

| 场景 | aggro_radius | retarget_radius |
|------|--------------|-----------------|
| 竞技场 | 40 | 12 |
| 正式局 AI | — | `profile.retarget_radius`（默认 8） |

### 目标选择（与现有一致）

```text
1. 若当前 ATTACK 目标仍有效 → 保持
2. retarget_radius 内最近敌对单位 → command_attack
3. 否则默认攻击 enemy_tc
4. prefer_units_over_buildings（可调）
```

### 不覆盖的命令

与 `AutoCombatDirector._unit_wants_auto_combat` 一致：单位在 `MOVE` / `GATHER` / `BUILD` 时不被战斗 AI 打断。

## ScoutManager（Phase 2）

- 指派 1 单位向未覆盖象限移动  
- 进入 `vision_radius` 的敌人写入 `blackboard.enemy_visible`  
- ATTACK 前若长时间无视野，先 `command_move` 向敌方基地方向  
- **不** 全图作弊选目标；`CombatManager` 优先攻击 `enemy_visible` 内目标  

## 难度分级

通过 `AiDifficultyModifiers` 乘在 Profile 或 `MatchState` 上：

| 难度 | 修正 |
|------|------|
| Easy | `attack_time + 60s`；`military_attack_count + 2`；不 rally |
| Normal | Profile 默认值 |
| Hard | `villager_target + 2`；更早 BOOM；`retarget_radius + 4` |
| Insane | 训练/建造成本 -10%（仅 AI team） |

## 文件结构（目标）

```text
scripts/systems/ai/
  ai_director.gd              # 主入口，替换 ai_controller.gd 职责
  ai_blackboard.gd
  ai_economy_manager.gd
  ai_build_manager.gd
  ai_production_manager.gd
  ai_army_manager.gd
  ai_combat_manager.gd
  ai_scout_manager.gd         # Phase 2

scripts/data/
  civ_ai_profile.gd

data/ai/
  profile_chinese.tres
  profile_teutons.tres
  difficulty_normal.tres

scripts/systems/
  ai_controller.gd            # Phase 1：薄包装 → AiDirector，保持 class_name 与测试兼容
  auto_combat_director.gd     # 被 CombatManager 复用
```

**挂载不变：** `Match` 根下仍叫 `AiController` 节点，`match_bootstrap._setup_ai_controller()` 无需改场景路径。

## 与竞技场的关系

```text
match.tscn:
  AiDirector (enabled) + CombatManager in ATTACK
  AutoCombatDirector: 不使用

combat_arena / duel_arena:
  AiDirector: disabled (现有逻辑)
  AutoCombatDirector: enabled per ArenaConfig
```

`CombatManager` 与 `AutoCombatDirector` 共享静态方法：

```gdscript
# ai_combat_manager.gd
static func pick_attack_target(unit, blackboard, profile) -> Node:
    # 委托 AutoCombatDirector.pick_target_for_unit 或提取 _hostiles_for_unit
```

## Implementation Phases

| 阶段 | 内容 | 验收 |
|------|------|------|
| **P0** | `CivAiProfile` + 将 `ai_controller.gd` 拆为 Director + Economy/Build/Production；行为与现网一致 | `test_ai_controller.gd` 全过 |
| **P1** | `CombatManager` + ATTACK 集结；统一 retarget 与 `AutoCombatDirector` | 正式局 AI 一波推 TC；竞技场测试仍过 |
| **P2** | 动态选址、Scout、DEFEND | 玩家早攻时 AI 有回防 |
| **P3** | 难度、多波次 army、Profile 热更 | 可选 skirmish 配置 |

## Testing

| 测试 | 文件 | 要点 |
|------|------|------|
| 阶段转换 | `test_ai_controller.gd` | ECO→MILITARY→ATTACK、时间兜底 |
| 村民分配 | 同上 | idle → GATHER |
| 攻击 TC | 同上 | 6 军事单位 command_attack TC |
| 胜负停止 | 同上 | winner 后 `enabled == false` |
| Ghost 过滤 | 同上 | 不攻击 placement ghost |
| 战斗导演 | `test_auto_combat_director.gd` | aggro、保持目标、MOVE 不打断 |
| 集成 | `test_match_2d.gd` | AiController 存在、civ 正确 |

新增：`test_ai_profile.gd` 验证 Profile 加载与阶段阈值覆盖。

## Performance

- **Tick 0.5s**：单次 evaluate 扫描 `Entities` 子节点 O(n)，n 为实体数（通常 < 200）  
- **避免每帧**：所有 AI 决策在 tick 边界执行  
- **寻路**：AI 只发 `command_move`；A* 由 `UnitAgent` 按需触发，不在 AI 层批量跑  
- **Blackboard 缓存**：同 tick 内各 Manager 共享一次扫描结果  

## Risks & Mitigations

| 风险 | 缓解 |
|------|------|
| 重构破坏现有测试 | P0 保持 `AiController` 类名与对外 API；内部委托 Director |
| 攻击与采集命令冲突 | Combat 不覆盖 GATHER/BUILD；ATTACK 阶段仍保留少量村民经济 |
| 建筑堵死 rally 点 | rally 点用 `BuildSystem.can_place` 或 NavGrid 采样空闲格 |
| AI 与玩家指令争单位 | 正式局仅 AI team 由 AI 控制；玩家 team 不受 AiDirector 影响 |

## References

- 现有实现：`scripts/systems/ai_controller.gd`  
- 战斗 micro：`scripts/systems/auto_combat_director.gd`  
- 单位命令：`scripts/entities/unit_agent.gd`  
- 对局启动：`scripts/match/match_bootstrap.gd`  
- 寻路设计：`docs/superpowers/specs/2026-08-10-pathfinding-design.md`  
- 碰撞设计：`docs/superpowers/specs/2026-08-08-unit-collision-design.md`  
