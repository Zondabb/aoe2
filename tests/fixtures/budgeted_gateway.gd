extends "res://scripts/ai_gateway/ai_gateway.gd"
## Force deterministic preparation boundaries without changing production APIs.
var audit := {"waits": 0, "resumed": 0, "pending": 0}

func _observation_frame_budget_usec() -> int:
	return 1

func _wait_observation_frame(generation: int) -> bool:
	audit.waits += 1
	audit.pending += 1
	var result: bool = await super._wait_observation_frame(generation)
	audit.pending -= 1
	audit.resumed += 1
	return result
