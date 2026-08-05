# AoE2 RTS Demo (Chinese vs Teutons) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a playable Godot 4.7 single-player vs AI micro-RTS demo (Chinese vs Teutons) with isometric-style 3D billboard presentation, three-resource economy, and destroy-TC victory, using offline-converted AoE2 HD art.

**Architecture:** 3D presentation layer (`Camera3D` + ground mesh + billboard sprites) over an XZ-plane simulation (units/buildings as data + `Node3D` views). Input uses screen-ray ground picks and screen-space box select. Civ differences and unit stats live in Resource configs. AI is a phased script (eco → military → attack). Old 2D elephant demo is deleted; main scene becomes the 3D match.

**Tech Stack:** Godot 4.7 (GDScript), Python 3 + Pillow for SLP/DRS export, optional pytest for export tools.

## Global Constraints

- Engine: Godot 4.7 (`config/features` includes `"4.7"`).
- Civilizations only: Chinese and Teutons.
- Resources only: food, wood, gold (no stone).
- Mode: single player vs AI; player picks civ, AI gets the other.
- Presentation: Godot 3D + Y-billboard sprites + fixed-pitch oblique camera (not the removed 2D demo).
- Win condition: destroy enemy town center.
- Do not keep elephant 2D demo files.
- Do not commit full AoE2 install tree; tools read `D:\BaiduNetdiskDownload\gaoqingban2\gaoqingban2\resources` via config.
- Git commits: Conventional Commits (`type(scope): English subject`, Chinese body when needed).
- Spec: `docs/superpowers/specs/2026-08-05-aoe2-rts-demo-design.md`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `project.godot` | App name, main scene → civ select / match |
| `scenes/civ_select.tscn` | Pick Chinese or Teutons, start match |
| `scenes/match_3d.tscn` | 3D battlefield root |
| `scenes/ui/hud.tscn` | Resources, pop, train buttons, win/lose |
| `scenes/entities/unit_view.tscn` | Billboard unit presentation |
| `scenes/entities/building_view.tscn` | Building presentation + footprint |
| `scripts/core/match_state.gd` | Players, resources, pop, win flag |
| `scripts/core/enums.gd` | ResourceType, UnitType, BuildingType, Team, OrderType |
| `scripts/core/combat_math.gd` | Pure damage formula (testable) |
| `scripts/data/unit_def.gd` | Unit Resource definition |
| `scripts/data/building_def.gd` | Building Resource definition |
| `scripts/data/civ_def.gd` | Civ Resource definition |
| `data/units/*.tres` | Concrete unit stats |
| `data/buildings/*.tres` | Concrete building stats |
| `data/civs/chinese.tres` / `teutons.tres` | Civ configs |
| `scripts/entities/unit_agent.gd` | Unit FSM + sim position |
| `scripts/entities/building_agent.gd` | Train queue, HP, drop-off |
| `scripts/entities/resource_node.gd` | Gatherable amount |
| `scripts/systems/gather_system.gd` | Carry / drop-off loop helpers |
| `scripts/systems/build_system.gd` | Placement validity + construction |
| `scripts/systems/combat_system.gd` | Attack ticks |
| `scripts/systems/ai_controller.gd` | Eco / military / attack phases |
| `scripts/input/rts_camera_3d.gd` | Pan, edge scroll, zoom |
| `scripts/input/selection_controller_3d.gd` | Select, box, orders |
| `scripts/input/ground_picker.gd` | Ray ∩ y=0 plane |
| `scripts/ui/hud_controller.gd` | Bind match state + train UI |
| `scripts/ui/civ_select_controller.gd` | Start match with chosen civ |
| `scripts/match/match_bootstrap.gd` | Spawn map, both sides, wire AI |
| `tests/test_combat_math.gd` | Headless logic tests |
| `tests/run_tests.gd` | Minimal test runner |
| `tools/slp_export/` | DRS/SLP → PNG pipeline |
| `assets/sprites/...` | Converted / placeholder art |
| `assets/terrain/` | Ground textures |

**Delete on Task 1:** `scenes/elephant.tscn`, `scenes/main.tscn`, `scripts/elephant.gd`, `scripts/selection_box.gd`, `scripts/selection_controller.gd`, `scripts/main.gd`, `assets/elephant_walk.png*`, `assets/grass.png*`, `elephant.bmp*`.

---

### Task 1: Remove 2D elephant demo and reset project entry

**Files:**
- Delete: `scenes/elephant.tscn`, `scenes/main.tscn`, `scripts/elephant.gd`, `scripts/elephant.gd.uid`, `scripts/selection_box.gd`, `scripts/selection_box.gd.uid`, `scripts/selection_controller.gd`, `scripts/selection_controller.gd.uid`, `scripts/main.gd`, `scripts/main.gd.uid`, `assets/elephant_walk.png`, `assets/elephant_walk.png.import`, `assets/grass.png`, `assets/grass.png.import`, `elephant.bmp`, `elephant.bmp.import`
- Create: `scenes/civ_select.tscn` (placeholder Control with two buttons)
- Create: `scripts/ui/civ_select_controller.gd`
- Modify: `project.godot`

**Interfaces:**
- Consumes: none
- Produces: `project.godot` `run/main_scene="res://scenes/civ_select.tscn"`; app name `AoE2 RTS Demo`

- [ ] **Step 1: Delete old demo files listed above**

- [ ] **Step 2: Create minimal civ select scene script**

```gdscript
# scripts/ui/civ_select_controller.gd
extends Control

signal civ_chosen(civ_id: StringName)

func _on_chinese_pressed() -> void:
	civ_chosen.emit(&"chinese")

func _on_teutons_pressed() -> void:
	civ_chosen.emit(&"teutons")

func _ready() -> void:
	# Temporary: just print until match scene exists (Task 10 wires change_scene).
	if not civ_chosen.is_connected(_temp_log):
		civ_chosen.connect(_temp_log)

func _temp_log(civ_id: StringName) -> void:
	print("Selected civ: ", civ_id)
```

In `civ_select.tscn`: root `Control` full rect, title label, buttons "中国" / "条顿" connected to the handlers. Script on root.

- [ ] **Step 3: Update `project.godot` application block**

```ini
config/name="AoE2 RTS Demo"
config/description="Micro RTS demo: Chinese vs Teutons"
run/main_scene="res://scenes/civ_select.tscn"
config/features=PackedStringArray("4.7", "Forward Plus")
```

Remove obsolete `layer_names` 2D units layer if present (optional cleanup).

- [ ] **Step 4: Open project in Godot editor, run; click buttons; confirm console prints civ ids and no missing script errors**

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore: remove 2D elephant demo and add civ select stub

删除旧大象 demo，主场景改为文明选择占位界面。
EOF
)"
```

---

### Task 2: Core enums, combat math, and headless test runner

**Files:**
- Create: `scripts/core/enums.gd`
- Create: `scripts/core/combat_math.gd`
- Create: `tests/test_combat_math.gd`
- Create: `tests/run_tests.gd`

**Interfaces:**
- Consumes: none
- Produces:
  - `Enums.ResourceType { FOOD, WOOD, GOLD }`
  - `Enums.Team { PLAYER, AI }`
  - `CombatMath.apply_armor(raw_damage: float, armor: float) -> float` — `maxf(0.0, raw_damage - armor)` with minimum chip damage `0.5` when `raw_damage > 0`

- [ ] **Step 1: Write failing test script**

```gdscript
# tests/test_combat_math.gd
extends RefCounted

func run() -> Array[String]:
	var failures: Array[String] = []
	var d := CombatMath.apply_armor(10.0, 2.0)
	if not is_equal_approx(d, 8.0):
		failures.append("expected 8 got %s" % d)
	var chip := CombatMath.apply_armor(1.0, 5.0)
	if not is_equal_approx(chip, 0.5):
		failures.append("expected chip 0.5 got %s" % chip)
	var zero := CombatMath.apply_armor(0.0, 5.0)
	if not is_equal_approx(zero, 0.0):
		failures.append("expected 0 got %s" % zero)
	return failures
```

```gdscript
# tests/run_tests.gd
extends SceneTree

func _initialize() -> void:
	var failures: Array[String] = []
	failures.append_array(load("res://tests/test_combat_math.gd").new().run())
	if failures.is_empty():
		print("ALL TESTS PASSED")
		quit(0)
	else:
		for f in failures:
			push_error(f)
		print("TESTS FAILED: ", failures.size())
		quit(1)
```

- [ ] **Step 2: Run runner expecting failure (CombatMath missing)**

```bash
# Adjust path to local Godot 4.7 executable
godot --path . --headless -s res://tests/run_tests.gd
```

Expected: error / non-zero (class not found or parse error).

- [ ] **Step 3: Implement enums + combat math**

```gdscript
# scripts/core/enums.gd
class_name Enums
enum ResourceType { FOOD, WOOD, GOLD }
enum Team { PLAYER, AI }
enum OrderType { NONE, MOVE, GATHER, BUILD, ATTACK }
enum UnitType { VILLAGER, SWORDSMAN, ARCHER, CHU_KO_NU, TEUTONIC_KNIGHT }
enum BuildingType { TOWN_CENTER, HOUSE, BARRACKS, ARCHERY_RANGE, STABLE, MILL, LUMBER_CAMP, MINING_CAMP }
```

```gdscript
# scripts/core/combat_math.gd
class_name CombatMath
static func apply_armor(raw_damage: float, armor: float) -> float:
	if raw_damage <= 0.0:
		return 0.0
	return maxf(0.5, raw_damage - armor)
```

Ensure scripts use `class_name` so headless load works (no need to preload if globally registered after editor import — for headless first run, `run_tests.gd` may `preload` explicitly):

```gdscript
const _CombatMath = preload("res://scripts/core/combat_math.gd")
# In test, call _CombatMath.apply_armor if class_name not yet registered
```

Prefer `class_name` + opening once in editor so `.godot` global class cache exists; if CI-less local, preload in tests.

- [ ] **Step 4: Re-run tests — expect `ALL TESTS PASSED` exit 0**

- [ ] **Step 5: Commit**

```bash
git add scripts/core/enums.gd scripts/core/combat_math.gd tests/
git commit -m "$(cat <<'EOF'
feat(core): add enums and armored damage helper

为战斗结算提供可单测的减甲公式与全局枚举。
EOF
)"
```

---

### Task 3: Data resources (unit / building / civ definitions)

**Files:**
- Create: `scripts/data/unit_def.gd`, `scripts/data/building_def.gd`, `scripts/data/civ_def.gd`
- Create: `data/units/villager.tres`, `swordsman.tres`, `archer.tres`, `chu_ko_nu.tres`, `teutonic_knight.tres`
- Create: `data/buildings/town_center.tres`, `house.tres`, `barracks.tres`, `archery_range.tres`, `stable.tres`, `mill.tres`, `lumber_camp.tres`, `mining_camp.tres`
- Create: `data/civs/chinese.tres`, `data/civs/teutons.tres`

**Interfaces:**
- Consumes: `Enums`
- Produces:
  - `UnitDef` extends Resource: `id`, `display_name`, `max_hp`, `attack`, `attack_cooldown`, `range`, `melee_armor`, `pierce_armor`, `move_speed`, `cost_food/wood/gold`, `train_time`, `population`, `is_ranged`
  - `BuildingDef`: `id`, `max_hp`, `footprint` (Vector2), `cost_*`, `build_time`, `population_provided`, `trainable: Array[UnitDef]`, `drop_off: Enums.ResourceType` (-1 none via optional `has_drop_off`)
  - `CivDef`: `id`, `display_name`, `extra_starting_villagers`, `villager_train_time_mul`, `building_hp_mul`, `melee_armor_bonus`, `allowed_buildings: Array[BuildingType]`, `unique_unit: UnitDef`

**Baseline numbers (hand-tuned, locked for demo):**

| Unit | HP | Atk | CD | Range | mArmor | pArmor | Speed | Cost F/W/G | Time | Pop |
|---|---|---|---|---|---|---|---|---|---|---|
| Villager | 25 | 3 | 1.5 | 0.5 | 0 | 0 | 4.5 | 50/0/0 | 25s | 1 |
| Swordsman | 40 | 8 | 1.2 | 0.6 | 1 | 0 | 4.0 | 60/0/20 | 21s | 1 |
| Archer | 30 | 5 | 1.4 | 6.0 | 0 | 0 | 4.2 | 0/25/45 | 35s | 1 |
| Chu Ko Nu | 35 | 3 | 0.7 | 5.5 | 0 | 0 | 4.2 | 0/35/50 | 30s | 1 |
| Teutonic Knight | 80 | 14 | 1.5 | 0.7 | 5 | 2 | 3.2 | 80/0/60 | 40s | 1 |

| Building | HP | Footprint | Cost F/W/G | Build | Pop+ | Trains |
|---|---|---|---|---|---|---|
| TC | 2400 | 4x4 | — | — | 5 | Villager |
| House | 550 | 2x2 | 0/30/0 | 10s | 5 | — |
| Barracks | 1200 | 3x3 | 0/175/0 | 30s | 0 | Swordsman |
| Archery | 1200 | 3x3 | 0/175/0 | 30s | 0 | Archer (+Chu for Chinese via civ filter) |
| Stable | 1400 | 3x3 | 0/175/0 | 35s | 0 | Teutonic Knight |
| Mill / Lumber / Mining | 600 | 2x2 | 0/100/0 | 20s | 0 | drop-off food/wood/gold |

Chinese: `extra_starting_villagers=1`, `villager_train_time_mul=0.85`, `building_hp_mul=1.0`, `melee_armor_bonus=0`, buildings without Stable, unique Chu Ko Nu.  
Teutons: `extra=0`, `villager_train_time_mul=1.0`, `building_hp_mul=1.25`, `melee_armor_bonus=1`, includes Stable, unique Teutonic Knight.

- [ ] **Step 1: Implement the three Resource scripts with exported fields as in Interfaces**

- [ ] **Step 2: Create `.tres` files in editor (or text resources) matching the table**

Example `data/civs/chinese.tres` fields: `id=&"chinese"`, wire `unique_unit` to chu_ko_nu, `allowed_buildings` exclude STABLE.

- [ ] **Step 3: Add a tiny loader test in `tests/test_civ_defs.gd`**

```gdscript
extends RefCounted
func run() -> Array[String]:
	var failures: Array[String] = []
	var c: CivDef = load("res://data/civs/chinese.tres")
	var t: CivDef = load("res://data/civs/teutons.tres")
	if c.extra_starting_villagers != 1:
		failures.append("chinese extra villagers")
	if t.building_hp_mul < 1.2:
		failures.append("teutons hp mul")
	if t.melee_armor_bonus != 1:
		failures.append("teutons armor bonus")
	return failures
```

Register in `run_tests.gd`.

- [ ] **Step 4: Run `godot --path . --headless -s res://tests/run_tests.gd` — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add scripts/data data tests
git commit -m "$(cat <<'EOF'
feat(data): add unit, building, and civ definitions

配置中国/条顿数值与可训练单位，供对局启动读取。
EOF
)"
```

---

### Task 4: Match state (resources, population, teams)

**Files:**
- Create: `scripts/core/match_state.gd`
- Create: `tests/test_match_state.gd`
- Modify: `tests/run_tests.gd`

**Interfaces:**
- Consumes: `Enums`, `CivDef`, `UnitDef`, `BuildingDef`
- Produces: `MatchState` (RefCounted):
  - `var resources: Dictionary` # Team -> {FOOD:int, WOOD:int, GOLD:int}
  - `var population: Dictionary` / `population_cap: Dictionary`
  - `func can_afford(team, cost_f, cost_w, cost_g) -> bool`
  - `func spend(team, cost_f, cost_w, cost_g) -> bool`
  - `func add_resource(team, type, amount) -> void`
  - `func can_train(team, def: UnitDef) -> bool` # afford + pop
  - `func register_pop(team, used_delta, cap_delta) -> void`
  - Starting stock: `FOOD=200, WOOD=200, GOLD=100` each team

- [ ] **Step 1: Write tests for afford/spend/pop gate**

```gdscript
func run() -> Array[String]:
	var failures: Array[String] = []
	var m := MatchState.new()
	m.setup_defaults()
	if not m.can_afford(Enums.Team.PLAYER, 50, 0, 0):
		failures.append("should afford villager")
	m.spend(Enums.Team.PLAYER, 50, 0, 0)
	if m.get_resource(Enums.Team.PLAYER, Enums.ResourceType.FOOD) != 150:
		failures.append("food not spent")
	m.population[Enums.Team.PLAYER] = 5
	m.population_cap[Enums.Team.PLAYER] = 5
	var u := UnitDef.new()
	u.cost_food = 0
	u.cost_wood = 0
	u.cost_gold = 0
	u.population = 1
	if m.can_train(Enums.Team.PLAYER, u):
		failures.append("pop full should block")
	return failures
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement `MatchState` to pass**

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit** `feat(core): add match resource and population state`

---

### Task 5: 3D match scene, ground, camera, ground picker

**Files:**
- Create: `scenes/match_3d.tscn`
- Create: `scripts/input/rts_camera_3d.gd`
- Create: `scripts/input/ground_picker.gd`
- Create: `scripts/match/match_bootstrap.gd` (stub: builds green ground plane only)
- Modify: later tasks expand bootstrap

**Interfaces:**
- Consumes: none
- Produces:
  - `GroundPicker.pick_ground(camera: Camera3D, screen_pos: Vector2) -> Variant` # `Vector3` or `null` — ray vs plane y=0
  - `RtsCamera3D`: pitch 50°, yaw 45°, WASD/arrows pan on XZ, edge margin 18px, wheel zoom distance clamp `[18, 80]`

- [ ] **Step 1: Create `match_3d.tscn`**

Root `Node3D` named `Match`. Children:
- `DirectionalLight3D`
- `WorldEnvironment` (simple ambient)
- `Map/Ground` = `MeshInstance3D` with `PlaneMesh` size 120x120, green `StandardMaterial3D`
- `CameraRig` (`Node3D`) + child `Camera3D` with script `rts_camera_3d.gd`
- `Entities` (`Node3D`)
- `Bootstrap` (`Node`) with `match_bootstrap.gd`

- [ ] **Step 2: Implement ground picker**

```gdscript
# scripts/input/ground_picker.gd
class_name GroundPicker
static func pick_ground(camera: Camera3D, screen_pos: Vector2) -> Variant:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 0.0001:
		return null
	var t := -from.y / dir.y
	if t < 0.0:
		return null
	return from + dir * t
```

- [ ] **Step 3: Implement camera pan/zoom in `_process` / `_unhandled_input`**

Keep camera looking at `CameraRig` origin; change rig XZ position and camera `position.z` (local distance) for zoom.

- [ ] **Step 4: Manual test — set `project.godot` temporarily OR add debug key on civ select to `change_scene_to_file("res://scenes/match_3d.tscn")`; verify pan/zoom and print ground picks on click**

- [ ] **Step 5: Commit** `feat(scene): add 3D match ground and RTS camera`

---

### Task 6: Unit agent + selection + move orders

**Files:**
- Create: `scenes/entities/unit_view.tscn` (Node3D + MeshInstance3D capsule placeholder + SelectionRing Mesh)
- Create: `scripts/entities/unit_agent.gd`
- Create: `scripts/input/selection_controller_3d.gd`
- Modify: `scripts/match/match_bootstrap.gd` — spawn 1 player villager at origin
- Modify: `scenes/match_3d.tscn` — add SelectionController node

**Interfaces:**
- Consumes: `GroundPicker`, `UnitDef`, `Enums`
- Produces:
  - `UnitAgent` (Node3D): `team`, `def`, `hp`, `order`, `sim_pos: Vector3` (y=0), `command_move(target: Vector3)`, `set_selected(bool)`, speed from def
  - `SelectionController3D`: LMB click/drag box in screen space; RMB issues `command_move` to selected player units; Shift add

**Movement:** each physics frame move toward target on XZ at `move_speed`; arrive within `0.15` m; face movement via `rotation.y = atan2(velocity.x, velocity.z)`.

**Box select:** project each unit origin to screen; `Rect2` abs from drag start/end; threshold 6px for click vs drag.

- [ ] **Step 1: Implement `UnitAgent` with placeholder mesh colored by team (blue player / red AI)**

- [ ] **Step 2: Implement selection + move**

- [ ] **Step 3: Bootstrap spawns one villager; manual test select + RMB move across plane**

- [ ] **Step 4: Commit** `feat(units): add 3D selection and move commands`

---

### Task 7: Resource nodes + gather + drop-off

**Files:**
- Create: `scripts/entities/resource_node.gd`
- Create: `scripts/systems/gather_system.gd` (logic helpers on UnitAgent or autoload-style statics)
- Modify: `unit_agent.gd` — GATHER order, carry stock `carry_type`, `carry_amount`, `carry_capacity=10`
- Modify: `match_bootstrap.gd` — spawn food bush, trees, gold, TC as drop-off building stub
- Modify: `building_agent.gd` may start here as minimal drop-off-only TC

**Interfaces:**
- `ResourceNode`: `resource_type`, `amount`, `gather_rate` per second while villager in range `1.2`; `extract(dt) -> float`
- Gather loop: move to node → extract until carry full or node empty → move to nearest friendly drop-off that accepts type (TC accepts all; mill/lumber/mining accept one) → `MatchState.add_resource` → return to last node if amount>0
- RMB on resource with villagers selected → `command_gather(node)`

- [ ] **Step 1: Implement resource node + gather state machine transitions on UnitAgent**

- [ ] **Step 2: Spawn TC + 3 resource types; manual test villager gathers and food/wood/gold counters increase (temporary on-screen Label OK)**

- [ ] **Step 3: Commit** `feat(economy): add gather and drop-off loop`

---

### Task 8: Buildings — placement, construction, train queue

**Files:**
- Create: `scripts/entities/building_agent.gd`
- Create: `scripts/systems/build_system.gd`
- Create: `scenes/entities/building_view.tscn`
- Create: `scenes/ui/hud.tscn` + `scripts/ui/hud_controller.gd`
- Modify: selection to select buildings; HUD shows train buttons from `BuildingDef.trainable` filtered by civ

**Interfaces:**
- `BuildSystem.can_place(footprint, center, existing_buildings) -> bool` — AABB/circle overlap reject
- `UnitAgent.command_build(ghost: BuildingAgent)` — BUILD order adds `build_progress` until `build_time`
- `BuildingAgent.enqueue_train(unit_def) -> bool` — queue size max 1; spends resources; ticks `train_time` (Chinese villager time `* civ.villager_train_time_mul`); spawn unit beside building
- Ghost placement: press hotkey or HUD "建房" → follow mouse ground pos → LMB confirm if `can_place`

Population: on building complete `register_pop(0, population_provided)`; on unit spawn `register_pop(+pop, 0)`; on death reverse.

- [ ] **Step 1: Implement building agent HP, footprint, train tick**

- [ ] **Step 2: Implement place + villager construct**

- [ ] **Step 3: HUD resources + train buttons; manual test house + barracks + swordsman**

- [ ] **Step 4: Commit** `feat(buildings): add placement, construction, and training`

---

### Task 9: Combat system

**Files:**
- Create: `scripts/systems/combat_system.gd`
- Modify: `unit_agent.gd` — ATTACK order
- Modify: `building_agent.gd` — take damage, emit `destroyed`
- Modify: `selection_controller_3d.gd` — RMB enemy → attack

**Interfaces:**
- `command_attack(target: Node)` — chase until in `range`, then every `attack_cooldown` apply `CombatMath.apply_armor(atk, target_melee_or_pierce_armor)` where ranged uses pierce armor
- Teutons: when spawning units, `melee_armor += civ.melee_armor_bonus` for melee units / knights
- Building HP uses `def.max_hp * civ.building_hp_mul` at spawn
- On TC `destroyed` for a team → `MatchState.set_winner(other_team)`

- [ ] **Step 1: Extend tests for ranged vs melee armor choice if pure function extracted**

```gdscript
# CombatMath.armor_for(is_ranged_attack: bool, melee_armor: float, pierce_armor: float) -> float
```

- [ ] **Step 2: Implement combat ticks + death removal**

- [ ] **Step 3: Manual test — spawn AI swordsman, order attack, verify HP drops and death**

- [ ] **Step 4: Commit** `feat(combat): add attack orders and armored damage`

---

### Task 10: Match bootstrap both sides + civ select wiring + win UI

**Files:**
- Modify: `scripts/match/match_bootstrap.gd`
- Modify: `scripts/ui/civ_select_controller.gd`
- Modify: `scripts/ui/hud_controller.gd` — win/lose panel, return to civ select
- Modify: `project.godot` main scene stays civ select

**Interfaces:**
- Civ select sets `GameSession.player_civ_id` (autoload) then `change_scene_to_file("res://scenes/match_3d.tscn")`
- Create: `scripts/core/game_session.gd` autoload: `player_civ_id`, `ai_civ_id`
- Bootstrap: symmetric spawns at `(-40,0,-40)` and `(40,0,40)` — TC, 3 villagers (+ Chinese extra), nearby resources; AI team opposite civ
- Starting resources via `MatchState.setup_defaults()`
- When winner set: show panel "胜利" / "失败", stop AI and input orders, button → civ select

- [ ] **Step 1: Add autoload `GameSession` in `project.godot`**

```ini
[autoload]
GameSession="*res://scripts/core/game_session.gd"
```

- [ ] **Step 2: Implement symmetric bootstrap from CivDef**

- [ ] **Step 3: Manual accept — Chinese starts 4 villagers; Teutons start 3; destroy AI TC with debug damage key `F9` optional to test win UI**

- [ ] **Step 4: Commit** `feat(match): wire civ select, dual-base bootstrap, win UI`

---

### Task 11: AI controller

**Files:**
- Create: `scripts/systems/ai_controller.gd`
- Modify: `match_bootstrap.gd` — add AI node with player/ai team refs

**Interfaces:**
- Phases enum `ECO, MILITARY, ATTACK`
- ECO until `villager_count >= 8` (or food stockpile high): keep training villagers; assign idle villagers to food/wood/gold ratio `50/30/20`
- MILITARY: ensure Barracks+Archery (+Stable if Teutons); train unique + swordsman/archer while wood/gold allow; houses when pop blocked
- ATTACK when `military_count >= 6` OR match time `>= 180s`: all military `command_attack` / move toward enemy TC, retarget hostiles in radius `8`
- Re-evaluate every `0.5s`

- [ ] **Step 1: Implement phased AI with clear thresholds as above**

- [ ] **Step 2: Play 3–5 min — AI gathers, builds, trains, pushes; player can win or lose**

- [ ] **Step 3: Commit** `feat(ai): add eco-military-attack AI phases`

---

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

```python
def test_pal_len():
    pal = load_pal(Path(os.environ["AOE2_RES"]) / "_common/dat/pal_2.pal")
    assert len(pal) == 256
```

- [ ] **Step 2: Implement DRS + SLP decode enough to export one UI/known SLP smoke test to `assets/sprites/_smoke/`**

- [ ] **Step 3: Batch export priority list; commit only small PNGs needed + scripts (not full game)**

- [ ] **Step 4: Commit** `feat(tools): add DRS/SLP sprite export pipeline`

---

### Task 13: Replace placeholders with billboard sprites

**Files:**
- Modify: `unit_view.tscn` / `unit_agent.gd` — `AnimatedSprite3D` or `Sprite3D` atlas, `billboard = BASE` / Y-lock
- Modify: buildings/resources to use exported textures
- Modify: ground material to terrain texture from `resources/_common/terrain/textures` copy into `assets/terrain/`

**Interfaces:**
- Direction: quantize velocity yaw into 5 authored dirs + flip (same approach as old elephant) **or** 8-dir if sheet provides; document mapping in `assets/sprites/units/README.md`
- Keep capsule fallback if texture missing (`ResourceLoader.exists`)

- [ ] **Step 1: Hook villager sheet; verify billboard facing camera while feet stay on ground (offset)**

- [ ] **Step 2: Hook remaining units/buildings/resources**

- [ ] **Step 3: Full manual acceptance from spec Testing section**

- [ ] **Step 4: Commit** `feat(art): bind AoE2 sprites to 3D billboard entities`

---

### Task 14: Polish pass + final acceptance

**Files:**
- Modify: HUD styling (readable, not overbuilt)
- Modify: selection ring / move marker decal on ground
- Modify: `.gitignore` — ignore `tools/slp_export/config.json`, large raw dumps, `.godot/` already
- Update: `docs/superpowers/specs/2026-08-05-aoe2-rts-demo-design.md` status to `Approved/Implemented` when done

**Acceptance checklist (all must pass):**
1. Chinese start: 4 villagers; can gather F/W/G; house/barracks/archery/chu ko nu.
2. Teutons start: 3 villagers; stable + teutonic knight; tankier buildings; melee armor felt.
3. Box select, move, attack, train queue (len 1) work.
4. AI ecos, trains, attacks; either TC destroy ends match.
5. Camera pan/zoom/pick accurate.

- [ ] **Step 1: Run checklist, fix blockers only**

- [ ] **Step 2: Commit** `chore: polish HUD markers and finalize demo acceptance`

---

## Spec Coverage Self-Review

| Spec item | Task |
|---|---|
| Remove elephant 2D demo | T1 |
| Godot 3D + billboard + oblique camera | T5, T13 |
| Food/wood/gold | T4, T7 |
| Chinese vs Teutons configs + uniques + bonuses | T3, T10 |
| Buildings list + Teutons stable only | T3, T8 |
| Gather / build / train / attack FSM | T6–T9 |
| AI phases | T11 |
| Win on TC destroy | T9–T10 |
| Offline SLP pipeline + no full game in repo | T12 |
| Manual acceptance | T14 |

No intentional placeholders left in tasks. Types (`MatchState`, `UnitAgent.command_*`, `CivDef` fields) are named consistently across tasks.

## Note on plan size

This is one shippable demo plan (not split), sequenced so each task leaves something runnable. Prefer **subagent-driven-development** per task with review gates after T6, T10, and T13.
