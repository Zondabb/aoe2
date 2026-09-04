class_name AiGatewayMetrics
extends RefCounted

const HISTOGRAM_BUCKETS_MS := [10.0, 25.0, 50.0, 100.0, 250.0, 500.0, 1000.0]

var tick_success_count := 0
var tick_skip_count := 0
var reject_count := 0
var timeout_count := 0
var _latencies_ms: Array[float] = []


func clear() -> void:
	tick_success_count = 0
	tick_skip_count = 0
	reject_count = 0
	timeout_count = 0
	_latencies_ms.clear()


func record_tick_success(latency_ms: float) -> void:
	tick_success_count += 1
	_latencies_ms.append(maxf(0.0, latency_ms))


func record_tick_skip(reason: String = "") -> void:
	tick_skip_count += 1
	if reason == "timeout":
		timeout_count += 1


func record_command_reject() -> void:
	reject_count += 1


func avg_latency_ms() -> float:
	if _latencies_ms.is_empty():
		return -1.0
	var total := 0.0
	for value in _latencies_ms:
		total += value
	return total / float(_latencies_ms.size())


func latency_histogram() -> Dictionary:
	var buckets := {}
	for edge in HISTOGRAM_BUCKETS_MS:
		buckets["<=%.0fms" % edge] = 0
	buckets[">1000ms"] = 0
	for value in _latencies_ms:
		var placed := false
		for edge in HISTOGRAM_BUCKETS_MS:
			if value <= edge:
				buckets["<=%.0fms" % edge] = int(buckets["<=%.0fms" % edge]) + 1
				placed = true
				break
		if not placed:
			buckets[">1000ms"] = int(buckets[">1000ms"]) + 1
	return buckets


func summary() -> Dictionary:
	return {
		"tick_success": tick_success_count,
		"tick_skip": tick_skip_count,
		"reject_count": reject_count,
		"timeout_count": timeout_count,
		"avg_latency_ms": avg_latency_ms(),
		"latency_histogram": latency_histogram(),
	}
