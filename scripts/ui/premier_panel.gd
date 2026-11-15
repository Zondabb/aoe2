extends PanelContainer
## Subtitles for the premier's broadcasts, with the switches for reading them aloud.
##
## Why the premier chose is shown pale, what it chose in bold. The latest few
## broadcasts are kept; older ones fade. Presentation only: nothing here reaches
## the simulation.

const Voice := preload("res://scripts/audio/premier_voice.gd")
const Settings := preload("res://scripts/core/game_settings.gd")
const KEPT := 3
const HEADINGS := {"order": "回应指令", "threat": "敌情", "change": "调整安排", "done": "指令完成"}

## Reads the lines aloud. The panel makes its own unless one is set before it enters the tree.
var voice: Voice

var _subtitles_check: CheckBox
var _voice_check: CheckBox
var _settings_button: Button
var _settings_row: HBoxContainer
var _voice_pick: OptionButton
var _rate: HSlider
var _notice: Label
var _list: VBoxContainer
var _entries: Array[Dictionary] = []
var _bold: FontVariation


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	if voice == null:
		voice = Voice.new()
		voice.name = "Voice"
		add_child(voice)
	_bold = FontVariation.new()
	_bold.variation_embolden = 0.6
	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 4)
	add_child(column)

	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 8)
	column.add_child(header)
	var title := Label.new()
	title.name = "Title"
	title.text = "首相播报"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color("f1d395"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_subtitles_check = CheckBox.new()
	_subtitles_check.name = "Subtitles"
	_subtitles_check.text = "字幕"
	_subtitles_check.tooltip_text = "显示首相的思考和选择"
	_subtitles_check.add_theme_font_size_override("font_size", 13)
	_subtitles_check.toggled.connect(_on_subtitles_toggled)
	header.add_child(_subtitles_check)
	_voice_check = CheckBox.new()
	_voice_check.name = "Speech"
	_voice_check.text = "朗读"
	_voice_check.tooltip_text = "用系统的中文语音读出首相的播报，音量跟随游戏音效"
	_voice_check.add_theme_font_size_override("font_size", 13)
	_voice_check.toggled.connect(_on_voice_toggled)
	header.add_child(_voice_check)
	_settings_button = Button.new()
	_settings_button.name = "VoiceSettings"
	_settings_button.text = "语音设置"
	_settings_button.toggle_mode = true
	_settings_button.add_theme_font_size_override("font_size", 13)
	_settings_button.toggled.connect(_on_settings_toggled)
	header.add_child(_settings_button)

	_settings_row = HBoxContainer.new()
	_settings_row.name = "Settings"
	_settings_row.add_theme_constant_override("separation", 6)
	_settings_row.hide()
	column.add_child(_settings_row)
	_settings_row.add_child(_small_label("声音"))
	_voice_pick = OptionButton.new()
	_voice_pick.name = "VoicePick"
	_voice_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_pick.add_theme_font_size_override("font_size", 13)
	_voice_pick.item_selected.connect(_on_voice_picked)
	_settings_row.add_child(_voice_pick)
	_settings_row.add_child(_small_label("语速"))
	_rate = HSlider.new()
	_rate.name = "Rate"
	_rate.custom_minimum_size = Vector2(90, 24)
	_rate.min_value = Settings.MIN_VOICE_RATE
	_rate.max_value = Settings.MAX_VOICE_RATE
	_rate.step = 0.1
	_rate.tooltip_text = "朗读速度"
	_rate.value_changed.connect(_on_rate_changed)
	_rate.drag_ended.connect(_on_rate_released)
	_settings_row.add_child(_rate)
	var preview := Button.new()
	preview.name = "Preview"
	preview.text = "试听"
	preview.add_theme_font_size_override("font_size", 13)
	preview.pressed.connect(_on_preview_pressed)
	_settings_row.add_child(preview)

	_notice = Label.new()
	_notice.name = "Notice"
	_notice.add_theme_font_size_override("font_size", 12)
	_notice.add_theme_color_override("font_color", Color("ffb195"))
	_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_notice.custom_minimum_size.x = 200
	_notice.hide()
	column.add_child(_notice)
	_list = VBoxContainer.new()
	_list.name = "Lines"
	_list.add_theme_constant_override("separation", 6)
	column.add_child(_list)
	voice.settings_changed.connect(_sync_controls)
	_sync_controls()


## Lines of this team's premier from one tick response: shown as subtitles and read aloud.
func receive(lines: Array) -> void:
	if voice.subtitles:
		show_lines(lines)
	voice.say_lines(lines)


## Add lines to the subtitles. Lines that share an id belong to one broadcast.
func show_lines(lines: Array) -> void:
	for line: Variant in lines:
		if not (line is Dictionary):
			continue
		var text := String(line.get("text", "")).strip_edges()
		if text.is_empty():
			continue
		var entry := _entry_for(line)
		var label: Label = entry["decision"] if String(line.get("kind", "")) == "decision" else entry["thinking"]
		label.text += text
		label.show()
	while _entries.size() > KEPT:
		var old: Dictionary = _entries.pop_front()
		var gone: Control = old["box"]
		gone.queue_free()
	for index in _entries.size():
		var box: Control = _entries[index]["box"]
		box.modulate.a = 1.0 if index == _entries.size() - 1 else 0.6


## What the subtitles show, oldest first: [{"id", "heading", "thinking", "decision"}].
func shown() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for entry: Dictionary in _entries:
		var heading: Label = entry["heading"]
		var thinking: Label = entry["thinking"]
		var decision: Label = entry["decision"]
		rows.append({"id": entry["id"], "heading": heading.text, "thinking": thinking.text, "decision": decision.text})
	return rows


func clear() -> void:
	for entry: Dictionary in _entries:
		var box: Control = entry["box"]
		box.queue_free()
	_entries.clear()
	voice.stop()


func _entry_for(line: Dictionary) -> Dictionary:
	var id := String(line.get("id", ""))
	for entry: Dictionary in _entries:
		if String(entry["id"]) == id:
			return entry
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	_list.add_child(box)
	var trigger := String(line.get("trigger", ""))
	var heading := _small_label(String(HEADINGS.get(trigger, "首相")))
	heading.name = "Heading"
	heading.add_theme_color_override("font_color", Color("ffb195") if trigger == "threat" else Color("c9b98a"))
	heading.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var about := String(line.get("about", "")).strip_edges()
	if not about.is_empty():
		heading.text += "：" + about
	box.add_child(heading)
	var thinking := _line_label("Thinking", 13, Color("b9ad8c"), false)
	box.add_child(thinking)
	var decision := _line_label("Decision", 14, Color("f3ead2"), true)
	box.add_child(decision)
	var created := {"id": id, "box": box, "heading": heading, "thinking": thinking, "decision": decision}
	_entries.append(created)
	return created


func _small_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	return label


func _line_label(node_name: String, font_size: int, color: Color, bold: bool) -> Label:
	var label := Label.new()
	label.name = node_name
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	if bold:
		label.add_theme_font_override("font", _bold)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = 200
	label.hide()
	return label


func _sync_controls() -> void:
	_subtitles_check.set_pressed_no_signal(voice.subtitles)
	_voice_check.set_pressed_no_signal(voice.voice_enabled)
	_rate.set_value_no_signal(voice.rate)
	_list.visible = voice.subtitles
	# Looking for a voice also refreshes the reason nothing can be read aloud.
	voice.resolve_voice()
	_notice.text = voice.notice
	_notice.visible = voice.voice_enabled and not voice.notice.is_empty()
	_fill_voices()


func _fill_voices() -> void:
	var voices := voice.chinese_voices()
	_voice_pick.clear()
	_voice_pick.disabled = voices.is_empty()
	if voices.is_empty():
		_voice_pick.add_item("没有中文语音")
		return
	for index in voices.size():
		_voice_pick.add_item(String(voices[index]["name"]))
		_voice_pick.set_item_metadata(index, String(voices[index]["id"]))
		if String(voices[index]["id"]) == voice.voice_id:
			_voice_pick.select(index)


func _on_subtitles_toggled(on: bool) -> void:
	voice.set_subtitles(on)


func _on_voice_toggled(on: bool) -> void:
	voice.set_voice_enabled(on)


func _on_settings_toggled(open: bool) -> void:
	_settings_row.visible = open


func _on_voice_picked(index: int) -> void:
	if index >= 0 and not _voice_pick.disabled:
		voice.set_voice_id(String(_voice_pick.get_item_metadata(index)))


func _on_rate_changed(value: float) -> void:
	# Remembered when the slider is let go, not on every step.
	voice.set_rate(value, false)


func _on_rate_released(_changed: bool) -> void:
	voice.set_rate(_rate.value)


func _on_preview_pressed() -> void:
	voice.preview()
