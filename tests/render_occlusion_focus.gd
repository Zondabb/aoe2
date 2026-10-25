extends SceneTree
## A fully transparent full-screen unit makes the renderer retain every static
## silhouette, reproducing the old mask coverage without changing visible pixels.
## Compare that reference framebuffer byte for byte with the focused mask.
const Renderer := preload("res://scripts/presentation/unit_occlusion.gd")
var checks := 0
var failures := 0
var viewport: SubViewport
var entities: Node2D
var renderer: Node
var phantom: Node2D
var wall: Sprite2D
var polygon: Polygon2D

class UnitActor extends Node2D:
	var team := 0
	var hp := 100
	var match_state: MatchState

class StaticActor extends Node2D:
	var is_placement_ghost := false

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func image_texture(size: Vector2i, color: Color) -> ImageTexture:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)

func frames() -> void:
	for index in 3:
		await process_frame
		await RenderingServer.frame_post_draw

func actor(at: Vector2, size: Vector2i, color: Color) -> UnitActor:
	var value := UnitActor.new()
	value.position = at
	value.add_to_group("units")
	var sprite := Sprite2D.new()
	sprite.name = "Body"
	sprite.texture = image_texture(size, color)
	sprite.offset.y = -size.y * 0.5
	value.add_child(sprite)
	entities.add_child(value)
	return value

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Focused occlusion test requires a real renderer")
		quit(1)
		return
	root.get_node("GameSession").match_ai_mode = "sandbox"
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	viewport = SubViewport.new()
	viewport.size = Vector2i(440, 320)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	root.add_child(viewport)
	var ground := ColorRect.new()
	ground.color = Color("415236")
	ground.size = Vector2(viewport.size)
	ground.z_index = -100
	viewport.add_child(ground)
	entities = Node2D.new()
	entities.y_sort_enabled = true
	viewport.add_child(entities)
	var rear := actor(Vector2(180, 155), Vector2i(20, 60), Color("ddaa44"))
	var front := actor(Vector2(170, 190), Vector2i(30, 70), Color("99dd66"))
	actor(Vector2(300, 120), Vector2i(20, 50), Color("ddaa44"))
	var building := StaticActor.new()
	building.position = Vector2(180, 180)
	building.add_to_group("buildings")
	wall = Sprite2D.new()
	wall.name = "Billboard"
	wall.texture = image_texture(Vector2i(100, 110), Color("8b7355"))
	wall.offset.y = -55
	building.add_child(wall)
	entities.add_child(building)
	var terrain := StaticActor.new()
	terrain.add_to_group("path_blockers")
	polygon = Polygon2D.new()
	polygon.polygon = PackedVector2Array([Vector2(265, 70), Vector2(335, 70), Vector2(335, 135), Vector2(265, 135)])
	polygon.color = Color("8b7355")
	terrain.position.y = 140
	polygon.position.y = -140
	terrain.add_child(polygon)
	entities.add_child(terrain)
	for index in 400:
		var filler := StaticActor.new()
		filler.position = Vector2(4 + index % 40 * 11, 4 + index / 40 * 31)
		filler.add_to_group("resource_nodes")
		var sprite := Sprite2D.new()
		sprite.name = "Billboard"
		sprite.texture = image_texture(Vector2i(3, 3), Color("8b7355"))
		filler.add_child(sprite)
		entities.add_child(filler)
	phantom = actor(Vector2.ZERO, Vector2i(2000, 2000), Color.TRANSPARENT)
	var phantom_sprite := phantom.get_node("Body") as Sprite2D
	phantom_sprite.offset = Vector2.ZERO
	phantom.hide()
	Renderer.ensure_for(rear)
	await frames()
	renderer = viewport.get_meta(Renderer.KEY)
	await compare("dense static sprites and foreground unit")
	front.position = Vector2(185, 170)
	rear.move_to_front()
	await compare("same-layer unit ordering changes")
	var cutout := Image.create(100, 110, false, Image.FORMAT_RGBA8)
	cutout.fill(Color("8b7355"))
	cutout.fill_rect(Rect2i(35, 0, 30, 110), Color.TRANSPARENT)
	wall.texture = ImageTexture.create_from_image(cutout)
	wall.flip_h = true
	await compare("new static texture and transparent doorway")
	polygon.texture = image_texture(Vector2i(4, 4), Color(1, 1, 1, 0.2))
	await compare("polygon texture changes without geometry change")
	entities.scale = Vector2(0.9, 1.1)
	entities.position = Vector2(10, -15)
	viewport.canvas_transform = Transform2D(0, Vector2(5, 8)).scaled_local(Vector2(1.1, 1.1))
	await compare("camera and ancestor transforms")
	building.position.y += 1000
	await compare("occluder moves outside unit coverage")
	building.position.y -= 1000
	await compare("occluder returns to unit coverage")
	viewport.free()
	print("FOCUSED OCCLUSION RENDER: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func compare(label: String) -> void:
	phantom.hide()
	await frames()
	var focused := viewport.get_texture().get_image()
	var focused_copies: int = renderer.copies.size()
	phantom.show()
	await frames()
	var reference := viewport.get_texture().get_image()
	var reference_copies: int = renderer.copies.size()
	check(focused.get_data() == reference.get_data(), "%s: focused mask matches full viewport reference byte for byte" % label)
	check(reference_copies > focused_copies + 150, "%s: skips unrelated static copies (%d versus %d)" % [label, focused_copies, reference_copies])
	check(renderer.static_registered >= 402, "%s: all static entities remain registered" % label)
