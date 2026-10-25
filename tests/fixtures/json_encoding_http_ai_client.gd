extends "res://scripts/ai_gateway/http_ai_client.gd"
## Loaded after autoload initialization by run_http_json_encoding.gd.
class SlowJob extends HttpAiClient.JsonEncodingJob:
	var thread_id := 0
	func encode() -> void:
		thread_id = OS.get_thread_caller_id()
		# Controlled overlap exercises cancellation, not machine-speed timing.
		OS.delay_usec(25000)
		super.encode()

var jobs: Array[SlowJob] = []

func _new_json_job(snapshot: Dictionary) -> HttpAiClient.JsonEncodingJob:
	var job := SlowJob.new()
	job.snapshot = snapshot
	jobs.append(job)
	return job
