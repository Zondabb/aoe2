extends Node

const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const Memory := preload("res://scripts/presentation/fog_memory.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
const Terrain := preload("res://scripts/presentation/terrain_visual.gd")
const ALL := -1

# These records are read several times per fog update. Typed fields avoid
# hashing the same string keys for every resource and wall in each pass.
class StaticRecord:
	var entity: Node2D
	var id: int
	var kind: String
	var resource: bool
	var team: Variant
	var definition: Variant
	var position: Vector2
	var footprint: Vector2
	var cells: Rect2i
	var size_override: Variant
	var resource_type: Variant
	var seen_mask := 0
	var observed_mask := 0
	var seen_geometry := Rect2()
	var terrain := false
	## FAST_RESOURCE / FAST_BUILDING when the node's script is exactly
	## ResourceNode or BuildingAgent/FarmAgent: their fields are read typed
	## (same values as the property-name path, which other nodes keep).
	var fast := 0

var fog := Fog.new()
var match_state: MatchState
var entities: Node2D
var base_view := Enums.Team.PLAYER
var view_team := Enums.Team.PLAYER
var debug_mode := false
var _elapsed := 0.0
var _dirty := false
var _overlay: Polygon2D
var _texture: ImageTexture
var _texture_revision := -1
var _texture_team := -2
var _memory_views: Dictionary = {}
var _panel: PanelContainer
var _choices: OptionButton
var _stats: Label
var _grid: Node2D
var _grid_check: CheckBox
var _saved_flags: Dictionary = {}
var _saved_selection: Array = []
var _entities_dirty := true
var _live_entities: Array[Node2D] = []
var _dynamic_entities: Array[Node2D] = []
var _vision_sources: Array[Node2D] = []
var _static_records: Array[StaticRecord] = []
var _shown: Dictionary = {}
var _records_by_id: Dictionary = {}
var _static_seen_revision := -1
var _proxy_states: Dictionary = {}
var _resource_visual_cache: Dictionary = {}
## Cell rectangles of _static_records ([x, y, w, h] each) for the native
## per-revision visibility pass; rebuilt when a record's cells change.
var _static_rects := PackedInt32Array()
var _static_rects_dirty := true
static var _kernel: RefCounted = ClassDB.instantiate("AoeSimKernel") if ClassDB.class_exists("AoeSimKernel") and ClassDB.class_has_method("AoeSimKernel", "fog_rects_seen") else null
## Lockstep matches rebuild the visibility grids inside every simulation step;
## textures, remembered objects and node visibility follow on render frames.
const LOCKSTEP_PRESENTATION_USEC := 100000
var _lockstep_presentation := false
## Single player: the grids follow every 0.1 s of game time, but textures,
## memories and static visibility are drawn at most every 0.09 s of real time
## (game speed above 1x, or physics catching up after a long frame, would
## otherwise redraw them several times per shown frame); _process draws the
## latest state once the interval has passed.
const PRESENTATION_INTERVAL_USEC := 90000
var _presented_frame := -1
var _presented_tick := -1
var _deferred_presentation := false
const TEAMS := [Enums.Team.PLAYER, Enums.Team.AI]
const FAST_RESOURCE := 1
const FAST_BUILDING := 2
static var _farm_script: Script = load("res://scripts/entities/farm_agent.gd")
## Records of terrain regions (lakes, cliffs): the only nodes bind_fog touches.
var _terrain_records: Array[StaticRecord] = []
## ResourceNode.geometry_revision when every record last matched its node.
var _resource_geometry_stamp := -1
var _presentation_dirty := false
var _dynamic_dirty := false
var _presentation_usec := 0

static func install(root: Node, state: MatchState, minimum: float, maximum: float, default_view := 0) -> void:
	install_rect(root, state, Vector2(minimum, minimum), Vector2(maximum, maximum), default_view)

static func install_rect(root: Node, state: MatchState, minimum: Vector2, maximum: Vector2, default_view := 0) -> void:
	if root == null or not root.is_inside_tree():
		return
	if root.has_meta("fog_holder"):
		var existing: Node = root.get_meta("fog_holder")
		existing.reset_match()
		return
	var holder := load("res://scripts/systems/fog_of_war_holder.gd").new() as Node
	holder.name = "FogOfWar"
	holder.match_state = state
	holder.entities = root.get_node("Entities")
	holder.base_view = default_view
	holder.view_team = default_view
	# Larger maps use one fog cell per converted original tile. Keep fine cells
	# for small authored arenas, and avoid scanning 480² cells at every update.
	var span := maximum - minimum
	var cell_size := 4.0 if maxf(span.x, span.y) > 256.0 else 1.0
	holder.fog.setup_rect(minimum, maximum, cell_size)
	state.fog_enabled = true
	state.fog = holder.fog
	root.set_meta("fog_holder", holder)
	root.set_meta("fog", holder.fog)
	root.add_child(holder)

func _ready() -> void:
	# Before units/AI physics; each match owns its holder and all visual caches.
	process_physics_priority = -100
	# Deferred presentation runs before the minimap and HUD read its caches.
	process_priority = -100
	fog.static_cache = self
	add_to_group("fog_of_war")
	_create_overlay()
	_create_debug_panel()
	match_state.team_color_changed.connect(func(_team: int):
		_refresh_choice_labels()
		for key in _resource_visual_cache: _resource_visual_dirty(key))
	entities.child_entered_tree.connect(_entity_entered)
	entities.child_exiting_tree.connect(_entity_exiting)
	rebuild_now()
	_sync_debug_ui()
	get_viewport().size_changed.connect(_layout_debug_ui)
	_layout_debug_ui()

## Projectiles enter and leave many times a second in combat. They are neither
## vision sources nor static records, so the cached lists are kept in step
## (the same order a rescan gives) instead of rescanning every entity and
## rebuilding the masks for each arrow.
func _entity_entered(node: Node) -> void:
	if node.has_meta("fog_memory"):
		return
	if node is ProjectileAgent and not _entities_dirty and node.get_index() == entities.get_child_count() - 1:
		_live_entities.append(node)
		_dynamic_entities.append(node)
	else:
		_dirty = true
		_entities_dirty = true
	# Prevent newly spawned enemies being rendered before the next visibility tick.
	if node is CanvasItem and node.get("sim_pos") != null:
		node.visible = view_can_see(node)

func _entity_exiting(node: Node) -> void:
	if node.has_meta("fog_memory"):
		return
	if node is ProjectileAgent and not _entities_dirty:
		_live_entities.erase(node)
		_dynamic_entities.erase(node)
		_shown.erase(node.get_instance_id())
		return
	_entity_changed(node)

func _entity_changed(node: Node) -> void:
	if node.has_meta("fog_memory"):
		return
	_dirty = true
	_entities_dirty = true
	# Prevent newly spawned enemies being rendered before the next visibility tick.
	if node is CanvasItem and node.get("sim_pos") != null:
		node.visible = view_can_see(node)

func _physics_process(delta: float) -> void:
	if match_state.lockstep_enabled and not match_state.lockstep_stepping: return
	_elapsed += delta
	if not match_state.frozen and (_dirty or fog.dirty or _elapsed >= 0.1):
		# Only engine physics ticks after the presented one defer; repeated
		# calls within one tick (scripts, tests) still draw at once.
		if Engine.is_in_physics_frame() and not _lockstep_presentation and Engine.get_physics_frames() != _presented_tick \
				and (Time.get_ticks_usec() - _presentation_usec < PRESENTATION_INTERVAL_USEC or Engine.get_process_frames() == _presented_frame):
			rebuild_simulation()
			if not _deferred_presentation:
				_deferred_presentation = true
				set_process(true)
		else:
			rebuild_now()
	else:
		# Moving enemies can cross a visibility cell between fog updates. Static
		# trees and their memory proxies only need a pass when fog is rebuilt.
		_apply_visibility(_entities_dirty)

func set_lockstep_presentation(enabled: bool) -> void:
	_lockstep_presentation = enabled
	set_process(enabled)

func mark_presentation_dirty() -> void:
	_entities_dirty = true
	_presentation_dirty = true
	_dynamic_dirty = true
	_presentation_usec = 0

## Simulation half of rebuild_now(): only the deterministic visibility grids.
func rebuild_simulation() -> void:
	_elapsed = 0.0
	_dirty = false
	_ensure_entity_cache()
	fog.rebuild(_vision_sources)
	_presentation_dirty = true
	_dynamic_dirty = true

## Presentation half for lockstep: the full pass (texture, memories, static
## visibility) at the single-player 10 Hz cadence; moving actors in between.
func _process(_delta: float) -> void:
	if _deferred_presentation and not _lockstep_presentation:
		if not _presentation_dirty or Time.get_ticks_usec() - _presentation_usec >= PRESENTATION_INTERVAL_USEC:
			_deferred_presentation = false
			set_process(false)
			if _presentation_dirty: _present()
		elif _dynamic_dirty:
			_dynamic_dirty = false
			_apply_visibility(false)
		return
	if not _lockstep_presentation or not _presentation_dirty: return
	var now := Time.get_ticks_usec()
	if now - _presentation_usec >= LOCKSTEP_PRESENTATION_USEC:
		_presentation_usec = now
		_presentation_dirty = false
		_dynamic_dirty = false
		_sync_texture()
		_update_memories(_live_entities)
		_apply_visibility(true, true)
		_update_stats()
	elif _dynamic_dirty:
		_dynamic_dirty = false
		_apply_visibility(false)

func reset_match() -> void:
	if debug_mode:
		set_debug_mode(false)
	fog.reset()
	_clear_memory_views()
	_entities_dirty = true
	view_team = base_view
	rebuild_now()
	_refresh_choice_labels()
	_choices.select(view_team + 1)

func rebuild_now() -> void:
	_elapsed = 0.0
	_dirty = false
	_ensure_entity_cache()
	fog.rebuild(_vision_sources)
	_present()

func _present() -> void:
	_presentation_dirty = false
	_dynamic_dirty = false
	_presented_frame = Engine.get_process_frames()
	_presented_tick = Engine.get_physics_frames()
	_presentation_usec = Time.get_ticks_usec()
	_sync_texture()
	_update_memories(_live_entities)
	_apply_visibility(true, true)
	_update_stats()

func _ensure_entity_cache() -> void:
	if not _entities_dirty: return
	_entities_dirty = false
	_live_entities.clear()
	_dynamic_entities.clear()
	_vision_sources.clear()
	_static_records.clear()
	_terrain_records.clear()
	# A trained/lost unit changes these lists without changing the forest or
	# wall records. Reuse those records instead of allocating thousands again.
	var existing_records := _records_by_id
	_records_by_id = {}
	_static_seen_revision = -1
	_static_rects_dirty = true
	var alive_ids := {}
	for node in entities.get_children():
		if node is not Node2D or node.has_meta("fog_memory") or node.get("sim_pos") == null or node.is_queued_for_deletion(): continue
		_live_entities.append(node)
		var id: int = node.get_instance_id()
		alive_ids[id] = true
		var definition: Variant = node.get("def")
		var resource: bool = node.has_method("extract")
		var static_kind := "building" if definition is BuildingDef else ("resource" if resource else ("blocker" if node.is_in_group("path_blockers") else ""))
		if static_kind.is_empty():
			_dynamic_entities.append(node)
		else:
			var footprint := Fog.footprint_of(node)
			var record: StaticRecord = existing_records.get(id)
			if record == null: record = StaticRecord.new()
			record.entity = node
			record.id = id
			record.kind = static_kind
			record.resource = resource
			record.terrain = node.is_in_group("terrain_regions")
			var script: Script = node.get_script()
			record.fast = FAST_RESOURCE if script == ResourceNode else (FAST_BUILDING if (script == BuildingAgent or script == _farm_script) and static_kind == "building" else 0)
			if record.terrain: _terrain_records.append(record)
			record.team = node.get("team")
			record.definition = definition
			record.position = node.get("sim_pos")
			record.footprint = footprint
			record.cells = fog.footprint_cells(record.position, footprint)
			record.size_override = node.get("block_size_override")
			record.resource_type = node.get("resource_type")
			_static_records.append(record)
			_records_by_id[id] = record
			if static_kind == "resource": _track_resource_visual(node, id)
		if node.get("hp") != null and node.get("team") in Enums.Team.values(): _vision_sources.append(node)
	_resource_geometry_stamp = ResourceNode.geometry_revision
	for id in _shown.keys():
		if not alive_ids.has(id): _shown.erase(id)
	for id in _resource_visual_cache.keys():
		if not alive_ids.has(id): _resource_visual_cache.erase(id)

func _track_resource_visual(node: Node2D, key: int) -> void:
	if _resource_visual_cache.has(key): return
	_resource_visual_cache[key] = {"dirty":true, "children_dirty":true, "visuals":[], "values":[], "parts":[], "appearance":0}
	var changed := _resource_visual_dirty.bind(key)
	var children_changed := _resource_visual_children_changed.bind(key)
	node.visibility_changed.connect(changed)
	node.child_entered_tree.connect(children_changed)
	node.child_exiting_tree.connect(children_changed)

func _resource_visual_dirty(key: int) -> void:
	if _resource_visual_cache.has(key): _resource_visual_cache[key].dirty = true

func _resource_visual_children_changed(_child: Node, key: int) -> void:
	if _resource_visual_cache.has(key):
		_resource_visual_cache[key].children_dirty = true
		_resource_visual_cache[key].dirty = true

func _resource_snapshot(node: Node2D, key: int) -> Dictionary:
	var cached: Dictionary = _resource_visual_cache[key]
	if cached.children_dirty:
		cached.visuals = Memory.visual_nodes(node)
		cached.children_dirty = false
		var changed := _resource_visual_dirty.bind(key)
		for child in cached.visuals:
			for signal_name in ["item_rect_changed", "visibility_changed", "texture_changed", "frame_changed"]:
				if child.has_signal(signal_name) and not child.is_connected(signal_name, changed): child.connect(signal_name, changed)
	var values := Memory.resource_values(node, cached.visuals)
	if cached.dirty or cached.values != values:
		var changed := _resource_visual_dirty.bind(key)
		for child in cached.visuals:
			if is_instance_valid(child) and child.material != null and not child.material.changed.is_connected(changed): child.material.changed.connect(changed)
		cached.values = values
		cached.appearance = Memory.appearance_key(node)
		cached.parts = Memory.capture(node)
		cached.dirty = false
	return cached

func _refresh_static_record(record: StaticRecord) -> bool:
	var node: Node2D = record.entity
	if not is_instance_valid(node) or node.is_queued_for_deletion():
		_entities_dirty = true
		return false
	var position: Vector2
	var footprint: Vector2 = record.footprint
	if record.fast == FAST_RESOURCE:
		var tree: ResourceNode = node
		position = tree.sim_pos
		record.team = null
		if tree.block_size_override != record.size_override or tree.resource_type != record.resource_type:
			record.size_override = tree.block_size_override
			record.resource_type = tree.resource_type
			footprint = tree.block_size
	elif record.fast == FAST_BUILDING:
		var building: BuildingAgent = node
		position = building.sim_pos
		record.team = building.team
		if building.def != record.definition:
			record.definition = building.def
			footprint = Fog.footprint_of(node)
	else:
		position = node.get("sim_pos")
		record.team = node.get("team")
		if record.kind == "building":
			var definition: Variant = node.get("def")
			if definition != record.definition:
				record.definition = definition
				footprint = Fog.footprint_of(node)
		elif node is ResourceNode:
			var resource: ResourceNode = node
			if resource.block_size_override != record.size_override or resource.resource_type != record.resource_type:
				record.size_override = resource.block_size_override
				record.resource_type = resource.resource_type
				footprint = resource.block_size
		elif record.resource or record.kind == "blocker":
			var override: Variant = node.get("block_size_override")
			var resource_type: Variant = node.get("resource_type") if record.resource else null
			var type_changed: bool = resource_type != record.resource_type
			record.resource_type = resource_type
			if override is Vector2:
				if override != record.size_override or type_changed:
					record.size_override = override
					footprint = Fog.footprint_of(node)
			else:
				var size: Variant = node.get("block_size")
				if size is Vector2: footprint = size
	if position != record.position or footprint != record.footprint:
		record.position = position
		record.footprint = footprint
		record.cells = fog.footprint_cells(position, footprint)
		# Cells and the geometry seen_geometry records both follow the record.
		_static_rects_dirty = true
		_static_seen_revision = -1
	return true

## seen_mask (bit per team: any covered cell visible now) of every static
## record from its current cells, and the geometry those cells belong to.
## Records whose `valid` byte is 0 are left unseen, as _update_memories did.
func _compute_seen_masks(valid := PackedByteArray()) -> void:
	var count := _static_records.size()
	var bits := PackedByteArray()
	# seen_geometry only changes with a record's geometry, which marks the
	# rectangles dirty (as does every entity-cache rebuild).
	var geometry_changed := _static_rects_dirty or _static_rects.size() != count * 4
	if fog.ready and _kernel != null:
		if _static_rects_dirty or _static_rects.size() != count * 4:
			_static_rects.resize(count * 4)
			var at := 0
			for record in _static_records:
				var cells := record.cells
				_static_rects[at] = cells.position.x
				_static_rects[at + 1] = cells.position.y
				_static_rects[at + 2] = cells.size.x
				_static_rects[at + 3] = cells.size.y
				at += 4
			_static_rects_dirty = false
		bits = _kernel.fog_rects_seen(_static_rects, fog.visible_now.get(Enums.Team.PLAYER, PackedByteArray()), fog.visible_now.get(Enums.Team.AI, PackedByteArray()), fog.side, fog.grid_size.y)
	var check_valid := not valid.is_empty()
	for index in count:
		var record := _static_records[index]
		if check_valid and valid[index] == 0:
			record.seen_mask = 0
			continue
		var mask := 0
		if fog.ready:
			if _kernel != null:
				mask = bits[index]
			else:
				for team in TEAMS:
					if fog.rect_visible(team, record.cells): mask |= 1 << team
		record.seen_mask = mask
		if geometry_changed: record.seen_geometry = Rect2(record.position, record.footprint)
	if _kernel == null: _static_rects_dirty = false
	_static_seen_revision = fog.revision

## FogOfWarService.can_see for a static entity from the per-revision record
## cache: 1 or 0, or -1 when its record, geometry or the cache is unavailable.
## Never rebuilds the entity lists, which callers may be iterating.
func cached_static_seen(team: int, node: Object) -> int:
	if _entities_dirty or not fog.ready or not fog.visible_now.has(team): return -1
	var record: StaticRecord = _records_by_id.get(node.get_instance_id())
	if record == null: return -1
	var footprint: Vector2
	if node is ResourceNode: footprint = (node as ResourceNode).block_size
	elif node is BuildingAgent and (node as BuildingAgent).def != null: footprint = (node as BuildingAgent).def.footprint
	else: return -1
	if _static_seen_revision != fog.revision: _compute_seen_masks()
	if record.seen_geometry != Rect2(node.sim_pos, footprint): return -1
	return (record.seen_mask >> team) & 1

func _update_memories(_nodes: Array) -> void:
	_ensure_entity_cache()
	var seen_at := Time.get_ticks_msec()
	# Refresh every record's geometry, then test all cell rectangles in one
	# pass (native when available), then take memory snapshots.
	var valid := PackedByteArray()
	valid.resize(_static_records.size())
	for index in _static_records.size():
		var record := _static_records[index]
		record.observed_mask = 0
		if record.fast != FAST_RESOURCE:
			valid[index] = 1 if _refresh_static_record(record) else 0
			continue
		# _refresh_static_record's resource branch inline: most records are
		# trees and mines, and the call itself was a large share of this loop.
		var entity: Variant = record.entity
		if not is_instance_valid(entity) or entity.is_queued_for_deletion():
			_entities_dirty = true
			valid[index] = 0
			continue
		var tree: ResourceNode = entity
		valid[index] = 1
		record.team = null
		var footprint: Vector2 = record.footprint
		if tree.block_size_override != record.size_override or tree.resource_type != record.resource_type:
			record.size_override = tree.block_size_override
			record.resource_type = tree.resource_type
			footprint = tree.block_size
		var position := tree.sim_pos
		if position != record.position or footprint != record.footprint:
			record.position = position
			record.footprint = footprint
			record.cells = fog.footprint_cells(position, footprint)
			_static_rects_dirty = true
			_static_seen_revision = -1
	_resource_geometry_stamp = ResourceNode.geometry_revision
	_compute_seen_masks(valid)
	for index in _static_records.size():
		if valid[index] == 0: continue
		var record := _static_records[index]
		var node: Node2D = record.entity
		if record.terrain: Terrain.bind_fog(node, self)
		# Unseen by both teams: no memory changes (most of the forest).
		if record.seen_mask == 0: continue
		var key: int = record.id
		var appearance := 0
		var appearance_ready := false
		var captured: Array = []
		# Facts about the node, read once for both teams (nothing changes them
		# in between): -1 until a team needs them.
		var eligible := -1
		var resource_type: Variant = null
		var kind: Variant = null
		var terrain_region := false
		for team in TEAMS:
			if (record.seen_mask & (1 << team)) == 0 or record.team == team: continue
			if eligible < 0:
				eligible = 1 if _memory_eligible(record, node) else 0
				if record.fast == FAST_RESOURCE: resource_type = (node as ResourceNode).resource_type
				elif record.fast == FAST_BUILDING: resource_type = (node as BuildingAgent).resource_type
				else:
					resource_type = node.get("resource_type")
					kind = node.get("kind")
				terrain_region = node.is_in_group("terrain_regions")
			if eligible == 0: continue
			record.observed_mask |= 1 << team
			var known: Dictionary = fog.memories[team]
			var previous: Dictionary = known.get(key, {})
			if not appearance_ready:
				if record.kind == "resource":
					var resource_snapshot := _resource_snapshot(node, key)
					appearance = resource_snapshot.appearance
					captured = resource_snapshot.parts
				else: appearance = Memory.appearance_key(node)
				appearance_ready = true
			var parts: Array
			if not previous.is_empty() and previous.get("appearance") == appearance:
				parts = previous.parts
				# An unchanged sighting only refreshes its time; most visible trees
				# and walls are seen again on every pass.
				if previous.size() == 12 and previous.has("last_seen_msec") and previous.sim_pos == record.position and previous.position == node.position \
						and previous.footprint == record.footprint and previous.cells == record.cells and previous.minimap_kind == record.kind \
						and previous.team == record.team and previous.resource_type == resource_type and previous.kind == kind \
						and previous.terrain_region == terrain_region:
					previous.last_seen_msec = seen_at
					continue
			else:
				if captured.is_empty(): captured = Memory.capture(node)
				parts = captured
			known[key] = {"sim_pos":record.position, "position":node.position, "footprint":record.footprint,
				"cells":record.cells, "parts":parts, "appearance":appearance, "minimap_kind":record.kind,
				"team":record.team, "resource_type":resource_type, "kind":kind,
				"terrain_region":terrain_region, "last_seen_msec":seen_at}
	for team in TEAMS:
		var known: Dictionary = fog.memories[team]
		var bit: int = 1 << team
		for key in known.keys():
			# Observed this pass: kept regardless of its cells.
			var record: StaticRecord = _records_by_id.get(key)
			if record != null and (record.observed_mask & bit) != 0: continue
			var snapshot: Dictionary = known[key]
			var cells: Rect2i = snapshot.cells if snapshot.has("cells") else fog.footprint_cells(snapshot.sim_pos, snapshot.footprint)
			if fog.rect_visible(team, cells, true): known.erase(key)
	_static_seen_revision = fog.revision

## Whether a seen static node can enter a team's memory (not a placement
## ghost, depleted resource or destroyed building).
func _memory_eligible(record: StaticRecord, node: Node2D) -> bool:
	if record.fast == FAST_RESOURCE:
		return (node as ResourceNode).amount_q > 0
	if record.fast == FAST_BUILDING:
		var building: BuildingAgent = node
		return not building.is_placement_ghost and (not record.resource or building.amount_q > 0) and building.hp_q > 0
	if node.get("is_placement_ghost") == true: return false
	return not ((record.resource and node.get("amount") <= 0) or (record.kind == "building" and node.get("hp") != null and node.get("hp") <= 0))

## Consumers must treat the shared list as read-only. It excludes visual
## memory proxies, while retaining hidden real entities for team queries.
func live_entities() -> Array[Node2D]:
	_ensure_entity_cache()
	return _live_entities

## Reuse only visibility evaluated for this exact geometry and fog revision.
## Mobile/new/changed actors and externally rebuilt masks use the live query.
func entity_visible_for(team: int, node: Variant, position: Vector2, footprint: Vector2) -> bool:
	if not is_instance_valid(node) or node is not Node2D: return false
	if node.get("is_placement_ghost") == true: return node.get("team") == team
	if node.get("team") == team and node.get("hp") != null and float(node.get("hp")) > 0: return true
	var id: int = node.get_instance_id()
	var record: StaticRecord = _records_by_id.get(id)
	if fog.ready and _static_seen_revision != fog.revision and record != null and not _entities_dirty: _compute_seen_masks()
	if fog.ready and _static_seen_revision == fog.revision and record != null and fog.visible_now.has(team):
		if record.seen_geometry == Rect2(position, footprint):
			return (record.seen_mask & (1 << team)) != 0
	return fog.can_see(team, node)

func view_can_see(node: Node) -> bool:
	return view_team == ALL or fog.can_see(view_team, node)

func _apply_visibility(update_static := true, use_cached_seen := false) -> void:
	_ensure_entity_cache()
	for node in _dynamic_entities:
		if is_instance_valid(node): _set_entity_visible(node, view_can_see(node))
	if not update_static: return
	for record in _static_records:
		var node: Node2D = record.entity
		# rebuild_now just refreshed every static geometry in _update_memories.
		# Reuse that pass when consuming its visibility; external calls still
		# refresh geometry before consulting the current mask.
		if use_cached_seen:
			if not is_instance_valid(node) or node.is_queued_for_deletion(): continue
		elif not _refresh_static_record(record): continue
		var visible_visual: bool
		var seen := view_team == ALL
		if record.fast == FAST_RESOURCE:
			# No team, health or ghost state: only the fog test applies.
			visible_visual = (node as ResourceNode).amount_q > 0
			if not seen and fog.ready:
				seen = (record.seen_mask & (1 << view_team)) != 0 if use_cached_seen else fog.rect_visible(view_team, record.cells)
		elif record.fast == FAST_BUILDING:
			var building: BuildingAgent = node
			visible_visual = not record.resource or building.amount_q > 0
			if not seen:
				if record.team == view_team and building.hp_q > 0: seen = true
				elif building.is_placement_ghost: seen = record.team == view_team
				elif fog.ready:
					seen = (record.seen_mask & (1 << view_team)) != 0 if use_cached_seen else fog.rect_visible(view_team, record.cells)
		else:
			visible_visual = not record.resource or float(node.get("amount")) > 0
			if not seen:
				var hp: Variant = node.get("hp") if record.team == view_team else null
				if hp != null and float(hp) > 0: seen = true
				elif node.get("is_placement_ghost") == true: seen = record.team == view_team
				elif fog.ready:
					seen = (record.seen_mask & (1 << view_team)) != 0 if use_cached_seen else fog.rect_visible(view_team, record.cells)
		# _set_entity_visible(node, visible_visual and seen), inlined.
		var value := visible_visual and seen
		if node.visible != value:
			node.visible = value
			if not value and node.has_method("set_selected"): node.call("set_selected", false)
		if value: _shown[record.id] = true
		else: _shown.erase(record.id)
	_sync_memory_views()

func _set_entity_visible(node: Node2D, value: bool) -> void:
	var key := node.get_instance_id()
	if node.visible != value:
		node.visible = value
		if not value and node.has_method("set_selected"): node.call("set_selected", false)
	if value: _shown[key] = true
	else: _shown.erase(key)

func _sync_memory_views() -> void:
	var known: Dictionary = fog.memories.get(view_team, {})
	for key in _memory_views.keys():
		if not known.has(key):
			_memory_views[key].hide()
			_memory_views[key].queue_free()
			_memory_views.erase(key)
			_proxy_states.erase(key)
	for key in known:
		if _shown.has(key):
			if _memory_views.has(key): _memory_views[key].hide()
			continue
		var proxy: Node2D = _memory_views.get(key)
		if proxy == null:
			proxy = Memory.make_view(known[key])
			entities.add_child(proxy)
			_memory_views[key] = proxy
			_proxy_states[key] = [known[key].appearance, known[key].position]
		else:
			var previous: Array = _proxy_states[key]
			if previous[0] != known[key].appearance or previous[1] != known[key].position:
				Memory.update_view(proxy, known[key])
				_proxy_states[key] = [known[key].appearance, known[key].position]
		if known[key].get("terrain_region", false): Terrain.bind_fog(proxy, self)
		if not proxy.visible: proxy.show()

func _clear_memory_views() -> void:
	for proxy in _memory_views.values():
		proxy.hide()
		proxy.queue_free()
	_memory_views.clear()
	_proxy_states.clear()

func _create_overlay() -> void:
	_grid = preload("res://scripts/presentation/fog_grid_overlay.gd").new()
	_grid.holder = self
	_grid.z_index = 81
	_grid.visible = false
	get_parent().add_child(_grid)
	_overlay = Polygon2D.new()
	_overlay.name = "FogOverlay"
	_overlay.z_index = -50
	_overlay.polygon = PackedVector2Array([Vector2(-100000,-100000), Vector2(100000,-100000), Vector2(100000,100000), Vector2(-100000,100000)])
	var material := ShaderMaterial.new()
	material.shader = preload("res://scripts/presentation/fog_overlay.gdshader")
	material.set_shader_parameter("logical_min", fog.map_origin)
	material.set_shader_parameter("logical_span", fog.map_end-fog.map_origin)
	_overlay.material = material
	get_parent().add_child(_overlay)

func _sync_texture() -> void:
	_overlay.visible = view_team != ALL
	if view_team == ALL:
		_bind_terrain_fog()
		return
	if _texture_revision == fog.revision and _texture_team == view_team:
		return
	_texture_revision = fog.revision
	_texture_team = view_team
	var data := fog.mask_image(view_team)
	if _texture == null:
		_texture = ImageTexture.create_from_image(data)
		_overlay.material.set_shader_parameter("fog_mask", _texture)
	else:
		_texture.update(data)
	_bind_terrain_fog()

func _bind_terrain_fog() -> void:
	for record in _terrain_records:
		var node: Node2D = record.entity
		if is_instance_valid(node) and node.is_in_group("terrain_regions"):
			Terrain.bind_fog(node, self)
	for proxy in _memory_views.values():
		if is_instance_valid(proxy): Terrain.bind_fog(proxy, self)

func set_view(team: int) -> void:
	if get_parent().get_meta("online_match", false) and not get_parent().get_meta("spectator", false) and team != base_view:
		return
	if team != ALL and team not in Enums.Team.values():
		return
	view_team = team
	_clear_selection()
	_clear_memory_views()
	_sync_texture()
	_apply_visibility()
	_update_stats()
	var overlay := get_parent().get_node_or_null("NavDebugOverlay")
	if overlay != null:
		overlay.set("view_team", team)
	_choices.select(team + 1)

## Spectator perspective is presentation only. The command identity stays -1.
func set_spectator_view(team: int) -> bool:
	if not get_parent().get_meta("spectator", false) or team not in [-1, 0, 1]:
		return false
	set_view(team)
	return view_team == team

func set_debug_mode(enabled: bool) -> void:
	if enabled and get_parent().get_meta("online_match", false):
		return
	if debug_mode == enabled:
		return
	debug_mode = enabled
	var selection := get_parent().get_node_or_null("UILayer/SelectionController")
	var hud := get_parent().get_node_or_null("UILayer/HUD")
	if enabled:
		if selection != null:
			_saved_flags = {"read_only": selection.read_only, "select_all_teams": selection.select_all_teams}
			_saved_selection = selection.get("_selected").duplicate()
			selection.read_only = true
			selection.select_all_teams = true
		if hud != null:
			_saved_flags["hud_read_only"] = hud.read_only
			hud.read_only = true
		var build := get_parent().get_node_or_null("BuildSystem")
		if build != null:
			build.cancel_placement()
		_clear_selection()
	else:
		set_view(base_view)
		if selection != null and not _saved_flags.is_empty():
			selection.read_only = _saved_flags.read_only
			selection.select_all_teams = _saved_flags.select_all_teams
			for entity in _saved_selection:
				if is_instance_valid(entity) and view_can_see(entity) and (selection.select_all_teams or entity.get("team") == Enums.Team.PLAYER):
					selection.call("_add_selection", entity)
		if hud != null:
			hud.read_only = _saved_flags.get("hud_read_only", false)
			hud.call("_rebuild_command_grid")
		_saved_selection.clear()
	_sync_debug_ui()
	_update_stats()

func _clear_selection() -> void:
	var selection := get_parent().get_node_or_null("UILayer/SelectionController")
	if selection != null:
		selection.set("_dragging", false)
		selection.call("_clear_selection")
		selection.queue_redraw()
	var legacy := get_parent().get_node_or_null("UILayer/TestController")
	if legacy != null:
		for unit in legacy.get("_selected"):
			if is_instance_valid(unit):
				unit.set_selected(false)
		legacy.get("_selected").clear()

func _sync_debug_ui() -> void:
	_panel.visible = debug_mode
	_grid.visible = debug_mode and _grid_check.button_pressed
	var old_panel := get_parent().get_node_or_null("UILayer/PathfindingDebugPanel")
	if old_panel != null:
		old_panel.visible = debug_mode
	var overlay := get_parent().get_node_or_null("NavDebugOverlay")
	if overlay != null:
		overlay.visible = debug_mode
		overlay.set("debug_enabled", debug_mode)
		overlay.set("view_team", view_team)
		overlay.refresh_debug_state()
	var legacy := get_parent().get_node_or_null("PathDebug")
	if legacy != null:
		legacy.visible = debug_mode
	var help := get_parent().get_node_or_null("UILayer/HelpPanel")
	if help != null:
		help.visible = not debug_mode

func _layout_debug_ui() -> void:
	var old_panel := get_parent().get_node_or_null("UILayer/PathfindingDebugPanel") as Control
	if old_panel != null:
		old_panel.position = Vector2(get_viewport().get_visible_rect().size.x - old_panel.size.x - 12, 70)

func _unhandled_input(event: InputEvent) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if event.is_action_pressed("toggle_debug_mode") and not event.is_echo():
		set_debug_mode(not debug_mode)
		get_viewport().set_input_as_handled()

func _create_debug_panel() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	_panel = PanelContainer.new()
	_panel.position = Vector2(12, 70)
	_panel.custom_minimum_size = Vector2(285, 0)
	layer.add_child(_panel)
	var box := VBoxContainer.new()
	_panel.add_child(box)
	var title := Label.new()
	title.text = "战争迷雾调试 · 只读观战 · G 退出"
	box.add_child(title)
	_choices = OptionButton.new()
	_choices.add_item("全图可见")
	_choices.add_item("玩家")
	_choices.add_item("AI")
	_refresh_choice_labels()
	_choices.select(view_team + 1)
	_choices.item_selected.connect(func(index: int): set_view(index - 1))
	box.add_child(_choices)
	_stats = Label.new()
	box.add_child(_stats)
	_grid_check = CheckBox.new()
	_grid_check.text = "显示迷雾逻辑网格"
	_grid_check.toggled.connect(func(on: bool): _grid.visible = debug_mode and on)
	box.add_child(_grid_check)
	var hint := Label.new()
	hint.text = "黑色：未探索    暗色：已探索\n右侧面板可切换视野圈、网格与路径"
	box.add_child(hint)

func _refresh_choice_labels() -> void:
	for team in Enums.Team.values():
		var civ_name := "玩家" if team == Enums.Team.PLAYER else "AI"
		for node in entities.get_children():
			if node.get("team") == team and node.get("civ") != null:
				civ_name += " · " + String(node.get("civ").id)
				break
		_choices.set_item_text(team + 1, "%s · 玩家色 %d" % [civ_name, match_state.get_team_color_id(team)])

func _update_stats() -> void:
	if _stats == null or not debug_mode:
		return
	if view_team == ALL:
		_stats.text = "全知显示不改变双方探索记录\n更新 %.2f ms" % fog.elapsed_ms
		return
	var visible_count := 0
	var explored_count := 0
	for value in fog.visible_now[view_team]:
		visible_count += int(value != 0)
	for value in fog.explored[view_team]:
		explored_count += int(value != 0)
	var total := float(fog.grid_size.x * fog.grid_size.y)
	_stats.text = "可见 %.1f%%  已探索 %.1f%%\n视野源 %d  更新 %.2f ms" % [visible_count*100/total, explored_count*100/total, fog.source_counts[view_team], fog.elapsed_ms]
