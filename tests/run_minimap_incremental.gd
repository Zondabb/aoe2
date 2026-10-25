extends SceneTree

const Map := preload("res://scripts/ui/minimap.gd")
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const Shore := preload("res://scripts/world/shore_geometry.gd")
const Holder := preload("res://scripts/systems/fog_of_war_holder.gd")
var checks := 0
var failures: Array[String] = []

class Source extends Node2D:
	var def := UnitDef.new()
	var sim_pos := Vector2.ZERO
	var hp := 100.0
	var team := 0
	func resolved_vision_radius() -> float: return 8.0

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _run() -> void:
	_terrain()
	_mesh()
	_holder_snapshot()
	print("MINIMAP INCREMENTAL: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _terrain() -> void:
	var map := Map.new()
	var state := MatchState.new()
	state.setup_defaults()
	state.fog_enabled = true
	var fog := Fog.new()
	fog.setup_rect(Vector2(-32, -16), Vector2(32, 16))
	state.fog = fog
	map.match_state = state
	map._fog = fog
	map.map_min = Vector2(-32, -16)
	map.map_max = Vector2(32, 16)
	map._terrain_shapes = [
		{"sim_pos": Vector2.ZERO, "footprint": Vector2(24, 12), "kind": &"water", "coast": [PackedVector2Array([Vector2(-12, -6), Vector2(12, -6), Vector2(9, 6), Vector2(-8, 4)])]},
		{"sim_pos": Vector2(9, 1), "footprint": Vector2(10, 4), "kind": &"cliff", "coast": []}]
	var dims := Vector2i(64, 32)
	_compare_terrain(map, dims, "unexplored image")
	var image := map._terrain_image(dims)
	check(image == map._terrain_image(dims), "unchanged masks reuse the terrain image")
	var rng := RandomNumberGenerator.new()
	rng.seed = 481517
	for iteration in 12:
		var explored: PackedByteArray = fog.explored[0]
		var current: PackedByteArray = fog.visible_now[0]
		for change in 100:
			var index := rng.randi_range(0, explored.size() - 1)
			var visibility := rng.randi_range(0, 2)
			explored[index] = 0 if visibility == 0 else (1 if change % 2 == 0 else 255)
			current[index] = 255 if visibility == 2 else 0
		fog.explored[0] = explored
		fog.visible_now[0] = current
		_compare_terrain(map, dims, "direct mask changes %d" % iteration)
	map._terrain_shapes[0].kind = &"cliff"
	_compare_terrain(map, dims, "in-place terrain kind edit")
	map._terrain_shapes[0].footprint = Vector2(30, 18)
	_compare_terrain(map, dims, "in-place terrain footprint edit")
	map._terrain_shapes[0].kind = &"water"
	map._terrain_shapes[0].coast = [PackedVector2Array([Vector2(-12, -6), Vector2(8, -6), Vector2(3, 4)])]
	_compare_terrain(map, dims, "shoreline edit")
	map.map_min = Vector2(-40, -20)
	map.map_max = Vector2(40, 20)
	_compare_terrain(map, dims, "bounds change")
	map._team = 1
	_compare_terrain(map, dims, "perspective change hides previous team's terrain")
	map._team = -1
	_compare_terrain(map, dims, "omniscient terrain")
	map._team = 0
	_compare_terrain(map, Vector2i(80, 40), "dimension change with short masks")
	map._fog = null
	_compare_terrain(map, dims, "fog unavailable retains black unknown terrain")
	state.fog_enabled = false
	_compare_terrain(map, dims, "disabled fog")
	map._terrain_shapes.clear()
	_compare_terrain(map, Vector2i.ONE, "empty one-pixel arena")
	map.free()

func _compare_terrain(map: Minimap, dims: Vector2i, label: String) -> void:
	check(map._terrain_image(dims).get_data() == _reference_terrain(map, dims).get_data(), label + ": every RGB8 pixel matches the full raster")

## Independent original full-image paint path; no incremental cache is read.
func _reference_terrain(map: Minimap, dims: Vector2i) -> Image:
	var pixels := Image.create(dims.x, dims.y, false, Image.FORMAT_RGB8)
	var hidden := map.match_state != null and map.match_state.fog_enabled and map._team != -1
	pixels.fill(Color.BLACK if hidden else map.GRASS)
	var explored := PackedByteArray()
	var current := PackedByteArray()
	if hidden and map._fog != null:
		explored = map._fog.explored.get(map._team, PackedByteArray())
		current = map._fog.visible_now.get(map._team, PackedByteArray())
		for y in dims.y:
			for x in dims.x:
				var index := y * dims.x + x
				if index < explored.size() and explored[index] != 0:
					pixels.set_pixel(x, y, map.GRASS if index < current.size() and current[index] != 0 else map.GRASS.darkened(0.58))
	var scale := Vector2(dims) / (map.map_max - map.map_min)
	for shape in map._terrain_shapes:
		var half: Vector2 = shape.footprint * 0.5
		var first := Vector2i(((shape.sim_pos - half - map.map_min) * scale).floor()).clamp(Vector2i.ZERO, dims)
		var last := Vector2i(((shape.sim_pos + half - map.map_min) * scale).ceil()).clamp(Vector2i.ZERO, dims)
		var color := Color(0.18, 0.40, 0.60) if shape.kind == &"water" else Color(0.55, 0.53, 0.45)
		for y in range(first.y, last.y):
			for x in range(first.x, last.x):
				var index := y * dims.x + x
				if hidden and (index >= explored.size() or explored[index] == 0): continue
				if shape.kind == &"water" and not shape.get("coast", []).is_empty():
					var logical := map.map_min + (Vector2(x, y) + Vector2.ONE * 0.5) / scale
					if not Shore.contains(logical, shape.coast): continue
				var dimmed: bool = hidden and (index >= current.size() or current[index] == 0)
				pixels.set_pixel(x, y, color.darkened(0.58) if dimmed else color)
	return pixels

func _mesh() -> void:
	var map := Map.new()
	map.size = Vector2(392, 196)
	map.map_min = Vector2(-32, -32)
	map.map_max = Vector2(32, 32)
	var state := MatchState.new()
	state.setup_defaults()
	map.match_state = state
	var entities := Node2D.new()
	map._entities = entities
	var resource := ResourceNode.new()
	resource.sim_pos = Vector2(3, 3)
	entities.add_child(resource)
	var unit := UnitAgent.new()
	unit.def = UnitDef.new()
	unit.sim_pos = Vector2(3, 3)
	unit.hp = 100
	entities.add_child(unit)
	map.refresh_markers()
	var key := map._static_mesh_key
	var gpu_mesh := map._marker_mesh
	var vertices := map._static_mesh_vertices.duplicate()
	unit.sim_pos = Vector2(8, 4)
	map.refresh_markers()
	check(is_same(key, map._static_mesh_key) and vertices == map._static_mesh_vertices, "moving units reuse the complete static mesh prefix")
	check(map._marker_mesh == gpu_mesh, "moving units keep the same static mesh on the GPU")
	_check_mesh(map, "moving unit")
	resource.sim_pos = Vector2(4, 7)
	map.refresh_markers()
	check(not is_same(key, map._static_mesh_key), "moving static geometry invalidates the static mesh")
	_check_mesh(map, "resource geometry change")
	resource.resource_type = Enums.ResourceType.GOLD
	map.refresh_markers()
	_check_mesh(map, "resource color change")
	resource.amount = 0
	map.refresh_markers()
	_check_mesh(map, "resource removed from the visible prefix")
	map.size = Vector2(588, 294)
	map._rebuild_marker_mesh()
	_check_mesh(map, "resized projection")
	entities.free()
	map.free()

func _check_mesh(map: Minimap, label: String) -> void:
	var vertices := PackedVector2Array()
	var colors := PackedColorArray()
	for mesh in [map._marker_mesh, map._tail_marker_mesh]:
		if mesh == null: continue
		var actual: Array = mesh.surface_get_arrays(0)
		vertices.append_array(actual[Mesh.ARRAY_VERTEX])
		colors.append_array(actual[Mesh.ARRAY_COLOR])
	var cursor := 0
	var correct := true
	for marker in map._markers:
		for point in map._make_marker_polygon(marker):
			correct = correct and cursor < vertices.size() and vertices[cursor].is_equal_approx(point)
			var expected := map.marker_color(marker)
			correct = correct and absf(colors[cursor].r - expected.r) <= 1.0 / 255.0 and absf(colors[cursor].g - expected.g) <= 1.0 / 255.0 and absf(colors[cursor].b - expected.b) <= 1.0 / 255.0
			cursor += 1
	check(correct and cursor == vertices.size(), label + ": mesh equals fresh marker geometry and colors in the original order")

func _holder_snapshot() -> void:
	var world := Node2D.new()
	root.add_child(world)
	var entities := Node2D.new()
	entities.name = "Entities"
	world.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	var observer := Source.new()
	entities.add_child(observer)
	var resource := ResourceNode.new()
	resource.sim_pos = Vector2(4, 0)
	entities.add_child(resource)
	Holder.install(world, state, -32, 32)
	var holder: Node = world.get_meta("fog_holder")
	holder.set_physics_process(false)
	var map := Map.new()
	map.match_state = state
	map._entities = entities
	map._holder = holder
	map._fog = state.fog
	map.map_min = Vector2(-32, -32)
	map.map_max = Vector2(32, 32)
	map.size = Vector2(392, 196)
	_compare_holder(map, "current typed holder records")
	resource.sim_pos = Vector2(24, 24)
	_compare_holder(map, "moved resource rejects an old geometry snapshot")
	resource.sim_pos = Vector2(4, 0)
	resource.block_size_override = Vector2(12, 8)
	_compare_holder(map, "resized resource rejects an old geometry snapshot")
	observer.sim_pos = Vector2(-20, 0)
	state.fog.rebuild([observer])
	_compare_holder(map, "direct mask rebuild rejects an old revision")
	var added := ResourceNode.new()
	added.sim_pos = Vector2(-17, 0)
	entities.add_child(added)
	_compare_holder(map, "new entity cache invalidates old visibility records")
	holder.rebuild_now()
	_compare_holder(map, "rebuilt records reenter the snapshot path")
	resource.sim_pos = Vector2(-10, 0)
	resource.block_size_override = Vector2(12, 8)
	for resource_type in [Enums.ResourceType.WOOD, Enums.ResourceType.FOOD, Enums.ResourceType.GOLD, Enums.ResourceType.FOOD, Enums.ResourceType.WOOD]:
		resource.resource_type = resource_type
		_compare_holder(map, "resource type %d with unchanged override before fog rebuild" % resource_type)
		holder.rebuild_now()
		var record: Holder.StaticRecord = holder._records_by_id[resource.get_instance_id()]
		check(record.resource_type == resource_type and record.footprint == resource.block_size, "resource type changes invalidate the holder footprint even with the same override")
		_compare_holder(map, "resource type %d with unchanged override after fog rebuild" % resource_type)
	for override in [Vector2.ZERO, Vector2(12, 8), Vector2(4, 4), Vector2.ZERO]:
		resource.block_size_override = override
		_compare_holder(map, "resource override change before fog rebuild")
		holder.rebuild_now()
		_compare_holder(map, "resource override change after fog rebuild")
	var building := BuildingAgent.new()
	building.def = BuildingDef.new()
	building.def.id = &"house"
	building.def.max_hp = 100
	building.def.footprint = Vector2(2, 2)
	building.team = 1
	building.match_state = state
	building.sim_pos = Vector2(24, 24)
	entities.add_child(building)
	holder.rebuild_now()
	_compare_holder(map, "hidden hostile building is culled before marker allocation")
	building.team = 0
	_compare_holder(map, "converted owned building bypasses old hostile visibility")
	map._team = 1
	_compare_holder(map, "perspective change cannot reuse another team's visibility")
	map.free()
	world.free()

func _compare_holder(map: Minimap, label: String) -> void:
	var holder := map._holder
	map._holder = null
	map.refresh_markers()
	var reference := _marker_values(map)
	map._holder = holder
	map.refresh_markers()
	check(reference == _marker_values(map), label + ": direct snapshot matches independent live fog queries")

func _marker_values(map: Minimap) -> Array:
	var values: Array = []
	for marker in map._markers:
		values.append([marker.sim_pos, marker.footprint, marker.minimap_kind, marker.team,
			marker.resource_type, marker.get("kind"), marker.get("memory", false)])
	return values
