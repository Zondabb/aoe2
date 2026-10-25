extends SceneTree
## Real framebuffer regression for 30 Hz simulation / 60 Hz presentation.
## godot --path . --script res://tests/render_physics_interpolation.gd
const UnitView := preload("res://scenes/entities/unit_view.tscn")
const ProjectileView := preload("res://scenes/entities/projectile_view.tscn")
const Camera := preload("res://scripts/input/rts_camera_2d.gd")
const Renderer := preload("res://scripts/presentation/unit_occlusion.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
const GOLD := Color("ddaa44")
var checks := 0
var failures: Array[String] = []
var viewport: SubViewport
var entities: Node2D
var actors: Array[UnitAgent] = []
var renderer: Node
var driver: MotionDriver
var intermediate_frames := 0
var outline_frames := 0

class StaticActor extends Node2D:
	var is_placement_ghost := false

class MotionDriver extends Node:
	var units: Array[UnitAgent] = []
	var velocity := Vector2(100, 0)
	func _physics_process(delta: float) -> void:
		for actor in units:
			# Use the real unit's history/early-return handling, then give it a
			# deterministic physics translation independent of crowd decisions.
			actor._physics_process(delta)
			actor.position += velocity * delta

class ResetProjectile extends ProjectileAgent:
	var reset_notifications := 0
	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESET_PHYSICS_INTERPOLATION:
			reset_notifications += 1

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func texture(size: Vector2i, color: Color) -> ImageTexture:
	var pixels := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	pixels.fill(color)
	return ImageTexture.create_from_image(pixels)

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Interpolation display test needs a real renderer")
		quit(1)
		return
	Engine.time_scale = 1.0
	Engine.physics_ticks_per_second = 30
	Engine.max_fps = 60
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	check(ProjectSettings.get_setting("physics/common/physics_interpolation", false), "project enables physics interpolation")
	viewport = SubViewport.new()
	viewport.size = Vector2i(480, 320)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var ground := ColorRect.new()
	ground.size = Vector2(viewport.size)
	ground.color = Color("415236")
	ground.z_index = -100
	ground.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	viewport.add_child(ground)
	entities = Node2D.new()
	entities.y_sort_enabled = true
	entities.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	viewport.add_child(entities)
	for y in [150.0, 195.0]:
		var actor := UnitView.instantiate() as UnitAgent
		actor.def = GameCatalog.get_unit(&"militia")
		actor.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_ON
		actor.sim_pos = Iso.screen_to_world(Vector2(95, y))
		entities.add_child(actor)
		actor.set_physics_process(false)
		actor._use_billboard = false
		(actor.get_node("Body") as CanvasItem).hide()
		var sprite := actor.get_node("Billboard") as AnimatedSprite2D
		sprite.sprite_frames = SpriteFrames.new()
		sprite.sprite_frames.add_frame("default", texture(Vector2i(16, 40), GOLD))
		sprite.animation = &"default"
		sprite.frame = 0
		sprite.scale = Vector2.ONE
		sprite.offset = Vector2(0, -20)
		sprite.material = null
		sprite.show()
		actor.reset_physics_interpolation()
		actors.append(actor)
	var building := StaticActor.new()
	building.position = Vector2(145, 180)
	building.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	building.add_to_group("buildings")
	var wall := Sprite2D.new()
	wall.name = "Billboard"
	wall.texture = texture(Vector2i(70, 110), Color("8b7355"))
	wall.offset = Vector2(0, -55)
	building.add_child(wall)
	entities.add_child(building)
	driver = MotionDriver.new()
	driver.units = actors
	viewport.add_child(driver)
	for frame in 5:
		await process_frame
		await RenderingServer.frame_post_draw
	renderer = viewport.get_meta(Renderer.KEY)
	check(renderer.mask_view.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF, "screen mask viewport disables double interpolation")
	for phase in 2:
		if phase == 1:
			entities.scale = Vector2(1.1, 0.9)
			entities.position = Vector2(7, 5)
			viewport.canvas_transform = Transform2D(0, Vector2(-8, 9)).scaled_local(Vector2(1.05, 1.05))
		for frame in 18:
			await process_frame
			await RenderingServer.frame_post_draw
			_compare_frame("phase %d frame %d" % [phase, frame])
	# Cross the wall's Y-sort origin while the displayed position lies between
	# ticks; the mask must agree with the backend's actual foreground ordering.
	driver.velocity = Vector2(0, 100)
	for frame in 14:
		await process_frame
		await RenderingServer.frame_post_draw
		_compare_frame("Y-sort crossing %d" % frame)
	driver.velocity = Vector2.ZERO
	for frame in 6:
		await process_frame
		await RenderingServer.frame_post_draw
		_compare_frame("idle frame %d" % frame)
	actors[1].position = Vector2(270, 195)
	actors[1].reset_physics_interpolation()
	check(actors[1].previous_physics_position == actors[1].position, "teleport reset also resets the mask history")
	await process_frame
	await RenderingServer.frame_post_draw
	_compare_frame("teleport")
	check(intermediate_frames >= 5, "sampled actual frames between physics positions (%d)" % intermediate_frames)
	check(outline_frames >= 5, "moving units retain covered contours (%d frames)" % outline_frames)
	_test_camera_and_projectiles()
	viewport.get_texture().get_image().save_png("res://.godot/physics-interpolation-preview.png")
	viewport.free()
	print("PHYSICS INTERPOLATION DISPLAY: %d checks, %d failures, %d intermediate frames, %d outline frames" % [checks, failures.size(), intermediate_frames, outline_frames])
	quit(0 if failures.is_empty() else 1)

func _compare_frame(label: String) -> void:
	var displayed := viewport.get_texture().get_image()
	var mask: Image = renderer.mask_view.get_texture().get_image()
	var source := actors[1].get_node("Billboard") as AnimatedSprite2D
	var copy: Sprite2D = renderer.copies.get(source.get_instance_id())
	if copy != null:
		check(copy.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF, "%s: mask copy disables double interpolation" % label)
	var displayed_transform := actors[1].render_canvas_transform(source)
	var row := roundi((displayed_transform * Vector2(0, -20)).y)
	var gold_min := displayed.get_width()
	var gold_max := -1
	var mask_min := mask.get_width()
	var mask_max := -1
	for x in displayed.get_width():
		var color := displayed.get_pixel(x, row)
		if absf(color.r - GOLD.r) < 0.02 and absf(color.g - GOLD.g) < 0.02 and absf(color.b - GOLD.b) < 0.02:
			gold_min = mini(gold_min, x)
			gold_max = maxi(gold_max, x)
		var mask_pixel := mask.get_pixel(x, row)
		if mask_pixel.a > 0.99 and mask_pixel.r == 0.0 and mask_pixel.g == 0.0:
			mask_min = mini(mask_min, x)
			mask_max = maxi(mask_max, x)
	check(gold_max > gold_min, "%s: real unit framebuffer is visible" % label)
	var copied_bounds: Rect2 = displayed_transform * Renderer._source_bounds(source, source.sprite_frames.get_frame_texture(source.animation, source.frame))
	if copy != null: copied_bounds = copy.transform * copy.get_rect()
	check(absf((gold_min + gold_max + 1) * 0.5 - copied_bounds.get_center().x) <= 1.0, "%s: mask copy transform matches actual framebuffer position" % label)
	# The mask intentionally stops rendering once no static can overlap a unit.
	# Its retained texture is then unused; compare raster pixels only when an
	# outline actually consumes that texture.
	var mask_used := copy != null
	var outline_shown := false
	for overlay in renderer.outlines.values(): outline_shown = outline_shown or overlay.visible
	mask_used = mask_used and outline_shown
	if mask_used:
		check(absi(gold_min - mask_min) <= 1 and absi(gold_max - mask_max) <= 1, "%s: mask matches rendered unit bounds (gold %d..%d, mask %d..%d)" % [label, gold_min, gold_max, mask_min, mask_max])
	var physics_x := source.get_global_transform_with_canvas().origin.x
	if absf(displayed_transform.origin.x - physics_x) > 0.5:
		intermediate_frames += 1
	var rear_source := actors[0].get_node("Billboard") as AnimatedSprite2D
	var rear_copy: Sprite2D = renderer.copies.get(rear_source.get_instance_id())
	var rear_transform := actors[0].render_canvas_transform(rear_source)
	if rear_copy != null: rear_transform = rear_copy.transform
	var centre := Vector2i((rear_transform * Vector2(0, -20)).round())
	var centre_color := displayed.get_pixelv(centre)
	var centre_depth := mask.get_pixelv(centre)
	var centre_is_gold := absf(centre_color.r - GOLD.r) < 0.02 and absf(centre_color.g - GOLD.g) < 0.02 and absf(centre_color.b - GOLD.b) < 0.02
	var uncovered := roundi(centre_depth.r * 255) + roundi(centre_depth.g * 255) * 256 == 0
	if mask_used:
		check(centre_is_gold == uncovered, "%s: mask agrees with actual foreground draw order" % label)
	# The second actor follows the same X motion below the wall. Its exposed
	# gold pixels give an independent framebuffer position oracle for the outline.
	var blue_count := 0
	for y in range(60, mini(row - 30, displayed.get_height())):
		for x in range(maxi(0, gold_min - 1), mini(displayed.get_width(), gold_max + 2)):
			var color := displayed.get_pixel(x, y)
			if color.b > color.r + 0.1:
				blue_count += 1
	if blue_count > 4:
		outline_frames += 1
		if outline_frames == 1: displayed.save_png("res://.godot/physics-interpolation-covered.png")

func _test_camera_and_projectiles() -> void:
	var camera := Camera.new()
	camera.limit_to_map_bounds = false
	viewport.add_child(camera)
	camera.set_process(false)
	check(camera.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF, "render-frame camera pan/focus bypasses physics interpolation")
	camera.focus_on(Vector2(3, 7))
	check(camera.position == Iso.world_to_screen(Vector2(3, 7)), "camera focus takes effect immediately")
	camera.free()
	var shot := ProjectileView.instantiate() as ProjectileAgent
	shot.set_script(ResetProjectile)
	viewport.add_child(shot)
	shot.set_physics_process(false)
	shot.setup(Vector2(12, 6), Vector2(20, 8), GameCatalog.get_unit(&"archer"), Enums.Team.PLAYER)
	check((shot as ResetProjectile).reset_notifications > 0, "new projectile resets interpolation after launch setup")
	check(shot.position.is_equal_approx(shot._screen_pos_for_progress(0.0)), "projectile reset uses its final launch height/position")
	shot.free()
	var remote := ProjectileView.instantiate() as ProjectileAgent
	remote.set_meta("network_replica", true)
	viewport.add_child(remote)
	check(remote.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF, "remote projectile snapshots bypass local physics interpolation")
	remote.free()
	var replica := UnitView.instantiate() as UnitAgent
	replica.def = GameCatalog.get_unit(&"militia")
	replica.set_meta("network_replica", true)
	viewport.add_child(replica)
	check(replica.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF, "remote unit snapshots bypass local physics interpolation")
	var body := replica.get_node("Billboard") as Node2D
	check(replica.render_canvas_transform(body) == body.get_global_transform_with_canvas(), "remote mask uses the snapshot transform directly")
	replica.free()
