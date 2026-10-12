extends SceneTree

## GPU pixel checks for Polygon2D masks. Runtime terrain uses the same path;
## this fixture also exercises UV holes and edits that Sprite2D cannot cover.
const RENDERER := preload("res://scripts/presentation/unit_occlusion.gd")
const MEMORY := preload("res://scripts/presentation/fog_memory.gd")
var viewport: SubViewport
var entities: Node2D
var actor: StaticStub
var wall: Polygon2D
var unit: UnitStub
var renderer: Node
var checks := 0
var failures: Array[String] = []

class UnitStub extends Node2D:
	var team := 0
	var match_state: MatchState
	var hp := 100

class StaticStub extends Node2D:
	var is_placement_ghost := false

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func frame() -> void:
	for i in 4:
		await process_frame
		await RenderingServer.frame_post_draw

func texture(color: Color, hole := false) -> ImageTexture:
	var image := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	image.fill(color)
	if hole: image.fill_rect(Rect2i(40, 0, 40, 128), Color.TRANSPARENT)
	return ImageTexture.create_from_image(image)

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Polygon occlusion checks require the graphical backend")
		quit(1)
		return
	viewport = SubViewport.new()
	viewport.size = Vector2i(400, 300)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var ground := ColorRect.new()
	ground.size = viewport.size
	ground.color = Color("415236")
	ground.z_index = -100
	viewport.add_child(ground)
	entities = Node2D.new()
	entities.y_sort_enabled = true
	viewport.add_child(entities)
	unit = UnitStub.new()
	unit.position = Vector2(180, 155)
	unit.add_to_group("units")
	entities.add_child(unit)
	var sprite := Sprite2D.new()
	sprite.name = "Billboard"
	var person := Image.create(40, 64, false, Image.FORMAT_RGBA8)
	person.fill(Color.TRANSPARENT)
	person.fill_rect(Rect2i(9, 4, 15, 56), Color("ddaa44"))
	person.fill_rect(Rect2i(24, 22, 8, 10), Color("ddaa44"))
	sprite.texture = ImageTexture.create_from_image(person)
	sprite.offset = Vector2(0, -32)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	unit.add_child(sprite)
	actor = StaticStub.new()
	actor.position = Vector2(180, 180)
	actor.add_to_group("path_blockers")
	entities.add_child(actor)
	wall = Polygon2D.new()
	wall.name = "Body"
	wall.polygon = PackedVector2Array([Vector2(-60, -105), Vector2(60, -105), Vector2(60, 0), Vector2(-60, 0)])
	wall.uv = PackedVector2Array([Vector2(0, 0), Vector2(120, 0), Vector2(120, 105), Vector2(0, 105)])
	wall.texture = texture(Color("8b7355"))
	wall.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	wall.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	actor.add_child(wall)
	RENDERER.ensure_for(unit)
	await frame()
	renderer = viewport.get_meta(RENDERER.KEY)
	check(renderer.copies[wall.get_instance_id()] is Polygon2D, "terrain depth copy is a polygon mesh")
	await compare("opaque cliff wall", true)
	wall.texture = texture(Color("8b7355"), true)
	await compare("transparent texture gap", false)
	wall.texture_offset = Vector2(60, 0)
	await compare("texture offset moves opaque pixels onto unit", true)
	var mask_copy := renderer.copies[wall.get_instance_id()] as Polygon2D
	check(mask_copy.uv == wall.uv and mask_copy.texture_offset == wall.texture_offset, "polygon mask preserves pixel UV and offset")
	wall.color.a = 0.5
	await compare("translucent polygon color", false)
	wall.color.a = 1.0
	wall.vertex_colors = PackedColorArray([Color(1, 1, 1, 0.4), Color(1, 1, 1, 0.4), Color(1, 1, 1, 0.4), Color(1, 1, 1, 0.4)])
	await compare("translucent vertex colors", false)
	wall.vertex_colors = PackedColorArray()
	wall.texture = null
	await compare("untextured solid wall", true)
	check(mask_copy.texture != null, "untextured mask uses a reusable opaque texture")
	actor.is_placement_ghost = true
	await compare("terrain editor placement preview", false)
	actor.is_placement_ghost = false
	wall.z_index = -99
	await compare("ground water is excluded from depth", false)
	wall.z_index = 0
	actor.position.y = 140
	await compare("unit in front of terrain", false)
	actor.position.y = 180
	wall.offset.x = 10000
	await compare("polygon offset moves offscreen", false)
	wall.offset.x = 0
	await compare("polygon offset returns onscreen", true)
	var original := wall.polygon
	var far_shape := PackedVector2Array()
	for point in original: far_shape.append(point + Vector2(10000, 0))
	wall.polygon = far_shape
	await compare("offscreen polygon geometry", false)
	wall.polygon = original
	await compare("polygon geometry returns onscreen", true)
	wall.texture = texture(Color("8b7355"))
	wall.texture_scale = Vector2(0.75, 1.25)
	wall.texture_offset = Vector2(15, -25)
	wall.texture_rotation = 0.1
	wall.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	await compare("transformed repeating texture", true)
	var stable_redraws: int = renderer.mask_redraws
	await frame()
	check(renderer.mask_redraws == stable_redraws, "unchanged polygon meshes reuse their depth mask")
	var old_key := MEMORY.appearance_key(actor)
	var parts := MEMORY.capture(actor)
	var snapshot := {"position":actor.position, "parts":parts, "appearance":old_key}
	var remembered := MEMORY.make_view(snapshot)
	var saved_wall := remembered.get_child(0) as Polygon2D
	check(saved_wall.texture == wall.texture and saved_wall.uv == wall.uv, "fog memory retains the observed terrain texture and UV")
	check(saved_wall.texture_filter == wall.texture_filter and saved_wall.texture_repeat == wall.texture_repeat, "fog memory retains filtering and repetition")
	check(saved_wall.texture_scale == wall.texture_scale and saved_wall.texture_offset == wall.texture_offset and saved_wall.texture_rotation == wall.texture_rotation, "fog memory retains texture transforms")
	actor.hide()
	entities.add_child(remembered)
	await compare("remembered textured cliff silhouette", true)
	var observed := saved_wall.texture
	wall.texture = texture(Color(0, 0, 0, 0))
	wall.uv = PackedVector2Array([Vector2.ZERO, Vector2(1, 0), Vector2.ONE, Vector2(0, 1)])
	check(MEMORY.appearance_key(actor) != old_key, "texture and UV changes invalidate a newly observed appearance")
	MEMORY.update_view(remembered, snapshot)
	check(saved_wall.texture == observed and saved_wall.uv == parts[0].uv, "hidden live edits do not mutate the last observed appearance")
	await compare("hidden live texture update preserves old contour", true)
	remembered.free()
	actor.show()
	await compare("newly seen transparent texture", false)
	actor.z_index = -99
	wall.texture = texture(Color("8b7355"))
	var low_parts := MEMORY.capture(actor)
	var low_memory := MEMORY.make_view({"position":actor.position, "parts":low_parts})
	check(low_memory.get_child(0).z_index == -99, "fog snapshot preserves parent terrain depth")
	low_memory.free()
	actor.free()
	await compare("removed terrain releases polygon mask", false)
	check(renderer._polygon_sources.is_empty(), "destroyed terrain leaves no geometry polling records")
	viewport.free()
	print("Terrain polygon occlusion: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func compare(label: String, expected: bool) -> void:
	renderer.enabled = false
	await frame()
	var base := viewport.get_texture().get_image()
	renderer.enabled = true
	await frame()
	var outlined := viewport.get_texture().get_image()
	var mask: Image = renderer.mask_view.get_texture().get_image()
	var count := 0
	var outside := 0
	var order := 0.0
	if renderer.outlines.has(unit.get_instance_id()):
		order = renderer.outlines[unit.get_instance_id()].material.get_shader_parameter("unit_order")
	for y in outlined.get_height():
		for x in outlined.get_width():
			if base.get_pixel(x, y).is_equal_approx(outlined.get_pixel(x, y)): continue
			count += 1
			var depth := mask.get_pixel(x, y)
			if roundf(depth.r * 255) + roundf(depth.g * 255) * 256 <= order: outside += 1
	check(count > 10 if expected else count == 0, "%s expected outline %s; changed pixels %d" % [label, expected, count])
	check(outside == 0, "%s changes only pixels with foreground terrain depth" % label)
