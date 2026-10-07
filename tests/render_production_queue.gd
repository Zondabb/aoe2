extends SceneTree

var failures: Array[String] = []
var hud: Control
var selection: SelectionController2D
var state: MatchState
var world: Node

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error(message)

func settle() -> void:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw

func _run() -> void:
	world = load("res://scenes/match_2d.tscn").instantiate()
	world.child_entered_tree.connect(func(child: Node):
		if child.name == "AiGateway": child.set("enabled", false)
		if child.name in ["AiController", "Camera2D"]: child.process_mode = Node.PROCESS_MODE_DISABLED)
	root.add_child(world)
	await settle()
	hud = world.get_node("UILayer/HUD")
	selection = world.get_node("UILayer/SelectionController")
	state = world.get_node("Bootstrap").match_state
	for entity in world.get_node("Entities").get_children(): entity.set_physics_process(false)
	var town := world.get_node("Entities/PlayerTownCenter") as BuildingAgent
	for type in 4: state.resources[0][type] = 10000
	state.population_cap[0] = 100
	var villager := town.get_trainable_units()[0]
	for i in BuildingAgent.MAX_TRAIN_QUEUE: check(town.enqueue_train(villager), "enqueue villager %d" % i)
	town.train_progress = town._train_time(villager) * 0.4
	town.set_physics_process(false)
	selection._clear_selection(false)
	selection._add_selection(town)
	await settle()
	var queue := hud.get_node("%ProductionQueue") as GridContainer
	check(queue.visible and queue.get_child_count() == 15, "full queue shows all 15 slots")
	check(int((hud.get_node("%ProductionProgress") as ProgressBar).value) == 40, "progress uses civilization-adjusted duration")
	for size in [Vector2i(1280, 720), Vector2i(960, 540), Vector2i(1440, 800)]:
		root.size = size
		await settle()
		var first := queue.get_child(0) as Control
		var last := queue.get_child(14) as Control
		check(first.get_global_rect().end.x < last.get_global_rect().end.x, "queue order stays left to right")
		check(not last.get_global_rect().intersects((hud.get_node("Minimap") as Control).get_global_rect()), "full queue must not overlap minimap")
		check(queue.position.y + queue.size.y <= (hud.get_node("%CommandHint") as Control).position.y, "queue must not overlap help text")
		root.get_texture().get_image().save_png("res://.godot/production-queue-%d.png" % size.x)
	root.size = Vector2i(1280, 720)
	state.population_cap[0] = state.population[0]
	await settle()
	check("等待人口" in (hud.get_node("%QueueLabel") as Label).text, "population wait is visible")
	root.get_texture().get_image().save_png("res://.godot/production-queue-population.png")
	var food: int = state.resources[0][0]
	(queue.get_child(14) as Button).pressed.emit()
	await settle()
	check(town.train_queue.size() == 14 and state.resources[0][0] == food + villager.cost_food, "real queue button cancels the intended slot")
	check(is_equal_approx(town.training_progress_ratio(), 0.4), "cancelling tail keeps current progress")
	selection._clear_selection()
	await settle()
	check(not queue.visible, "queue hides when selection clears")
	print("PRODUCTION QUEUE RENDER: %d failures" % failures.size())
	quit(0 if failures.is_empty() else 1)
