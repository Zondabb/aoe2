# scripts/match/match_bootstrap.gd
extends Node

const FogHolder := preload("res://scripts/systems/fog_of_war_holder.gd")

const Catalog := preload("res://scripts/data/game_catalog.gd")
const AgeService := preload("res://scripts/systems/age_progression.gd")
const TechnologyService := preload("res://scripts/systems/technology_progression.gd")

const CHINESE_CIV := preload("res://data/civs/chinese.tres")
const TEUTONS_CIV := preload("res://data/civs/teutons.tres")
const NavServiceHolderScript := preload("res://scripts/systems/nav_service_holder.gd")
const VisionServiceHolderScript := preload("res://scripts/systems/vision_service_holder.gd")
const NavDebugOverlayScript := preload("res://scripts/presentation/nav_debug_overlay.gd")
const AiGatewayScript := preload("res://scripts/ai_gateway/ai_gateway.gd")
const AiConfigScript := preload("res://scripts/ai_gateway/ai_config.gd")
const PlayerAiControlScript := preload("res://scripts/ai_gateway/player_ai_control.gd")
const MapLoaderScript := preload("res://scripts/world/map_loader.gd")
const MapDataScript := preload("res://scripts/world/map_data.gd")
const DefaultMap := preload("res://scripts/world/default_map_generator.gd")
const SaveGames := preload("res://scripts/core/save_game_service.gd")

var match_state := MatchState.new()
var player_civ: CivDef
var ai_civ: CivDef
var map_bounds := Rect2(Vector2.ONE * (-DefaultMap.DEFAULT_SIZE * 0.5), Vector2.ONE * DefaultMap.DEFAULT_SIZE)
var map_data: Dictionary = {}
var generated_default_map := false
var setup_ready := false
var _saved_data: Dictionary = {}

func _ready() -> void:
	if not GameSession.online_active:
		_saved_data = GameSession.pending_save_data.duplicate(true)
	GameSession.pending_save_data.clear()
	match_state.fog_enabled = true
	if match_state.resources.is_empty():
		match_state.setup_defaults()
	if GameSession.online_active:
		match_state.frozen = true
		get_parent().set_meta("online_match", true)
	get_parent().set_meta("local_team", GameSession.local_team())
	player_civ = _civ_for_id(GameSession.player_civ_id)
	ai_civ = _civ_for_id(GameSession.ai_civ_id)
	match_state.progression_enabled = true
	match_state.team_civilizations = {0:player_civ.id, 1:ai_civ.id}
	match_state.unit_catalog.assign(Catalog.units().values())
	map_data = GameSession.match_map_data.duplicate(true)
	generated_default_map = map_data.is_empty()
	if generated_default_map:
		map_data = DefaultMap.generate(DefaultMap.DEFAULT_SEED, player_civ.id, ai_civ.id)
	var errors := MapDataScript.validate(map_data)
	if not errors.is_empty():
		GameSession.menu_notice = "地图无法启动：" + "；".join(errors)
		get_tree().call_deferred("change_scene_to_file", "res://scenes/civ_select.tscn")
		return
	map_bounds = MapDataScript.bounds(map_data)
	match_state.map_bounds = map_bounds
	_setup_ground()
	_setup_nav()
	_setup_vision()
	_spawn_entities()
	call_deferred("_finish_setup")
	_focus_camera_on_player_base()
	_setup_building_controls()
	call_deferred("_setup_ai_gateway")

func _setup_nav() -> void:
	var holder := NavServiceHolderScript.new()
	holder.name = "NavService"
	holder.setup_rect(Vector2i(map_bounds.position), Vector2i(map_bounds.end))
	var match_root := get_parent()
	if match_root != null:
		# Must defer: Bootstrap._ready runs while Match is still adding children,
		# so immediate add_child(Match, ...) fails and NavService never enters the tree.
		match_root.call_deferred("add_child", holder)

func _setup_vision() -> void:
	var holder := VisionServiceHolderScript.new()
	holder.name = "VisionService"
	holder.setup(2.0)
	var match_root := get_parent()
	if match_root != null:
		match_root.call_deferred("add_child", holder)

func _finish_setup() -> void:
	var age := AgeService.new()
	age.name = "AgeProgression"
	get_parent().add_child(age)
	age.setup(match_state, get_node("../Entities"))
	var tech := TechnologyService.new()
	tech.name = "TechnologyProgression"
	get_parent().add_child(tech)
	tech.setup(match_state, get_node("../Entities"))
	var support: Node = load("res://scripts/systems/land_support.gd").new()
	support.name = "LandSupport"
	get_parent().add_child(support)
	support.setup(match_state, get_node("../Entities"))
	var nav_holder := get_tree().get_first_node_in_group("nav_service") as NavServiceHolderScript
	if nav_holder != null:
		nav_holder.rebuild_from_scene()
	var vision_holder := get_tree().get_first_node_in_group("vision_service") as VisionServiceHolderScript
	if vision_holder != null:
		vision_holder.rebuild_from_scene()
	_setup_debug_overlay()
	FogHolder.install_rect(get_parent(), match_state, map_bounds.position, map_bounds.end, GameSession.local_team())
	if not _saved_data.is_empty():
		var error := SaveGames.restore(self, _saved_data)
		if not error.is_empty():
			GameSession.menu_notice = "存档无法恢复：" + error
			get_tree().call_deferred("change_scene_to_file", "res://scenes/civ_select.tscn")
			return
	setup_ready = true
	var player_ai := PlayerAiControlScript.new()
	player_ai.name = "PlayerAiControl"
	get_parent().add_child(player_ai)
	player_ai.setup(self)
	if GameSession.online_active:
		var network := load("res://scripts/network/network_match.gd").new() as Node
		network.name = "NetworkMatch"
		get_parent().add_child(network)
		network.setup(self)

func _setup_debug_overlay() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	if get_tree().get_first_node_in_group("nav_debug_overlay") != null:
		return
	var nav_holder := get_tree().get_first_node_in_group("nav_service") as NavServiceHolderScript
	var vision_holder := get_tree().get_first_node_in_group("vision_service") as VisionServiceHolderScript
	var overlay := NavDebugOverlayScript.new()
	overlay.name = "NavDebugOverlay"
	if nav_holder != null:
		overlay.nav = nav_holder.nav
	if vision_holder != null:
		overlay.vision = vision_holder.vision
	match_root.add_child(overlay)
	var panel := match_root.get_node_or_null("UILayer/PathfindingDebugPanel")
	if panel != null:
		panel.call_deferred("_bind_overlay")

func _focus_camera_on_player_base() -> void:
	var camera := get_node_or_null("../Camera2D") as Camera2D
	var focus := DefaultMap.BASE_POSITION
	var focus_team := "player" if GameSession.local_team() == Enums.Team.PLAYER else "ai"
	if not map_data.is_empty():
		focus = map_bounds.get_center()
		for record in map_data.entities:
			if record.get("team") == focus_team:
				focus = MapDataScript.position_of(record)
				if record.get("building_id") == "town_center":
					break
	if camera != null:
		camera.call("set_map_bounds", map_bounds.position, map_bounds.end)
		camera.call("focus_on", focus)

func _setup_ground() -> void:
	var ground := get_node_or_null("../Map/Ground") as Node2D
	if ground == null:
		return
	MapLoaderScript.setup_ground(map_data, ground)

func _spawn_entities() -> void:
	if not _saved_data.is_empty():
		return
	if GameSession.online_active and GameSession.local_team() != Enums.Team.PLAYER:
		return
	var entities := get_node_or_null("../Entities") as Node2D
	if entities == null or entities.get_child_count() > 0:
		return
	MapLoaderScript.spawn_entities(map_data, entities, match_state, false, {Enums.Team.PLAYER: player_civ, Enums.Team.AI: ai_civ})
	if generated_default_map:
		for entity in entities.get_children():
			entity.name = entity.get_meta("map_id")

func _civ_for_id(civ_id: StringName) -> CivDef:
	return TEUTONS_CIV if civ_id == &"teutons" else CHINESE_CIV

func _setup_building_controls() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	var camera := match_root.get_node_or_null("Camera2D") as Camera2D
	var entities := match_root.get_node_or_null("Entities") as Node2D
	var selection := match_root.get_node_or_null("UILayer/SelectionController") as Control
	var build_system := match_root.get_node_or_null("BuildSystem") as Node
	var hud := match_root.get_node_or_null("UILayer/HUD") as Control
	if (
		camera == null
		or entities == null
		or selection == null
		or build_system == null
		or hud == null
	):
		return
	var local_civ := player_civ if GameSession.local_team() == Enums.Team.PLAYER else ai_civ
	build_system.call(
		"setup", camera, entities, selection, match_state, local_civ
	)
	hud.call("setup", match_state, local_civ, build_system, selection)

func _setup_ai_gateway() -> void:
	var match_root := get_parent()
	if match_root == null:
		return
	if GameSession.online_active:
		var local_ai := match_root.get_node_or_null("AiController")
		if local_ai != null:
			local_ai.stop()
			local_ai.queue_free()
		return
	var entities := match_root.get_node_or_null("Entities") as Node2D
	if entities == null:
		return
	if GameSession.match_ai_mode != "gateway":
		var local_ai := match_root.get_node_or_null("AiController")
		if local_ai != null:
			if GameSession.match_ai_mode == "local":
				local_ai.setup(match_state, entities, ai_civ, Enums.Team.AI, Enums.Team.PLAYER, "AI", null, false)
				local_ai.set_process(true)
			else:
				local_ai.stop()
		if not _saved_data.is_empty():
			SaveGames.restore_ai(match_root, _saved_data.ai)
			_saved_data.clear()
		return
	var existing := match_root.get_node_or_null("AiGateway")
	if existing != null:
		existing.queue_free()
	var ai := match_root.get_node_or_null("AiController")
	if ai != null:
		ai.queue_free()
	var gateway := AiGatewayScript.new()
	gateway.name = "AiGateway"
	match_root.add_child(gateway)
	var teams: Array = [
		{
			"team": Enums.Team.AI,
			"enemy_team": Enums.Team.PLAYER,
			"civ": ai_civ,
			"label": "AI",
		},
	]
	gateway.setup(match_state, entities, teams, AiConfigScript.from_game_session())
	if not _saved_data.is_empty():
		SaveGames.restore_ai(match_root, _saved_data.ai)
		_saved_data.clear()
