extends SceneTree
## Checks for the premier's broadcasts on the game side: the settings, the
## gateway's hand-over, the reading queue, the subtitle panel and its place in
## the managed-play controls. No Python service and no speech engine is needed.
##
##   godot --headless --path . --script res://tests/run_premier_broadcast.gd

## The game scripts are loaded with load() once the autoloads exist, never
## preloaded: a script given with --script is compiled before the autoloads are
## registered, and so is everything it preloads. game_settings.gd and the AI
## gateway use GameSession by name and would not compile that early.
const SETTINGS_SCRIPT := "res://scripts/core/game_settings.gd"
const GATEWAY_SCRIPT := "res://scripts/ai_gateway/ai_gateway.gd"
const PLAYER_CONTROL_SCRIPT := "res://scripts/ai_gateway/player_ai_control.gd"
const VOICE_SCRIPT := "res://scripts/audio/premier_voice.gd"
const PANEL_SCRIPT := "res://scripts/ui/premier_panel.gd"
const CONTROLS_SCRIPT := "res://scripts/ui/ai_autoplay_controls.gd"
const FAKE_VOICE_SCRIPT := "res://tests/fixtures/fake_premier_voice.gd"
const PACKAGED_SETTINGS := "res://data/game_settings.cfg"
const PREVIEW_TEXT := "首相播报试听。"
const TEST_SETTINGS := "user://premier_settings_test.cfg"


class MockController extends Node:
	signal state_changed
	signal premier_spoke(team: int, lines: Array)
	var local_team := 0
	var state := {"enabled": true, "status": "active", "message": "", "available": true}

	func local_state() -> Dictionary:
		return state

	func request_local_enabled(_value: bool) -> bool:
		return true

	func request_local_instruction(_value: String) -> bool:
		return true


class RecordingSession extends "res://scripts/network/network_session.gd":
	var packets: Array[Dictionary] = []

	func _send(message: Dictionary) -> bool:
		packets.append(message.duplicate(true))
		return true


var _failures := 0
var _checks := 0
var _settings: GDScript
var _gateway: GDScript
var _player_control: GDScript
var _voice_script: GDScript
var _panel_script: GDScript
var _controls_script: GDScript
var _fake_voice_script: GDScript


func _initialize() -> void:
	call_deferred("_run")


func _check(value: bool, description: String) -> void:
	_checks += 1
	if not value:
		_failures += 1
		push_error(description)


func _line(id: String, seq: int, kind: String, text: String, trigger: String, priority: int, about := "") -> Dictionary:
	var line := {"id": id, "seq": seq, "kind": kind, "text": text, "trigger": trigger, "priority": priority}
	if not about.is_empty():
		line["order"] = 1
		line["about"] = about
	return line


func _fake_voice() -> Variant:
	var voice: Variant = _fake_voice_script.new()
	voice.settings_path = TEST_SETTINGS
	return voice


func _load(path: String) -> GDScript:
	var loaded := load(path) as GDScript
	_check(loaded != null and loaded.can_instantiate(), "脚本能加载并编译：" + path)
	return loaded


## False when any script failed to compile: everything after that would only fail in its wake.
func _load_scripts() -> bool:
	var before := _failures
	_settings = _load(SETTINGS_SCRIPT)
	_gateway = _load(GATEWAY_SCRIPT)
	_player_control = _load(PLAYER_CONTROL_SCRIPT)
	_voice_script = _load(VOICE_SCRIPT)
	_panel_script = _load(PANEL_SCRIPT)
	_controls_script = _load(CONTROLS_SCRIPT)
	_fake_voice_script = _load(FAKE_VOICE_SCRIPT)
	return _failures == before


func _run() -> void:
	if not _load_scripts():
		print("Premier broadcast: %d checks, %d failures (scripts did not compile)" % [_checks, _failures])
		quit(1)
		return
	DirAccess.remove_absolute(TEST_SETTINGS)
	var audio: Variant = root.get_node("GameAudio")
	var was_muted: bool = audio.muted
	var was_volume: float = audio.master_volume
	audio.muted = false
	audio.master_volume = 0.5
	var answer := [
		_line("b-1", 0, "thinking", "游侠要先升时代。", "order", 1, "囤积50个游侠"),
		_line("b-1", 1, "decision", "先攒钱。", "order", 1, "囤积50个游侠"),
	]

	_check_settings()
	_check_gateway(answer)
	_check_voice(audio, answer)
	await _check_panel(answer)
	await _check_controls(answer)
	await _check_network_players(0)
	await _check_network_players(1)

	audio.muted = was_muted
	audio.master_volume = was_volume
	DirAccess.remove_absolute(TEST_SETTINGS)
	print("Premier broadcast: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)


func _check_settings() -> void:
	var defaults := {"subtitles": true, "voice": true, "voice_id": "", "voice_rate": 1.0}
	_check(_settings.load_premier_settings(["user://no_such_premier_file.cfg"]) == defaults, "没有配置文件时用默认值")
	_check(_settings.load_premier_settings([PACKAGED_SETTINGS]) == defaults, "随游戏发布的配置等于默认值")
	_check(bool(ProjectSettings.get_setting("audio/general/text_to_speech", false)), "项目设置里打开了 Text to Speech")
	_settings.save_premier_settings({"subtitles": false, "voice": false, "voice_id": "zh-2", "voice_rate": 9.0}, TEST_SETTINGS)
	var saved: Dictionary = _settings.load_premier_settings([PACKAGED_SETTINGS, TEST_SETTINGS])
	_check(saved == {"subtitles": false, "voice": false, "voice_id": "zh-2", "voice_rate": 2.0}, "游戏内开关保存后能读回，语速限制在 0.5 到 2.0")
	var wrong := ConfigFile.new()
	wrong.set_value("premier", "subtitles", "yes")
	wrong.set_value("premier", "voice_rate", "fast")
	wrong.set_value("premier", "voice_id", 7)
	wrong.save(TEST_SETTINGS)
	_check(_settings.load_premier_settings([TEST_SETTINGS]) == defaults, "类型不对的配置项被忽略")
	DirAccess.remove_absolute(TEST_SETTINGS)


func _check_gateway(answer: Array) -> void:
	var gateway: Variant = _gateway.new()
	var heard: Array = []
	gateway.premier_spoke.connect(func(team: int, lines: Array) -> void: heard.append([team, lines]))
	gateway._relay_premier_lines(1, {"broadcasts": answer})
	gateway._relay_premier_lines(1, {"broadcasts": answer})
	var later := _line("b-2", 0, "decision", "农田先停。", "change", 0)
	gateway._relay_premier_lines(1, {"broadcasts": [answer[1], later, "junk", {"id": "b-9", "seq": 0, "text": "   "}]})
	gateway._relay_premier_lines(1, {"broadcasts": "nonsense"})
	gateway._relay_premier_lines(1, {})
	_check(heard.size() == 2, "同一句只交出一次，没有播报时不发信号")
	if heard.size() == 2:
		_check(heard[0][0] == 1 and heard[0][1] == answer, "播报带着队伍编号原样交出")
		_check(heard[1][1] == [later], "重复的句子、空句子和格式不对的条目被丢掉")
	gateway.free()

	var control: Variant = _player_control.new()
	var relayed: Array = []
	control.premier_spoke.connect(func(team: int, lines: Array) -> void: relayed.append([team, lines]))
	control._on_premier_spoke(1, answer)
	_check(relayed == [[1, answer]], "托管控制器把播报转给界面")
	control.free()


func _check_voice(audio: Variant, answer: Array) -> void:
	var voice: Variant = _fake_voice()
	root.add_child(voice)
	voice.subtitles = true
	voice.voice_enabled = true
	voice.voice_id = ""
	voice.rate = 1.0
	_check(voice.stops == 1, "新对局初始化时清理系统语音队列")
	var chinese: Array = voice.chinese_voices()
	_check(chinese.size() == 2 and chinese[0]["id"] == "zh-1" and chinese[1]["name"] == "Yaoyao", "只列出系统里的中文语音")
	_check(voice.resolve_voice() == "zh-1" and voice.notice.is_empty(), "默认用第一个中文语音")

	voice.say_lines(answer)
	_check(voice.spoken.size() == 2, "一条播报按句交给语音引擎")
	if voice.spoken.size() == 2:
		var first: Dictionary = voice.spoken[0]
		_check(first["text"] == "游侠要先升时代。" and first["voice"] == "zh-1" and first["volume"] == 50 and first["speed"] == 1.0, "音量跟随主音量，用选中的语音和语速")
		_check(not first["interrupt"] and not voice.spoken[1]["interrupt"] and voice.spoken[1]["utterance"] == int(first["utterance"]) + 1, "空闲时开始朗读不打断任何东西")
	voice.say({"id": "b-2", "priority": 0, "texts": ["第二条。"]})
	voice.say({"id": "b-3", "priority": 0, "texts": ["第三条。"]})
	_check(voice.spoken.size() == 2 and voice._waiting.get("id") == "b-3", "正在读时新播报等待，并替换掉更早等待的那条")
	voice.say({"id": "b-4", "priority": 1, "texts": ["第四条。"]})
	voice.say({"id": "b-5", "priority": 0, "texts": ["第五条。"]})
	_check(voice._waiting.get("id") == "b-4", "等待中的指令回话不会被例行播报挤掉")
	voice.say({"id": "b-6", "priority": 2, "texts": ["敌军来了！", "守家。"]})
	_check(voice.spoken.size() == 4 and voice.spoken[2]["interrupt"] and not voice.spoken[3]["interrupt"] and voice.spoken[2]["text"] == "敌军来了！", "威胁播报打断正在读的内容")

	# Brief silence gaps between sentences must not finish the broadcast prematurely.
	voice.now_msec = 10000
	voice._started_msec = 10000 - voice.START_GRACE_MSEC - 10
	voice.speaking = false
	voice._process(0.0)
	_check(voice.is_reading() and voice.spoken.size() == 4, "刚进入静音确认窗口时不提前判定播完")
	voice.now_msec = 10000 + voice.SILENT_CONFIRM_MSEC - 50
	voice._process(0.0)
	_check(voice.is_reading() and voice.spoken.size() == 4, "句间短暂停顿不清空当前播报")
	voice.speaking = true
	voice.now_msec += 20
	voice._process(0.0)
	_check(voice.is_reading() and voice._silent_since_msec == -1, "恢复发声后重置静音计时")
	voice.speaking = false
	voice.now_msec += 100
	voice._process(0.0)
	_check(voice.is_reading() and voice.spoken.size() == 4, "再次静音初期仍等待确认")
	voice.now_msec += voice.SILENT_CONFIRM_MSEC
	voice._process(0.0)
	_check(voice.spoken.size() == 5 and voice.spoken[4]["text"] == "第四条。" and not voice.spoken[4]["interrupt"], "连续静音达到确认时长后才接着读等待的那条")
	voice.now_msec = -1

	voice.fall_silent()
	_check(not voice.is_reading() and voice.spoken.size() == 5, "没有等待的播报时安静下来")

	var stops_before_idle_stop: int = voice.stops
	voice.stop()
	_check(voice.stops == stops_before_idle_stop + 1, "即使状态空闲，stop 也会无条件停止系统语音")

	# If residual audio is still speaking in the OS queue while _playing is empty, cut it off.
	voice.speaking = true
	voice.say({"id": "b-stale", "priority": 0, "texts": ["打断残留语音。"]})
	_check(voice.spoken.size() == 6 and voice.spoken[5]["interrupt"], "系统仍在发声但本地状态空闲时打断旧队列")
	voice.fall_silent()

	audio.muted = true
	voice.say({"id": "b-7", "priority": 2, "texts": ["静音时不读。"]})
	audio.muted = false
	var stops_before_disable: int = voice.stops
	voice.set_voice_enabled(false)
	voice.say({"id": "b-7", "priority": 2, "texts": ["关掉朗读时不读。"]})
	voice.set_voice_enabled(true)
	_check(voice.spoken.size() == 6 and voice.stops == stops_before_disable + 1, "静音或关掉朗读时不读，关闭朗读立即停止系统语音")
	voice.say({"id": "b-8", "priority": 0, "texts": ["读到一半。"]})
	var stops_before_mute: int = voice.stops
	audio.muted = true
	audio.settings_changed.emit()
	audio.muted = false
	_check(voice.stops == stops_before_mute + 1 and not voice.is_reading(), "读到一半静音，立刻停下")

	voice.installed = [{"id": "en-1", "name": "Zira", "language": "en-US"}]
	var before: int = voice.spoken.size()
	voice.say({"id": "b-9", "priority": 2, "texts": ["没有中文语音。"]})
	_check(voice.spoken.size() == before and voice.notice.contains("没有中文语音"), "没有中文语音时不读，并说明原因")
	voice.problem = "这台设备不支持语音朗读，只显示字幕。"
	_check(voice.resolve_voice().is_empty() and voice.notice == voice.problem and voice.chinese_voices().is_empty(), "设备不支持语音时说明原因")

	voice.problem = ""
	voice.installed = [{"id": "zh-1", "name": "Huihui", "language": "zh-CN"}, {"id": "zh-2", "name": "Yaoyao", "language": "zh_CN"}]
	voice.set_voice_id("zh-2")
	voice.set_rate(5.0)
	voice.say({"id": "b-10", "priority": 0, "texts": ["换了声音。"]})
	var last: Dictionary = voice.spoken[voice.spoken.size() - 1]
	_check(voice.rate == 2.0 and last["voice"] == "zh-2" and last["speed"] == 2.0 and voice.notice.is_empty(), "选中的语音和语速生效，语速有上限")
	voice.fall_silent()
	var stops_before_exit: int = voice.stops
	root.remove_child(voice)
	_check(voice.stops == stops_before_exit + 1, "离开场景树时即使空闲也无条件停止系统语音")
	var again: Variant = _fake_voice()
	root.add_child(again)
	_check(again.voice_id == "zh-2" and again.rate == 2.0 and again.voice_enabled and again.subtitles, "开关、语音和语速下次还在")
	again.set_voice_id("uninstalled")
	_check(again.resolve_voice() == "zh-1", "选中的语音被卸载后退回第一个中文语音")
	again.set_voice_id("zh-2")
	voice.queue_free()
	again.queue_free()

	# What this machine's own speech engine offers. Nothing is read aloud here.
	var real: Variant = _voice_script.new()
	real.settings_path = TEST_SETTINGS
	root.add_child(real)
	var chosen: String = real.resolve_voice()
	print("Speech on this machine: ", ("voice " + chosen) if not chosen.is_empty() else real.notice)
	_check(chosen.is_empty() != real.notice.is_empty(), "要么找到中文语音，要么给出不能朗读的原因")
	real.queue_free()


func _check_panel(answer: Array) -> void:
	var panel: Variant = _panel_script.new()
	var voice: Variant = _fake_voice()
	panel.voice = voice
	panel.add_child(voice)
	root.add_child(panel)
	panel.size = Vector2(440, 0)
	await process_frame
	voice.set_subtitles(true)
	voice.set_voice_enabled(true)
	var lines_box := panel.get_node("Column/Lines") as Control
	var pick := panel.get_node("Column/Settings/VoicePick") as OptionButton
	_check(pick.item_count == 2 and not pick.disabled and pick.selected >= 0 and pick.get_item_metadata(pick.selected) == "zh-2", "语音下拉框列出中文语音并选中保存的那个")

	panel.receive(answer)
	var rows: Array = panel.shown()
	_check(rows.size() == 1 and voice.spoken.size() == 2, "收到播报后显示字幕并朗读")
	if rows.size() == 1:
		_check(rows[0]["heading"] == "回应指令：囤积50个游侠" and rows[0]["thinking"] == "游侠要先升时代。" and rows[0]["decision"] == "先攒钱。", "字幕分成思考和选择，标题带上元首的原话")
	panel.receive([_line("b-1", 2, "decision", "中国造不了游侠，改为重装骑士。", "order", 1, "囤积50个游侠")])
	_check(panel.shown().size() == 1 and panel.shown()[0]["decision"] == "先攒钱。中国造不了游侠，改为重装骑士。", "同一条播报后到的句子接在后面")
	panel.receive([_line("b-2", 0, "decision", "第二条。", "change", 0)])
	panel.receive([_line("b-3", 0, "decision", "第三条。", "done", 0, "村民补到20个")])
	panel.receive([_line("b-4", 0, "thinking", "敌军到了门口。", "threat", 2), "junk", _line("b-4", 1, "decision", "   ", "threat", 2)])
	await process_frame
	rows = panel.shown()
	_check(rows.size() == 3 and lines_box.get_child_count() == 3, "只保留最近三条播报")
	if rows.size() == 3:
		_check(rows[0]["id"] == "b-2" and rows[0]["heading"] == "调整安排" and rows[1]["heading"] == "指令完成：村民补到20个" and rows[2]["heading"] == "敌情", "每条播报有说明来由的标题")
		_check(rows[2]["thinking"] == "敌军到了门口。" and rows[2]["decision"].is_empty(), "空句子和格式不对的条目不显示")
		_check((lines_box.get_child(0) as Control).modulate.a < 1.0 and (lines_box.get_child(2) as Control).modulate.a == 1.0, "旧播报变淡，最新一条最清楚")

	var subtitles := panel.get_node("Column/Header/Subtitles") as CheckBox
	subtitles.button_pressed = false
	voice.stop()
	var before: int = voice.spoken.size()
	panel.receive([_line("b-5", 0, "decision", "关掉字幕后仍然朗读。", "change", 0)])
	_check(not voice.subtitles and not lines_box.visible and panel.shown().size() == 3 and voice.spoken.size() == before + 1, "关掉字幕只隐藏文字，朗读照常")
	subtitles.button_pressed = true
	_check(voice.subtitles and lines_box.visible, "字幕可以重新打开")

	var speech := panel.get_node("Column/Header/Speech") as CheckBox
	speech.button_pressed = false
	_check(not voice.voice_enabled and not voice.is_reading(), "关掉朗读立刻停下")
	speech.button_pressed = true
	var settings_row := panel.get_node("Column/Settings") as Control
	var settings_button := panel.get_node("Column/Header/VoiceSettings") as Button
	_check(not settings_row.visible, "语音设置默认收起")
	settings_button.button_pressed = true
	_check(settings_row.visible, "点开后显示语音和语速")
	pick.select(0)
	pick.item_selected.emit(0)
	_check(voice.voice_id == "zh-1", "下拉框改变朗读用的语音")
	var rate := panel.get_node("Column/Settings/Rate") as HSlider
	rate.value = 1.5
	_check(is_equal_approx(voice.rate, 1.5), "滑块改变语速")
	(panel.get_node("Column/Settings/Preview") as Button).pressed.emit()
	_check(voice.spoken[voice.spoken.size() - 1]["text"] == PREVIEW_TEXT and is_equal_approx(voice.spoken[voice.spoken.size() - 1]["speed"], 1.5), "试听按当前语音和语速读一句")

	var notice := panel.get_node("Column/Notice") as Label
	_check(not notice.visible, "能朗读时不显示提示")
	voice.installed = []
	voice.settings_changed.emit()
	_check(notice.visible and notice.text.contains("没有中文语音") and pick.disabled, "没有中文语音时面板说明原因，只显示字幕")
	panel.clear()
	await process_frame
	_check(panel.shown().is_empty() and lines_box.get_child_count() == 0 and not voice.is_reading(), "清空后没有字幕也不再朗读")
	panel.queue_free()


func _check_controls(answer: Array) -> void:
	var match_root := Node2D.new()
	root.add_child(match_root)
	var layer := CanvasLayer.new()
	layer.name = "UILayer"
	match_root.add_child(layer)
	node_added.connect(_install_voice)
	var controls: Control = _controls_script.new()
	controls.name = "AiAutoplayControls"
	controls.size = Vector2(1280, 720)
	layer.add_child(controls)
	node_added.disconnect(_install_voice)
	await process_frame
	var premier: Variant = controls.get_node_or_null("PremierPanel")
	_check(premier != null, "托管控件里有播报面板")
	if premier == null:
		match_root.queue_free()
		return
	_check(not premier.visible, "没有托管时不显示播报面板")
	var controller := MockController.new()
	controller.name = "PlayerAiControl"
	match_root.add_child(controller)
	await process_frame
	await process_frame
	_check(premier.visible, "托管中显示播报面板")
	# The machine's own speech engine stays silent in this check, and the player's saved switches are left alone.
	premier.voice.voice_enabled = false
	premier.voice.subtitles = true
	controller.premier_spoke.emit(1, answer)
	_check(premier.shown().is_empty(), "对方首相的播报不显示")
	controller.premier_spoke.emit(0, answer)
	await process_frame
	await process_frame
	var bar := controls.get_node("Panel") as Control
	var instruction := controls.get_node("InstructionPanel") as Control
	_check(premier.shown().size() == 1, "本队首相的播报显示在面板上")
	_check(premier.position.x == 16 and premier.size.x == bar.size.x and premier.size.y > 30, "播报面板与托管面板同宽")
	_check(instruction.visible and premier.position.y >= instruction.position.y + instruction.size.y, "播报面板排在指令输入框下面")
	var stops_before_cancel: int = premier.voice.stops
	controller.state["enabled"] = false
	controller.state["status"] = "off"
	controller.state_changed.emit()
	_check(not premier.visible and premier.shown().is_empty() and premier.voice.stops == stops_before_cancel + 1, "取消托管后收起、清空并停止朗读")
	controller.premier_spoke.emit(0, answer)
	_check(premier.shown().is_empty(), "取消托管后到达的播报不显示")
	controller.state.merge({"enabled": true, "status": "pending"}, true)
	controller.state_changed.emit()
	controller.premier_spoke.emit(1, answer)
	controller.premier_spoke.emit(0, answer)
	_check(premier.shown().is_empty(), "确认托管前不显示提前到达的播报")
	var stops_before_pending_cancel: int = premier.voice.stops
	controller.state.merge({"enabled": false, "status": "off"}, true)
	controller.state_changed.emit()
	_check(premier.voice.stops == stops_before_pending_cancel + 1 and controls._starting_broadcasts.is_empty(), "连接确认中取消托管时也清理语音和暂存播报")
	controller.state.merge({"enabled": true, "status": "pending"}, true)
	controller.state_changed.emit()
	controller.premier_spoke.emit(1, answer)
	controller.premier_spoke.emit(0, answer)
	_check(premier.shown().is_empty(), "再次确认托管前仍不显示提前到达的播报")
	controller.state["status"] = "active"
	controller.state_changed.emit()
	_check(premier.shown().size() == 1 and premier.shown()[0].thinking == answer[0].text, "确认托管后补播本队消息一次")
	match_root.queue_free()
	await process_frame


func _network_player(side: int, host: int) -> Node:
	var arena := Node2D.new()
	root.add_child(arena)
	var transport := RecordingSession.new()
	transport.team = side
	transport.host_team = host
	transport.state = "playing"
	transport.match_info = {"match_id": "1234567890abcdef1234567890abcdef", "premier_broadcasts": true}
	arena.add_child(transport)
	var net: Variant = load("res://scripts/network/network_match.gd").new()
	net.name = "NetworkMatch"
	arena.add_child(net)
	net.set_process(false)
	net.set_physics_process(false)
	net.session = transport
	net.local_team = side
	net.is_host = side == host
	net._playing = true
	transport.message_received.connect(net._on_message)
	var control: Variant = _player_control.new()
	control.name = "PlayerAiControl"
	arena.add_child(control)
	control.online = true
	control.local_team = side
	control._set_state(side, true, "active", "")
	var layer := CanvasLayer.new()
	layer.name = "UILayer"
	arena.add_child(layer)
	var controls: Control = _controls_script.new()
	controls.name = "Controls"
	layer.add_child(controls)
	return arena


func _install_voice(node: Node) -> void:
	if node.name == "PremierPanel":
		var voice: Variant = _fake_voice()
		node.set("voice", voice)
		node.add_child(voice)


func _check_network_players(host: int) -> void:
	var guest := 1 - host
	node_added.connect(_install_voice)
	var home := _network_player(host, host)
	var away := _network_player(guest, host)
	node_added.disconnect(_install_voice)
	await process_frame
	await process_frame
	var panels := [home.get_node("UILayer/Controls/PremierPanel"), away.get_node("UILayer/Controls/PremierPanel")]
	for panel: Variant in panels:
		panel.voice.voice_enabled = true
		panel.voice.subtitles = true
	var authority: Variant = home.get_node("PlayerAiControl")
	var sender: RecordingSession = home.get_node("NetworkMatch").session
	var receiver: RecordingSession = away.get_node("NetworkMatch").session
	var gateway: Variant = _gateway.new()
	gateway.premier_spoke.connect(authority._on_premier_spoke)
	var host_line := _line("h", 0, "decision", "主队先采木。", "order", 1)
	var guest_line := _line("g", 0, "decision", "客队先采金。", "order", 1)
	guest_line["final"] = true
	gateway._relay_premier_lines(host, {"broadcasts": [host_line]})
	# As on the HTTP path, numbers arrive from Godot's JSON parser as floats.
	var reply: Dictionary = JSON.parse_string(JSON.stringify({"broadcasts": [guest_line]}))
	gateway._relay_premier_lines(guest, reply)
	gateway._relay_premier_lines(guest, reply)
	_check(sender.packets.size() == 1, "只有客队播报走网络，重复的 tick 不重发")
	if sender.packets.size() == 1:
		var packet: Dictionary = sender.packets[0]
		_check(packet.team == guest and packet.lines == [guest_line] and packet.lines[0].seq is int, "客队消息保留字幕、优先级和整数序号")
		var decoded: Dictionary = JSON.parse_string(JSON.stringify(packet))
		receiver._handle_message(decoded.merged({"team": host}, true))
		receiver._handle_message(decoded.merged({"match_id": "old"}, true))
		receiver._handle_message(decoded.merged({"lines": ["invalid"]}, true))
		receiver.spectator = true
		receiver._handle_message(decoded)
		receiver.spectator = false
		_check(panels[1].shown().is_empty() and panels[1].voice.spoken.is_empty(), "错队、旧对局、格式错误和观战消息均未展示")
		receiver._handle_message(decoded)
		for i in 2:
			var expected: String = [host_line.text, guest_line.text][i]
			var rows: Array = panels[i].shown()
			var spoken: Array = panels[i].voice.spoken
			_check(rows.size() == 1 and rows[0].decision == expected, "双方各自只显示本队字幕")
			_check(spoken.size() == 1 and spoken[0].text == expected, "双方各自只朗读本队消息")
		away.get_node("PlayerAiControl").stop_all()
		receiver._handle_message(decoded)
		_check(panels[1].shown().is_empty() and panels[1].voice.spoken.size() == 1, "对局结束后丢弃迟到的消息")
	home.get_node("PlayerAiControl").stop_all()
	sender.match_info.erase("premier_broadcasts")
	sender.send_premier_broadcast(guest, [guest_line])
	_check(sender.packets.size() == 1, "旧中继不会收到不认识的播报消息")
	gateway.free()
	home.queue_free()
	away.queue_free()
	await process_frame
