class_name BuildingAgent
extends Node2D

signal construction_completed(building: BuildingAgent)
signal construction_started(building: BuildingAgent)
signal train_queue_changed
signal destroyed(building: BuildingAgent)

const PLAYER_COLOR := Color(0.18, 0.42, 0.95)
const AI_COLOR := Color(0.88, 0.18, 0.14)
const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")

@export var team: Enums.Team = Enums.Team.PLAYER
@export var def: BuildingDef
@export var civ: CivDef
@export var accepts_all_resources := false
@export var accepted_resource_type: Enums.ResourceType = Enums.ResourceType.FOOD
var match_state: MatchState
var sim_pos := Vector2.ZERO
var hp := 0.0
var melee_armor := 0.0
var pierce_armor := 0.0
var build_progress := 0.0
var is_complete := true
var is_placement_ghost := false
var train_queue: Array[UnitDef] = []
var train_progress := 0.0
var _construction_started := false
var _population_cap_registered := false
var _reserved_population := 0
var _ghost_visual_valid: Variant = null
var _use_billboard := false
var block_half := Vector2.ONE

func _ready() -> void:
	if sim_pos == Vector2.ZERO:
		sim_pos = position
	_sync_visual()
	if not is_placement_ghost:
		_register_groups()
	if def != null:
		accepted_resource_type = def.drop_off
		melee_armor = float(def.melee_armor)
		pierce_armor = float(def.pierce_armor)
		_configure_visuals()
		_sync_block_half()
		if _construction_started and def.build_time > 0.0:
			is_complete = false
			hp = maxf(1.0, _max_hp() * build_progress / def.build_time)
		else:
			build_progress = def.build_time
			hp = _max_hp()
			_complete_construction()
	set_physics_process(not train_queue.is_empty())
	set_selected(false)

func _physics_process(delta: float) -> void:
	if match_state != null and match_state.frozen:
		return
	if not is_complete or train_queue.is_empty():
		return
	train_progress += delta
	var unit_def := train_queue[0]
	if train_progress >= _train_time(unit_def):
		if _spawn_trained_unit(unit_def):
			train_queue.clear()
			train_progress = 0.0
			set_physics_process(false)
			train_queue_changed.emit()

func accepts_resource(resource_type: Enums.ResourceType) -> bool:
	return accepts_all_resources or accepted_resource_type == resource_type

func start_construction() -> void:
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
	return float(def.max_hp) * hp_multiplier

func enqueue_train(unit_def: UnitDef) -> bool:
	if (
		not is_complete
		or unit_def == null
		or not train_queue.is_empty()
		or unit_def not in get_trainable_units()
		or match_state == null
		or not match_state.can_train(team, unit_def)
	):
		return false
	if not match_state.spend(
		team, unit_def.cost_food, unit_def.cost_wood, unit_def.cost_gold
	):
		return false
	train_queue.append(unit_def)
	_reserved_population = unit_def.population
	match_state.reserve_pop(team, _reserved_population)
	train_progress = 0.0
	set_physics_process(true)
	train_queue_changed.emit()
	return true

func get_trainable_units() -> Array[UnitDef]:
	var result: Array[UnitDef] = []
	if def == null:
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

func set_selected(selected: bool) -> void:
	var selection_ring := get_node_or_null("SelectionRing") as CanvasItem
	if selection_ring != null:
		selection_ring.visible = selected

func set_ghost_visual(valid: bool) -> void:
	if _ghost_visual_valid == valid:
		return
	_ghost_visual_valid = valid
	var tint := Color(0.2, 0.9, 0.35, 0.55) if valid else Color(0.95, 0.2, 0.2, 0.55)
	var billboard := get_node_or_null("Billboard") as CanvasItem
	if _use_billboard and billboard != null:
		billboard.modulate = tint
		return
	var body := get_node_or_null("Body") as CanvasItem
	if body == null:
		return
	body.modulate = tint

func clear_ghost_visual() -> void:
	is_placement_ghost = false
	_ghost_visual_valid = null
	_register_groups()
	_configure_visuals()

func _complete_construction() -> void:
	if is_complete and _population_cap_registered:
		return
	is_complete = true
	if (
		not _population_cap_registered
		and match_state != null
		and def != null
		and def.population_provided != 0
	):
		match_state.register_pop(team, 0, def.population_provided)
		_population_cap_registered = true
	construction_completed.emit(self)

func _train_time(unit_def: UnitDef) -> float:
	if unit_def.id == &"villager" and civ != null:
		return unit_def.train_time * civ.villager_train_time_mul
	return unit_def.train_time

func _spawn_trained_unit(unit_def: UnitDef) -> bool:
	var parent := get_parent() as Node2D
	if parent == null:
		return false
	var unit_view := load("res://scenes/entities/unit_view.tscn") as PackedScene
	if unit_view == null:
		return false
	var unit := unit_view.instantiate() as Node2D
	unit.set("team", team)
	unit.set("def", unit_def)
	unit.set("civ", civ)
	unit.set("match_state", match_state)
	match_state.reserve_pop(team, -_reserved_population)
	_reserved_population = 0
	unit.call("register_population")
	var spawn_offset := Vector2(
		(def.footprint.x * 0.5 if def != null else 1.0) + 0.8, 0.0
	)
	unit.set("sim_pos", sim_pos + spawn_offset)
	parent.add_child(unit)
	return true

func _configure_visuals() -> void:
	_use_billboard = false
	var body := get_node_or_null("Body") as CanvasItem
	var billboard := get_node_or_null("Billboard") as Sprite2D
	var civ_id: StringName = civ.id if civ != null else &""
	var base := SpriteCatalogScript.building_sheet_base(def.id, civ_id)
	if billboard != null and SpriteCatalogScript.sheet_paths_exist(base):
		var meta := SpriteCatalogScript.load_meta(base)
		var texture := SpriteCatalogScript.load_texture(base)
		if not meta.is_empty() and texture != null:
			billboard.texture = SpriteCatalogScript.first_atlas_texture(meta, texture)
			var hotspot := SpriteCatalogScript.average_hotspot(meta)
			var offset := SpriteCatalogScript.offset_for_hotspot_2d(meta, hotspot)
			var frame_w := float(meta.get("frame_w", 1))
			var target_width := maxf(def.footprint.x, def.footprint.y) * IsoMathScript.SCALE_X * 1.15
			var pixel_scale := SpriteCatalogScript.BUILDING_PIXEL_SCALE_2D
			if frame_w > 0.0:
				pixel_scale = clampf(target_width / frame_w, 1.2, 3.0)
			SpriteCatalogScript.configure_sprite_2d(billboard, pixel_scale, offset)
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
	var ring := get_node_or_null("SelectionRing") as Polygon2D
	if ring != null and def != null:
		var radius := maxf(def.footprint.x, def.footprint.y) * IsoMathScript.SCALE_X * 0.45
		ring.polygon = SpriteCatalogScript._ellipse_points(radius, radius * 0.5, 28)
	var shadow_radius := 18.0
	if def != null:
		shadow_radius = maxf(def.footprint.x, def.footprint.y) * IsoMathScript.SCALE_X * 0.4
	SpriteCatalogScript.ensure_ground_shadow_2d(self, shadow_radius)
	if not _use_billboard:
		_apply_team_color()

func _sync_block_half() -> void:
	if def == null:
		block_half = Vector2.ONE
		return
	var civ_id: StringName = civ.id if civ != null else &""
	var footprint := SpriteCatalogScript.pathfinding_footprint_for_building(def, civ_id)
	block_half = footprint * 0.5

func _apply_team_color() -> void:
	var body := get_node_or_null("Body") as CanvasItem
	if body == null:
		return
	body.modulate = PLAYER_COLOR if team == Enums.Team.PLAYER else AI_COLOR

func _sync_visual() -> void:
	IsoMathScript.sync_node(self, sim_pos)

func _register_groups() -> void:
	add_to_group("buildings")
	if accepts_all_resources or (def != null and def.has_drop_off):
		add_to_group("drop_off_buildings")

func _exit_tree() -> void:
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
