extends RefCounted

const UnitAgentScript := preload("res://scripts/entities/unit_agent.gd")
const SelectionController2DScript := preload("res://scripts/input/selection_controller_2d.gd")

func run() -> Array[String]:
	var failures: Array[String] = []
	_test_forward_progress_filters_lateral_slide(failures)
	_test_walk_threshold(failures)
	_test_formation_offsets_spread(failures)
	return failures

func _test_forward_progress_filters_lateral_slide(failures: Array[String]) -> void:
	var intended := Vector2(0.2, 0.0)
	var forward := UnitAgentScript.forward_progress(
		Vector2.ZERO, Vector2(0.2, 0.0), intended
	)
	if forward < 0.19:
		failures.append("forward step should count as locomotion progress")
	var lateral := UnitAgentScript.forward_progress(
		Vector2.ZERO, Vector2(0.0, 0.15), intended
	)
	if absf(lateral) > 0.001:
		failures.append("pure soft-sep lateral slide should not count as forward progress")
	var blocked := UnitAgentScript.forward_progress(
		Vector2.ZERO, Vector2.ZERO, intended
	)
	if absf(blocked) > 0.001:
		failures.append("no movement should yield zero forward progress")

func _test_walk_threshold(failures: Array[String]) -> void:
	if UnitAgentScript.is_walk_progress(0.005, 0.2):
		failures.append("tiny progress should not trigger walk")
	if not UnitAgentScript.is_walk_progress(0.1, 0.2):
		failures.append("strong forward progress should trigger walk")

func _test_formation_offsets_spread(failures: Array[String]) -> void:
	var a: Vector2 = SelectionController2DScript.formation_offset(0, 1)
	if a != Vector2.ZERO:
		failures.append("single unit formation offset should be zero")
	var slots: Array[Vector2] = []
	for i in 4:
		slots.append(SelectionController2DScript.formation_offset(i, 4, 0.9))
	var unique := {}
	for slot in slots:
		unique[slot] = true
	if unique.size() != 4:
		failures.append("four-unit formation should use distinct slots")
	var min_dist := INF
	for i in slots.size():
		for j in range(i + 1, slots.size()):
			min_dist = minf(min_dist, slots[i].distance_to(slots[j]))
	if min_dist < 0.89:
		failures.append("formation spacing should keep units from stacking")
