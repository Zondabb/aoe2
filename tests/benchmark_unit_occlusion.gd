extends SceneTree

## Run with GL: CPU time measures update_mask only, including queued render work.
const Renderer := preload("res://scripts/presentation/unit_occlusion.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
var world: Node2D
var renderer: Node
var checks := 0
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _initialize() -> void:
	call_deferred("_run")

func frame() -> void:
	await process_frame
	await RenderingServer.frame_post_draw

func _run() -> void:
	var session := root.get_node("GameSession")
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	world = load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	world.get_node("Camera2D").set_process(false)
	await frame()
	await frame()
	var state: MatchState = world.get_node("Bootstrap").match_state
	state.frozen = true
	renderer = root.get_meta(Renderer.KEY)
	renderer.set_process(false)
	await _measure("starting base / team fog")
	world.get_node("FogOfWar").set_view(-1)
	await _measure("starting base / all 980 trees visible")
	world.get_node("Camera2D").focus_on(Vector2(-120, -188))
	for i in 40:
		var unit := UNIT.instantiate() as UnitAgent
		unit.def = GameCatalog.get_unit(&"villager")
		unit.match_state = state
		unit.sim_pos = Vector2(-120, -188) + Vector2(6 + i % 8, 9 + i / 8)
		world.get_node("Entities").add_child(unit)
		unit.set_physics_process(false)
	await frame()
	await _measure("forest / 40 villagers / all resources visible")
	world.free()
	print("UNIT OCCLUSION BENCHMARK: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _measure(label: String) -> void:
	var samples: Array[float] = []
	for i in 10:
		renderer.update_mask()
		await frame()
	for i in 120:
		var started := Time.get_ticks_usec()
		renderer.update_mask()
		samples.append((Time.get_ticks_usec() - started) / 1000.0)
		await frame()
	samples.sort()
	var total := 0.0
	for sample in samples: total += sample
	print("OCCLUSION CPU [%s]: mean %.3f ms, median %.3f ms, p95 %.3f ms; %d copies, %d outlines" % [label, total / samples.size(), samples[samples.size() / 2], samples[int(samples.size() * 0.95)], renderer.copies.size(), renderer.outlines.size()])
	check(renderer.static_registered >= 980, "benchmark contains the complete 980-tree map")
	check(renderer.static_candidates < renderer.static_registered / 3, "only nearby spatial cells are queried: " + label)
	print("OCCLUSION SPATIAL [%s]: %d/%d static source candidates; %d mask redraws" % [label, renderer.static_candidates, renderer.static_registered, renderer.mask_redraws])
