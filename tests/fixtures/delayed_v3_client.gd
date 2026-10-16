extends "res://scripts/ai_gateway/http_ai_client.gd"

signal completed
var calls := 0
var last_payload: Dictionary = {}
var response: Dictionary = {}

func post_multi_agent_tick(payload: Dictionary) -> Dictionary:
	calls += 1
	last_payload = payload.duplicate(true)
	await completed
	return response
