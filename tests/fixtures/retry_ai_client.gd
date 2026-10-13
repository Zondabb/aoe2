extends "res://scripts/ai_gateway/http_ai_client.gd"
## Cancel at the retry boundary, rather than duplicating retry implementation.

var attempts := 0
var cancel_in_retry := false
var replies: Array = [
	{"ok":false,"reason":"http_503"},
	{"ok":true,"body":{"completion":"recovered","responses":[{"completion":"recovered"}]}},
]

func _request_json(_method: String, _url: String, _payload: Dictionary, generation: int = -1) -> Dictionary:
	if generation != -1 and generation != _cancel_generation:
		return {"ok":false,"reason":"cancelled"}
	attempts += 1
	return replies[mini(attempts - 1, replies.size() - 1)].duplicate(true)

func _should_retry(response: Dictionary) -> bool:
	var retry := super._should_retry(response)
	if retry and cancel_in_retry:
		cancel_requests()
	return retry
