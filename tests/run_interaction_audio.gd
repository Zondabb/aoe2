extends SceneTree

const Commands := preload("res://scripts/input/player_commands.gd")
const Selection := preload("res://scripts/input/selection_controller_2d.gd")
const VILLAGER: UnitDef = preload("res://data/units/villager.tres")
var checks := 0
var failures := 0
var world: Node2D
var selection: SelectionController2D
var audio: AudioStub

class AudioStub extends Node:
	var events: Array[StringName] = []
	var speakers: Array[Node] = []
	func play_unit_voice(unit: Node, action: StringName) -> bool:
		events.append(action)
		speakers.append(unit)
		return true
	func play_event(event: StringName, _category: StringName = &"ui", source: Node = null, _key := "") -> bool:
		events.append(event)
		speakers.append(source)
		return true
	func clear() -> void:
		events.clear()
		speakers.clear()

class Actor extends Node2D:
	var team := 0
	var hp := 100.0
	var def: UnitDef = VILLAGER
	var selected := false
	var moves := 0
	func set_selected(value: bool) -> void: selected = value
	func command_move(_target: Vector2) -> void: moves += 1
	func command_stop() -> void: pass
	func command_attack(_target: Node) -> void: pass
	func command_build(_target: Node) -> void: pass
	func command_gather(_target: Node) -> void: pass

class ResourceStub extends Node2D:
	var resource_type := Enums.ResourceType.WOOD
	var amount := 100.0
	func set_selected(_value: bool) -> void: pass

class NetworkStub extends Node:
	var accepted := false
	var commands: Array[Dictionary] = []
	func entity_id(unit: Node2D) -> int: return unit.get_instance_id()
	func submit_command(command: Dictionary) -> bool:
		commands.append(command)
		return accepted

class ProductionStub extends Node2D:
	var team := 0
	var is_complete := true
	var blocked := false
	var train_queue_ids: Array[int] = []
	func train_blocked_reason(_definition: UnitDef) -> String: return "queue full" if blocked else ""
	func enqueue_train(_definition: UnitDef) -> bool:
		train_queue_ids.append(train_queue_ids.size() + 1)
		return true

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func actor_at(position: Vector2, group := "units", team := 0) -> Actor:
	var actor := Actor.new()
	actor.position = position
	actor.team = team
	world.add_child(actor)
	actor.add_to_group(group)
	return actor

func _run() -> void:
	# Stub only the audio output; exercise the actual selection/input routes.
	var live_audio := root.get_node_or_null("GameAudio")
	if live_audio != null: live_audio.name = "LiveAudioDuringInteractionTest"
	audio = AudioStub.new()
	audio.name = "GameAudio"
	root.add_child(audio)
	world = Node2D.new()
	root.add_child(world)
	selection = Selection.new()
	world.add_child(selection)
	selection.set_process(false)
	var a := actor_at(Vector2(50, 50))
	var b := actor_at(Vector2(90, 50))
	var enemy := actor_at(Vector2(180, 50), "units", 1)
	var building := actor_at(Vector2(240, 50), "buildings")
	var resource := ResourceStub.new()
	resource.position = Vector2(300, 50)
	world.add_child(resource)
	resource.add_to_group("resource_nodes")
	selection._select_click(a.position, false)
	check(audio.events == [&"select"] and audio.speakers == [a], "own unit click speaks once")
	audio.clear()
	selection._select_box(Rect2(30, 30, 90, 50), false)
	check(audio.events == [&"select"] and selection.get_selected_units().size() == 2, "a box-selected group has one speaker")
	audio.clear()
	selection._select_click(a.position, true)
	check(audio.events.is_empty() and selection.get_selected_units() == [b], "Shift deselection does not make the remaining unit speak")
	selection._select_click(enemy.position, false)
	selection._select_click(resource.position, false)
	selection._select_click(Vector2(600, 600), false)
	check(audio.events.is_empty(), "opponent, resource and empty clicks are silent")
	selection._select_click(building.position, false)
	check(audio.events == [&"building_select"] and audio.speakers == [building], "building selection passes the building for its original sound")
	audio.clear()
	selection.read_only = true
	selection._select_click(a.position, false)
	selection.read_only = false
	check(audio.events.is_empty(), "spectator selection is silent")
	selection._add_selection(b, false)
	selection.assign_control_group(1)
	selection._clear_selection()
	check(audio.events.is_empty(), "programmatic selection and clearing are silent")
	selection.recall_control_group(1)
	check(audio.events == [&"select"], "recalling a group has one speaker")
	audio.clear()
	a.hp = 0
	selection._process(0)
	check(audio.events.is_empty() and selection.get_selected_units() == [b], "death cleanup does not replay selection voices")
	a.hp = 100
	Commands.unit_order(selection, a, "move", Vector2(10, 10))
	Commands.unit_order(selection, b, "move", Vector2(15, 10))
	check(audio.events == [&"move"] and a.moves == 1 and b.moves == 1, "a local group move issues all commands with one acknowledgement")
	audio.clear()
	a.command_move(Vector2.ZERO)
	check(audio.events.is_empty(), "direct AI and replicated unit orders stay silent")
	await process_frame
	await process_frame
	Commands.unit_order(selection, a, "gather", resource)
	check(audio.events == [&"gather_wood"], "gather acknowledgement uses the resource type")
	audio.clear()
	await process_frame
	var network := NetworkStub.new()
	network.name = "NetworkMatch"
	world.add_child(network)
	world.set_meta("online_match", true)
	Commands.unit_order(selection, a, "move", Vector2.ZERO)
	check(audio.events.is_empty(), "a locally rejected online order has no acknowledgement")
	network.accepted = true
	Commands.unit_order(selection, a, "stop")
	Commands.unit_order(selection, b, "stop")
	check(audio.events == [&"stop"] and network.commands.size() == 3, "accepted guest group commands speak only on the local input route")
	audio.clear()
	await process_frame
	Commands.unit_order(selection, enemy, "stop")
	a.hp = 0
	Commands.unit_order(selection, a, "stop")
	check(audio.events.is_empty(), "opponents and dead units cannot acknowledge local orders")
	a.hp = 100
	world.set_meta("online_match", false)
	_test_training_feedback()
	world.free()
	audio.free()
	if live_audio != null: live_audio.name = "GameAudio"
	await process_frame
	print("INTERACTION AUDIO: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _test_training_feedback() -> void:
	var hud: Node = load("res://scenes/ui/hud.tscn").instantiate()
	world.add_child(hud)
	hud.set_process(false)
	var production := ProductionStub.new()
	world.add_child(production)
	var state := MatchState.new()
	state.setup_defaults()
	hud.match_state = state
	hud._selected_building = production
	audio.clear()
	hud._enqueue_train(VILLAGER)
	check(audio.events == [&"click"] and production.train_queue_ids.size() == 1, "accepted production gives one click feedback")
	audio.clear()
	production.blocked = true
	hud._enqueue_train(VILLAGER)
	check(audio.events == [&"error"] and production.train_queue_ids.size() == 1, "blocked production gives error feedback without queue mutation")
	audio.clear()
	production.blocked = false
	world.set_meta("online_match", true)
	var network := world.get_node("NetworkMatch") as NetworkStub
	network.accepted = false
	hud._enqueue_train(VILLAGER)
	check(audio.events == [&"error"], "rejected online production uses error feedback")
	hud.free()
