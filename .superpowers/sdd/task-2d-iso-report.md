# Task Report: True 2D Isometric Battlefield

**Date:** 2026-08-06  
**Status:** Done  

## Summary

Ported the AoE2 RTS demo battlefield from `Node3D` + `Sprite3D` billboards to a true 2D isometric scene using `Node2D`, `Camera2D`, and `AnimatedSprite2D` / `Sprite2D`, with logical simulation on a Vector2 (x, z) plane and presentation via `IsoMath`.

## Deliverables

| Item | Path |
|---|---|
| Main battlefield | `scenes/match_2d.tscn` |
| Camera | `scripts/input/rts_camera_2d.gd` |
| Selection | `scripts/input/selection_controller_2d.gd` |
| Iso math (existing) | `scripts/presentation/iso_math.gd` |
| Report | `.superpowers/sdd/task-2d-iso-report.md` |

`scenes/match_3d.tscn` remains in the repo unused. Civ select now opens `match_2d.tscn`.

## Key changes

- **Entities:** `UnitAgent`, `BuildingAgent`, `ResourceNode` extend `Node2D`; `sim_pos: Vector2` drives logic; `IsoMath.sync_node` updates screen position.
- **Sprites:** `SpriteCatalog.configure_sprite_2d` / `ensure_ground_shadow_2d` / `offset_for_hotspot_2d`; entity scenes use 2D Billboard + Polygon2D selection rings.
- **Input:** Screen-space pick by distance to `global_position`; empty RMB uses `screen_to_world` through canvas transform.
- **Systems:** Build / Gather / AI / Bootstrap use Vector2 logical coords and Node2D roots; Entities enable `y_sort`.
- **Ground:** Bootstrap tiles `assets/terrain/grass.png` across logical −60..60.
- **Tests:** `test_match_2d.gd` replaces `test_match_3d.gd`; Vector3 assertions → Vector2 / `sim_pos`.

## Verification

```
Godot_v4.7.1-stable_win64.exe --path ... --headless -s res://tests/run_tests.gd
→ ALL TESTS PASSED
```

## Concerns

- Placeholder `Body` sprites remain as fallback when sheets are missing; visual polish may need per-building scale tuning.
- `match_3d` paths/scripts are stale relative to the 2D entities and will not run as a coherent match without a separate 3D port restore.
- Control HUD/selection under a `Node2D` root relies on Godot canvas mixing; acceptable for this demo but a `CanvasLayer` split would be cleaner later.
