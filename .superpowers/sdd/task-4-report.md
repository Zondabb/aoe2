# Task 4 Report — Icon frame mapping

## Done

- Updated `FRAME_*` constants in `ui_catalog.gd` after visual inspection of exported sheets.
- Added `unit_icon_frame(unit_id)` for train buttons and unit portraits.
- Wired `hud_controller.gd` train slots and info portrait to unit-specific frames.
- Extended `test_command_panel.gd` with atlas non-null and unit frame mapping checks.
- Added `assets/sprites/ui/README.md` with frame index table.

## Key frame choices

| Target | Frame | Rationale |
|--------|-------|-----------|
| Stop | commands 0 | Red X confirmed |
| House | buildings 34 | Western EU house |
| Barracks | buildings 2 | Crossed swords |
| Archery | buildings 0 | Bow |
| Stable | buildings 24 | Horseshoe build glyph |
| Mill | buildings 20 | Windmill |
| Lumber Camp | buildings 41 | Shed + logs (not frame 40 repair hammer) |
| Mining Camp | buildings 39 | Pickaxe + stone |
| Villager | units 15 | Male villager |
| Archer | units 17 | Bow + quiver |
| Swordsman | units 12 | Sword infantry |
| Chu Ko Nu | units 44 | Repeating crossbow |
| Teutonic Knight | units 8 | Armored knight |

## Manual checklist (F5)

1. Civ select → match
2. Select villager → build icons + stop; house/mill/lumber/mining look correct
3. Chinese civ → stable horseshoe appears in build row
4. Select TC → train villager shows villager icon
5. Select barracks/archery → train buttons show unit icons
6. Move units → Stop clears walk
7. Empty selection → info/commands clear

## Tests

Headless: `Godot --headless --path . -s res://tests/run_tests.gd`
