class_name BuildingAgent
extends Node3D

signal construction_completed(building: BuildingAgent)
signal train_queue_changed
signal destroyed(building: BuildingAgent)

const PLAYER_COLOR := Color(0.18, 0.42, 0.95)
const AI_COLOR := Color(0.88, 0.18, 0.14)
const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")

@export var team: Enums.Team = Enums.Team.PLAYER
@export var def: BuildingDef
@export var civ: CivDef
@export var accepts_all_resources := false
@export var accepted_resource_type: Enums.ResourceType = Enums.ResourceType.FOOD
var match_state: MatchState
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

func _ready() -> void:
	if not is_placement_ghost:
		_register_groups()
	if def != null:
		accepted_resource_type = def.drop_off
		_configure_visuals()
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

func add_build_progress(amount: float) -> void:
	if is_complete or def == null or amount <= 0.0:
		return
	build_progress = minf(build_progress + amount, def.build_time)
	hp = maxf(1.0, _max_hp() * build_progress / maxf(def.build_time, 0.001))
	if build_progress >= def.build_time:
		hp = _max_hp()
		_complete_construction()

func take_damage(amount: float) -> void:
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
	var selection_ring := get_node_or_null("SelectionRing") as MeshInstance3D
	if selection_ring != null:
		selection_ring.visible = selected

func set_ghost_visual(valid: bool) -> void:
	if _ghost_visual_valid == valid:
		return
	_ghost_visual_valid = valid
	var tint := Color(0.2, 0.9, 0.35, 0.55) if valid else Color(0.95, 0.2, 0.2, 0.55)
	var billboard := get_node_or_null("Billboard") as Sprite3D
	if _use_billboard and billboard != null:
		billboard.modulate = tint
		return
	var body := get_node_or_null("Body") as MeshInstance3D
	if body == null:
		return
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	body.material_override = material

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
	var parent := get_parent_node_3d()
	if parent == null:
		return false
	var unit_view := load("res://scenes/entities/unit_view.tscn") as PackedScene
	if unit_view == null:
		return false
	var unit := unit_view.instantiate() as Node3D
	unit.set("team", team)
	unit.set("def", unit_def)
	unit.set("civ", civ)
	unit.set("match_state", match_state)
	match_state.reserve_pop(team, -_reserved_population)
	_reserved_population = 0
	unit.call("register_population")
	unit.position = position + Vector3(
		(def.footprint.x * 0.5 if def != null else 1.0) + 0.8, 0.0, 0.0
	)
	parent.add_child(unit)
	return true

func _configure_visuals() -> void:
	_use_billboard = false
	var body := get_node_or_null("Body") as MeshInstance3D
	var billboard := get_node_or_null("Billboard") as Sprite3D
	var civ_id: StringName = civ.id if civ != null else &""
	var base := SpriteCatalogScript.building_sheet_base(def.id, civ_id)
	if billboard != null and SpriteCatalogScript.sheet_paths_exist(base):
		var meta := SpriteCatalogScript.load_meta(base)
		var texture := SpriteCatalogScript.load_texture(base)
		if not meta.is_empty() and texture != null:
			billboard.texture = SpriteCatalogScript.first_atlas_texture(meta, texture)
			var hotspot := SpriteCatalogScript.average_hotspot(meta)
			var offset := SpriteCatalogScript.offset_for_hotspot(meta, hotspot)
			var pixel_size := SpriteCatalogScript.BUILDING_PIXEL_SIZE
			var frame_w := float(meta.get("frame_w", 1))
			var target_width := maxf(def.footprint.x, def.footprint.y) * 1.15
			if frame_w > 0.0:
				pixel_size = clampf(target_width / frame_w, 0.018, 0.05)
			SpriteCatalogScript.configure_billboard_sprite(billboard, pixel_size, offset)
			billboard.modulate = Color.WHITE
			billboard.visible = true
			_use_billboard = true
	if body != null and body.mesh is BoxMesh:
		var box := (body.mesh as BoxMesh).duplicate() as BoxMesh
		box.size = Vector3(def.footprint.x, 2.2, def.footprint.y)
		body.mesh = box
		body.position.y = box.size.y * 0.5
		body.visible = not _use_billboard
	if billboard != null and not _use_billboard:
		billboard.visible = false
	var ring := get_node_or_null("SelectionRing") as MeshInstance3D
	if ring != null and ring.mesh is CylinderMesh:
		var cylinder := (ring.mesh as CylinderMesh).duplicate() as CylinderMesh
		cylinder.top_radius = maxf(def.footprint.x, def.footprint.y) * 0.62
		cylinder.bottom_radius = cylinder.top_radius
		ring.mesh = cylinder
	if not _use_billboard:
		_apply_team_color()

func _apply_team_color() -> void:
	var body := get_node_or_null("Body") as MeshInstance3D
	if body == null:
		return
	var material := StandardMaterial3D.new()
	material.albedo_color = PLAYER_COLOR if team == Enums.Team.PLAYER else AI_COLOR
	material.roughness = 0.85
	body.material_override = material

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
