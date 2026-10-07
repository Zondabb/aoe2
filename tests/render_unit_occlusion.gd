extends SceneTree

const Renderer := preload("res://scripts/presentation/unit_occlusion.gd")
var viewport: SubViewport
var entities: Node2D
var renderer: Node
var building: Node2D
var unit: Node2D
var failures: Array[String] = []
var checks := 0

class UnitStub extends Node2D:
	var team := 0
	var match_state: MatchState
	var hp := 100

class StaticStub extends Node2D:
	var is_placement_ghost := false

class AnimationStepper extends Node:
	var sprite: AnimatedSprite2D
	func _process(_delta: float) -> void:
		sprite.frame = (sprite.frame + 1) % 2

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func frame() -> void:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw

func block_texture(size: Vector2i, color: Color) -> ImageTexture:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)

func _run() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(400, 300)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var ground := ColorRect.new()
	ground.size = Vector2(400, 300)
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
	var sprite := AnimatedSprite2D.new()
	sprite.name = "Billboard"
	var image := Image.create(40, 64, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	image.fill_rect(Rect2i(9, 4, 15, 56), Color("ddaa44"))
	image.fill_rect(Rect2i(24, 22, 8, 10), Color("ddaa44"))
	sprite.sprite_frames = SpriteFrames.new()
	sprite.sprite_frames.add_frame("default", ImageTexture.create_from_image(image))
	sprite.offset = Vector2(0, -32)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	unit.add_child(sprite)
	building = StaticStub.new()
	building.position = Vector2(180, 180)
	building.add_to_group("buildings")
	entities.add_child(building)
	var wall := Sprite2D.new()
	wall.name = "Billboard"
	wall.texture = block_texture(Vector2i(120, 110), Color("8b7355"))
	wall.offset = Vector2(0, -55)
	building.add_child(wall)
	Renderer.ensure_for(unit)
	Renderer.ensure_for(unit)
	await frame()
	renderer = viewport.get_meta(Renderer.KEY)
	check(renderer != null and renderer.outlines.size() == 1, "one shared renderer creates one outline per unit")
	await compare("behind opaque building", true)
	# Units are not hidden by a static drawn behind them (same texture overlap).
	building.position.y = 140
	wall.offset.y = -15
	await compare("foreground unit", false)
	building.position.y = unit.position.y
	wall.offset.y = -32
	await compare("same Y, later building", true)
	entities.move_child(unit, entities.get_child_count() - 1)
	await compare("same Y, later unit", false)
	building.position.y = 180
	wall.offset.y = -55
	wall.texture = block_texture(Vector2i(120, 110), Color(0, 0, 0, 100.0 / 255.0))
	await compare("ground shadow", false)
	var cutout := Image.create(120, 110, false, Image.FORMAT_RGBA8)
	cutout.fill(Color("8b7355"))
	cutout.fill_rect(Rect2i(35, 0, 50, 110), Color.TRANSPARENT)
	wall.texture = ImageTexture.create_from_image(cutout)
	await compare("transparent doorway", false)
	wall.texture = block_texture(Vector2i(120, 110), Color("8b7355"))
	wall.offset.y = -110
	await compare("partial head covering", true)
	wall.offset.y = -55
	building.is_placement_ghost = true
	wall.modulate.a = 0.55
	await compare("placement ghost", false)
	building.is_placement_ghost = false
	wall.modulate.a = 1.0
	building.hide()
	await compare("fog-hidden building", false)
	building.show()
	unit.hide()
	await compare("fog-hidden enemy unit", false)
	unit.show()
	await _test_animation_steps(sprite)
	sprite.flip_h = true
	await compare("mirrored animation", true)
	var next_frame := Image.create(40, 64, false, Image.FORMAT_RGBA8)
	next_frame.fill(Color.TRANSPARENT)
	next_frame.fill_rect(Rect2i(16, 12, 16, 48), Color("ddaa44"))
	sprite.sprite_frames.add_frame("default", ImageTexture.create_from_image(next_frame))
	sprite.frame = 1
	await compare("animation frame changes", true)
	check(renderer.outlines[unit.get_instance_id()].texture == sprite.sprite_frames.get_frame_texture("default", 1), "outline follows current animation frame")
	unit.match_state = MatchState.new()
	unit.match_state.setup_defaults()
	unit.match_state.set_team_color_id(0, 2)
	await frame()
	var tint: Color = renderer.outlines[unit.get_instance_id()].material.get_shader_parameter("outline_color")
	check(tint.r > tint.b, "outline follows the current team color")
	viewport.canvas_transform = Transform2D(0, Vector2(30, 20)).scaled_local(Vector2(1.35, 1.35))
	await compare("camera pan and zoom", true)
	viewport.canvas_transform = Transform2D.IDENTITY
	viewport.size = Vector2i(480, 320)
	await compare("viewport resize", true)
	check(renderer.mask_view.size == viewport.size, "mask resizes with the game viewport")
	var fillers: Array[Node] = []
	for i in 260:
		var filler := StaticStub.new()
		filler.position = Vector2(20, 20)
		filler.add_to_group("buildings")
		var pixel := Sprite2D.new()
		pixel.name = "Billboard"
		pixel.texture = block_texture(Vector2i.ONE, Color.WHITE)
		filler.add_child(pixel)
		entities.add_child(filler)
		fillers.append(filler)
	await compare("more than 256 draw ranks", true)
	for filler in fillers:
		filler.free()
	building.remove_from_group("buildings")
	building.add_to_group("resource_nodes")
	await compare("tree or resource", true)
	building.remove_from_group("resource_nodes")
	building.add_to_group("occlusion_memories")
	await compare("remembered static silhouette", true)
	var foreground := UnitStub.new()
	foreground.position = Vector2(180, 195)
	foreground.add_to_group("units")
	entities.add_child(foreground)
	var body := Sprite2D.new()
	body.name = "Body"
	body.offset.y = -60
	body.texture = block_texture(Vector2i(80, 130), Color("99dd66"))
	foreground.add_child(body)
	await compare("foreground dynamic unit clears static mask", false)
	foreground.free()
	building.free()
	await compare("destroyed building", false)
	check(renderer.copies.size() == 1, "destroyed occluder mask is removed")
	unit.free()
	await frame()
	check(renderer.outlines.is_empty(), "destroyed unit outline is removed")
	for child in viewport.get_children():
		if child.get_script() == Renderer:
			check(child == renderer, "repeated installation must reuse renderer")
	viewport.free()
	await _test_window_match()
	print("UNIT OCCLUSION RENDER: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func compare(label: String, expect_outline: bool) -> void:
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
	if is_instance_valid(unit) and renderer.outlines.has(unit.get_instance_id()):
		order = renderer.outlines[unit.get_instance_id()].material.get_shader_parameter("unit_order")
	for y in outlined.get_height():
		for x in outlined.get_width():
			if base.get_pixel(x, y).is_equal_approx(outlined.get_pixel(x, y)):
				continue
			count += 1
			var depth := mask.get_pixel(x, y)
			if roundf(depth.r * 255.0) + roundf(depth.g * 255.0) * 256.0 <= order:
				outside += 1
	check(count > 10 if expect_outline else count == 0, "%s: expected outline=%s, changed pixels=%d" % [label, expect_outline, count])
	check(outside == 0, "%s: outline must affect only pixels actually covered by a static" % label)

func _test_animation_steps(sprite: AnimatedSprite2D) -> void:
	# Change atlas UVs every rendered frame. Updating in frame_pre_draw leaves
	# Sprite2D geometry one frame behind its shader uniforms on GL/WebGL.
	var previous := sprite.sprite_frames
	var sheet := Image.create(80, 64, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.TRANSPARENT)
	sheet.fill_rect(Rect2i(9, 4, 15, 56), Color("ddaa44"))
	sheet.fill_rect(Rect2i(56, 12, 16, 48), Color("ddaa44"))
	var texture := ImageTexture.create_from_image(sheet)
	var frames := SpriteFrames.new()
	for i in 2:
		var atlas := AtlasTexture.new()
		atlas.atlas = texture
		atlas.region = Rect2(i * 40, 0, 40, 64)
		frames.add_frame("default", atlas)
	sprite.sprite_frames = frames
	var stepper := AnimationStepper.new()
	stepper.sprite = sprite
	viewport.add_child(stepper)
	await frame()
	for i in 8:
		await process_frame
		await RenderingServer.frame_post_draw
		var rendered := viewport.get_texture().get_image()
		var blue_pixels := 0
		for y in range(80, 180):
			for x in range(140, 220):
				var pixel := rendered.get_pixel(x, y)
				if pixel.b > pixel.r + 0.1:
					blue_pixels += 1
		check(blue_pixels > 10, "animated atlas frame %d keeps its occluded contour" % i)
	stepper.free()
	sprite.sprite_frames = previous

func _test_window_match() -> void:
	# A real Window backbuffer has a different SCREEN_UV orientation from a
	# SubViewport on GL. Exercise the actual camera and production atlas too.
	var match_scene: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(match_scene)
	match_scene.get_node("Camera2D").set_process(false)
	for i in 3:
		await frame()
	match_scene.get_node("Bootstrap").match_state.frozen = true
	await _compare_window("default window", true)
	root.size = Vector2i(960, 540)
	await frame()
	await _compare_window("smaller window", false)
	root.size = Vector2i(1440, 800)
	await frame()
	await _compare_window("larger window", false)

func _compare_window(label: String, save_preview: bool) -> void:
	var window_renderer: Node = root.get_meta(Renderer.KEY)
	window_renderer.enabled = false
	await frame()
	var baseline := root.get_texture().get_image()
	window_renderer.enabled = true
	await frame()
	var outlined := root.get_texture().get_image()
	var mask: Image = window_renderer.mask_view.get_texture().get_image()
	var changed := 0
	var outside := 0
	for y in range(int(80.0 * outlined.get_height() / 720.0), int(510.0 * outlined.get_height() / 720.0)):
		for x in range(outlined.get_width()):
			if baseline.get_pixel(x, y).is_equal_approx(outlined.get_pixel(x, y)):
				continue
			changed += 1
			var mask_pixel := mask.get_pixel(int((x + 0.5) * mask.get_width() / outlined.get_width()), int((y + 0.5) * mask.get_height() / outlined.get_height()))
			if mask_pixel.r == 0.0 and mask_pixel.g == 0.0:
				outside += 1
	check(changed > 100, "%s must outline villagers beneath the roof (%d pixels)" % [label, changed])
	check(outside == 0, "%s must leave uncovered pixels unchanged (%d outside)" % [label, outside])
	if save_preview:
		outlined.save_png("res://.godot/unit-occlusion-match.png")
