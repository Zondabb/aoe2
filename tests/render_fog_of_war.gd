extends SceneTree

## Real Compatibility renderer test, including projection, alpha and map edges.
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
var failures: Array[String] = []

class SightSource extends RefCounted:
	var team := 0
	var hp := 100.0
	var sim_pos := Vector2.ZERO
	func resolved_vision_radius() -> float:
		return 4.0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1000,600)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var world := Node2D.new()
	world.position = Vector2(500,300)
	viewport.add_child(world)
	var ground := Polygon2D.new()
	ground.polygon = PackedVector2Array([Vector2(-2000,-2000),Vector2(2000,-2000),Vector2(2000,2000),Vector2(-2000,2000)])
	ground.color = Color.WHITE
	ground.z_index = -100
	world.add_child(ground)
	var fog := Fog.new()
	fog.setup(-10,10)
	# Interior states remain exact; only their boundaries are feathered.
	for y in 20:
		for x in 20:
			fog.explored[0][y*20+x] = 255 if x >= 7 else 0
			fog.visible_now[0][y*20+x] = 255 if x >= 14 else 0
	var texture := ImageTexture.create_from_image(fog.mask_image(0))
	var overlay := Polygon2D.new()
	overlay.polygon = ground.polygon
	overlay.z_index = -50
	var material := ShaderMaterial.new()
	material.shader = preload("res://scripts/presentation/fog_overlay.gdshader")
	material.set_shader_parameter("fog_mask",texture)
	material.set_shader_parameter("logical_min",Vector2(-10,-10))
	material.set_shader_parameter("logical_span",Vector2(20,20))
	overlay.material = material
	world.add_child(overlay)
	await process_frame
	await RenderingServer.frame_post_draw
	var captured := viewport.get_texture().get_image()
	for sample in [
		{"pos":Vector2(-8,0),"value":0.0,"name":"unexplored black"},
		{"pos":Vector2(0,0),"value":0.4,"name":"explored dim"},
		{"pos":Vector2(7,0),"value":1.0,"name":"visible full"},
		{"pos":Vector2(11,0),"value":0.0,"name":"outside map black"},
	]:
		var pixel := Vector2i(world.position + Iso.world_to_screen(sample.pos))
		var actual := captured.get_pixelv(pixel)
		if absf(actual.r-sample.value) > 0.02 or absf(actual.g-sample.value) > 0.02:
			failures.append("%s: got %s" % [sample.name,actual])
	for boundary in [-3.0, 4.0]:
		var previous := -1.0
		var transition_samples := 0
		for i in 41:
			var point := Vector2(boundary - 2.0 + i * 0.1, 0)
			var value := captured.get_pixelv(Vector2i(world.position + Iso.world_to_screen(point))).r
			if value + 0.015 < previous:
				failures.append("fog feather must not reverse or ring around the boundary")
			if (boundary < 0 and value > 0.03 and value < 0.37) or (boundary > 0 and value > 0.43 and value < 0.97):
				transition_samples += 1
			previous = value
		if transition_samples < 8:
			failures.append("fog boundary must contain a continuous soft transition")
	fog.reset()
	fog.rebuild([SightSource.new()])
	var logical_before: PackedByteArray = fog.visible_now[0].duplicate()
	texture.update(fog.mask_image(0))
	await process_frame
	await RenderingServer.frame_post_draw
	captured = viewport.get_texture().get_image()
	var feather_pixels := 0
	for y in captured.get_height():
		for x in captured.get_width():
			var value := captured.get_pixel(x,y).r
			if value > 0.02 and value < 0.98:
				feather_pixels += 1
	if feather_pixels < 200:
		failures.append("circular vision must have a smooth perimeter")
	if fog.visible_now[0] != logical_before or fog.state_at(0, Vector2(5,0)) != Fog.State.UNEXPLORED:
		failures.append("visual feathering must not enlarge gameplay visibility")
	captured.save_png(ProjectSettings.globalize_path("res://.godot/fog-shader-test.png"))
	viewport.queue_free()
	await process_frame
	# Render a real match with explored terrain and normal HUD for visual review.
	root.size = Vector2i(1280,720)
	var match_scene := load("res://scenes/match_2d.tscn").instantiate() as Node
	root.add_child(match_scene)
	await process_frame
	await process_frame
	var holder: Node = match_scene.get_meta("fog_holder")
	holder.set_physics_process(false)
	var state: MatchState = match_scene.get_node("Bootstrap").match_state
	state.frozen = true
	var scout: Node2D = match_scene.get_node("Entities/PlayerVillager1")
	var original: Vector2 = scout.sim_pos
	scout.sim_pos = Vector2(-10,-20)
	holder.rebuild_now()
	scout.sim_pos = original
	holder.rebuild_now()
	var camera := match_scene.get_node("Camera2D") as Camera2D
	camera.set_process(false)
	camera.position = Iso.world_to_screen(original) + Vector2(0, 80)
	camera.zoom = Vector2.ONE*0.75
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://.godot/fog-game-player.png"))
	holder.set_debug_mode(true)
	holder.set_view(1)
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://.godot/fog-game-ai.png"))
	holder.set_view(-1)
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(ProjectSettings.globalize_path("res://.godot/fog-game-all.png"))
	match_scene.queue_free()
	await process_frame
	for failure in failures:
		push_error(failure)
	print("FOG GPU TEST: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
