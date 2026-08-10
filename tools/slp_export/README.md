# SLP / DRS export toolchain

Offline Python tools to convert Age of Empires II HD SLP graphics into PNG
sprite sheets for the Godot demo. Runtime never reads DRS/SLP.

## Prerequisites

- Python 3.10+
- Pillow, pytest: `pip install -r requirements.txt`
- Local AoE2 HD `resources` tree (not committed)

Default path (see `config.example.json`):

```text
D:/BaiduNetdiskDownload/gaoqingban2/gaoqingban2/resources
```

Copy the example config if you need a different path:

```powershell
Copy-Item config.example.json config.json
```

`config.json` is gitignored.

## Layout (HD)

This install already unpacks DRS archives into folders:

| Path | Contents |
|------|----------|
| `_common/drs/graphics/{id}.slp` | Units, buildings, resources |
| `_common/drs/interface/{id}.slp` / `.bina` | UI + palettes (`50500.bina` = main JASC-PAL) |
| `_common/dat/pal_*.pal`, `clf_pal.pal` | Tree / cliff palettes |
| `_common/slp/*.slp` | Loose UI SLPs |

`drs.py` also understands classic packed `.drs` archives if you point at one.

## Commands

From `tools/slp_export`:

```powershell
# Palette tests (set AOE2_RES to override)
$env:AOE2_RES = "D:\BaiduNetdiskDownload\gaoqingban2\gaoqingban2\resources"
pytest tests/test_palette.py -q

# Smoke-export one SLP -> assets/sprites/_smoke/
python export_sprites.py --smoke

# Priority demo list -> assets/sprites/{units,buildings,resources}/
python export_sprites.py --priority

# UI panel + icon sheets -> assets/sprites/ui/
python export_sprites.py --ui

# Default: smoke + priority
python export_sprites.py

# Single id
python export_sprites.py --id 1484 --key villager_walk --category units --directions 5
```

Outputs:

- `{key}.png` — packed sheet
- `{key}.json` — `{cols, rows, frame_w, frame_h, directions, hotspots, ...}`
- `export_report.json` — success / missing summary (priority export)
- `ui_export_report.json` — success / missing summary (UI export)

### UI sheets (`--ui`)

| Key | SLP ID | Notes |
|-----|--------|-------|
| panel_game | 51141 | Large game panel strip |
| icons_units | 50730 | Unit icons |
| icons_buildings | 50705 | Building icons |
| icons_commands | 50721 | Command icons |

Outputs land in `assets/sprites/ui/` with `directions: 1`.

### Unit directions + flip

Classic AoE unit SLPs store **5 authored facings** (frame counts like 50/60/75 divide by 5, not 8). Runtime covers the other three by **horizontal flip** of the mirrored authored dir. JSON `directions` is therefore `5` for unit walks; `frames_per_direction = frame_count / 5`.

`hotspots` in the JSON are **cell-relative** (after sheet packing: centered X, bottom-aligned Y inside `frame_w`×`frame_h`), so atlas sampling can anchor directly against the sheet cell.

## Discovered priority IDs

| Key | SLP ID | Notes |
|-----|--------|-------|
| villager_walk | 1484 | Male villager moving |
| villager_idle | 1479 | Male villager standing |
| villager_gather_food | 2589 | Male villager kneeling picking berries |
| villager_chop | 1535 | Male villager woodcutter chopping |
| villager_mine | 1560 | Male villager miner mining |
| villager_build | 1496 | Male villager builder kneeling |
| militia_walk | 997 | Basic melee stand-in |
| swordsman_walk | 604 | ROR swordsman moving |
| archer_walk | 12 | Archer moving |
| chu_ko_nu_walk | 225 | Chinese unique |
| teutonic_knight_walk | 1198 | Teuton unique |
| tc_dark_main | 891 | Single TC layer (not full multi-part TC) |
| tc_asian_feudal_top | 901 | Asian feudal TC top |
| house_dark | 2223 | Dark Age houses |
| house_asian_feudal | 2233 | Asian feudal houses |
| barracks_asian_feudal | 131 | |
| archery_asian_feudal | 22 | |
| stable_asian_feudal | 1007 | Chinese-facing set |
| stable_ne_feudal | 1006 | Teuton-facing set |
| tree_oak | 1251 | Uses `pal_2.pal` |
| gold_mine | 4479 | |
| berry_bush | 2560 | Food source |

IDs sourced from the openage AoC SLP list and verified present under
`_common/drs/graphics/`.

## Placeholders / limits

- Town Centers are multi-SLP layers in the original game; we export representative tops only.
- Unit sheets: 5 authored dirs + flip (see above); buildings/resources use `directions: 1`.
- Player-color pixels remapped for player 1 (blue band); shadow pixels approximated.
- Do not commit the full game tree — only tools + small converted PNGs.

## Modules

| File | API |
|------|-----|
| `palette.py` | `load_pal(path) -> list[(r,g,b,a)]` |
| `drs.py` | `extract(drs_path, file_id or name) -> bytes` |
| `slp.py` | `decode(bytes, palette) -> list[Image]` |
| `export_sprites.py` | CLI entry |

See `../../assets/ATTRIBUTION.txt` for copyright notice.
