# Task 12 Report

## Status

Complete.

## Implementation

- Added `tools/slp_export/` with `palette.py`, `drs.py`, `slp.py`, `export_sprites.py`, `config.example.json`, `README.md`, `requirements.txt`, pytest.
- HD install uses unpacked DRS folders (`_common/drs/graphics/{id}.slp`); `drs.extract` supports folders and packed `.drs`.
- Palette loader reads JASC-PAL (`pal_2.pal`, `clf_pal.pal`, interface `50500.bina`); index 0 transparent.
- SLP 2.0N decode → RGBA frames; packs sheets + JSON meta under `assets/sprites/`.
- Smoke: `assets/sprites/_smoke/ui_50731.png` (interface SLP 50731).
- Priority batch: 17/17 IDs exported (villager, militia/swordsman, archer, chu ko nu, teutonic knight, TC tops, houses, barracks, archery, stables, tree, gold, bush).
- `assets/ATTRIBUTION.txt` + `.gitignore` for `config.json` / raw dumps.

## Verification

- GREEN: `pytest tests/test_palette.py -q` → `3 passed`.
- Smoke + priority export succeeded; PNGs visually recognizable (UI icons, berry bushes, villager sheet).

## Commit

`feat(tools): add DRS/SLP sprite export pipeline`

## Concerns

- TC is multi-layer in original; demo exports single top pieces (891/901) only.
- `directions` / `frames_per_direction` are hints until confirmed from `empires2.dat`.
- Shadow pixels approximated; outline (behind-tree) commands skipped for cleaner PNG.
- Do not start Task 13 in this session.
