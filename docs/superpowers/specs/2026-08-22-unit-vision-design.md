# Unit Vision + Spatial Enemy Query Design

**Date:** 2026-08-22  
**Engine:** Godot 4.7  
**Status:** Implemented (Phase 1)

## Goal

为单位增加**视野半径**，并用**均匀网格空间哈希**高效查询视野内的敌对单位/建筑，替代对全图实体的线性扫描。为后续雾战、`blackboard.enemy_visible`、侦察 AI 提供同一套索引。

## Context（现状）

| 已有 | 缺失 |
|------|------|
| `sim_pos` 逻辑坐标 | `UnitDef.vision_radius` |
| `AiEntityQueries.nearest_hostile_in_radius` 全表扫 | O(视野邻域) 查询 |
| AI `retarget_radius` / 竞技场 `aggro_radius` | 与单位视野解耦的空间索引 |
| `NavGridService` 静态障碍格 | 动态单位位置格（不可混用） |
| AI 设计 Phase 2：`enemy_visible` | 可见目标写入入口 |

当前 `nearest_hostile_in_radius` 对 `entities` 每个子节点做 `distance_squared`。单位少时可用；单位/建筑增多后，每帧/每 tick 全扫会浪费。

## Decisions Locked

| 项 | 选择 |
|---|---|
| 空间结构 | **均匀网格哈希**（`SpatialHash`），不用四叉树 |
| 格子大小 | `cell_size = 2.0` 逻辑单位（与 nav `1.0` 对齐坐标系，但独立实例） |
| 索引对象 | 可受伤实体：`units` + `buildings`（`take_damage` + `hp > 0`） |
| 不索引 | 资源点、放置幽灵、投射物 |
| 坐标 | 全程 `sim_pos`（Vector2 xz） |
| 视野数据 | `UnitDef.vision_radius`（默认 **8.0**）；实例可设 `UnitAgent.vision_radius_override` |
| 查询判定 | `distance_squared <= R²`；先扫邻格再精确距离 |
| 敌人定义 | `team != observer.team`，`hp > 0`，非 ghost |
| 寻路关系 | **不**把单位写入 `NavGrid`；视野与 A* 分离 |
| 无服务时 | `AiEntityQueries` 回退全表扫（测试/无 bootstrap 场景） |
| 实现层 | `RefCounted` + `VisionServiceHolder` Node（对标 `NavServiceHolder`） |

## Non-Goals（Phase 1）

- 战争迷雾 / 队伍共享可见遮罩绘制
- 视线遮挡（墙后看不见）
- `ScoutManager` 与 `blackboard.enemy_visible` 完整 AI（仅提供查询 API）
- 建筑自身视野（塔楼后续可用同一套哈希）
- Godot `Area2D` / 物理探测

## Architecture

```text
UnitDef.vision_radius
        │
UnitAgent / BuildingAgent
  register / sync_position / unregister
        │
VisionServiceHolder (group: vision_service)
        │ owns
VisionService
        │ owns
SpatialHash  (cell → entity list)
        │
AiEntityQueries.nearest_hostile_in_radius
AutoCombatDirector.pick_target_for_unit   (可选走哈希邻域)
```

### SpatialHash

```gdscript
class_name SpatialHash
extends RefCounted

func setup(cell_size: float = 2.0) -> void
func clear() -> void
func insert(entity: Object, pos: Vector2) -> void
func remove(entity: Object) -> void
func move(entity: Object, pos: Vector2) -> void
func query_radius(center: Vector2, radius: float) -> Array
func world_to_cell(world: Vector2) -> Vector2i
```

- `_buckets: Dictionary` 键为 `Vector2i`，值为实体数组  
- `_entity_cell: Dictionary` 以 `instance_id` 跟踪所在格，移动时仅在跨格时更新  
- `query_radius`：覆盖 `[center ± radius]` 的格子矩形，再过滤距离

### VisionService

```gdscript
class_name VisionService
extends RefCounted

func setup(cell_size: float = 2.0) -> void
func register(entity: Object) -> void
func unregister(entity: Object) -> void
func sync_position(entity: Object) -> void
func rebuild_from_tree(tree: SceneTree) -> void

func vision_radius_of(observer: Object) -> float
func hostiles_in_radius(observer, enemy_team, radius := -1.0) -> Array
func nearest_hostile(observer, enemy_team, radius := -1.0) -> Node2D
```

- `radius < 0` → 使用 `vision_radius_of(observer)`  
- 建筑观察者若无 `vision_radius`，用默认 8.0（Phase 1 主要为单位服务）

### VisionServiceHolder

- `group: "vision_service"`，`meta "vision"` → `VisionService`  
- `setup` / `rebuild_from_scene`  
- `node_added` 延迟注册新单位/建筑  
- Match / AI / 竞技场 bootstrap 与 `NavService` 一并创建

## Data

### UnitDef

```gdscript
@export var vision_radius: float = 8.0

func resolved_vision_radius() -> float:
    if vision_radius > 0.0:
        return vision_radius
    return 8.0
```

建议默认值（可在 `.tres` 覆盖）：

| 单位 | vision_radius | 说明 |
|------|---------------|------|
| villager | 8.0 | 与 AI retarget 同量级 |
| swordsman / knight | 8.0 | |
| archer / chu_ko_nu | 10.0 | 略远，仍小于竞技场 aggro 40 |

## Integration

| 位置 | 行为 |
|------|------|
| `UnitAgent._ready` | `register` |
| `UnitAgent._exit_tree` | `unregister` |
| `UnitAgent._apply_resolved_position` | `sim_pos` 写入后 `sync_position` |
| `BuildingAgent._ready`（非 ghost） | `register` |
| `BuildingAgent` 销毁/退出 | `unregister` |
| `AiEntityQueries.nearest_hostile_in_radius` | 有 `vision_service` 则哈希查询，否则线性 |
| Bootstrap | 创建 `VisionServiceHolder` 并 `rebuild_from_scene` |

## Performance

| 指标 | 目标 |
|------|------|
| 单次查询 | 扫 `(2⌈R/CELL⌉+1)²` 格内实体，而非全图 N |
| 移动更新 | 仅跨格时改 bucket（同格 noop） |
| 节流（可选后续） | 空闲单位每 5–10 帧才扫视野；ATTACK 可更勤 |

百级单位时，哈希查询相对全扫优势明显；&lt;80 单位时正确性优先，回退扫描也可接受。

## Testing

`tests/test_spatial_hash.gd` / `tests/test_vision_service.gd`：

1. insert/move 跨格后旧格无实体、新格有实体  
2. `query_radius` 只返回圆内实体  
3. `nearest_hostile` 忽略同队、ghost、hp≤0  
4. `radius` 默认取 `UnitDef.vision_radius`  
5. 无 holder 时 `AiEntityQueries` 线性路径仍可用  

## Implementation Phases

### Phase 1 — 本规格

- [x] 设计文档  
- [x] `SpatialHash` + `VisionService` + `VisionServiceHolder`  
- [x] `UnitDef.vision_radius`  
- [x] 单位/建筑注册与位置同步  
- [x] `AiEntityQueries` / 相关调用接哈希  
- [x] Headless 测试  

### Phase 2 — AI / 雾战（后续）

- [ ] `ScoutManager` 写入 `blackboard.enemy_visible`  
- [ ] CombatManager 优先攻击可见列表  
- [ ] 队伍共享迷雾绘制  
- [ ] 空闲视野节流  

## Manual acceptance

- 正式局 / AI vs AI：敌方进入某单位 `vision_radius` 后，AI 重锁定能找到该敌人  
- 人堆重叠时查询不崩溃、不漏注册  
- 单位死亡/出树后不再被查到  
- 无 VisionService 的旧测试场景仍通过（线性回退）
