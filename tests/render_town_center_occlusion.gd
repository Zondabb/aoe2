extends SceneTree

## Render with the real GL backend (not --headless). Compare roof/shadow pixels
## against a foreground marker, then save a preview with production villagers.
const BUILDING := preload("res://scenes/entities/building_view.tscn")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const CATALOG := preload("res://scripts/presentation/sprite_catalog.gd")
const MARKER := Color(1, 0, 1, 1)
var viewport: SubViewport
var cases: Array[Dictionary] = []
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _frame() -> void:
	await process_frame
	await RenderingServer.frame_post_draw

func _run() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var ground := ColorRect.new()
	ground.color = Color("526543")
	ground.size = Vector2(1280, 720)
	ground.z_index = -100
	viewport.add_child(ground)
	for index in 2:
		var civ_id := "chinese" if index == 0 else "teutons"
		var entities := Node2D.new()
		entities.position = Vector2(325 + index * 630, 420)
		entities.y_sort_enabled = true
		viewport.add_child(entities)
		var building := BUILDING.instantiate() as BuildingAgent
		building.def = load("res://data/buildings/town_center.tres")
		building.civ = load("res://data/civs/%s.tres" % civ_id)
		building.team = index
		entities.add_child(building)
		var probe := Node2D.new()
		probe.position.y = 1000
		probe.visible = false
		var marker := ColorRect.new()
		marker.color = MARKER
		marker.position = Vector2(-280, -1350)
		marker.size = Vector2(560, 620)
		probe.add_child(marker)
		entities.add_child(probe)
		cases.append({"building": building, "probe": probe, "entities": entities})
	await _frame()
	await _frame()
	var baseline := viewport.get_texture().get_image()
	for item in cases:
		item.probe.visible = true
	await _frame()
	await _frame()
	var foreground := viewport.get_texture().get_image()
	var solid_checks := 0
	var shadow_checks := 0
	for item in cases:
		var sprite := item.building.get_node("Billboard") as Sprite2D
		var pixels := sprite.texture.get_image()
		for y in range(0, pixels.get_height(), 3):
			for x in range(0, pixels.get_width(), 3):
				var pixel := pixels.get_pixel(x, y)
				var at := Vector2i((sprite.global_transform * (Vector2(x + 0.5, y + 0.5) + sprite.offset - sprite.texture.get_size() * 0.5)).floor())
				if pixel.a > 0.999:
					solid_checks += 1
					if not foreground.get_pixelv(at).is_equal_approx(baseline.get_pixelv(at)):
						failures.append("foreground walker covered a solid roof pixel at %s" % at)
				elif pixel.a > 0.1:
					shadow_checks += 1
					if not foreground.get_pixelv(at).is_equal_approx(MARKER):
						failures.append("ground shadow covered a foreground walker at %s" % at)
		item.probe.visible = false
		for screen_at in [Vector2(-185, 65), Vector2(-95, 38), Vector2(0, 15), Vector2(95, 38), Vector2(185, 65)]:
			var unit := UNIT.instantiate() as UnitAgent
			unit.def = load("res://data/units/villager.tres")
			unit.team = item.building.team
			unit.civ = item.building.civ
			unit.sim_pos = IsoMath.screen_to_world(screen_at)
			item.entities.add_child(unit)
			unit.set_physics_process(false)
		var label := Label.new()
		label.text = "CHINESE" if item.building.team == 0 else "TEUTONS"
		label.position = item.entities.position + Vector2(-110, -330)
		label.add_theme_font_size_override("font_size", 24)
		viewport.add_child(label)
	if solid_checks < 1000 or shadow_checks < 100:
		failures.append("render checks did not cover enough solid and shadow pixels")
	await _frame()
	await _frame()
	viewport.get_texture().get_image().save_png("res://.godot/town-center-occlusion.png")
	for failure in failures.slice(0, 8):
		push_error(failure)
	print("TOWN CENTER RENDER: %d solid pixels, %d shadow pixels, %d failures" % [solid_checks, shadow_checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
