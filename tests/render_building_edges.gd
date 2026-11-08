extends SceneTree
## Run windowed (not --headless). Renders villagers leaving a town center and
## militia/archers attacking a town center and a house in a real match, and
## checks that both happen at the drawn building edge rather than its center.

const Catalog := preload("res://scripts/data/game_catalog.gd")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const BUILDING := preload("res://scenes/entities/building_view.tscn")
var checks := 0
var failures: Array[String] = []
var world: Node
var state: MatchState
var entities: Node2D
var spawned: Array[Node] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func settle() -> void:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw

func wait_seconds(seconds: float) -> void:
	await create_timer(seconds).timeout
	await settle()

## How far a point lies outside a building's drawn rectangle (negative inside).
func outside(point: Vector2, building: BuildingAgent) -> float:
	var delta := point - building.sim_pos
	var half := building.get_interaction_half()
	return maxf(absf(delta.x) - half.x, absf(delta.y) - half.y)

func add_unit(id: StringName, team: int, at: Vector2, label: String) -> UnitAgent:
	var bootstrap := world.get_node("Bootstrap")
	var unit := UNIT.instantiate() as UnitAgent
	unit.name = label
	unit.team = team
	unit.def = Catalog.get_unit(id)
	unit.civ = bootstrap.ai_civ if team == 1 else bootstrap.player_civ
	unit.match_state = state
	unit.sim_pos = at
	entities.add_child(unit)
	return unit

func report_attackers(target: BuildingAgent, attackers: Array[UnitAgent], tag: String) -> void:
	var alive := 0
	var striking := 0
	var inside := 0
	for unit in attackers:
		if not is_instance_valid(unit) or unit.hp <= 0.0: continue
		alive += 1
		var out := outside(unit.sim_pos, target)
		# Melee units hold position anywhere within range plus chase slack.
		if not unit._needs_attack_chase(target): striking += 1
		if out < -0.05: inside += 1
		print("%s %s %s out=%.2f striking=%s spot=%d" % [tag, unit.name, unit.def.id, out, not unit._needs_attack_chase(target), unit._attack_spot])
	print("%s alive=%d striking=%d inside=%d" % [tag, alive, striking, inside])
	check(alive > 0 and striking == alive, "%s: every attacker reaches the drawn edge (%d/%d)" % [tag, striking, alive])
	check(inside == 0, "%s: no attacker stands inside the drawn building (%d)" % [tag, inside])

func _run() -> void:
	world = load("res://scenes/match_2d.tscn").instantiate()
	world.child_entered_tree.connect(func(child: Node):
		if child.name == "AiGateway": child.set("enabled", false)
		if child.name == "AiController": child.process_mode = Node.PROCESS_MODE_DISABLED)
	root.add_child(world)
	await settle()
	root.size = Vector2i(1600, 900)
	state = world.get_node("Bootstrap").match_state
	state.fog_enabled = false
	entities = world.get_node("Entities") as Node2D
	var town := entities.get_node("PlayerTownCenter") as BuildingAgent
	var camera := world.get_node("Camera2D") as Camera2D
	camera.process_mode = Node.PROCESS_MODE_DISABLED
	camera.zoom = Vector2.ONE * 0.8
	camera.call("focus_on", town.sim_pos + Vector2(-2, 4))
	for team in 2:
		for resource in 4: state.resources[team][resource] = 10000
		state.population_cap[team] = 200
	entities.child_entered_tree.connect(func(child: Node): spawned.append(child))
	var house := BUILDING.instantiate() as BuildingAgent
	house.name = "RenderHouse"
	house.team = 0
	house.def = Catalog.get_building(&"house")
	house.civ = world.get_node("Bootstrap").player_civ
	house.match_state = state
	house.sim_pos = town.sim_pos + Vector2(-4, 15)
	entities.add_child(house)
	await settle()
	spawned.clear()

	var villager := town.get_trainable_units()[0]
	for i in 5:
		check(town.enqueue_train(villager), "queue villager %d" % i)
	for i in 5:
		town.train_progress = town._train_time(villager) - 0.05
		await wait_seconds(0.4)
	var trained: Array[UnitAgent] = []
	for child in spawned:
		if child is UnitAgent and (child as UnitAgent).def.id == villager.id: trained.append(child)
	check(trained.size() == 5, "five villagers trained (got %d)" % trained.size())
	for unit in trained:
		var out := outside(unit.sim_pos, town)
		print("villager %s at %s out=%.2f" % [unit.name, unit.sim_pos - town.sim_pos, out])
		check(out >= -0.05 and out <= 3.0, "villager %s appears just outside the drawn town center (out=%.2f)" % [unit.name, out])
	root.get_texture().get_image().save_png("res://.godot/render-edge-spawn.png")

	var tc_attackers: Array[UnitAgent] = []
	var house_attackers: Array[UnitAgent] = []
	for i in 18:
		tc_attackers.append(add_unit(&"militia", 1, town.sim_pos + Vector2(-15.0 + float(i % 2) * 1.2, -6.0 + float(i / 2) * 1.2), "TcMilitia%d" % i))
	for i in 4:
		tc_attackers.append(add_unit(&"archer", 1, town.sim_pos + Vector2(4.0 + float(i) * 1.2, -16.0), "TcArcher%d" % i))
	for i in 9:
		house_attackers.append(add_unit(&"militia", 1, house.sim_pos + Vector2(-12.0 + float(i % 2) * 1.2, -3.0 + float(i / 2) * 1.2), "HouseMilitia%d" % i))
	await settle()
	var town_hp := town.hp
	var house_hp := house.hp
	for unit in tc_attackers: unit.command_attack(town)
	for unit in house_attackers: unit.command_attack(house)
	await wait_seconds(24.0)
	root.get_texture().get_image().save_png("res://.godot/render-edge-attack.png")
	report_attackers(town, tc_attackers, "town_center")
	report_attackers(house, house_attackers, "house")
	check(town.hp < town_hp, "town center takes damage (%.0f -> %.0f)" % [town_hp, town.hp])
	check(house.hp < house_hp, "house takes damage (%.0f -> %.0f)" % [house_hp, house.hp])
	camera.zoom = Vector2.ONE * 1.3
	camera.call("focus_on", town.sim_pos + Vector2(-3, 0))
	await settle()
	root.get_texture().get_image().save_png("res://.godot/render-edge-attack-close.png")
	print("BUILDING EDGE RENDER: %d checks, %d failures" % [checks, failures.size()])
	for failure in failures: print("FAIL: " + failure)
	quit(0 if failures.is_empty() else 1)
