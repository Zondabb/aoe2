extends "res://scripts/network/network_session.gd"
## Test-only timing wrapper; all actual transport logic runs in the base class.
var probe_snapshots := 0
var probe_send_usec := 0
var probe_send_max_usec := 0
var probe_snapshot_bytes := 0
var probe_sent_bytes := 0
var probe_first_usec := 0
var probe_last_usec := 0
var probe_encode_usec := 0
var probe_failure := ""
var probe_close_code := 0
var probe_close_reason := ""
var probe_server_error := ""

func _handle_message(message: Dictionary) -> void:
	if message.get("type") == "error": probe_server_error = String(message.get("code", ""))
	super._handle_message(message)

func _fail(message: String) -> void:
	probe_failure = message
	if _peer != null:
		probe_close_code = _peer.get_close_code()
		probe_close_reason = _peer.get_close_reason()
	super._fail(message)

func _send(message: Dictionary) -> bool:
	var start := Time.get_ticks_usec()
	var result := super._send(message)
	if message.get("type") == "snapshot":
		var elapsed := Time.get_ticks_usec() - start
		if probe_first_usec == 0: probe_first_usec = start
		probe_last_usec = start
		probe_snapshots += 1
		probe_send_usec += elapsed
		probe_send_max_usec = maxi(probe_send_max_usec, elapsed)
		if probe_snapshot_bytes == 0 or probe_snapshots % 100 == 0:
			var encode_start := Time.get_ticks_usec()
			probe_snapshot_bytes = JSON.stringify(message).to_utf8_buffer().size()
			probe_encode_usec += Time.get_ticks_usec() - encode_start
		probe_sent_bytes += probe_snapshot_bytes
	return result

func probe_report() -> Dictionary:
	var seconds := maxf(0.000001, float(probe_last_usec - probe_first_usec) / 1000000.0)
	return {"snapshot_count": probe_snapshots, "snapshot_bytes": probe_snapshot_bytes,
		"snapshot_hz": (probe_snapshots - 1) / seconds if probe_snapshots > 1 else 0.0,
		"snapshot_bytes_per_second": probe_sent_bytes / seconds,
		"send_average_ms": float(probe_send_usec) / maxf(1, probe_snapshots) / 1000.0,
		"send_max_ms": probe_send_max_usec / 1000.0,
		"diagnostic_encode_total_ms": probe_encode_usec / 1000.0,
		"transport_failure": probe_failure, "websocket_close_code": probe_close_code,
		"websocket_close_reason": probe_close_reason, "server_error_code": probe_server_error}
