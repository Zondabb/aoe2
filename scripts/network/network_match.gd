extends Node

## Trusted-host MVP: team 0 simulates; team 1 renders snapshots and submits orders.
## net_id is independent of process-local EntityRegistry IDs.
signal status_changed(message: String)

const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Protocol := preload("res://scripts/ai_gateway/ai_protocol.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const PROJECTILE_VIEW := preload("res://scenes/entities/projectile_view.tscn")
const ResourceScript := preload("res://scripts/entities/resource_node.gd")
const SNAPSHOT_INTERVAL := 0.1
const SNAPSHOT_TIMEOUT := 10.0
const MAX_ENTITIES := 2000

var match_state: MatchState
var entities: Node2D
var session: Node
var map_bounds := Rect2(-60, -60, 120, 120)
var local_team := 0
var is_host := false
var _civs: Dictionary = {}
var _net_entities: Dictionary = {}
var _next_id := 1
var _playing := false
var _terminal := false
var _snapshot_elapsed := 0.0
var _snapshot_wait := 0.0
var _last_snapshot_sequence := -1
var _last_command_sequence := -1
var _command_window := 0.0
var _command_count := 0
var _status_label: Label


func setup(bootstrap: Node) -> void:
	match_state = bootstrap.get("match_state") as MatchState
	entities = bootstrap.get_node_or_null("../Entities") as Node2D
	map_bounds = bootstrap.get("map_bounds")
	_civs = {0: bootstrap.get("player_civ"), 1: bootstrap.get("ai_civ")}
	session = get_node_or_null("/root/NetworkSession")
	if session == null or match_state == null or entities == null:
		return
	local_team = int(session.get("team"))
	is_host = local_team == 0
	add_to_group("network_match")
	match_state.frozen = true
	_create_status_label()
	session.connect("started", _on_started)
	session.connect("message_received", _on_message)
	session.connect("ended", _on_ended)
	session.connect("status_changed", _set_status)
	match_state.winner_decided.connect(_on_winner)
	if is_host:
		_index_host_entities()
	else:
		for entity in entities.get_children():
			if _entity_kind(entity) != "":
				entity.set_meta("network_replica", true)
				entity.set_physics_process(false)
	_set_status("等待双方载入地图…")
	if session.get("state") == "playing":
		_on_started()
	elif session.get("state") == "matched":
		session.call("send_ready")
	else:
		var result: Dictionary = session.get("last_result")
		_on_ended(result if not result.is_empty() else {"winner": -1, "message": "连接已结束，请返回大厅重新匹配"})


func entity_id(entity: Node) -> int:
	if entity == null or not is_instance_valid(entity) or entity.is_queued_for_deletion():
		return -1
	if is_host and not entity.has_meta("net_id") and _entity_kind(entity) != "":
		entity.set_meta("net_id", _next_id)
		_net_entities[_next_id] = entity
		_next_id += 1
	return int(entity.get_meta("net_id", -1))


func submit_command(command: Dictionary) -> bool:
	if not _playing or _terminal or match_state == null or match_state.frozen:
		return false
	if is_host:
		return execute_team_command(command, local_team)
	if session == null:
		return false
	return bool(session.call("send_command", command))


## Validate wire types before calling the shared gameplay validator/executor.
func execute_team_command(command: Dictionary, sender_team: int) -> bool:
	if not is_host or not _playing or _terminal or match_state == null or match_state.frozen:
		return false
	if sender_team not in [0, 1] or command.size() > 10:
		return false
	_command_count += 1
	if _command_count > 240:
		return false
	if command.get("op") is not String:
		return false
	var op := String(command.op)
	var required: Dictionary = {
		"move": ["unit_id"], "stop": ["unit_id"], "gather": ["unit_id", "target_id"],
		"build": ["unit_id", "building_id"], "attack": ["unit_id", "target_id"],
		"train": ["building_id"], "place_building": ["builder_id"],
	}
	if not required.has(op):
		return false
	var translated := {"op": op}
	for key in required[op]:
		if not command.has(key):
			return false
	for key in ["unit_id", "target_id", "building_id", "builder_id"]:
		if not command.has(key):
			continue
		if not _valid_id(command[key]):
			return false
		var node := _resolve(int(command[key]))
		if node == null:
			return false
		translated[key] = Registry.id_of(node)
		if int(translated[key]) < 0:
			return false
		if key in ["unit_id", "builder_id"] and op in ["gather", "build", "place_building"]:
			var unit_def := node.get("def") as UnitDef
			if unit_def == null or unit_def.id != &"villager":
				return false
	if op in ["move", "place_building"]:
		if not _valid_position(command.get("pos")):
			return false
		var pos := _vec(command.pos)
		if not map_bounds.has_point(pos):
			return false
		translated["pos"] = [pos.x, pos.y]
	if op == "place_building":
		if command.get("building_def_id") is not String:
			return false
		var definition := Protocol.building_def_for_id(command.building_def_id)
		if definition == null:
			return false
		# Match the human command panel: town centers cannot be placed for free.
		var build_types := {"house": Enums.BuildingType.HOUSE, "barracks": Enums.BuildingType.BARRACKS,
			"archery_range": Enums.BuildingType.ARCHERY_RANGE, "stable": Enums.BuildingType.STABLE,
			"mill": Enums.BuildingType.MILL, "lumber_camp": Enums.BuildingType.LUMBER_CAMP,
			"mining_camp": Enums.BuildingType.MINING_CAMP}
		var civilization := _civs.get(sender_team) as CivDef
		if not build_types.has(command.building_def_id) or civilization == null or build_types[command.building_def_id] not in civilization.allowed_buildings:
			return false
		var pos := _vec(command.pos)
		if not map_bounds.encloses(Rect2(pos - definition.footprint * 0.5, definition.footprint)):
			return false
		translated["building_def_id"] = command.building_def_id
	if op == "train":
		if command.get("unit_def_id") is not String:
			return false
		translated["unit_def_id"] = command.unit_def_id
	var context := Context.new()
	context.match_state = match_state
	context.entities = entities
	context.team = sender_team as Enums.Team
	context.civ = _civs.get(sender_team) as CivDef
	return bool(Executor.execute(translated, context).get("ok", false))


func _process(delta: float) -> void:
	_command_window += delta
	if _command_window >= 1.0:
		_command_window = 0.0
		_command_count = 0
	if not _playing or _terminal or session == null:
		return
	if is_host:
		_snapshot_elapsed += delta
		if _snapshot_elapsed >= SNAPSHOT_INTERVAL:
			_snapshot_elapsed = 0.0
			session.call("send_snapshot", capture_snapshot())
	else:
		_snapshot_wait += delta
		if _snapshot_wait > SNAPSHOT_TIMEOUT:
			_on_ended({"winner": -1, "message": "主机状态同步超时，对局结束"})
			session.call("leave")


func _on_started() -> void:
	if _terminal:
		return
	_playing = true
	match_state.frozen = false
	_snapshot_wait = 0.0
	_set_status("联机对战 · %s" % ("主机" if is_host else "玩家"))
	if is_host:
		session.call("send_snapshot", capture_snapshot())


func _on_message(message: Dictionary) -> void:
	if _terminal:
		return
	if message.get("type") == "command" and is_host:
		var seq := int(message.get("seq", -1))
		if seq <= _last_command_sequence or int(message.get("team", -1)) != 1:
			return
		_last_command_sequence = seq
		if message.get("command") is Dictionary:
			execute_team_command(message.command, 1)
	elif message.get("type") == "snapshot" and not is_host:
		if message.get("state") is Dictionary:
			apply_snapshot(message.state, int(message.get("seq", -1)))


func capture_snapshot() -> Dictionary:
	_index_host_entities()
	var records: Array = []
	for entity in entities.get_children():
		var kind := _entity_kind(entity)
		if kind.is_empty() or entity.is_queued_for_deletion():
			continue
		var pos: Vector2 = entity.get("sim_pos")
		var record := {"id": entity_id(entity), "kind": kind, "pos": [pos.x, pos.y]}
		if kind == "resource":
			record.merge({"resource_type": entity.get("resource_type"), "amount": entity.get("amount"), "gather_rate": entity.get("gather_rate")})
		else:
			record["team"] = entity.get("team")
			if kind == "projectile":
				record["presentation"] = entity.call("network_presentation")
			else:
				record["def"] = String(entity.get("def").id)
				record["hp"] = entity.get("hp")
				if kind == "unit":
					record.merge({"order": entity.get("order"), "carry_type": entity.get("carry_type"), "carry_amount": entity.get("carry_amount"), "presentation": entity.call("network_presentation")})
				else:
					var queue: Array = []
					for definition in entity.get("train_queue"):
						queue.append(String(definition.id))
					record.merge({"complete": entity.get("is_complete"), "build_progress": entity.get("build_progress"), "train_progress": entity.get("train_progress"), "train_queue": queue, "accepts_all": entity.get("accepts_all_resources")})
		records.append(record)
	var economies: Array = []
	for side in [0, 1]:
		var stock: Dictionary = match_state.resources[side]
		economies.append({"food": stock[0], "wood": stock[1], "gold": stock[2], "population": match_state.population[side], "cap": match_state.population_cap[side], "reserved": match_state.population_reserved[side]})
	return {"entities": records, "economies": economies, "winner": match_state.winner}


func apply_snapshot(snapshot: Dictionary, sequence: int) -> bool:
	if is_host or _terminal or sequence <= _last_snapshot_sequence or entities == null or match_state == null:
		return false
	if snapshot.get("entities") is not Array or snapshot.entities.size() > MAX_ENTITIES:
		return false
	if snapshot.get("economies") is not Array or snapshot.economies.size() != 2:
		return false
	if not _valid_enum(snapshot.get("winner", -1), -1, 1):
		return false
	var seen: Dictionary = {}
	for record in snapshot.entities:
		if record is not Dictionary or not _valid_record(record) or seen.has(int(record.id)):
			return false
		var existing := _resolve(int(record.id))
		if existing != null:
			if _entity_kind(existing) != record.kind:
				return false
			if record.kind in ["unit", "building"] and (String(existing.get("def").id) != record.def or int(existing.get("team")) != int(record.team)):
				return false
		seen[int(record.id)] = true
	for economy in snapshot.economies:
		if economy is not Dictionary:
			return false
		for key in ["food", "wood", "gold", "population", "cap", "reserved"]:
			if not _finite_number(economy.get(key)) or float(economy[key]) < 0:
				return false
	for record in snapshot.entities:
		var id := int(record.id)
		var entity := _resolve(id)
		if entity == null:
			entity = _spawn_replica(record)
			if entity == null:
				return false
			_net_entities[id] = entity
		_apply_record(entity, record)
	for id in _net_entities.keys():
		if not seen.has(id):
			var stale := _resolve(int(id))
			_net_entities.erase(id)
			if stale != null:
				stale.free()
	for side in [0, 1]:
		var economy: Dictionary = snapshot.economies[side]
		match_state.resources[side] = {0: int(economy.food), 1: int(economy.wood), 2: int(economy.gold)}
		match_state.population[side] = int(economy.population)
		match_state.population_cap[side] = int(economy.cap)
		match_state.population_reserved[side] = int(economy.reserved)
	_last_snapshot_sequence = sequence
	_snapshot_wait = 0.0
	if match_state.fog != null:
		match_state.fog.dirty = true
	var winner := int(snapshot.get("winner", -1))
	if winner in [0, 1]:
		match_state.set_winner(winner as Enums.Team)
	return true


func _spawn_replica(record: Dictionary) -> Node2D:
	var entity: Node2D
	match String(record.kind):
		"unit":
			entity = UNIT_VIEW.instantiate()
			entity.set("def", Protocol.unit_def_for_id(String(record.def)))
		"building":
			entity = BUILDING_VIEW.instantiate()
			entity.set("def", Protocol.building_def_for_id(String(record.def)))
			entity.set("accepts_all_resources", bool(record.get("accepts_all", false)))
		"resource":
			entity = ResourceScript.new()
			entity.set("resource_type", int(record.resource_type))
		"projectile":
			entity = PROJECTILE_VIEW.instantiate()
		_:
			return null
	entity.set_meta("net_id", int(record.id))
	entity.set_meta("network_replica", true)
	entity.set("sim_pos", _vec(record.pos))
	if record.kind != "resource":
		entity.set("team", int(record.team))
		entity.set("match_state", match_state)
		if record.kind != "projectile":
			entity.set("civ", _civs.get(int(record.team)))
	entities.add_child(entity)
	entity.set_physics_process(false)
	if record.kind == "projectile":
		entity.call("_configure_visual")
	return entity


func _apply_record(entity: Node2D, record: Dictionary) -> void:
	entity.set("sim_pos", _vec(record.pos))
	if record.kind == "resource":
		entity.set("amount", float(record.amount))
		entity.set("gather_rate", float(record.gather_rate))
		entity.visible = float(record.amount) > 0.0
	elif record.kind == "projectile":
		entity.call("apply_network_presentation", record.presentation)
		return
	else:
		entity.set("hp", float(record.hp))
		if record.kind == "unit":
			entity.set("order", int(record.get("order", 0)))
			entity.set("carry_type", int(record.get("carry_type", -1)))
			entity.set("carry_amount", float(record.get("carry_amount", 0.0)))
			entity.call("apply_network_presentation", record.get("presentation", {}))
		else:
			entity.set("is_complete", bool(record.complete))
			entity.set("build_progress", float(record.build_progress))
			entity.set("train_progress", float(record.train_progress))
			var queue: Array[UnitDef] = []
			for id in record.train_queue:
				var definition := Protocol.unit_def_for_id(String(id))
				if definition != null:
					queue.append(definition)
			entity.set("train_queue", queue)
	Iso.sync_node(entity, _vec(record.pos))


func _valid_record(record: Dictionary) -> bool:
	if not _valid_id(record.get("id")) or not _valid_position(record.get("pos")):
		return false
	var kind: Variant = record.get("kind")
	if kind not in ["unit", "building", "resource", "projectile"]:
		return false
	if kind == "resource":
		return _valid_enum(record.get("resource_type"), 0, 2) and _finite_number(record.get("amount")) and _finite_number(record.get("gather_rate"))
	if not _valid_enum(record.get("team"), 0, 1):
		return false
	if kind == "projectile":
		var visual: Variant = record.get("presentation")
		return visual is Dictionary and _valid_position(visual.get("origin")) and _valid_position(visual.get("aim")) and _finite_number(visual.get("traveled"))
	if record.get("def") is not String or not _finite_number(record.get("hp")):
		return false
	if kind == "unit":
		if Protocol.unit_def_for_id(record.def) == null or not _valid_enum(record.get("order"), 0, 4) or not _valid_enum(record.get("carry_type"), -1, 2) or not _finite_number(record.get("carry_amount")):
			return false
		var visual: Variant = record.get("presentation")
		if visual is not Dictionary or not _valid_enum(visual.get("facing"), 0, 31) or not _valid_enum(visual.get("frame"), 0, 10000) or visual.get("flip") is not bool:
			return false
		for key in ["animation", "combat_action", "gather_state"]:
			if visual.get(key) is not String or String(visual[key]).length() > 128:
				return false
		return true
	if Protocol.building_def_for_id(record.def) == null or record.get("complete") is not bool or not _finite_number(record.get("build_progress")) or not _finite_number(record.get("train_progress")) or record.get("train_queue") is not Array:
		return false
	if record.train_queue.size() > 1:
		return false
	for id in record.train_queue:
		if id is not String or Protocol.unit_def_for_id(id) == null:
			return false
	return true


func _index_host_entities() -> void:
	if entities == null:
		return
	for entity in entities.get_children():
		if _entity_kind(entity) != "":
			entity_id(entity)
	for id in _net_entities.keys():
		if _resolve(int(id)) == null:
			_net_entities.erase(id)


func _entity_kind(entity: Node) -> String:
	if entity.get("is_placement_ghost") == true or entity.has_meta("fog_memory"):
		return ""
	if entity is UnitAgent:
		return "unit"
	if entity is BuildingAgent:
		return "building"
	if entity is ResourceNode:
		return "resource"
	if entity is ProjectileAgent:
		return "projectile"
	return ""


func _resolve(id: int) -> Node2D:
	var node: Variant = _net_entities.get(id)
	if not is_instance_valid(node) or node is not Node2D or node.is_queued_for_deletion():
		return null
	return node


static func _finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _valid_id(value: Variant) -> bool:
	return _finite_number(value) and float(value) >= 1 and float(value) <= 2147483647 and float(value) == floor(float(value))


static func _valid_enum(value: Variant, minimum: int, maximum: int) -> bool:
	return _finite_number(value) and float(value) == floor(float(value)) and int(value) >= minimum and int(value) <= maximum


static func _valid_position(value: Variant) -> bool:
	return value is Array and value.size() == 2 and _finite_number(value[0]) and _finite_number(value[1])


static func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


func _on_winner(winner: int) -> void:
	if is_host and not _terminal and session != null:
		session.call("send_snapshot", capture_snapshot())
		session.call("finish_match", winner)


func _on_ended(info: Dictionary) -> void:
	_terminal = true
	_playing = false
	if match_state != null:
		match_state.frozen = true
		var winner := int(info.get("winner", -1))
		if winner in [0, 1]:
			match_state.set_winner(winner as Enums.Team)
	_set_status(String(info.get("message", "对局已结束")))
	var hud := get_parent().get_node_or_null("UILayer/HUD")
	if hud != null and match_state.winner == -1:
		hud.show_network_result(String(info.get("message", "对局已结束")))


func _create_status_label() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 25
	add_child(layer)
	_status_label = Label.new()
	_status_label.position = Vector2(16, 76)
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_status_label.add_theme_constant_override("shadow_offset_x", 1)
	_status_label.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(_status_label)
	var leave_button := Button.new()
	leave_button.name = "LeaveMatch"
	leave_button.text = "离开对局"
	leave_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	leave_button.offset_left = -148
	leave_button.offset_right = -16
	leave_button.offset_top = 70
	leave_button.offset_bottom = 108
	leave_button.pressed.connect(_return_to_lobby)
	layer.add_child(leave_button)


func _return_to_lobby() -> void:
	var game := get_node("/root/GameSession")
	game.online_active = false
	game.online_return_to_lobby = true
	if session != null:
		session.leave()
	get_tree().change_scene_to_file("res://scenes/civ_select.tscn")


func _set_status(message: String) -> void:
	if _status_label != null:
		_status_label.text = message
	status_changed.emit(message)


func _exit_tree() -> void:
	if session != null and is_instance_valid(session):
		session.call("leave")
