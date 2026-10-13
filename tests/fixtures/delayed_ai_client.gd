extends "res://scripts/ai_gateway/http_ai_client.gd"
## Loaded after GameSession initializes; no real HTTP or upstream LLM calls.

signal completed
var calls := 0
var start_calls := 0
var cancels := 0
var health_delay := false
var start_delay := false
var health_reply := {"ok":true}
var response: Dictionary = {}

func cancel_requests() -> void:
	cancels += 1
	super.cancel_requests()

func get_health() -> Dictionary:
	if health_delay:
		await completed
	return health_reply

func post_match_start(_payload: Dictionary) -> Dictionary:
	start_calls += 1
	if start_delay:
		await completed
	return {"ok":true}

func post_chat_completions(_payload: Dictionary, _retry: bool = true) -> Dictionary:
	calls += 1
	await completed
	return response

func post_tick(_payload: Dictionary, _retry: bool = true) -> Dictionary:
	calls += 1
	await completed
	return response

func post_chat_completions_batch(_payload: Dictionary, _retry: bool = true) -> Array:
	calls += 1
	await completed
	return [response, response]

func post_tick_batch(_payload: Dictionary, _retry: bool = true) -> Array:
	calls += 1
	await completed
	return [response, response]
