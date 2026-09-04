class_name HttpAiClient
extends Node

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")

var config: AiConfig

var _http: HTTPRequest
var _active := false
var _active_result: Dictionary = {}


func _ready() -> void:
	_ensure_http()


func _exit_tree() -> void:
	_active = false


func configure(new_config: AiConfig) -> void:
	config = new_config
	_ensure_http()
	_apply_timeout()


func cancel_requests() -> void:
	_active = false
	if _http != null:
		_http.cancel_request()


func get_health() -> Dictionary:
	return await _request_json("GET", config.health_url(), {})


func post_match_start(payload: Dictionary) -> Dictionary:
	return await _request_json("POST", config.match_start_url(), payload)


func post_match_end(payload: Dictionary) -> Dictionary:
	return await _request_json("POST", config.match_end_url(), payload)


func post_tick(request_dict: Dictionary, retry: bool = true) -> Dictionary:
	var response := await _request_json("POST", config.tick_url(), request_dict)
	if response.get("ok") == true:
		return response.get("body", {}) as Dictionary
	if retry and _should_retry(response):
		push_warning("AI tick request failed (%s), retrying once" % response.get("reason", ""))
		response = await _request_json("POST", config.tick_url(), request_dict)
		if response.get("ok") == true:
			return response.get("body", {}) as Dictionary
	push_warning("AI tick skipped: %s" % response.get("reason", "unknown"))
	return {}


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


func _request_json(method: String, url: String, payload: Dictionary) -> Dictionary:
	if not _ensure_http():
		return {"ok": false, "reason": "http_not_ready"}
	while _active:
		if not await _wait_frame():
			return {"ok": false, "reason": "tree_exited"}
	_active = true
	_active_result = {}
	var headers := PackedStringArray(["Content-Type: application/json"])
	var body := ""
	if method != "GET":
		body = JSON.stringify(AiProtocolScript.json_safe(payload))
	var http_method := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var err := _http.request(url, headers, http_method, body)
	if err != OK:
		_active = false
		return {"ok": false, "reason": "network_error", "error_code": err}
	while _active:
		if not is_instance_valid(self) or not is_inside_tree():
			_active = false
			return {"ok": false, "reason": "tree_exited"}
		if not await _wait_frame():
			_active = false
			return {"ok": false, "reason": "tree_exited"}
	return _active_result


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
	_active = false
