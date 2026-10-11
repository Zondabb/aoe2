extends SceneTree

const Map := preload("res://scripts/ui/minimap.gd")
const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
var checks := 0
var failures: Array[String] = []

class Source extends Node2D:
	var hp := 100.0
	var team := Enums.Team.PLAYER
	var sim_pos := Vector2.ZERO
	func resolved_vision_radius() -> float: return 8.0

class CustomResource extends Node2D:
	var sim_pos := Vector2(2, 2)
	var block_size := Vector2.ONE
	var amount := 20.0
	var resource_type := Enums.ResourceType.GOLD
	func extract(_delta: float) -> float: return 0.0

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var map := Map.new() as Minimap
	map.size = Vector2(392, 196)
	map.map_min = Vector2(-32, -32)
	map.map_max = Vector2(32, 32)
	var state := MatchState.new()
	state.setup_defaults()
	state.fog_enabled = true
	var fog := Fog.new()
	fog.setup(-32, 32)
	state.fog = fog
	map.match_state = state
	map._fog = fog
	var entities := Node2D.new()
	map._entities = entities
	var source := Source.new()
	fog.rebuild([source])
	var resource := ResourceNode.new()
	resource.resource_type = Enums.ResourceType.WOOD
	resource.block_size_override = Vector2(4, 4)
	resource.sim_pos = Vector2(3, 0)
	entities.add_child(resource)
	var custom := CustomResource.new()
	entities.add_child(custom)
	var building := BuildingAgent.new()
	building.def = BuildingDef.new()
	building.def.footprint = Vector2(4, 4)
	building.hp = 100
	building.sim_pos = Vector2(14, 0)
	entities.add_child(building)
	var unit := UnitAgent.new()
	unit.def = UnitDef.new()
	unit.hp = 100
	unit.team = Enums.Team.AI
	unit.sim_pos = Vector2(3, 3)
	entities.add_child(unit)
	var blocker := PathBlocker.new()
	blocker.sim_pos = Vector2(4, 0)
	blocker.kind = &"water"
	blocker.add_to_group("path_blockers")
	entities.add_child(blocker)
	entities.add_child(Node2D.new())
	_compare(map, "initial typed entities and generic fixture")
	var cached: Dictionary = map._static_marker_cache[resource.get_instance_id()]
	_compare(map, "unchanged repeat")
	check(is_same(cached, map._static_marker_cache[resource.get_instance_id()]), "unchanged resource retains its marker")
	resource.sim_pos = Vector2(14, 0)
	_compare(map, "resource moves outside visibility without a fog rebuild")
	resource.block_size_override = Vector2(14, 14)
	_compare(map, "changed footprint reaches visible cells without a fog rebuild")
	resource.resource_type = Enums.ResourceType.FOOD
	_compare(map, "resource type changes the footprint and marker color")
	resource.amount = 0
	_compare(map, "resource depletion removes the live marker")
	resource.amount = 20
	resource.sim_pos = Vector2(3, 0)
	resource.set_meta("fog_memory", true)
	_compare(map, "memory proxies are excluded regardless of their script")
	resource.remove_meta("fog_memory")
	building.team = Enums.Team.AI
	_compare(map, "building ownership changes in the same fog revision")
	building.def.footprint = Vector2(14, 14)
	_compare(map, "in-place building footprint change refreshes visibility and geometry")
	building.def = BuildingDef.new()
	building.def.footprint = Vector2.ONE
	_compare(map, "building definition replacement")
	building.is_placement_ghost = true
	_compare(map, "placement ghost cannot keep a cached marker")
	building.is_placement_ghost = false
	unit.sim_pos = Vector2(22, 22)
	_compare(map, "mobile enemy visibility is always current")
	unit.hp = 0
	_compare(map, "dead unit is omitted")
	fog.memories[0][999999] = {"sim_pos":Vector2(18, 18), "minimap_kind":"resource",
		"team":null, "resource_type":Enums.ResourceType.GOLD, "kind":null, "footprint":Vector2(2, 2)}
	_compare(map, "unseen memory keeps its last observed position and color")
	fog.reset()
	_compare(map, "unready fog does not reuse old visibility")
	source.sim_pos = Vector2(16, 0)
	fog.rebuild([source])
	_compare(map, "changed visibility revision")
	map._team = Enums.Team.AI
	_compare(map, "switching perspective")
	var replacement := Fog.new()
	replacement.setup(-32, 32)
	replacement.rebuild([])
	map._fog = replacement
	state.fog = replacement
	_compare(map, "replacing the fog service")
	map._team = -1
	_compare(map, "omniscient perspective")
	map.size = Vector2(588, 294)
	_compare(map, "resizing the minimap refreshes cached polygons")
	map.map_min = Vector2(-64, -64)
	map.map_max = Vector2(64, 64)
	_compare(map, "changing map bounds refreshes cached polygons")
	var removed_id := resource.get_instance_id()
	resource.free()
	_compare(map, "freed resources are removed safely")
	check(not map._static_marker_cache.has(removed_id), "freed resource cannot remain in the marker cache")
	entities.free()
	source.free()
	map.free()
	check(checks >= 46, "all cache invalidation checks completed")
	print("MINIMAP CACHE: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _compare(map: Minimap, label: String) -> void:
	var expected := _reference_markers(map)
	map.refresh_markers()
	check(_values(map._markers) == _values(expected), label + ": live and remembered markers match the original path")
	var correct := true
	for marker in map._markers:
		correct = correct and map._marker_polygon(marker) == _reference_polygon(map, marker)
	check(correct, label + ": visible marker footprints match the original projection")

func _values(markers: Array) -> Array:
	var result: Array = []
	for marker in markers:
		result.append([marker.sim_pos, marker.footprint, marker.minimap_kind, marker.team,
			marker.resource_type, marker.get("kind"), marker.get("memory", false)])
	return result

## The pre-cache, property-based implementation is the behavioral reference.
func _reference_markers(map: Minimap) -> Array:
	var markers: Array = []
	var shown := {}
	var restricted := map.match_state.fog_enabled and map._team != -1
	for entity in map._entities.get_children():
		if not is_instance_valid(entity) or entity.is_queued_for_deletion(): continue
		if entity.has_meta("fog_memory") or entity.get("sim_pos") == null or entity.get("is_placement_ghost") == true: continue
		if restricted and (map._fog == null or not map._fog.can_see(map._team, entity)): continue
		if entity.get("hp") != null and float(entity.get("hp")) <= 0.0: continue
		if entity.has_method("extract") and float(entity.get("amount")) <= 0.0: continue
		var definition: Variant = entity.get("def")
		var kind := "building" if definition is BuildingDef else ("unit" if definition is UnitDef else (
			"resource" if entity.has_method("extract") else ("blocker" if entity.is_in_group("path_blockers") else "")))
		if kind.is_empty(): continue
		shown[entity.get_instance_id()] = true
		markers.append({"sim_pos":entity.get("sim_pos"), "footprint":Fog.footprint_of(entity),
			"minimap_kind":kind, "team":entity.get("team"), "resource_type":entity.get("resource_type"),
			"kind":entity.get("kind"), "memory":false})
	if restricted and map._fog != null:
		for id in map._fog.memories[map._team]:
			var snapshot: Dictionary = map._fog.memories[map._team][id]
			if shown.has(id) or not snapshot.has("minimap_kind"): continue
			var marker := snapshot.duplicate()
			marker.memory = true
			markers.append(marker)
	var layers := [[], [], []]
	for marker in markers:
		layers[2 if marker.minimap_kind == "unit" else (1 if marker.minimap_kind == "building" else 0)].append(marker)
	markers.clear()
	for layer in layers: markers.append_array(layer)
	return markers

func _reference_polygon(map: Minimap, marker: Dictionary) -> PackedVector2Array:
	var center: Vector2 = marker.sim_pos
	if center.x < map.map_min.x or center.y < map.map_min.y or center.x > map.map_max.x or center.y > map.map_max.y:
		return PackedVector2Array()
	if marker.minimap_kind == "unit":
		var radius := maxf(1.0, map.size.x / 196.0)
		var rect := Rect2(map.world_to_map(center) - Vector2.ONE * radius * 0.5, Vector2.ONE * radius)
		return PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	var half: Vector2 = marker.footprint * 0.5
	var minimum := (map.map_max - map.map_min) * (1.5 / maxf(map.size.x, 1.0))
	half = half.max(minimum)
	var polygon := PackedVector2Array()
	for offset in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]:
		polygon.append(map.world_to_map((center + offset).clamp(map.map_min, map.map_max)))
	return polygon
