# Unit Collision Volume Design

**Date:** 2026-08-08  
**Engine:** Godot 4.7  
**Status:** Approved for planning  

## Goal

为人物单位增加逻辑碰撞体积：单位之间软分离、单位与建筑硬阻挡；不引入完整寻路。

## Decisions Locked

| 项 | 选择 |
|---|---|
| 单位↔单位 | 软分离（重叠时只挪自己，按重叠深度的一部分推开） |
| 单位↔建筑 | 硬挡（圆 vs footprint AABB；沿边滑动或停下） |
| 绕障 | 不寻路：直线移动 + 滑墙/停下 |
| 实现层 | 仿真层解析碰撞（逻辑 `sim_pos`），不用 Godot 物理体 |
| 坐标 | 仅在逻辑 xz（`sim_pos`）上计算；`IsoMath` 只负责显示 |
| 资源点 | 本期不挡路 |

## Non-Goals

- 网格 A* / 完整绕建筑寻路
- `CharacterBody2D` / 物理引擎驱动单位
- 改点选像素半径、选中环、采集/攻击距离公式
- 资源节点（树/矿）碰撞
- Debug 碰撞可视化（可后续加）

## Data

- `UnitDef` 新增 `@export var collision_radius: float = 0.35`（逻辑世界单位）
- 建筑继续使用 `BuildingDef.footprint`（中心 + half extents），约定与 `BuildSystem.can_place` 一致
- 所有在 `buildings` 组且带 footprint 的建筑（含未建成）均挡路

## Architecture

新建 `scripts/systems/collision_resolver.gd`（`class_name CollisionResolver`，`RefCounted`）。

### API

```text
resolve_move(unit, desired_pos, units, buildings) -> Vector2
```

返回校正后的逻辑位置。

### Resolve order

1. **建筑硬挡**：圆 `(desired_pos, r)` 与各建筑 AABB。重叠则推出到最近外表面；尽量保留切向滑动分量；推不出则沿最短分离轴推出。
2. **单位软挤**：对附近其他单位做圆-圆检测。重叠时沿分离轴只移动自己，位移 ≈ `overlap * 0.5`。忽略自己与无效节点；距离剪枝（例如 > 3.0 跳过）。
3. 多障碍时对建筑结果最多再迭代 2–3 次，避免角落穿透。

### Integration

唯一写 `sim_pos` 的移动路径：

- `UnitAgent._process_move`
- `UnitAgent._move_toward`
- 到达吸附（`sim_pos = _move_target`）也必须经 resolver，避免吸进墙内

查询：`get_tree().get_nodes_in_group("units")` / `"buildings"`。

## Edge Cases

- 出生/训练点若落在建筑内：首次移动时推出；不强制开局重排全部单位
- 敌我单位同样软挤（不区分阵营）
- 攻击/采集交互距离逻辑不变；单位可能站在建筑外缘而距建筑中心偏远——可接受
- 资源点本期不参与碰撞

## Testing

`tests/test_collision_resolver.gd`，挂入 `tests/run_tests.gd`：

1. 圆撞建筑 AABB → 结果在盒外，不穿透  
2. 两单位重叠 → 自己被推开，重叠减小  
3. 斜向撞墙 → 不进墙，尽量保留切向分量  

### Manual acceptance

- 村民撞 TC/房屋会停或滑边，不穿模  
- 一群村民挤在一起会略微散开，仍可挤过  
- 正面撞墙可能停住（无绕路属预期）

## File touch list

| Path | Change |
|------|--------|
| `scripts/data/unit_def.gd` | 增加 `collision_radius` |
| `data/units/*.tres` | 可选显式半径；缺省用 0.35 |
| `scripts/systems/collision_resolver.gd` | 新建解析器 |
| `scripts/entities/unit_agent.gd` | 移动后调用 resolver |
| `tests/test_collision_resolver.gd` | 新建单元测试 |
| `tests/run_tests.gd` | 注册测试 |

## Out of scope follow-ups

- 简易侧向绕障或网格 A*
- 资源 footprint
- 碰撞 debug 绘制
