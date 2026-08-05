extends RefCounted

func run() -> Array[String]:
	var failures: Array[String] = []
	var c: CivDef = load("res://data/civs/chinese.tres")
	var t: CivDef = load("res://data/civs/teutons.tres")
	if c.extra_starting_villagers != 1:
		failures.append("chinese extra villagers")
	if t.building_hp_mul < 1.2:
		failures.append("teutons hp mul")
	if t.melee_armor_bonus != 1:
		failures.append("teutons armor bonus")
	return failures
