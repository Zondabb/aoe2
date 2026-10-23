extends SceneTree
class FakeGateway extends Node:
	var stopped := false
	func stop() -> void:
		stopped = true

var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error("TEAM AI ROUTING: " + label)

func _run() -> void:
	var Settings: GDScript = load("res://scripts/core/game_settings.gd")
	var PlayerControl: GDScript = load("res://scripts/ai_gateway/player_ai_control.gd")
	for pair in [
		["http://127.0.0.1:8765", "http://127.0.0.1:8765"],
		[" https://AI.example.com:443/ ", "https://ai.example.com:443"],
		["http://localhost:8766", "http://localhost:8766"],
		["http://192.168.1.20:9000", "http://192.168.1.20:9000"],
		["http://[::1]:8766/", "http://[::1]:8766"],
		["HTTPS://[2001:DB8::1]", "https://[2001:db8::1]"],
	]:
		check(Settings.normalize_ai_service_url(pair[0]) == pair[1], "normalize valid root " + pair[0])
	for bad in ["", "http://", "ftp://localhost", "http://user:password@localhost", "http://localhost/path", "http://localhost?key=x", "http://localhost#x", "http://localhost:", "http://localhost:0", "http://localhost:65536", "http://localhost:+5", "http://localhost:8.1", "http://localhost//", "http://999.1.1.1", "http://::1:8765", "http://[::1]garbage", "http://[::1]:", "http://host..test", "http://-host.test", "http://host\\evil", "http://host%2Fpath", "http://local\nhost"]:
		check(Settings.normalize_ai_service_url(bad).is_empty(), "reject malformed root " + bad)
	var session := root.get_node("GameSession")
	session.ai_service_url = "http://127.0.0.1:8765"
	session.ai_chat_url = "http://obsolete.example/v1/chat/completions"
	session.ai_service_token = "shared-test-token"
	session.ai_team_service_urls = {0: "http://127.0.0.1:8766", 1: "https://ai.example.com"}
	session.ai_team_service_tokens = {0: "team-zero-test-token", 1: ""}
	check(PlayerControl.external_config().chat_url == session.ai_chat_url, "no-argument compatibility keeps explicit legacy chat URL")
	var zero: Variant = PlayerControl.external_config(0)
	var one: Variant = PlayerControl.external_config(1)
	check(zero.service_url == "http://127.0.0.1:8766" and one.service_url == "https://ai.example.com", "teams resolve independently")
	check(zero.chat_url.is_empty() and one.chat_url.is_empty(), "shared chat endpoint cannot override team routing")
	check(zero.api_token == "team-zero-test-token" and one.api_token == "shared-test-token", "per-team credentials inherit shared token when empty")
	check(not zero.use_local_embedded and zero.protocol == "v2_chat", "team config always uses external service")
	session.ai_team_service_urls[1] = ""
	check(PlayerControl.external_config(1).service_url == session.ai_service_url, "empty team URL inherits shared service")
	session.ai_service_url = "http://user:password@localhost"
	check(PlayerControl.external_config(1).service_url == "http://127.0.0.1:8765", "invalid legacy shared URL cannot expose embedded credentials in snapshots")
	session.ai_service_url = "http://127.0.0.1:8765"
	var controller: Node = PlayerControl.new()
	root.add_child(controller)
	controller.online = true
	controller.local_team = 0
	check(controller.request_team_service_url(1, "http://localhost:9876/"), "host may configure guest service")
	check(controller.team_service_url(1) == "http://localhost:9876", "host endpoint update is normalized")
	check(not controller.request_team_service_url(1, "http://name@localhost"), "invalid update is rejected")
	check(controller.team_service_url(1) == "http://localhost:9876", "invalid update preserves previous endpoint")
	var old := FakeGateway.new()
	controller.add_child(old)
	controller._gateways[0] = old
	check(controller.request_team_service_url(0, "http://localhost:9999"), "host may update own endpoint")
	check(old.stopped and not controller._gateways.has(0), "endpoint switch stops and removes old gateway")
	var snapshot: Dictionary = controller.capture_states()
	check(snapshot["0"].service_url == "http://localhost:9999" and snapshot["1"].service_url == "http://localhost:9876", "public snapshot includes both service roots")
	check(not JSON.stringify(snapshot).contains("test-token") and not snapshot["0"].has("api_token"), "service credentials never enter public snapshot")
	controller.local_team = 1
	controller.apply_remote_states(snapshot)
	check(controller.team_service_url(0) == snapshot["0"].service_url and controller.team_service_url(1) == snapshot["1"].service_url, "guest reads authoritative host endpoints")
	check(not controller.request_team_service_url(0, "http://localhost:1") and not controller.request_team_service_url(1, "http://localhost:1"), "guest cannot direct host HTTP requests for either team")
	controller.online = false
	controller.local_team = 0
	check(not controller.request_team_service_url(1, "http://localhost:1"), "single player cannot modify opponent player control")
	check(not controller.request_team_service_url(2, "http://localhost:1"), "invalid team rejected")
	controller.stop_all()
	check(not controller.request_team_service_url(0, "http://localhost:1"), "ended match cannot restart routing")
	controller.queue_free()
	var cfg := ConfigFile.new()
	cfg.set_value("ai", "team_0_service_url", "http://localhost:8765/")
	cfg.set_value("ai", "team_1_service_url", "http://localhost:8766")
	cfg.set_value("ai", "team_0_api_token", "private-fixture")
	var path := "res://.godot/team-ai-routing-test.cfg"
	check(cfg.save(path) == OK, "write isolated configuration fixture")
	var loaded: Dictionary = Settings.load_ai_settings(path)
	check(loaded.team_0_service_url == "http://localhost:8765" and loaded.team_1_service_url == "http://localhost:8766", "both team endpoints load from cfg")
	check(loaded.team_0_api_token == "private-fixture" and loaded.team_1_api_token == "", "optional per-team credentials load from cfg")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	await process_frame
	print("TEAM AI ROUTING: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
