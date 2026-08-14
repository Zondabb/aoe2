# scripts/systems/ai_controller.gd
class_name AiController
extends AiDirector

## Legacy wrapper: Phase.ECO / MILITARY / ATTACK for existing tests and match bootstrap.

enum Phase { ECO, MILITARY, ATTACK }

var _legacy_phase: Phase = Phase.ECO

## Legacy alias: hostile scans use player_team as the enemy side.
var player_team: Enums.Team:
	get:
		return enemy_team
	set(value):
		enemy_team = value


var phase: Phase:
	get:
		return _legacy_phase
	set(value):
		_legacy_phase = value
		director_phase = _from_legacy_phase(value)


func setup(
	state: MatchState,
	entities_root: Node2D,
	civ: CivDef,
	ai_side: Enums.Team = Enums.Team.AI,
	enemy_side: Enums.Team = Enums.Team.PLAYER,
	label: String = "",
	shared_log: AiDecisionLog = null
) -> void:
	super.setup(state, entities_root, civ, ai_side, enemy_side, label, shared_log)
	_legacy_phase = Phase.ECO


func evaluate() -> void:
	super.evaluate()
	_legacy_phase = _to_legacy_phase(director_phase)


func _from_legacy_phase(value: Phase) -> AiDirector.Phase:
	match value:
		Phase.ECO:
			return AiDirector.Phase.ECO
		Phase.MILITARY:
			return AiDirector.Phase.BOOM
		_:
			return AiDirector.Phase.ATTACK


func _to_legacy_phase(value: AiDirector.Phase) -> Phase:
	match value:
		AiDirector.Phase.ECO:
			return Phase.ECO
		AiDirector.Phase.BOOM:
			return Phase.MILITARY
		_:
			return Phase.ATTACK


func _nearest_hostile_in_radius(unit: Node2D, radius: float) -> Node2D:
	return nearest_hostile_in_radius(unit, radius)
