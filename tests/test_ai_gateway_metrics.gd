extends RefCounted

const AiGatewayMetricsScript := preload("res://scripts/ai_gateway/ai_gateway_metrics.gd")


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_histogram_and_skip(failures)
	return failures


func _test_histogram_and_skip(failures: Array[String]) -> void:
	var metrics := AiGatewayMetricsScript.new()
	metrics.record_tick_success(12.0)
	metrics.record_tick_success(80.0)
	metrics.record_tick_skip("timeout")
	metrics.record_command_reject()

	if metrics.tick_success_count != 2:
		failures.append("metrics should count successful ticks")
	if metrics.timeout_count != 1:
		failures.append("metrics should count timeout skips")
	if metrics.reject_count != 1:
		failures.append("metrics should count command rejects")

	var histogram: Dictionary = metrics.latency_histogram()
	if int(histogram.get("<=25ms", 0)) != 1:
		failures.append("histogram should bucket 12ms tick at <=25ms")
	if int(histogram.get("<=100ms", 0)) != 1:
		failures.append("histogram should bucket 80ms tick at <=100ms")

	var summary: Dictionary = metrics.summary()
	if float(summary.get("avg_latency_ms", -1.0)) < 0.0:
		failures.append("metrics summary should include avg latency")
