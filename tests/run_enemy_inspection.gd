extends SceneTree

const Selection := preload("res://scripts/input/selection_controller_2d.gd")
const UnitScene := preload("res://scenes/entities/unit_view.tscn")
const BuildingScene := preload("res://scenes/entities/building_view.tscn")
const Villager: UnitDef = preload("res://data/units/villager.tres")
const Barracks: BuildingDef = preload("res://data/buildings/barracks.tres")
const Civ: CivDef = preload("res://data/civs/chinese.tres")

class TestFog extends RefCounted:
	var hidden: Array = []
	var debug_mode := false
	func view_can_see(entity: Node) -> bool:
		return entity not in hidden

var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var world := Node2D.new()
	world.name = "Match"
	root.add_child(world)
	var fog := TestFog.new()
	world.set_meta("fog_holder", fog)
	var state := MatchState.new()
	state.setup_defaults()
	var selection := Selection.new()
	world.add_child(selection)
	selection.set_process(false)
	# Load after autoload registration: HUD references the network/session singletons.
	var hud := load("res://scenes/ui/hud.tscn").instantiate() as Control
	world.add_child(hud)
	hud.set_process(false)
	var own := _unit(world, state, Enums.Team.PLAYER, Vector2.ZERO)
	var enemy := _unit(world, state, Enums.Team.AI, Vector2(20, 0))
	var other_enemy := _unit(world, state, Enums.Team.AI, Vector2(40, 0))
	var building := BuildingScene.instantiate() as BuildingAgent
	building.def = Barracks
	building.civ = Civ
	building.team = Enums.Team.AI
	building.match_state = state
	building.sim_pos = Vector2(20, 25)
	world.add_child(building)
	building.set_physics_process(false)
	hud.setup(state, Civ, null, selection)
	enemy.hp = 17.0
	enemy.carry_amount = 5.0
	_click(selection, enemy)
	check(selection.get_primary_selection() == enemy, "left click inspects a visible enemy unit")
	check(not (hud.get_node("%NameLabel") as Label).text.is_empty(), "enemy inspection displays its name")
	check((hud.get_node("%HpLabel") as Label).text == "17 / %d" % Villager.max_hp, "enemy inspection displays current and maximum health")
	check((hud.get_node("%CountLabel") as Label).text == "对手", "inspection marks opponent ownership")
	check("攻击" in (hud.get_node("%StatsLabel") as Label).text, "enemy inspection displays basic combat stats")
	check((hud.get_node("%QueueLabel") as Label).text.is_empty(), "enemy inspection keeps carried resources private")
	check("仅可查看" in (hud.get_node("%CommandHint") as Label).text, "enemy inspection clearly states it is read-only")
	check(_command_count(hud) == 0, "enemy unit inspection exposes no commands")
	enemy.command_move(Vector2(60, 80))
	selection._issue_move(Vector2(80, 80))
	selection._issue_attack(own)
	selection._issue_gather(building)
	selection._issue_build(building)
	hud._stop_selected_units()
	check(enemy.order == Enums.OrderType.MOVE and enemy._move_target == Vector2(60, 80), "world and HUD commands cannot change an inspected enemy's existing order")
	var stop_key := InputEventKey.new()
	stop_key.keycode = KEY_S
	stop_key.pressed = true
	hud._unhandled_key_input(stop_key)
	check(enemy.order == Enums.OrderType.MOVE, "enemy inspection cannot stop the opponent via a hotkey")
	enemy.hp = 9.0
	hud._refresh_info_panel()
	check((hud.get_node("%HpLabel") as Label).text.begins_with("9 /"), "enemy health updates while inspected")
	_click(selection, own, true)
	check(selection._selected == [own], "Shift-clicking own unit replaces enemy inspection")
	_click(selection, enemy, true)
	check(selection._selected == [enemy], "Shift-clicking enemy cannot append it to an own command group")
	_click(selection, other_enemy, true)
	check(selection._selected == [other_enemy], "Shift-clicking a second enemy replaces the inspection target")
	selection._select_box(Rect2(Vector2(-1000, -1000), Vector2(4000, 4000)), false)
	check(selection._selected == [own], "box selection includes only own units")
	_click(selection, enemy)
	selection._select_box(Rect2(Vector2(-1000, -1000), Vector2(4000, 4000)), true)
	check(selection._selected == [own], "additive box selection cannot mix enemy and own units")
	building.hp = 123.0
	building.train_queue.append(Villager)
	_click(selection, building)
	check(selection.get_selected_building() == building, "left click also inspects visible enemy buildings")
	check((hud.get_node("%HpLabel") as Label).text.begins_with("123 /"), "enemy building inspection displays its health")
	check(_command_count(hud) == 0 and not (hud.get_node("%ProductionQueue") as Control).visible, "enemy building has no training or queue controls")
	check((hud.get_node("%QueueLabel") as Label).text.is_empty(), "enemy building production details remain private")
	var train_key := InputEventKey.new()
	train_key.keycode = KEY_C
	train_key.pressed = true
	hud._unhandled_key_input(train_key)
	check(building.train_queue.size() == 1, "enemy building training cannot be triggered via a hotkey")
	fog.hidden.append(enemy)
	_click(selection, enemy)
	check(selection.get_primary_selection() == null, "hidden enemy cannot be selected through fog")
	check(selection._enemy_at_screen(_screen_point(selection, enemy)) == null, "hidden enemy cannot become a right-click attack target")
	fog.hidden.clear()
	_click(selection, enemy)
	fog.hidden.append(enemy)
	hud._refresh_info_panel()
	check((hud.get_node("%NameLabel") as Label).text.is_empty() and (hud.get_node("%HpLabel") as Label).text.is_empty(), "HUD clears enemy information immediately after losing vision")
	selection._process(0.01)
	check(selection.get_primary_selection() == null, "losing vision clears enemy selection")
	fog.hidden.clear()
	_click(selection, other_enemy)
	other_enemy.queue_free()
	selection._process(0.01)
	check(selection.get_primary_selection() == null and (hud.get_node("%NameLabel") as Label).text.is_empty(), "enemy removal clears inspection and HUD safely")
	world.set_meta("local_team", Enums.Team.AI)
	_click(selection, own)
	check(selection.get_primary_selection() == own and _command_count(hud) == 0, "opponent inspection follows match-local team for online player two")
	selection._select_box(Rect2(Vector2(-1000, -1000), Vector2(4000, 4000)), false)
	check(selection._selected == [enemy], "box selection follows the match-local team")
	world.set_meta("local_team", Enums.Team.PLAYER)
	selection.select_all_teams = true
	selection.read_only = true
	selection._select_box(Rect2(Vector2(-1000, -1000), Vector2(4000, 4000)), false)
	check(selection._selected.has(own) and selection._selected.has(enemy), "spectator mode retains selection across teams")
	world.free()
	await process_frame
	check(checks >= 29, "all enemy inspection test sections completed")
	print("ENEMY INSPECTION: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _unit(world: Node, state: MatchState, team: Enums.Team, position: Vector2) -> UnitAgent:
	var unit := UnitScene.instantiate() as UnitAgent
	unit.def = Villager
	unit.civ = Civ
	unit.team = team
	unit.match_state = state
	unit.sim_pos = position
	world.add_child(unit)
	unit.set_physics_process(false)
	return unit

func _screen_point(selection: SelectionController2D, entity: Node2D) -> Vector2:
	return root.get_canvas_transform() * selection._visual_rect_canvas(entity).get_center()

func _click(selection: SelectionController2D, entity: Node2D, additive := false) -> void:
	selection._select_click(_screen_point(selection, entity), additive)

func _command_count(hud: Control) -> int:
	var count := 0
	for child in hud.get_node("%CommandGrid").get_children():
		if child is BaseButton:
			count += 1
	return count
