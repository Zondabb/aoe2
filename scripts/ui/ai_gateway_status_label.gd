extends Label

var _gateway: AiGateway


func bind_gateway(gateway: AiGateway) -> void:
	_gateway = gateway
	set_process(_gateway != null)


func _process(_delta: float) -> void:
	if _gateway == null or not is_instance_valid(_gateway):
		text = ""
		set_process(false)
		return
	var latency := _gateway.last_tick_latency_ms
	var latency_text := "--"
	if latency >= 0.0:
		latency_text = "%.0f" % latency
	var status := _gateway.service_status
	var url := _gateway.config.display_url() if _gateway.config != null else ""
	text = "AI %s | %s | tick %s ms" % [status, url, latency_text]
