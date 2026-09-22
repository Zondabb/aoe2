extends RefCounted

const CATALOG := preload("res://scripts/presentation/sprite_catalog.gd")
const COLORS := preload("res://scripts/presentation/team_color_catalog.gd")
const UNIT_VIEW := preload("res://scenes/entities/unit_view.tscn")
const BUILDING_VIEW := preload("res://scenes/entities/building_view.tscn")


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_match_colors(failures)
	_test_asset_contract(failures)
	_test_material_sharing(failures)
	_test_unit_action_masks(failures)
	_test_buildings_and_ghosts(failures)
	_test_trained_unit_inherits_color(failures)
	return failures


func _test_match_colors(failures: Array[String]) -> void:
	var state := MatchState.new()
	state.setup_defaults()
	if state.get_team_color_id(Enums.Team.PLAYER) != 1 or state.get_team_color_id(Enums.Team.AI) != 2:
		failures.append("default player/AI colors should be AoE palette rows 1/2")
	if COLORS.resolve_color_id(Enums.Team.AI) != 2:
		failures.append("entities without match state should still resolve AI to red")
	for color_id in range(1, 9):
		if not state.set_team_color_id(Enums.Team.PLAYER, color_id):
			failures.append("match should accept all eight player colors")
		elif COLORS.resolve_color_id(Enums.Team.PLAYER, state) != color_id:
			failures.append("presentation should honor the match's player color")
	for invalid_id in [-1, 0, 9]:
		if state.set_team_color_id(Enums.Team.PLAYER, invalid_id):
			failures.append("invalid player color should be rejected")
		if state.get_team_color_id(Enums.Team.PLAYER) != 8:
			failures.append("rejected player color must preserve the previous valid selection")
	state.set_team_color_id(Enums.Team.AI, 5)
	state.setup_defaults()
	if state.get_team_color_id(Enums.Team.PLAYER) != 1 or state.get_team_color_id(Enums.Team.AI) != 2:
		failures.append("restarting match state should restore blue/red defaults")


func _test_asset_contract(failures: Array[String]) -> void:
	var bases: Dictionary = {}
	for base: String in CATALOG.UNIT_SHEETS.values():
		bases[base] = true
	for base: String in CATALOG.VILLAGER_ACTION_SHEETS.values():
		bases[base] = true
	for actions: Dictionary in CATALOG.UNIT_COMBAT_SHEETS.values():
		for base: String in actions.values():
			bases[base] = true
	for civilizations: Dictionary in CATALOG.BUILDING_SHEETS.values():
		for base: String in civilizations.values():
			bases[base] = true
	var indexed_count := 0
	for base: String in bases:
		var meta := CATALOG.load_meta(base)
		var color: Dictionary = meta.get("player_color", {})
		if color.get("mode", "") == "none":
			continue
		if color.get("mode", "") != "indexed":
			failures.append("playable unit/building sheet should declare player-color mode: " + base)
			continue
		indexed_count += 1
		if color.get("encoding", "") != "index_weight_rg8":
			failures.append("indexed sheet should explicitly declare index/weight encoding: " + base)
		if not CATALOG.player_color_is_valid(base):
			failures.append("indexed sheet should have a valid mask and palette: " + base)
			continue
		var material := CATALOG.player_color_material(base, 2)
		if material == null:
			failures.append("indexed sheet should produce a material: " + base)
			continue
		var mask := material.get_shader_parameter("player_mask") as Texture2D
		var texture := CATALOG.load_texture(base)
		if mask == null or texture == null or mask.get_size() != texture.get_size():
			failures.append("player mask must match the complete atlas size: " + base)
		var palette := material.get_shader_parameter("player_palette") as Texture2D
		if palette == null or palette.get_size() != Vector2(16, 8):
			failures.append("palette should contain 16 shades for each of 8 players")
	if indexed_count < 10:
		failures.append("indexed player colors should cover units, work actions and buildings")


func _test_material_sharing(failures: Array[String]) -> void:
	var base := CATALOG.unit_sheet_base(&"villager")
	var blue := CATALOG.player_color_material(base, 1)
	var red := CATALOG.player_color_material(base, 2)
	if blue == null or red == null:
		failures.append("villager should have blue and red player-color materials")
		return
	if blue != CATALOG.player_color_material(base, 1):
		failures.append("same sheet/color should reuse its immutable material")
	if red == blue:
		failures.append("opposing colors must not share a mutable ShaderMaterial")
	if blue.get_shader_parameter("player_mask") != red.get_shader_parameter("player_mask"):
		failures.append("opposing teams should reuse the same player-index mask")
	if blue.get_shader_parameter("player_palette") != red.get_shader_parameter("player_palette"):
		failures.append("opposing teams should reuse the same eight-row palette")
	for color_id in range(1, 9):
		var material := CATALOG.player_color_material(base, color_id)
		if material == null or int(material.get_shader_parameter("target_player")) != color_id:
			failures.append("material should bind its requested player-color row")
	if int(blue.get_shader_parameter("target_player")) != 1 or int(red.get_shader_parameter("target_player")) != 2:
		failures.append("creating other colors must not change existing blue/red materials")


func _test_unit_action_masks(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var holder := Node2D.new()
	tree.root.add_child(holder)
	var state := MatchState.new()
	state.setup_defaults()
	for unit_id in ["villager", "swordsman", "archer", "chu_ko_nu", "teutonic_knight"]:
		var unit := UNIT_VIEW.instantiate() as UnitAgent
		unit.def = load("res://data/units/%s.tres" % unit_id) as UnitDef
		unit.team = Enums.Team.AI
		unit.match_state = state
		holder.add_child(unit)
		unit._ready()
		var sprite := unit.get_node("Billboard") as AnimatedSprite2D
		var actions: Array[StringName] = [&"", &"attack", &"die"]
		if unit_id == "villager":
			actions = [&"walk", &"idle", &"gather_food", &"chop", &"mine", &"build", &"attack", &"die"]
		for action in actions:
			unit.set("_facing_dir", 2)
			unit.set("_facing_flip", true)
			unit.call("_apply_billboard_frame", true, action)
			if not sprite.visible or not bool(unit.get("_use_billboard")):
				failures.append("colored unit should keep its sprite for %s/%s" % [unit_id, action])
				continue
			var frame := sprite.sprite_frames.get_frame_texture(sprite.animation, sprite.frame) as AtlasTexture
			var material := sprite.material as ShaderMaterial
			if frame == null or material == null:
				failures.append("unit action should bind an atlas and player shader: %s/%s" % [unit_id, action])
				continue
			# Derive the expected mask from the displayed atlas, independently of action routing.
			var actual_base := frame.atlas.resource_path.get_basename()
			var mask := material.get_shader_parameter("player_mask") as Texture2D
			if mask == null or mask.resource_path != actual_base + "_player_mask.png":
				failures.append("action switched atlas without switching its player mask: %s/%s" % [unit_id, action])
			if int(material.get_shader_parameter("target_player")) != 2:
				failures.append("AI action should preserve its red palette row")
			if sprite.modulate != Color.WHITE:
				failures.append("indexed units should not tint non-player pixels through modulate")
			if not sprite.flip_h:
				failures.append("player-color binding should preserve mirrored facing")
		var old_material := sprite.material as ShaderMaterial
		state.set_team_color_id(Enums.Team.AI, 6)
		var changed_material := sprite.material as ShaderMaterial
		if changed_material == null or int(changed_material.get_shader_parameter("target_player")) != 6:
			failures.append("existing unit should refresh color without resetting its death animation")
		if old_material != null and int(old_material.get_shader_parameter("target_player")) != 2:
			failures.append("changing unit color must not mutate the old shared material")
		state.set_team_color_id(Enums.Team.AI, 2)
		holder.remove_child(unit)
		unit.free()
	holder.free()


func _test_buildings_and_ghosts(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var holder := Node2D.new()
	tree.root.add_child(holder)
	var state := MatchState.new()
	state.setup_defaults()
	for civ_id in ["chinese", "teutons"]:
		for building_id in ["town_center", "house", "barracks", "archery_range", "stable"]:
			var building := BUILDING_VIEW.instantiate() as BuildingAgent
			building.def = load("res://data/buildings/%s.tres" % building_id) as BuildingDef
			building.civ = load("res://data/civs/%s.tres" % civ_id) as CivDef
			building.team = Enums.Team.AI
			building.match_state = state
			building.is_placement_ghost = true
			holder.add_child(building)
			building._ready()
			var sprite := building.get_node("Billboard") as Sprite2D
			var material := sprite.material as ShaderMaterial
			if not sprite.visible or material == null:
				failures.append("building should bind player-color material: %s/%s" % [civ_id, building_id])
			else:
				if int(material.get_shader_parameter("target_player")) != 2:
					failures.append("building palette color should follow team independently of civilization")
				building.set_ghost_visual(true)
				if not is_equal_approx(sprite.modulate.a, 0.55) or sprite.material != material:
					failures.append("valid placement ghost should retain player shader with translucent modulate")
				building.set_ghost_visual(false)
				if not is_equal_approx(sprite.modulate.a, 0.55) or sprite.modulate.r <= sprite.modulate.g:
					failures.append("invalid placement should show the existing red translucent feedback")
				var ghost_tint := sprite.modulate
				state.set_team_color_id(Enums.Team.AI, 6)
				var changed_material := sprite.material as ShaderMaterial
				if changed_material == null or int(changed_material.get_shader_parameter("target_player")) != 6 or sprite.modulate != ghost_tint:
					failures.append("changing ghost player color must retain placement feedback")
				state.set_team_color_id(Enums.Team.AI, 2)
				building.clear_ghost_visual()
				if sprite.modulate != Color.WHITE or sprite.material != material:
					failures.append("placed building should restore full opacity and its cached player material")
			holder.remove_child(building)
			building.free()
	holder.free()


func _test_trained_unit_inherits_color(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var holder := Node2D.new()
	tree.root.add_child(holder)
	var state := MatchState.new()
	state.setup_defaults()
	state.set_team_color_id(Enums.Team.AI, 5)
	var building := BUILDING_VIEW.instantiate() as BuildingAgent
	building.def = load("res://data/buildings/town_center.tres") as BuildingDef
	building.civ = load("res://data/civs/chinese.tres") as CivDef
	building.team = Enums.Team.AI
	building.match_state = state
	holder.add_child(building)
	building._ready()
	var villager := load("res://data/units/villager.tres") as UnitDef
	if not building.enqueue_train(villager):
		failures.append("test town center should accept a villager for training")
	else:
		building._physics_process(100.0)
		var spawned: UnitAgent
		for child in holder.get_children():
			if child is UnitAgent:
				spawned = child as UnitAgent
		if spawned == null:
			failures.append("completed training should create a unit")
		else:
			spawned._ready()
			var sprite := spawned.get_node("Billboard") as AnimatedSprite2D
			var material := sprite.material as ShaderMaterial
			if material == null or int(material.get_shader_parameter("target_player")) != 5:
				failures.append("trained unit should inherit its team's configured palette row")
			if spawned.team != Enums.Team.AI or spawned.match_state != state:
				failures.append("trained unit color must come from inherited team/match ownership")
	holder.free()
