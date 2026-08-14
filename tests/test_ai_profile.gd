extends RefCounted

const CivAiProfileScript := preload("res://scripts/data/civ_ai_profile.gd")
const CHINESE: CivDef = preload("res://data/civs/chinese.tres")
const TEUTONS: CivDef = preload("res://data/civs/teutons.tres")


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_profile_load(failures)
	_test_phase_ratios(failures)
	return failures


func _test_profile_load(failures: Array[String]) -> void:
	var chinese := CivAiProfileScript.for_civ(CHINESE)
	if chinese == null or chinese.civ_id != &"chinese":
		failures.append("Chinese AI profile should load from data/ai/profile_chinese.tres")
	var teutons := CivAiProfileScript.for_civ(TEUTONS)
	if teutons == null or teutons.civ_id != &"teutons":
		failures.append("Teutons AI profile should load from data/ai/profile_teutons.tres")
	if not teutons.build_order.has(&"stable"):
		failures.append("Teutons profile should include stable in build order")


func _test_phase_ratios(failures: Array[String]) -> void:
	var profile := CivAiProfileScript.for_civ(CHINESE)
	var eco := profile.ratios_for_phase(0)
	if float(eco[Enums.ResourceType.FOOD]) < 0.5:
		failures.append("ECO phase should prioritize food gathering")
