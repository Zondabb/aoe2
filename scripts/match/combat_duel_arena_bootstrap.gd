extends Node

## F6 combat playground: fixed lanes for melee clash, projectile kite/miss,
## and building siege. R resets. AI auto-attacks player units.

const GROUND_COLOR := Color(0.20, 0.48, 0.16)
const TERRAIN_TEXTURE := "res://assets/terrain/grass.png"
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")
const CHINESE_CIV := preload("res://data/civs/chinese.tres")
const TEUTONS_CIV := preload("res://data/civs/teutons.tres")
const SWORDSMAN_DEF := preload("res://data/units/swordsman.tres")
const ARCHER_DEF := preload("res://data/units/archer.tres")
const CHU_KO_NU_DEF := preload("res://data/units/chu_ko_nu.tres")
const TEUTONIC_KNIGHT_DEF := preload("res://data/units/teutonic_knight.tres")
const BARRACKS_DEF := preload("res://data/buildings/barracks.tres")
const IsoMathScript := preload("res://scripts/presentation/iso_math.gd")

const GROUND_MIN := -36
const GROUND_MAX := 36
const GROUND_STEP := 8
const AI_ATTACK_INTERVAL := 0.75

var match_state := MatchState.new()
var player_civ: CivDef = CHINESE_CIV
var ai_civ: CivDef = TEUTONS_CIV
var _ai_attack_timer := 0.0

func _ready() -> void:
	if match_state.resources.is_empty():
		match_state.setup_defaults()
	match_state.population_cap[Enums.Team.PLAYER] = 200
	match_state.population_cap[Enums.Team.AI] = 200
	GameSession.player_civ_id = player_civ.id
	GameSession.ai_civ_id = ai_civ.id
	_setup_ground()
	_spawn_scenarios()
	_focus_camera()
	_setup_hud()
	_setup_hint()

func _process(delta: float) -> void:
	if match_state.frozen:
		return
	_ai_attack_timer += delta
	if _ai_attack_timer < AI_ATTACK_INTERVAL:
		return
	_ai_attack_timer = 0.0
	_tick_ai_auto_attack()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		if key.keycode == KEY_R:
			_spawn_scenarios()

func _spawn_scenarios() -> void:
	_clear_entities()
	# Lane A — melee clash (south)
	_spawn_line(
		Enums.Team.PLAYER, SWORDSMAN_DEF, Vector2(-10.0, -12.0), Vector2(0.0, 1.4), 4, "MeleeP"
	)
	_spawn_line(
		Enums.Team.AI, SWORDSMAN_DEF, Vector2(10.0, -12.0), Vector2(0.0, 1.4), 4, "MeleeA"
	)
	# Lane B — ranged / kite (center): archers vs knights that can walk off aim points
	_spawn_line(
		Enums.Team.PLAYER, ARCHER_DEF, Vector2(-12.0, 0.0), Vector2(0.0, 1.5), 3, "ArcherP"
	)
	_spawn_unit(Enums.Team.PLAYER, CHU_KO_NU_DEF, Vector2(-12.0, 5.0), "ChuKoNuP")
	_spawn_line(
		Enums.Team.AI, TEUTONIC_KNIGHT_DEF, Vector2(10.0, 0.0), Vector2(0.0, 1.6), 3, "KnightA"
	)
	_spawn_unit(Enums.Team.AI, SWORDSMAN_DEF, Vector2(8.0, 5.0), "KiteBaitA")
	# Lane C — siege (north): mix vs barracks
	_spawn_line(
		Enums.Team.PLAYER, SWORDSMAN_DEF, Vector2(-10.0, 12.0), Vector2(0.0, 1.3), 3, "SiegeMeleeP"
	)
	_spawn_line(
		Enums.Team.PLAYER, ARCHER_DEF, Vector2(-14.0, 12.0), Vector2(0.0, 1.3), 2, "SiegeArcherP"
	)
	_spawn_building(Enums.Team.AI, BARRACKS_DEF, Vector2(10.0, 13.0), "AiBarracks")
	_spawn_line(
		Enums.Team.AI, SWORDSMAN_DEF, Vector2(8.0, 10.0), Vector2(1.4, 0.0), 2, "SiegeGuardA"
	)

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

func _clear_entities() -> void:
	var entities := get_node_or_null("../Entities") as Node2D
	if entities == null:
		return
	for child in entities.get_children():
		child.free()

func _spawn_line(
	team: Enums.Team,
	unit_def: UnitDef,
	origin: Vector2,
	step: Vector2,
	count: int,
	name_prefix: String
) -> void:
	for i in count:
		_spawn_unit(team, unit_def, origin + step * float(i), "%s_%d" % [name_prefix, i + 1])

func _spawn_unit(
	team: Enums.Team, unit_def: UnitDef, pos: Vector2, node_name: String
) -> void:
	var entities := get_node_or_null("../Entities") as Node2D
	if entities == null:
		return
	var unit := UNIT_VIEW.instantiate() as Node2D
	unit.name = node_name
	unit.set("team", team)
	unit.set("def", unit_def)
	unit.set("civ", player_civ if team == Enums.Team.PLAYER else ai_civ)
	unit.set("match_state", match_state)
	unit.set("sim_pos", pos)
	entities.add_child(unit)

func _spawn_building(
	team: Enums.Team, building_def: BuildingDef, pos: Vector2, node_name: String
) -> void:
	var entities := get_node_or_null("../Entities") as Node2D
	if entities == null:
		return
	var building := BUILDING_VIEW.instantiate() as Node2D
	building.name = node_name
	building.set("team", team)
	building.set("def", building_def)
	building.set("civ", player_civ if team == Enums.Team.PLAYER else ai_civ)
	building.set("match_state", match_state)
	building.set("sim_pos", pos)
	entities.add_child(building)

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

func _focus_camera() -> void:
	var camera := get_node_or_null("../Camera2D") as Camera2D
	if camera != null and camera.has_method("configure_for_map"):
		camera.call("configure_for_map", GROUND_MIN, GROUND_MAX, Vector2.ZERO)
	elif camera != null and camera.has_method("focus_on"):
		camera.call("focus_on", Vector2.ZERO)

func _setup_hud() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	var selection := match_root.get_node_or_null("UILayer/SelectionController") as Control
	var hud := match_root.get_node_or_null("UILayer/HUD") as Control
	if hud != null and hud.has_method("setup"):
		hud.call("setup", match_state, player_civ, null, selection)

func _setup_hint() -> void:
	var label := get_node_or_null("../UILayer/HintLabel") as Label
	if label == null:
		return
	label.text = (
		"对战测试场  |  南：近战  中：远程落点/kite  北：攻建筑  |  "
		+ "左键框选  右键攻击/移动  |  R 重置  |  AI 自动寻敌"
	)
