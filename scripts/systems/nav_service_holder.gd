class_name NavServiceHolder
extends Node

## Owns NavGridService, flushes path queues, rebuilds on map changes.

const NavGridServiceScript := preload("res://scripts/systems/nav_grid_service.gd")
const CollisionResolverScript := preload("res://scripts/systems/collision_resolver.gd")
const Fixed := preload("res://scripts/core/sim_fixed.gd")
const DEFAULT_FRAME_BUDGET := 12
const STATIC_BUCKET_SIZE := 8.0

var nav: NavGridServiceScript
var _static_buckets: Dictionary = {}
var _static_records: Dictionary = {}
var _tracked_buildings: Dictionary = {}
var _static_dirty := true
var _rebuild_queued := false
var _last_building_check_frame := -1
var _last_building_check_process_frame := -1
var lockstep_enabled := false
var _lockstep_tick := 0
var _lockstep_repath := false

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
	_reset_static_index()

func _ready() -> void:
	call_deferred("_connect_existing_buildings")
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)
	if not get_tree().node_removed.is_connected(_on_node_removed):
		get_tree().node_removed.connect(_on_node_removed)


func setup_rect(minimum: Vector2i, maximum: Vector2i) -> void:
	nav = NavGridServiceScript.new()
	nav.setup_rect(minimum, maximum)
	nav.set_frame_budget(DEFAULT_FRAME_BUDGET)
	CollisionResolverScript.set_map_bounds(Vector2(minimum), Vector2(maximum))
	set_meta("nav", nav)
	add_to_group("nav_service")
	_reset_static_index()

func _on_node_added(node: Node) -> void:
	if node is Node2D and (node.has_signal("construction_started") or node.has_method("extract") or node.get("block_size") is Vector2):
		if lockstep_enabled:
			if get_parent().is_ancestor_of(node): _try_connect_building(node)
			_static_dirty = true
			return
		call_deferred("_try_connect_weak", weakref(node))
		_queue_static_rebuild()


func _on_node_removed(node: Node) -> void:
	var id := node.get_instance_id()
	if _static_records.has(id) or _tracked_buildings.has(id):
		_tracked_buildings.erase(id)
		_queue_static_rebuild()

func _try_connect_weak(reference: WeakRef) -> void:
	var node := reference.get_ref() as Node
	if node != null and node.is_inside_tree() and get_parent().is_ancestor_of(node):
		_try_connect_building(node)
		_queue_static_rebuild()

func _connect_existing_buildings() -> void:
	for node in get_tree().get_nodes_in_group("buildings"):
		if get_parent().is_ancestor_of(node): _try_connect_building(node)
	_queue_static_rebuild()

func _try_connect_building(node: Node) -> void:
	if not is_instance_valid(node):
		return
	if node.has_signal("construction_started"):
		_tracked_buildings[node.get_instance_id()] = {"node": weakref(node), "signature": _building_signature(node)}
	if node.has_signal("construction_started"):
		if not node.is_connected("construction_started", _on_construction_changed):
			node.connect("construction_started", _on_construction_changed)
	if node.has_signal("construction_completed"):
		if not node.is_connected("construction_completed", _on_construction_changed):
			node.connect("construction_completed", _on_construction_changed)


func _on_construction_changed(_building: Node) -> void:
	rebuild_from_scene()

## Coalesce network terrain edits with the existing deferred static rebuild.
func invalidate_static_geometry() -> void:
	_queue_static_rebuild()

## Refresh one tracked building's collision record in place. An auto gate
## opening or closing changes only its own collision box: its navigation
## footprint, the route grid and every other record stay the same, so a full
## rebuild would produce exactly these records. Anything not already indexed
## and clean falls back to the full deferred rebuild.
func update_static_entity(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		_queue_static_rebuild()
		return
	var id := node.get_instance_id()
	if _static_dirty or not _tracked_buildings.has(id) or not node.is_inside_tree() or node.is_queued_for_deletion() or not get_parent().is_ancestor_of(node):
		_queue_static_rebuild()
		return
	var old: Dictionary = _static_records.get(id, {})
	if not old.is_empty():
		for cell in _bucket_cells(old.center, old.half):
			var ids: Array = _static_buckets.get(cell, [])
			ids.erase(id)
			if ids.is_empty(): _static_buckets.erase(cell)
		_static_records.erase(id)
	if NavGridServiceScript._building_blocks_nav(node):
		var half := CollisionResolverScript._blocker_half(node, 0.0)
		if half.x > 0.0 and half.y > 0.0:
			var center: Vector2 = node.get("sim_pos")
			_static_records[id] = _static_record(node, center, half)
			for cell in _bucket_cells(center, half):
				if not _static_buckets.has(cell): _static_buckets[cell] = []
				_static_buckets[cell].append(id)
	_tracked_buildings[id].signature = _building_signature(node)

func _bucket_cells(center: Vector2, half: Vector2) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var minimum := Vector2i(((center - half) / STATIC_BUCKET_SIZE).floor())
	var maximum := Vector2i(((center + half) / STATIC_BUCKET_SIZE).floor())
	for y in range(minimum.y, maximum.y + 1):
		for x in range(minimum.x, maximum.x + 1):
			cells.append(Vector2i(x, y))
	return cells

func rebuild_from_scene() -> void:
	if nav == null:
		return
	var blockers: Array = []
	for node in NavGridServiceScript.collect_blockers_from_tree(get_tree()):
		if is_instance_valid(node) and node.is_inside_tree() and not node.is_queued_for_deletion() and get_parent().is_ancestor_of(node):
			blockers.append(node)
	var changed := nav.rebuild_from_blockers(blockers)
	var static_state := _remove_vanished_static_records(blockers)
	if static_state < 0:
		_update_static_index(blockers)
	elif changed or static_state > 0:
		_refresh_tracked_signatures()
	_static_dirty = false
	if changed:
		_refresh_debug_overlays()
		if lockstep_enabled: _lockstep_repath = true
		else: call_deferred("_repath_moving_units")


func _process(_delta: float) -> void:
	if lockstep_enabled: return
	_flush_paths()

func lockstep_step() -> void:
	_lockstep_tick += 1
	_check_building_changes()
	if _static_dirty: rebuild_from_scene()
	if _lockstep_repath:
		_lockstep_repath = false
		_repath_moving_units()
	_flush_paths()

func _flush_paths() -> void:
	if nav == null:
		return
	_check_building_changes()
	if _static_dirty: rebuild_from_scene()
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
		if get_parent().is_ancestor_of(unit) and unit.has_method("refresh_nav_path_if_moving"):
			unit.call("refresh_nav_path_if_moving")


## Sweep broad phase over actual static AABBs. A mover normally visits only
## nearby 8×8 buckets, regardless of the forest's total tree count.
func query_static_blockers(from: Vector2, to: Vector2, radius: float) -> Array:
	_check_building_changes()
	if _static_dirty: rebuild_from_scene()
	var margin := Vector2.ONE * maxf(0.0, radius)
	var minimum := from.min(to) - margin
	var maximum := from.max(to) + margin
	var first := Vector2i((minimum / STATIC_BUCKET_SIZE).floor())
	var last := Vector2i((maximum / STATIC_BUCKET_SIZE).floor())
	var seen := {}
	var result: Array = []
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			for id in _static_buckets.get(Vector2i(x, y), []):
				if seen.has(id): continue
				seen[id] = true
				var record: Dictionary = _static_records[id]
				var node: Node = record.node.get_ref()
				if node == null or not node.is_inside_tree() or node.is_queued_for_deletion(): continue
				# Amount may become zero before the deferred tree/depletion update.
				if node.get("def") is not BuildingDef and node.get("resource_type") != null and float(node.get("amount")) <= 0: continue
				var center: Vector2 = record.center
				var half: Vector2 = record.half
				if center.x + half.x >= minimum.x and center.x - half.x <= maximum.x and center.y + half.y >= minimum.y and center.y - half.y <= maximum.y:
					result.append(node)
	if lockstep_enabled:
		result.sort_custom(func(a: Node, b: Node): return int(a.get_meta("net_id", 0)) < int(b.get_meta("net_id", 0)))
	return result


## Fixed-point geometry is cached with the bucket record so avoidance does
## not re-derive each blocker's footprint for every moving unit and step.
func _static_record(node: Node, center: Vector2, half: Vector2) -> Dictionary:
	var contours: Variant = null
	if node.has_method("get_water_contours") and not node.get_water_contours().is_empty():
		contours = node.get_water_contours()
	return {"node": weakref(node), "center": center, "half": half, "center_q": Fixed.vector(center), "half_q": Fixed.vector(half), "contours": contours}


## Integer avoidance boxes near `from`: [boxes, water] as in
## CollisionResolver.static_boxes, with each half widened by `radius_q`.
## Same candidate set and liveness rules as query_static_blockers.
func query_static_boxes(from: Vector2, reach: float, radius_q: int) -> Array:
	_check_building_changes()
	if _static_dirty: rebuild_from_scene()
	var margin := Vector2.ONE * maxf(0.0, reach)
	var minimum := from - margin
	var maximum := from + margin
	var first := Vector2i((minimum / STATIC_BUCKET_SIZE).floor())
	var last := Vector2i((maximum / STATIC_BUCKET_SIZE).floor())
	# A record spans several buckets; one bucket lists each record once.
	var single_bucket := first == last
	var seen := {}
	var boxes := PackedInt64Array()
	var water: Array = []
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			for id in _static_buckets.get(Vector2i(x, y), []):
				if not single_bucket:
					if seen.has(id): continue
					seen[id] = true
				var record: Dictionary = _static_records[id]
				var node: Node = record.node.get_ref()
				if node == null or not node.is_inside_tree() or node.is_queued_for_deletion(): continue
				# Depleted resources no longer block (typed reads of the generic test).
				if node is ResourceNode:
					if (node as ResourceNode).amount_q <= 0: continue
				elif node is BuildingAgent and (node as BuildingAgent).def != null: pass
				elif node.get("def") is not BuildingDef and node.get("resource_type") != null and float(node.get("amount")) <= 0: continue
				var center: Vector2 = record.center
				var half: Vector2 = record.half
				if center.x + half.x < minimum.x or center.x - half.x > maximum.x or center.y + half.y < minimum.y or center.y - half.y > maximum.y: continue
				var center_q: Vector2i = record.center_q
				var half_q: Vector2i = record.half_q
				var water_index := -1
				if record.contours != null:
					water_index = water.size()
					water.append(record.contours)
				boxes.append_array([center_q.x, center_q.y, half_q.x + radius_q, half_q.y + radius_q, water_index])
	return [boxes, water]


func _reset_static_index() -> void:
	_static_buckets.clear()
	_static_records.clear()
	_tracked_buildings.clear()
	_static_dirty = true
	_last_building_check_frame = -1
	_last_building_check_process_frame = -1


func _update_static_index(blockers: Array) -> void:
	_static_buckets.clear()
	_static_records.clear()
	for node in blockers:
		var half := CollisionResolverScript._blocker_half(node, 0.0)
		if half.x <= 0.0 or half.y <= 0.0: continue
		var center: Vector2 = node.get("sim_pos")
		var id: int = node.get_instance_id()
		_static_records[id] = _static_record(node, center, half)
		var minimum := Vector2i(((center - half) / STATIC_BUCKET_SIZE).floor())
		var maximum := Vector2i(((center + half) / STATIC_BUCKET_SIZE).floor())
		for y in range(minimum.y, maximum.y + 1):
			for x in range(minimum.x, maximum.x + 1):
				var cell := Vector2i(x, y)
				if not _static_buckets.has(cell): _static_buckets[cell] = []
				_static_buckets[cell].append(id)
	_refresh_tracked_signatures()


func _refresh_tracked_signatures() -> void:
	for record: Dictionary in _tracked_buildings.values():
		var node: Node = record.node.get_ref()
		if node != null: record.signature = _building_signature(node)


## _update_static_index without rebuilding every record when blockers only
## disappeared (a tree cut down, a building destroyed): 0 when the index
## already matches, 1 after removing the vanished records (the remaining
## records and bucket order are what a full rebuild produces), -1 when
## anything else changed and the full rebuild is needed.
func _remove_vanished_static_records(blockers: Array) -> int:
	var keep := {}
	for node in blockers:
		var half := CollisionResolverScript._blocker_half(node, 0.0)
		if half.x <= 0.0 or half.y <= 0.0: continue
		var id: int = node.get_instance_id()
		var record: Dictionary = _static_records.get(id, {})
		if record.is_empty() or record.center != node.get("sim_pos") or record.half != half: return -1
		keep[id] = true
	if keep.size() == _static_records.size(): return 0
	for id in _static_records.keys():
		if keep.has(id): continue
		var record: Dictionary = _static_records[id]
		var center: Vector2 = record.center
		var half: Vector2 = record.half
		var minimum := Vector2i(((center - half) / STATIC_BUCKET_SIZE).floor())
		var maximum := Vector2i(((center + half) / STATIC_BUCKET_SIZE).floor())
		for y in range(minimum.y, maximum.y + 1):
			for x in range(minimum.x, maximum.x + 1):
				var cell := Vector2i(x, y)
				var bucket: Array = _static_buckets.get(cell, [])
				bucket.erase(id)
				if bucket.is_empty(): _static_buckets.erase(cell)
		_static_records.erase(id)
	return 1


func _building_signature(node: Node) -> Array:
	if node.is_queued_for_deletion() or node.get("is_placement_ghost") == true: return []
	var half := CollisionResolverScript._blocker_half(node, 0.0)
	return [] if half == Vector2.ZERO else [node.get("sim_pos"), half]


func _check_building_changes() -> void:
	var frame := _lockstep_tick if lockstep_enabled else Engine.get_physics_frames()
	if frame == _last_building_check_frame: return
	# Single player: once per rendered frame as well. Physics catching up runs
	# several ticks per frame; paths are flushed on the frame, and the changes
	# this poll backs up (signals cover construction and gates) wait one frame.
	if not lockstep_enabled:
		var process_frame := Engine.get_process_frames()
		if process_frame == _last_building_check_process_frame and Engine.is_in_physics_frame(): return
		_last_building_check_process_frame = process_frame
	_last_building_check_frame = frame
	var vanished: Array = []
	for id in _tracked_buildings:
		var record: Dictionary = _tracked_buildings[id]
		var node: Node = record.node.get_ref()
		if node == null:
			vanished.append(id)
		elif node is BuildingAgent:
			# _signature_changed's typed branch, inlined: this runs for every
			# building on every tick.
			var building: BuildingAgent = node
			var signature: Array = record.signature
			var changed: bool
			if building.is_queued_for_deletion() or building.is_placement_ghost:
				changed = not signature.is_empty()
			else:
				var half := building.get_movement_half()
				if half.x <= 0.0 or half.y <= 0.0: changed = not signature.is_empty()
				else: changed = signature.size() != 2 or signature[0] != building.sim_pos or signature[1] != half
			if changed: _queue_static_rebuild()
		elif _signature_changed(record.signature, node):
			_queue_static_rebuild()
	for id in vanished:
		_tracked_buildings.erase(id)
		_queue_static_rebuild()


## record.signature != _building_signature(node) without building the array:
## this poll covers every building on every tick.
func _signature_changed(signature: Array, node: Node) -> bool:
	if node is not BuildingAgent: return signature != _building_signature(node)
	var building: BuildingAgent = node
	if building.is_queued_for_deletion() or building.is_placement_ghost: return not signature.is_empty()
	var half := building.get_movement_half()
	if half.x <= 0.0 or half.y <= 0.0: return not signature.is_empty()
	return signature.size() != 2 or signature[0] != building.sim_pos or signature[1] != half


func _queue_static_rebuild() -> void:
	_static_dirty = true
	if lockstep_enabled: return
	if not _rebuild_queued and is_inside_tree():
		_rebuild_queued = true
		call_deferred("_rebuild_if_dirty")


func _rebuild_if_dirty() -> void:
	_rebuild_queued = false
	if lockstep_enabled: return
	if is_inside_tree() and _static_dirty: rebuild_from_scene()

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
