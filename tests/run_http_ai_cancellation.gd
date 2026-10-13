extends SceneTree
## Exercise real HTTPRequest waits plus the retry boundary, without paid APIs.

var checks := 0
var failures: Array[String] = []

class HeldServer extends Node:
	var listener := TCPServer.new()
	var peers: Array[Dictionary] = []
	var requests := 0
	func _process(_delta: float) -> void:
		while listener.is_connection_available():
			peers.append({"socket":listener.take_connection(), "buffer":"", "received":false})
		for peer in peers:
			var socket: StreamPeerTCP = peer.socket
			socket.poll()
			if socket.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				continue
			if socket.get_available_bytes() > 0:
				peer.buffer += socket.get_string(socket.get_available_bytes())
			if not peer.received and String(peer.buffer).contains("\r\n\r\n"):
				peer.received = true
				requests += 1
	func reply(index: int, body: Dictionary) -> void:
		var content := JSON.stringify(body)
		var wire := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [content.to_utf8_buffer().size(), content]
		(peers[index].socket as StreamPeerTCP).put_data(wire.to_utf8_buffer())
		(peers[index].socket as StreamPeerTCP).disconnect_from_host()
	func close() -> void:
		listener.stop()
		for peer in peers:
			(peer.socket as StreamPeerTCP).disconnect_from_host()
		peers.clear()

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	for operation in ["post_tick", "post_chat_completions", "post_tick_batch", "post_chat_completions_batch", "get_health"]:
		await _test_real_cancel(operation)
	for operation in ["post_tick", "post_chat_completions", "post_tick_batch", "post_chat_completions_batch"]:
		await _test_retry_cancel(operation)
	await _test_queued_success()
	print("HTTP AI CANCELLATION: cancellation checks completed without request warnings")
	await _test_error_behavior()
	check(checks >= 40, "all HTTP cancellation test sections ran")
	print("HTTP AI CANCELLATION: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _invoke(client, operation: String, captured: Dictionary) -> void:
	if operation == "get_health":
		captured["body"] = await client.get_health()
	else:
		captured["body"] = await client.call(operation, {})
	captured["done"] = true

func _test_real_cancel(operation: String) -> void:
	var server := HeldServer.new()
	root.add_child(server)
	var listen_error := server.listener.listen(0, "127.0.0.1")
	check(listen_error == OK, "%s fixture binds a local ephemeral HTTP port" % operation)
	if listen_error != OK:
		server.free()
		return
	var client = load("res://scripts/ai_gateway/http_ai_client.gd").new()
	root.add_child(client)
	var config = load("res://scripts/ai_gateway/ai_config.gd").new()
	config.use_local_embedded = false
	config.service_url = "http://127.0.0.1:%d" % server.listener.get_local_port()
	config.timeout_sec = 10.0
	client.configure(config)
	var active := {"done":false}
	var queued := {"done":false}
	_invoke(client, operation, active)
	var started := Time.get_ticks_msec()
	while server.requests == 0 and Time.get_ticks_msec() - started < 2000:
		await process_frame
	check(server.requests == 1 and not active.done, "%s request is active on a real held HTTP connection" % operation)
	_invoke(client, operation, queued)
	check(not queued.done and server.requests == 1, "%s second request waits behind the active transport" % operation)
	client.last_error = "current_generation_marker"
	client.cancel_requests()
	await process_frame
	await process_frame
	check(active.done and queued.done, "%s cancellation releases both active and queued coroutines" % operation)
	if active.done and queued.done:
		if operation == "get_health":
			check(active.body.get("reason") == "cancelled" and queued.body.get("reason") == "cancelled", "low-level cancellation has an explicit cancelled result")
		else:
			check(active.body.is_empty() and queued.body.is_empty(), "%s normal cancellation returns empty actions" % operation)
	check(client.last_error == "current_generation_marker", "%s cancelled old requests do not overwrite diagnostic state" % operation)
	# Leave time for any wrongly restarted queued request to reach the server.
	await create_timer(0.05).timeout
	check(server.requests == 1 and not client._active, "%s cancellation never sends the previously queued request" % operation)
	server.close()
	client.free()
	server.free()

func _wait_until(predicate: Callable) -> bool:
	var started := Time.get_ticks_msec()
	while not predicate.call() and Time.get_ticks_msec() - started < 2000:
		await process_frame
	return bool(predicate.call())

func _test_queued_success() -> void:
	var server := HeldServer.new()
	root.add_child(server)
	check(server.listener.listen(0, "127.0.0.1") == OK, "normal queue fixture binds a local HTTP port")
	var client = load("res://tests/fixtures/queued_http_ai_client.gd").new()
	root.add_child(client)
	var config = load("res://scripts/ai_gateway/ai_config.gd").new()
	config.service_url = "http://127.0.0.1:%d" % server.listener.get_local_port()
	config.timeout_sec = 10.0
	client.configure(config)
	var first := {"done":false}
	var second := {"done":false}
	_invoke(client, "post_chat_completions", first)
	check(await _wait_until(func(): return server.requests == 1), "first queued request reaches its real HTTP connection")
	_invoke(client, "post_chat_completions", second)
	server.reply(0, {"completion":"first"})
	check(await _wait_until(func(): return server.requests == 2), "queued second request starts while the first waiter is deliberately held")
	client.release_first.emit()
	check(first.done and first.body.get("completion") == "first" and not second.done, "old waiter reads only its own successful response while the next request is active")
	server.reply(1, {"completion":"second"})
	check(await _wait_until(func(): return second.done), "second queued request completes normally")
	check(second.done and second.body.get("completion") == "second", "queued waiter receives its own response without returning the earlier result")
	server.close()
	client.free()
	server.free()

func _new_retry_client():
	var client = load("res://tests/fixtures/retry_ai_client.gd").new()
	root.add_child(client)
	client.configure(load("res://scripts/ai_gateway/ai_config.gd").new())
	return client

func _test_retry_cancel(operation: String) -> void:
	var client = _new_retry_client()
	client.cancel_in_retry = true
	client.last_error = "retry_generation_marker"
	var captured := {"done":false}
	await _invoke(client, operation, captured)
	check(captured.done and captured.body.is_empty(), "%s retry-window cancellation returns no actions" % operation)
	check(client.attempts == 1, "%s retry-window cancellation prevents another HTTP attempt" % operation)
	check(client.last_error == "retry_generation_marker", "%s retry-window cancellation does not create an error diagnostic" % operation)
	client.free()

func _test_error_behavior() -> void:
	var client = _new_retry_client()
	for reason in ["timeout", "http_408", "http_503", "network_error"]:
		check(client._should_retry({"reason":reason}), "%s still qualifies for one retry" % reason)
	for reason in ["http_400", "http_401", "http_500", "cancelled", "tree_exited"]:
		check(not client._should_retry({"reason":reason}), "%s never retries" % reason)
	var recovered: Dictionary = await client.post_chat_completions({})
	check(client.attempts == 2 and not recovered.is_empty() and client.last_error.is_empty(), "real retry policy still accepts a recovered HTTP request")
	client.free()
	client = _new_retry_client()
	client.replies = [{"ok":false,"reason":"http_401"}]
	var unauthorized: Array = await client.post_tick_batch({})
	check(unauthorized.is_empty() and client.attempts == 1 and client.last_error == "http_401", "authorization errors remain visible and are never retried")
	client.free()
	client = _new_retry_client()
	client.replies = [{"ok":false,"reason":"http_503"}]
	var failed: Dictionary = await client.post_tick({})
	check(failed.is_empty() and client.attempts == 2 and client.last_error == "http_503", "failed network retries retain their real failure diagnostic")
	client.free()
