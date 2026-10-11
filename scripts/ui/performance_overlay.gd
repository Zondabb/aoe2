extends PanelContainer

## Measure wall-clock frame intervals: game speed must not change reported FPS.
## Entity groups are sampled once a second, only while the detail view is open.
const SAMPLE_INTERVAL_USEC := 500_000
const COUNT_INTERVAL_USEC := 1_000_000

var detailed := false
var _summary: Label
var _details: Label
var _sample_start_usec := 0
var _last_frame_usec := 0
var _last_count_usec := 0
var _frame_count := 0
var _max_frame_ms := 0.0
var _process_ms_sum := 0.0
var _physics_ms_sum := 0.0
var _counts := Vector3i.ZERO


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -350.0
	offset_right = -10.0
	offset_top = 76.0
	offset_bottom = 76.0
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.06, 0.08, 0.78)
	style.set_corner_radius_all(4)
	style.content_margin_left = 9
	style.content_margin_right = 9
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	column.name = "Column"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 3)
	add_child(column)
	_summary = _add_label(column, "Summary", 14)
	_summary.text = "FPS --  |  -- ms  [F3]"
	_summary.tooltip_text = "真实帧率与平均帧间隔；F3 展开/收起性能信息"
	_details = _add_label(column, "Details", 13)
	_details.visible = false
	var now := Time.get_ticks_usec()
	_sample_start_usec = now
	_last_frame_usec = now
	minimum_size_changed.connect(_align_right)
	_align_right()


func _add_label(parent: Node, node_name: String, font_size: int) -> Label:
	var label := Label.new()
	label.name = node_name
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(0.93, 0.95, 0.91))
	parent.add_child(label)
	return label


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	_max_frame_ms = maxf(_max_frame_ms, float(now - _last_frame_usec) / 1000.0)
	_last_frame_usec = now
	_frame_count += 1
	if detailed:
		_process_ms_sum += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		_physics_ms_sum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		if now - _last_count_usec >= COUNT_INTERVAL_USEC:
			_refresh_counts(now)
	var elapsed := now - _sample_start_usec
	if elapsed < SAMPLE_INTERVAL_USEC:
		return
	var frame_ms := float(elapsed) / 1000.0 / _frame_count
	var fps := float(_frame_count) * 1_000_000.0 / elapsed
	_summary.text = "FPS %.0f  |  %.1f ms  [F3]" % [fps, frame_ms]
	_summary.add_theme_color_override("font_color", Color("ffb995") if fps < 30.0 else Color("f1d395") if fps < 55.0 else Color("def0d4"))
	if detailed:
		# TIME_PROCESS includes frame/render waiting; it is not script CPU cost.
		_details.text = "最长帧 %.1f ms（最近 0.5 秒）\n引擎帧 %.1f / 物理 %.1f ms\n单位 %d | 建筑 %d | 资源 %d\n绘制调用 %d | 模拟 ×%.2f%s" % [
			_max_frame_ms, _process_ms_sum / _frame_count, _physics_ms_sum / _frame_count,
			_counts.x, _counts.y, _counts.z,
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			Engine.time_scale, "（暂停）" if get_tree().paused else "",
		]
	_sample_start_usec = now
	_frame_count = 0
	_max_frame_ms = 0.0
	_process_ms_sum = 0.0
	_physics_ms_sum = 0.0


func _refresh_counts(now: int) -> void:
	_counts = Vector3i(
		get_tree().get_nodes_in_group("units").size(),
		get_tree().get_nodes_in_group("buildings").size(),
		get_tree().get_nodes_in_group("resource_nodes").size(),
	)
	_last_count_usec = now


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and (event.keycode == KEY_F3 or event.physical_keycode == KEY_F3):
		set_detailed(not detailed)
		get_viewport().set_input_as_handled()


func set_detailed(value: bool) -> void:
	detailed = value
	_details.visible = value
	# Start a fresh interval so CPU averages never include time when hidden.
	var now := Time.get_ticks_usec()
	_sample_start_usec = now
	_last_frame_usec = now
	_frame_count = 0
	_max_frame_ms = 0.0
	_process_ms_sum = 0.0
	_physics_ms_sum = 0.0
	if value:
		_refresh_counts(now)
		_details.text = "正在采样…"
	else:
		_details.text = ""
	# Shrink the panel after the detail label disappears.
	_align_right()


func _align_right() -> void:
	var minimum := get_combined_minimum_size()
	offset_left = -minimum.x - 10.0
	offset_right = -10.0
	offset_top = 76.0
	offset_bottom = 76.0 + minimum.y
