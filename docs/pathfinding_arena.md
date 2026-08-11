# Pathfinding Arena

Standalone scene to exercise grid A* with dozens of units.

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
| **G** | Toggle solid-cell footprint overlay **and unit path lines** |
| WASD / edge | Pan camera |
| Wheel | Zoom |

## What is blocked

Square logical footprints baked into `NavGridService`:

- Houses (building footprints)
- Gold ore (`PathBlocker` 2×2)
- Water shallows (AoE2 SLP 1885)
- Cliff sections (AoE2 SLP 229 / 230)

Units soft-separate; they are **not** baked into the nav grid. Path requests are budgeted (~16 / frame) so many simultaneous movers stay smooth.
