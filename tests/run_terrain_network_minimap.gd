extends SceneTree

const Runtime := preload("res://scripts/network/network_match.gd")
const Transport := preload("res://scripts/network/network_session.gd")
const Holder := preload("res://scripts/systems/fog_of_war_holder.gd")
const Visual := preload("res://scripts/presentation/terrain_visual.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _rgb8_matches(actual: Color, expected: Color) -> bool:
	return absf(actual.r - expected.r) <= 1.0 / 255.0 and absf(actual.g - expected.g) <= 1.0 / 255.0 and absf(actual.b - expected.b) <= 1.0 / 255.0

func _runtime(authority: bool) -> Node:
	var world := Node2D.new()
	root.add_child(world)
	var runtime := Runtime.new()
	runtime.entities = Node2D.new()
	runtime.entities.name = "Entities"
	world.add_child(runtime.entities)
	runtime.match_state = MatchState.new()
	runtime.match_state.setup_defaults()
	runtime.is_host = authority
	runtime.local_team = 0 if authority else 1
	world.add_child(runtime)
	runtime.set_process(false)
	var holder := NavServiceHolder.new()
	holder.name = "Nav"
	world.add_child(holder)
	holder.setup_rect(Vector2i(-60, -60), Vector2i(60, 60))
	holder.set_process(false)
	return runtime

func _run() -> void:
	await _network()
	_minimap()
	_preview()
	print("Terrain network/minimap: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _network() -> void:
	var host := _runtime(true)
	var guest := _runtime(false)
	var host_nav := host.get_parent().get_node("Nav") as NavServiceHolder
	var guest_nav := guest.get_parent().get_node("Nav") as NavServiceHolder
	var record := {"id":"lake", "type":"terrain", "terrain_id":"water", "pos":[-20, 0], "block_size":[8.0, 12.0]}
	var lake := MapLoader.spawn_entity(record, host.entities, host.match_state) as PathBlocker
	var id: int = host.entity_id(lake)
	var packet: Dictionary = JSON.parse_string(JSON.stringify(host.capture_snapshot()))
	check(packet.entities.size() == 1 and packet.entities[0].kind == "terrain", "wire snapshot includes static terrain")
	check(not packet.entities[0].has("team") and not packet.entities[0].has("hp"), "neutral terrain has no economy or health fields")
	check(guest.apply_snapshot(packet, 1), "terrain survives JSON transport and initial replica spawn")
	await process_frame
	var copy := guest._resolve(id) as PathBlocker
	check(copy != null and copy.kind == &"water" and copy.block_size == Vector2(8, 12), "replica preserves kind and rectangular dimensions")
	check(copy.is_in_group("terrain_regions") and copy.block_half == Vector2(4, 6), "replica joins static navigation/collision groups")
	check(guest_nav.nav.is_world_solid(Vector2(-20, 0)), "client navigation blocks replicated lake")
	check(not host_nav.nav.is_world_solid(Vector2(20, 0)), "client geometry does not affect another match holder")
	var surface_id := copy.get_node("Billboard").get_instance_id()
	guest_nav.rebuild_from_scene()
	check(guest.apply_snapshot(packet, 2), "repeated terrain snapshot is accepted")
	check(copy.get_node("Billboard").get_instance_id() == surface_id and not guest_nav._static_dirty, "unchanged terrain reuses its visual nodes and navigation cache")
	var original_id := copy.get_instance_id()
	var updated: Dictionary = packet.duplicate(true)
	updated.entities[0].terrain_id = "cliff"
	updated.entities[0].pos = [20.0, 4.0]
	updated.entities[0].block_size = [10.0, 4.0]
	check(guest.apply_snapshot(updated, 3), "existing terrain can change position, size and kind")
	check(copy.get_instance_id() == original_id and copy.get_child_count() == 4, "terrain edit replaces surfaces without duplicate nodes or entity replacement")
	check(copy.get_node("SelectionFootprint").points == Visual.footprint(Vector2(10, 4)), "replicated resize refreshes selection footprint")
	check(copy.get_node("Billboard").uv == Visual.ground_uv(Vector2(10, 4), Vector2(20, 4)), "replicated move refreshes world-anchored texture coordinates")
	check(guest_nav.query_static_blockers(Vector2(20, 4), Vector2(20, 4), 0.1).has(copy), "collision broad phase refreshes immediately after terrain move")
	check(not guest_nav.query_static_blockers(Vector2(-20, 0), Vector2(-20, 0), 0.1).has(copy), "old terrain position leaves no cached collision blocker")
	check(guest_nav.nav.is_world_solid(Vector2(20, 4)) and not guest_nav.nav.is_world_solid(Vector2(-20, 0)), "client navigation reflects moved terrain")
	updated.entities[0].pos = [20.2, 4.0]
	check(guest.apply_snapshot(updated, 4), "position-only edit is accepted")
	check(copy.get_node("Billboard").uv == Visual.ground_uv(Vector2(10, 4), Vector2(20.2, 4)), "position-only edit keeps water/rock texture anchored in world")
	guest_nav.query_static_blockers(Vector2(20, 4), Vector2(20, 4), 0.1)
	check(guest_nav._static_records[original_id].center == Vector2(20.2, 4), "subcell edit refreshes collision geometry")
	for invalid_size in [[0,4], [-1,4], [129,4], [4,129], [NAN,4], [INF,4], [true,4], [4], "4"]:
		var invalid: Dictionary = updated.duplicate(true)
		invalid.entities[0].block_size = invalid_size
		check(not guest.apply_snapshot(invalid, 5) and copy.sim_pos == Vector2(20.2,4), "malformed terrain size is rejected atomically: %s" % str(invalid_size))
	for field in ["terrain_id", "pos"]:
		var invalid: Dictionary = updated.duplicate(true)
		invalid.entities[0][field] = "sea" if field == "terrain_id" else [59, 4]
		check(not guest.apply_snapshot(invalid, 5) and copy.get_child_count() == 4, "unknown kind or out-of-bounds terrain does not mutate existing surfaces")
	updated.entities[0].terrain_id = "water"
	check(guest.apply_snapshot(updated, 5) and copy.get_child_count() == 2, "cliff-to-water edit removes both obsolete front walls")
	var empty: Dictionary = updated.duplicate(true)
	empty.entities.clear()
	check(guest.apply_snapshot(empty, 6) and guest._resolve(id) == null, "terrain deletion removes replica")
	await process_frame
	check(not guest_nav.nav.is_world_solid(Vector2(20, 4)), "terrain deletion restores client land")
	check(not guest.apply_snapshot(packet, 1), "stale snapshot cannot restore deleted terrain")
	host.get_parent().free()
	guest.get_parent().free()
	# The largest shipped map still fits the existing transport budget.
	var full := _runtime(true)
	full.map_bounds = MapData.bounds(DefaultMapGenerator.generate())
	MapLoader.spawn_entities(DefaultMapGenerator.generate(), full.entities, full.match_state, true)
	var payload := JSON.stringify({"type":"snapshot", "seq":1, "state":full.capture_snapshot()}).to_utf8_buffer()
	check(payload.size() <= Transport.MAX_MESSAGE_BYTES, "default map plus terrain fits 512 KiB snapshot budget (%d bytes)" % payload.size())
	full.get_parent().free()

func _minimap() -> void:
	var world := Node2D.new()
	root.add_child(world)
	var entities := Node2D.new()
	world.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	state.fog_enabled = true
	state.fog = FogOfWarService.new()
	state.fog.setup_rect(Vector2(-20, -10), Vector2(20, 10))
	state.fog.ready = true
	var lake := MapLoader.spawn_entity({"id":"lake", "type":"terrain", "terrain_id":"water", "pos":[0,0], "block_size":[20,8]}, entities, state) as PathBlocker
	var map := Minimap.new()
	map.match_state = state
	map._fog = state.fog
	map._entities = entities
	map.map_min = Vector2(-20,-10)
	map.map_max = Vector2(20,10)
	map.size = Vector2(392,196)
	world.add_child(map)
	map.set_process(false)
	var explored: PackedByteArray = state.fog.explored[0]
	var current: PackedByteArray = state.fog.visible_now[0]
	var seen: Vector2i = state.fog.cell_at(Vector2(-5,0))
	var remembered: Vector2i = state.fog.cell_at(Vector2(5,0))
	var dry_corner: Vector2i = state.fog.cell_at(Vector2(9,3))
	explored[seen.y * 40 + seen.x] = 1
	current[seen.y * 40 + seen.x] = 1
	explored[remembered.y * 40 + remembered.x] = 1
	explored[dry_corner.y * 40 + dry_corner.x] = 1
	current[dry_corner.y * 40 + dry_corner.x] = 1
	state.fog.explored[0] = explored
	state.fog.visible_now[0] = current
	var holder := Holder.new()
	holder.entities = entities
	holder.match_state = state
	holder.fog = state.fog
	holder._update_memories([])
	check(state.fog.memories[0][lake.get_instance_id()].terrain_region == true, "actual fog snapshots tag terrain for masked minimap drawing")
	map.refresh_markers()
	check(map._markers.is_empty() and map._terrain_shapes.size() == 1, "large lake is represented beneath fog rather than a visible marker quad")
	var pixels := map._terrain_image(Vector2i(40,20))
	check(_rgb8_matches(pixels.get_pixelv(seen), Color(0.18,0.4,0.6)), "visible lake cell is blue")
	check(_rgb8_matches(pixels.get_pixelv(dry_corner), map.GRASS), "minimap keeps the walkable corner outside the irregular coast as grass")
	var observed_coast: Array = map._terrain_shapes[0].coast.duplicate(true)
	check(not observed_coast.is_empty() and observed_coast == lake.get_water_contours(), "minimap uses the actual observed water outline")
	check(pixels.get_pixelv(remembered).b > 0 and pixels.get_pixelv(remembered).b < pixels.get_pixelv(seen).b, "remembered lake cell is dimmed")
	var leaked := 0
	for y in 20:
		for x in 40:
			if explored[y*40+x] == 0 and pixels.get_pixel(x,y) != Color.BLACK: leaked += 1
	check(leaked == 0, "seeing a lake edge leaves all unexplored cells black")
	current.fill(0)
	state.fog.visible_now[0] = current
	lake.sim_pos = Vector2(8,4)
	lake.block_size = Vector2(2,2)
	lake._setup_visual()
	map.refresh_markers()
	check(map._terrain_shapes[0].sim_pos == Vector2.ZERO and map._terrain_shapes[0].footprint == Vector2(20,8), "unseen terrain edits retain the last observed geometry")
	check(map._terrain_shapes[0].coast == observed_coast and map._terrain_shapes[0].coast != lake.get_water_contours(), "unseen terrain edits cannot replace the remembered minimap shoreline")
	lake.free()
	map.refresh_markers()
	check(map._markers.is_empty() and map._terrain_shapes.size() == 1, "unseen terrain removal preserves masked memory without marker leakage")
	state.fog_enabled = false
	map._fog = null
	map.refresh_markers()
	map._sync_terrain()
	check(map._terrain.get_width() == 1 and map._terrain.get_height() == 1, "empty non-fog arena retains one-pixel ground texture")
	var cliff := MapLoader.spawn_entity({"id":"cliff", "type":"terrain", "terrain_id":"cliff", "pos":[0,0], "block_size":[10,4]}, entities, state) as PathBlocker
	map.refresh_markers()
	map._sync_terrain()
	check(map._terrain.get_width() == 40 and map._terrain.get_height() == 20, "non-fog rectangular arena rasterizes terrain at useful resolution")
	check(_rgb8_matches(map._terrain_image(Vector2i(40,20)).get_pixel(20,10), Color(0.55,0.53,0.45)), "non-fog cliff has terrain color rather than enemy color")
	var cache: Array = map._terrain_key.duplicate()
	map.refresh_markers()
	check(map._terrain_key == cache, "unchanged terrain does not invalidate minimap pixels on every marker refresh")
	cliff.free()
	var legacy := PathBlocker.new()
	legacy.kind = &"water"
	legacy.sim_pos = Vector2(-14,6)
	entities.add_child(legacy)
	map.refresh_markers()
	check(map._markers.size() == 1 and map._markers[0].minimap_kind == "blocker", "legacy arena blockers keep their old marker behavior")
	holder.free()
	world.free()

func _preview() -> void:
	var preview := load("res://scripts/ui/map_preview.gd").new() as Control
	preview.size = Vector2(360,200)
	var bounds := Rect2(-20,-10,40,20)
	check(preview._preview_point(bounds.position, bounds) == Vector2(180,12), "menu preview maps rectangular north corner")
	check(preview._preview_point(bounds.end, bounds) == Vector2(180,188), "menu preview maps rectangular south corner")
	check(preview._preview_point(Vector2.ZERO, bounds) == Vector2(180,100), "menu preview maps terrain/world center consistently")
	preview.free()
