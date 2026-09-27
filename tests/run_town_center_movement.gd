extends SceneTree

const Agent := preload("res://scripts/entities/unit_agent.gd")
const Building := preload("res://scripts/entities/building_agent.gd")
const Holder := preload("res://scripts/systems/nav_service_holder.gd")
const Selection := preload("res://scripts/input/selection_controller_2d.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
const BuildSystemScript := preload("res://scripts/systems/build_system.gd")

var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	for suite in ["test_collision_resolver", "test_nav_grid_service", "test_economy", "test_buildings"]:
		var errors: Array = load("res://tests/%s.gd" % suite).new().run()
		check(errors.is_empty(), "%s: %s" % [suite, str(errors)])
	for civilization in ["chinese", "teutons"]:
		_test_right_click_and_crossing(civilization)
	print("TOWN CENTER MOVEMENT: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_right_click_and_crossing(civilization: String) -> void:
	var world := Node2D.new()
	world.name = "Match"
	root.add_child(world)
	var state := MatchState.new()
	state.setup_defaults()
	var holder := Holder.new()
	holder.setup(-20, 20)
	world.add_child(holder)
	holder.set_process(false)
	var town_center := Building.new()
	town_center.def = load("res://data/buildings/town_center.tres")
	town_center.civ = load("res://data/civs/%s.tres" % civilization)
	town_center.match_state = state
	town_center.sim_pos = Vector2(3, 3)
	world.add_child(town_center)
	var unit := Agent.new()
	unit.def = load("res://data/units/villager.tres")
	unit.match_state = state
	unit.sim_pos = town_center.sim_pos + Vector2(-6, 0)
	world.add_child(unit)
	unit.set_physics_process(false)
	var selection := Selection.new()
	world.add_child(selection)
	selection._add_selection(unit)
	holder.rebuild_from_scene()
	check(not holder.nav.is_world_solid(town_center.sim_pos), "%s: town center is open in the live scene grid" % civilization)
	check(not BuildSystemScript.can_place(Vector2(2, 2), town_center.sim_pos, [town_center]), "%s: open town center still reserves its construction footprint" % civilization)
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	click.position = root.get_canvas_transform() * Iso.world_to_screen(town_center.sim_pos)
	selection._unhandled_input(click)
	check(unit.order == Enums.OrderType.MOVE, "%s: right click at town center issues a move order" % civilization)
	check(unit._move_target.is_equal_approx(town_center.sim_pos), "%s: right click destination remains inside town center" % civilization)
	_advance_until_arrival(unit, holder)
	check(unit.order == Enums.OrderType.NONE and unit.sim_pos.distance_to(town_center.sim_pos) < 0.5, "%s: unit arrives underneath town center" % civilization)
	for direction in [Vector2.RIGHT, Vector2.DOWN, Vector2.ONE.normalized()]:
		unit.sim_pos = town_center.sim_pos - direction * 6.0
		var target: Vector2 = town_center.sim_pos + direction * 6.0
		unit.command_move(target)
		var crossed_center := _advance_until_arrival(unit, holder, town_center.sim_pos)
		check(crossed_center, "%s: unit crosses town center interior along %s" % [civilization, direction])
		check(unit.order == Enums.OrderType.NONE and unit.sim_pos.distance_to(target) < 0.5, "%s: unit exits town center and reaches its target" % civilization)
	world.free()
	CollisionResolver.clear_map_bounds()

func _advance_until_arrival(unit: UnitAgent, holder: NavServiceHolder, center := Vector2.INF) -> bool:
	var crossed_center := false
	for frame in 600:
		var paths := holder.nav.flush_pending_paths()
		for id in paths:
			instance_from_id(id).apply_nav_path(paths[id])
		unit._physics_process(1.0 / 30.0)
		if unit.sim_pos.distance_to(center) < 1.0:
			crossed_center = true
		if unit.order == Enums.OrderType.NONE:
			break
	return crossed_center
