extends SceneTree
## Read-only probe: are AI decision-context options rotation-symmetric for the
## two bases of the (rotationally symmetric) default map at the first tick?
## Args: civ_team0 civ_team1 [map_seed]
const Observation := preload("res://scripts/ai_gateway/observation_builder.gd")
const MapGenerator := preload("res://scripts/world/default_map_generator.gd")

func _initialize() -> void:
	call_deferred("_run")

func _rel(pos: Variant, base: Vector2, team: int) -> Array:
	var p := Vector2(float(pos[0]), float(pos[1])) - base
	if team == 1: p = -p
	return [snappedf(p.x, 0.1), snappedf(p.y, 0.1)]

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var civs := [StringName(args[0]), StringName(args[1])]
	var session := root.get_node("GameSession")
	session.match_ai_mode = "sandbox"
	session.match_map_data = {}
	if args.size() >= 3 and args[2].is_valid_int():
		session.match_map_data = MapGenerator.generate(int(args[2]), civs[0], civs[1])
	session.online_active = false
	session.player_civ_id = civs[0]
	session.ai_civ_id = civs[1]
	var world := load("res://scenes/match_2d.tscn").instantiate() as Node2D
	root.add_child(world)
	current_scene = world
	await process_frame
	await process_frame
	world.process_mode = Node.PROCESS_MODE_DISABLED
	var state: MatchState = world.get_node("Bootstrap").match_state
	var entities: Node2D = world.get_node("Entities")
	state.fog.rebuild(entities.get_children())
	var out := {}
	for team in 2:
		var obs: Dictionary = Observation.build(state, entities, team, 1 - team, 0.0)
		var derived: Dictionary = obs.get("derived", {})
		var tc: Array = derived.get("own_tc_pos", [0, 0])
		var base := Vector2(float(tc[0]), float(tc[1]))
		var ctx: Dictionary = obs.get("decision_context", {})
		var sites := {}
		for option: Dictionary in ctx.get("construction_options", []):
			var key := String(option.get("building_def_id"))
			if not sites.has(key): sites[key] = []
			sites[key].append([_rel(option.pos, base, team), option.get("score")])
		var army: Dictionary = ctx.get("army", {})
		var scouting: Dictionary = ctx.get("scouting", {})
		var frontiers := []
		for item: Dictionary in scouting.get("frontiers", []):
			frontiers.append(_rel(item.pos, base, team))
		var probes := []
		for item: Dictionary in scouting.get("probes", []):
			probes.append(_rel(item.pos, base, team))
		var defense := []
		for item: Dictionary in ctx.get("defense_options", []):
			defense.append([_rel(item.get("start"), base, team), _rel(item.get("end"), base, team)])
		out[team] = {"tc": tc, "sites": sites, "rally": _rel(army.get("rally_point", tc), base, team),
			"frontiers": frontiers, "probes": probes, "defense": defense}
	print("SITE PROBE: " + JSON.stringify(out))
	quit(0)
