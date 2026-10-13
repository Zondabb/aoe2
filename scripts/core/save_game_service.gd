extends RefCounted
## Local JSON snapshots contain catalog IDs and simulation values, never scripts,
## credentials, or network replicas. All input is checked before changing a match.

const FORMAT := "aoe2-rts-save"
const VERSION := 1
const DEFAULT_SAVE_PATH := "user://saves/single_player.json"
const MAX_FILE_BYTES := 32 * 1024 * 1024
const MAX_ENTITIES := 12000
const Catalog := preload("res://scripts/data/game_catalog.gd")
const MapDataScript := preload("res://scripts/world/map_data.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const PROJECTILE_VIEW := preload("res://scenes/entities/projectile_view.tscn")
const PLAYER_COLOR_SHADER := preload("res://shaders/player_color.gdshader")
const TERRAIN_SCRIPT := preload("res://scripts/entities/path_blocker.gd")
const CLIFF_FOG_SHADER := preload("res://shaders/terrain_cliff_fog.gdshader")
const WATER_SHADER := preload("res://shaders/terrain_water.gdshader")
const WATER_COAST_LIMIT := 192
const WATER_TEXTURE_PATHS := {"sand_texture":"res://assets/terrain/beach.png", "shallow_texture":"res://assets/terrain/shallow.png", "grass_texture":"res://assets/terrain/grass.png"}
const POLYGON_VECTORS := ["polygon_offset", "texture_scale", "texture_offset"]
const PART_COLORS := ["modulate", "self_modulate", "polygon_color"]
const CHINESE := preload("res://data/civs/chinese.tres")
const TEUTONS := preload("res://data/civs/teutons.tres")
const SESSION_FIELDS := ["match_ai_mode", "ai_service_url", "ai_chat_url", "ai_service_timeout_sec", "ai_tick_interval_sec", "ai_use_local_embedded", "ai_protocol", "ai_protocol_version", "ai_backend", "ai_model", "ai_max_tokens", "ai_use_tick_batch", "ai_history_turns", "ai_log_observation", "ai_llm_base_url"]
const UNIT_NUMBERS := ["hp", "melee_armor", "pierce_armor", "carry_type", "carry_amount", "carry_capacity", "vision_radius_override", "_attack_cooldown_remaining", "_gather_resource_type", "_facing_dir", "_anim_frame", "_combat_anim_time", "_max_hp", "_path_index", "_path_retry_cooldown", "_stuck_repath_attempts", "_stuck_seconds", "_repath_cooldown", "_goal_refresh_remaining"]
const UNIT_BOOLS := ["_gather_source_depleted", "_automatic_gather_target", "_population_registered", "_facing_flip", "_attack_hit_applied", "_projectile_spawned", "_path_is_crowd_route", "_has_move_command"]
const UNIT_VECTORS := ["_move_target", "_last_seen_resource_pos", "_last_seen_attack_pos", "_automatic_gather_goal", "_automatic_gather_resource_pos", "_nav_goal", "_requested_move_target"]
const UNIT_REFS := ["_gather_target", "_last_resource", "_drop_off_target", "_build_target", "_attack_target"]
const BUILDING_NUMBERS := ["hp", "melee_armor", "pierce_armor", "build_progress", "amount", "resource_type", "gather_rate", "accepted_resource_type", "train_progress", "_next_train_id", "_reserved_population"]
const BUILDING_BOOLS := ["is_complete", "accepts_all_resources", "_construction_started", "_population_cap_registered"]


static func has_save(path := DEFAULT_SAVE_PATH) -> bool:
	return FileAccess.file_exists(path)


static func save(bootstrap: Node, path := DEFAULT_SAVE_PATH) -> String:
	if GameSession.online_active or (is_instance_valid(bootstrap) and bootstrap.get_parent().get_meta("online_match", false)):
		return "联机对局不支持本地存档。"
	if not is_instance_valid(bootstrap) or not bootstrap.get("setup_ready"):
		return "对局尚未准备完成，请稍后再存档。"
	var data := capture(bootstrap)
	var error := validate(data)
	if not error.is_empty(): return error
	var directory := path.get_base_dir()
	var result := DirAccess.make_dir_recursive_absolute(directory)
	if result != OK: return "无法创建存档目录：" + error_string(result)
	var temporary := path + ".tmp"
	var serialized := JSON.stringify(data, "", false, true)
	if serialized.to_utf8_buffer().size() > MAX_FILE_BYTES: return "存档超过 32 MiB，无法保存。"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return "无法写入存档：" + error_string(FileAccess.get_open_error())
	file.store_string(serialized)
	file.flush()
	result = file.get_error()
	file.close()
	if result == OK: result = DirAccess.rename_absolute(temporary, path)
	if result != OK:
		DirAccess.remove_absolute(temporary)
		return "保存失败，原存档保留：" + error_string(result)
	return ""


static func read(path := DEFAULT_SAVE_PATH) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {"data": {}, "error": "无法打开存档：" + error_string(FileAccess.get_open_error())}
	if file.get_length() > MAX_FILE_BYTES: return {"data": {}, "error": "存档超过 32 MiB。"}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return {"data": {}, "error": "存档 JSON 已损坏（第 %d 行）。" % json.get_error_line()}
	var error := validate(json.data)
	return {"data": json.data if error.is_empty() else {}, "error": error}


static func prepare_load(path := DEFAULT_SAVE_PATH) -> String:
	if GameSession.online_active: return "请先退出联机对局，再读取单机存档。"
	var result := read(path)
	if not result.error.is_empty(): return result.error
	var data: Dictionary = result.data
	GameSession.pending_save_data = data.duplicate(true)
	GameSession.player_civ_id = StringName(data.session.player_civ_id)
	GameSession.ai_civ_id = StringName(data.session.ai_civ_id)
	GameSession.match_map_data = MapDataScript.normalized(data.map)
	GameSession.selected_map_path = String(data.session.get("selected_map_path", ""))
	for field in SESSION_FIELDS:
		if data.session.has(field): GameSession.set(field, data.session[field])
	return ""


static func capture(bootstrap: Node) -> Dictionary:
	if not is_instance_valid(bootstrap): return {}
	var root := bootstrap.get_parent()
	var state: MatchState = bootstrap.get("match_state")
	var session := {"player_civ_id": String(bootstrap.player_civ.id), "ai_civ_id": String(bootstrap.ai_civ.id), "selected_map_path": GameSession.selected_map_path}
	for field in SESSION_FIELDS: session[field] = GameSession.get(field)
	var data := {"format": FORMAT, "schema_version": VERSION, "saved_at": Time.get_datetime_string_from_system(), "session": session,
		"map": bootstrap.map_data.duplicate(true), "teams": [], "winner": state.winner, "frozen": state.frozen,
		"entities": [], "age_jobs": [], "technology_jobs": [], "fog": {}, "camera": {}, "ai": {}, "support": {}}
	for team in Enums.Team.values():
		var stock: Array = []
		for type in 4: stock.append(state.get_resource(team, type))
		data.teams.append({"resources": stock, "population": int(state.population[team]), "population_cap": int(state.population_cap[team]), "population_reserved": int(state.population_reserved[team]),
			"age": state.age_of(team), "technologies": state.researched_technologies.get(team, {}).keys().map(func(value): return String(value)), "color": state.get_team_color_id(team)})
	var ids := {}
	var next_id := 1
	for entity in root.get_node("Entities").get_children():
		if entity.has_meta("fog_memory") or entity.get("is_placement_ghost") == true or entity.is_queued_for_deletion(): continue
		if entity is UnitAgent or entity is BuildingAgent or entity is ResourceNode or entity is ProjectileAgent or entity.is_in_group("terrain_regions"):
			ids[entity.get_instance_id()] = next_id
			next_id += 1
	for entity in root.get_node("Entities").get_children():
		if ids.has(entity.get_instance_id()): data.entities.append(_capture_entity(entity, ids))
	if is_instance_valid(state.age_progression):
		for team in state.age_progression._jobs:
			var job: Dictionary = state.age_progression._jobs[team]
			var building: Variant = job.building.get_ref()
			var record := _capture_fields(job, ["target_age", "elapsed", "duration", "food", "gold"])
			record.merge({"team": team, "building": _id_of(building, ids)})
			data.age_jobs.append(record)
	if is_instance_valid(state.technology_progression):
		for job in state.technology_progression.jobs.values():
			var record := _capture_fields(job, ["technology_id", "team", "elapsed", "duration", "progress", "cost"])
			record.building = _id_of(job.building.get_ref(), ids)
			data.technology_jobs.append(record)
	if state.fog != null:
		data.fog = {"cell_size": state.fog.cell_size, "explored": [], "memories": []}
		for team in Enums.Team.values():
			data.fog.explored.append(Marshalls.raw_to_base64(state.fog.explored[team]))
			var records: Array = []
			for key in state.fog.memories[team]:
				var memory: Dictionary = state.fog.memories[team][key]
				records.append(_capture_memory(memory, int(ids.get(key, 0))))
			data.fog.memories.append(records)
	var camera := root.get_node_or_null("Camera2D") as Camera2D
	if camera != null: data.camera = {"position": _vec(camera.position), "zoom": _vec(camera.zoom)}
	data.ai = capture_ai(root)
	var support := root.get_node_or_null("LandSupport")
	if support != null:
		var cooldowns: Array = []
		for key in support.cooldowns:
			if ids.has(key): cooldowns.append({"entity": ids[key], "remaining": support.cooldowns[key]})
		data.support = {"elapsed": support.elapsed, "cooldowns": cooldowns}
	return data


static func _capture_entity(entity: Node2D, ids: Dictionary) -> Dictionary:
	var record := {"id": ids[entity.get_instance_id()], "pos": _vec(entity.sim_pos), "name": String(entity.name), "map_id": String(entity.get_meta("map_id", ""))}
	if entity is UnitAgent:
		record.merge({"type": "unit", "definition": String(entity.def.id), "team": entity.team, "fields": _object_fields(entity, UNIT_NUMBERS + UNIT_BOOLS), "vectors": _object_vectors(entity, UNIT_VECTORS), "refs": {}, "order": entity.order,
			"gather_state": entity._gather_state, "combat_action": String(entity._combat_action), "path": _vectors(entity._path), "gather_work_points": _vectors(entity._gather_work_points), "gather_candidates": []})
		for field in UNIT_REFS: record.refs[field] = _id_of(entity.get(field), ids)
		for reference in entity._gather_candidates:
			var id := _id_of(reference.get_ref(), ids)
			if id != 0: record.gather_candidates.append(id)
	elif entity is BuildingAgent:
		record.merge({"type": "building", "definition": String(entity.def.id), "team": entity.team, "fields": _object_fields(entity, BUILDING_NUMBERS + BUILDING_BOOLS), "queue": []})
		record.fields["_spawn_retry_remaining"] = entity._spawn_retry_remaining
		for i in entity.train_queue.size():
			var id: int = entity.train_queue_ids[i]
			record.queue.append({"id": id, "definition": String(entity.train_queue[i].id), "payment": entity._train_payments[id].duplicate(true)})
	elif entity is ResourceNode:
		record.merge({"type": "resource", "resource_type": entity.resource_type, "amount": entity.amount, "gather_rate": entity.gather_rate, "block_size": _vec(entity.block_size_override)})
	elif entity is PathBlocker and entity.is_in_group("terrain_regions"):
		record.merge({"type":"terrain", "terrain_id":String(entity.kind), "block_size":_vec(entity.block_size)})
	elif entity is ProjectileAgent:
		var weapon: UnitDef = entity.attacker_def
		record.merge({"type": "projectile", "team": entity.team, "presentation": entity.network_presentation(), "attacker": _id_of(entity.attacker, ids), "weapon": {"id": String(weapon.id), "attack": weapon.attack, "is_ranged": weapon.is_ranged, "projectile_speed": weapon.projectile_speed, "projectile_kind": String(weapon.projectile_kind)}})
	return record


static func restore(bootstrap: Node, data: Dictionary) -> String:
	var error := validate(data)
	if not error.is_empty(): return error
	var root := bootstrap.get_parent()
	if GameSession.online_active or root.get_meta("online_match", false): return "联机对局无法恢复本地存档。"
	var entities := root.get_node("Entities") as Node2D
	var state: MatchState = bootstrap.get("match_state")
	state.frozen = true
	if is_instance_valid(state.age_progression): state.age_progression._jobs.clear()
	if is_instance_valid(state.technology_progression): state.technology_progression.jobs.clear()
	# Memory proxies belong to the old entity tree. Drop holder references before
	# replacing that tree, including restores into the currently running match.
	var fog_holder := root.get_node_or_null("FogOfWar")
	if fog_holder != null: fog_holder._clear_memory_views()
	for child in entities.get_children(): child.free()
	# Age-dependent presentation is constructed with the saved age. Economic
	# totals are assigned after _ready registration, so they are not doubled.
	for team in Enums.Team.values():
		state.team_ages[team] = int(data.teams[team].age)
		state.team_color_ids[team] = int(data.teams[team].color)
		state.researched_technologies[team] = {}
		for id in data.teams[team].technologies: state.researched_technologies[team][String(id)] = true
	var nodes := {}
	for record in data.entities:
		var entity: Node2D
		match record.type:
			"unit":
				entity = UNIT_VIEW.instantiate()
				entity.def = Catalog.get_unit(StringName(record.definition))
			"building":
				entity = BUILDING_VIEW.instantiate()
				if record.definition == "farm": entity.set_script(load("res://scripts/entities/farm_agent.gd"))
				entity.def = Catalog.get_building(StringName(record.definition))
				entity.is_complete = record.fields.is_complete
				entity.build_progress = float(record.fields.build_progress)
				entity._construction_started = record.fields._construction_started
			"resource":
				entity = ResourceNode.new()
				entity.resource_type = int(record.resource_type)
				entity.amount = float(record.amount)
				entity.gather_rate = float(record.gather_rate)
				entity.block_size_override = _vector(record.block_size)
			"terrain":
				entity = TERRAIN_SCRIPT.new()
				entity.kind = StringName(record.terrain_id)
				entity.auto_block_size = false
				entity.block_size = _vector(record.block_size)
			"projectile": entity = PROJECTILE_VIEW.instantiate()
		entity.name = String(record.name)
		entity.sim_pos = _vector(record.pos)
		if record.type in ["unit", "building"]:
			entity.team = int(record.team)
			entity.civ = CHINESE if String(data.session["player_civ_id" if entity.team == 0 else "ai_civ_id"]) == "chinese" else TEUTONS
			entity.match_state = state
		if not record.map_id.is_empty(): entity.set_meta("map_id", record.map_id)
		entities.add_child(entity)
		nodes[int(record.id)] = entity
	for record in data.entities:
		var entity: Node2D = nodes[int(record.id)]
		if record.type == "unit":
			_apply_fields(entity, record.fields, UNIT_NUMBERS + UNIT_BOOLS)
			for field in UNIT_VECTORS: entity.set(field, _vector(record.vectors[field]))
			for field in UNIT_REFS: entity.set(field, nodes.get(int(record.refs[field])))
			entity.order = int(record.order)
			entity._gather_state = String(record.gather_state)
			entity._combat_action = StringName(record.combat_action)
			entity._path = _packed_vectors(record.path)
			entity._path_pending = false
			entity._gather_work_points = _packed_vectors(record.gather_work_points)
			entity._gather_candidates.clear()
			for id in record.gather_candidates: entity._gather_candidates.append(weakref(nodes[int(id)]))
			entity._sync_visual()
			entity._update_idle_animation(0.0)
		elif record.type == "building":
			_apply_fields(entity, record.fields, BUILDING_NUMBERS + BUILDING_BOOLS)
			entity._spawn_retry_remaining = float(record.fields.get("_spawn_retry_remaining", 0.0))
			entity.train_queue.clear()
			entity.train_queue_ids.clear()
			entity._train_payments.clear()
			for item in record.queue:
				entity.train_queue.append(Catalog.get_unit(StringName(item.definition)))
				entity.train_queue_ids.append(int(item.id))
				entity._train_payments[int(item.id)] = {"cost": item.payment.cost.duplicate(), "population": int(item.payment.population)}
			entity.set_physics_process(not entity.train_queue.is_empty())
			entity._configure_visuals()
			entity._sync_visual()
		elif record.type == "projectile":
			var weapon := Catalog.get_unit(StringName(record.weapon.id))
			if weapon == null:
				weapon = UnitDef.new()
				weapon.id = StringName(record.weapon.id)
				weapon.attack = int(record.weapon.attack)
				weapon.is_ranged = record.weapon.is_ranged
				weapon.projectile_speed = float(record.weapon.projectile_speed)
				weapon.projectile_kind = StringName(record.weapon.projectile_kind)
			entity.setup(_vector(record.presentation.origin), _vector(record.presentation.aim), weapon, int(record.team), nodes.get(int(record.attacker)))
			entity.match_state = state
			entity.apply_network_presentation(record.presentation)
	for team in Enums.Team.values():
		var saved: Dictionary = data.teams[team]
		for type in 4: state.resources[team][type] = int(saved.resources[type])
		state.population[team] = int(saved.population)
		state.population_cap[team] = int(saved.population_cap)
		state.population_reserved[team] = int(saved.population_reserved)
	if is_instance_valid(state.age_progression):
		for record in data.age_jobs:
			var job: Dictionary = record.duplicate(true)
			job.building = weakref(nodes[int(record.building)])
			job.target_age = int(record.target_age)
			state.age_progression._jobs[int(record.team)] = job
	if is_instance_valid(state.technology_progression):
		for record in data.technology_jobs:
			var job: Dictionary = record.duplicate(true)
			var building: Node = nodes[int(record.building)]
			job.building = weakref(building)
			job.building_id = building.get_instance_id()
			job.team = int(record.team)
			state.technology_progression.jobs[building.get_instance_id()] = job
	var support := root.get_node_or_null("LandSupport")
	if support != null and not data.support.is_empty():
		support.cooldowns.clear()
		support.elapsed = float(data.support.elapsed)
		for item in data.support.cooldowns: support.cooldowns[nodes[int(item.entity)].get_instance_id()] = float(item.remaining)
	for service in ["NavService", "VisionService"]:
		var holder := root.get_node_or_null(service)
		if holder != null: holder.rebuild_from_scene()
	_restore_fog(root, state, data.fog, nodes)
	for entity in nodes.values():
		# Pending navigation callbacks belong to the old tree. Restart resource
		# searches only after the restored nav grid and visibility are available.
		if entity is UnitAgent and entity.order == Enums.OrderType.GATHER and entity._gather_state == "searching_resource":
			entity._finish_or_drop_off()
	var camera := root.get_node_or_null("Camera2D") as Camera2D
	if camera != null and not data.camera.is_empty():
		camera.position = _vector(data.camera.position)
		camera.zoom = _vector(data.camera.zoom)
	state.winner = int(data.winner)
	state.frozen = bool(data.frozen)
	for team in Enums.Team.values():
		state.team_color_changed.emit(team)
		state.age_changed.emit(team, state.age_of(team))
		if is_instance_valid(state.age_progression): state.age_progression._emit_progress(team)
	if state.winner >= 0: state.winner_decided.emit(state.winner)
	return ""


static func capture_ai(root: Node) -> Dictionary:
	var result := {}
	for name in ["AiController", "AiGateway"]:
		var ai := root.get_node_or_null(name)
		if ai == null or ai.is_queued_for_deletion(): continue
		var fields := ["match_time", "_tick_accum", "enabled"]
		fields.append_array(["tick"] if name == "AiGateway" else ["director_phase", "_previous_phase", "_next_build_slot", "_legacy_phase"])
		result[name] = _object_fields(ai, fields)
	return result


static func restore_ai(root: Node, data: Dictionary) -> void:
	for name in data:
		var ai := root.get_node_or_null(name)
		if ai == null: continue
		var fields := ["match_time", "_tick_accum", "enabled"]
		fields.append_array(["tick"] if name == "AiGateway" else ["director_phase", "_previous_phase", "_next_build_slot", "_legacy_phase"])
		_apply_fields(ai, data[name], fields)
		ai.set_process(bool(ai.enabled))


static func _capture_memory(memory: Dictionary, id: int) -> Dictionary:
	var record := {"entity": id, "sim_pos": _vec(memory.sim_pos), "position": _vec(memory.position), "footprint": _vec(memory.footprint), "minimap_kind": memory.get("minimap_kind", "resource"), "team": memory.get("team"), "resource_type": memory.get("resource_type"), "parts": []}
	record["terrain_region"] = memory.get("terrain_region", false)
	record["kind"] = String(memory.kind) if memory.get("kind") != null else null
	for part in memory.parts:
		var transform: Transform2D = part.transform
		var color: Color = part.color
		var encoded := {"transform": [_vec(transform.x), _vec(transform.y), _vec(transform.origin)], "color": [color.r, color.g, color.b, color.a], "z": part.z}
		for key in PART_COLORS:
			if part.has(key):
				var value: Color = part[key]
				encoded[key] = [value.r, value.g, value.b, value.a]
		for key in ["z_as_relative", "texture_filter", "texture_repeat"]:
			if part.has(key): encoded[key] = part[key]
		if part.has("polygon"):
			encoded.polygon = _vectors(part.polygon)
			encoded.uv = _vectors(part.get("uv", PackedVector2Array()))
			if part.get("texture") != null: encoded.texture = _capture_texture(part.texture)
			for key in POLYGON_VECTORS:
				if part.has(key): encoded[key] = _vec(part[key])
			for key in ["texture_rotation", "invert_enabled", "invert_border", "antialiased"]:
				if part.has(key): encoded[key] = part[key]
			encoded.vertex_colors = []
			for value: Color in part.get("vertex_colors", PackedColorArray()):
				encoded.vertex_colors.append([value.r, value.g, value.b, value.a])
			encoded.polygons = []
			for polygon in part.get("polygons", []): encoded.polygons.append(Array(polygon))
		elif part.has("texture"):
			encoded.texture = _capture_texture(part.texture)
			encoded.offset = _vec(part.offset)
			encoded.centered = part.centered
		if part.get("material") is ShaderMaterial and part.material.shader == PLAYER_COLOR_SHADER:
			encoded.material = {"type": "player_color", "player_mask": _capture_texture(part.material.get_shader_parameter("player_mask")), "player_palette": _capture_texture(part.material.get_shader_parameter("player_palette")),
				"source_player": part.material.get_shader_parameter("source_player"), "target_player": part.material.get_shader_parameter("target_player"), "sprite_layer": part.material.get_shader_parameter("sprite_layer")}
		elif part.get("material") is CanvasItemMaterial:
			encoded.material = {"type": "canvas", "blend_mode": part.material.blend_mode, "light_mode": part.material.light_mode}
		elif part.get("material") is ShaderMaterial and part.material.shader == CLIFF_FOG_SHADER:
			encoded.material = {"type":"terrain_cliff"}
		elif part.get("material") is ShaderMaterial and part.material.shader == WATER_SHADER:
			var material := part.material as ShaderMaterial
			var count: int = material.get_shader_parameter("coast_count")
			var points: PackedVector2Array = material.get_shader_parameter("coast_points")
			var ends: PackedVector2Array = material.get_shader_parameter("coast_ends")
			encoded.material = {"type":"terrain_water", "coast_count":count,
				"coast_points":_vectors(points.slice(0,count)), "coast_ends":_vectors(ends.slice(0,count)),
				"shore_width":material.get_shader_parameter("shore_width")}
			for uniform in WATER_TEXTURE_PATHS:
				encoded.material[uniform] = _capture_texture(material.get_shader_parameter(uniform))
			# Fog textures, view-team state and screen_origin belong to the current
			# match. The holder rebinds them after the value snapshot is restored.
		record.parts.append(encoded)
	return record


static func _capture_texture(texture: Texture2D) -> Dictionary:
	if texture is AtlasTexture:
		return {"atlas": _capture_texture(texture.atlas), "region": [_vec(texture.region.position), _vec(texture.region.size)]}
	return {"path": texture.resource_path}


static func _restore_texture(record: Dictionary) -> Texture2D:
	if record.has("atlas"):
		var texture := AtlasTexture.new()
		texture.atlas = _restore_texture(record.atlas)
		texture.region = Rect2(_vector(record.region[0]), _vector(record.region[1]))
		return texture
	return load(record.path) as Texture2D if not String(record.path).is_empty() else null


static func _restore_fog(root: Node, state: MatchState, data: Dictionary, nodes: Dictionary) -> void:
	if state.fog == null or data.is_empty(): return
	var fog: RefCounted = state.fog
	for team in Enums.Team.values():
		fog.explored[team] = Marshalls.base64_to_raw(data.explored[team])
		fog.memories[team].clear()
		var orphan := -1
		for record in data.memories[team]:
			var parts: Array = []
			for encoded in record.parts:
				var part := {"transform": Transform2D(_vector(encoded.transform[0]), _vector(encoded.transform[1]), _vector(encoded.transform[2])), "color": Color(encoded.color[0], encoded.color[1], encoded.color[2], encoded.color[3]), "z": int(encoded.z)}
				for field in PART_COLORS:
					if encoded.has(field):
						var color: Array = encoded[field]
						part[field] = Color(color[0], color[1], color[2], color[3])
				for field in ["z_as_relative", "texture_filter", "texture_repeat"]:
					if encoded.has(field): part[field] = encoded[field]
				if encoded.has("polygon"):
					part.polygon = _packed_vectors(encoded.polygon)
					part.uv = _packed_vectors(encoded.get("uv", []))
					part.texture = _restore_texture(encoded.texture) if encoded.has("texture") else null
					for field in POLYGON_VECTORS:
						if encoded.has(field): part[field] = _vector(encoded[field])
					for field in ["texture_rotation", "invert_enabled", "invert_border", "antialiased"]:
						if encoded.has(field): part[field] = encoded[field]
					var colors := PackedColorArray()
					for value in encoded.get("vertex_colors", []): colors.append(Color(value[0],value[1],value[2],value[3]))
					part.vertex_colors = colors
					part.polygons = []
					for polygon in encoded.get("polygons", []): part.polygons.append(PackedInt32Array(polygon))
				elif encoded.has("texture"):
					part.merge({"texture": _restore_texture(encoded.texture), "offset": _vector(encoded.offset), "centered": encoded.centered})
				if encoded.has("material"):
					var material_data: Dictionary = encoded.material
					if material_data.type == "player_color":
						var material := ShaderMaterial.new()
						material.shader = PLAYER_COLOR_SHADER
						for uniform in ["source_player", "target_player", "sprite_layer"]: material.set_shader_parameter(uniform, int(material_data[uniform]))
						for uniform in ["player_mask", "player_palette"]: material.set_shader_parameter(uniform, _restore_texture(material_data[uniform]))
						part.material = material
					elif material_data.type == "terrain_cliff":
						var material := ShaderMaterial.new()
						material.shader = CLIFF_FOG_SHADER
						part.material = material
					elif material_data.type == "terrain_water":
						var material := ShaderMaterial.new()
						material.shader = WATER_SHADER
						material.set_shader_parameter("coast_count",int(material_data.coast_count))
						material.set_shader_parameter("shore_width",float(material_data.shore_width))
						for uniform in ["coast_points", "coast_ends"]:
							var vectors := _packed_vectors(material_data[uniform])
							vectors.resize(WATER_COAST_LIMIT)
							material.set_shader_parameter(uniform,vectors)
						for uniform in WATER_TEXTURE_PATHS:
							material.set_shader_parameter(uniform,_restore_texture(material_data[uniform]))
						part.material = material
					else:
						var material := CanvasItemMaterial.new()
						material.blend_mode = int(material_data.blend_mode)
						material.light_mode = int(material_data.light_mode)
						part.material = material
				parts.append(part)
			var key: int = nodes[int(record.entity)].get_instance_id() if nodes.has(int(record.entity)) else orphan
			orphan -= 1
			var pos := _vector(record.sim_pos)
			var footprint := _vector(record.footprint)
			fog.memories[team][key] = {"sim_pos": pos, "position": _vector(record.position), "footprint": footprint, "cells": fog.footprint_cells(pos, footprint), "parts": parts, "appearance": hash(record.parts), "minimap_kind": record.minimap_kind, "team": record.team, "resource_type": record.resource_type, "kind": StringName(record.kind) if record.get("kind") != null else null, "terrain_region":record.get("terrain_region", false), "last_seen_msec": Time.get_ticks_msec()}
	fog.dirty = true
	fog.revision += 1
	var holder := root.get_node_or_null("FogOfWar")
	if holder != null: holder.rebuild_now()


static func _id_of(entity: Variant, ids: Dictionary) -> int:
	return int(ids.get(entity.get_instance_id(), 0)) if is_instance_valid(entity) else 0

static func _object_fields(object: Object, fields: Array) -> Dictionary:
	var result := {}
	for field in fields: result[field] = object.get(field)
	return result

static func _capture_fields(source: Dictionary, fields: Array) -> Dictionary:
	var result := {}
	for field in fields: result[field] = source[field]
	return result

static func _object_vectors(object: Object, fields: Array) -> Dictionary:
	var result := {}
	for field in fields: result[field] = _vec(object.get(field))
	return result

static func _apply_fields(object: Object, source: Dictionary, fields: Array) -> void:
	for field in fields:
		if not source.has(field): continue
		var current: Variant = object.get(field)
		object.set(field, int(source[field]) if current is int else source[field])

static func _vec(vector: Vector2) -> Array:
	return [vector.x, vector.y]

static func _vector(vector: Array) -> Vector2:
	return Vector2(float(vector[0]), float(vector[1]))

static func _vectors(vectors: PackedVector2Array) -> Array:
	var result: Array = []
	for vector in vectors: result.append(_vec(vector))
	return result

static func _packed_vectors(vectors: Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for vector in vectors: result.append(_vector(vector))
	return result


static func validate(data: Variant) -> String:
	if not data is Dictionary: return "存档已损坏：根节点必须是对象。"
	if data.get("format") != FORMAT or data.get("schema_version") != VERSION: return "不支持的存档格式或版本（需要 aoe2-rts-save / 1）。"
	var map_errors := MapDataScript.validate(data.get("map"))
	if not map_errors.is_empty(): return "存档地图已损坏：" + "；".join(map_errors)
	if not data.get("saved_at") is String or not data.get("session") is Dictionary: return "存档缺少时间或对局设置。"
	var session: Dictionary = data.session
	if session.has("selected_map_path") and not session.selected_map_path is String: return "存档地图来源已损坏。"
	if session.get("player_civ_id") not in ["chinese", "teutons"] or session.get("ai_civ_id") not in ["chinese", "teutons"] or session.get("match_ai_mode") not in ["local", "gateway", "sandbox", "none"]: return "存档文明或 AI 模式无效。"
	for field in SESSION_FIELDS:
		if not session.has(field) or typeof(session[field]) != typeof(GameSession.get(field)) and not (MapDataScript.number(session[field]) and MapDataScript.number(GameSession.get(field))): return "存档 AI 设置已损坏：" + field
	if not data.get("teams") is Array or data.teams.size() != 2: return "存档阵营数据已损坏。"
	for team in data.teams:
		if not team is Dictionary or not _numbers(team.get("resources"), 4) or not _integers(team, ["population", "population_cap", "population_reserved", "age", "color"]): return "存档经济数据已损坏。"
		if not _integer_between(team.age, 0, 3) or not _integer_between(team.color, 1, 8) or not team.get("technologies") is Array: return "存档时代或科技数据已损坏。"
		for value in team.resources:
			if not _integer_between(value, 0, 2147483647): return "存档资源值已损坏。"
		for id in team.technologies:
			if not id is String or not Catalog.technologies().has(id): return "存档包含未知科技。"
	if not _integer_between(data.get("winner"), -1, 1) or not data.get("frozen") is bool: return "存档胜负状态已损坏。"
	if not data.get("entities") is Array or data.entities.size() > MAX_ENTITIES: return "存档实体列表已损坏或过大。"
	var ids := {}
	for record in data.entities:
		if not record is Dictionary or not _integer_between(record.get("id"), 1, MAX_ENTITIES) or ids.has(int(record.id)): return "存档实体 ID 无效或重复。"
		ids[int(record.id)] = record
		if not MapDataScript.vector(record.get("pos")) or not record.get("name") is String or not record.get("map_id") is String: return "存档实体位置或名称已损坏。"
		if record.get("type") in ["unit", "building"]:
			if not _integer_between(record.get("team"), 0, 1): return "存档实体阵营无效。"
			if not record.get("definition") is String: return "存档实体定义已损坏。"
			var definition: Variant = Catalog.get_unit(StringName(record.get("definition", ""))) if record.type == "unit" else Catalog.get_building(StringName(record.get("definition", "")))
			if definition == null: return "存档包含未知实体定义。"
			var numbers: Array = UNIT_NUMBERS if record.type == "unit" else BUILDING_NUMBERS
			var booleans: Array = UNIT_BOOLS if record.type == "unit" else BUILDING_BOOLS
			if not record.get("fields") is Dictionary: return "存档实体属性已损坏。"
			for field in numbers:
				if not MapDataScript.number(record.fields.get(field)): return "存档实体数值已损坏：" + field
			for field in booleans:
				if not record.fields.get(field) is bool: return "存档实体状态已损坏：" + field
			if record.type == "unit":
				if not _integer_between(record.get("order"), 0, Enums.OrderType.size()-1) or not record.get("gather_state") is String or record.get("combat_action") not in ["", "attack", "die"]: return "存档单位命令已损坏。"
				if not record.get("vectors") is Dictionary or not record.get("refs") is Dictionary: return "存档单位目标已损坏。"
				for field in UNIT_VECTORS:
					if not MapDataScript.vector(record.vectors.get(field)): return "存档单位坐标已损坏。"
				for field in UNIT_REFS:
					if not _integer_between(record.refs.get(field), 0, MAX_ENTITIES): return "存档单位引用已损坏。"
				if not _vector_list(record.get("path")) or not _vector_list(record.get("gather_work_points")) or not record.get("gather_candidates") is Array: return "存档单位路径已损坏。"
			else:
				if not record.get("queue") is Array or record.queue.size() > BuildingAgent.MAX_TRAIN_QUEUE: return "存档生产队列已损坏。"
				if record.fields.has("_spawn_retry_remaining") and (not MapDataScript.number(record.fields._spawn_retry_remaining) or record.fields._spawn_retry_remaining < 0 or record.fields._spawn_retry_remaining > BuildingAgent.TRAIN_SPAWN_RETRY_INTERVAL): return "存档建筑出口等待进度已损坏。"
				var queue_ids := {}
				for item in record.queue:
					if not item is Dictionary or not _integer_between(item.get("id"), 1, 2147483647) or queue_ids.has(int(item.id)) or not item.get("definition") is String or Catalog.get_unit(StringName(item.definition)) == null: return "存档生产队列项目已损坏。"
					queue_ids[int(item.id)] = true
					if not item.get("payment") is Dictionary or not _numbers(item.payment.get("cost"), 4) or not _integer_between(item.payment.get("population"), 0, 200): return "存档生产付款信息已损坏。"
		elif record.get("type") == "resource":
			if not _integer_between(record.get("resource_type"), 0, 3) or not MapDataScript.number(record.get("amount")) or float(record.amount) < 0 or not MapDataScript.number(record.get("gather_rate")) or float(record.gather_rate) < 0 or not MapDataScript.vector(record.get("block_size")): return "存档资源节点已损坏。"
		elif record.get("type") == "terrain":
			if record.get("terrain_id") not in ["water", "cliff"] or not MapDataScript.vector(record.get("block_size")): return "存档地形类型或尺寸已损坏。"
			var size := _vector(record.block_size)
			if size.x <= 0 or size.y <= 0 or size.x > MapDataScript.MAX_TERRAIN_SIZE or size.y > MapDataScript.MAX_TERRAIN_SIZE or not MapDataScript.bounds(data.map).encloses(Rect2(_vector(record.pos) - size * 0.5, size)): return "存档地形占地无效。"
		elif record.get("type") == "projectile":
			if not _integer_between(record.get("team"), 0, 1) or not record.get("presentation") is Dictionary or not record.get("weapon") is Dictionary: return "存档飞行弹药已损坏。"
			var p: Dictionary = record.presentation
			var w: Dictionary = record.weapon
			if not MapDataScript.vector(p.get("origin")) or not MapDataScript.vector(p.get("aim")) or not _numeric_fields(p, ["traveled", "launch_height", "impact_elapsed"]) or not p.get("impact") is bool or not p.get("source_def") is String or p.get("projectile_kind") not in ["stone", "arrow"]: return "存档弹药进度已损坏。"
			if not w.get("id") is String or not w.get("projectile_kind") is String or not w.get("is_ranged") is bool or not _numeric_fields(w, ["attack", "projectile_speed"]) or not _integer_between(record.get("attacker"), 0, MAX_ENTITIES): return "存档弹药来源已损坏。"
		else: return "存档包含未知实体类型。"
	for record in data.entities:
		if record.type == "unit":
			for field in UNIT_REFS:
				var id := int(record.refs[field])
				if id != 0 and (not ids.has(id) or not _valid_target(field, ids[id])): return "存档引用了不存在或不适用的单位目标。"
			for id in record.gather_candidates:
				if not _integer_between(id, 1, MAX_ENTITIES) or not ids.has(int(id)) or not _valid_target("_gather_target", ids[int(id)]): return "存档采集候选目标已损坏。"
		elif record.type == "projectile" and int(record.attacker) != 0 and not ids.has(int(record.attacker)): return "存档弹药引用已损坏。"
		if record.type == "projectile":
			if record.presentation.source_def != record.weapon.id or record.presentation.projectile_kind != ("stone" if record.weapon.projectile_kind == "stone" else "arrow"): return "存档弹药定义不一致。"
			if record.presentation.projectile_kind == "stone" and Catalog.get_unit(StringName(record.weapon.id)) == null: return "存档石弹定义已损坏。"
	for key in ["age_jobs", "technology_jobs"]:
		if not data.get(key) is Array or data[key].size() > MAX_ENTITIES: return "存档研究队列已损坏。"
		for job in data[key]:
			if not job is Dictionary or not _integer_between(job.get("team"), 0, 1) or not _integer_between(job.get("building"), 1, MAX_ENTITIES) or not ids.has(int(job.building)) or ids[int(job.building)].type != "building" or int(ids[int(job.building)].team) != int(job.team) or not _numeric_fields(job, ["elapsed", "duration"]) or job.elapsed < 0 or job.duration <= 0: return "存档研究目标或进度已损坏。"
			if key == "age_jobs":
				if not _integer_between(job.get("target_age"), 1, 3) or not _numeric_fields(job, ["food", "gold"]): return "存档时代研究已损坏。"
			else:
				if not job.get("technology_id") is String or not Catalog.technologies().has(job.technology_id) or not job.get("cost") is Dictionary or not MapDataScript.number(job.get("progress")): return "存档科技研究已损坏。"
				for value in job.cost.values():
					if not MapDataScript.number(value) or value < 0: return "存档研究费用已损坏。"
	var error := _validate_fog(data.get("fog"), MapDataScript.bounds(data.map))
	if not error.is_empty(): return error
	if not data.get("camera") is Dictionary or not data.get("ai") is Dictionary or not data.get("support") is Dictionary: return "存档附加状态已损坏。"
	if not data.camera.is_empty() and (not MapDataScript.vector(data.camera.get("position")) or not MapDataScript.vector(data.camera.get("zoom")) or data.camera.zoom[0] < 0.1 or data.camera.zoom[1] < 0.1): return "存档镜头已损坏。"
	for name in data.ai:
		if name not in ["AiController", "AiGateway"] or not data.ai[name] is Dictionary or not _numeric_fields(data.ai[name], ["match_time", "_tick_accum"]) or not data.ai[name].get("enabled") is bool: return "存档 AI 运行状态已损坏。"
		var fields: Array = ["tick"] if name == "AiGateway" else ["director_phase", "_previous_phase", "_next_build_slot", "_legacy_phase"]
		if not _integers(data.ai[name], fields): return "存档 AI 阶段已损坏。"
	if not data.support.is_empty():
		if not MapDataScript.number(data.support.get("elapsed")) or not data.support.get("cooldowns") is Array: return "存档建筑攻击进度已损坏。"
		for item in data.support.cooldowns:
			if not item is Dictionary or not _integer_between(item.get("entity"), 1, MAX_ENTITIES) or not ids.has(int(item.entity)) or not MapDataScript.number(item.get("remaining")): return "存档建筑攻击目标已损坏。"
	return ""


static func _validate_fog(data: Variant, bounds: Rect2) -> String:
	if not data is Dictionary: return "存档迷雾数据已损坏。"
	if data.is_empty(): return ""
	var expected_size := 4.0 if maxf(bounds.size.x, bounds.size.y) > 256 else 1.0
	if data.get("cell_size") != expected_size or not data.get("explored") is Array or data.explored.size() != 2 or not data.get("memories") is Array or data.memories.size() != 2: return "存档迷雾尺寸已损坏。"
	var mask_size := ceili(bounds.size.x / expected_size) * ceili(bounds.size.y / expected_size)
	for team in 2:
		if not data.explored[team] is String or data.explored[team].length() > mask_size * 2 or Marshalls.base64_to_raw(data.explored[team]).size() != mask_size or not data.memories[team] is Array or data.memories[team].size() > MAX_ENTITIES: return "存档探索记录已损坏。"
		for memory in data.memories[team]:
			if not memory is Dictionary or not _integer_between(memory.get("entity"), 0, MAX_ENTITIES) or not MapDataScript.vector(memory.get("sim_pos")) or not MapDataScript.vector(memory.get("position")) or not MapDataScript.vector(memory.get("footprint")) or memory.get("minimap_kind") not in ["building", "resource", "blocker"] or not memory.get("parts") is Array or memory.parts.size() > 64: return "存档迷雾记忆已损坏。"
			if memory.get("team") != null and not _integer_between(memory.team, 0, 1) or memory.get("resource_type") != null and not _integer_between(memory.resource_type, 0, 3): return "存档迷雾记忆阵营已损坏。"
			if memory.has("terrain_region") and not memory.terrain_region is bool: return "存档地形记忆已损坏。"
			if memory.get("kind") != null and (not memory.kind is String or memory.kind.length() > 128): return "存档迷雾记忆类型已损坏。"
			if memory.get("terrain_region", false) and (memory.get("kind") not in ["water", "cliff"] or memory.minimap_kind != "blocker"): return "存档地形记忆类型已损坏。"
			for part in memory.parts:
				if not part is Dictionary or not _vector_list(part.get("transform")) or part.transform.size() != 3 or not _numbers(part.get("color"), 4) or not MapDataScript.number(part.get("z")): return "存档迷雾图像已损坏。"
				for field in PART_COLORS:
					if part.has(field) and not _numbers(part[field],4): return "存档迷雾颜色已损坏。"
				if part.has("z_as_relative") and not part.z_as_relative is bool: return "存档迷雾层级已损坏。"
				if part.has("texture_filter") and not _integer_between(part.texture_filter,0,6) or part.has("texture_repeat") and not _integer_between(part.texture_repeat,0,3): return "存档迷雾纹理设置已损坏。"
				if part.has("polygon"):
					if not _vector_list(part.polygon) or not _vector_list(part.get("uv", [])) or not part.get("uv", []).is_empty() and part.uv.size() != part.polygon.size(): return "存档迷雾多边形已损坏。"
					if part.has("texture") and not _valid_texture(part.texture): return "存档迷雾纹理已损坏。"
					for field in POLYGON_VECTORS:
						if part.has(field) and not MapDataScript.vector(part[field]): return "存档迷雾纹理坐标已损坏。"
					for field in ["texture_rotation", "invert_border"]:
						if part.has(field) and not MapDataScript.number(part[field]): return "存档迷雾纹理数值已损坏。"
					for field in ["invert_enabled", "antialiased"]:
						if part.has(field) and not part[field] is bool: return "存档迷雾多边形状态已损坏。"
					if not part.get("vertex_colors", []) is Array or part.get("vertex_colors", []).size() > part.polygon.size(): return "存档迷雾顶点颜色已损坏。"
					for color in part.get("vertex_colors", []):
						if not _numbers(color,4): return "存档迷雾顶点颜色已损坏。"
					if not part.get("polygons", []) is Array or part.get("polygons", []).size() > MAX_ENTITIES: return "存档迷雾面索引已损坏。"
					for polygon in part.get("polygons", []):
						if not polygon is Array or polygon.size() > MAX_ENTITIES: return "存档迷雾面索引已损坏。"
						for index in polygon:
							if not _integer_between(index,0,part.polygon.size()-1): return "存档迷雾面索引已损坏。"
				elif part.has("texture"):
					if not _valid_texture(part.texture) or not MapDataScript.vector(part.get("offset")) or not part.get("centered") is bool: return "存档迷雾纹理已损坏。"
				else: return "存档迷雾轮廓已损坏。"
				if part.has("material"):
					var material: Variant = part.material
					if not material is Dictionary or material.get("type") not in ["player_color", "canvas", "terrain_cliff", "terrain_water"]: return "存档迷雾材质已损坏。"
					if material.type == "player_color":
						if not _valid_texture(material.get("player_mask")) or not _valid_texture(material.get("player_palette")) or not _integer_between(material.get("source_player"), 1, 8) or not _integer_between(material.get("target_player"), 1, 8) or not _integer_between(material.get("sprite_layer"), 0, 2): return "存档迷雾颜色已损坏。"
					elif material.type == "terrain_cliff":
						if not part.has("polygon") or not memory.get("terrain_region", false): return "存档地形材质已损坏。"
					elif material.type == "terrain_water":
						if not part.has("polygon") or not memory.get("terrain_region",false) or memory.get("kind") != "water" or not _valid_water_material(material): return "存档水域岸线材质已损坏。"
					elif not _integer_between(material.get("blend_mode"), 0, 4) or not _integer_between(material.get("light_mode"), 0, 2): return "存档迷雾混合模式已损坏。"
	return ""

static func _valid_water_material(material: Dictionary) -> bool:
	if not _integer_between(material.get("coast_count"),1,WATER_COAST_LIMIT): return false
	for uniform in ["coast_points", "coast_ends"]:
		if not _vector_list(material.get(uniform)) or material[uniform].size() != int(material.coast_count): return false
		for point: Array in material[uniform]:
			if not _vector(point).is_finite(): return false
	if not MapDataScript.number(material.get("shore_width")) or material.shore_width <= 0.0 or material.shore_width > 2.6: return false
	for uniform in WATER_TEXTURE_PATHS:
		var texture: Variant = material.get(uniform)
		if not texture is Dictionary or texture.size() != 1 or texture.get("path") != WATER_TEXTURE_PATHS[uniform]: return false
	return true

static func _valid_texture(data: Variant, depth := 0) -> bool:
	if not data is Dictionary or depth > 4: return false
	if data.has("atlas"):
		return _valid_texture(data.atlas, depth + 1) and _vector_list(data.get("region")) and data.region.size() == 2
	var path: Variant = data.get("path")
	return path is String and (path.is_empty() or path.begins_with("res://assets/") and not ".." in path and path.get_extension().to_lower() in ["png", "webp", "jpg", "jpeg"])

static func _numbers(values: Variant, size: int) -> bool:
	if not values is Array or values.size() != size: return false
	for value in values:
		if not MapDataScript.number(value): return false
	return true

static func _valid_target(field: String, record: Dictionary) -> bool:
	if field in ["_gather_target", "_last_resource"]:
		return record.type == "resource" or record.type == "building" and record.definition == "farm"
	if field in ["_drop_off_target", "_build_target"]: return record.type == "building"
	return record.type in ["unit", "building"]

static func _numeric_fields(data: Dictionary, fields: Array) -> bool:
	for field in fields:
		if not MapDataScript.number(data.get(field)): return false
	return true

static func _integers(data: Dictionary, fields: Array) -> bool:
	for field in fields:
		if not _integer_between(data.get(field), 0, 2147483647): return false
	return true

static func _integer_between(value: Variant, minimum: int, maximum: int) -> bool:
	return MapDataScript.number(value) and float(value) == floorf(float(value)) and value >= minimum and value <= maximum

static func _vector_list(values: Variant) -> bool:
	if not values is Array or values.size() > MAX_ENTITIES: return false
	for vector in values:
		if not MapDataScript.vector(vector): return false
	return true
