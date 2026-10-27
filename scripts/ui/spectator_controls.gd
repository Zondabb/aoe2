extends Control
## Changing the view never changes this client's spectator authority.

const VIEWS := [-1, 0, 1]
var _bootstrap: Node
var _holder: Node
var _panel: PanelContainer
var _choice: OptionButton
var _hint: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	add_child(_panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.08, 0.055, 0.94)
	style.border_color = Color("a1834e")
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(6)
	_panel.add_theme_stylebox_override("panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_panel.add_child(row)
	var title := Label.new()
	title.text = "观战"
	row.add_child(title)
	_choice = OptionButton.new()
	_choice.name = "ViewChoice"
	_choice.custom_minimum_size.x = 250
	_choice.fit_to_longest_item = false
	_choice.clip_text = true
	_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_choice.add_item("全图 · 解除战争迷雾")
	_choice.add_item("队伍 1 视角")
	_choice.add_item("队伍 2 视角")
	_choice.item_selected.connect(_on_view_selected)
	row.add_child(_choice)
	_hint = Label.new()
	_hint.name = "ReadOnlyHint"
	_hint.text = "只读 · 无法下令"
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.tooltip_text = "可以移动镜头、缩放、小地图定位及选中单位查看信息；不能移动、攻击、建造、生产或开启 AI 托管。全图模式资源栏显示队伍 1。"
	row.add_child(_hint)
	resized.connect(_layout)
	_layout()


func setup(bootstrap: Node) -> void:
	_bootstrap = bootstrap
	var world := bootstrap.get_parent()
	_holder = world.get_meta("fog_holder", null)
	var network := get_node_or_null("/root/NetworkSession")
	if network != null:
		var players: Array = network.match_info.get("players", [])
		for player in players:
			if player is Dictionary and (player.get("team") is float or player.get("team") is int):
				var team: int = int(player.team)
				if team in [0, 1]: _choice.set_item_text(team + 1, "队伍 %d · %s" % [team + 1, String(player.get("name", "玩家"))])
	_on_view_selected(0)


func _layout() -> void:
	if _panel != null:
		_panel.position = Vector2(16, 36)
		_panel.size = Vector2(minf(620.0, maxf(300.0, size.x - 32.0)), 36)
	if _hint != null: _hint.visible = size.x >= 560.0


func _on_view_selected(index: int) -> void:
	if index < 0 or index >= VIEWS.size() or not is_instance_valid(_holder): return
	var view: int = VIEWS[index]
	if not _holder.call("set_spectator_view", view): return
	_choice.select(index)
	if view in [0, 1] and is_instance_valid(_bootstrap):
		var world := _bootstrap.get_parent()
		var camera := world.get_node_or_null("Camera2D")
		var entities := world.get_node_or_null("Entities")
		if camera != null and entities != null:
			for entity in entities.get_children():
				if entity is BuildingAgent and entity.team == view and entity.def != null and entity.def.id == &"town_center":
					camera.call("focus_on", entity.sim_pos)
					break
	var hud := _bootstrap.get_node_or_null("../UILayer/HUD") if is_instance_valid(_bootstrap) else null
	if hud != null: hud.call("_refresh")
