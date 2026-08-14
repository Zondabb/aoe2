class_name AiRunContext
extends RefCounted

var match_state: MatchState
var entities: Node2D
var civ: CivDef
var profile: CivAiProfile
var team: Enums.Team
var enemy_team: Enums.Team
var blackboard: AiBlackboard
var decision_log: AiDecisionLog
var team_label: String
var phase: int = 0
var next_build_slot: int = 0


func log_decision(category: String, message: String) -> void:
	if decision_log == null:
		return
	decision_log.log(blackboard.match_time, team_label, category, message)
