# AoE2 Bottom Command Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an AoE2-style bottom command panel showing selection info/HP and build/train/stop command slots, using offline-exported interface SLP art.

**Architecture:** Extend existing `HudController` with a bottom `CommandPanel` (Info | Center reserve | Command grid). Selection still flows through `selection_changed`. Build/train reuse `BuildSystem` / `BuildingAgent.enqueue_train`; add `UnitAgent.command_stop()`. UI art lives under `assets/sprites/ui/` from `tools/slp_export --ui`.

**Tech Stack:** Godot 4.7 GDScript, existing headless `tests/run_tests.gd`, Python SLP export toolchain.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-10-command-panel-design.md`
- Top bar resources/pop stay; no minimap this slice
- Shared panel skin `51141` (`panel_game`); reserve `panel_skin` path for future civ variants
- Commands: build set + train icons + Stop; attack remains RMB
- Multi-select info: first selected entity HP + `×N`
- AoE2 resources path: `D:/BaiduNetdiskDownload/gaoqingban2/gaoqingban2/resources`
- Do not commit raw DRS/SLP; only PNG+JSON under `assets/sprites/ui/`
- Commits: Conventional Commits (`type(scope): English subject`, Chinese body when needed)
- Godot: `D:\Users\jiangzw\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64.exe`
- Tests: `& "...\Godot_v4.7.1-stable_win64.exe" --headless --path "D:\Users\jiangzw\workspace\godot_game\aoe2" -s res://tests/run_tests.gd`

---

## File Structure

| Path | Responsibility |
|------|----------------|
| `tools/slp_export/export_sprites.py` | `UI_PRIORITY` + `--ui` export mode |
| `tools/slp_export/README.md` | Document UI IDs / command |
| `assets/sprites/ui/*` | Exported panel + icon sheets |
| `scripts/presentation/ui_catalog.gd` | Paths, atlas frame helper, panel skin |
| `scripts/entities/unit_agent.gd` | `command_stop()` |
| `scenes/ui/hud.tscn` | Bottom CommandPanel layout; hide old BuildPanel |
| `scripts/ui/hud_controller.gd` | Info refresh + dynamic command grid |
| `tests/test_command_panel.gd` | Stop + selection → slots (headless) |
| `tests/run_tests.gd` | Register new tests |

---

### Task 1: Export UI SLP sheets

**Files:**
- Modify: `tools/slp_export/export_sprites.py`
- Modify: `tools/slp_export/README.md`
- Create: `assets/sprites/ui/panel_game.png` (+ `.json`)
- Create: `assets/sprites/ui/icons_units.png` (+ `.json`)
- Create: `assets/sprites/ui/icons_buildings.png` (+ `.json`)
- Create: `assets/sprites/ui/icons_commands.png` (+ `.json`)

**Interfaces:**
- Consumes: existing `export_one` / `export_priority` patterns; interface folder lookup already in `export_one`
- Produces: UI sheets under `assets/sprites/ui/` with `directions: 1`

- [ ] **Step 1: Add `UI_PRIORITY` list**

In `export_sprites.py` after `PRIORITY`:

```python
UI_PRIORITY: List[Dict[str, Any]] = [
    {"key": "panel_game", "category": "ui", "id": 51141, "directions": 1, "note": "Large game panel strip"},
    {"key": "icons_units", "category": "ui", "id": 50730, "directions": 1, "note": "Unit icons"},
    {"key": "icons_buildings", "category": "ui", "id": 50705, "directions": 1, "note": "Building icons"},
    {"key": "icons_commands", "category": "ui", "id": 50721, "directions": 1, "note": "Command icons"},
]
```

- [ ] **Step 2: Add `--ui` CLI and `export_ui()`**

Mirror `export_priority` but iterate `UI_PRIORITY` and write report keys. Wire:

```python
parser.add_argument("--ui", action="store_true", help="export UI panel/icon SLPs")
```

When `--ui` alone: run UI export only. Document in README:

```powershell
python export_sprites.py --ui
```

- [ ] **Step 3: Run export**

From `tools/slp_export` with config pointing at local resources:

```powershell
python export_sprites.py --ui
```

Expected: four PNG/JSON pairs under `assets/sprites/ui/`. If an ID fails, fix path/lookup or note fallback in report — panel must at least export `51141` or document substitute (`51121`/`51101`).

- [ ] **Step 4: Commit**

```text
feat(tools): export AoE2 interface panel and icon sheets

离线导出底栏条与单位/建筑/命令图标到 assets/sprites/ui。
```

---

### Task 2: `command_stop` + UiCatalog helpers

**Files:**
- Modify: `scripts/entities/unit_agent.gd`
- Create: `scripts/presentation/ui_catalog.gd`
- Create: `tests/test_command_panel.gd` (stop test first)
- Modify: `tests/run_tests.gd`

**Interfaces:**
- Produces:
  - `UnitAgent.command_stop() -> void`
  - `UiCatalog.PANEL_GAME_BASE`, `ICONS_*_BASE` path constants
  - `UiCatalog.panel_texture() -> Texture2D`
  - `UiCatalog.atlas_frame(sheet_base: String, frame_index: int) -> Texture2D` (null if missing)

- [ ] **Step 1: Failing test for stop**

`tests/test_command_panel.gd`:

```gdscript
extends RefCounted

const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_command_stop_clears_move(failures)
	return failures

func _test_command_stop_clears_move(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)
	var unit := UNIT_VIEW.instantiate() as UnitAgent
	unit.def = VILLAGER
	unit.sim_pos = Vector2.ZERO
	root.add_child(unit)
	unit.command_move(Vector2(5, 0))
	if unit.order != Enums.OrderType.MOVE:
		failures.append("setup move order failed")
	unit.command_stop()
	if unit.order != Enums.OrderType.NONE:
		failures.append("command_stop should clear MOVE order")
	root.free()
```

Register in `run_tests.gd`. Run tests → expect FAIL (no `command_stop`).

- [ ] **Step 2: Implement `command_stop`**

In `unit_agent.gd` near other `command_*`:

```gdscript
func command_stop() -> void:
	_move_target = Vector2.ZERO
	_gather_target = null
	_drop_off_target = null
	_build_target = null
	_attack_target = null
	_gather_state = ""
	_no_progress_frames = 0
	order = Enums.OrderType.NONE
	_update_idle_animation(0.0)
```

- [ ] **Step 3: Add `UiCatalog`**

```gdscript
class_name UiCatalog
extends RefCounted

## Shared panel skin v1; swap path later for civ variants.
const PANEL_GAME_BASE := "res://assets/sprites/ui/panel_game"
const ICONS_UNITS_BASE := "res://assets/sprites/ui/icons_units"
const ICONS_BUILDINGS_BASE := "res://assets/sprites/ui/icons_buildings"
const ICONS_COMMANDS_BASE := "res://assets/sprites/ui/icons_commands"

## Provisional frame indices — adjust after inspecting exported sheets in-editor.
const FRAME_STOP := 0
const FRAME_BUILD_HOUSE := 0
const FRAME_BUILD_BARRACKS := 1
const FRAME_BUILD_ARCHERY := 2
const FRAME_BUILD_STABLE := 3
const FRAME_BUILD_MILL := 4
const FRAME_BUILD_LUMBER := 5
const FRAME_BUILD_MINING := 6

static func load_meta(base: String) -> Dictionary:
	var path := "%s.json" % base
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text)
	return data if typeof(data) == TYPE_DICTIONARY else {}

static func load_texture(base: String) -> Texture2D:
	var path := "%s.png" % base
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D

static func atlas_frame(base: String, frame_index: int) -> Texture2D:
	var tex := load_texture(base)
	var meta := load_meta(base)
	if tex == null or meta.is_empty():
		return null
	var cols := int(meta.get("cols", 1))
	var fw := int(meta.get("frame_w", 0))
	var fh := int(meta.get("frame_h", 0))
	if cols <= 0 or fw <= 0 or fh <= 0:
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2((frame_index % cols) * fw, int(frame_index / cols) * fh, fw, fh)
	return atlas

static func panel_texture() -> Texture2D:
	return load_texture(PANEL_GAME_BASE)
```

- [ ] **Step 4: Run tests → pass; commit**

```text
feat(units): add command_stop and UI catalog helpers

停止指令清空单位订单；增加底栏/图标资源路径与图集切片辅助。
```

---

### Task 3: HUD CommandPanel scene + controller wiring

**Files:**
- Modify: `scenes/ui/hud.tscn`
- Modify: `scripts/ui/hud_controller.gd`
- Modify: `tests/test_command_panel.gd` (selection → slots)

**Interfaces:**
- Consumes: `UiCatalog`, `selection.get_selected_units/building`, `command_stop`, `begin_placement`, `enqueue_train`
- Produces: bottom panel visible; old BuildPanel hidden; dynamic grid

- [ ] **Step 1: Restructure `hud.tscn`**

Add under `HUD` (anchors bottom, height ~140–160px, full width):

```
CommandPanel (Control, mouse_filter=STOP)
  PanelBg (TextureRect) — stretch panel_game if present else ColorRect dark
  InfoColumn (VBox)
    Portrait (TextureRect 64×64)
    NameLabel
    HpBar (ProgressBar)
    HpLabel
    CountLabel  # "×N" when N>1
  CenterReserve (Control) — empty
  CommandGrid (GridContainer columns=5)
```

Set `BuildPanel` + `BuildPanelBg` `visible = false` (keep nodes so unique names do not break until controller migrates). Move/hide old `TrainPanel` or leave empty — train buttons spawn into `CommandGrid` instead.

Ensure `CommandPanel` does **not** use `mouse_filter = IGNORE` on the bar itself (buttons must receive clicks). Rest of HUD can stay IGNORE where appropriate.

- [ ] **Step 2: Rewrite selection refresh in `hud_controller.gd`**

Core behavior:

```gdscript
func _on_selection_changed(_selected: Array) -> void:
	_disconnect_selected_building()
	_selected_building = selection.call("get_selected_building") as Node2D
	# reconnect train_queue_changed → _rebuild_command_grid
	_refresh_info_panel()
	_rebuild_command_grid()

func _refresh_info_panel() -> void:
	var units: Array = selection.call("get_selected_units")
	var building: Node2D = selection.call("get_selected_building")
	# pick first entity: unit preferred if any, else building
	# set name, hp bar value = hp/max_hp, count label

func _rebuild_command_grid() -> void:
	# clear CommandGrid children
	# if any player villager in selection: add build buttons (civ-filtered stable)
	# if selected completed building: add train buttons for get_trainable_units()
	# if any player units: add Stop button → _stop_selected_units()
	# use TextureButton when UiCatalog.atlas_frame returns texture; else Button with text

func _stop_selected_units() -> void:
	for unit in selection.call("get_selected_units"):
		if unit.get("team") == Enums.Team.PLAYER and unit.has_method("command_stop"):
			unit.call("command_stop")
```

Build buttons call existing `_request_build`. Train buttons call existing `_enqueue_train`. Disable train when `not _can_enqueue`.

In `setup()`: stop wiring visible old BuildPanel if hidden; still OK to connect if nodes exist. Prefer connecting only grid-created buttons.

- [ ] **Step 3: Headless tests for grid**

Extend `test_command_panel.gd`:

- Instantiate HUD + fake selection helper OR drive match scene lightly:
  - After selecting villager via selection controller APIs, `CommandGrid` child count ≥ 1 (build or stop)
  - After `command_stop` test already present

Minimal approach without full match: unit-test `_rebuild` by constructing HudController with stub selection RefCounted is heavy — prefer loading `hud.tscn`, manually set `selection` mock Node with methods, call `_on_selection_changed`.

Simpler acceptance in this task: keep stop test; add test that `UiCatalog.panel_texture()` non-null after Task 1 assets committed.

- [ ] **Step 4: Run full suite; commit**

```text
feat(ui): add AoE2-style bottom command panel

底栏显示选中血量与建造/训练/停止指令格，复用导出 UI 贴图。
```

---

### Task 4: Icon frame mapping polish + manual checklist

**Files:**
- Modify: `scripts/presentation/ui_catalog.gd` (frame indices after visual check)
- Optionally small README note under `assets/sprites/ui/README.md` listing frame meanings

- [ ] **Step 1: Open exported sheets in Godot/editor; set FRAME_* constants** to sensible stop/build icons (wrong frames OK temporarily if labeled; prefer correct stop glyph from `icons_commands`).

- [ ] **Step 2: Manual playthrough**

1. F5 → civ select → match  
2. Select villager → bottom shows name/HP; build + stop icons  
3. Place house from panel  
4. Select TC → train villager from panel  
5. Move units → Stop cancels walk  
6. Empty selection → info/commands clear  

- [ ] **Step 3: Commit frame index tweaks if any**

```text
fix(ui): map command panel icon frames
```

---

## Spec coverage self-review

| Spec item | Task |
|-----------|------|
| UI SLP export 51141/50730/50705/50721 | Task 1 |
| Bottom Info + Command grid | Task 3 |
| Top bar kept | Task 3 (no remove) |
| Build/train/stop | Task 2–3 |
| panel_skin reserved via UiCatalog const | Task 2 |
| No minimap | N/A (center empty) |
| Headless stop + slots | Task 2–3 |
| Manual acceptance | Task 4 |

No placeholders remaining for required behavior; icon frame indices may need post-export visual tune in Task 4 (explicit).
