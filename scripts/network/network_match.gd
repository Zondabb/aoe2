extends Node

## Trusted-host MVP: team 0 simulates; team 1 renders snapshots and submits orders.
## net_id is independent of process-local EntityRegistry IDs.
signal status_changed(message: String)

const Catalog := preload("res://scripts/data/game_catalog.gd")
const Registry := preload("res://scripts/ai_gateway/entity_registry.gd")
const Protocol := preload("res://scripts/ai_gateway/ai_protocol.gd")
const Executor := preload("res://scripts/ai_gateway/command_executor.gd")
const Context := preload("res://scripts/ai_gateway/command_execution_context.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const PROJECTILE_VIEW := preload("res://scenes/entities/projectile_view.tscn")
const ResourceScript := preload("res://scripts/entities/resource_node.gd")
const TerrainScript := preload("res://scripts/entities/path_blocker.gd")
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
	if op == "set_ai_control":
		# The relay owns sender_team; a peer cannot select another player's team.
		if command.size() != 2 or command.get("enabled") is not bool:
			return false
		var controller := _ai_controller()
		if controller == null or not controller.has_method("set_team_enabled"):
			return false
		var accepted := bool(controller.call("set_team_enabled", sender_team, command.enabled))
		_snapshot_elapsed = SNAPSHOT_INTERVAL
		return accepted
	var required: Dictionary = {
		"move": ["unit_id"], "stop": ["unit_id"], "gather": ["unit_id", "target_id"],
		"build": ["unit_id", "building_id"], "attack": ["unit_id", "target_id"],
		"train": ["building_id"], "cancel_train": ["building_id"], "place_building": ["builder_id"],
		"research_age": ["building_id"], "cancel_research_age": ["building_id"],
		"research_technology": ["building_id"], "cancel_technology": ["building_id"],
		"place_wall": ["builder_id", "building_def_id", "start", "end"], "set_gate_state": ["building_id", "gate_state"],
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
		if key in ["unit_id", "builder_id"] and op in ["gather", "build", "place_building", "place_wall"]:
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
	if command.has("formation_speed"):
		if op != "move" or not (command.formation_speed is int or command.formation_speed is float):
			return false
		var speed := float(command.formation_speed)
		var mover := _resolve(int(command.unit_id))
		var definition := mover.get("def") as UnitDef
		if definition == null or not is_finite(speed) or speed <= 0.0 or speed > definition.move_speed:
			return false
	if op == "place_building":
		if not _valid_enum(command.get("orientation", 0), 0, 3): return false
		translated["orientation"] = int(command.get("orientation", 0))
		if command.get("building_def_id") is not String:
			return false
		var definition := Protocol.building_def_for_id(command.building_def_id)
		if definition == null:
			return false
		var civilization := _civs.get(sender_team) as CivDef
		if civilization == null or not Catalog.building_reason(match_state, sender_team, civilization, definition, entities).is_empty():
			return false
		var pos := _vec(command.pos)
		var footprint := preload("res://scripts/systems/wall_system.gd").footprint_for(definition, translated.orientation)
		if not map_bounds.encloses(Rect2(pos - footprint * 0.5, footprint)):
			return false
		translated["building_def_id"] = command.building_def_id
	if op == "place_wall":
		if command.building_def_id is not String or not _valid_position(command.start) or not _valid_position(command.end): return false
		if command.get("include_gate", false) is not bool or command.get("append_queue", false) is not bool: return false
		for key in ["building_def_id", "start", "end"]: translated[key] = command[key]
		translated["include_gate"] = command.get("include_gate", false)
		translated["append_queue"] = command.get("append_queue", false)
	if op == "set_gate_state":
		if command.gate_state not in ["auto", "open", "locked"]: return false
		translated["gate_state"] = command.gate_state
	if op == "train":
		if command.get("unit_def_id") is not String:
			return false
		translated["unit_def_id"] = command.unit_def_id
	if op == "cancel_train":
		if not _valid_id(command.get("queue_id")):
			return false
		var building := _resolve(int(command.building_id)) as BuildingAgent
		var cancelled := building != null and int(building.team) == sender_team and building.cancel_train(int(command.queue_id))
		if cancelled:
			translated["queue_id"] = int(command.queue_id)
			Registry.report_manual_command(translated, sender_team)
		return cancelled
	if op == "research_technology":
		if command.get("technology_id") is not String or String(command.technology_id).length() > 128:
			return false
		translated["technology_id"] = command.technology_id
	var context := Context.new()
	context.match_state = match_state
	context.entities = entities
	context.team = sender_team as Enums.Team
	context.civ = _civs.get(sender_team) as CivDef
	var result := Executor.execute(translated, context)
	if bool(result.get("ok", false)):
		if op == "move" and command.has("formation_speed"):
			var mover := _resolve(int(command.unit_id))
			if mover.has_method("set_formation_move_speed"):
				mover.call("set_formation_move_speed", float(command.formation_speed))
		Registry.report_manual_command(translated, sender_team, result)
	return bool(result.get("ok", false))


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
			if entity.block_size_override != Vector2.ZERO:
				record["block_size"] = [entity.block_size_override.x, entity.block_size_override.y]
		elif kind == "terrain":
			record.merge({"terrain_id": String(entity.kind), "block_size": [entity.block_size.x, entity.block_size.y]})
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
					record.merge({"wall_orientation": entity.wall_orientation, "gate_state": entity.gate_state, "gate_open": entity.gate_open})
					var queue: Array = []
					for definition in entity.get("train_queue"):
						queue.append(String(definition.id))
					record.merge({"complete": entity.get("is_complete"), "build_progress": entity.get("build_progress"), "train_progress": entity.get("train_progress"), "train_queue": queue, "train_queue_ids": entity.get("train_queue_ids").duplicate(), "accepts_all": entity.get("accepts_all_resources"), "farm_food": entity.get("amount")})
					if record.def == "farm":
						record["farm_has_crops"] = entity.get("farm_has_crops")
		records.append(record)
	var economies: Array = []
	for side in [0, 1]:
		var stock: Dictionary = match_state.resources[side]
		economies.append({"food": stock[0], "wood": stock[1], "gold": stock[2], "stone": stock.get(3, 0), "population": match_state.population[side], "cap": match_state.population_cap[side], "reserved": match_state.population_reserved[side]})
	var research: Array = []
	var technologies: Array = []
	for side in [0, 1]:
		research.append(match_state.age_progression.progress_for(side) if match_state.age_progression != null else {})
		technologies.append(match_state.researched_technologies.get(side, {}).duplicate())
	var technology_research: Array = []
	if match_state.technology_progression != null:
		for entity in entities.get_children():
			if entity is BuildingAgent:
				var progress: Dictionary = match_state.technology_progression.progress_for(entity)
				if not progress.is_empty():
					progress = progress.duplicate(true)
					progress["building_id"] = entity_id(entity)
					progress["team"] = int(entity.get("team"))
					technology_research.append(progress)
	var snapshot := {"entities": records, "economies": economies, "winner": match_state.winner,
		"progression": {"enabled": match_state.progression_enabled, "ages": [match_state.age_of(0), match_state.age_of(1)],
		"research": research, "technologies": technologies, "technology_research": technology_research}}
	var controller := _ai_controller()
	if controller != null and controller.has_method("capture_states"):
		snapshot["ai_control"] = controller.call("capture_states")
	return snapshot



func apply_snapshot(snapshot: Dictionary, sequence: int) -> bool:
	if is_host or _terminal or sequence <= _last_snapshot_sequence or entities == null or match_state == null:
		return false
	if snapshot.get("entities") is not Array or snapshot.entities.size() > MAX_ENTITIES:
		return false
	if snapshot.get("economies") is not Array or snapshot.economies.size() != 2:
		return false
	if not _valid_enum(snapshot.get("winner", -1), -1, 1):
		return false
	if snapshot.has("progression") and not _valid_progression(snapshot.progression):
		return false
	if snapshot.has("ai_control") and not _valid_ai_control(snapshot.ai_control):
		return false
	var seen: Dictionary = {}
	for record in snapshot.entities:
		if record is not Dictionary or not _valid_record(record) or seen.has(int(record.id)):
			return false
		var existing := _resolve(int(record.id))
		if existing != null:
			if _entity_kind(existing) != record.kind:
				return false
			if record.kind in ["unit", "building"] and (not Catalog.is_upgrade(String(existing.get("def").id), record.def) or int(existing.get("team")) != int(record.team)):
				return false
		seen[int(record.id)] = true
	for economy in snapshot.economies:
		if economy is not Dictionary:
			return false
		if economy.has("stone") and (not _finite_number(economy.stone) or float(economy.stone) < 0):
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
		match_state.resources[side] = {0: int(economy.food), 1: int(economy.wood), 2: int(economy.gold), 3: int(economy.get("stone", 0))}
		match_state.population[side] = int(economy.population)
		match_state.population_cap[side] = int(economy.cap)
		match_state.population_reserved[side] = int(economy.reserved)
	if snapshot.has("progression"):
		var progression: Dictionary = snapshot.progression
		match_state.progression_enabled = bool(progression.enabled)
		for side in [0, 1]:
			match_state.set_age(side, int(progression.ages[side]))
			var changed: bool = match_state.researched_technologies[side] != progression.technologies[side]
			match_state.researched_technologies[side] = progression.technologies[side].duplicate()
			if changed: match_state.technology_changed.emit(side, &"")
		if match_state.age_progression != null:
			match_state.age_progression.apply_network_state(progression.research)
		if match_state.technology_progression != null:
			match_state.technology_progression.apply_network_state(progression.technology_research)
	if snapshot.has("ai_control"):
		var controller := _ai_controller()
		if controller != null and controller.has_method("apply_remote_states"):
			controller.call("apply_remote_states", snapshot.ai_control)
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
			if record.def == "farm": entity.set_script(load("res://scripts/entities/farm_agent.gd"))
			entity.set("def", Protocol.building_def_for_id(String(record.def)))
			entity.set("wall_orientation", int(record.get("wall_orientation", 0)))
			entity.set("gate_state", String(record.get("gate_state", "auto")))
			entity.set("gate_open", bool(record.get("gate_open", false)))
			if record.def == "farm": entity.set("farm_has_crops", _farm_crops_from_record(record))
			entity.set("accepts_all_resources", bool(record.get("accepts_all", false)))
			entity.set("is_complete", bool(record.complete))
			entity.set("build_progress", float(record.build_progress))
			entity.set("hp", float(record.hp))
		"resource":
			entity = ResourceScript.new()
			entity.set("resource_type", int(record.resource_type))
			if record.has("block_size"): entity.set("block_size_override", _vec(record.block_size))
		"terrain":
			entity = TerrainScript.new()
			entity.set("kind", StringName(record.terrain_id))
			entity.set("auto_block_size", false)
			entity.set("block_size", _vec(record.block_size))
		"projectile":
			entity = PROJECTILE_VIEW.instantiate()
		_:
			return null
	entity.set_meta("net_id", int(record.id))
	entity.set_meta("network_replica", true)
	entity.set("sim_pos", _vec(record.pos))
	if record.kind not in ["resource", "terrain"]:
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
	var position_changed: bool = entity.get("sim_pos") != _vec(record.pos)
	if entity is UnitAgent and String(entity.def.id) != record.def:
		entity.apply_definition_upgrade(Catalog.get_unit(record.def))
	elif entity is BuildingAgent and String(entity.def.id) != record.def:
		entity.apply_definition_upgrade(Catalog.get_building(record.def))
	entity.set("sim_pos", _vec(record.pos))
	if record.kind == "resource":
		entity.set("amount", float(record.amount))
		entity.set("gather_rate", float(record.gather_rate))
		entity.set("block_size_override", _vec(record.block_size) if record.has("block_size") else Vector2.ZERO)
		entity.block_half = entity.pathfinding_size() * 0.5
		entity.visible = float(record.amount) > 0.0
	elif record.kind == "terrain":
		var new_size := _vec(record.block_size)
		var new_kind := StringName(record.terrain_id)
		if position_changed or entity.block_size != new_size or entity.kind != new_kind:
			entity.block_size = new_size
			entity.block_half = new_size * 0.5
			entity.kind = new_kind
			entity.call("_setup_visual")
			for holder in get_tree().get_nodes_in_group("nav_service"):
				if holder.get_parent().is_ancestor_of(entity):
					holder.invalidate_static_geometry()
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
			if record.def == "farm": entity.set("farm_has_crops", _farm_crops_from_record(record))
			entity.set("wall_orientation", int(record.get("wall_orientation", 0)))
			entity.set("gate_state", String(record.get("gate_state", "auto")))
			entity.set("gate_open", bool(record.get("gate_open", false)))
			entity.set("is_complete", bool(record.complete))
			entity.set("build_progress", float(record.build_progress))
			entity.set("train_progress", float(record.train_progress))
			entity.set("amount", float(record.get("farm_food",175.0)))
			var queue: Array[UnitDef] = []
			for id in record.train_queue:
				var definition := Protocol.unit_def_for_id(String(id))
				if definition != null:
					queue.append(definition)
			entity.set("train_queue", queue)
			var queue_ids: Array[int] = []
			for id in record.get("train_queue_ids", []):
				queue_ids.append(int(id))
			entity.set("train_queue_ids", queue_ids)
			entity.call("_sync_block_half")
			if preload("res://scripts/systems/wall_system.gd").is_fortification(entity.def.id): entity.call("_configure_visuals")
	Iso.sync_node(entity, _vec(record.pos))


func _valid_record(record: Dictionary) -> bool:
	if not _valid_id(record.get("id")) or not _valid_position(record.get("pos")):
		return false
	var kind: Variant = record.get("kind")
	if kind not in ["unit", "building", "resource", "projectile", "terrain"]:
		return false
	if kind == "terrain":
		var size: Variant = record.get("block_size")
		return record.get("terrain_id") in ["water", "cliff"] and _valid_position(size) and float(size[0]) > 0 and float(size[1]) > 0 and float(size[0]) <= 128 and float(size[1]) <= 128 and map_bounds.encloses(Rect2(_vec(record.pos) - _vec(size) * 0.5, _vec(size)))
	if kind == "resource":
		if record.has("block_size"):
			var size: Variant = record.block_size
			if size is not Array or size.size() != 2 or not _finite_number(size[0]) or not _finite_number(size[1]) or float(size[0]) <= 0 or float(size[1]) <= 0 or float(size[0]) > 64 or float(size[1]) > 64:
				return false
		return _valid_enum(record.get("resource_type"), 0, 3) and _finite_number(record.get("amount")) and _finite_number(record.get("gather_rate"))
	if not _valid_enum(record.get("team"), 0, 1):
		return false
	if kind == "projectile":
		var visual: Variant = record.get("presentation")
		if visual is not Dictionary or not _valid_position(visual.get("origin")) or not _valid_position(visual.get("aim")) or not _finite_number(visual.get("traveled")):
			return false
		if visual.get("projectile_kind", "arrow") not in ["arrow", "stone"]:
			return false
		if visual.get("source_def", "") is not String:
			return false
		if visual.get("projectile_kind", "arrow") == "stone":
			var definition := Catalog.get_unit(StringName(visual.get("source_def", "")))
			if definition == null or definition.projectile_kind != &"stone":
				return false
		return _finite_number(visual.get("launch_height", 0.0)) and float(visual.get("launch_height", 0.0)) >= 0.0 and visual.get("impact", false) is bool and _finite_number(visual.get("impact_elapsed", 0.0)) and float(visual.get("impact_elapsed", 0.0)) >= 0.0 and float(visual.traveled) >= 0.0
	if record.get("def") is not String or not _finite_number(record.get("hp")):
		return false
	if kind == "unit":
		if Protocol.unit_def_for_id(record.def) == null or not _valid_enum(record.get("order"), 0, 4) or not _valid_enum(record.get("carry_type"), -1, 3) or not _finite_number(record.get("carry_amount")):
			return false
		var visual: Variant = record.get("presentation")
		if visual is not Dictionary or not _valid_enum(visual.get("facing"), 0, 31) or not _valid_enum(visual.get("frame"), 0, 10000) or visual.get("flip") is not bool:
			return false
		for key in ["animation", "combat_action", "gather_state"]:
			if visual.get(key) is not String or String(visual[key]).length() > 128:
				return false
		return true
	if not _valid_enum(record.get("wall_orientation", 0), 0, 3) or record.get("gate_state", "auto") not in ["auto", "open", "locked"] or record.get("gate_open", false) is not bool: return false
	if Protocol.building_def_for_id(record.def) == null or record.get("complete") is not bool or not _finite_number(record.get("build_progress")) or not _finite_number(record.get("train_progress")) or record.get("train_queue") is not Array:
		return false
	if record.train_queue.size() > BuildingAgent.MAX_TRAIN_QUEUE:
		return false
	var queue_ids: Variant = record.get("train_queue_ids", [])
	if queue_ids is not Array or queue_ids.size() != record.train_queue.size():
		return false
	var seen_ids := {}
	for id in queue_ids:
		if not _valid_id(id) or seen_ids.has(int(id)):
			return false
		seen_ids[int(id)] = true
	if record.has("farm_food") and (not _finite_number(record.farm_food) or float(record.farm_food) < 0.0):
		return false
	if record.has("farm_has_crops") and record.farm_has_crops is not bool:
		return false
	for id in record.train_queue:
		if id is not String or Protocol.unit_def_for_id(id) == null:
			return false
	return true


func _farm_crops_from_record(record: Dictionary) -> bool:
	# Older hosts did not transmit the visual lifecycle. Depletion is the only
	# evidence that gathering began; a fresh or unfinished farm stays bare.
	return bool(record.get("farm_has_crops", bool(record.complete) and float(record.get("farm_food", 175.0)) < 175.0))


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
	if entity is TerrainScript and entity.kind in [&"water", &"cliff"]:
		return "terrain"
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
	_stop_ai_control()
	if is_host and not _terminal and session != null:
		session.call("send_snapshot", capture_snapshot())
		session.call("finish_match", winner)


func _on_ended(info: Dictionary) -> void:
	_terminal = true
	_playing = false
	_stop_ai_control()
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
	_stop_ai_control()
	if session != null and is_instance_valid(session):
		session.call("leave")


func _ai_controller() -> Node:
	return get_parent().get_node_or_null("PlayerAiControl") if get_parent() != null else null


func _stop_ai_control() -> void:
	var controller := _ai_controller()
	if controller != null and controller.has_method("stop_all"):
		controller.call("stop_all")


func _valid_ai_control(value: Variant) -> bool:
	if value is not Dictionary or value.size() != 2 or not value.has("0") or not value.has("1"):
		return false
	# Load at validation time to avoid an autoload initialization cycle through
	# GameSettings -> GameSession when this network script is preloaded.
	var settings: Script = load("res://scripts/core/game_settings.gd")
	for team_key in ["0", "1"]:
		var state: Variant = value[team_key]
		if state is not Dictionary or state.size() not in [3, 4] or state.get("enabled") is not bool:
			return false
		# New hosts advertise only a public service URL, never credentials. Keep
		# older three-field ownership snapshots compatible.
		if state.size() == 4 and not state.has("service_url"):
			return false
		if state.has("service_url"):
			if state.service_url is not String or String(state.service_url).length() > 2048:
				return false
			if not String(state.service_url).is_empty() and str(settings.normalize_ai_service_url(state.service_url)).is_empty():
				return false
		if state.get("status") is not String or String(state.status).length() > 64:
			return false
		if state.get("message") is not String or String(state.message).length() > 256:
			return false
	return true


func _valid_progression(value: Variant) -> bool:
	if value is not Dictionary or value.get("enabled") is not bool:
		return false
	for field in ["ages", "research", "technologies"]:
		if value.get(field) is not Array or value[field].size() != 2:
			return false
	for age in value.ages:
		if not _valid_enum(age, 0, 3):
			return false
	for research in value.research:
		if research is not Dictionary:
			return false
		if research.is_empty():
			continue
		if not _valid_id(research.get("building_id")) or not _valid_enum(research.get("target_age"), 1, 3) or not _valid_enum(research.get("from_age"), 0, 2):
			return false
		if not _valid_research_progress(research):
			return false
	for technologies in value.technologies:
		if technologies is not Dictionary or technologies.size() > 256:
			return false
		for technology_id in technologies:
			if technology_id is not String or not Catalog.techs().has(technology_id) or technologies[technology_id] != true:
				return false
	if value.get("technology_research") is not Array or value.technology_research.size() > MAX_ENTITIES:
		return false
	for research in value.technology_research:
		if research is not Dictionary or not _valid_id(research.get("building_id")) or not _valid_enum(research.get("team"), 0, 1):
			return false
		if research.get("technology_id") is not String or not Catalog.techs().has(research.technology_id) or not _valid_research_progress(research):
			return false
	return true


func _valid_research_progress(research: Dictionary) -> bool:
	for field in ["elapsed", "duration", "progress"]:
		if not _finite_number(research.get(field)) or float(research[field]) < 0:
			return false
	return float(research.duration) > 0 and float(research.elapsed) <= float(research.duration) and float(research.progress) <= 1.0
