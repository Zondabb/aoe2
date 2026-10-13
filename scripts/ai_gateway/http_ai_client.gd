class_name HttpAiClient
extends Node

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")

var config: AiConfig

var _http: HTTPRequest
var _active := false
var _active_result: Dictionary = {}
var _active_request: Dictionary = {}
var _cancel_generation := 0
var _active_generation := -1
var last_error := ""


func _ready() -> void:
	_ensure_http()


func _exit_tree() -> void:
	cancel_requests()


func configure(new_config: AiConfig) -> void:
	config = new_config
	_ensure_http()
	_apply_timeout()


func cancel_requests() -> void:
	_cancel_generation += 1
	_active = false
	_active_result = {"ok": false, "reason": "cancelled"}
	if not _active_request.is_empty():
		_active_request["result"] = _active_result
		_active_request["done"] = true
	if _http != null and is_instance_valid(_http):
		_http.cancel_request()


func get_health() -> Dictionary:
	return await _request_json("GET", config.health_url(), {})


func post_match_start(payload: Dictionary) -> Dictionary:
	return await _request_json("POST", config.match_start_url(), payload)


func post_match_end(payload: Dictionary) -> Dictionary:
	return await _request_json("POST", config.match_end_url(), payload)


func post_tick(request_dict: Dictionary, retry: bool = true) -> Dictionary:
	return await _request_ai_body(config.tick_url(), request_dict, retry, "tick")


func post_chat_completions(request_dict: Dictionary, retry: bool = true) -> Dictionary:
	return await _request_ai_body(
		config.chat_completions_url(), request_dict, retry, "chat completions"
	)


func post_chat_completions_batch(request_dict: Dictionary, retry: bool = true) -> Array:
	var body := await _request_ai_body(
		config.chat_completions_batch_url(), request_dict, retry, "chat completions_batch"
	)
	return body.get("responses", [])


func post_tick_batch(request_dict: Dictionary, retry: bool = true) -> Array:
	var body := await _request_ai_body(config.tick_batch_url(), request_dict, retry, "tick_batch")
	return body.get("responses", [])


func _request_ai_body(url: String, payload: Dictionary, retry: bool, label: String) -> Dictionary:
	var generation := _cancel_generation
	var response := await _request_json("POST", url, payload, generation)
	if _was_cancelled(response, generation):
		return {}
	if response.get("ok") == true:
		last_error = ""
		return response.get("body", {}) as Dictionary
	if retry and _should_retry(response):
		if generation != _cancel_generation:
			return {}
		push_warning(
			"AI %s request failed (%s), retrying once" % [label, response.get("reason", "")]
		)
		response = await _request_json("POST", url, payload, generation)
		if _was_cancelled(response, generation):
			return {}
		if response.get("ok") == true:
			last_error = ""
			return response.get("body", {}) as Dictionary
	last_error = String(response.get("reason", "unknown"))
	push_warning("AI %s skipped: %s" % [label, last_error])
	return {}


func _was_cancelled(response: Dictionary, generation: int) -> bool:
	return generation != _cancel_generation or response.get("reason") in ["cancelled", "tree_exited"]


func _should_retry(response: Dictionary) -> bool:
	var reason := String(response.get("reason", ""))
	return reason in ["timeout", "http_408", "http_503", "network_error"]


func _ensure_http() -> bool:
	if _http != null:
		return true
	if not is_inside_tree():
		return false
	_http = HTTPRequest.new()
	add_child(_http)
	if not _http.request_completed.is_connected(_on_request_completed):
		_http.request_completed.connect(_on_request_completed)
	_apply_timeout()
	return true


func _apply_timeout() -> void:
	if _http == null or config == null:
		return
	_http.timeout = int(maxf(1.0, config.timeout_sec))


func _request_json(method: String, url: String, payload: Dictionary, generation: int = -1) -> Dictionary:
	if generation == -1:
		generation = _cancel_generation
	if generation != _cancel_generation:
		return {"ok": false, "reason": "cancelled"}
	if not _ensure_http():
		return {"ok": false, "reason": "http_not_ready"}
	while _active and generation == _cancel_generation:
		if not await _wait_frame():
			return {"ok": false, "reason": "tree_exited"}
	if generation != _cancel_generation:
		return {"ok": false, "reason": "cancelled"}
	_active = true
	_active_generation = generation
	_active_result = {}
	# Each waiter retains its own result if the next queued request starts first.
	var request := {"done":false, "result":{}}
	_active_request = request
	last_error = ""
	var headers := _auth_headers()
	var body := ""
	if method != "GET":
		body = JSON.stringify(AiProtocolScript.json_safe(payload))
	if generation != _cancel_generation:
		return {"ok": false, "reason": "cancelled"}
	var http_method := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var err := _http.request(url, headers, http_method, body)
	if err != OK:
		_active = false
		request["done"] = true
		request["result"] = {"ok": false, "reason": "network_error", "error_code": err}
		return request["result"]
	while not request["done"] and generation == _cancel_generation:
		if not is_instance_valid(self) or not is_inside_tree():
			_active = false
			return {"ok": false, "reason": "tree_exited"}
		if not await _wait_frame():
			_active = false
			return {"ok": false, "reason": "tree_exited"}
	if generation != _cancel_generation:
		return {"ok": false, "reason": "cancelled"}
	return request["result"]


func _wait_frame() -> bool:
	var tree := _scene_tree()
	if tree == null:
		return false
	await tree.process_frame
	return is_instance_valid(self)


func _scene_tree() -> SceneTree:
	var tree := get_tree()
	if tree != null:
		return tree
	return Engine.get_main_loop() as SceneTree


func _on_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	if not _active or _active_generation != _cancel_generation:
		return
	var parsed: Variant = {}
	if not body.is_empty():
		var json := JSON.new()
		if json.parse(body.get_string_from_utf8()) == OK:
			parsed = json.data
	if result != HTTPRequest.RESULT_SUCCESS:
		var reason := "network_error"
		if result == HTTPRequest.RESULT_TIMEOUT:
			reason = "timeout"
		_active_result = {"ok": false, "reason": reason, "result": result}
	elif response_code == 408:
		_active_result = {"ok": false, "reason": "http_408", "status": response_code}
	elif response_code == 503:
		_active_result = {"ok": false, "reason": "http_503", "status": response_code}
	elif response_code >= 500:
		_active_result = {
			"ok": false, "reason": "http_500", "status": response_code, "body": parsed
		}
	elif response_code == 400:
		_active_result = {
			"ok": false, "reason": "http_400", "status": response_code, "body": parsed
		}
	elif response_code == 401:
		_active_result = {
			"ok": false, "reason": "http_401", "status": response_code, "body": parsed
		}
	elif response_code < 200 or response_code >= 300:
		_active_result = {
			"ok": false,
			"reason": "http_%d" % response_code,
			"status": response_code,
			"body": parsed,
		}
	else:
		_active_result = {
			"ok": true,
			"status": response_code,
			"body": parsed if parsed is Dictionary else {},
		}
	_active_request["result"] = _active_result
	_active_request["done"] = true
	_active = false


func _auth_headers() -> PackedStringArray:
	var headers := PackedStringArray(["Content-Type: application/json"])
	if config != null and not config.bearer_token.is_empty():
		headers.append("Authorization: Bearer %s" % config.bearer_token)
	return headers
