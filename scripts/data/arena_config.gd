class_name ArenaConfig
extends Resource

@export var player_civ_id: StringName = &"chinese"
@export var ai_civ_id: StringName = &"teutons"
@export var player_auto_attack := false
@export var ai_auto_attack := false
@export var aggro_radius := 40.0
@export var include_buildings := true
@export var tick_interval := 0.5
@export var unit_counts: Dictionary = {
	&"villager": 2,
	&"swordsman": 2,
	&"archer": 2,
	&"chu_ko_nu": 2,
	&"teutonic_knight": 2,
}

func total_units() -> int:
	var total := 0
	for count in unit_counts.values():
		total += int(count)
	return total

func duplicate_config() -> Resource:
	return duplicate(true)
