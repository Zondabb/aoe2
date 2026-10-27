extends SceneTree

var _checks := 0
var _failures := 0
var _played: Array[StringName] = []

class VoiceUnit extends Node2D:
	var def: UnitDef
	var civ: CivDef
	var team := Enums.Team.PLAYER
	var match_state: MatchState

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	_checks += 1
	if not value:
		_failures += 1
		push_error(message)

func _run() -> void:
	await process_frame
	var audio := root.get_node("GameAudio")
	audio.set_muted(false)
	audio.set_master_volume(0.8)
	audio.stop_all()
	audio.event_played.connect(func(event: StringName, _category: StringName): _played.append(event))
	check(not audio.events.is_empty(), "original sound manifest loads")
	for event in audio.events:
		var entry: Dictionary = audio.events[event]
		check(not entry.files.is_empty(), "event has a sound: " + event)
		for path in entry.files:
			var stream := load(path) as AudioStream
			check(stream != null and stream.get_length() > 0.0, "imported sound decodes: " + path)
	check(audio.play_event(&"click", &"ui"), "first UI click plays")
	check(not audio.play_event(&"click", &"ui"), "repeated clicks are rate limited")
	await process_frame
	audio.set_muted(true)
	check(not audio.play_event(&"error", &"ui"), "mute suppresses playback")
	for pool in audio._players.values():
		for player in pool: check(not player.playing, "mute stops active players")
	audio.set_muted(false)
	audio.set_master_volume(0.0)
	check(not audio.play_event(&"click", &"ui"), "zero volume suppresses playback")
	audio.set_master_volume(2.0)
	check(audio.master_volume == 1.0, "volume clamps to one")
	audio.set_master_volume(NAN)
	check(audio.master_volume == 1.0, "invalid volume rejected")
	audio.set_master_volume(0.8)
	var source := Node2D.new()
	root.add_child(source)
	source.position = Vector2(100, 100)
	check(audio.source_audible(source), "visible viewport source audible")
	source.position = Vector2(100000, 100000)
	check(not audio.play_event(&"melee", &"world", source), "offscreen combat silent")
	source.position = Vector2(100, 100)
	source.hide()
	check(not audio.play_event(&"melee", &"world", source), "hidden combat silent")
	source.show()
	audio.stop_all()
	for index in 40:
		audio.play_event(&"melee", &"world", source, "limit-%d" % index)
	check(audio._players[&"world"].size() <= 12, "world playback has a hard concurrency limit")
	await process_frame
	audio.stop_all()
	check(audio.play_event(&"attack_warning", &"alert"), "attack alert plays")
	check(audio.play_event(&"unit_ready", &"alert"), "production alert fills second slot")
	await process_frame
	check(audio.play_event(&"victory", &"alert"), "victory preempts a full notification pool")
	var china := VoiceUnit.new()
	china.def = load("res://data/units/villager.tres")
	china.civ = load("res://data/civs/chinese.tres")
	china.team = Enums.Team.PLAYER
	root.add_child(china)
	root.get_node("GameSession").online_active = false
	await process_frame
	audio.stop_all()
	check(audio.play_unit_voice(china, &"select"), "Chinese selection voice plays")
	check(_played.back() == &"voice_villager_select_chinese", "voice uses unit civilization")
	china.civ = load("res://data/civs/teutons.tres")
	await process_frame
	audio.stop_all()
	check(audio.play_unit_voice(china, &"move"), "Teuton command voice plays")
	check(_played.back() == &"voice_villager_move_teutons", "Teuton voice remains separate")
	china.def = UnitDef.new()
	china.def.id = &"trebuchet"
	await process_frame
	audio.stop_all()
	check(audio.play_unit_voice(china, &"select"), "siege selection uses original cue")
	check(_played.back() == &"voice_trebuchet_select_teutons", "siege engine does not use infantry voice")
	china.team = Enums.Team.AI
	await process_frame
	audio.stop_all()
	check(not audio.play_unit_voice(china, &"select"), "enemy selection does not acknowledge player orders")
	china.free()
	source.free()
	audio.stop_all()
	for pool in audio._players.values():
		for player in pool: player.stream = null
	audio._streams.clear()
	# Let the audio thread consume the same-frame play/stop stress test.
	await create_timer(0.15, true, false, true).timeout
	print("Game audio: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)
