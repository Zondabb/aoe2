extends Node
## Reads the premier's broadcasts aloud with the system's text-to-speech voices.
##
## One broadcast plays and one waits. A newer broadcast takes the waiting
## place unless what waits there is more urgent; a broadcast more urgent than
## the one playing cuts in on it. Without a Chinese voice nothing is spoken and
## `notice` says why, so the panel shows subtitles only.

signal settings_changed

const Settings := preload("res://scripts/core/game_settings.gd")
## After a speak call the system needs a moment before it reports that it is speaking.
const START_GRACE_MSEC := 1200
## Require continuous silence across frames so brief pauses between sentences do not look finished.
const SILENT_CONFIRM_MSEC := 450
const PREVIEW_TEXT := "首相播报试听。"

var subtitles := true
var voice_enabled := true
## Empty: the system's first Chinese voice.
var voice_id := ""
var rate := 1.0
## Why nothing is read aloud; empty while speech works.
var notice := ""
## Where the in-game switches are remembered.
var settings_path := Settings.PREMIER_USER_PATH

var _playing: Dictionary = {}
var _waiting: Dictionary = {}
var _started_msec := 0
var _silent_since_msec := -1
var _next_utterance := 1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var saved: Dictionary = Settings.load_premier_settings([Settings.RES_PATH, Settings.USER_PATH, settings_path])
	subtitles = bool(saved["subtitles"])
	voice_enabled = bool(saved["voice"])
	voice_id = String(saved["voice_id"])
	rate = float(saved["voice_rate"])
	var audio := get_node_or_null("/root/GameAudio")
	if audio != null and audio.has_signal("settings_changed"):
		audio.connect("settings_changed", _on_audio_changed)
	resolve_voice()
	# Clear any leftover process-wide TTS queue from an earlier match.
	stop()


func _exit_tree() -> void:
	stop()


# The five calls below are the only ones that touch the system's speech engine; a test replaces them.

## Empty when speech can be used, otherwise the reason it cannot.
func _engine_problem() -> String:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_TEXT_TO_SPEECH):
		return "这台设备不支持语音朗读，只显示字幕。"
	if not bool(ProjectSettings.get_setting("audio/general/text_to_speech", false)):
		return "项目设置里没有打开 Text to Speech，只显示字幕。"
	return ""


func _engine_voices() -> Array:
	return DisplayServer.tts_get_voices()


func _engine_speak(text: String, voice: String, volume: int, speed: float, utterance: int, interrupt: bool) -> void:
	DisplayServer.tts_speak(text, voice, volume, 1.0, speed, utterance, interrupt)


func _now_msec() -> int:
	return Time.get_ticks_msec()


func _engine_speaking() -> bool:
	if not _engine_problem().is_empty():
		return false
	return DisplayServer.tts_is_speaking()


func _engine_stop() -> void:
	if _engine_problem().is_empty():
		DisplayServer.tts_stop()


## The system's Chinese voices as {"id", "name"}; empty when there are none or speech cannot be used.
func chinese_voices() -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	if not _engine_problem().is_empty():
		return found
	for voice: Variant in _engine_voices():
		if not (voice is Dictionary):
			continue
		var language := String(voice.get("language", "")).to_lower()
		if language.begins_with("zh") or language.begins_with("cmn") or language.begins_with("yue"):
			found.append({"id": String(voice.get("id", "")), "name": String(voice.get("name", ""))})
	return found


## The voice to speak with, or empty when there is none; `notice` then says why.
func resolve_voice() -> String:
	var problem := _engine_problem()
	if not problem.is_empty():
		notice = problem
		return ""
	var voices := chinese_voices()
	if voices.is_empty():
		notice = "系统里没有中文语音，只显示字幕。在系统的语言设置里安装中文语音后就能朗读。"
		return ""
	notice = ""
	for voice: Dictionary in voices:
		if String(voice["id"]) == voice_id:
			return voice_id
	return String(voices[0]["id"])


## Read the lines of one tick response aloud. Lines that share an id are one broadcast.
func say_lines(lines: Array) -> void:
	var order: Array[String] = []
	var grouped: Dictionary = {}
	for line: Variant in lines:
		if not (line is Dictionary):
			continue
		var text := String(line.get("text", "")).strip_edges()
		if text.is_empty():
			continue
		var id := String(line.get("id", ""))
		if not grouped.has(id):
			grouped[id] = {"id": id, "priority": int(line.get("priority", 0)), "texts": []}
			order.append(id)
		var texts: Array = grouped[id]["texts"]
		texts.append(text)
	for id: String in order:
		say(grouped[id])


## Read one broadcast, {"id", "priority", "texts"}: now, after the one playing, or not at all.
func say(broadcast: Dictionary) -> void:
	if not voice_enabled or _muted() or resolve_voice().is_empty():
		return
	var urgency := int(broadcast.get("priority", 0))
	if _playing.is_empty():
		_start(broadcast, _engine_speaking())
	elif urgency > int(_playing.get("priority", 0)):
		# More urgent than what is being read: cut in. What was waiting still follows.
		_start(broadcast, true)
	elif _waiting.is_empty() or urgency >= int(_waiting.get("priority", 0)):
		# It waits, in place of whatever waited before: old news is not read after newer news.
		_waiting = broadcast


## Read a short sentence with the current voice and speed, so the player can hear the setting.
func preview() -> void:
	say({"id": "preview", "priority": 3, "texts": [PREVIEW_TEXT]})


func stop() -> void:
	_engine_stop()
	_playing = {}
	_waiting = {}
	_silent_since_msec = -1
	set_process(false)


func is_reading() -> bool:
	return not _playing.is_empty()


func set_subtitles(value: bool) -> void:
	subtitles = value
	_save()


func set_voice_enabled(value: bool) -> void:
	voice_enabled = value
	if not value:
		stop()
	_save()


func set_voice_id(value: String) -> void:
	voice_id = value
	_save()


func set_rate(value: float, persist := true) -> void:
	if not is_finite(value):
		return
	rate = clampf(value, Settings.MIN_VOICE_RATE, Settings.MAX_VOICE_RATE)
	if persist:
		_save()


func _process(_delta: float) -> void:
	if _playing.is_empty():
		_silent_since_msec = -1
		set_process(false)
		return
	var now := _now_msec()
	if now - _started_msec < START_GRACE_MSEC or _engine_speaking():
		_silent_since_msec = -1
		return
	if _silent_since_msec < 0:
		_silent_since_msec = now
		return
	if now - _silent_since_msec < SILENT_CONFIRM_MSEC:
		return
	_playing = {}
	_silent_since_msec = -1
	if _waiting.is_empty():
		set_process(false)
		return
	var next: Dictionary = _waiting
	_waiting = {}
	_start(next, false)


func _start(broadcast: Dictionary, interrupt: bool) -> void:
	var voice := resolve_voice()
	var texts: Array = broadcast.get("texts", [])
	if voice.is_empty() or texts.is_empty():
		return
	_playing = broadcast
	_started_msec = _now_msec()
	_silent_since_msec = -1
	var volume := _volume()
	var first := true
	for text: Variant in texts:
		# The system queues the sentences; only the first may cut off what is being read.
		_engine_speak(String(text), voice, volume, rate, _next_utterance, interrupt and first)
		_next_utterance += 1
		first = false
	set_process(true)


func _save() -> void:
	Settings.save_premier_settings(
		{"subtitles": subtitles, "voice": voice_enabled, "voice_id": voice_id, "voice_rate": rate}, settings_path
	)
	settings_changed.emit()


func _audio() -> Node:
	return get_node_or_null("/root/GameAudio") if is_inside_tree() else null


## The premier is as loud as the game's sound effects and silent when they are muted.
func _muted() -> bool:
	var audio := _audio()
	return audio != null and bool(audio.get("muted"))


func _volume() -> int:
	var audio := _audio()
	var level := 0.8
	if audio != null:
		level = float(audio.get("master_volume"))
	return clampi(int(round(level * 100.0)), 0, 100)


func _on_audio_changed() -> void:
	if _muted():
		stop()
