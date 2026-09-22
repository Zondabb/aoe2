extends SceneTree

const Selection := preload("res://scripts/input/selection_controller_2d.gd")
const Overlay := preload("res://scripts/presentation/nav_debug_overlay.gd")
const Focus := preload("res://scripts/debug/unit_debug_focus.gd")
var failures := 0
var notifications: Array = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	var selection := Selection.new()
	root.add_child(selection)
	selection.set_process(false)
	selection.selection_changed.connect(func(items: Array): notifications.append(items.duplicate()))
	var overlay := Overlay.new()
	root.add_child(overlay)
	var survivor := Node2D.new()
	root.add_child(survivor)
	survivor.add_to_group("units")
	var dead_a := Node2D.new()
	var dead_b := Node2D.new()
	selection._selected.assign([survivor, dead_a, dead_b])
	var stale: Array = [dead_a, survivor, dead_b]
	dead_a.free()
	dead_b.free()
	# Direct consumers must tolerate stale selections before any frame cleanup.
	Focus.set_focus_from_selection(stale)
	selection._sync_nav_debug_focus(stale)
	overlay.set_focus_units(stale)
	check(Focus.focused_unit() == survivor, "focus must skip freed references")
	check(overlay._focus_units.size() == 1, "overlay must skip freed references before casting")
	selection._process(0.01)
	check(selection._selected.size() == 1 and selection.get_primary_selection() == survivor, "frame cleanup must remove multiple freed entries without losing survivor")
	check(notifications.size() == 1 and notifications[0] == [survivor], "selection signal must contain only live entries")
	var dead_c := Node2D.new()
	selection._selected.append(dead_c)
	dead_c.free()
	selection._emit_selection_changed()
	check(selection._selected.size() == 1 and notifications.back() == [survivor], "direct emission must also prune freed entries")
	survivor.queue_free()
	selection._emit_selection_changed()
	check(selection._selected.is_empty() and notifications.back().is_empty(), "queued deletion must clear selection before the node is freed")
	check(Focus.focused_unit() == null and overlay._focus_units.is_empty(), "last unit deletion must clear both debug consumers")
	selection.queue_free()
	overlay.queue_free()
	await process_frame
	print("SELECTION LIFETIME: 7 checks, %d failures" % failures)
	quit(0 if failures == 0 else 1)
