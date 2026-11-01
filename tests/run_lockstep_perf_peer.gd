extends SceneTree
## One process of the lockstep performance probe (see tools/bench_lockstep_e2e.py).
## Both players load the seeded default map plus an identical extra army, send
## their armies to the centre and villagers to wood, then sample for a fixed
## wall-clock window: simulated speed, render-frame hitches and frame lag.
const DefaultMap := preload("res://scripts/world/default_map_generator.gd")
const Catalog := preload("res://scripts/world/map_catalog.gd")
var session: Node
var game: Node
var arena: Node
var runtime: Node
var role := ""
var output := ""
var army := 40
var window_ms := 20000
var started := 0
var ordered := false
var sampling := false
var sample_start_usec := 0
var sample_start_tick := 0
var last_process_usec := 0
var frame_times: PackedInt64Array = PackedInt64Array()
var physics_ticks := 0
var idle_ticks := 0
var last_position := -1
var done := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var endpoint: String = args[0]
	role = args[1]
	output = args[2]
	if args.size() > 3: army = int(args[3])
	if args.size() > 4: window_ms = int(args[4])
	started = Time.get_ticks_msec()
	session = root.get_node("NetworkSession")
	game = root.get_node("GameSession")
	session.matched.connect(_matched)
	session.ended.connect(func(info: Dictionary): if not done: _fail("ended early: " + str(info)))
	session.join_queue(endpoint, role, "chinese")

func _matched(info: Dictionary) -> void:
	game.online_active = true
	game.online_spectator = false
	game.online_team = int(info.get("team", -1))
	game.player_civ_id = &"chinese"
	game.ai_civ_id = &"chinese"
	var data: Dictionary = DefaultMap.generate(int(info.seed), &"chinese", &"chinese")
	var centres := {}
	for record in data.entities:
		if record.get("type") == "building" and Catalog.definition_id(record) == "town_center":
			centres[record.team] = Vector2(record.pos[0], record.pos[1])
	var kinds := ["archer", "man_at_arms", "spearman"]
	for team_name in ["player", "ai"]:
		var base: Vector2 = centres[team_name]
		var toward := (Vector2.ZERO - base).normalized()
		for i in army:
			var offset := Vector2(float(i % 10) * 1.6 - 8.0, float(i / 10) * 1.6)
			var pos := base + toward * 16.0 + offset
			data.entities.append({"id": "perf-%s-%d" % [team_name, i], "type": "unit", "unit_id": kinds[i % 3], "team": team_name, "pos": [pos.x, pos.y]})
	game.match_map_data = data
	game.match_ai_mode = "sandbox"
	arena = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(arena)
	current_scene = arena

func _process(_delta: float) -> bool:
	if done: return false
	var now := Time.get_ticks_usec()
	if Time.get_ticks_msec() - started > window_ms + 90000:
		_fail("timed out")
		return false
	if arena == null: return false
	runtime = arena.get_node_or_null("NetworkMatch")
	if runtime == null or not runtime.synchronized or not runtime._playing:
		last_process_usec = now
		return false
	if not ordered:
		ordered = true
		_orders()
	if not sampling and int(runtime.tick) >= 60:
		sampling = true
		sample_start_usec = now
		sample_start_tick = int(runtime.tick)
		last_process_usec = now
		return false
	if sampling:
		frame_times.append(now - last_process_usec)
		if now - sample_start_usec >= window_ms * 1000:
			_report(now)
	last_process_usec = now
	return false

## Physics ticks on which this peer's simulation did not advance (waiting for
## frames or acknowledgements): visible as actors pausing.
func _physics_process(_delta: float) -> bool:
	if not sampling or done or runtime == null: return false
	var position := int(runtime.tick) + int(runtime._frame_step)
	physics_ticks += 1
	if position == last_position: idle_ticks += 1
	last_position = position
	return false

func _orders() -> void:
	var side := int(runtime.local_team)
	var trees: Array = []
	for entity in runtime.entities.get_children():
		if entity is ResourceNode and entity.resource_type == 1: trees.append(entity)
	for entity in runtime.entities.get_children():
		if entity is not UnitAgent or int(entity.team) != side: continue
		if entity.def.id == &"villager":
			var best: Node = null
			for tree in trees:
				if best == null or tree.sim_pos.distance_squared_to(entity.sim_pos) < best.sim_pos.distance_squared_to(entity.sim_pos): best = tree
			if best != null: runtime.submit_command({"op": "gather", "unit_id": runtime.entity_id(entity), "target_id": runtime.entity_id(best)})
		elif entity.def.id != &"scout_cavalry":
			runtime.submit_command({"op": "move", "unit_id": runtime.entity_id(entity), "pos": [float(side * 2 - 1) * 6.0, float(side * 2 - 1) * 6.0]})

func _report(now: int) -> void:
	done = true
	var sorted := frame_times.duplicate()
	sorted.sort()
	var count := sorted.size()
	var over_50 := 0
	var over_100 := 0
	for value in sorted:
		if value > 50000: over_50 += 1
		if value > 100000: over_100 += 1
	var seconds := float(now - sample_start_usec) / 1000000.0
	var ticks := int(runtime.tick) - sample_start_tick
	var report := {"role": role, "host": bool(runtime.is_host), "tick": int(runtime.tick), "seconds": seconds,
		"sim_speed": float(ticks) / 30.0 / seconds, "match_speed": float(runtime.match_speed), "frames": count,
		"frame_ms_p50": sorted[count / 2] / 1000.0, "frame_ms_p99": sorted[int(count * 0.99)] / 1000.0,
		"frame_ms_max": sorted[-1] / 1000.0, "frames_over_50ms": over_50, "frames_over_100ms": over_100,
		"desyncs": int(runtime.desync_count), "keyframes": int(runtime.keyframes_received),
		"idle_tick_ratio": float(idle_ticks) / maxf(1.0, float(physics_ticks)),
		"units": runtime.entities.get_children().filter(func(n: Node): return n is UnitAgent).size()}
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(report))
	file.close()
	print("LOCKSTEP PERF ", JSON.stringify(report))

func _fail(message: String) -> void:
	if done: return
	done = true
	push_error("LOCKSTEP PERF FAILED: " + message)
	quit(1)
