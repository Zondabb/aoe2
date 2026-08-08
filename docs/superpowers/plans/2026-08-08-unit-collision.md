# Unit Collision Volume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add logical unit collision so units soft-separate from each other and hard-block against building footprints, without pathfinding.

**Architecture:** Pure simulation-space resolver (`CollisionResolver`) adjusts `sim_pos` after each intended step. Units are circles (`UnitDef.collision_radius`); buildings stay axis-aligned boxes (`BuildingDef.footprint`). `UnitAgent` is the only integration point that writes movement positions.

**Tech Stack:** Godot 4.7 GDScript, existing headless `tests/run_tests.gd`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-08-unit-collision-design.md`
- Coordinates: logical xz via `sim_pos` only; do not use Godot physics bodies
- Unit↔unit: soft separate (move self only, factor 0.5)
- Unit↔building: hard block with axis slide / stop; no A*
- Resources do not block
- Default radius `0.35` if unset / non-positive
- Commits: Conventional Commits (`type(scope): English subject`, Chinese body when needed)
- Godot binary (Windows): `D:\Users\jiangzw\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64.exe`
- Test command:  
  `& "D:\Users\jiangzw\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64.exe" --headless --path "D:\Users\jiangzw\workspace\godot_game\aoe2" -s res://tests/run_tests.gd`

---

## File Structure

| Path | Responsibility |
|---|---|
| `scripts/systems/collision_resolver.gd` | Circle/AABB resolve + soft unit push |
| `scripts/data/unit_def.gd` | Export `collision_radius` |
| `scripts/entities/unit_agent.gd` | Call resolver whenever movement writes `sim_pos` |
| `tests/test_collision_resolver.gd` | Headless unit tests for resolver |
| `tests/run_tests.gd` | Register new test module |
| `data/units/*.tres` | Optional explicit radii (default from script is enough) |

---

### Task 1: CollisionResolver + headless tests

**Files:**
- Create: `scripts/systems/collision_resolver.gd`
- Create: `tests/test_collision_resolver.gd`
- Modify: `tests/run_tests.gd`

**Interfaces:**
- Consumes: `UnitDef`, `BuildingDef`, objects with `sim_pos` / `def`
- Produces:
  - `CollisionResolver.unit_radius(unit: Object) -> float`
  - `CollisionResolver.resolve_move(unit: Object, from_pos: Vector2, desired_pos: Vector2, units: Array, buildings: Array) -> Vector2`
  - Constants: `DEFAULT_RADIUS := 0.35`, `UNIT_SOFT_FACTOR := 0.5`, `UNIT_QUERY_RANGE := 3.0`, `BUILDING_ITERATIONS := 3`

- [ ] **Step 1: Write failing tests**

Create `tests/test_collision_resolver.gd`:

```gdscript
extends RefCounted

const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")
const HOUSE: BuildingDef = preload("res://data/buildings/house.tres")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_building_push_out(failures)
	_test_unit_soft_separate(failures)
	_test_wall_slide_keeps_tangent(failures)
	return failures

func _make_unit(pos: Vector2, radius: float = 0.35) -> Object:
	var u := Node2D.new()
	var def := UnitDef.new()
	def.collision_radius = radius
	u.set("def", def)
	u.set("sim_pos", pos)
	return u

func _make_building(pos: Vector2, footprint: Vector2 = Vector2(2, 2)) -> Object:
	var b := Node2D.new()
	var def := BuildingDef.new()
	def.footprint = footprint
	b.set("def", def)
	b.set("sim_pos", pos)
	return b

func _test_building_push_out(failures: Array[String]) -> void:
	var unit := _make_unit(Vector2(0, 0))
	var building := _make_building(Vector2(0, 0), Vector2(2, 2))
	# Desired center overlaps house AABB expanded by radius.
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, Vector2(-2, 0), Vector2(0, 0), [], [building]
	)
	var half := Vector2(1, 1) + Vector2(0.35, 0.35)
	if absf(resolved.x) < half.x and absf(resolved.y) < half.y:
		failures.append("unit should be pushed outside building expanded AABB, got %s" % resolved)
	unit.free()
	building.free()

func _test_unit_soft_separate(failures: Array[String]) -> void:
	var self_unit := _make_unit(Vector2(0, 0), 0.35)
	var other := _make_unit(Vector2(0.2, 0.0), 0.35)
	var before := self_unit.get("sim_pos").distance_to(other.get("sim_pos"))
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		self_unit, Vector2(0, 0), Vector2(0, 0), [self_unit, other], []
	)
	var after := resolved.distance_to(other.get("sim_pos"))
	if after <= before + 0.001:
		failures.append("soft separate should increase distance, before=%s after=%s" % [before, after])
	if after >= 0.35 + 0.35:
		failures.append("soft separate should not fully hard-block (got full separation %s)" % after)
	self_unit.free()
	other.free()

func _test_wall_slide_keeps_tangent(failures: Array[String]) -> void:
	# Building occupies x in [-1,1], y in [-1,1]. Unit radius 0.35 → solid expanded x in [-1.35,1.35].
	var unit := _make_unit(Vector2(-2.0, 0.0), 0.35)
	var building := _make_building(Vector2(0, 0), Vector2(2, 2))
	var from_pos := Vector2(-2.0, 0.0)
	var desired := Vector2(-1.0, 0.8) # into the wall + upward
	var resolved: Vector2 = CollisionResolverScript.resolve_move(
		unit, from_pos, desired, [], [building]
	)
	if absf(resolved.x) < 1.35 - 0.001:
		failures.append("slide must not enter building on X, got %s" % resolved)
	if resolved.y < 0.4:
		failures.append("slide should keep most of tangent Y motion, got %s" % resolved)
	unit.free()
	building.free()
```

Add to `tests/run_tests.gd` after sprite catalog line:

```gdscript
failures.append_array(load("res://tests/test_collision_resolver.gd").new().run())
```

- [ ] **Step 2: Run tests to verify they fail**

Run the Godot test command above.

Expected: FAIL (missing `collision_resolver.gd` and/or `UnitDef.collision_radius`).

- [ ] **Step 3: Add `UnitDef.collision_radius` (needed by tests)**

In `scripts/data/unit_def.gd`, after `move_speed`:

```gdscript
@export var collision_radius: float = 0.35
```

Do not require editing every `.tres` (default applies).

- [ ] **Step 4: Implement `CollisionResolver`**

Create `scripts/systems/collision_resolver.gd`:

```gdscript
class_name CollisionResolver
extends RefCounted

const DEFAULT_RADIUS := 0.35
const UNIT_SOFT_FACTOR := 0.5
const UNIT_QUERY_RANGE := 3.0
const BUILDING_ITERATIONS := 3

static func unit_radius(unit: Object) -> float:
	if unit == null:
		return DEFAULT_RADIUS
	var unit_def := unit.get("def") as UnitDef
	if unit_def != null and unit_def.collision_radius > 0.0:
		return unit_def.collision_radius
	return DEFAULT_RADIUS

static func resolve_move(
	unit: Object,
	from_pos: Vector2,
	desired_pos: Vector2,
	units: Array,
	buildings: Array
) -> Vector2:
	var radius := unit_radius(unit)
	var pos := _slide_against_buildings(from_pos, desired_pos, radius, buildings)
	for _i in BUILDING_ITERATIONS:
		pos = _push_out_buildings(pos, radius, buildings)
	pos = _soft_separate_units(unit, pos, radius, units)
	for _i in BUILDING_ITERATIONS:
		pos = _push_out_buildings(pos, radius, buildings)
	return pos

static func _hits_building(pos: Vector2, radius: float, building: Object) -> bool:
	var building_def := building.get("def") as BuildingDef
	if building_def == null:
		return false
	var center: Vector2 = building.get("sim_pos")
	var half := building_def.footprint * 0.5 + Vector2(radius, radius)
	var delta := pos - center
	return absf(delta.x) < half.x and absf(delta.y) < half.y

static func _hits_any_building(pos: Vector2, radius: float, buildings: Array) -> bool:
	for value in buildings:
		var building := value as Object
		if building == null or not is_instance_valid(building):
			continue
		if _hits_building(pos, radius, building):
			return true
	return false

static func _push_out_buildings(pos: Vector2, radius: float, buildings: Array) -> Vector2:
	var result := pos
	for value in buildings:
		var building := value as Object
		if building == null or not is_instance_valid(building):
			continue
		var building_def := building.get("def") as BuildingDef
		if building_def == null:
			continue
		var center: Vector2 = building.get("sim_pos")
		var half := building_def.footprint * 0.5 + Vector2(radius, radius)
		var delta := result - center
		if absf(delta.x) >= half.x or absf(delta.y) >= half.y:
			continue
		var pen_x := half.x - absf(delta.x)
		var pen_y := half.y - absf(delta.y)
		if pen_x < pen_y:
			var sx := 1.0 if delta.x >= 0.0 else -1.0
			result.x = center.x + sx * half.x
		else:
			var sy := 1.0 if delta.y >= 0.0 else -1.0
			result.y = center.y + sy * half.y
	return result

static func _slide_against_buildings(
	from_pos: Vector2,
	desired_pos: Vector2,
	radius: float,
	buildings: Array
) -> Vector2:
	if not _hits_any_building(desired_pos, radius, buildings):
		return desired_pos
	var slide_x := Vector2(desired_pos.x, from_pos.y)
	var slide_y := Vector2(from_pos.x, desired_pos.y)
	var ok_x := not _hits_any_building(slide_x, radius, buildings)
	var ok_y := not _hits_any_building(slide_y, radius, buildings)
	if ok_x and ok_y:
		if absf(desired_pos.x - from_pos.x) >= absf(desired_pos.y - from_pos.y):
			return slide_x
		return slide_y
	if ok_x:
		return slide_x
	if ok_y:
		return slide_y
	return from_pos

static func _soft_separate_units(
	unit: Object,
	pos: Vector2,
	radius: float,
	units: Array
) -> Vector2:
	var result := pos
	for value in units:
		var other := value as Object
		if other == null or other == unit or not is_instance_valid(other):
			continue
		var other_pos: Vector2 = other.get("sim_pos")
		var offset := result - other_pos
		var dist := offset.length()
		if dist > UNIT_QUERY_RANGE:
			continue
		var other_r := unit_radius(other)
		var min_dist := radius + other_r
		if dist >= min_dist:
			continue
		if dist <= 0.0001:
			offset = Vector2(1, 0)
			dist = 1.0
		var overlap := min_dist - dist
		result += offset.normalized() * (overlap * UNIT_SOFT_FACTOR)
	return result
```

- [ ] **Step 5: Run tests to verify they pass**

Run the Godot test command.

Expected: `ALL TESTS PASSED` (or at least collision tests pass; fix failures if any).

- [ ] **Step 6: Commit**

```bash
git add scripts/data/unit_def.gd scripts/systems/collision_resolver.gd tests/test_collision_resolver.gd tests/run_tests.gd
git commit -m "feat(units): add logical collision resolver"
```

PowerShell message body optional:

```text
feat(units): add logical collision resolver

单位圆与建筑 footprint 硬挡、单位软分离；附 headless 测试。
```

---

### Task 2: Wire UnitAgent movement through CollisionResolver

**Files:**
- Modify: `scripts/entities/unit_agent.gd`

**Interfaces:**
- Consumes: `CollisionResolver.resolve_move(unit, from_pos, desired_pos, units, buildings) -> Vector2`
- Produces: all `sim_pos` writes from `_process_move` / `_move_toward` go through resolver

- [ ] **Step 1: Preload resolver and add helper**

Near top of `unit_agent.gd` with other preloads:

```gdscript
const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")
```

Add private helper (near `_move_toward`):

```gdscript
func _apply_resolved_position(from_pos: Vector2, desired_pos: Vector2) -> void:
	var units: Array = []
	var buildings: Array = []
	var tree := get_tree()
	if tree != null:
		units = tree.get_nodes_in_group("units")
		buildings = tree.get_nodes_in_group("buildings")
	sim_pos = CollisionResolverScript.resolve_move(self, from_pos, desired_pos, units, buildings)
```

- [ ] **Step 2: Update `_process_move`**

Replace the arrival + step body so both paths resolve:

```gdscript
func _process_move(delta: float) -> void:
	var offset := _move_target - sim_pos
	var distance := offset.length()
	if distance <= ARRIVAL_DISTANCE:
		var from_pos := sim_pos
		_apply_resolved_position(from_pos, _move_target)
		_sync_visual()
		order = Enums.OrderType.NONE
		_update_idle_animation(0.0)
		return
	var step := minf(def.move_speed * delta, distance)
	var velocity := offset.normalized() * step
	var from_pos := sim_pos
	_apply_resolved_position(from_pos, from_pos + velocity)
	_sync_visual()
	_update_billboard_facing(sim_pos - from_pos, delta, true)
```

- [ ] **Step 3: Update `_move_toward`**

```gdscript
func _move_toward(target: Vector2, delta: float) -> void:
	var offset := target - sim_pos
	var distance := offset.length()
	if distance <= ARRIVAL_DISTANCE:
		if _villager_actions:
			_update_idle_animation(0.0)
		else:
			_apply_billboard_frame(false)
		return
	var step := minf(def.move_speed * delta, distance)
	var velocity := offset.normalized() * step
	var from_pos := sim_pos
	_apply_resolved_position(from_pos, from_pos + velocity)
	_sync_visual()
	_update_billboard_facing(sim_pos - from_pos, delta, true)
```

Note: on arrival in `_move_toward`, do **not** snap into the target if that would ignore collision; current early-return already stops without snapping into walls. Keep that behavior.

- [ ] **Step 4: Run full test suite**

Run the Godot test command.

Expected: `ALL TESTS PASSED`.

If `test_buildings.gd` villager construction fails because villager can no longer stand on incomplete house center: adjust that test’s villager start to outside footprint (e.g. `Vector2(2.5, 0)`) **only if** needed — construction range already allows approach from outside.

- [ ] **Step 5: Commit**

```bash
git add scripts/entities/unit_agent.gd
# include tests/test_buildings.gd only if adjusted
git commit -m "feat(units): apply collision resolver to unit movement"
```

Body:

```text
移动与接近目标时经 CollisionResolver 校正 sim_pos，避免穿建筑与重叠堆叠。
```

---

### Task 3: Manual acceptance checklist (no code)

**Files:** none

- [ ] **Step 1: Launch match in editor**

Open project in Godot 4.7, F5 → pick civ → enter `match_2d`.

- [ ] **Step 2: Verify building hard block**

Select villagers, right-click through Town Center / house. Units stop or slide on edges; do not walk through.

- [ ] **Step 3: Verify unit soft separate**

Stack-order several villagers on one point; they should ease apart but still be able to crowd.

- [ ] **Step 4: Confirm non-goals**

No pathfinding around buildings (head-on stop is OK). Resources still walkable.

---

## Spec coverage self-review

| Spec item | Task |
|---|---|
| `UnitDef.collision_radius` default 0.35 | Task 1 |
| Building footprint hard block | Task 1 |
| Unit soft separate (self only, factor ~0.5) | Task 1 |
| Axis slide / stop, no A* | Task 1 |
| Integrate `_process_move` / `_move_toward` | Task 2 |
| Arrival path resolved | Task 2 (`_process_move`) |
| Headless tests for push / soft / slide | Task 1 |
| Resources not blocking | Implicit (not queried) |
| Manual acceptance | Task 3 |

No placeholders remaining. API uses `from_pos` in addition to `desired_pos` so wall-slide can preserve tangent motion (required by spec tests).
