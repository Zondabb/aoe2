extends HBoxContainer
## Shared compact sound control for the menu and in-game HUD.

var _mute: CheckButton
var _volume: HSlider


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_mute = CheckButton.new()
	_mute.text = "音效"
	_mute.tooltip_text = "开启或静音原版音效"
	add_child(_mute)
	_volume = HSlider.new()
	_volume.custom_minimum_size = Vector2(100, 28)
	_volume.min_value = 0.0
	_volume.max_value = 1.0
	_volume.step = 0.05
	_volume.tooltip_text = "音效音量"
	add_child(_volume)
	_mute.toggled.connect(func(enabled: bool): GameAudio.set_muted(not enabled, true))
	_volume.value_changed.connect(func(value: float): GameAudio.set_master_volume(value))
	_volume.drag_ended.connect(func(_changed: bool): GameAudio.save_settings())
	_volume.focus_exited.connect(GameAudio.save_settings)
	GameAudio.settings_changed.connect(_sync)
	_sync()


func _sync() -> void:
	_mute.set_pressed_no_signal(not GameAudio.muted)
	_volume.set_value_no_signal(GameAudio.master_volume)
