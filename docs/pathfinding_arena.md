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
| **G** | Toggle solid cells, paths, **vision rings**, sight links; **prints vision query time** to console |
| WASD / edge | Pan camera |
| Wheel | Zoom |

## Vision

- Each unit has configurable vision via `UnitDef.vision_radius` or per-instance `vision_radius_override`
- Arena assigns radii cycling through **4 / 6 / 8 / 10 / 12** sim tiles
- Left group = Player, right group = AI (so cross-team sightings show up)
- **G** draws isometric vision ellipses and yellow lines to entities currently in range
- Console prints total µs/ms for scanning all units, plus a few per-unit samples

## What is blocked

Square logical footprints baked into `NavGridService`:

- Houses (building footprints)
- Gold ore (`PathBlocker` 2×2)
- Water shallows (AoE2 SLP 1885)
- Cliff sections (AoE2 SLP 229 / 230)

Units are **not** baked into the nav grid. Vision uses `VisionService` / `SpatialHash` (cell size 2).
