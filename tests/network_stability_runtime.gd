extends "res://scripts/network/network_match.gd"
## Test-only timing wrapper. Return values and payloads are unchanged.
var probe_captures := 0
var probe_capture_usec := 0
var probe_capture_max_usec := 0
var probe_applies := 0
var probe_apply_usec := 0
var probe_apply_max_usec := 0

func capture_snapshot() -> Dictionary:
	var start := Time.get_ticks_usec()
	var result := super.capture_snapshot()
	var elapsed := Time.get_ticks_usec() - start
	probe_captures += 1
	probe_capture_usec += elapsed
	probe_capture_max_usec = maxi(probe_capture_max_usec, elapsed)
	return result

func apply_snapshot(snapshot: Dictionary, sequence: int) -> bool:
	var start := Time.get_ticks_usec()
	var result := super.apply_snapshot(snapshot, sequence)
	var elapsed := Time.get_ticks_usec() - start
	probe_applies += 1
	probe_apply_usec += elapsed
	probe_apply_max_usec = maxi(probe_apply_max_usec, elapsed)
	return result

func probe_report() -> Dictionary:
	return {"captures": probe_captures,
		"capture_average_ms": float(probe_capture_usec) / maxf(1, probe_captures) / 1000.0,
		"capture_max_ms": probe_capture_max_usec / 1000.0,
		"applies": probe_applies,
		"apply_average_ms": float(probe_apply_usec) / maxf(1, probe_applies) / 1000.0,
		"apply_max_ms": probe_apply_max_usec / 1000.0}
