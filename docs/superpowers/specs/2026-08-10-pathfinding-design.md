# Pathfinding System Design

**Date:** 2026-08-10  
**Engine:** Godot 4.7  
**Status:** Draft — pending review  

## Goal

为 RTS 单位增加**绕建筑寻路**：右键移动、采集、建造、追击时，单位能沿可通行路径到达目标，而不是直线撞墙后停下。在现有 `sim_pos` 仿真层上叠加全局路径规划，**保留** `CollisionResolver` 做逐步局部修正。

## Context（现状）

| 已有 | 缺失 |
|------|------|
| `sim_pos` 逻辑坐标 + `IsoMath` 仅负责显示 | 全局路径（A* / NavMesh） |
| `CollisionResolver`：建筑硬挡 + 单位软分离 | 可通行网格 / 障碍地图 |
| `UnitAgent` 直线步进 `_process_move` / `_move_toward` | 路径 waypoint 队列 |
| 建筑 `footprint` AABB + `buildings` 组 | 建筑增删时的网格更新 |
| Stuck 检测（10 帧无进展 → 放弃移动） | 绕障后 stuck 语义需调整 |

2026-08-08 碰撞设计明确 **「不寻路：直线 + 滑墙/停下」**。本设计是对该决策的**升级**，碰撞解析器职责不变，在其之上新增路径层。

## Decisions Locked

| 项 | 选择 |
|---|---|
| 算法 | **网格 A\***（逻辑 xz 平面） |
| 网格单元 | `cell_size = 1.0` 逻辑单位（120×120 @ match 边界） |
| 静态障碍 | `buildings` 组 + 部分 `resource_nodes`（见下表） |
| 动态障碍（单位） | **不参与寻路**；仍靠 `CollisionResolver` 软分离 |
| 资源点通行 | **按类型区分**（见「资源通行规则」） |
| 资源采空 | **树（WOOD）、矿（GOLD）采空后同一帧立即可通行**；无树桩/矿渣占位 |
| 地图边界 | 逻辑范围外标记 blocked（match ±60，arena ±40） |
| 路径平滑 | A* 后 **string pulling**（视线检测简化折线） |
| 局部修正 | 每帧仍调用 `CollisionResolver.resolve_move` |
| 实现层 | 纯 GDScript `RefCounted`，不用 Godot `NavigationRegion` |
| 坐标 | 全程 `sim_pos`（Vector2 表 xz），不经 `IsoMath` |

## 资源通行规则

| 资源 | `Enums.ResourceType` | 寻路 | 说明 |
|------|---------------------|------|------|
| 树木 | `WOOD` | **不可通行** | 路径需绕树 |
| 金矿 / 石矿 | `GOLD`（石矿预留） | **不可通行** | 矿点视为固体障碍 |
| 浆果丛 | `FOOD` | **可通行** | 单位可穿过草丛到达采集点 |
| 建筑 | —（`buildings` 组） | **不可通行** | 沿用 `BuildingDef.footprint` |

判定 API（拟，`ResourceNode` 或 `NavGrid` 内）：

```gdscript
static func resource_blocks_pathfinding(type: Enums.ResourceType) -> bool:
    match type:
        Enums.ResourceType.FOOD:
            return false
        Enums.ResourceType.WOOD, Enums.ResourceType.GOLD:
            return true
        _:
            return true  # 未来新增矿类默认可挡路
```

**资源障碍 footprint（逻辑 AABB， centered at `sim_pos`）：**

| 类型 | footprint | 备注 |
|------|-----------|------|
| `WOOD` | `Vector2(1.2, 1.2)` | 单棵树占位 |
| `GOLD` | `Vector2(2.0, 2.0)` | 矿点较大 |
| `FOOD` | — | 不标记 |

标记方式与建筑相同：`half = footprint/2 + Vector2(r, r)`，覆盖 cell 置 blocked。

**资源采空 → 立即可通行（Phase 1，已锁定）：**

- **树（`WOOD`）与矿（`GOLD`）** 均在 `amount <= 0` 的同一帧释放 NavGrid cell
- 触发：`ResourceNode.extract()` 使 `amount <= 0`
- 动作：`NavGrid.mark_resource(node, false)` 清除该 footprint 覆盖的 blocked cell
- 不做树桩 / 矿渣占位；节点 `visible = false` 与网格释放在同一逻辑路径
- 已在途单位：不强制重算；新 `command_move` 与新 A* 立即受益；Stuck 重算时也会用到更新后的 grid

```text
ResourceNode.extract()
  amount → 0
    → visible = false
    → NavGrid.mark_resource(self, false)   # WOOD/GOLD only
```

`NavGrid` 引用：由 `MatchBootstrap` 创建后注入 match 根节点（如 `Match/NavGrid`），`ResourceNode` 通过 `get_tree().get_first_node_in_group("nav_grid")` 或 bootstrap 注册的 singleton 访问。

**与碰撞设计的关系：** 2026-08-08 碰撞 spec 仍规定资源**不参与** `CollisionResolver`（单位仍可物理挤过/贴近浆果丛）。寻路层单独维护资源挡路，两者职责分离。

## Non-Goals

- 对标 AoE2 原版的完整路径质量 / 群体流场
- 单位占位、排队、门洞开关
- 地形类型（水、悬崖、高度差）
- 3D `match_3d` 场景导航（本期仅 2D 主玩法）
- 投射物 / 远程弹道避障
- 运行时 Debug 可视化（可后续加 `@tool` 或 F3 叠加层）

## Architecture

```
command_move(target)
       │
       ▼
PathfindingService.find_path(from, to, radius) ──► PackedVector2Array waypoints
       │
       ▼
UnitAgent._path_waypoints / _path_index
       │
       ▼ 每帧
当前 waypoint ──► 直线步进 ──► CollisionResolver ──► sim_pos
       │
       ▼ 到达 waypoint
推进 _path_index；末点到达 → _finish_move()
```

### 模块职责

| 模块 | 文件（拟） | 职责 |
|------|-----------|------|
| `NavGrid` | `scripts/systems/nav_grid.gd` | 可通行位图；world↔cell 转换；按建筑/资源/边界标记 |
| `PathfindingService` | `scripts/systems/pathfinding_service.gd` | A* 搜索 + string pulling；对外 `find_path()` |
| `UnitAgent` | `scripts/entities/unit_agent.gd` | 维护 waypoint 队列；`_process_move` / `_move_toward` 改追 waypoint |
| `MatchBootstrap` / `CombatArenaBootstrap` | 现有 bootstrap | 初始化 `NavGrid` 边界；注册到 autoload 或 match 根节点 |
| `BuildingAgent` | `scripts/entities/building_agent.gd` | 施工开始 / 销毁时通知 `NavGrid` 增量更新 |
| `ResourceNode` | `scripts/entities/resource_node.gd` | footprint 常量；`extract()` 采空时通知 `NavGrid` 释放 |

### NavGrid

```text
NavGrid
  bounds: Rect2          # 逻辑世界 AABB，如 (-60,-60)-(60,60)
  cell_size: float = 1.0
  _blocked: PackedByteArray  # 0=walkable, 1=blocked（边界 + 建筑 + 树/矿）

  world_to_cell(pos: Vector2) -> Vector2i
  cell_to_world(cell: Vector2i) -> Vector2   # cell 中心点
  is_walkable(cell, unit_radius) -> bool     # 查询时再膨胀（见下）
  mark_building(building, blocked: bool)
  mark_resource(resource, blocked: bool)     # 仅 WOOD/GOLD；FOOD 跳过
  rebuild_from_scene(buildings, resources)   # 全量重建
```

**障碍膨胀（per-query）：**

- 与 `CollisionResolver._hits_building` 一致：`half = footprint/2 + Vector2(r, r)`
- 网格标记时，建筑占用的 cell 集合 = 膨胀 AABB 覆盖的所有 cell
- 不同 `collision_radius` 的单位查询同一张 base grid，但在 A* 邻居扩展时用 `unit_radius` 做边缘 clearance 检测（或对 base grid 做 morphological dilation，缓存 per-radius 位图——**Phase 2 优化**；Phase 1 直接在 A* 中检查圆心到最近建筑距离）

**Phase 1 简化：** 标记建筑时用 **全局最大半径**（如 1.0，覆盖 villager）膨胀，小单位路径略宽但实现简单。

### PathfindingService

```text
find_path(
  grid: NavGrid,
  from: Vector2,
  to: Vector2,
  unit_radius: float
) -> PackedVector2Array
```

流程：

1. `start_cell = grid.world_to_cell(from)`，`goal_cell = grid.world_to_cell(to)`
2. 若 goal 在 blocked 内，找 goal 邻域最近 walkable cell（BFS 一圈，半径 ≤ 3 cell）
3. **A\***（8 邻接，欧几里得启发式），代价 = 步长（对角 × √2）
4. 无路径 → 返回 `[to]`（退化为直线，与现行为兼容）
5. **String pulling**：从终点往回，若当前点与下一拐点之间直线无阻挡，跳过中间点
6. 输出 world 坐标 waypoint 列表（不含起点，含终点）

阻挡检测（string pulling / LOS）：沿线段采样（步长 0.5 cell），每点检查 `NavGrid.is_walkable` + 半径 clearance。

### UnitAgent 集成

新增字段：

```gdscript
var _path_waypoints: PackedVector2Array = []
var _path_index: int = 0
var _move_target: Vector2  # 最终目标（已有）
```

改动点：

| 方法 | 变更 |
|------|------|
| `command_move(target)` | 调用 `PathfindingService.find_path`，写入 `_path_waypoints`，`_path_index = 0` |
| `_process_move` | 当前追 `_current_steering_target()` = waypoints[index] 或 `_move_target` |
| `_move_toward(target)` | 短距订单（采集/建造/攻击）可选 **不寻路**（距离 < 8）或每次 `_request_path_to(target)` |
| `command_stop` | 清空 `_path_waypoints` |
| `_finish_move` | 清空路径状态 |

**Waypoint 推进：** 距当前 waypoint ≤ `ARRIVAL_DISTANCE`（0.15）时 `_path_index += 1`；末点到达后 `_finish_move()`。

**短距策略（采集/建造/攻击）：**

- 目标距离 ≤ `PATHFIND_MIN_DISTANCE`（建议 8.0）→ 不请求路径，保持直线（减少 A* 开销）
- 否则 `_request_path_to(intermediate)`，到达后切换交互逻辑

### 路径失效与重算

| 事件 | Phase 1 | Phase 2 |
|------|---------|---------|
| 新 `command_move` | 立即重算 | 同左 |
| 树/矿采空 | **立即** `NavGrid.mark_resource(false)` | 同左 |
| 建筑新建/销毁 | 不主动重算 | `NavGrid` 更新 + 对受影响单位 lazy 重算 |
| Stuck（无进展 10 帧） | 尝试一次重算；仍 stuck 则 `_finish_move` | 同左 |
| 目标移动中（追敌） | 不重算路径，直线 `_move_toward`（现逻辑） | 可选周期性重算 |

## Data Flow（与现有系统）

```
SelectionController.command_move
  → UnitAgent.command_move(target + formation_offset)   # 每单位独立路径
AiController.command_move / command_gather / command_build
  → 同上，AI 无感知变化
BuildSystem.can_place
  → 不变；NavGrid 独立维护
CollisionResolver
  → 不变；每帧 resolve_move 作为最后一步
MatchState.frozen
  → 停止移动与路径重算（已有）
```

**编队：** 每个单位仍带 `formation_offset` 各自寻路到不同终点；不引入群体流场。

## Edge Cases

| 情况 | 处理 |
|------|------|
| 目标点在墙内（点击建筑） | snap 到最近 walkable cell；到达外缘即 `_finish_move` |
| 完全不可达 | 返回空路径或仅 `[to]`；stuck 后放弃（与现 stuck 一致） |
| 路径中途新建建筑 | Phase 1 靠 CollisionResolver 滑墙；Phase 2 触发重算 |
| 单位出生在建筑内 | 首帧 `CollisionResolver` 推出；路径从推出位置开始 |
| villager radius=1.0 vs 士兵 0.35 | Phase 1 统一按 1.0 膨胀；Phase 2 per-radius |
| 浆果丛（FOOD） | 不标记，路径可穿过 |
| 树 / 金矿（WOOD/GOLD） | 按 footprint 标记 blocked，路径绕开 |
| 树/矿采空 | **同一帧**释放 cell，立即可通行；无树桩 |
| `is_placement_ghost` | 不在 `buildings` 组，不挡路 |
| 战斗测试场小地图 | bootstrap 传入较小 `NavGrid.bounds` |

## Performance Budget

| 指标 | 目标 |
|------|------|
| 网格规模 | 120×120 = 14,400 cells ≈ 14 KB |
| 单次 A* | < 1 ms（GDScript，typical 路径 < 80 cell） |
| 同帧批量移动 | 50 单位同时下单 → 分帧队列或每帧上限 10 次 A* |
| 内存 | 单 `NavGrid` 实例 per match |

**批量优化（可选）：** `PathfindingService` 维护请求队列，`process_path_requests(max_n)` 在 bootstrap `_process` 中调用，避免一帧卡顿。

## Testing

新建 `tests/test_pathfinding.gd`，挂入 `tests/run_tests.gd`：

1. 空地图直线 A→B → 1–2 个 waypoint  
2. 中间单建筑 → 路径绕开，不穿过 footprint  
3. 中间一棵树（WOOD）→ 路径绕开；浆果丛（FOOD）→ 路径可直线穿过  
4. 金矿（GOLD）→ 路径绕开  
5. 目标被包围 → 返回空或 snap 到最近可达点  
6. 地图边界外 → 不可通行  
7. String pulling → 路径无冗余共线中间点  
8. 树/矿采空后原 footprint 区域变为 walkable  

集成测试（`tests/test_locomotion.gd` 扩展或新文件）：

6. `UnitAgent.command_move` 绕 TC 到达对面  
7. 编队各单位到达不同 offset，不永久 stuck  
8. 村民绕树到达树后方的浆果丛（路径不穿树，可穿草丛）  

### Manual acceptance

- 村民右键城镇中心另一侧，绕墙而行而非贴墙停住  
- 右键树后方地面，单位绕树而行  
- 右键浆果丛，单位可穿过 bushes 直达采集  
- 砍倒树木或采空金矿后，单位可立即经原位置通行  
- 10+ 单位同时移动无明显帧尖刺  

## Implementation Phases

### Phase 1 — 核心绕障（MVP）

- [ ] `NavGrid` + 边界 + 从 `buildings` / `resource_nodes` 全量构建  
- [ ] `ResourceNode.extract()` 采空时同步释放 NavGrid cell  
- [ ] `PathfindingService` A* + string pulling  
- [ ] `UnitAgent.command_move` / `_process_move` waypoint 跟随  
- [ ] Bootstrap 初始化 grid  
- [ ] 单元测试 + 手动验收  

### Phase 2 — 动态与精细

- [x] 建筑施工/销毁增量更新 `NavGrid`  
- [x] Stuck 时 lazy 重算（采集/建造/移动）  
- [x] Per-unit radius clearance  
- [x] 分帧路径请求队列  

### Phase 3 — polish（可选）

- [ ] Debug 网格叠加层  
- [ ] 长距采集/建造也走寻路  
- [ ] 追敌周期性重算  

## File Touch List

| Path | Change |
|------|--------|
| `scripts/systems/nav_grid.gd` | 新建 |
| `scripts/systems/pathfinding_service.gd` | 新建 |
| `scripts/entities/unit_agent.gd` | waypoint 路径跟随 |
| `scripts/match/match_bootstrap.gd` | 创建/注入 NavGrid |
| `scripts/match/combat_arena_bootstrap.gd` | 小地图 NavGrid bounds |
| `scripts/entities/resource_node.gd` | footprint 常量；`extract()` 采空 → `NavGrid.mark_resource(false)` |
| `scripts/entities/building_agent.gd` | Phase 2：grid 增量更新 |
| `tests/test_pathfinding.gd` | 新建 |
| `tests/run_tests.gd` | 注册测试 |
| `docs/superpowers/plans/2026-08-10-pathfinding.md` | 实施计划（review 通过后写） |

## Open Questions

1. **Autoload vs Match 子节点：** `NavGrid` 挂 `Match/NavGrid` 还是 `PathfindingService` autoload？建议 match 子节点，便于多场景不同 bounds。  
2. **cell_size 0.5 vs 1.0：** 1.0 先上线；若贴墙路径太粗再降到 0.5。  
3. **追敌是否寻路：** 默认否（AoE2 追敌多为直线）；可配置。  

## Relation to Collision Design

```
┌─────────────────────────────────────────┐
│  Pathfinding (global, grid A*)          │  ← 新增：决定「走哪条路」
├─────────────────────────────────────────┤
│  UnitAgent step (straight to waypoint)  │  ← 已有：每帧迈一步
├─────────────────────────────────────────┤
│  CollisionResolver (local fix)          │  ← 已有：滑墙 / 软分离
└─────────────────────────────────────────┘
```

碰撞设计文档中的「不做寻路」条目在实现本设计后应标注为 **superseded**。
