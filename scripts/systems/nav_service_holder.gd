class_name NavServiceHolder
extends Node

## Owns NavGridService, flushes path queues, rebuilds on map changes.

const NavGridServiceScript := preload("res://scripts/systems/nav_grid_service.gd")
const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")
const DEFAULT_FRAME_BUDGET := 4

var nav: NavGridServiceScript

func setup(
	map_min: int,
	map_max: int,
	cell_size: float = 1.0,
	frame_budget: int = DEFAULT_FRAME_BUDGET
) -> void:
	nav = NavGridServiceScript.new()
	nav.setup(map_min, map_max, cell_size)
	nav.set_frame_budget(frame_budget)
	CollisionResolverScript.set_map_bounds(Vector2(map_min, map_min), Vector2(map_max, map_max))
	set_meta("nav", nav)
	add_to_group("nav_service")

func _ready() -> void:
	call_deferred("_connect_existing_buildings")
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)

func _on_node_added(node: Node) -> void:
	call_deferred("_try_connect_building", node)

func _connect_existing_buildings() -> void:
	for node in get_tree().get_nodes_in_group("buildings"):
		_try_connect_building(node)

func _try_connect_building(node: Node) -> void:
	if not node.has_signal("construction_completed"):
		return
	if node.is_connected("construction_completed", _on_construction_completed):
		return
	node.connect("construction_completed", _on_construction_completed)

func _on_construction_completed(_building: Node) -> void:
	rebuild_from_scene()

func rebuild_from_scene() -> void:
	if nav == null:
		return
	nav.rebuild_from_blockers(NavGridServiceScript.collect_blockers_from_tree(get_tree()))
	_refresh_debug_overlays()
	call_deferred("_repath_moving_units")


func _process(_delta: float) -> void:
	if nav == null:
		return
	var results: Dictionary = nav.flush_pending_paths()
	if results.is_empty():
		return
	for uid_variant in results.keys():
		var uid := int(uid_variant)
		var unit: Object = instance_from_id(uid)
		if unit == null or not is_instance_valid(unit):
			continue
		if unit.has_method("apply_nav_path"):
			unit.call("apply_nav_path", results[uid])

func _repath_moving_units() -> void:
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.has_method("refresh_nav_path_if_moving"):
			unit.call("refresh_nav_path_if_moving")

func _refresh_debug_overlays() -> void:
	for node in get_tree().get_nodes_in_group("nav_debug_overlay"):
		if node.get("nav") != null:
			node.set("nav", nav)
		if node.has_method("queue_redraw"):
			node.call("queue_redraw")
	var overlay := get_parent().get_node_or_null("NavDebugOverlay") if get_parent() else null
	if overlay != null:
		overlay.set("nav", nav)
		if overlay.has_method("queue_redraw"):
			overlay.call("queue_redraw")
