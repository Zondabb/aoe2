extends Node

const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const Memory := preload("res://scripts/presentation/fog_memory.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
const Terrain := preload("res://scripts/presentation/terrain_visual.gd")
const ALL := -1
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
var _static_records: Array[Dictionary] = []
var _shown: Dictionary = {}
var _static_seen := {0: {}, 1: {}}
var _seen_geometry: Dictionary = {}
var _static_seen_revision := -1
var _proxy_states: Dictionary = {}
var _resource_visual_cache: Dictionary = {}

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
	add_to_group("fog_of_war")
	_create_overlay()
	_create_debug_panel()
	match_state.team_color_changed.connect(func(_team: int):
		_refresh_choice_labels()
		for key in _resource_visual_cache: _resource_visual_dirty(key))
	entities.child_entered_tree.connect(_entity_changed)
	entities.child_exiting_tree.connect(_entity_changed)
	rebuild_now()
	_sync_debug_ui()
	get_viewport().size_changed.connect(_layout_debug_ui)
	_layout_debug_ui()

func _entity_changed(node: Node) -> void:
	if node.has_meta("fog_memory"):
		return
	_dirty = true
	_entities_dirty = true
	# Prevent newly spawned enemies being rendered before the next visibility tick.
	if node is CanvasItem and node.get("sim_pos") != null:
		node.visible = view_can_see(node)

func _physics_process(delta: float) -> void:
	_elapsed += delta
	if not match_state.frozen and (_dirty or fog.dirty or _elapsed >= 0.1):
		rebuild_now()
	else:
		# Moving enemies can cross a visibility cell between fog updates. Static
		# trees and their memory proxies only need a pass when fog is rebuilt.
		_apply_visibility(_entities_dirty)

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
			_static_records.append({"entity":node, "id":id, "kind":static_kind, "resource":resource,
				"team":node.get("team"), "definition":definition, "position":node.get("sim_pos"), "footprint":footprint,
				"cells":fog.footprint_cells(node.get("sim_pos"), footprint), "size_override":node.get("block_size_override")})
			if static_kind == "resource": _track_resource_visual(node, id)
		if node.get("hp") != null and node.get("team") in Enums.Team.values(): _vision_sources.append(node)
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

func _refresh_static_record(record: Dictionary) -> bool:
	var node: Node2D = record.entity
	if not is_instance_valid(node) or node.is_queued_for_deletion():
		_entities_dirty = true
		return false
	var position: Vector2 = node.get("sim_pos")
	record.team = node.get("team")
	var footprint: Vector2 = record.footprint
	if record.kind == "building":
		var definition: Variant = node.get("def")
		if definition != record.definition:
			record.definition = definition
			footprint = Fog.footprint_of(node)
	elif record.resource or record.kind == "blocker":
		var override: Variant = node.get("block_size_override")
		if override is Vector2:
			if override != record.size_override:
				record.size_override = override
				footprint = Fog.footprint_of(node)
		else:
			var size: Variant = node.get("block_size")
			if size is Vector2: footprint = size
	if position != record.position or footprint != record.footprint:
		record.position = position
		record.footprint = footprint
		record.cells = fog.footprint_cells(position, footprint)
	return true

func _update_memories(_nodes: Array) -> void:
	_ensure_entity_cache()
	var observed := {0:{}, 1:{}}
	_static_seen = {0:{}, 1:{}}
	_seen_geometry.clear()
	var seen_at := Time.get_ticks_msec()
	for record in _static_records:
		if not _refresh_static_record(record): continue
		var node: Node2D = record.entity
		if node.is_in_group("terrain_regions"): Terrain.bind_fog(node, self)
		var key: int = record.id
		_seen_geometry[key] = Rect2(record.position, record.footprint)
		var appearance := 0
		var appearance_ready := false
		var captured: Array = []
		for team in Enums.Team.values():
			var seen: bool = fog.ready and fog.rect_visible(team, record.cells)
			_static_seen[team][key] = seen
			if not seen or record.team == team or node.get("is_placement_ghost") == true: continue
			if (record.resource and node.get("amount") <= 0) or (record.kind == "building" and node.get("hp") != null and node.get("hp") <= 0): continue
			observed[team][key] = true
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
			else:
				if captured.is_empty(): captured = Memory.capture(node)
				parts = captured
			known[key] = {"sim_pos":record.position, "position":node.position, "footprint":record.footprint,
				"cells":record.cells, "parts":parts, "appearance":appearance, "minimap_kind":record.kind,
				"team":record.team, "resource_type":node.get("resource_type"), "kind":node.get("kind"),
				"terrain_region":node.is_in_group("terrain_regions"), "last_seen_msec":seen_at}
	for team in Enums.Team.values():
		var known: Dictionary = fog.memories[team]
		for key in known.keys():
			var snapshot: Dictionary = known[key]
			var cells: Rect2i = snapshot.cells if snapshot.has("cells") else fog.footprint_cells(snapshot.sim_pos, snapshot.footprint)
			if not observed[team].has(key) and fog.rect_visible(team, cells, true): known.erase(key)
	_static_seen_revision = fog.revision

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
	if fog.ready and _static_seen_revision == fog.revision and _seen_geometry.has(id):
		if _seen_geometry[id] == Rect2(position, footprint) and _static_seen.get(team, {}).has(id):
			return _static_seen[team][id]
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
		var visible_visual: bool = not record.resource or float(node.get("amount")) > 0
		var seen := view_team == ALL
		if not seen:
			var hp: Variant = node.get("hp") if record.team == view_team else null
			if hp != null and float(hp) > 0: seen = true
			elif node.get("is_placement_ghost") == true: seen = record.team == view_team
			elif fog.ready:
				seen = bool(_static_seen[view_team].get(record.id, false)) if use_cached_seen else fog.rect_visible(view_team, record.cells)
		_set_entity_visible(node, visible_visual and seen)
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
	for record in _static_records:
		var node: Node2D = record.entity
		if is_instance_valid(node) and node.is_in_group("terrain_regions"):
			Terrain.bind_fog(node, self)
	for proxy in _memory_views.values():
		if is_instance_valid(proxy): Terrain.bind_fog(proxy, self)

func set_view(team: int) -> void:
	if get_parent().get_meta("online_match", false) and team != base_view:
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
