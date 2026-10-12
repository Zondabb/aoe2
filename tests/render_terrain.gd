extends SceneTree

## Run with a real GL backend. Adjacent water rectangles must have the same
## original texture and footprint as one large rectangle, without grid nodes.
const BLOCKER := preload("res://scripts/entities/path_blocker.gd")
const VISUAL := preload("res://scripts/presentation/terrain_visual.gd")
const ISO := preload("res://scripts/presentation/iso_math.gd")
const MEMORY := preload("res://scripts/presentation/fog_memory.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const OCCLUSION := preload("res://scripts/presentation/unit_occlusion.gd")
const FOG_HOLDER := preload("res://scripts/systems/fog_of_war_holder.gd")
const BG := Color("526543")
var viewport: SubViewport
var entities: Node2D
var checks := 0
var failures: Array[String] = []

class FogProbe extends Node2D:
	var hp := 100.0
	var team := 0
	var sim_pos := Vector2(-10, 0)
	func resolved_vision_radius() -> float: return 3.0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func frame() -> void:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw

func region(kind: StringName, size: Vector2, sim_pos: Vector2 = Vector2.ZERO) -> PathBlocker:
	var result := BLOCKER.new() as PathBlocker
	result.kind = kind
	result.block_size = size
	result.auto_block_size = false
	result.sim_pos = sim_pos
	entities.add_child(result)
	check(result.block_half == size * 0.5, "terrain keeps the explicit logical rectangle")
	check(result.is_in_group("path_blockers") and result.is_in_group("terrain_regions"), "terrain enters navigation and map terrain groups")
	check(result.get_node("SelectionFootprint").points == VISUAL.footprint(size), "selection follows the exact rectangle without padding")
	return result

func changed_pixels(before: Image, after: Image) -> int:
	var count := 0
	for y in before.get_height():
		for x in before.get_width():
			if not before.get_pixel(x, y).is_equal_approx(after.get_pixel(x, y)): count += 1
	return count

func _run() -> void:
	check(DisplayServer.get_name() != "headless", "terrain render checks require a graphical backend")
	if DisplayServer.get_name() == "headless":
		quit(1)
		return
	viewport = SubViewport.new()
	viewport.size = Vector2i(1100, 750)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var ground := ColorRect.new()
	ground.size = viewport.size
	ground.color = BG
	ground.z_index = -100
	viewport.add_child(ground)
	entities = Node2D.new()
	entities.position = Vector2(550, 390)
	entities.y_sort_enabled = true
	viewport.add_child(entities)
	var water := region(&"water", Vector2(16, 12))
	var surface := water.get_node("Billboard") as Polygon2D
	check(surface.texture != null, "water uses the imported original terrain texture")
	check(surface.polygon == VISUAL.footprint(water.block_size), "water occupies exactly its blocking footprint")
	check(surface.z_index == -99, "water stays on the ground layer")
	check(water.get_child_count() == 2, "large water area uses one surface and one selection node")
	check(surface.texture_repeat == CanvasItem.TEXTURE_REPEAT_ENABLED, "water repeats texture without stretching it over a lake")
	await frame()
	var single := viewport.get_texture().get_image()
	check(single.get_pixel(550, 390).b > single.get_pixel(550, 390).r, "native framebuffer has visible blue water")
	var outside := Vector2i(entities.position + ISO.world_to_screen(Vector2(8.5, 0)))
	check(single.get_pixelv(outside).is_equal_approx(BG), "water does not spill beyond the logical shore")
	water.visible = false
	var left := region(&"water", Vector2(8, 12), Vector2(-4, 0))
	var right := region(&"water", Vector2(8, 12), Vector2(4, 0))
	await frame()
	var adjoining := viewport.get_texture().get_image()
	check(changed_pixels(single, adjoining) < 100, "two adjacent areas preserve the same seamless world-anchored water image")
	adjoining.save_png("res://.godot/terrain-water.png")
	left.free()
	right.free()
	water.free()
	var cliff := region(&"cliff", Vector2(16, 4))
	check(cliff.get_child_count() == 4, "cliff area uses three surfaces and one selection node")
	var plateau := cliff.get_node("Billboard") as Polygon2D
	check(plateau.z_index == -99, "rock plateau remains below units")
	var lift := Vector2(0, -VISUAL.CLIFF_HEIGHT)
	var base := VISUAL.footprint(cliff.block_size)
	for i in 4:
		check(plateau.polygon[i].is_equal_approx(base[i] + lift), "rock plateau has a visible height above its exact ground footprint")
	for label in ["Body", "Fallback"]:
		var wall := cliff.get_node(label) as Polygon2D
		check(wall.texture != null and wall.texture.resource_path == VISUAL.FACE, "cliff wall uses original SLP rock-face pixels")
		check(wall.polygon.size() == 4 and wall.z_index == 0, "cliff wall supplies a solid four-corner foreground edge")
	cliff.set_selected(true)
	check(cliff.get_node("SelectionFootprint").visible, "map editor can select terrain")
	cliff.set_selected(false)
	await frame()
	var cliffs := viewport.get_texture().get_image()
	cliffs.save_png("res://.godot/terrain-cliff.png")
	check(cliffs.get_pixel(550, 390).is_equal_approx(BG) == false, "native framebuffer displays the raised rock region")
	# Static fog memories must reproduce textured ground and cliff walls exactly.
	var parts := MEMORY.capture(cliff)
	check(parts.size() == 3, "cliff fog memory captures all three textured surfaces")
	var view := MEMORY.make_view({"position":cliff.position, "parts":parts})
	view.modulate = Color.WHITE
	entities.add_child(view)
	cliff.visible = false
	await frame()
	check(changed_pixels(cliffs, viewport.get_texture().get_image()) == 0, "textured cliff memory preserves the original framebuffer")
	view.free()
	cliff.visible = true
	var worker := UNIT.instantiate() as UnitAgent
	worker.def = GameCatalog.get_unit(&"villager")
	# Rendering fixture only: put the idle actor under the wall to exercise its
	# alpha/depth mask. Runtime navigation prevents reaching this blocked area.
	worker.sim_pos = Vector2(-3, 0.8)
	entities.add_child(worker)
	worker.set_physics_process(false)
	await frame()
	var renderer: Node = viewport.get_meta(OCCLUSION.KEY)
	check(renderer.get("_static_actors").has(cliff.get_instance_id()), "cliff enters the static occlusion registry")
	renderer.enabled = false
	await frame()
	var plain := viewport.get_texture().get_image()
	renderer.enabled = true
	await frame()
	var outlined := viewport.get_texture().get_image()
	check(changed_pixels(plain, outlined) > 2, "foreground cliff wall outlines a covered unit")
	outlined.save_png("res://.godot/terrain-cliff-unit.png")
	worker.free()
	cliff.free()
	entities.free()
	await _fog_clipping()
	viewport.free()
	print("Terrain rendering: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _fog_clipping() -> void:
	# Keep match-local coordinates distinct from the viewport offset and test
	# an actual holder, including its materials / memory / debug-view lifecycle.
	var stage := Node2D.new()
	stage.position = Vector2(550, 390)
	viewport.add_child(stage)
	entities = Node2D.new()
	entities.name = "Entities"
	entities.y_sort_enabled = true
	stage.add_child(entities)
	var long_cliff := region(&"cliff", Vector2(32, 4))
	var probe := FogProbe.new()
	entities.add_child(probe)
	var state := MatchState.new()
	state.setup_defaults()
	FOG_HOLDER.install_rect(stage, state, Vector2(-32, -24), Vector2(32, 24), -1)
	var holder: Node = stage.get_meta("fog_holder")
	await frame()
	var all_view := viewport.get_texture().get_image()
	var near := Vector2i(stage.position + ISO.world_to_screen(Vector2(-10, 2)) + Vector2(0, -18))
	var far := Vector2i(stage.position + ISO.world_to_screen(Vector2(10, 2)) + Vector2(0, -18))
	var near_original := all_view.get_pixelv(near)
	check(near_original.r > 0.01 and all_view.get_pixelv(far).r > 0.01, "full-view fixture contains both near and far cliff wall pixels")
	holder.set_view(0)
	await frame()
	var partial := viewport.get_texture().get_image()
	check(long_cliff.visible, "one visible part keeps the long cliff simulation visual active")
	check(partial.get_pixelv(near).r > 0.01, "the wall fragment inside current vision remains visible")
	check(partial.get_pixelv(far).r < 0.001 and partial.get_pixelv(far).g < 0.001 and partial.get_pixelv(far).b < 0.001, "the far wall cannot leak into unexplored black terrain")
	for label in ["Body", "Fallback"]:
		var material := long_cliff.get_node(label).material as ShaderMaterial
		check(material.get_shader_parameter("fog_mask") == holder.get("_texture"), "walls share the actual fog holder's live data texture")
		check(material.get_shader_parameter("fog_enabled") and not material.get_shader_parameter("is_memory"), "live wall material has fragment fog clipping enabled")
	partial.save_png("res://.godot/terrain-cliff-fog-visible.png")
	probe.sim_pos = Vector2(-26, -18)
	holder.rebuild_now()
	await frame()
	check(not long_cliff.visible, "moving vision away switches the cliff to memory")
	var memory_image := viewport.get_texture().get_image()
	var remembered := memory_image.get_pixelv(near)
	check(absf(remembered.r - near_original.r * 0.4) <= 2.0 / 255.0 and absf(remembered.g - near_original.g * 0.4) <= 2.0 / 255.0 and absf(remembered.b - near_original.b * 0.4) <= 2.0 / 255.0, "remembered wall receives the 0.4 memory tint exactly once")
	check(memory_image.get_pixelv(far).r < 0.001 and memory_image.get_pixelv(far).g < 0.001 and memory_image.get_pixelv(far).b < 0.001, "a remembered cliff still clips its unexplored far wall")
	memory_image.save_png("res://.godot/terrain-cliff-fog-memory.png")
	probe.sim_pos = Vector2(10, 0)
	holder.rebuild_now()
	await frame()
	var far_view := viewport.get_texture().get_image()
	check(long_cliff.visible and far_view.get_pixelv(far).is_equal_approx(all_view.get_pixelv(far)), "newly exploring the far end shows its original wall color")
	var near_history := far_view.get_pixelv(near)
	check(absf(near_history.r - near_original.r * 0.4) <= 2.0 / 255.0 and absf(near_history.g - near_original.g * 0.4) <= 2.0 / 255.0 and absf(near_history.b - near_original.b * 0.4) <= 2.0 / 255.0, "a live cliff shades its previously explored invisible near wall")
	probe.sim_pos = Vector2(-10, 0)
	holder.rebuild_now()
	await frame()
	var near_view := viewport.get_texture().get_image()
	var far_history := near_view.get_pixelv(far)
	var far_original := all_view.get_pixelv(far)
	check(absf(far_history.r - far_original.r * 0.4) <= 2.0 / 255.0 and absf(far_history.g - far_original.g * 0.4) <= 2.0 / 255.0 and absf(far_history.b - far_original.b * 0.4) <= 2.0 / 255.0, "a live cliff shades its previously explored invisible far wall")
	var middle := Vector2i(stage.position + ISO.world_to_screen(Vector2(0, 2)) + Vector2(0, -18))
	check(near_view.get_pixelv(middle).r < 0.001 and near_view.get_pixelv(middle).g < 0.001 and near_view.get_pixelv(middle).b < 0.001, "exploring both cliff ends still leaves the unseen middle wall black")
	near_view.save_png("res://.godot/terrain-cliff-fog-partial-history.png")
	holder.set_view(-1)
	await frame()
	var restored := viewport.get_texture().get_image()
	check(changed_pixels(all_view, restored) == 0, "switching to all-view immediately restores the entire original cliff framebuffer")
	holder.set_view(1)
	await frame()
	var opponent := viewport.get_texture().get_image()
	check(opponent.get_pixelv(near).r < 0.001 and opponent.get_pixelv(far).r < 0.001, "the other team's unexplored view reveals no cliff wall")
	stage.free()
