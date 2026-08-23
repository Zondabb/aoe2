class_name Aoe2DigitRow
extends Control

## Right-aligned resource counter text overlaid on panel_game top-band number slots.

var _label: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_color_override("font_color", Color(0.98, 0.98, 0.94, 1.0))
	_label.add_theme_color_override("font_outline_color", Color(0.04, 0.04, 0.04, 0.95))
	_label.add_theme_constant_override("outline_size", 2)
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Arial Narrow", "Arial", "Helvetica", "sans-serif"])
	font.font_weight = 700
	_label.add_theme_font_override("font", font)
	add_child(_label)
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func set_font_size(size_px: int) -> void:
	if _label != null:
		_label.add_theme_font_size_override("font_size", size_px)

func set_number(value: int) -> void:
	_set_text(str(max(value, 0)))

func set_population(current: int, cap: int) -> void:
	_set_text("%d/%d" % [max(current, 0), max(cap, 0)])

func _set_text(text: String) -> void:
	if _label == null:
		return
	if _label.text != text:
		_label.text = text
