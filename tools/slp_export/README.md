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

Player colors now use one original atlas plus a semantic index/weight mask,
with a shared 16x8 palette. Godot's player-color shader recolors only SLP player
pixels; it does not need one atlas per team. To rebuild only the game units and
buildings, from the repository root run:

```powershell
python tools/slp_export/regenerate_all.py --team-masks
python -m pytest tools/slp_export/tests -q
```

The configured `player_color` remains the original atlas's baked source color;
it is recorded in JSON as `player_color.source_player`. This is independent of
the match's blue/red defaults. Each colored sheet writes `_player_mask.png`:
R byte = shade + 1 (zero means ordinary artwork), G byte = player contribution
to straight RGB, B = 0. Data imports are lossless, nearest-sampled, without
mipmaps or alpha-border processing. `player_palette.png` is shared by all teams.
Uncolored sheets declare `mode: none`. Town Center masks follow the same layer
offsets and preserve attenuation by overlaid shadows. Ordinary palette-colored
pixels are never inferred to be player pixels from their RGB value.

The regular exporters also maintain this metadata, so rebuilding a sheet with
another source player does not invalidate its shader. `--team-masks` excludes
UI, terrain and enlarged previews. The full rebuild keeps enlarged preview
masks aligned using the original image's Scale2x pixel choices.

See [the shader design](../../docs/superpowers/specs/2026-09-21-team-color-shader-design.md)
for runtime integration, limitations and GPU verification commands.

From `tools/slp_export`:

```powershell
# Rebuild all project SLP sheets and existing archer previews using config player_color
python regenerate_all.py
# Optional: override player color (1 = blue)
python regenerate_all.py --player 1

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

# Bake Asian feudal Town Center layers into one PNG
python export_sprites.py --composite-tc
```

Outputs:

- `{key}.png` — packed sheet
- `{key}.json` — `{cols, rows, frame_w, frame_h, directions, hotspots, ...}`
- `export_report.json` — success / missing summary (priority export)
- `ui_export_report.json` — success / missing summary (UI export)
- `regenerate_report.json` — full rebuild summary, including extra sheets and derived previews

`regenerate_all.py` covers priority, combat, UI, existing extra SLP manifests,
and the existing archer 1x/Scale2x 4x previews and individual frames. It does not
recreate the standalone ground textures, which are outside the SLP pipeline.
`import_terrain.py` copies original HD grass/water/beach/shallows/rock PNGs unchanged
and records their paths and hashes in `assets/terrain/terrain_sources.json`.
Run `python tools/slp_export/import_terrain.py` from the repository root to rebuild
them. The pale sand uses `g_bc3_00_color.png`, terrain 53 **Beach 4** in the local
HD expansion DAT; the shallow rim uses `g_sh2_00_color.png`, terrain 59
**Shallows**. Both source terrain IDs, original names and DAT hash are recorded.
`g_snd` is **Snow Dirt**, so it is not used as sand. The imported files retain
their original 512×512 pixels. Godot enables mipmaps for grass, water, beach and
shallows; the shared ground renderer samples world coordinates so adjoining
regions retain the same texture phase and density.

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
| tc_dark_main | 891 | Dark Age TC (single layer) |
| tc_asian_feudal | composite | Asian feudal TC (layers 893/901/3598/3602/3606/4614/4618/4622 baked into one PNG) |
| house_dark | 2223 | Dark Age houses |
| house_asian_feudal | 2233 | Asian feudal houses |
| barracks_asian_feudal | 131 | |
| archery_asian_feudal | 22 | |
| stable_asian_feudal | 1007 | Chinese-facing set |
| stable_ne_feudal | 1006 | Teuton-facing set |
| tree_oak | 1251 | Uses the main `50500.bina` palette; `pal_2.pal` produces incorrect foliage colors |
| gold_mine | 4479 | |
| berry_bush | 2560 | Food source |
| water_shallow | 1885 | Water shallows tiles |
| cliff_main | 226 | Cliffs |
| cliff_section | 229 | Cliff section |
| cliff_section_b | 230 | Cliff section B |

IDs sourced from the openage AoC SLP list and verified present under
`_common/drs/graphics/`.

## Chinese / Teutons land catalog and four ages

`import_civilizations.py` is the separate DAT-driven importer for the playable
Chinese and Teutons land roster. It imports original names, costs, base
attributes, training/research locations, civilization restrictions, upgrade
links and graphics. The existing `regenerate_all.py` priority-sheet workflow
does not replace this catalog import.

The current checked-in source is HD `empires2_x1_p1.dat`, `VER 5.7`:
41 unit definitions, 25 building definitions and 26 research definitions.
Counts include upgraded forms and exclude navy, heroes and scenario objects.
Age research has its own `ages` section. These are local HD values, not current
Definitive Edition balance data. See the Chinese
[gameplay and implementation guide](../../docs/civilizations_and_ages.md).

### Dependencies and command

In addition to this directory's `requirements.txt`, provide an `openage` source
checkout whose DAT reader supports HD. `--openage` is the source root containing
the Python `openage/` package, not the outer workspace or virtual environment.
The parser imports the Python reader directly; it does not need a built openage
game executable. Use the Python environment in which openage's reader
dependencies are available.

Run from the Godot repository root:

```powershell
# Install this exporter's dependencies into the selected Python environment.
python -m pip install -r tools/slp_export/requirements.txt

python tools/slp_export/import_civilizations.py `
  --openage "D:/Users/jiangzw/workspace/openage_workspace/openage" `
  --resources "D:/BaiduNetdiskDownload/gaoqingban2/gaoqingban2/resources"
```

`--resources` can be omitted to use `aoe2_resources` from the usual tool config.
The importer requires the local English and Chinese UTF-8 language files as
well as the DAT and graphics. It reads the original installation without
modifying it. It writes the following project files:

| Output | Contents |
| --- | --- |
| `data/civilization_catalog.json` | Formatted UTF-8 catalog, DAT SHA-256 and original source IDs |
| `assets/sprites/civilizations/g<graphic_id>_anim.*` | Unit animation atlases, hotspots, frame/direction metadata and player masks |
| `assets/sprites/civilizations/g<graphic_id>_static.*` | Building/resource graphic composites and metadata |
| `assets/sprites/civilizations/farm_ground.*` | Original farm terrain texture projected onto the isometric ground plane |
| `assets/sprites/civilizations/import_report.json` | All graphics referenced by the current import, including reused cache entries and missing SLP layer IDs |
| `assets/sprites/ui/icons_technologies.*` | Original research icon sheet, SLP 50729 |

The catalog also references the existing unit/building icon sheets and shared
player palette. Keep those outputs from the regular exporter. Once converted,
the game runs entirely from its JSON and PNG assets; Python, openage and the
original installation are not runtime dependencies.

For a data-only inspection, write to a separate output so the playable catalog's
graphic references remain intact:

```powershell
python tools/slp_export/import_civilizations.py `
  --openage "D:/Users/jiangzw/workspace/openage_workspace/openage" `
  --catalog-only --catalog ".godot/civilization_catalog.preview.json"
```

`--catalog-only` skips all graphic export and does **not** preserve old sprite
references in its output. The importer rejects data-only writes to the default
playable catalog; use a separate `--catalog` output as shown above. A full
import writes its catalog only after graphic export succeeds, so an export
failure does not replace the previous catalog with incomplete references.

### Parsing and composition rules

- DAT is raw-deflate compressed. The importer requires the openage reader to
  consume the entire decompressed file; the current input is 5,634,431 bytes.
  A different or unsupported version should fail at import, rather than produce
  a partially read catalog.
- Chinese is source civilization ID 6, Teutons ID 4. Availability follows each
  civilization's disabled technologies, research dependencies and actual
  `UNIT_ENABLED` effects. Tree connection fields must be interpreted as
  research IDs, not effect-bundle indices. For example, a display-tree entry
  alone must not accidentally enable Bombard Cannon for Chinese.
- `dat.graphics` is compacted: look graphics up by `graphic_id`, never by list
  offset. `original_graphics.py` composites the main graphic and its direct
  delta layers, preserving offsets and placing terrain/shadows below solid
  artwork. Recursing into delta layers would incorrectly include damage/fire
  overlays.
- Each graphic ID is exported once and referenced by multiple units, buildings
  or ages where appropriate. Unit actions include idle, walk, attack and death
  when the source provides them. Frame counts and original authored directions
  are retained in the metadata. Spare SLP frames after complete direction groups
  are excluded from playback; `source_frame_count` preserves their original count.
- Town Center uses original gameplay record 109, build-cost record 621 and the
  corresponding multi-part building graphic. Its new-construction requirement
  is Castle Age. Trebuchet movement uses the packed source, while idle/attack
  artwork and combat attributes use the unpacked source.
- Farm's transparent SLP overlay is replaced by a projection of the original
  `g_fm1_00_color.png` farm terrain texture. Stone's graphic is read from Gaia's
  stone resource definition.
- The generated catalog retains original attack/armor-class arrays for future
  use, but the current runtime does not implement every original combat effect
  or technology modifier. Consult the gameplay guide's scope section before
  treating catalog presence as full mechanic support.

### Incremental output and validation

The graphic exporter reuses a graphic when its destination JSON, atlas and any
declared player-color mask already exist.
It does not automatically invalidate that cache after a source DAT/SLP or
exporter change, and it does not remove obsolete files. To regenerate a changed
graphic, first move aside that graphic's generated atlas, metadata and mask,
then run the full importer again. Keep backups or inspect the diff before
discarding previous outputs. A data-only run cannot refresh the artwork.

`import_report.json` lists every graphic referenced by the current import once,
including cached outputs; the `cached` field identifies reuse. Per-sheet JSON contains `layers` and
`missing_slp_ids` for detailed inspection. A missing optional layer is recorded
while usable layers can still be exported. A graphic with no usable layers
fails, except for the explicit farm-terrain fallback. Check missing-layer
reports visually instead of assuming a successful process means every original
layer was present.

After import, allow Godot to import new PNGs, then run the relevant checks:

```powershell
python -m pytest tools/slp_export/tests -q
godot --headless --path . --editor --quit
godot --headless --path . --script tests/run_age_progression.gd
python ai_service_python/tools/export_land_catalog.py
```

Use your local Godot console executable if `godot` is not on `PATH`. The age
test validates catalog asset references and gameplay integration; it does not
establish visual equivalence for every animation or complete original-game
mechanics. Rendered age/HUD inspection is available with:

```powershell
godot --path . --script tests/run_age_progression.gd -- --render
```

Screenshots are written to `.godot/age-research.png` and `.godot/age-progression.png`.
The AI export command above refreshes the gameplay-only catalog shipped with the
standalone Python AI service; its regression test checks parity with the game catalog.

## Placeholders / limits

- SLP palette entries (including index 0, black) are opaque; only skip/outline commands and row bounds create transparent regions. Treating index 0 as transparent removes dark roof and interior details.

- Town Center exports also write `buildings/tc_asian_feudal_green.jpg`, a green-background preview of the final RGBA composite for checking shadows.

- Town Centers are multi-SLP in the original game. `python export_sprites.py --composite-tc` bakes Asian feudal layers into `tc_asian_feudal.png`; Dark Age still uses the single 891 piece.
- Unit sheets: 5 authored dirs + flip (see above); buildings/resources use `directions: 1`.
- Player-color pixels use the configured player; shadow commands preserve every pixel as black with alpha 100 (matching openage). Sheets preserve RGBA and building layers use source-over alpha compositing.
- Do not commit the full game tree — only tools + small converted PNGs.

## Modules

| File | API |
|------|-----|
| `palette.py` | `load_pal(path) -> list[(r,g,b,a)]` |
| `drs.py` | `extract(drs_path, file_id or name) -> bytes` |
| `slp.py` | `decode(bytes, palette) -> list[Image]` |
| `export_sprites.py` | CLI entry |

See `../../assets/ATTRIBUTION.txt` for copyright notice.
