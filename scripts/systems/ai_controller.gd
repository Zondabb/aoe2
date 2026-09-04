# scripts/systems/ai_controller.gd
class_name AiController
extends AiDirector

## Legacy wrapper: ECO / MILITARY / ATTACK for existing tests and match bootstrap.
## Named LegacyPhase because AiDirector already defines Phase.

enum LegacyPhase { ECO, MILITARY, ATTACK }

var _legacy_phase: LegacyPhase = LegacyPhase.ECO

## Legacy alias: hostile scans use player_team as the enemy side.
var player_team: Enums.Team:
	get:
		return enemy_team
	set(value):
		enemy_team = value


var phase: LegacyPhase:
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
	shared_log: AiDecisionLog = null,
	defer_evaluate: bool = true
) -> void:
	super.setup(state, entities_root, civ, ai_side, enemy_side, label, shared_log, defer_evaluate)
	_legacy_phase = LegacyPhase.ECO


func evaluate() -> void:
	super.evaluate()
	_legacy_phase = _to_legacy_phase(director_phase)


func _from_legacy_phase(value: LegacyPhase) -> AiDirector.Phase:
	match value:
		LegacyPhase.ECO:
			return AiDirector.Phase.ECO
		LegacyPhase.MILITARY:
			return AiDirector.Phase.BOOM
		_:
			return AiDirector.Phase.ATTACK


func _to_legacy_phase(value: AiDirector.Phase) -> LegacyPhase:
	match value:
		AiDirector.Phase.ECO:
			return LegacyPhase.ECO
		AiDirector.Phase.BOOM:
			return LegacyPhase.MILITARY
		_:
			return LegacyPhase.ATTACK


func _nearest_hostile_in_radius(unit: Node2D, radius: float) -> Node2D:
	return nearest_hostile_in_radius(unit, radius)
