### Task 12: SLP/DRS export toolchain (Python)

**Files:**
- Create: `tools/slp_export/README.md` — source path, how to run
- Create: `tools/slp_export/config.example.json` with `"aoe2_resources": "D:/BaiduNetdiskDownload/gaoqingban2/gaoqingban2/resources"`
- Create: `tools/slp_export/drs.py`, `slp.py`, `palette.py`, `export_sprites.py`
- Create: `tools/slp_export/tests/test_palette.py` (pytest)
- Create: `assets/ATTRIBUTION.txt` — copyright notice for AoE2 assets

**Interfaces:**
- `palette.load_pal(path) -> list[tuple[r,g,b,a]]` (index 0 transparent if needed)
- `drs.extract(drs_path, file_id or name) -> bytes`
- `slp.decode(bytes, palette) -> list[Image]` frames
- `export_sprites.main` writes under `assets/sprites/{units,buildings,resources,ui}/` + JSON frame meta `{cols, rows, frame_w, frame_h, directions}`

Priority export list (map IDs via known HD filenames / graphics DRS — document chosen IDs in README when discovered): villager walk, swordsman, archer, chu ko nu, teutonic knight, TC, house, barracks, archery, stable, tree, gold, bush.

- [ ] **Step 1: Implement palette loader + pytest for known 256-entry file `resources/_common/dat/clf_pal.pal` or `pal_*.pal`**

- [ ] **Step 2: Implement DRS + SLP decode enough to export one UI/known SLP smoke test to `assets/sprites/_smoke/`**

- [ ] **Step 3: Batch export priority list; commit only small PNGs needed + scripts (not full game)**

- [ ] **Step 4: Commit** `feat(tools): add DRS/SLP sprite export pipeline`

---
