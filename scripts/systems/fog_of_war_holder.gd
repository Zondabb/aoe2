extends Node

const Fog := preload("res://scripts/systems/fog_of_war_service.gd")
const Memory := preload("res://scripts/presentation/fog_memory.gd")
const Iso := preload("res://scripts/presentation/iso_math.gd")
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

static func install(root: Node, state: MatchState, minimum: float, maximum: float, default_view := 0) -> void:
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
	holder.fog.setup(minimum, maximum)
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
	match_state.team_color_changed.connect(func(_team: int): _refresh_choice_labels())
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
	# Prevent newly spawned enemies being rendered before the next visibility tick.
	if node is CanvasItem and node.get("sim_pos") != null:
		node.visible = view_can_see(node)

func _physics_process(delta: float) -> void:
	_elapsed += delta
	if not match_state.frozen and (_dirty or fog.dirty or _elapsed >= 0.1):
		rebuild_now()
	else:
		_apply_visibility()

func reset_match() -> void:
	if debug_mode:
		set_debug_mode(false)
	fog.reset()
	_clear_memory_views()
	view_team = base_view
	rebuild_now()
	_refresh_choice_labels()
	_choices.select(view_team + 1)

func rebuild_now() -> void:
	_elapsed = 0.0
	_dirty = false
	var nodes := entities.get_children()
	fog.rebuild(nodes)
	_update_memories(nodes)
	_sync_texture()
	_apply_visibility()
	_update_stats()

func _update_memories(nodes: Array) -> void:
	for team in Enums.Team.values():
		var known: Dictionary = fog.memories[team]
		var observed: Dictionary = {}
		for node in nodes:
			if node.get("team") == team or node.get("is_placement_ghost") == true:
				continue
			if node.get("def") is not BuildingDef and not node.has_method("extract") and not node.is_in_group("path_blockers"):
				continue
			if not fog.can_see(team, node):
				continue
			var key: int = node.get_instance_id()
			if (node.has_method("extract") and node.get("amount") <= 0) or (node.get("hp") != null and node.get("hp") <= 0):
				continue
			observed[key] = true
			known[key] = {"sim_pos": node.get("sim_pos"), "position": node.position,
				"footprint": Fog.footprint_of(node), "parts": Memory.capture(node),
				"last_seen_msec": Time.get_ticks_msec()}
		for key in known.keys():
			var snapshot: Dictionary = known[key]
			if not observed.has(key) and fog.footprint_visible(team, snapshot.sim_pos, snapshot.footprint, true):
				known.erase(key)

func view_can_see(node: Node) -> bool:
	return view_team == ALL or fog.can_see(view_team, node)

func _apply_visibility() -> void:
	var shown: Dictionary = {}
	for node in entities.get_children():
		if node.has_meta("fog_memory") or node is not Node2D:
			continue
		if node.get("sim_pos") == null:
			continue
		var alive_visual := not node.has_method("extract") or float(node.get("amount")) > 0
		node.visible = alive_visual and view_can_see(node)
		if node.visible:
			shown[node.get_instance_id()] = true
		elif node.has_method("set_selected"):
			node.call("set_selected", false)
	var known: Dictionary = fog.memories.get(view_team, {})
	for key in _memory_views.keys():
		if not known.has(key) or shown.has(key):
			_memory_views[key].hide()
			_memory_views[key].queue_free()
			_memory_views.erase(key)
	for key in known:
		if shown.has(key) or _memory_views.has(key):
			continue
		var proxy := Memory.make_view(known[key])
		entities.add_child(proxy)
		_memory_views[key] = proxy

func _clear_memory_views() -> void:
	for proxy in _memory_views.values():
		proxy.hide()
		proxy.queue_free()
	_memory_views.clear()

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
	material.set_shader_parameter("logical_min", Vector2.ONE*fog.map_min)
	material.set_shader_parameter("logical_span", fog.map_max-fog.map_min)
	_overlay.material = material
	get_parent().add_child(_overlay)

func _sync_texture() -> void:
	_overlay.visible = view_team != ALL
	if view_team == ALL:
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

func set_view(team: int) -> void:
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
	if _stats == null:
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
	var total := float(fog.side * fog.side)
	_stats.text = "可见 %.1f%%  已探索 %.1f%%\n视野源 %d  更新 %.2f ms" % [visible_count*100/total, explored_count*100/total, fog.source_counts[view_team], fog.elapsed_ms]
