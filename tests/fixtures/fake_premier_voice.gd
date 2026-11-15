extends "res://scripts/audio/premier_voice.gd"
## A speech engine that records what it is asked to read, for tests/run_premier_broadcast.gd.
## Kept out of the test script itself: that script is compiled before the
## autoloads exist, and this one's base needs them.

var problem := ""
var installed: Array = [
	{"id": "zh-1", "name": "Huihui", "language": "zh-CN"},
	{"id": "en-1", "name": "Zira", "language": "en-US"},
	{"id": "zh-2", "name": "Yaoyao", "language": "zh_CN"},
]
var spoken: Array = []
var speaking := false
var stops := 0


func _engine_problem() -> String:
	return problem


func _engine_voices() -> Array:
	return installed


func _engine_speak(text: String, voice: String, volume: int, speed: float, utterance: int, interrupt: bool) -> void:
	spoken.append({"text": text, "voice": voice, "volume": volume, "speed": speed, "utterance": utterance, "interrupt": interrupt})
	speaking = true


func _engine_speaking() -> bool:
	return speaking


func _engine_stop() -> void:
	stops += 1
	speaking = false


## The engine has finished reading and the start-up grace is long over.
func fall_silent() -> void:
	speaking = false
	_started_msec = -100000
	_process(0.0)
