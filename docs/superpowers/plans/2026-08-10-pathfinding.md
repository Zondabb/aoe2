# Pathfinding System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 RTS 单位增加网格 A* 寻路，绕开建筑与树/矿，保留 CollisionResolver 局部修正。

**Architecture:** `NavGrid`（Node，`nav_grid` 组）维护 blocked 位图；`PathfindingService`（RefCounted）提供 A* + string pulling；`UnitAgent.command_move` 写入 waypoint 队列；`ResourceNode.extract()` 采空时重建资源层。

**Tech Stack:** Godot 4.7 GDScript，`sim_pos` 逻辑坐标，cell_size=1.0，膨胀半径 1.0

## Global Constraints

- 算法：网格 A*，8 邻接，欧几里得启发式
- 树/矿（WOOD/GOLD）挡路；FOOD 可通行；采空同一帧释放
- 单位不参与寻路网格；CollisionResolver 每帧仍运行
- match 边界 ±60，arena ±40
- 测试：`godot --headless -s res://tests/run_tests.gd`

---

### Task 1: NavGrid

**Files:**
- Create: `scripts/systems/nav_grid.gd`
- Test: `tests/test_pathfinding.gd`

**Interfaces:**
- Produces: `NavGrid.setup(bounds)`, `rebuild(buildings, resources)`, `rebuild_resources(resources)`, `is_walkable_cell(cell)`, `world_to_cell`, `cell_to_world`

### Task 2: PathfindingService

**Files:**
- Create: `scripts/systems/pathfinding_service.gd`
- Test: `tests/test_pathfinding.gd`

**Interfaces:**
- Consumes: `NavGrid`
- Produces: `PathfindingService.find_path(grid, from, to, unit_radius) -> PackedVector2Array`

### Task 3: ResourceNode + Bootstrap

**Files:**
- Modify: `scripts/entities/resource_node.gd`
- Modify: `scripts/match/match_bootstrap.gd`
- Modify: `scripts/match/combat_arena_bootstrap.gd`

### Task 4: UnitAgent waypoint 跟随

**Files:**
- Modify: `scripts/entities/unit_agent.gd`

### Task 5: Phase 2 — dynamic grid, radius, queue

**Files:**
- Modify: `scripts/systems/nav_grid.gd`, `pathfinding_service.gd`
- Modify: `scripts/entities/building_agent.gd`, `unit_agent.gd`
- Test: `tests/test_pathfinding.gd`

**Done:**
- Building placed/destroyed → `mark_building` / `rebuild_buildings`
- `navigation_map_changed` → units repath
- Per-unit `unit_radius` in A* / LOS
- `queue_path_request` max 10/frame
