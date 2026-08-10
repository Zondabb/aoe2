# UI sprite sheets

Exported from AoE2 HD SLP sheets (51141 panel, 50730 units, 50705 buildings, 50721 commands).
Each sheet has a companion `.json` with `cols`, `frame_w`, and `frame_h` for `UiCatalog.atlas_frame()`.

## Frame index reference

| Use | Sheet | Frame | Notes |
|-----|-------|-------|-------|
| Stop | `icons_commands` | 0 | Red X |
| House | `icons_buildings` | 34 | Western European house |
| Barracks | `icons_buildings` | 2 | Crossed swords |
| Archery Range | `icons_buildings` | 0 | Bow |
| Stable | `icons_buildings` | 24 | Horseshoe (build-menu glyph) |
| Mill | `icons_buildings` | 20 | Windmill |
| Lumber Camp | `icons_buildings` | 41 | Shed with log pile |
| Mining Camp | `icons_buildings` | 39 | Pickaxe + stone |
| Villager | `icons_units` | 15 | |
| Archer | `icons_units` | 17 | |
| Swordsman | `icons_units` | 12 | |
| Chu Ko Nu | `icons_units` | 44 | |
| Teutonic Knight | `icons_units` | 8 | |

Frame 40 in `icons_buildings` is a repair hammer, not Lumber Camp (wiki icon IDs do not match sheet order).

Mappings live in `scripts/presentation/ui_catalog.gd`.
