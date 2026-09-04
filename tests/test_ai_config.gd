extends RefCounted

const AiConfigScript := preload("res://scripts/ai_gateway/ai_config.gd")


func run() -> Array[String]:
	var failures: Array[String] = []
	_test_empty_url_defaults_to_embedded(failures)
	_test_external_only_requires_probe(failures)
	return failures


func _test_empty_url_defaults_to_embedded(failures: Array[String]) -> void:
	GameSession.ai_service_url = ""
	GameSession.ai_use_local_embedded = true
	var config := AiConfigScript.from_civ_select("", true)
	if config.service_url != AiConfigScript.default_service_url():
		failures.append("empty civ_select URL should resolve to default service URL")
	if not config.use_local_embedded:
		failures.append("empty civ_select URL should keep embedded enabled")


func _test_external_only_requires_probe(failures: Array[String]) -> void:
	var config := AiConfigScript.from_civ_select("http://127.0.0.1:9999", false)
	if not config.requires_external_only_probe():
		failures.append("custom URL without embedded should require external probe")
	if config.allows_embedded_fallback():
		failures.append("external-only config should not allow embedded fallback")
