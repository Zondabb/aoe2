extends SceneTree
## Repeated cached frame updates must match the authored sprite hotspots and
## color material across facing, frame, action, ownership and upgrade changes.
const UnitView := preload("res://scenes/entities/unit_view.tscn")
const Sprites := preload("res://scripts/presentation/sprite_catalog.gd")
const Colors := preload("res://scripts/presentation/team_color_catalog.gd")
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var holder := Node2D.new()
	root.add_child(holder)
	var state := MatchState.new()
	state.setup_defaults()
	for id in [&"villager", &"militia", &"archer", &"knight"]:
		var unit := UnitView.instantiate() as UnitAgent
		unit.def = GameCatalog.get_unit(id)
		unit.match_state = state
		holder.add_child(unit)
		unit.set_physics_process(false)
		var sprite := unit.get_node("Billboard") as AnimatedSprite2D
		check(sprite.sprite_frames != null, "%s has original animation frames" % id)
		if sprite.sprite_frames == null:
			unit.free()
			continue
		for animation in sprite.sprite_frames.get_animation_names():
			var parsed := Sprites.parse_directional_animation(animation)
			var metadata: Dictionary = unit._sprite_metas.get(parsed.action, unit._sprite_metas.get(&"", {}))
			if metadata.is_empty(): continue
			var count := sprite.sprite_frames.get_frame_count(animation)
			for frame in [0, count / 2, count - 1]:
				for flip in [false, true]:
					unit._facing_flip = flip
					var expected := Sprites.offset_for_frame_2d(metadata, parsed.direction, frame, flip)
					unit._apply_billboard_hotspot(sprite, animation, frame)
					check(sprite.offset.is_equal_approx(expected), "%s %s frame %s mirrored %s" % [id, animation, frame, flip])
					# The cached branch must also repair an externally reset offset.
					sprite.offset = Vector2(9999, 9999)
					unit._apply_billboard_hotspot(sprite, animation, frame)
					check(sprite.offset.is_equal_approx(expected), "repeated frame retains authored hotspot")
			for team in [0, 1]:
				unit.team = team
				state.set_team_color_id(team, 3 + team)
				unit._apply_billboard_player_color(sprite, animation)
				var sheet := Sprites.unit_animation_sheet_base(unit.def.id, animation)
				var expected_material := Sprites.player_color_material(sheet, Colors.resolve_color_id(team, state))
				check(sprite.material == expected_material, "%s %s uses current team material" % [id, animation])
				unit._apply_billboard_player_color(sprite, animation)
				check(sprite.material == expected_material, "repeated animation retains team material")
		# Rebuilding presentation invalidates the per-frame hotspot cache.
		unit._setup_presentation()
		var animation := sprite.animation
		var parsed := Sprites.parse_directional_animation(animation)
		var metadata: Dictionary = unit._sprite_metas.get(parsed.action, unit._sprite_metas.get(&"", {}))
		unit._apply_billboard_hotspot(sprite, animation, sprite.frame)
		check(sprite.offset.is_equal_approx(Sprites.offset_for_frame_2d(metadata, parsed.direction, sprite.frame, unit._facing_flip)), "%s presentation rebuild resets hotspot cache" % id)
		unit.free()
	holder.free()
	failures.append_array(load("res://tests/test_combat_visual.gd").new().run())
	print("UNIT PRESENTATION CACHE: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
