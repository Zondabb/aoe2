class_name AiEventBuffer
extends RefCounted

## 增量事件缓冲：实体生命周期、资源枯竭等，每个 AI tick 前 drain 进 HTTP 请求。

static var _events: Array[Dictionary] = []
static var _seq := 0


static func push(event: Dictionary) -> void:
	var copy := event.duplicate(true)
	_seq += 1
	copy["seq"] = _seq
	_events.append(copy)


static func drain() -> Array:
	var snapshot: Array = []
	snapshot.assign(_events)
	_events.clear()
	return snapshot


static func peek_count() -> int:
	return _events.size()


static func clear() -> void:
	_events.clear()
	_seq = 0
