extends SceneTree

const Holder := preload("res://scripts/systems/fog_of_war_holder.gd")
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
var checks := 0
var failures: Array[String] = []

class Source extends Node2D:
	var hp := 100.0
	var team := 0
	var sim_pos := Vector2.ZERO
	func resolved_vision_radius() -> float: return 8.0

class CountedResource extends ResourceNode:
	var deselections := 0
	func set_selected(selected: bool) -> void:
		if not selected: deselections += 1
		super(selected)

class StaticSource extends Source:
	var def := BuildingDef.new()

func _initialize() -> void: call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func _material(snapshot: Dictionary) -> ShaderMaterial:
	for part in snapshot.parts:
		if part.get("material") is ShaderMaterial: return part.material
	return null

func _billboard_part(snapshot: Dictionary) -> Dictionary:
	for part in snapshot.parts:
		if part.get("material") is ShaderMaterial: return part
	return {}

func _run() -> void:
	_test_small_rect_queries()
	var world := Node2D.new()
	root.add_child(world)
	var entities := Node2D.new()
	entities.name = "Entities"
	world.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	var observer := Source.new()
	entities.add_child(observer)
	var enemy := Source.new()
	enemy.team = 1
	enemy.sim_pos = Vector2(4, 0)
	entities.add_child(enemy)
	var resource := CountedResource.new()
	resource.resource_type = Enums.ResourceType.WOOD
	resource.sim_pos = Vector2(3, 0)
	entities.add_child(resource)
	var billboard: Sprite2D = resource.get_node("Billboard")
	var shader := Shader.new()
	shader.code = "shader_type canvas_item; uniform vec4 tint : source_color = vec4(1.0); void fragment() { COLOR = texture(TEXTURE, UV) * tint; }"
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("tint", Color.WHITE)
	billboard.material = material
	Holder.install(world, state, -32, 32)
	var holder: Node = world.get_meta("fog_holder")
	holder.set_physics_process(false)
	var key := resource.get_instance_id()
	var snapshot: Dictionary = holder.fog.memories[0][key]
	check(holder.entity_visible_for(0, resource, resource.sim_pos, resource.block_size), "visible static geometry reuses team visibility")
	resource.sim_pos = Vector2(24, 24)
	holder._apply_visibility()
	check(not holder.entity_visible_for(0, resource, resource.sim_pos, resource.block_size), "record refresh cannot reuse visibility from an old static position")
	resource.sim_pos = Vector2(3, 0)
	holder.rebuild_now()
	observer.sim_pos = Vector2(-20, -20)
	holder.fog.rebuild([observer])
	check(not holder.entity_visible_for(0, resource, resource.sim_pos, resource.block_size), "direct fog rebuild invalidates cached visibility by revision")
	observer.sim_pos = Vector2.ZERO
	holder.rebuild_now()
	var converted := StaticSource.new()
	converted.team = 1
	converted.sim_pos = Vector2(24, 24)
	entities.add_child(converted)
	holder.rebuild_now()
	check(not holder.entity_visible_for(0, converted, converted.sim_pos, converted.def.footprint), "hidden hostile building remains hidden to the requested team")
	converted.team = 0
	check(holder.entity_visible_for(0, converted, converted.sim_pos, converted.def.footprint), "newly owned living buildings bypass a stale hostile visibility entry")
	holder._apply_visibility()
	check(converted.visible, "static display ownership refreshes without a cache reconstruction")
	converted.free()
	holder.rebuild_now()
	snapshot = holder.fog.memories[0][key]
	var copied := _material(snapshot)
	check(copied != material, "visible resource remembers an independent material")
	for tick in 10: holder.rebuild_now()
	check(_material(holder.fog.memories[0][key]) == copied, "unchanged visible static art reuses its material snapshot")
	material.set_shader_parameter("tint", Color.RED)
	holder.rebuild_now()
	check(_material(holder.fog.memories[0][key]).get_shader_parameter("tint") == Color.RED, "visible shader uniform changes invalidate the cached snapshot")
	billboard.modulate = Color(0.2, 0.4, 0.8)
	billboard.position = Vector2(2, 3)
	holder.rebuild_now()
	check(_billboard_part(holder.fog.memories[0][key]).color == billboard.modulate, "visible color changes invalidate a resource snapshot")
	check(_billboard_part(holder.fog.memories[0][key]).transform == billboard.transform, "visible local transform changes invalidate a resource snapshot")
	billboard.z_index = 7
	holder.rebuild_now()
	check(_billboard_part(holder.fog.memories[0][key]).z == 7, "visible drawing-order changes invalidate a resource snapshot")
	var fallback := Polygon2D.new()
	fallback.name = "Fallback"
	fallback.polygon = PackedVector2Array([Vector2.ZERO, Vector2(2, 0), Vector2(0, 2)])
	fallback.color = Color.RED
	resource.add_child(fallback)
	holder.rebuild_now()
	fallback.color = Color.GREEN
	holder.rebuild_now()
	var polygon_color := Color.WHITE
	for part in holder.fog.memories[0][key].parts:
		if part.has("polygon"): polygon_color = part.color
	check(polygon_color == Color.GREEN, "fallback polygon color changes invalidate a resource snapshot")
	observer.sim_pos = Vector2(-20, -20)
	holder.rebuild_now()
	check(not resource.visible and holder.get("_memory_views").has(key), "hidden known resource uses a memory proxy")
	var proxy: Node2D = holder.get("_memory_views")[key]
	var proxy_id := proxy.get_instance_id()
	var remembered_color: Color = _billboard_part(holder.fog.memories[0][key]).color
	billboard.modulate = Color.BLUE
	material.set_shader_parameter("tint", Color.GREEN)
	holder.rebuild_now()
	check(_billboard_part(holder.fog.memories[0][key]).color == remembered_color and _material(holder.fog.memories[0][key]).get_shader_parameter("tint") == Color.RED, "hidden visual changes never replace last observed art")
	observer.sim_pos = Vector2.ZERO
	holder.rebuild_now()
	check(holder.get("_memory_views")[key].get_instance_id() == proxy_id and not proxy.visible, "reobserving retains and hides the existing proxy")
	check(_billboard_part(holder.fog.memories[0][key]).color == Color.BLUE, "reobservation captures previously hidden color changes")
	observer.sim_pos = Vector2(-20, -20)
	holder.rebuild_now()
	check(holder.get("_memory_views")[key].get_instance_id() == proxy_id and proxy.visible, "losing sight reuses the same proxy")
	var shown_color := Color.WHITE
	for child in proxy.get_children():
		if child.material is ShaderMaterial: shown_color = child.modulate
	check(shown_color == Color.BLUE, "reused proxy updates to the newest observed snapshot")
	var calls := resource.deselections
	state.frozen = true
	for tick in 120: holder._physics_process(1.0 / 60.0)
	check(resource.deselections == calls, "frozen idle frames do not repeatedly deselect hidden resources")
	enemy.sim_pos = Vector2(-20, -20)
	# This coordinate is currently visible to the player's stationary observer.
	holder._physics_process(1.0 / 60.0)
	check(enemy.visible, "dynamic enemy entering a visible cell is shown between rebuilds")
	enemy.sim_pos = Vector2(24, 24)
	holder._physics_process(1.0 / 60.0)
	check(not enemy.visible, "dynamic enemy leaving visibility is hidden in the same frame")
	resource.extract(1000)
	holder.rebuild_now()
	check(holder.fog.memories[0].has(key), "hidden depletion keeps the last observed resource")
	holder.set_view(-1)
	check(not resource.visible and holder.get("_memory_views").is_empty(), "omniscient view never revives depleted resources")
	holder.set_view(0)
	observer.sim_pos = Vector2.ZERO
	holder.rebuild_now()
	check(not holder.fog.memories[0].has(key) and not holder.get("_memory_views").has(key), "fully observing depletion retires its memory and proxy")
	var newly_added := CountedResource.new()
	newly_added.sim_pos = Vector2(4, 0)
	entities.add_child(newly_added)
	check(holder.entity_visible_for(0, newly_added, newly_added.sim_pos, newly_added.block_size), "new entities query current fog before static caches observe them")
	check(holder.live_entities().all(func(node): return not node.has_meta("fog_memory")), "read-only entity list excludes all memory proxies")
	holder.rebuild_now()
	check(newly_added.visible and holder.fog.memories[0].has(newly_added.get_instance_id()), "new static entities enter visibility and memory caches")
	var new_key := newly_added.get_instance_id()
	var freed_reference: Variant = newly_added
	newly_added.free()
	check(not holder.entity_visible_for(0, freed_reference, Vector2.ZERO, Vector2.ZERO), "public visibility lookup safely rejects previously freed objects")
	holder.rebuild_now()
	check(not holder.fog.memories[0].has(new_key), "observed removal invalidates an old static memory")
	world.free()
	await process_frame
	print("FOG CACHE: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_small_rect_queries() -> void:
	var fog := Fog.new()
	fog.setup_rect(Vector2.ZERO, Vector2(8, 9))
	var random := RandomNumberGenerator.new()
	random.seed = 61587
	for trial in 16:
		var mask := PackedByteArray()
		mask.resize(72)
		for index in mask.size(): mask[index] = 255 if random.randf() > 0.6 else 0
		fog.visible_now[0] = mask
		var matches := true
		for width in range(1, 5):
			for height in range(1, 5):
				for origin in [Vector2i.ZERO, Vector2i(2, 3), Vector2i(8-width, 9-height)]:
					var any_seen := false
					var all_seen := true
					for y in range(origin.y, origin.y + height):
						for x in range(origin.x, origin.x + width):
							any_seen = any_seen or mask[y * 8 + x] != 0
							all_seen = all_seen and mask[y * 8 + x] != 0
					var rect := Rect2i(origin, Vector2i(width, height))
					matches = matches and fog.rect_visible(0, rect) == any_seen and fog.rect_visible(0, rect, true) == all_seen
		check(matches, "optimized tiny footprints and larger rectangles match independent mask oracle")
	check(not fog.rect_visible(0, Rect2i(-1, -1, 0, 0)) and not fog.rect_visible(8, Rect2i(0, 0, 1, 1)), "invalid footprint and team stay hidden")
