class_name BuildingAgent
extends Node2D

signal construction_completed(building: BuildingAgent)
signal construction_started(building: BuildingAgent)
signal train_queue_changed
signal destroyed(building: BuildingAgent)

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const TeamColorCatalogScript := preload("res://scripts/presentation/team_color_catalog.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const AiEventBufferScript := preload("res://scripts/ai_gateway/event_buffer.gd")
const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const UnitOcclusionScript := preload("res://scripts/presentation/unit_occlusion.gd")
const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")
# Keep the entity origin/footprint unchanged; only its artwork covers walkers.
const TOWN_CENTER_SOLID_Z := 1
const TOWN_CENTER_SHADOW_Z := -3
# Soil is below selection rings, building shadows and unit foot shadows.
const FARM_GROUND_Z := -4
const MAX_TRAIN_QUEUE := 15
const TRAIN_SPAWN_RETRY_INTERVAL := 0.25

@export var team: Enums.Team = Enums.Team.PLAYER
@export var def: BuildingDef
@export var civ: CivDef
@export var accepts_all_resources := false
@export var accepted_resource_type: Enums.ResourceType = Enums.ResourceType.FOOD
var amount := 175.0
var resource_type := Enums.ResourceType.FOOD
var gather_rate := 4.0
var farm_has_crops := false:
	set(value):
		if farm_has_crops == value:
			return
		farm_has_crops = value
		if match_state != null and match_state.fog != null:
			match_state.fog.dirty = true
		if is_node_ready() and def != null and def.id == &"farm":
			_configure_visuals()

var match_state: MatchState
var sim_pos := Vector2.ZERO
var hp := 0.0
var melee_armor := 0.0
var pierce_armor := 0.0
var build_progress := 0.0
var is_complete := true:
	set(value):
		if is_complete == value:
			return
		is_complete = value
		if match_state != null and match_state.fog != null:
			match_state.fog.dirty = true
		if is_node_ready():
			if def != null and def.id == &"farm" and not is_placement_ghost:
				if value:
					add_to_group("resource_nodes")
				else:
					remove_from_group("resource_nodes")
			_configure_visuals()
var is_placement_ghost := false
var train_queue: Array[UnitDef] = []
var train_queue_ids: Array[int] = []
var _next_train_id := 1
var _train_payments: Dictionary = {}
var train_progress := 0.0
var _construction_started := false
var _population_cap_registered := false
var _reserved_population := 0
var _ghost_visual_valid: Variant = null
var _use_billboard := false
var _sprite_sheet_base := ""
var block_half := Vector2.ONE
var _visual_age := 0
var _spawn_retry_remaining := 0.0
var _production_exit_blocked := false

func _ready() -> void:
	_visual_age = match_state.age_of(team) if match_state != null else 0
	if match_state != null and not match_state.age_changed.is_connected(_on_age_changed):
		match_state.age_changed.connect(_on_age_changed)
	if match_state != null and not match_state.team_color_changed.is_connected(_on_team_color_changed):
		match_state.team_color_changed.connect(_on_team_color_changed)
	if sim_pos == Vector2.ZERO:
		sim_pos = position
	_sync_visual()
	if not is_placement_ghost:
		_register_groups()
	if def != null:
		accepted_resource_type = def.drop_off
		melee_armor = float(_age_attributes().get("melee_armor",def.melee_armor))
		pierce_armor = float(_age_attributes().get("pierce_armor",def.pierce_armor))
		_sync_block_half()
		if is_placement_ghost:
			# The cursor preview has no completed-building effects or capacity.
			hp = maxf(1.0, hp)
		elif has_meta("network_replica"):
			# Snapshot state was assigned before entering the tree. Do not turn a
			# foundation into a completed building while constructing a replica.
			pass
		elif (_construction_started or not is_complete) and def.build_time > 0.0:
			is_complete = false
			hp = maxf(1.0, _max_hp() * build_progress / def.build_time)
		else:
			build_progress = def.build_time
			hp = _max_hp()
			_complete_construction()
		_configure_visuals()
	set_physics_process(not train_queue.is_empty())
	set_selected(false)
	if not is_placement_ghost:
		EntityRegistryScript.register(self)

func _physics_process(delta: float) -> void:
	if has_meta("network_replica"):
		return
	if match_state != null and match_state.frozen:
		return
	if not is_complete or hp <= 0.0 or is_queued_for_deletion() or train_queue.is_empty():
		return
	_spawn_retry_remaining = maxf(0.0, _spawn_retry_remaining - maxf(delta, 0.0))
	var remaining := maxf(delta, 0.0)
	while not train_queue.is_empty():
		if is_training_population_blocked():
			return
		var unit_def := train_queue[0]
		var duration := maxf(_train_time(unit_def), 0.001)
		var advance := minf(remaining, maxf(duration - train_progress, 0.0))
		train_progress += advance
		remaining -= advance
		if train_progress < duration or _spawn_retry_remaining > 0.0:
			return
		if not _spawn_trained_unit(unit_def):
			# A shoreline or a crowd can temporarily leave no legal exit. Keep
			# the completed item/payment/population reservation and retry locally.
			_spawn_retry_remaining = TRAIN_SPAWN_RETRY_INTERVAL
			_production_exit_blocked = true
			return
		_production_exit_blocked = false
		_train_payments.erase(train_queue_ids[0])
		train_queue.pop_front()
		train_queue_ids.pop_front()
		train_progress = 0.0
		train_queue_changed.emit()
		if remaining <= 0.0:
			break
	set_physics_process(not train_queue.is_empty())

func accepts_resource(resource_type: Enums.ResourceType) -> bool:
	return accepts_all_resources or (def != null and def.id == &"town_center") or accepted_resource_type == resource_type or (def != null and def.id == &"mining_camp" and resource_type == Enums.ResourceType.STONE)

func start_construction() -> void:
	if def != null and def.id == &"farm":
		farm_has_crops = false
	if _population_cap_registered and match_state != null and def != null:
		match_state.register_pop(team, 0, -def.population_provided)
		_population_cap_registered = false
	_construction_started = true
	is_complete = false
	build_progress = 0.0
	hp = 1
	_sync_block_half()
	construction_started.emit(self)

func add_build_progress(amount: float) -> void:
	if is_complete or def == null or amount <= 0.0:
		return
	build_progress = minf(build_progress + amount, def.build_time)
	hp = maxf(1.0, _max_hp() * build_progress / maxf(def.build_time, 0.001))
	if build_progress >= def.build_time:
		hp = _max_hp()
		_complete_construction()

func take_damage(amount: float, _source: Node = null) -> void:
	if is_placement_ghost or amount <= 0.0 or hp <= 0.0:
		return
	hp = maxf(0.0, hp - amount)
	if hp > 0.0:
		return
	cancel_age_upgrade()
	cancel_technology()
	destroyed.emit(self)
	if def != null and def.id == &"town_center" and match_state != null:
		var winning_team := (
			Enums.Team.AI if team == Enums.Team.PLAYER else Enums.Team.PLAYER
		)
		match_state.set_winner(winning_team)
	queue_free()

func _max_hp() -> float:
	if def == null:
		return 0.0
	var hp_multiplier := civ.building_hp_mul if civ != null else 1.0
	return float(_age_attributes().get("hp",def.max_hp)) * hp_multiplier

func enqueue_train(unit_def: UnitDef) -> bool:
	# Resolve by catalog ID: old maps may hold a .tres instance of the same unit.
	unit_def = trainable_definition(unit_def.id) if unit_def != null else null
	if has_meta("network_replica") or not train_blocked_reason(unit_def).is_empty():
		return false
	if not match_state.spend(
		team, unit_def.cost_food, unit_def.cost_wood, unit_def.cost_gold, unit_def.cost_stone
	):
		return false
	train_queue.append(unit_def)
	train_queue_ids.append(_next_train_id)
	# Research at another building may upgrade queued definitions. Refund the
	# amount actually paid, not the replacement unit's current catalog cost.
	_train_payments[_next_train_id] = {"cost": [unit_def.cost_food, unit_def.cost_wood, unit_def.cost_gold, unit_def.cost_stone], "population": unit_def.population}
	_next_train_id += 1
	_reserved_population += unit_def.population
	match_state.reserve_pop(team, unit_def.population)
	if train_queue.size() == 1:
		train_progress = 0.0
		_spawn_retry_remaining = 0.0
		_production_exit_blocked = false
	set_physics_process(true)
	train_queue_changed.emit()
	return true

func train_blocked_reason(unit_def: UnitDef) -> String:
	if match_state == null or match_state.frozen or hp <= 0.0 or is_queued_for_deletion() or is_placement_ghost:
		return "无法生产"
	if not is_complete:
		return "建筑尚未完成"
	if is_age_researching() or is_technology_researching():
		return "正在升级或研究"
	if train_queue.size() >= MAX_TRAIN_QUEUE:
		return "生产队列已满（%d/%d）" % [train_queue.size(), MAX_TRAIN_QUEUE]
	var definition := trainable_definition(unit_def.id) if unit_def != null else null
	if definition == null:
		return "此单位尚未解锁或无法在此建筑生产"
	if not match_state.can_afford(team, definition.cost_food, definition.cost_wood, definition.cost_gold, definition.cost_stone):
		return "资源不足"
	return ""

func is_training_population_blocked() -> bool:
	return match_state != null and not train_queue.is_empty() \
		and int(match_state.population[team]) + train_queue[0].population > int(match_state.population_cap[team])

func training_progress_ratio() -> float:
	return 0.0 if train_queue.is_empty() else clampf(train_progress / maxf(_train_time(train_queue[0]), 0.001), 0.0, 1.0)

## Queue admission is distinct from active production and from a usable exit.
## Observers and event sampling use this without repeating expensive spawn searches.
func production_status() -> Dictionary:
	var status := "idle"
	if not is_complete: status = "constructing"
	elif is_age_researching() or is_technology_researching(): status = "researching"
	elif not train_queue.is_empty():
		status = "population_blocked" if is_training_population_blocked() else "exit_blocked" if _production_exit_blocked else "training"
	return {"state": status, "queue_ids": train_queue_ids.duplicate(),
		"active_queue_id": train_queue_ids[0] if not train_queue_ids.is_empty() else null,
		"progress": training_progress_ratio(), "elapsed": train_progress,
		"duration": _train_time(train_queue[0]) if not train_queue.is_empty() else 0.0}

func cancel_train(queue_id: int) -> bool:
	# Stable IDs prevent a delayed network cancellation from removing the next unit.
	var index := train_queue_ids.find(queue_id)
	if index < 0 or match_state == null or match_state.frozen or hp <= 0.0 or has_meta("network_replica"):
		return false
	var payment: Dictionary = _train_payments[queue_id]
	_train_payments.erase(queue_id)
	train_queue.remove_at(index)
	train_queue_ids.remove_at(index)
	if index == 0:
		train_progress = 0.0
		_spawn_retry_remaining = 0.0
		_production_exit_blocked = false
	_reserved_population -= int(payment.population)
	match_state.reserve_pop(team, -int(payment.population))
	for type in 4:
		match_state.add_resource(team, type as Enums.ResourceType, int(payment.cost[type]))
	set_physics_process(not train_queue.is_empty())
	train_queue_changed.emit()
	return true

func trainable_definition(unit_id: StringName) -> UnitDef:
	for candidate in get_trainable_units():
		if candidate.id == unit_id:
			return candidate
	return null

func apply_definition_upgrade(upgraded: BuildingDef) -> void:
	if upgraded == null or def == null: return
	var ratio := hp / maxf(_max_hp(), 1.0)
	def = upgraded
	hp = _max_hp() * ratio
	var attributes := _age_attributes()
	melee_armor = int(attributes.get("melee_armor", def.melee_armor))
	pierce_armor = int(attributes.get("pierce_armor", def.pierce_armor))
	_configure_visuals()

func get_trainable_units() -> Array[UnitDef]:
	var result: Array[UnitDef] = []
	if def == null:
		return result
	if match_state != null and match_state.progression_enabled:
		var candidates: Array[UnitDef] = []
		candidates.assign(match_state.unit_catalog if not match_state.unit_catalog.is_empty() else def.trainable)
		if match_state.unit_catalog.is_empty() and civ != null and civ.unique_unit != null and def.id == &"castle":
			candidates.append(civ.unique_unit)
		var civilization_id: StringName = civ.id if civ != null else &""
		for candidate in candidates:
			if candidate.train_at != def.id:
				continue
			if not match_state.unit_unlocked(team, candidate, civilization_id):
				continue
			if civ != null and candidate == civ.unique_unit and def.id != &"castle":
				continue
			result.append(candidate)
		var replaced: Array[StringName] = []
		for candidate in result:
			if candidate.upgrades_from != &"":
				replaced.append(candidate.upgrades_from)
		for index in range(result.size() - 1, -1, -1):
			if result[index].id in replaced:
				result.remove_at(index)
		return result
	result.assign(def.trainable)
	if (
		civ != null
		and civ.id == &"chinese"
		and def.id == &"archery_range"
		and civ.unique_unit != null
		and civ.unique_unit not in result
	):
		result.append(civ.unique_unit)
	return result


func is_age_researching() -> bool:
	return match_state != null and is_instance_valid(match_state.age_progression) \
		and match_state.age_progression.is_building_researching(self)


func start_age_upgrade() -> bool:
	return match_state != null and is_instance_valid(match_state.age_progression) \
		and match_state.age_progression.start_advance(self)


func cancel_age_upgrade() -> bool:
	return is_age_researching() and match_state.age_progression.cancel_advance(team)


func is_technology_researching() -> bool:
	return match_state != null and is_instance_valid(match_state.technology_progression) \
		and match_state.technology_progression.is_researching(self)


func start_technology(technology_id: StringName) -> bool:
	return match_state != null and is_instance_valid(match_state.technology_progression) \
		and match_state.technology_progression.start_research(self, technology_id)


func cancel_technology() -> bool:
	return is_technology_researching() and match_state.technology_progression.cancel_research(self)

func set_selected(selected: bool) -> void:
	_ensure_selection_footprint()
	var selection_ring := get_node_or_null("SelectionRing") as CanvasItem
	if selection_ring != null:
		selection_ring.visible = selected


func _ensure_selection_footprint() -> void:
	if def == null:
		return
	var ring := get_node_or_null("SelectionRing")
	if ring is Line2D:
		return
	SpriteCatalogScript.configure_selection_footprint(self, def.footprint * 0.5)

func set_ghost_visual(valid: bool) -> void:
	if _ghost_visual_valid == valid:
		return
	_ghost_visual_valid = valid
	_apply_ghost_tint(valid)

func _apply_ghost_tint(valid: bool) -> void:
	var tint := Color(0.2, 0.9, 0.35, 0.55) if valid else Color(0.95, 0.2, 0.2, 0.55)
	var billboard := get_node_or_null("Billboard") as CanvasItem
	if _use_billboard and billboard != null:
		billboard.modulate = tint
		var shadow := get_node_or_null("GroundShadow") as Sprite2D
		if shadow != null:
			shadow.modulate = tint
		return
	var body := get_node_or_null("Body") as CanvasItem
	if body == null:
		return
	body.modulate = tint

func clear_ghost_visual() -> void:
	if match_state != null and match_state.fog != null:
		match_state.fog.dirty = true
	if not _construction_started:
		start_construction()
	is_placement_ghost = false
	_ghost_visual_valid = null
	_register_groups()
	_configure_visuals()

func _complete_construction() -> void:
	if is_placement_ghost:
		return
	if match_state != null and match_state.fog != null:
		match_state.fog.dirty = true
	if is_complete and _population_cap_registered:
		return
	var was_incomplete := not is_complete
	is_complete = true
	if def != null and def.id == &"farm": add_to_group("resource_nodes")
	if (
		not _population_cap_registered
		and not has_meta("network_replica")
		and match_state != null
		and def != null
		and def.population_provided != 0
	):
		match_state.register_pop(team, 0, def.population_provided)
		_population_cap_registered = true
	if was_incomplete:
		var building_id := EntityRegistryScript.id_of(self)
		if building_id >= 0:
			AiEventBufferScript.push_for_entity({
				"type": AiProtocolScript.EVENT_BUILDING_COMPLETED,
				"entity_id": building_id,
			}, self)
	construction_completed.emit(self)

func _train_time(unit_def: UnitDef) -> float:
	if unit_def.id == &"villager" and civ != null:
		return unit_def.train_time * civ.villager_train_time_mul
	return unit_def.train_time

func _spawn_trained_unit(unit_def: UnitDef) -> bool:
	var parent := get_parent() as Node2D
	if parent == null:
		return false
	var spawn_position: Variant = _training_spawn_position(unit_def, parent)
	if spawn_position == null:
		return false
	var unit_view := load("res://scenes/entities/unit_view.tscn") as PackedScene
	if unit_view == null:
		return false
	var unit := unit_view.instantiate() as Node2D
	unit.set("team", team)
	unit.set("def", unit_def)
	unit.set("civ", civ)
	unit.set("match_state", match_state)
	var reserved: int = _train_payments[train_queue_ids[0]].population
	match_state.reserve_pop(team, -reserved)
	_reserved_population -= reserved
	unit.call("register_population")
	unit.set("sim_pos", spawn_position)
	var queue_id: int = train_queue_ids[0]
	var lineage: Dictionary = get_meta("ai_queue_lineage", {}).get(queue_id, {}).duplicate(true)
	unit.set_meta("ai_production_lineage", {"building_id": EntityRegistryScript.id_of(self), "queue_id": queue_id, "lineage": lineage})
	parent.add_child(unit)
	AiEventBufferScript.push({"type": "train_completed", "team": int(team), "_visible_to": [int(team)],
		"building_id": EntityRegistryScript.id_of(self), "queue_id": queue_id,
		"created_entity_id": EntityRegistryScript.id_of(unit), "unit_def_id": String(unit_def.id), "lineage": lineage})
	return true

func _training_spawn_position(unit_def: UnitDef, parent: Node2D) -> Variant:
	var radius := unit_def.resolved_footprint_radius()
	var half := def.footprint * 0.5 if def != null else Vector2.ONE
	half = half.max(CollisionResolverScript._blocker_half(self, 0.0))
	var clearance := maxf(0.8, radius + 0.2)
	var holder: Node
	if is_inside_tree():
		for candidate in get_tree().get_nodes_in_group("nav_service"):
			if candidate.get_parent() != null and (candidate.get_parent() == parent or candidate.get_parent().is_ancestor_of(parent)):
				holder = candidate
				break
	var solids: Array = []
	if holder != null and holder.has_method("query_static_blockers"):
		# Only the production building's neighborhood, at completion / retry.
		solids = holder.query_static_blockers(sim_pos, sim_pos, half.length() + clearance + 2.0 + radius)
	else:
		for child in parent.get_children():
			if child.get("def") is BuildingDef or child.get("block_size") is Vector2 or child.has_method("extract"):
				solids.append(child)
	solids.erase(self)
	var units: Array = []
	if is_inside_tree():
		for other in get_tree().get_nodes_in_group("units"):
			if other.get_parent() == parent and not other.is_queued_for_deletion() and float(other.get("hp")) > 0.0:
				units.append(other)
	else:
		for other in parent.get_children():
			if other.get("def") is UnitDef and float(other.get("hp")) > 0.0: units.append(other)
	var offsets: Array[Vector2] = [Vector2(half.x + 0.8, 0)]
	for ring in 3:
		var edge := half + Vector2.ONE * (clearance + ring)
		for fraction in [0.0, 0.5, -0.5, 1.0, -1.0]:
			offsets.append_array([Vector2(edge.x, edge.y * fraction), Vector2(edge.x * fraction, edge.y),
				Vector2(-edge.x, edge.y * fraction), Vector2(edge.x * fraction, -edge.y)])
	for offset in offsets:
		var position := sim_pos + offset
		if match_state != null and match_state.map_bounds.has_area() and not match_state.map_bounds.encloses(Rect2(position - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)):
			continue
		if not CollisionResolverScript.clamp_to_map(position, radius).is_equal_approx(position): continue
		if CollisionResolverScript._hits_building(position, radius, self): continue
		if holder != null and holder.get("nav") != null and not holder.nav.is_world_walkable_with_radius(position, radius): continue
		# Check the whole exit segment so a farther empty point cannot jump a
		# water strip, cliff or wall into another disconnected land pocket.
		if not CollisionResolverScript.static_step_safe(sim_pos, position, radius, solids): continue
		var occupied := false
		for other in units:
			var separation := radius + CollisionResolverScript.unit_radius(other)
			if position.distance_squared_to(other.get("sim_pos")) < separation * separation:
				occupied = true
				break
		if not occupied: return position
	return null

func _configure_visuals() -> void:
	_use_billboard = false
	_sprite_sheet_base = ""
	var body := get_node_or_null("Body") as CanvasItem
	var billboard := get_node_or_null("Billboard") as Sprite2D
	var civ_id: StringName = civ.id if civ != null else &""
	var base := ""
	var meta := {}
	var foundation := _uses_foundation_visual()
	var ground_farm := def != null and def.id == &"farm"
	if def != null:
		var age := match_state.age_of(team) if match_state != null and match_state.progression_enabled else -1
		base = SpriteCatalogScript.foundation_sheet_base(def.id, civ_id, age, def.footprint) if foundation else SpriteCatalogScript.building_sheet_base(def.id, civ_id, age)
	if billboard != null and SpriteCatalogScript.sheet_paths_exist(base):
		meta = SpriteCatalogScript.load_meta(base)
		var texture := SpriteCatalogScript.load_texture(base)
		if not meta.is_empty() and texture != null:
			_sprite_sheet_base = base
			billboard.texture = SpriteCatalogScript.first_atlas_texture(meta, texture)
			var hotspot := SpriteCatalogScript.average_hotspot(meta)
			var offset := SpriteCatalogScript.offset_for_hotspot_2d(meta, hotspot)
			var pixel_scale := SpriteCatalogScript.building_pixel_scale(def, meta)
			SpriteCatalogScript.configure_sprite_2d(billboard, pixel_scale, offset)
			if ground_farm:
				billboard.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
			billboard.modulate = Color.WHITE
			billboard.visible = true
			_use_billboard = true
	if body != null:
		body.visible = not _use_billboard
		var footprint := def.footprint if def != null else Vector2.ONE
		body.scale = Vector2(
			maxi(int(footprint.x * 8.0), 12),
			maxi(int(footprint.y * 6.0), 10)
		)
	if billboard != null and not _use_billboard:
		billboard.visible = false
	if def != null:
		SpriteCatalogScript.configure_selection_footprint(self, def.footprint * 0.5)
		if ground_farm:
			# Soil uses the original art scale, like the other building atlases.
			# Follow its displayed boundary instead of shrinking it to sim tiles.
			var bounds := billboard.transform * billboard.get_rect() if _use_billboard else Rect2(-66, -33, 132, 66)
			var center := bounds.get_center()
			var points := PackedVector2Array([Vector2(center.x, bounds.position.y),
				Vector2(bounds.end.x, center.y), Vector2(center.x, bounds.end.y), Vector2(bounds.position.x, center.y)])
			SpriteCatalogScript._apply_selection_line(get_node("SelectionRing") as Line2D, points)
	var has_sprite_shadow := bool(meta.get("includes_shadow", false))
	var layered_town_center := def != null and def.id == &"town_center" and not foundation
	if billboard != null:
		billboard.z_index = FARM_GROUND_Z if ground_farm else (-1 if foundation else (TOWN_CENTER_SOLID_Z if layered_town_center else 0))
	if body != null:
		body.z_index = FARM_GROUND_Z if ground_farm else (TOWN_CENTER_SOLID_Z if layered_town_center else 0)
	var ground_shadow := get_node_or_null("GroundShadow") as CanvasItem
	if foundation or ground_farm:
		if ground_shadow != null:
			ground_shadow.visible = false
	elif layered_town_center and has_sprite_shadow and _use_billboard:
		_configure_sprite_shadow(billboard)
	elif has_sprite_shadow:
		if ground_shadow != null:
			ground_shadow.visible = false
	else:
		var shadow_radius := 18.0
		if def != null:
			shadow_radius = maxf(def.footprint.x, def.footprint.y) * IsoMathScript.SCALE_X * 0.4
		SpriteCatalogScript.ensure_ground_shadow_2d(self, shadow_radius)
		if layered_town_center:
			(get_node("GroundShadow") as CanvasItem).z_index = TOWN_CENTER_SHADOW_Z
	_apply_team_color()


func _uses_foundation_visual() -> bool:
	if def != null and def.id == &"farm":
		# Preview, construction and an unworked completed field are bare soil.
		# Only an actual food extraction plants the visible crops.
		return is_placement_ghost or not is_complete or not farm_has_crops
	return not is_placement_ghost and not is_complete

func _configure_sprite_shadow(billboard: Sprite2D) -> void:
	var shadow := get_node_or_null("GroundShadow") as Sprite2D
	if shadow == null:
		var previous := get_node_or_null("GroundShadow")
		if previous != null:
			remove_child(previous)
			previous.free()
		shadow = Sprite2D.new()
		shadow.name = "GroundShadow"
		add_child(shadow)
	shadow.texture = billboard.texture
	shadow.transform = billboard.transform
	shadow.centered = billboard.centered
	shadow.offset = billboard.offset
	shadow.texture_filter = billboard.texture_filter
	shadow.z_index = TOWN_CENTER_SHADOW_Z
	shadow.visible = true

func _sync_block_half() -> void:
	if def == null:
		block_half = Vector2.ONE
		return
	var civ_id: StringName = civ.id if civ != null else &""
	var footprint := SpriteCatalogScript.pathfinding_footprint_for_building(def, civ_id)
	block_half = footprint * 0.5

func _apply_team_color() -> void:
	var color_id := TeamColorCatalogScript.resolve_color_id(team, match_state)
	var body := get_node_or_null("Body") as CanvasItem
	var billboard := get_node_or_null("Billboard") as Sprite2D
	if not _sprite_sheet_base.is_empty() and billboard != null:
		var layer := SpriteCatalogScript.SpriteLayer.SOLID if def != null and def.id == &"town_center" and not _uses_foundation_visual() else SpriteCatalogScript.SpriteLayer.ALL
		_use_billboard = SpriteCatalogScript.apply_player_color(billboard, _sprite_sheet_base, color_id, layer)
		billboard.modulate = Color.WHITE
		billboard.visible = _use_billboard
	var shadow := get_node_or_null("GroundShadow") as Sprite2D
	if shadow != null:
		var separate_shadow := def != null and def.id == &"town_center" and not _uses_foundation_visual() and bool(SpriteCatalogScript.load_meta(_sprite_sheet_base).get("includes_shadow", false))
		shadow.visible = separate_shadow and _use_billboard and SpriteCatalogScript.apply_player_color(shadow, _sprite_sheet_base, color_id, SpriteCatalogScript.SpriteLayer.SHADOW)
		shadow.modulate = Color.WHITE
	if body != null:
		body.visible = not _use_billboard
		body.modulate = TeamColorCatalogScript.fallback_color(color_id)
	if _ghost_visual_valid != null:
		_apply_ghost_tint(bool(_ghost_visual_valid))

func refresh_team_color() -> void:
	_apply_team_color()

func _on_team_color_changed(changed_team: int) -> void:
	if changed_team == team:
		refresh_team_color()

func _sync_visual() -> void:
	IsoMathScript.sync_node(self, sim_pos)

func _register_groups() -> void:
	add_to_group("buildings")
	if def != null and def.id == &"farm" and is_complete: add_to_group("resource_nodes")
	if accepts_all_resources or (def != null and def.has_drop_off):
		add_to_group("drop_off_buildings")
	_vision_register()
	UnitOcclusionScript.notify_static_entity(self)

func _exit_tree() -> void:
	cancel_age_upgrade()
	cancel_technology()
	EntityRegistryScript.unregister(self, "removed")
	_vision_unregister()
	if _reserved_population != 0 and match_state != null:
		match_state.reserve_pop(team, -_reserved_population)
		_reserved_population = 0
	if (
		_population_cap_registered
		and match_state != null
		and def != null
		and def.population_provided != 0
	):
		match_state.register_pop(team, 0, -def.population_provided)
		_population_cap_registered = false


func resolved_vision_radius() -> float:
	if def == null:
		return 0.0
	if not is_complete:
		return def.construction_vision_radius
	var age := match_state.age_of(team) if match_state != null and match_state.progression_enabled else Enums.Age.DARK
	return def.resolved_vision_radius(age)


func _get_vision_service() -> Object:
	if not is_inside_tree():
		return null
	var holders := get_tree().get_nodes_in_group("vision_service")
	if holders.is_empty():
		return null
	var holder := holders[0]
	if holder.has_meta("vision"):
		return holder.get_meta("vision")
	return null


func _vision_register() -> void:
	var vision := _get_vision_service()
	if vision != null and vision.has_method("register"):
		vision.call("register", self)


func _vision_unregister() -> void:
	var vision := _get_vision_service()
	if vision != null and vision.has_method("unregister"):
		vision.call("unregister", self)

func _on_age_changed(changed_team: int, age: int) -> void:
	if team == changed_team:
		var old_max := float(_age_attributes(_visual_age).get("hp",def.max_hp)) * (civ.building_hp_mul if civ != null else 1.0)
		if not has_meta("network_replica"): hp = hp / maxf(old_max,1) * _max_hp()
		_visual_age = age
		var attributes := _age_attributes()
		melee_armor = float(attributes.get("melee_armor",def.melee_armor))
		pierce_armor = float(attributes.get("pierce_armor",def.pierce_armor))
		_configure_visuals()

func _age_attributes(age := -1) -> Dictionary:
	if match_state == null or not match_state.progression_enabled or def == null: return {}
	var era := match_state.age_of(team) if age < 0 else age
	var record: Dictionary = GameCatalog.building_record(def.id)
	return record.get("age_variants",{}).get(["dark","feudal","castle","imperial"][era],{})
