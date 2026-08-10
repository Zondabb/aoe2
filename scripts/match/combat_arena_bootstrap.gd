extends Node

const GROUND_COLOR := Color(0.20, 0.48, 0.16)
const TERRAIN_TEXTURE := "res://assets/terrain/grass.png"
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const CHINESE_CIV := preload("res://data/civs/chinese.tres")
const TEUTONS_CIV := preload("res://data/civs/teutons.tres")
const VILLAGER_DEF := preload("res://data/units/villager.tres")
const SWORDSMAN_DEF := preload("res://data/units/swordsman.tres")
const ARCHER_DEF := preload("res://data/units/archer.tres")
const CHU_KO_NU_DEF := preload("res://data/units/chu_ko_nu.tres")
const TEUTONIC_KNIGHT_DEF := preload("res://data/units/teutonic_knight.tres")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")
const SelectionController2DScript := preload("res://scripts/input/selection_controller_2d.gd")
const ArenaConfigScript := preload("res://scripts/data/arena_config.gd")
const GROUND_MIN := -40
const GROUND_MAX := 40
const GROUND_STEP := 8
const PLAYER_ORIGIN := Vector2(-18.0, 0.0)
const AI_ORIGIN := Vector2(18.0, 0.0)
const FORMATION_SPACING := 1.1

const UNIT_DEFS := {
	&"villager": VILLAGER_DEF,
	&"swordsman": SWORDSMAN_DEF,
	&"archer": ARCHER_DEF,
	&"chu_ko_nu": CHU_KO_NU_DEF,
	&"teutonic_knight": TEUTONIC_KNIGHT_DEF,
}

var match_state := MatchState.new()
var player_civ: CivDef
var ai_civ: CivDef
var _arena_config: ArenaConfigScript
var _ai_controller: Node
var _ai_auto_attack_enabled := false
var _ai_attack_timer := 0.0

func _ready() -> void:
	if match_state.resources.is_empty():
		match_state.setup_defaults()
	_raise_population_caps()
	_setup_ground()
	var setup_panel := get_node_or_null("../UILayer/ArenaSetupPanel") as Control
	if setup_panel != null and setup_panel.has_signal("battle_requested"):
		setup_panel.connect("battle_requested", _on_battle_requested)
		return
	_start_battle(_default_config())

func _default_config() -> ArenaConfigScript:
	var config := ArenaConfigScript.new()
	config.player_civ_id = GameSession.player_civ_id if GameSession.player_civ_id != &"" else &"chinese"
	config.ai_civ_id = (
		&"teutons" if config.player_civ_id == &"chinese" else &"chinese"
	)
	return config

func _process(delta: float) -> void:
	if not _ai_auto_attack_enabled or match_state.frozen:
		return
	_ai_attack_timer += delta
	if _ai_attack_timer < 0.75:
		return
	_ai_attack_timer = 0.0
	_tick_ai_auto_attack()

func _tick_ai_auto_attack() -> void:
	var entities := get_node_or_null("../Entities") as Node2D
	if entities == null:
		return
	var player_units: Array[Node2D] = []
	var ai_units: Array[Node2D] = []
	for child in entities.get_children():
		var unit := child as Node2D
		if unit == null or not unit.is_in_group("units"):
			continue
		if float(unit.get("hp")) <= 0.0:
			continue
		if unit.get("team") == Enums.Team.PLAYER:
			player_units.append(unit)
		elif unit.get("team") == Enums.Team.AI:
			ai_units.append(unit)
	if player_units.is_empty():
		return
	for ai_unit in ai_units:
		var target := _nearest_unit(ai_unit, player_units)
		if target != null and ai_unit.has_method("command_attack"):
			ai_unit.call("command_attack", target)

func _nearest_unit(from_unit: Node2D, candidates: Array[Node2D]) -> Node2D:
	var best: Node2D = null
	var best_dist := INF
	var from_pos: Vector2 = from_unit.get("sim_pos")
	for candidate in candidates:
		if not is_instance_valid(candidate):
			continue
		var dist := from_pos.distance_squared_to(candidate.get("sim_pos"))
		if dist < best_dist:
			best_dist = dist
			best = candidate
	return best

func _on_battle_requested(config: ArenaConfigScript) -> void:
	_show_reconfigure_button(true)
	_start_battle(config)

func _show_reconfigure_button(visible_state: bool) -> void:
	var button := get_node_or_null("../UILayer/ReconfigureButton") as Control
	if button != null:
		button.visible = visible_state

func _start_battle(config: ArenaConfigScript) -> void:
	_arena_config = config.duplicate_config()
	player_civ = _civ_for_id(_arena_config.player_civ_id)
	ai_civ = _civ_for_id(_arena_config.ai_civ_id)
	GameSession.player_civ_id = player_civ.id
	GameSession.ai_civ_id = ai_civ.id
	match_state.setup_defaults()
	match_state.frozen = false
	_raise_population_caps()
	_clear_entities()
	_spawn_army(Enums.Team.PLAYER, player_civ, PLAYER_ORIGIN, 1.0)
	_spawn_army(Enums.Team.AI, ai_civ, AI_ORIGIN, -1.0)
	_focus_camera_on_battlefield()
	_setup_player_controls()
	_setup_ai_auto_attack(_arena_config.ai_auto_attack)

func reopen_setup() -> void:
	_show_reconfigure_button(false)
	_ai_auto_attack_enabled = false
	if _ai_controller != null and _ai_controller.has_method("stop"):
		_ai_controller.call("stop")
	_clear_entities()
	if _ai_controller != null and _ai_controller.has_method("stop"):
		_ai_controller.call("stop")
	var setup_panel := get_node_or_null("../UILayer/ArenaSetupPanel") as Control
	if setup_panel != null:
		setup_panel.visible = true
		if setup_panel.has_method("restore_from_config") and _arena_config != null:
			setup_panel.call("restore_from_config", _arena_config)

func _raise_population_caps() -> void:
	for team in Enums.Team.values():
		match_state.population_cap[team] = 200

func _clear_entities() -> void:
	var entities := get_node_or_null("../Entities") as Node2D
	if entities == null:
		return
	for child in entities.get_children():
		child.free()

func _spawn_army(
	team: Enums.Team,
	civ: CivDef,
	origin: Vector2,
	facing: float
) -> void:
	var entities := get_node_or_null("../Entities") as Node2D
	if entities == null or _arena_config == null:
		return
	var spawn_entries: Array[Dictionary] = []
	for unit_id: StringName in UNIT_DEFS:
		var count := int(_arena_config.unit_counts.get(unit_id, 0))
		for _i in count:
			spawn_entries.append({"def": UNIT_DEFS[unit_id]})
	if spawn_entries.is_empty():
		return
	var total := spawn_entries.size()
	for index in total:
		var entry: Dictionary = spawn_entries[index]
		var unit_def: UnitDef = entry["def"]
		var slot := SelectionController2DScript.formation_offset(
			index, total, FORMATION_SPACING
		)
		var unit := UNIT_VIEW.instantiate() as Node2D
		unit.name = "%s_%s_%d" % [
			"Player" if team == Enums.Team.PLAYER else "Ai",
			unit_def.id,
			index + 1,
		]
		unit.set("team", team)
		unit.set("def", unit_def)
		unit.set("civ", civ)
		unit.set("match_state", match_state)
		unit.set("sim_pos", origin + slot * facing)
		entities.add_child(unit)

func _focus_camera_on_battlefield() -> void:
	var camera := get_node_or_null("../Camera2D") as Camera2D
	if camera != null and camera.has_method("focus_on"):
		camera.call("focus_on", Vector2.ZERO)

func _setup_ground() -> void:
	var ground := get_node_or_null("../Map/Ground") as Node2D
	if ground == null:
		return
	for child in ground.get_children():
		child.free()
	var texture: Texture2D = null
	if ResourceLoader.exists(TERRAIN_TEXTURE):
		texture = load(TERRAIN_TEXTURE) as Texture2D
	var lx := GROUND_MIN
	while lx <= GROUND_MAX:
		var lz := GROUND_MIN
		while lz <= GROUND_MAX:
			var tile := Sprite2D.new()
			tile.centered = true
			tile.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			tile.z_index = -100
			if texture != null:
				tile.texture = texture
				tile.scale = Vector2(0.35, 0.35)
			else:
				tile.modulate = GROUND_COLOR
			tile.position = IsoMathScript.world_to_screen(Vector2(float(lx), float(lz)))
			ground.add_child(tile)
			lz += GROUND_STEP
		lx += GROUND_STEP

func _setup_player_controls() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	var camera := match_root.get_node_or_null("Camera2D") as Camera2D
	var entities := match_root.get_node_or_null("Entities") as Node2D
	var selection := match_root.get_node_or_null("UILayer/SelectionController") as Control
	var build_system := match_root.get_node_or_null("BuildSystem") as Node
	var hud := match_root.get_node_or_null("UILayer/HUD") as Control
	if camera == null or entities == null or selection == null or hud == null:
		return
	if build_system != null:
		build_system.call("setup", camera, entities, selection, match_state, player_civ)
	hud.call("setup", match_state, player_civ, build_system, selection)

func _setup_ai_auto_attack(enabled: bool) -> void:
	_ai_auto_attack_enabled = enabled
	_ai_attack_timer = 0.0
	var match_root := get_parent()
	if match_root == null:
		return
	_ai_controller = match_root.get_node_or_null("AiController") as Node
	if _ai_controller != null:
		_ai_controller.set_process(false)
		if _ai_controller.has_method("stop"):
			_ai_controller.call("stop")

func _civ_for_id(civ_id: StringName) -> CivDef:
	return TEUTONS_CIV if civ_id == &"teutons" else CHINESE_CIV
