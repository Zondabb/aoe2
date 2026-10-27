extends Node
## Presentation only: audio never changes simulation state or uses its RNG.

signal event_played(event: StringName, category: StringName)
signal settings_changed

const MANIFEST := "res://assets/audio/manifest.json"
const USER_SETTINGS := "user://audio_settings.cfg"
const FogAccess := preload("res://scripts/systems/fog_access.gd")
const LIMITS := {&"ui": 4, &"voice": 1, &"world": 12, &"alert": 2}
const BUS_NAMES := {&"ui": &"OriginalUI", &"voice": &"OriginalVoices", &"world": &"OriginalWorld", &"alert": &"OriginalAlerts"}

var master_volume := 0.8
var muted := false
var events: Dictionary = {}
var voice_profiles: Dictionary = {}
var _streams: Dictionary = {}
var _players: Dictionary = {}
var _last_played: Dictionary = {}
var _random := RandomNumberGenerator.new()
var _last_scene_id := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_random.randomize()
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if data is Dictionary:
		events = data.get("events", {})
		voice_profiles = data.get("voice_profiles", {})
	for category in LIMITS:
		var bus: StringName = BUS_NAMES[category]
		if AudioServer.get_bus_index(bus) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus)
		_players[category] = []
	for path in ["res://data/game_settings.cfg", "user://game_settings.cfg", USER_SETTINGS]:
		var config := ConfigFile.new()
		if config.load(path) == OK:
			var volume: Variant = config.get_value("audio", "volume", master_volume)
			if (volume is float or volume is int) and is_finite(float(volume)):
				master_volume = clampf(float(volume), 0.0, 1.0)
			var mute: Variant = config.get_value("audio", "muted", muted)
			if mute is bool:
				muted = mute
	_apply_volume()
	get_tree().node_added.connect(_node_added)
	_bind_existing(get_tree().root)


func _process(_delta: float) -> void:
	var scene := get_tree().current_scene
	var id := scene.get_instance_id() if is_instance_valid(scene) else 0
	if id != _last_scene_id:
		# A battle sound must not survive returning to the menu or loading a save.
		stop_all()
		_last_scene_id = id


func set_master_volume(value: float, persist := false) -> void:
	if not is_finite(value): return
	master_volume = clampf(value, 0.0, 1.0)
	_apply_volume()
	if persist: save_settings()
	settings_changed.emit()


func set_muted(value: bool, persist := false) -> void:
	muted = value
	if muted: stop_all()
	_apply_volume()
	if persist: save_settings()
	settings_changed.emit()


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("audio", "volume", master_volume)
	config.set_value("audio", "muted", muted)
	config.save(USER_SETTINGS)


func _apply_volume() -> void:
	for bus in BUS_NAMES.values():
		var index := AudioServer.get_bus_index(bus)
		if index >= 0:
			AudioServer.set_bus_volume_db(index, linear_to_db(maxf(master_volume, 0.0001)))
			AudioServer.set_bus_mute(index, muted or master_volume <= 0.0)


func stop_all() -> void:
	for pool in _players.values():
		for player in pool:
			if is_instance_valid(player): player.stop()
	_last_played.clear()


func source_audible(source: Node) -> bool:
	if not is_instance_valid(source) or not source.is_inside_tree(): return false
	if not source is Node2D: return false
	if not source.is_visible_in_tree() or not FogAccess.view_can_see(source): return false
	var point := (source as Node2D).get_global_transform_with_canvas().origin
	return source.get_viewport().get_visible_rect().grow(96.0).has_point(point)


func play_event(event: StringName, category: StringName = &"world", source: Node = null, cooldown_key := "") -> bool:
	if event in [&"building_select", &"construction_complete"] and is_instance_valid(source):
		var definition: Variant = source.get("def")
		if definition != null:
			var specific := "building_select_" + String(definition.id)
			if events.has(specific): event = StringName(specific)
	if muted or master_volume <= 0.0 or not events.has(String(event)): return false
	if source != null and category == &"world" and not source_audible(source): return false
	var spec: Dictionary = events[String(event)]
	if not LIMITS.has(category): category = &"world"
	var files: Array = spec.get("files", [])
	if files.is_empty(): return false
	var now := Time.get_ticks_msec() * 0.001
	var key := String(category) + ":" + (cooldown_key if not cooldown_key.is_empty() else String(event))
	var delay := float(spec.get("cooldown", 0.12))
	if now - float(_last_played.get(key, -100.0)) < delay: return false
	if category == &"voice" and now - float(_last_played.get("voice:any", -100.0)) < 0.18: return false
	var pool: Array = _players[category]
	if event in [&"victory", &"defeat"]:
		# The final outcome takes precedence over pending production/attack cues.
		for alert in pool: alert.stop()
	var player: AudioStreamPlayer
	for candidate in pool:
		if not candidate.playing:
			player = candidate
			break
	if player == null:
		if pool.size() >= int(LIMITS[category]):
			if category != &"voice": return false
			player = pool[0]
			player.stop()
		else:
			player = AudioStreamPlayer.new()
			player.bus = BUS_NAMES[category]
			player.max_polyphony = 1
			add_child(player)
			pool.append(player)
	var path: String = files[_random.randi_range(0, files.size() - 1)]
	if not _streams.has(path):
		_streams[path] = load(path) as AudioStream
	if _streams[path] == null: return false
	player.stream = _streams[path]
	player.volume_db = float(spec.get("volume_db", -3.0))
	# World samples retain their original pitch even with accelerated simulation.
	player.pitch_scale = 1.0
	if source is Node2D:
		var point := (source as Node2D).get_global_transform_with_canvas().origin
		var viewport_size := source.get_viewport().get_visible_rect().size
		var pan := clampf((point.x / maxf(viewport_size.x, 1.0) - 0.5) * 1.2, -0.6, 0.6)
		# AudioStreamPlayer mix_target has no panner; use mild distance attenuation.
		player.volume_db -= absf(pan) * 4.0
	_last_played[key] = now
	if _last_played.size() > 512:
		for old_key in _last_played.keys():
			if now - float(_last_played[old_key]) > 30.0: _last_played.erase(old_key)
	if category == &"voice": _last_played["voice:any"] = now
	player.play()
	event_played.emit(event, category)
	return true


func play_unit_voice(unit: Node, action: StringName) -> bool:
	if not is_instance_valid(unit) or not unit.is_inside_tree(): return false
	var definition: Variant = unit.get("def")
	if definition == null or unit.get("team") != GameSession.local_team(): return false
	var civ: Variant = unit.get("civ")
	var civilization := String(civ.id) if civ != null else ""
	if civilization.is_empty():
		var state: Variant = unit.get("match_state")
		if state != null: civilization = String(state.team_civilizations.get(int(unit.get("team")), ""))
	if civilization not in ["chinese", "teutons"]:
		civilization = String(GameSession.player_civ_id)
	var role := String(voice_profiles.get(String(definition.id), "villager" if definition.id == &"villager" else "military"))
	var key := "voice_%s_%s_%s" % [role, action, civilization]
	if not events.has(key):
		key = "voice_%s_%s_%s" % [role, "select" if action == &"select" else "move", civilization]
	return play_event(StringName(key), &"voice")


func _node_added(node: Node) -> void:
	if node is BaseButton: call_deferred("_bind_button", weakref(node))


func _bind_existing(node: Node) -> void:
	if node is BaseButton: _bind_button(weakref(node))
	for child in node.get_children(): _bind_existing(child)


func _bind_button(reference: WeakRef) -> void:
	var button := reference.get_ref() as BaseButton
	if not is_instance_valid(button): return
	var callback := _button_pressed.bind(button)
	if not button.pressed.is_connected(callback): button.pressed.connect(callback)


func _button_pressed(button: BaseButton) -> void:
	if not is_instance_valid(button) or button.disabled or not button.is_visible_in_tree(): return
	if button.get_meta("audio_skip_click", false): return
	play_event(&"click", &"ui")
