extends SceneTree
## Pure-data worker bytes, payload snapshots, HTTP ordering and task ownership.
const Protocol := preload("res://scripts/ai_gateway/ai_protocol.gd")
var Client: GDScript
var Config: GDScript
var SlowClient: GDScript

class StringProbe extends Node:
	var main_thread_only := true
	func _to_string() -> String:
		main_thread_only = main_thread_only and OS.get_thread_caller_id() == OS.get_main_thread_id()
		return "main_thread_object"

class LocalServer extends Node:
	var listener := TCPServer.new()
	var peers: Array[Dictionary] = []
	var bodies: Array[String] = []
	var automatic := true
	func _process(_delta: float) -> void:
		while listener.is_connection_available():
			peers.append({"socket": listener.take_connection(), "buffer": "", "received": false})
		for index in peers.size():
			var peer: Dictionary = peers[index]
			var socket: StreamPeerTCP = peer.socket
			socket.poll()
			if socket.get_status() != StreamPeerTCP.STATUS_CONNECTED or peer.received: continue
			if socket.get_available_bytes() > 0: peer.buffer += socket.get_string(socket.get_available_bytes())
			var marker: int = peer.buffer.find("\r\n\r\n")
			if marker < 0: continue
			var length := 0
			for line: String in String(peer.buffer).substr(0, marker).split("\r\n"):
				if line.to_lower().begins_with("content-length:"):
					length = int(line.split(":", true, 1)[1].strip_edges())
			# Network fixtures use ASCII so the UTF-8 byte and character counts
			# agree. Unicode byte equivalence is tested directly below.
			if String(peer.buffer).length() < marker + 4 + length: continue
			peer.received = true
			bodies.append(String(peer.buffer).substr(marker + 4, length))
			if automatic: reply(index, {"request": bodies.size()})
	func reply(index: int, body: Dictionary) -> void:
		var content := JSON.stringify(body)
		var wire := "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [content.to_utf8_buffer().size(), content]
		(peers[index].socket as StreamPeerTCP).put_data(wire.to_utf8_buffer())
		(peers[index].socket as StreamPeerTCP).disconnect_from_host()
	func close() -> void:
		listener.stop()
		for peer in peers: (peer.socket as StreamPeerTCP).disconnect_from_host()

var checks := 0
var failures := 0

func _initialize() -> void: call_deferred("_run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)

func _large_payload(tag: String = "large") -> Dictionary:
	var entities: Array = []
	for index in Client.BACKGROUND_ENTITY_COUNT:
		entities.append({"id": index, "name": "unit_%d" % index, "pos": Vector2(index * 0.25, -index * 0.5), "order": &"MOVE", "hp": 32.0})
	return {"tag": tag, "observation": {"entities": entities}, "events": []}

func _capture_encode(client, payload: Dictionary, result: Dictionary) -> void:
	result.value = await client._encode_payload(payload)
	result.done = true

func _capture_request(client, payload: Dictionary, result: Dictionary) -> void:
	result.value = await client._request_json("POST", client.config.tick_url(), payload)
	result.done = true

func _capture_request_and_restart(client, result: Dictionary, current: Dictionary) -> void:
	result.value = await client._request_json("POST", client.config.tick_url(), _large_payload("old"))
	result.done = true
	# This continuation resumes inside cancel_requests' waiter-wake loop. The
	# new generation must keep its task even while other old waiters unwind.
	_capture_request(client, _large_payload("current"), current)

func _wait_until(predicate: Callable) -> bool:
	var started := Time.get_ticks_msec()
	while not predicate.call() and Time.get_ticks_msec() - started < 3000:
		await process_frame
	return bool(predicate.call())

func _new_client():
	var client = SlowClient.new()
	root.add_child(client)
	client.configure(Config.new())
	return client

func _run() -> void:
	# AiConfig references the GameSession autoload. Load after initialization,
	# matching the existing real-HTTP cancellation regression harness.
	Client = load("res://scripts/ai_gateway/http_ai_client.gd")
	Config = load("res://scripts/ai_gateway/ai_config.gd")
	SlowClient = load("res://tests/fixtures/json_encoding_http_ai_client.gd")
	await _test_bytes_and_snapshot()
	await _test_reference_fallbacks()
	await _test_cycles()
	await _test_cancel_and_exit()
	await _test_http_queue()
	await _test_new_generation()
	check(checks >= 35, "all encoding/lifecycle test sections ran")
	print("HTTP JSON ENCODING: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _test_bytes_and_snapshot() -> void:
	var client = _new_client()
	var small := {"position": Vector2(-1.25, 3.5), &"label": "中文\n\t\"\\", "nil": null, "bool": true, "float": 1.25}
	var encoded: Dictionary = await client._encode_payload(small)
	check(encoded.ok and not encoded.background and encoded.body == JSON.stringify(Protocol.json_safe(small)), "small requests retain exact synchronous bytes")
	var payload := _large_payload()
	payload.unicode = "城墙\n单位\t\"\\"
	payload.values = [Vector2(-0.25, 1.5), Vector3(1, 2, 3), Color(0.1, 0.2, 0.3), Rect2(1, 2, 3, 4)]
	var shared := ["same", {"value": 17}]
	payload.shared_a = shared
	payload.shared_b = shared
	var expected := JSON.stringify(Protocol.json_safe(payload))
	var result := {"done": false}
	_capture_encode(client, payload, result)
	check(not result.done and client._json_task_id >= 0, "large payload starts a worker without blocking for encoding")
	payload.observation.entities[0].name = "changed_after_freeze"
	payload.observation.entities.append({"id": 999})
	shared[1].value = 99
	check(await _wait_until(func(): return result.done), "background encoding completes")
	check(result.value.ok and result.value.background and result.value.body.to_utf8_buffer() == expected.to_utf8_buffer(), "worker bytes match original encoder and survive later nested mutation")
	check(client.jobs.size() == 1 and client.jobs[0].thread_id != OS.get_main_thread_id(), "job executes off the main thread")
	check(client._json_task_id == -1 and client._json_job == null, "completed task is joined and released")
	# Both helper callers freeze before yielding for the single task slot.
	var first := {"done": false}
	var second := {"done": false}
	_capture_encode(client, _large_payload("first"), first)
	var second_payload := _large_payload("second")
	var second_expected := JSON.stringify(Protocol.json_safe(second_payload))
	_capture_encode(client, second_payload, second)
	second_payload.observation.entities[0].hp = 1
	check(await _wait_until(func(): return first.done and second.done), "direct helper callers serialize encoding ownership")
	check(second.value.body == second_expected and client._json_task_id == -1, "queued helper snapshot remains frozen and leaves no task")
	client.free()

func _test_reference_fallbacks() -> void:
	var client = _new_client()
	var probe := StringProbe.new()
	var resource := Resource.new()
	for reference in [probe, resource, PackedByteArray([1, 2, 3]), PackedVector2Array([Vector2.ONE]), Callable(probe, "get_name")]:
		var payload := _large_payload()
		payload.reference = reference
		var expected := JSON.stringify(Protocol.json_safe(payload))
		var encoded: Dictionary = await client._encode_payload(payload)
		check(encoded.ok and not encoded.background and encoded.body == expected, "reference-valued variants retain main-thread fallback and bytes")
	var object_key := _large_payload()
	object_key[probe] = "object_dictionary_key"
	var encoded: Dictionary = await client._encode_payload(object_key)
	check(encoded.ok and not encoded.background and encoded.body == JSON.stringify(Protocol.json_safe(object_key)), "Object dictionary keys never reach the worker")
	check(probe.main_thread_only and client.jobs.is_empty(), "no Node/Resource string conversion runs on a worker")
	probe.free()
	client.free()

func _test_cycles() -> void:
	var client = _new_client()
	var array: Array = []
	array.append(array)
	var encoded: Dictionary = await client._encode_payload({"cycle": array})
	check(not encoded.ok and encoded.reason == "json_payload_cycle", "array cycles are rejected before recursive conversion")
	array.clear()
	var dictionary := {}
	dictionary.self = dictionary
	encoded = await client._encode_payload(dictionary)
	check(not encoded.ok and encoded.reason == "json_payload_cycle", "dictionary cycles are rejected")
	dictionary.clear()
	var deep := {}
	var tail := deep
	for index in Client.MAX_JSON_DEPTH + 2:
		tail.child = {}
		tail = tail.child
	encoded = await client._encode_payload(deep)
	check(not encoded.ok and encoded.reason == "json_payload_too_deep", "excess depth cannot overflow converter or duplication")
	check(client.jobs.is_empty() and client._json_task_id == -1, "invalid graphs create no worker task")
	client.free()

func _test_cancel_and_exit() -> void:
	var client = _new_client()
	var result := {"done": false}
	_capture_encode(client, _large_payload(), result)
	client.cancel_requests()
	check(result.done and result.value.reason == "cancelled", "cancel wakes the existing encoder waiter immediately")
	check(client._json_task_id == -1 and client._json_job == null and client._frame_waiters.is_empty(), "cancel joins the worker and drains frame waiters")
	client.free()
	client = _new_client()
	result = {"done": false}
	_capture_encode(client, _large_payload(), result)
	root.remove_child(client)
	check(result.done and result.value.reason in ["cancelled", "tree_exited"], "tree exit finishes the encoding coroutine before a later frame")
	check(client._json_task_id == -1 and client._frame_waiters.is_empty(), "tree exit joins and releases the task")
	client.free()
	client = _new_client()
	result = {"done": false}
	_capture_encode(client, _large_payload(), result)
	client.free()
	check(result.done and result.value.reason in ["cancelled", "tree_exited"], "free during encoding completes waiters before destroying the Node")
	await process_frame
	await process_frame
	check(result.done, "no cleanup coroutine waits for a freed client")

func _test_http_queue() -> void:
	var server := LocalServer.new()
	root.add_child(server)
	check(server.listener.listen(0, "127.0.0.1") == OK, "HTTP fixture binds a local ephemeral port")
	server.automatic = false
	var client = _new_client()
	client.config.service_url = "http://127.0.0.1:%d" % server.listener.get_local_port()
	var first := {"done": false}
	var second := {"done": false}
	var payload := _large_payload("first")
	_capture_request(client, payload, first)
	check(await _wait_until(func(): return server.bodies.size() == 1), "encoded first request reaches real HTTP")
	_capture_request(client, _large_payload("second"), second)
	check(not second.done and client.jobs.size() == 1, "queued HTTP request waits before encoding and sending")
	server.reply(0, {"tag": "first_response"})
	check(await _wait_until(func(): return server.bodies.size() == 2), "second request starts after first transport completion")
	server.reply(1, {"tag": "second_response"})
	check(await _wait_until(func(): return first.done and second.done), "queued HTTP requests both complete")
	check(first.value.body.tag == "first_response" and second.value.body.tag == "second_response", "each waiter retains its own response")
	check(server.bodies[0] == JSON.stringify(Protocol.json_safe(payload)) and JSON.parse_string(server.bodies[1]).tag == "second", "HTTP wire bytes and queue order match original encoder")
	check(not client._active and client._json_task_id == -1, "HTTP success leaves no active task")
	server.close()
	client.free()
	server.free()

func _test_new_generation() -> void:
	var server := LocalServer.new()
	root.add_child(server)
	check(server.listener.listen(0, "127.0.0.1") == OK, "new-generation fixture binds")
	var client = _new_client()
	client.config.service_url = "http://127.0.0.1:%d" % server.listener.get_local_port()
	var old := {"done": false}
	var queued := {"done": false}
	var current := {"done": false}
	_capture_request_and_restart(client, old, current)
	_capture_request(client, _large_payload("queued_old"), queued)
	client.cancel_requests()
	check(old.done and queued.done and old.value.reason == "cancelled" and queued.value.reason == "cancelled", "cancelling encoding also releases the queued old generation")
	check(client._json_task_id >= 0 and client._active and client._active_generation == client._cancel_generation, "a new request started inside cancellation retains its own active task slot")
	check(await _wait_until(func(): return current.done), "new generation encodes and sends after cancellation")
	check(current.value.ok and server.bodies.size() == 1 and JSON.parse_string(server.bodies[0]).tag == "current", "cancelled generations never send or clear the new request")
	check(client._json_task_id == -1 and client._frame_waiters.is_empty(), "new generation owns and reaps only its own task")
	server.close()
	client.free()
	server.free()
