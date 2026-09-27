extends SceneTree

const BUILDING := preload("res://scenes/entities/building_view.tscn")
const CATALOG := preload("res://scripts/presentation/sprite_catalog.gd")
const MEMORY := preload("res://scripts/presentation/fog_memory.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var holder := Node2D.new()
	root.add_child(holder)
	var state := MatchState.new()
	state.setup_defaults()
	for civ_id in ["chinese", "teutons"]:
		var building := BUILDING.instantiate() as BuildingAgent
		building.def = load("res://data/buildings/town_center.tres")
		building.civ = load("res://data/civs/%s.tres" % civ_id)
		building.match_state = state
		building.sim_pos = Vector2(3, 4)
		holder.add_child(building)
		var solid := building.get_node("Billboard") as Sprite2D
		var shadow := building.get_node("GroundShadow") as Node2D
		check(solid.z_index > 0 and shadow.z_index < -2, "solid must cover units while shadow stays below selection/units")
		check(building.position == IsoMath.world_to_screen(building.sim_pos), "layering must preserve logical position")
		check(building.def.footprint == Vector2(4, 4) and building.block_half == Vector2.ZERO, "keep placement footprint while allowing passage")
		var solid_material := solid.material as ShaderMaterial
		check(int(solid_material.get_shader_parameter("sprite_layer")) == CATALOG.SpriteLayer.SOLID, "building uses solid-only artwork")
		if civ_id == "chinese":
			check(shadow is Sprite2D, "composite TC must use its original baked shadow")
			check(shadow.texture == solid.texture and shadow.transform == solid.transform and shadow.offset == solid.offset, "both layers must stay aligned")
			check(int(shadow.material.get_shader_parameter("sprite_layer")) == CATALOG.SpriteLayer.SHADOW, "shadow layer must exclude all solid artwork")
		else:
			check(shadow is Polygon2D, "TC without baked shadow must retain ground ellipse")
		building.set_ghost_visual(false)
		check(is_equal_approx(solid.modulate.a, 0.55), "placement ghost must remain translucent")
		if shadow is Sprite2D:
			check(shadow.modulate == solid.modulate, "ghost tint must apply to both layers")
		state.set_team_color_id(Enums.Team.PLAYER, 2)
		check(int(solid.material.get_shader_parameter("target_player")) == 2, "layered roof must retain team recoloring")
		check(int(solid_material.get_shader_parameter("target_player")) == 1, "recoloring must not mutate shared material")
		building.clear_ghost_visual()
		check(solid.modulate == Color.WHITE, "placed building must restore opacity")
		var snapshot := MEMORY.capture(building)
		check(snapshot.size() == 2, "fog memory must retain exactly the solid and shadow layers")
		var memory := MEMORY.make_view({"position": building.position, "parts": snapshot})
		check(memory.get_child_count() == 2, "fog memory must reconstruct both layers")
		memory.free()
		# Reconfiguration may switch between composite and unlayered civilizations.
		building.civ = load("res://data/civs/teutons.tres")
		building._configure_visuals()
		check(building.get_node("GroundShadow") is Polygon2D, "composite shadow must cleanly return to fallback ellipse")
		building.civ = load("res://data/civs/chinese.tres")
		building._configure_visuals()
		check(building.get_node("GroundShadow") is Sprite2D, "fallback ellipse must cleanly return to composite shadow")
		building.free()
		state.set_team_color_id(Enums.Team.PLAYER, 1)
	holder.free()
	failures.append_array(load("res://tests/test_team_color.gd").new().run())
	failures.append_array(load("res://tests/test_buildings.gd").new().run())
	print("TOWN CENTER LAYERS: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
