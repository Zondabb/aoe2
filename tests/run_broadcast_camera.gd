extends SceneTree

var checks := 0
var failures := 0

class GuestNetwork extends Node:
	var is_host := false
	var _playing := true
	var synchronized := true
	var _terminal := false

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)

func _run() -> void:
	root.get_node("GameSession").match_ai_mode = "local"
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	var control := world.get_node("PlayerAiControl")
	var camera := world.get_node("Camera2D") as RtsCamera2D
	var director := camera.get_node("BroadcastDirector")
	var toggle := world.get_node("UILayer/AiAutoplayControls/Panel/Row/BroadcastCamera") as CheckBox
	var entities := world.get_node("Entities")
	var state: MatchState = control.match_state
	var town: BuildingAgent
	var soldier: UnitAgent
	for entity in entities.get_children():
		if entity is BuildingAgent and entity.team == 0 and entity.def.id == &"town_center": town = entity
		if entity is UnitAgent and entity.team == 0: soldier = entity
	check(not camera.broadcast_following and not toggle.visible, "manual player keeps camera control")
	control._set_state(1, true, "active", "")
	control._set_state(0, true, "connecting", "")
	check(not camera.broadcast_following, "opponent control and connecting state don't take the camera")
	control._set_state(0, true, "active", "")
	check(camera.broadcast_following and toggle.visible and toggle.button_pressed, "local active takeover enables broadcast by default")
	camera.limit_to_map_bounds = false
	state.fog_enabled = false
	var now := Time.get_ticks_msec()
	var fight := Vector2(100, -100)
	soldier.sim_pos = fight
	soldier.take_damage(1.0)
	town.unit_trained.emit(soldier)
	town.construction_completed.emit(town)
	director._choose_shot(now)
	check(camera.position == IsoMath.world_to_screen(fight), "battle outranks completion and training and cuts to distant action")
	director._choose_shot(now + 1000)
	check(camera.position == IsoMath.world_to_screen(fight), "battle shot holds against lower priority events")
	director._choose_shot(now + director.SHOT_MS + 1)
	check(camera.position == IsoMath.world_to_screen(town.sim_pos), "recent construction gets a shot during a lull")

	toggle.button_pressed = false
	check(not camera.broadcast_following and control.local_state().enabled, "manual camera leaves AI in charge of units")
	toggle.button_pressed = true
	camera.focus_on(Vector2.ZERO)
	soldier.damaged.emit(soldier)
	director._choose_shot(Time.get_ticks_msec())
	check(camera.position == Vector2.ZERO, "minimap focus temporarily overrides live events")
	director._choose_shot(director._manual_until + 1)
	check(camera.position == IsoMath.world_to_screen(fight), "recent battle resumes after manual hold")

	toggle.button_pressed = false
	toggle.button_pressed = true
	var recruit := UnitAgent.new()
	recruit.sim_pos = Vector2.ZERO
	entities.add_child(recruit)
	town.unit_trained.emit(recruit)
	director._choose_shot(Time.get_ticks_msec())
	check(camera.position == Vector2.ZERO, "newly trained unit can be framed")
	recruit.sim_pos = IsoMath.screen_to_world(Vector2(root.get_visible_rect().size.x * 0.45, 0))
	recruit.damaged.emit(recruit)
	director._choose_shot(Time.get_ticks_msec())
	check(director._pan != null and camera.position == Vector2.ZERO, "nearby fight on newly added unit starts a smooth pan")
	camera._set_zoom(1.2)
	check(director._pan == null and is_equal_approx(camera.zoom.x, 1.2), "manual zoom cancels the moving shot")
	toggle.button_pressed = false
	toggle.button_pressed = true
	state.fog_enabled = true
	state.fog.reset()
	recruit.damaged.emit(recruit)
	check(not director._latest.has(director.Interest.BATTLE), "hidden combat does not register a shot")
	var cell: Vector2i = state.fog.cell_at(recruit.sim_pos)
	var index: int = cell.y * state.fog.side + cell.x
	state.fog.visible_now[0][index] = 1
	recruit.damaged.emit(recruit)
	state.fog.visible_now[0][index] = 0
	director._choose_shot(Time.get_ticks_msec())
	check(camera.position == Vector2.ZERO and director._pan == null, "lost visibility is rechecked before framing")
	state.fog.visible_now[0][index] = 1
	recruit.damaged.emit(recruit)
	director._choose_shot(Time.get_ticks_msec() + director.RECENT_MS + 1)
	check(director._latest.is_empty() and director._pan == null, "expired events don't cause late cuts")

	var network := GuestNetwork.new()
	network.name = "NetworkMatch"
	world.add_child(network)
	control.online = true
	control.local_team = 1
	var active := {"enabled": true, "status": "active", "message": ""}
	var off := {"enabled": false, "status": "off", "message": ""}
	control.apply_remote_states({"0": active, "1": off})
	check(not camera.broadcast_following, "host takeover alone doesn't move the guest's camera")
	control.apply_remote_states({"0": off, "1": active})
	check(camera.broadcast_following, "replicated local-team takeover enables the guest's camera")
	recruit.damaged.emit(recruit)
	check(not director._latest.has(director.Interest.BATTLE), "team one cannot frame a fight visible only to team zero")
	state.fog.visible_now[1][index] = 1
	recruit.damaged.emit(recruit)
	director._choose_shot(Time.get_ticks_msec())
	check(director._pan != null, "guest frames the fight when their own fog reveals it")
	control.apply_remote_states({"0": active, "1": off})
	check(not camera.broadcast_following and director._pan == null, "remote cancellation interrupts the guest shot")
	control.apply_remote_states({"0": off, "1": active})
	control.stop_all()
	check(not camera.broadcast_following and not toggle.visible, "match end returns the view to manual control")
	world.free()
	print("BROADCAST CAMERA: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
