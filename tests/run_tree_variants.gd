extends SceneTree

const Trees := preload("res://scripts/presentation/tree_variants.gd")
const Sprites := preload("res://scripts/presentation/sprite_catalog.gd")
const Runtime := preload("res://scripts/network/network_match.gd")
const Simulation := preload("res://scripts/network/lockstep_simulation.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("TREES: " + label)

func appearance(tree: Node) -> Array:
	var sprite := tree.get_node("Billboard") as Sprite2D
	var atlas := sprite.texture as AtlasTexture
	return [atlas.atlas.resource_path, atlas.region, sprite.offset, sprite.scale]

func _runtime(host: bool) -> Node:
	var world := Node2D.new()
	root.add_child(world)
	var runtime := Runtime.new()
	runtime.entities = Node2D.new()
	world.add_child(runtime.entities)
	runtime.match_state = MatchState.new()
	runtime.match_state.setup_defaults()
	runtime.map_bounds = Rect2(-240, -240, 480, 480)
	runtime.is_host = host
	world.add_child(runtime)
	runtime.set_process(false)
	runtime.set_physics_process(false)
	runtime.simulation = Simulation.new()
	runtime.simulation.setup(runtime)
	return runtime

func _run() -> void:
	# Pin selections so an incidental hash/table edit cannot silently change
	# every saved forest's appearance in a later build.
	for sample in [[Vector2.ZERO, "tree_deciduous", 11], [Vector2(-120, -188), "tree_bamboo", 1], [Vector2(64, 96), "tree_deciduous", 7], [Vector2(-17.125, 22.75), "tree_deciduous", 13]]:
		check(Trees.at_position(sample[0]) == {"base": "res://assets/sprites/resources/" + sample[1], "frame": sample[2]}, "stable coordinate-to-art fixture")
	var used := {}
	seed(1977)
	var expected_random := randi()
	seed(1977)
	for x in range(-240, 241, 4):
		for y in range(-240, 241, 4):
			var pos := Vector2(x, y)
			var variant := Trees.at_position(pos)
			used[str(variant)] = true
			if variant != Trees.at_position(-pos):
				check(false, "mirrored positions retain the same tree")
	check(randi() == expected_random, "tree selection does not consume the simulation RNG")
	check(used.size() == 35, "all 35 leafy shapes can appear")
	for family in Trees.BASES.size():
		var base: String = "res://assets/sprites/resources/" + Trees.BASES[family]
		check(Sprites.sheet_paths_exist(base), "imported atlas exists: " + base)
		var meta := Sprites.load_meta(base)
		check(int(meta.get("frame_count", 0)) == [14, 9, 13, 4][family], "original shape count preserved")
		for index: int in Trees.FRAMES[family]:
			check(index < meta.frame_count and Sprites.hotspot_at_index(meta, index).y > 0, "each selected frame has its own ground hotspot")
	var host := _runtime(true)
	var guest := _runtime(false)
	var spectator := _runtime(false)
	spectator.spectator = true
	spectator.local_team = -1
	var forest: Array = DefaultMapGenerator.generate().entities.filter(func(record): return record.type == "resource" and record.resource_type == "wood")
	var shapes := {}
	for record in forest:
		var tree := MapLoader.spawn_entity(record, host.entities, host.match_state) as ResourceNode
		host.entity_id(tree)
		shapes[str(appearance(tree))] = true
		var chosen := Trees.at_position(tree.sim_pos)
		var meta := Sprites.load_meta(chosen.base)
		check(appearance(tree)[0] == chosen.base + ".png" and tree.get_node("Billboard").offset == Sprites.offset_for_hotspot_2d(meta, Sprites.hotspot_at_index(meta, chosen.frame)), "generated tree uses selected atlas and exact frame hotspot")
	check(forest.size() > 900 and shapes.size() >= 25, "default forests visibly use many original tree shapes")
	var packet: Dictionary = JSON.parse_string(JSON.stringify(host.simulation.capture(), "", true, true))
	check(guest.simulation.restore(packet), "guest reconstructs tree keyframe through JSON")
	check(spectator.simulation.restore(packet), "late spectator reconstructs tree keyframe")
	for id in host._net_entities:
		var tree: ResourceNode = host._resolve(id)
		for peer in [guest, spectator]:
			var copy: ResourceNode = peer._resolve(id)
			check(appearance(tree) == appearance(copy), "different process IDs retain identical tree art")
			check(tree.pathfinding_size() == copy.pathfinding_size() and tree.amount_q == copy.amount_q, "art does not change resource or collision state")
	for peer in [guest, spectator]:
		check(peer.simulation.checksum() == host.simulation.checksum(), "keyframe simulation checksum matches")
		check(peer.simulation.restore(packet, 1), "repeated keyframe resynchronization succeeds")
		check(appearance(peer.entities.get_child(0)) == appearance(host.entities.get_child(0)), "resync keeps tree appearance")
	# A moved resource in an existing snapshot must update its derived tree art.
	var updated: Dictionary = packet.world.duplicate(true)
	updated.entities[0].pos = [64.0, 96.0]
	check(guest.apply_snapshot(updated, 2), "existing tree accepts position update")
	var moved: ResourceNode = guest._resolve(int(updated.entities[0].id))
	var expected := ResourceNode.new()
	expected.resource_type = Enums.ResourceType.WOOD
	expected.sim_pos = Vector2(64, 96)
	root.add_child(expected)
	check(appearance(moved) == appearance(expected), "position update refreshes species and frame")
	expected.free()
	for runtime in [host, guest, spectator]: runtime.get_parent().free()
	await _save_restore()
	print("TREE VARIANTS: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _save_restore() -> void:
	var session := root.get_node("GameSession")
	session.online_active = false
	session.match_ai_mode = "sandbox"
	session.pending_save_data = {}
	var data := MapData.create(160, 160, "Tree save test")
	for i in 12:
		var record := MapCatalog.make_record("resource", "wood", Vector2(-70 + i * 12, 12))
		record.id = "tree_%d" % i
		data.entities.append(record)
	session.match_map_data = data
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	await process_frame
	var bootstrap: Node = world.get_node("Bootstrap")
	var entities: Node = world.get_node("Entities")
	var before := {}
	for entity in entities.get_children():
		if entity is ResourceNode: before[str(entity.get_meta("map_id"))] = appearance(entity)
	var saves = load("res://scripts/core/save_game_service.gd")
	var save: Dictionary = JSON.parse_string(JSON.stringify(saves.capture(bootstrap)))
	check(saves.validate(save).is_empty(), "tree save validates with unchanged save format")
	check(saves.restore(bootstrap, save).is_empty(), "tree save restores")
	for entity in entities.get_children():
		if entity is ResourceNode:
			check(appearance(entity) == before[str(entity.get_meta("map_id"))], "save restores exact tree atlas, frame and anchor")
	world.queue_free()
	await process_frame
