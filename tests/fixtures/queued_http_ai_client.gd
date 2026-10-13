extends "res://scripts/ai_gateway/http_ai_client.gd"
## Force the queued request to resume before the completed request's waiter.

signal release_first
var hold_first_wait := true

func _wait_frame() -> bool:
	if hold_first_wait:
		hold_first_wait = false
		await release_first
		return is_instance_valid(self)
	return await super._wait_frame()
