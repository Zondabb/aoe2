extends PanelContainer

## Toggle layers on NavDebugOverlay (pathfinding arena debug).

@export var overlay_path: NodePath

var _overlay: NavDebugOverlay
var _grid: CheckBox
var _solids: CheckBox
var _paths: CheckBox
var _vision: CheckBox
var _arrows: CheckBox
var _timing: CheckBox


func _ready() -> void:
	visible = false
	add_to_group("pathfinding_debug_panel")
	_grid = get_node_or_null("Margin/VBox/GridCheck") as CheckBox
	_solids = get_node_or_null("Margin/VBox/SolidsCheck") as CheckBox
	_paths = get_node_or_null("Margin/VBox/PathsCheck") as CheckBox
	_vision = get_node_or_null("Margin/VBox/VisionCheck") as CheckBox
	_arrows = get_node_or_null("Margin/VBox/ArrowsCheck") as CheckBox
	_timing = get_node_or_null("Margin/VBox/TimingCheck") as CheckBox
	call_deferred("_bind_overlay")


func _bind_overlay() -> void:
	if overlay_path != NodePath():
		_overlay = get_node_or_null(overlay_path) as NavDebugOverlay
	if _overlay == null:
		_overlay = get_tree().get_first_node_in_group("nav_debug_overlay") as NavDebugOverlay
	if _overlay == null:
		return
	_wire_checkbox(_grid, "show_nav_grid", true)
	_wire_checkbox(_solids, "show_solid_cells", true)
	_wire_checkbox(_paths, "show_paths", true)
	_wire_checkbox(_vision, "show_vision", true)
	_wire_checkbox(_arrows, "show_move_arrows", true)
	_wire_checkbox(_timing, "print_vision_timing", false)
	_sync_from_overlay()


func _wire_checkbox(box: CheckBox, property: String, default_on: bool) -> void:
	if box == null:
		return
	box.set_pressed_no_signal(default_on)
	if box.has_meta("wired"):
		return
	box.set_meta("wired", true)
	box.toggled.connect(func(pressed: bool): _set_overlay_flag(property, pressed))


func _set_overlay_flag(property: String, value: bool) -> void:
	if _overlay == null:
		return
	_overlay.set(property, value)
	_overlay.refresh_debug_state()


func _sync_from_overlay() -> void:
	if _overlay == null:
		return
	_set_check(_grid, _overlay.show_nav_grid)
	_set_check(_solids, _overlay.show_solid_cells)
	_set_check(_paths, _overlay.show_paths)
	_set_check(_vision, _overlay.show_vision)
	_set_check(_arrows, _overlay.show_move_arrows)
	_set_check(_timing, _overlay.print_vision_timing)


func _set_check(box: CheckBox, value: bool) -> void:
	if box != null:
		box.set_pressed_no_signal(value)
