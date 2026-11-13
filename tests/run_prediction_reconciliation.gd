extends SceneTree
## Actual fixed-step movement plus render-rate prediction. A successful move
## must keep moving forward through confirmation and hand-off, not rubber-band
## back to the authority's older position. Prediction may never change a hash.
const Runtime := preload("res://scripts/network/network_match.gd")
const Simulation := preload("res://scripts/network/lockstep_simulation.gd")
const Prediction := preload("res://scripts/network/client_prediction.gd")
const UnitView := preload("res://scenes/entities/unit_view.tscn")
const Nav := preload("res://scripts/systems/nav_service_holder.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
var checks := 0
var failures: Array[String] = []
var arena: Node2D
var net: Node
var unit: UnitAgent
var prediction: Node2D
var id := 0

class ErrorCounter extends Logger:
	var errors: Array[String] = []
	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_WARNING:
			errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])
	func _log_message(_message: String, _error: bool) -> void: pass

class BlockedNav extends RefCounted:
	func _line_clear(_from: Vector2, _to: Vector2) -> bool: return false

func _initialize() -> void: call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error(label)

func fixture() -> void:
	if is_instance_valid(arena): arena.free()
	arena = Node2D.new()
	root.add_child(arena)
	var entities := Node2D.new()
	entities.name = "Entities"
	arena.add_child(entities)
	var nav := Nav.new()
	nav.name = "NavService"
	arena.add_child(nav)
	nav.setup(-40, 40)
	var state := MatchState.new()
	state.setup_defaults()
	state.map_bounds = Rect2(-40, -40, 80, 80)
	unit = UnitView.instantiate() as UnitAgent
	unit.def = GameCatalog.get_unit(&"villager")
	unit.match_state = state
	unit.sim_pos = Vector2(-15, -10)
	entities.add_child(unit)
	unit.set_physics_process(false)
	net = Runtime.new()
	net.name = "NetworkMatch"
	arena.add_child(net)
	net.set_process(false)
	net.set_physics_process(false)
	net.match_state = state
	net.entities = entities
	net.map_bounds = state.map_bounds
	net.local_team = 0
	net.is_host = true
	net._playing = true
	net.synchronized = true
	net.match_speed = 1.0
	net.simulation = Simulation.new()
	net.simulation.setup(net)
	prediction = Prediction.new()
	arena.add_child(prediction)
	prediction.setup(net)
	prediction.set_process(false)
	id = net.entity_id(unit)

func move(seq: int, goal: Vector2) -> void:
	check(prediction.submit(seq, {"op": "move", "unit_id": id, "pos": [goal.x, goal.y]}), "submit move %d" % seq)

func displayed() -> Vector2:
	return Iso.screen_to_world(unit.render_global_transform(unit).origin)

func advance(delta: float) -> void:
	var before: String = net.simulation.checksum()
	var previous_node := unit.position
	prediction.advance(delta)
	check(net.simulation.checksum() == before and unit.position == previous_node, "presentation leaves the full authority hash and node transform unchanged")

func successful_move(direction: Vector2, input_wait: float) -> void:
	fixture()
	var origin := unit.sim_pos
	var goal := origin + direction * 18.0
	move(1, goal)
	var previous := displayed()
	for frame in ceili(input_wait * 60.0):
		advance(1.0 / 60.0)
		var current := displayed()
		check((current - previous).dot(direction) >= -0.00001, "unconfirmed forward input does not retreat")
		previous = current
	check(unit.sim_pos == origin and (previous - origin).dot(direction) > 0.1, "preview moves while authority waits")
	unit.command_move(goal)
	net.simulation.step()
	var before: String = net.simulation.checksum()
	prediction.resolve(1, true)
	check(net.simulation.checksum() == before, "accepted confirmation changes no gameplay state")
	check(not prediction._motions[id].returning, "accepted straight movement waits for authority without backwards correction")
	for frame in 180:
		if frame % 2 == 0: net.simulation.step()
		advance(1.0 / 60.0)
		var current := displayed()
		check((current - previous).dot(direction) >= -0.00001, "successful movement remains monotone after confirmation, direction %s wait %.2f frame %d" % [direction, input_wait, frame])
		previous = current
	check(unit.sim_pos.distance_to(origin) > 1.0, "test exercises actual navigation and fixed-step movement")
	check(not unit._prediction_presentation_active and prediction._motions.is_empty(), "authority catches up and takes over rendering")

func _run() -> void:
	var logger := ErrorCounter.new()
	OS.add_logger(logger)
	for direction in [Vector2.RIGHT, Vector2.DOWN, Vector2(1, 1).normalized(), Vector2(-1, 1).normalized()]:
		for delay in [0.2, 0.6]: successful_move(direction, delay)

	fixture()
	var origin := unit.sim_pos
	move(1, origin + Vector2(12, 0))
	for frame in 12: advance(1.0 / 60.0)
	var before_reject := displayed()
	prediction.resolve(1, false)
	advance(1.0 / 60.0)
	check(displayed() != origin and displayed().distance_to(origin) < before_reject.distance_to(origin), "rejected prediction corrects gradually instead of snapping")
	for frame in 90: advance(1.0 / 60.0)
	check(not unit._prediction_presentation_active and displayed().is_equal_approx(origin), "rejected movement converges to actual position")

	fixture()
	origin = unit.sim_pos
	move(1, origin + Vector2(12, 0))
	for frame in 12: advance(1.0 / 60.0)
	check(prediction.submit(2, {"op": "stop", "unit_id": id}), "stop has an immediate visual response")
	var stopped := displayed()
	prediction.resolve(1, true)
	for frame in 6: advance(1.0 / 60.0)
	check(displayed().is_equal_approx(stopped) and prediction.pending.has(2), "old acceptance neither resumes movement nor clears newer stop")
	unit.command_stop()
	prediction.resolve(2, true)
	for frame in 90: advance(1.0 / 60.0)
	check(not unit._prediction_presentation_active and displayed().is_equal_approx(origin), "confirmed stop settles to the actual stopping point")

	fixture()
	origin = unit.sim_pos
	move(1, origin + Vector2(12, 0))
	for frame in 12: advance(1.0 / 60.0)
	move(2, origin + Vector2(0, 12))
	prediction.resolve(1, false)
	check(prediction.pending.has(2) and not prediction._motions[id].returning, "old rejection cannot undo a new direction")
	var turning := displayed()
	advance(1.0 / 60.0)
	check(displayed().y > turning.y, "new direction predicts immediately")
	unit.command_move(origin + Vector2(-10, 0))
	prediction.resolve(2, true)
	check(prediction._motions[id].returning, "a different authoritative goal reconciles even if acceptance is true")
	for frame in 90: advance(1.0 / 60.0)
	check(not unit._prediction_presentation_active, "changed route finishes its correction")

	fixture()
	origin = unit.sim_pos
	move(1, origin + Vector2(12, 0))
	for frame in 12: advance(1.0 / 60.0)
	unit.command_move(origin + Vector2(12, 0))
	net.simulation.step()
	prediction.resolve(1, true)
	prediction._nav = BlockedNav.new()
	advance(1.0 / 60.0)
	check(prediction._motions[id].returning, "newly blocked accepted route returns instead of leaving a ghost ahead")
	for frame in 90: advance(1.0 / 60.0)
	check(not unit._prediction_presentation_active, "blocked route converges")

	fixture()
	origin = unit.sim_pos
	move(1, origin + Vector2(12, 0))
	for frame in 12: advance(1.0 / 60.0)
	unit.command_move(origin + Vector2(12, 0))
	prediction.resolve(1, true)
	for frame in 150: advance(1.0 / 60.0) # authority deliberately stalls
	check(not unit._prediction_presentation_active, "accepted input cannot leave a permanent preview when authority stalls")

	fixture()
	move(1, unit.sim_pos + Vector2(12, 0))
	advance(4.0)
	for frame in 90: advance(1.0 / 60.0)
	check(prediction.pending.is_empty() and not unit._prediction_presentation_active, "unconfirmed timeout cleans prediction")
	move(2, unit.sim_pos + Vector2(12, 0))
	advance(0.1)
	unit.hp = 0
	advance(0.01)
	check(prediction.pending.is_empty() and prediction._motions.is_empty() and not unit._prediction_presentation_active, "death immediately removes local motion and pending input")

	OS.remove_logger(logger)
	check(logger.errors.is_empty(), "no engine or script errors")
	for error in logger.errors.slice(0, 8): print(error)
	arena.free()
	await process_frame
	print("PREDICTION RECONCILIATION: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
