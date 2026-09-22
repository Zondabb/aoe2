class_name AiEventBuffer
extends RefCounted

## 增量事件缓冲：实体生命周期、资源枯竭等，每个 AI tick 前 drain 进 HTTP 请求。

static var _events: Array[Dictionary] = []
static var _seq := 0

## Visibility is captured when the event occurs, not when HTTP drains later.
static func push_for_entity(event: Dictionary, entity: Node) -> void:
	var access := preload("res://scripts/systems/fog_access.gd")
	var fog := access.for_node(entity)
	var state: Variant = entity.get("match_state")
	if fog != null or (state != null and state.get("fog_enabled") == true):
		var allowed: Array = []
		for team in Enums.Team.values():
			if entity.get("team") == team or (fog != null and fog.can_see(team, entity)):
				allowed.append(team)
		event = event.duplicate(true)
		event["_visible_to"] = allowed
	push(event)

static func for_team(events: Array, team: int, fog_enabled: bool) -> Array:
	if not fog_enabled:
		return events
	var result: Array = []
	for event in events:
		# Untagged events from initialization cannot disclose enemy data.
		if team not in event.get("_visible_to", []):
			continue
		var copy: Dictionary = event.duplicate(true)
		copy.erase("_visible_to")
		result.append(copy)
	return result


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
