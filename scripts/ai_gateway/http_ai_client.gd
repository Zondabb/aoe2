class_name HttpAiClient
extends Node

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const BACKGROUND_ENTITY_COUNT := 96
const BACKGROUND_VALUE_COUNT := 2048
const BACKGROUND_TEXT_LENGTH := 32768
const MAX_JSON_DEPTH := 128

class JsonPayloadInfo extends RefCounted:
	var values := 0
	var text_length := 0
	var large_entities := false
	var worker_safe := true
	var error := ""

## The worker Callable retains only this pure-data job, never the HTTP client.
## Main-thread code reads body only after joining the completed task.
class JsonEncodingJob extends RefCounted:
	var snapshot: Dictionary
	var body := ""
	func encode() -> void:
		body = JSON.stringify(AiProtocolScript.json_safe(snapshot))

class RequestFrameWaiter extends RefCounted:
	signal resumed
	var released := false
	func wake() -> void:
		if released: return
		released = true
		resumed.emit()

var config: AiConfig

var _http: HTTPRequest
var _active := false
var _active_result: Dictionary = {}
var _active_request: Dictionary = {}
var _cancel_generation := 0
var _active_generation := -1
var _json_task_id := -1
var _json_job: JsonEncodingJob
var _frame_waiters: Array[RequestFrameWaiter] = []
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
	# Native JSON encoding cannot be interrupted. Cancellation/exit joins the
	# current pure-data task rather than leaving a cleanup coroutine or a worker
	# that could outlive its owning request's resource bookkeeping.
	_release_json_task(_json_task_id)
	# Finish existing Node coroutines while _exit_tree still has a live client.
	# Waking can resume callers that start a new generation, so touch no old
	# transport/encoding ownership after this point and wake only this snapshot.
	for waiter: RequestFrameWaiter in _frame_waiters.duplicate():
		waiter.wake()


func get_health() -> Dictionary:
	return await _request_json("GET", config.health_url(), {})


func post_match_start(payload: Dictionary) -> Dictionary:
	return await _request_json("POST", config.match_start_url(), payload)


func post_match_end(payload: Dictionary) -> Dictionary:
	return await _request_json("POST", config.match_end_url(), payload)


func post_tick(request_dict: Dictionary, retry: bool = true) -> Dictionary:
	return await _request_ai_body(config.tick_url(), request_dict, retry, "tick")


func post_multi_agent_tick(request_dict: Dictionary) -> Dictionary:
	# A failed fast tick retries next boundary with current observations; events
	# remain pending until acknowledged. Never wait for an upstream model here.
	return await _request_ai_body(config.multi_agent_tick_url(), request_dict, false, "multi-agent tick")


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
	_http.timeout = maxf(0.5, config.fast_timeout_sec if config.uses_multi_agent_protocol() else config.timeout_sec)


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
		var encoded := await _encode_payload(payload, generation)
		if generation != _cancel_generation:
			return {"ok": false, "reason": "cancelled"}
		if not encoded.get("ok", false):
			_active = false
			request["done"] = true
			request["result"] = encoded
			return encoded
		body = encoded.body
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


## Also usable by the observation benchmark without sending a network request.
## Small requests and unusual reference-valued variants keep the original
## synchronous encoder. Web exports retain that path regardless of thread setup.
func _encode_payload(payload: Dictionary, generation: int = -1) -> Dictionary:
	if generation == -1: generation = _cancel_generation
	if generation != _cancel_generation:
		return {"ok": false, "reason": "cancelled"}
	var info := JsonPayloadInfo.new()
	_inspect_json_value(payload, [], info)
	if not info.error.is_empty():
		return {"ok": false, "reason": info.error}
	var large := info.large_entities or info.values >= BACKGROUND_VALUE_COUNT or info.text_length >= BACKGROUND_TEXT_LENGTH
	if not large or not info.worker_safe or OS.has_feature("web") or not is_inside_tree():
		return {"ok": true, "body": JSON.stringify(AiProtocolScript.json_safe(payload)), "background": false}
	# Freeze before any await, including waiting for a direct helper caller's
	# previous job. A caller can mutate its original payload as soon as we yield.
	var job := _new_json_job(payload.duplicate(true))
	# The transport already serializes requests; this additional guard makes
	# direct benchmark/helper callers obey the same one-encoding-job ownership.
	while _json_task_id >= 0 and generation == _cancel_generation:
		if not await _wait_frame():
			return {"ok": false, "reason": "tree_exited"}
	if generation != _cancel_generation:
		return {"ok": false, "reason": "cancelled"}
	_json_job = job
	var task_id := WorkerThreadPool.add_task(job.encode, false, "AI JSON encoding")
	_json_task_id = task_id
	if task_id < 0:
		_json_job = null
		return {"ok": true, "body": JSON.stringify(AiProtocolScript.json_safe(job.snapshot)), "background": false}
	while not WorkerThreadPool.is_task_completed(task_id):
		if generation != _cancel_generation:
			_release_json_task(task_id)
			return {"ok": false, "reason": "cancelled"}
		if not await _wait_frame():
			# _exit_tree joins before a freed client can leave this await behind.
			if is_instance_valid(self): _release_json_task(task_id)
			return {"ok": false, "reason": "tree_exited"}
		# cancel_requests may have joined/released this ID while we yielded.
		# Never query or wait for an already-released task on the next loop test.
		if generation != _cancel_generation:
			return {"ok": false, "reason": "cancelled"}
	_release_json_task(task_id)
	if generation != _cancel_generation:
		return {"ok": false, "reason": "cancelled"}
	return {"ok": true, "body": job.body, "background": true}


func _new_json_job(snapshot: Dictionary) -> JsonEncodingJob:
	var job := JsonEncodingJob.new()
	job.snapshot = snapshot
	return job


func _release_json_task(task_id: int) -> void:
	if task_id < 0 or task_id != _json_task_id: return
	WorkerThreadPool.wait_for_task_completion(task_id)
	_json_task_id = -1
	_json_job = null


## Inspect both keys and values: json_safe stringifies keys too. Track identity
## along the current ancestor chain so shared subtrees are allowed but cycles
## cannot reach either the recursive converter or duplicate(true).
static func _inspect_json_value(value: Variant, ancestors: Array, info: JsonPayloadInfo, depth: int = 0) -> void:
	if not info.error.is_empty(): return
	info.values += 1
	if depth > MAX_JSON_DEPTH:
		info.error = "json_payload_too_deep"
		return
	var kind := typeof(value)
	if kind == TYPE_ARRAY or kind == TYPE_DICTIONARY:
		for parent in ancestors:
			if is_same(value, parent):
				info.error = "json_payload_cycle"
				return
		ancestors.append(value)
		# Leaves (most values: numbers, flags, text) are visited inline with the
		# same per-value rules as the tail of this function; only containers
		# recurse. Once an error is recorded every later visit is a no-op.
		var child_depth := depth + 1
		if kind == TYPE_DICTIONARY:
			for key in value:
				var key_kind := typeof(key)
				if key_kind == TYPE_ARRAY or key_kind == TYPE_DICTIONARY:
					_inspect_json_value(key, ancestors, info, child_depth)
				elif info.error.is_empty():
					info.values += 1
					if child_depth > MAX_JSON_DEPTH: info.error = "json_payload_too_deep"
					elif key_kind == TYPE_STRING or key_kind == TYPE_STRING_NAME: info.text_length += String(key).length()
					elif key_kind == TYPE_OBJECT or key_kind == TYPE_CALLABLE or key_kind == TYPE_SIGNAL or key_kind == TYPE_RID or key_kind >= TYPE_PACKED_BYTE_ARRAY: info.worker_safe = false
				var item: Variant = value[key]
				if (key_kind == TYPE_STRING or key_kind == TYPE_STRING_NAME) and key == "entities" and item is Array and item.size() >= BACKGROUND_ENTITY_COUNT:
					info.large_entities = true
				var item_kind := typeof(item)
				if item_kind == TYPE_ARRAY or item_kind == TYPE_DICTIONARY:
					_inspect_json_value(item, ancestors, info, child_depth)
				elif info.error.is_empty():
					info.values += 1
					if child_depth > MAX_JSON_DEPTH: info.error = "json_payload_too_deep"
					elif item_kind == TYPE_STRING or item_kind == TYPE_STRING_NAME: info.text_length += String(item).length()
					elif item_kind == TYPE_OBJECT or item_kind == TYPE_CALLABLE or item_kind == TYPE_SIGNAL or item_kind == TYPE_RID or item_kind >= TYPE_PACKED_BYTE_ARRAY: info.worker_safe = false
		else:
			for item in value:
				var item_kind := typeof(item)
				if item_kind == TYPE_ARRAY or item_kind == TYPE_DICTIONARY:
					_inspect_json_value(item, ancestors, info, child_depth)
				elif info.error.is_empty():
					info.values += 1
					if child_depth > MAX_JSON_DEPTH: info.error = "json_payload_too_deep"
					elif item_kind == TYPE_STRING or item_kind == TYPE_STRING_NAME: info.text_length += String(item).length()
					elif item_kind == TYPE_OBJECT or item_kind == TYPE_CALLABLE or item_kind == TYPE_SIGNAL or item_kind == TYPE_RID or item_kind >= TYPE_PACKED_BYTE_ARRAY: info.worker_safe = false
		ancestors.pop_back()
	elif kind == TYPE_STRING or kind == TYPE_STRING_NAME:
		info.text_length += String(value).length()
	elif kind == TYPE_OBJECT or kind == TYPE_CALLABLE or kind == TYPE_SIGNAL or kind == TYPE_RID or kind >= TYPE_PACKED_BYTE_ARRAY:
		# Packed arrays are reference-valued, and deep Dictionary duplication
		# need not isolate their backing storage. Preserve the old main-thread
		# path for these as well as Node/Resource/callable/signal references.
		info.worker_safe = false


func _wait_frame() -> bool:
	var tree := _scene_tree()
	if tree == null:
		return false
	var waiter := RequestFrameWaiter.new()
	_frame_waiters.append(waiter)
	tree.process_frame.connect(waiter.wake, CONNECT_ONE_SHOT)
	await waiter.resumed
	if not is_instance_valid(self): return false
	_frame_waiters.erase(waiter)
	if tree.process_frame.is_connected(waiter.wake):
		tree.process_frame.disconnect(waiter.wake)
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
