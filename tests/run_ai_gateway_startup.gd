extends SceneTree
## The opponent AI service connection must survive a slow match load. HTTPRequest
## counts scaled frame time, so the first frame after loading, with the whole
## loading time as its delta, used to exhaust the 3 s v3 fast-tick timeout and
## leave the external opponent AI offline for the whole match.

var checks := 0
var failures := 0

class OkServer extends Node:
	var listener := TCPServer.new()
	var peers: Array[Dictionary] = []
	var paths: Array[String] = []
	func _process(_delta: float) -> void:
		while listener.is_connection_available():
			peers.append({"socket": listener.take_connection(), "buffer": "", "answered": false})
		for peer in peers:
			var socket: StreamPeerTCP = peer.socket
			socket.poll()
			if socket.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				continue
			if socket.get_available_bytes() > 0:
				peer.buffer += socket.get_string(socket.get_available_bytes())
			if not peer.answered and String(peer.buffer).contains("\r\n\r\n"):
				peer.answered = true
				paths.append(String(peer.buffer).get_slice(" ", 1))
				var content := JSON.stringify({"ok": true})
				socket.put_data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
					% [content.length(), content]).to_utf8_buffer())
				socket.disconnect_from_host()
	func stop() -> void:
		listener.stop()

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)

func _wait(seconds: float, done: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if done.call():
			return true
		await process_frame
	return done.call()

func _run() -> void:
	var server := OkServer.new()
	root.add_child(server)
	check(server.listener.listen(0, "127.0.0.1") == OK, "test server listens")
	var url := "http://127.0.0.1:%d" % server.listener.get_local_port()
	Engine.time_scale = 2.0  # the shipped game speed

	# Health with a v3 config: a 1.2 s stall right after the request is sent
	# exceeds the 0.5 s tick timeout but not the control-plane timeout.
	# Loaded at run time: these scripts use the GameSession autoload.
	var config = load("res://scripts/ai_gateway/ai_config.gd").new()
	config.service_url = url
	config.use_local_embedded = false
	config.protocol = "v2_chat"
	config.multi_agent_enabled = true
	config.fast_timeout_sec = 0.5
	config.finalize_urls()
	check(config.uses_multi_agent_protocol(), "config uses the v3 fast-tick timeout")
	var client: Node = load("res://scripts/ai_gateway/http_ai_client.gd").new()
	root.add_child(client)
	client.configure(config)
	var result := {}
	var probe := func() -> void: result["health"] = await client.get_health()
	probe.call()
	OS.delay_msec(1200)
	await _wait(5.0, func() -> bool: return result.has("health"))
	check(result.get("health", {}).get("ok") == true, "health survives a long frame after sending: %s" % result.get("health", {}))
	client.queue_free()

	# Single-player match with the external opponent AI and a slow load.
	var session := root.get_node("GameSession")
	session.online_active = false
	session.match_ai_mode = "gateway"
	session.ai_service_url = url
	session.ai_chat_url = ""
	session.ai_service_token = ""
	session.ai_team_service_urls = {0: "", 1: ""}
	session.ai_team_service_tokens = {0: "", 1: ""}
	session.ai_use_local_embedded = false
	session.ai_protocol = "v2_chat"
	session.ai_multi_agent_enabled = true
	session.ai_fast_timeout_sec = 0.5
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	# A slower machine: loading takes longer than the tick timeout, and that
	# frame's time lands in the delta the request timeout counts.
	OS.delay_msec(1500)
	await _wait(5.0, func() -> bool: return world.get_node_or_null("AiGateway") != null)
	var gateway: Node = world.get_node_or_null("AiGateway")
	check(gateway != null, "external opponent AI uses the gateway")
	if gateway != null:
		var online := await _wait(10.0, func() -> bool: return gateway.service_status == "online")
		check(online, "opponent AI connects after a slow load (status=%s, error=%s)" % [gateway.service_status, gateway._http_client.last_error])
		check(server.paths.has("/health") and server.paths.has("/v1/ai/match/start"), "health and match start reached the service: %s" % [server.paths])
	world.queue_free()
	await process_frame
	server.stop()
	Engine.time_scale = 1.0
	print("AI GATEWAY STARTUP: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
