extends Node

## Local shots for an AI-controlled player's stream. All positions are snapshots
## of visible events, so a shot never tracks a unit that disappeared into fog.
const PlayerAi := preload("res://scripts/ai_gateway/player_ai_control.gd")
enum Interest { BASE, PRODUCTION, CONSTRUCTION, BATTLE }
const SHOT_MS := 4500
const RECENT_MS := 9000
const MANUAL_MS := 7000

var follow_enabled := true
var _camera: RtsCamera2D
var _control: PlayerAi
var _latest := {}
var _hold_until := 0
var _manual_until := 0
var _shot_priority := -1
var _pan: Tween

func setup(camera: RtsCamera2D, control: PlayerAi) -> void:
	_camera = camera
	_control = control
	set_process(false)
	_camera.manual_navigation.connect(_on_manual_navigation)
	_control.state_changed.connect(_sync)
	_sync()

func set_follow_enabled(value: bool) -> void:
	follow_enabled = value
	_sync()

func _sync() -> void:
	var state := _control.local_state()
	var active: bool = follow_enabled and bool(state.available) and bool(state.enabled) and state.status == "active"
	if active == is_processing(): return
	set_process(active)
	_camera.broadcast_following = active
	_stop_pan()
	_latest.clear()
	_hold_until = 0
	_manual_until = 0
	_shot_priority = -1
	if not active: return
	var entities := _control.entities
	if not entities.child_entered_tree.is_connected(_watch):
		entities.child_entered_tree.connect(_watch)
		for child in entities.get_children():
			_watch(child)
	for child in entities.get_children():
		if child is BuildingAgent and child.team == _control.local_team and child.def != null and child.def.id == &"town_center" and child.is_complete and not child.is_placement_ghost:
			_notice(child, Interest.BASE)
			break

func _watch(entity: Node) -> void:
	if entity is UnitAgent or entity is BuildingAgent:
		var hit := _notice.bind(Interest.BATTLE)
		if not entity.damaged.is_connected(hit): entity.damaged.connect(hit)
	if entity is BuildingAgent:
		var completion := _notice.bind(Interest.CONSTRUCTION)
		if not entity.construction_completed.is_connected(completion):
			entity.construction_completed.connect(completion)
			entity.unit_trained.connect(_notice.bind(Interest.PRODUCTION))

func _visible(point: Vector2) -> bool:
	var state := _control.match_state
	return not state.fog_enabled or (state.fog != null and state.fog.state_at(_control.local_team, point) == FogOfWarService.State.VISIBLE)

func _notice(entity: Node, priority: int) -> void:
	if not is_processing() or entity.get_parent() != _control.entities or entity.has_meta("network_replica") or entity.get("is_placement_ghost") == true: return
	var point: Vector2 = entity.get("sim_pos")
	if _visible(point):
		_latest[priority] = {"point": point, "time": Time.get_ticks_msec()}

func _on_manual_navigation() -> void:
	if not is_processing(): return
	_stop_pan()
	_manual_until = Time.get_ticks_msec() + MANUAL_MS

func _stop_pan() -> void:
	if _pan != null:
		_pan.kill()
		_pan = null

func _process(_delta: float) -> void:
	_choose_shot(Time.get_ticks_msec())

func _choose_shot(now: int) -> void:
	if now < _manual_until or _latest.is_empty(): return
	for priority in [Interest.BATTLE, Interest.CONSTRUCTION, Interest.PRODUCTION, Interest.BASE]:
		if not _latest.has(priority): continue
		var event: Dictionary = _latest[priority]
		if now - int(event.time) > RECENT_MS or not _visible(event.point):
			_latest.erase(priority)
			continue
		if now < _hold_until and priority <= _shot_priority: return
		_latest.erase(priority)
		# An opening shot of the base is obsolete once real action has begun.
		_latest.erase(Interest.BASE)
		_shot_priority = priority
		_hold_until = now + SHOT_MS
		_frame(event.point)
		return

func _frame(point: Vector2) -> void:
	var target := _camera.clamped_position(IsoMath.world_to_screen(point))
	var offset := (target - _camera.position) * _camera.zoom
	var view := _camera.get_viewport_rect().size
	_stop_pan()
	if absf(offset.x) < view.x * 0.18 and absf(offset.y) < view.y * 0.18: return
	if absf(offset.x) > view.x or absf(offset.y) > view.y:
		_camera.position = target
		return
	_pan = create_tween().set_ignore_time_scale(true)
	_pan.tween_property(_camera, "position", target, 0.65).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
