# Pathfinding Arena

Standalone scene to exercise grid A* with dozens of units, plus vision rings.

## Run

Open `scenes/pathfinding_arena.tscn` and press **F6** (Run Current Scene).

Or:

```powershell
& "D:\Program Files\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe" `
  --path "E:\jiangzhiwen\workspace\cursor\aoe2" `
  res://scenes/pathfinding_arena.tscn
```

## Controls

| Input | Action |
|-------|--------|
| LMB drag | Box-select units |
| RMB | Move selected units (formation + A* paths) |
| **Debug panel** (top-left) | Checkboxes: nav grid, solids, paths, vision, arrows, timing log |
| **G** | Toggle all debug layers |
| **N** | Nav grid lines |
| **B** | Solid blocked cells |
| **P** | Unit path polylines |
| **V** | Vision rings + sight links |
| **A** | Move steer arrows |
| **T** | Vision query timing to console |
| WASD / edge | Pan camera |
| Wheel | Zoom |

## Vision

- Each unit has configurable vision via `UnitDef.vision_radius` or per-instance `vision_radius_override`
- Arena assigns radii cycling through **4 / 6 / 8 / 10 / 12** sim tiles
- Left group = Player, right group = AI (so cross-team sightings show up)
- Enable **Vision range** in the debug panel (or **V**) for isometric rings and yellow sight links
- Enable **Vision timing log** (or **T**) to print µs/ms to the console

## What is blocked

Square logical footprints baked into `NavGridService`:

- Houses (building footprints)
- Gold ore (`PathBlocker` 2×2)
- Water shallows (AoE2 SLP 1885)
- Cliff sections (AoE2 SLP 229 / 230)

Units are **not** baked into the nav grid. Vision uses `VisionService` / `SpatialHash` (cell size 2).

Moving units use predictive local avoidance and swept collision checks. Recovery
paths can temporarily account for nearby units through the budgeted path queue.
See [多单位寻路、避让与碰撞优化](crowd_movement.md) for the implementation and regression results.
