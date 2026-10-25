extends "res://scripts/ai_gateway/http_ai_client.gd"
## Preserve the real cancellable frame waiter, but capture only complete
## in-memory payloads. No HTTP request or external model is contacted.
class HeldResponse extends RefCounted:
	signal resumed
	var done := false
	var reply: Dictionary = {}
	func finish(value: Dictionary) -> void:
		if done: return
		done = true
		reply = value
		resumed.emit()

var requests: Array[Dictionary] = []
var release_on_cancel := true
var calls := 0
var cancels := 0

func cancel_requests() -> void:
	cancels += 1
	var old_requests := requests.duplicate()
	super.cancel_requests()
	if release_on_cancel:
		for request in old_requests:
			(request.ticket as HeldResponse).finish({})

func _capture(operation: String, payload: Dictionary) -> Dictionary:
	var ticket := HeldResponse.new()
	requests.append({"operation": operation, "payload": payload.duplicate(true), "ticket": ticket})
	calls += 1
	await ticket.resumed
	return ticket.reply

func post_tick(payload: Dictionary, _retry := true) -> Dictionary:
	return await _capture("tick", payload)

func post_chat_completions(payload: Dictionary, _retry := true) -> Dictionary:
	return await _capture("chat", payload)

func post_multi_agent_tick(payload: Dictionary) -> Dictionary:
	return await _capture("multi", payload)

func post_tick_batch(payload: Dictionary, _retry := true) -> Array:
	var reply := await _capture("tick_batch", payload)
	return reply.get("responses", [])

func post_chat_completions_batch(payload: Dictionary, _retry := true) -> Array:
	var reply := await _capture("chat_batch", payload)
	return reply.get("responses", [])
