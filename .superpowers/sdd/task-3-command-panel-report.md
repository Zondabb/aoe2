# Task 3 Report: HUD CommandPanel scene + controller wiring

## Status

**DONE** (uncommitted)

## Summary

Added AoE2-style bottom `CommandPanel` to `hud.tscn` with info column (portrait, name, HP bar, count) and dynamic `CommandGrid`. Rewired `HudController` to refresh info and rebuild build/train/stop buttons on selection change. Hidden legacy `BuildPanel` / `TrainPanel` (nodes kept for unique names).

## Files Changed

| File | Change |
|------|--------|
| `scenes/ui/hud.tscn` | Bottom CommandPanel layout; hide old build/train strips |
| `scripts/ui/hud_controller.gd` | Info refresh, command grid, stop/build/train wiring |
| `tests/test_command_panel.gd` | panel_texture + villager grid tests |
| `tests/test_match_2d.gd` | TrainPanel → CommandGrid assertion |
| `assets/sprites/ui/*.import` | Generated via Godot import for headless texture load |

## Test Command & Result

```powershell
& "D:\Users\jiangzw\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64.exe" --headless --path "D:\Users\jiangzw\workspace\godot_game\aoe2" -s res://tests/run_tests.gd
```

```
ALL TESTS PASSED
```

## Manual Checklist (Task 4)

- [ ] F5 → select villager → bottom shows name/HP + build/stop icons
- [ ] Select TC → train villager from panel
- [ ] Move units → Stop cancels walk
- [ ] Empty selection clears panel
- [ ] Tune `FRAME_*` indices in `ui_catalog.gd` after visual check

## Concerns

- Icon frame indices still provisional (Task 4)
- UI `.import` files should be committed with Task 3
- `panel_game` strip may need crop/scale tuning in-editor
