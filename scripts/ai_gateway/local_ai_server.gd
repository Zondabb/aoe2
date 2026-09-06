class_name LocalAiServer
extends Node

const AiConfigScript := preload("res://scripts/ai_gateway/ai_config.gd")
const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const AiServiceAdapterScript := preload("res://scripts/ai_gateway/ai_service_adapter.gd")
const HttpAiClientScript := preload("res://scripts/ai_gateway/http_ai_client.gd")

enum ServiceMode { NONE, PYTHON, ADAPTER }

var config: AiConfig
var adapter: AiServiceAdapter
var http_client: HttpAiClient

var _server := TCPServer.new()
var _clients: Array[StreamPeerTCP] = []
var _running := false
var _python_pid := -1
var _service_mode := ServiceMode.NONE


func configure(
	new_config: AiConfig,
	service_adapter: AiServiceAdapter,
	client: HttpAiClient = null
) -> void:
	config = new_config
	adapter = service_adapter
	http_client = client


func start() -> bool:
	if _service_mode != ServiceMode.NONE:
		return true
	return _start_adapter_tcp()


func start_async() -> bool:
	if _service_mode != ServiceMode.NONE:
		return true
	if await _try_start_python():
		_service_mode = ServiceMode.PYTHON
		print("LocalAiServer: Python AI service on http://127.0.0.1:%d" % AiConfigScript.DEFAULT_PORT)
		return true
	push_warning("LocalAiServer: Python unavailable, falling back to GDScript adapter")
	if _start_adapter_tcp():
		_service_mode = ServiceMode.ADAPTER
		return true
	return false


func uses_adapter_fallback() -> bool:
	return _service_mode == ServiceMode.ADAPTER


func is_running() -> bool:
	return _service_mode != ServiceMode.NONE


func stop() -> void:
	if _python_pid > 0:
		OS.kill(_python_pid)
		_python_pid = -1
	if _running:
		_server.stop()
		for client in _clients:
			if client != null:
				client.disconnect_from_host()
		_clients.clear()
		_running = false
		set_process(false)
	_service_mode = ServiceMode.NONE


func _try_start_python() -> bool:
	var main_py := ProjectSettings.globalize_path("res://ai_service_python/main.py")
	if not FileAccess.file_exists(main_py):
		return false
	var python := _find_python_executable()
	if python.is_empty():
		return false
	if http_client != null:
		var existing := await http_client.get_health()
		if existing.get("ok") == true:
			return true
	var args := PackedStringArray([main_py])
	_python_pid = OS.create_process(python, args, false)
	if _python_pid <= 0:
		return false
	for _attempt in 10:
		await _await_timer(0.3)
		if http_client == null:
			continue
		var health := await http_client.get_health()
		if health.get("ok") == true:
			return true
	if _python_pid > 0:
		OS.kill(_python_pid)
		_python_pid = -1
	return false


func _find_python_executable() -> String:
	return "python" if OS.get_name() == "Windows" else "python3"


func _await_timer(seconds: float) -> void:
	var tree := get_tree()
	if tree != null:
		await tree.create_timer(seconds).timeout
		return
	var loop := Engine.get_main_loop()
	if loop != null and loop.has_method("create_timer"):
		await loop.create_timer(seconds).timeout


func _start_adapter_tcp() -> bool:
	if _running:
		return true
	var err := _server.listen(AiConfigScript.DEFAULT_PORT, AiConfigScript.DEFAULT_HOST)
	if err != OK:
		push_warning("LocalAiServer failed to listen on %s:%d (%s)" % [
			AiConfigScript.DEFAULT_HOST,
			AiConfigScript.DEFAULT_PORT,
			err,
		])
		return false
	_running = true
	set_process(true)
	print("LocalAiServer listening (adapter) on http://%s:%d" % [
		AiConfigScript.DEFAULT_HOST,
		AiConfigScript.DEFAULT_PORT,
	])
	return true


func _process(_delta: float) -> void:
	if not _running:
		return
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer != null:
			_clients.append(peer)
	var index := _clients.size() - 1
	while index >= 0:
		var client := _clients[index]
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_clients.remove_at(index)
			index -= 1
			continue
		client.poll()
		if client.get_available_bytes() <= 0:
			index -= 1
			continue
		var request_text := client.get_string(client.get_available_bytes())
		var response := _handle_http_request(request_text)
		client.put_data(response.to_utf8_buffer())
		client.disconnect_from_host()
		_clients.remove_at(index)
		index -= 1


func _handle_http_request(request_text: String) -> String:
	var lines := request_text.split("\r\n")
	if lines.is_empty():
		return _http_response(400, {"error": "invalid_request"})
	var request_line := lines[0].split(" ")
	if request_line.size() < 2:
		return _http_response(400, {"error": "invalid_request"})
	var method := String(request_line[0])
	var path := String(request_line[1]).split("?")[0]
	var body := _extract_body(lines, request_text)

	if method == "GET" and path == "/health":
		return _http_response(200, {"status": "ok"})
	if method == "POST" and path == "/v1/ai/match/start":
		return _handle_json_post(body, adapter.handle_match_start)
	if method == "POST" and path == "/v1/ai/match/end":
		return _handle_json_post(body, adapter.handle_match_end)
	if method == "POST" and path == "/v1/ai/tick":
		return _handle_json_post(body, adapter.handle_tick)
	if method == "POST" and path == "/v1/ai/tick_batch":
		return _handle_json_post(body, adapter.handle_tick_batch)
	if method == "POST" and path == "/v1/chat/completions":
		return _handle_json_post(body, adapter.handle_chat_completions)
	if method == "POST" and path == "/v1/chat/completions_batch":
		return _handle_json_post(body, adapter.handle_chat_completions_batch)
	return _http_response(404, {"error": "not_found"})


func _handle_json_post(body: String, handler: Callable) -> String:
	var payload: Variant = {}
	if not body.is_empty():
		var json := JSON.new()
		if json.parse(body) != OK:
			return _http_response(400, {"error": "invalid_request", "detail": "bad_json"})
		payload = json.data
	if not (payload is Dictionary):
		return _http_response(400, {"error": "invalid_request", "detail": "expected_object"})
	if adapter == null:
		return _http_response(500, {"error": "internal", "detail": "adapter_missing"})
	var response: Dictionary = handler.call(payload)
	return _http_response(200, response)


func _extract_body(lines: PackedStringArray, request_text: String) -> String:
	var body_start := request_text.find("\r\n\r\n")
	if body_start < 0:
		return ""
	return request_text.substr(body_start + 4)


func _http_response(status_code: int, payload: Dictionary) -> String:
	var body := JSON.stringify(AiProtocolScript.json_safe(payload))
	return "HTTP/1.1 %d OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [
		status_code,
		body.to_utf8_buffer().size(),
		body,
	]
