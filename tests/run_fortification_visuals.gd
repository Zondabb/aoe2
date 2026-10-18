extends SceneTree
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Building := preload("res://scenes/entities/building_view.tscn")
const Walls := preload("res://scripts/systems/wall_system.gd")
const Art := preload("res://scripts/presentation/fortification_visual.gd")
const Sprites := preload("res://scripts/presentation/sprite_catalog.gd")
const Memory := preload("res://scripts/presentation/fog_memory.gd")
const Selection := preload("res://scripts/input/selection_controller_2d.gd")
const Occlusion := preload("res://scripts/presentation/unit_occlusion.gd")
var checks := 0
var failures := 0
var entities: Node2D
var state: MatchState

func _initialize() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
func clear() -> void:
	if is_instance_valid(entities): entities.free()
	entities = Node2D.new()
	root.add_child(entities)
func building(id: String, pos: Vector2, civ_id := "chinese", orientation := 0, complete := true, ghost := false) -> BuildingAgent:
	var entity := Building.instantiate() as BuildingAgent
	entity.def = Catalog.get_building(StringName(id))
	entity.civ = load("res://data/civs/%s.tres" % civ_id)
	entity.match_state = state
	entity.sim_pos = pos
	entity.wall_orientation = orientation
	entity.is_complete = complete
	entity.is_placement_ghost = ghost
	entities.add_child(entity)
	return entity
func visual(entity: BuildingAgent) -> Node2D:
	var value := entity.get_node("FortificationVisual") as Node2D
	value.refresh()
	return value

func _run() -> void:
	state = MatchState.new()
	state.setup_defaults()
	state.set_age(0, 2)
	state.set_team_color_id(0, 1)
	state.frozen = true
	for civ_id in ["chinese", "teutons"]:
		for id in ["palisade_wall", "stone_wall", "fortified_wall"]:
			for orientation in 4:
				clear()
				var axis := Walls.direction(orientation)
				var center := building(id, Vector2.ZERO, civ_id, orientation)
				var left := building(id, -axis, civ_id, orientation)
				building(id, axis, civ_id, orientation)
				var art := visual(center)
				var meta := Sprites.load_meta(art.sheet_base)
				check(art.frame_index == [1,4,0,3][orientation], "%s %s actual connected axis %d" % [civ_id,id,orientation])
				check(art.get_child(0) is Sprite2D and not center.get_node("Billboard").visible and not center.get_node("Body").visible, "original Sprite2D replaces procedural body")
				check(meta.source.begins_with("AoE2 HD") and not meta.frames[art.frame_index].layers.is_empty(), "original source layers retained")
				check(Sprites.player_color_is_valid(art.sheet_base), "original indexed player mask valid")
				var sprite := art.get_child(0) as Sprite2D
				check(is_equal_approx(sprite.scale.x * 48, 22) and sprite.rotation == 0, "source tile seam scale without image rotation")
				check(visual(left).frame_index == 2, "original endpoint post")
				left.free()
				check(visual(center).frame_index == 2, "demolition exposes original endpoint post")
		for orientation in 4:
			clear()
			var gate := building("gate", Vector2.ZERO, civ_id, orientation)
			var axis := Walls.direction(orientation)
			var next := building("stone_wall", axis * 2.5, civ_id, orientation)
			building("stone_wall", axis * 3.5, civ_id, orientation)
			check(visual(next).frame_index == [1,4,0,3][orientation], "wall connects directly to original gate pillar")
			var art := visual(gate)
			check(art.frame_index == orientation * 2, "closed original directional gate")
			var before := Memory.appearance_key(gate)
			check(Memory.appearance_key(gate) == before, "unchanged sprite has stable fog key")
			var snapshot := Memory.capture(gate)
			var frozen_texture: Texture2D = snapshot[0].texture
			gate.set_gate_state("open")
			check(art.frame_index == orientation * 2 + 1 and Memory.appearance_key(gate) != before, "open uses distinct original gate art immediately")
			check(snapshot[0].texture == frozen_texture and art.get_child(0).texture != frozen_texture, "fog retains last seen closed frame")
			gate.set_gate_state("locked")
			check(art.frame_index == orientation * 2, "locked restores closed gate art")
			var old_material: ShaderMaterial = art.get_child(0).material
			state.set_team_color_id(0, 2)
			check(art.get_child(0).material != old_material and int(art.get_child(0).material.get_shader_parameter("target_player")) == 2, "team color updates original pixels")
			check(int(snapshot[0].material.get_shader_parameter("target_player")) == 1, "fog team shader is frozen")
			state.set_team_color_id(0, 1)
			var selector := Selection.new()
			check(selector._visual_rect_canvas(gate) == art.visual_rect_canvas(), "selection follows actual fortification sprite")
			if orientation == 1:
				check(art.visual_rect_canvas().size.x < art.get_child(0).texture.get_width() * art.get_child(0).scale.x * 0.7, "vertical gate excludes wide transparent atlas padding")
			selector.free()
			gate.is_complete = false
			check(art.get_child_count() == 4 and art.sheet_base.ends_with("gate_foundation_tile"), "construction uses four original foundation tiles")
			for index in 4:
				check(art.get_child(index).position == IsoMath.world_to_screen(axis * (float(index)-1.5)), "foundation follows actual gate axis")
			gate.is_complete = true
			check(art.get_child_count() == 1, "completion removes foundation tiles")
	clear()
	var ghost := building("stone_wall", Vector2.ZERO, "chinese", 0, false, true)
	ghost.set_ghost_visual(true)
	var ghost_art := visual(ghost)
	check(ghost_art.sheet_base.ends_with("chinese_stone_wall") and ghost_art.modulate.a < 1, "preview uses original completed art with transparent validity tint")
	ghost.clear_ghost_visual()
	check(ghost_art.modulate == Color.WHITE and ghost_art.sheet_base.ends_with("_construction"), "placing preview restores untinted original construction")
	ghost.build_progress = ghost.def.build_time * 0.8
	check(visual(ghost).frame_index % 4 == 3, "construction progress selects original DAT stage")
	clear()
	var corner := building("stone_wall", Vector2.ZERO)
	building("stone_wall", Vector2.RIGHT)
	building("stone_wall", Vector2.DOWN)
	check(visual(corner).frame_index == 2, "turn uses original corner post")
	var occlusion := Occlusion.new()
	root.add_child(occlusion)
	occlusion._register_static_actor(corner)
	check(occlusion._static_sources.has(visual(corner).get_child(0).get_instance_id()), "wall artwork participates in unit occlusion")
	occlusion.free()
	entities.free()
	print("FORTIFICATION VISUALS: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
