class_name CommandExecutionContext
extends RefCounted

## 命令校验与执行时的对局上下文（P1：内存 mock，P2 由 AiGateway 填充）。

var match_id := ""
var match_state: MatchState
var entities: Node2D
var team: Enums.Team = Enums.Team.AI
var civ: CivDef
var next_build_slot: int = 0
var executed_command_ids: Dictionary = {}


func clear_command_history() -> void:
	executed_command_ids.clear()
