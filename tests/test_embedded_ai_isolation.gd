extends Node
## Real loopback tests; no model provider or paid requests are involved.

const Config := preload("res://scripts/ai_gateway/ai_config.gd")
const LocalServer := preload("res://scripts/ai_gateway/local_ai_server.gd")
const Adapter := preload("res://scripts/ai_gateway/ai_service_adapter.gd")
const Client := preload("res://scripts/ai_gateway/http_ai_client.gd")

class AdapterOnlyServer extends LocalServer:
	func _find_python_executable() -> String:
		return ""

var checks := 0
var failures: Array[String] = []
var _saved_env: Dictionary = {}

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error(label)

func run() -> int:
	var root := get_tree().root
	var external_config := Config.new()
	var external := LocalServer.new()
	root.add_child(external)
	external.configure(external_config, Adapter.new())
	check(external.start(), "fixture external service starts on its own free port")
	var external_url := external_config.service_url
	var config := Config.new()
	config.service_url = external_url
	config.chat_url = external_url + "/wrong-upstream"
	config.api_token = "external-test-token"
	config.use_local_embedded = true
	config.protocol = "v2_chat"
	config.timeout_sec = 2
	var client := Client.new()
	root.add_child(client)
	client.configure(config)
	var server := LocalServer.new()
	root.add_child(server)
	server.configure(config, Adapter.new(), client)
	# Explicit embedded CLI flags must beat unrelated external service env/config.
	for name in ["AOE2_AI_HOST", "AOE2_AI_PORT", "AOE2_AI_TOKEN", "AOE2_AI_BACKEND", "AOE2_AI_CONFIG", "AOE2_LLM_BASE_URL"]:
		_saved_env[name] = {"present": OS.has_environment(name), "value": OS.get_environment(name)}
	OS.set_environment("AOE2_AI_HOST", "invalid.example")
	OS.set_environment("AOE2_AI_PORT", str(external._server.get_local_port()))
	OS.set_environment("AOE2_AI_TOKEN", "unrelated-external-token")
	OS.set_environment("AOE2_AI_BACKEND", "openai")
	OS.set_environment("AOE2_AI_CONFIG", "res://nonexistent-external-config.toml")
	OS.set_environment("AOE2_LLM_BASE_URL", "http://127.0.0.1:1/v1")
	var started := await server.start_async()
	check(started and not server.uses_adapter_fallback(), "embedded Python rules service starts despite bad config and external host/port/token/backend environment")
	check(config.service_url != external_url and config.service_url.begins_with("http://127.0.0.1:"), "embedded never reuses an existing healthy service")
	check(config.chat_url.is_empty(), "embedded clears unrelated external chat endpoint")
	check(not config.api_token.is_empty() and config.api_token != "external-test-token", "embedded uses its own generated service credential")
	var child_pid := server._python_pid
	if started:
		var response := await client.post_chat_completions(_rules_request(), false)
		check(not response.get("choices", []).is_empty(), "embedded accepts authenticated chat rules request")
		check(not client.last_error and not JSON.stringify(response).contains("LLM_FALLBACK"), "embedded rules request does not invoke or fail over from upstream LLM")
		var generated_token := config.api_token
		config.api_token = "wrong-test-token"
		var denied := await client.post_match_start({"match_id": "denied", "teams": []})
		check(denied.get("reason") == "http_401", "embedded requires its generated token instead of inherited external credential")
		config.api_token = generated_token
	server.stop()
	check(child_pid > 0 and not OS.is_process_running(child_pid), "stop terminates the Python child owned by this instance")
	check(config.service_url == external_url and config.chat_url.ends_with("/wrong-upstream") and config.api_token == "external-test-token", "stop restores caller endpoint settings")
	config.chat_url = ""
	var health := await client.get_health()
	check(health.get("ok") == true and external.is_running(), "stopping embedded service leaves external service running")
	server.free()
	var fallback := AdapterOnlyServer.new()
	root.add_child(fallback)
	fallback.configure(config, Adapter.new(), client)
	check(await fallback.start_async(), "GDScript fallback still starts when Python is unavailable")
	check(fallback.uses_adapter_fallback() and config.service_url != external_url, "adapter fallback owns a separate free port")
	health = await client.get_health()
	check(health.get("ok") == true, "client follows adapter fallback endpoint")
	var fallback_response := await client.post_chat_completions(_rules_request(), false)
	check(not fallback_response.get("choices", []).is_empty(), "adapter fallback handles chat rules request")
	fallback.stop()
	check(external.is_running(), "stopping fallback leaves external service running")
	fallback.free()
	await _test_cancelled_start(config, client)
	for name in _saved_env:
		if _saved_env[name].present:
			OS.set_environment(name, _saved_env[name].value)
		else:
			OS.unset_environment(name)
	client.free()
	external.stop()
	external.free()
	print("EMBEDDED AI ISOLATION: %d checks, %d failures" % [checks, failures.size()])
	return 0 if failures.is_empty() else 1

func _test_cancelled_start(config: AiConfig, client: HttpAiClient) -> void:
	var server := LocalServer.new()
	get_tree().root.add_child(server)
	server.configure(config, Adapter.new(), client)
	var completed := {"done": false, "result": true}
	_start_in_background(server, completed)
	var pid := server._python_pid
	server.stop()
	await get_tree().create_timer(0.5).timeout
	check(completed.done and not completed.result, "cancelled startup cannot revive itself or start fallback")
	check(not server.is_running() and server._python_pid == -1 and (pid <= 0 or not OS.is_process_running(pid)), "stop also cleans a Python process still starting")
	server.free()

func _start_in_background(server: LocalAiServer, completed: Dictionary) -> void:
	completed.result = await server.start_async()
	completed.done = true

func _rules_request() -> Dictionary:
	return {
		"model": "ignored-client-model",
		"messages": [{"role": "user", "content": "Take a rules turn"}],
		"metadata": {"match_id": "embedded-isolation", "team": 1, "tick": 0, "backend": "openai"},
		"observation": {
			"economy": {"food": 0, "wood": 0, "gold": 0, "pop_used": 0, "pop_cap": 5},
			"derived": {"own_tc_id": -1, "own_tc_pos": [0, 0], "enemy_tc_id": -1, "enemy_tc_pos": [0, 0], "threat_near_base": false, "villager_count": 0, "military_count": 0, "incomplete_buildings": 0},
			"entities": [],
		},
	}
