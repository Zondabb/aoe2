class_name AiEventBuffer
extends RefCounted

## 增量事件缓冲。Gateway 用独立订阅游标，兼容旧调用者的 drain。

const MAX_BUFFERED_EVENTS := 2048

static var _events: Array[Dictionary] = []
static var _subscriber_events: Array[Dictionary] = []
static var _subscribers: Dictionary = {}
static var _next_subscriber := 0
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
	var result: Array = []
	for event in events:
		# Untagged events from initialization cannot disclose enemy data.
		# Explicitly addressed command feedback stays private without fog too.
		if (fog_enabled or event.has("_visible_to")) and team not in event.get("_visible_to", []):
			continue
		var copy: Dictionary = event.duplicate(true)
		copy.erase("_visible_to")
		# A visible spawn is public art, not access to an enemy's private orders.
		if copy.get("entity") is Dictionary:
			var snapshot: Dictionary = copy.entity
			if int(snapshot.get("team", team)) != team:
				for key in ["train_queue_empty", "train_queue", "train_queue_ids", "train_progress", "trainable", "train_blocked_reasons", "is_researching", "technologies", "age_upgrade_reason", "production", "production_status", "research", "move_goal", "movement", "gather_state", "gather_resource_type", "target_id", "last_resource_id", "ai_command_lineage", "order_status"]:
					snapshot.erase(key)
		result.append(copy)
	return result


static func push(event: Dictionary) -> void:
	var copy := event.duplicate(true)
	_seq += 1
	copy["seq"] = _seq
	_events.append(copy)
	if _events.size() > MAX_BUFFERED_EVENTS:
		_events.pop_front()
	if not _subscribers.is_empty():
		_subscriber_events.append(copy)
		if _subscriber_events.size() > MAX_BUFFERED_EVENTS:
			_subscriber_events.pop_front()


## New consumers start at the current event sequence, not an earlier match.
static func subscribe() -> int:
	_next_subscriber += 1
	_subscribers[_next_subscriber] = _seq
	return _next_subscriber


static func unsubscribe(subscriber: int) -> void:
	_subscribers.erase(subscriber)
	_prune_subscriber_events()


static func read(subscriber: int) -> Array:
	# Legacy destructive consumer. HTTP gateways use peek + acknowledge instead.
	var delivery := peek(subscriber)
	acknowledge(subscriber, int(delivery.get("to_seq", 0)))
	return delivery.get("events", [])


static func peek(subscriber: int) -> Dictionary:
	if not _subscribers.has(subscriber):
		return {"events": [], "from_seq": 0, "to_seq": 0, "gap": false, "resync_required": false}
	var cursor := int(_subscribers[subscriber])
	var result: Array = []
	var oldest := int(_subscriber_events[0]["seq"]) if not _subscriber_events.is_empty() else _seq + 1
	for event in _subscriber_events:
		if int(event["seq"]) > cursor:
			result.append(event.duplicate(true))
	var gap := cursor + 1 < oldest
	return {"events": result, "from_seq": cursor + 1, "to_seq": _seq, "oldest_available_seq": oldest, "gap": gap, "resync_required": gap}


static func acknowledge(subscriber: int, through_seq: int) -> void:
	if not _subscribers.has(subscriber):
		return
	# A response can only acknowledge its snapshot, never events published while
	# HTTP was in flight. Old/retried responses cannot move a cursor backwards.
	_subscribers[subscriber] = maxi(int(_subscribers[subscriber]), mini(through_seq, _seq))
	_prune_subscriber_events()


static func _prune_subscriber_events() -> void:
	if _subscribers.is_empty():
		_subscriber_events.clear()
		return
	var oldest_cursor := _seq
	for cursor in _subscribers.values():
		oldest_cursor = mini(oldest_cursor, int(cursor))
	while not _subscriber_events.is_empty() and int(_subscriber_events[0]["seq"]) <= oldest_cursor:
		_subscriber_events.pop_front()


static func drain() -> Array:
	var snapshot: Array = []
	snapshot.assign(_events)
	_events.clear()
	return snapshot


static func peek_count() -> int:
	return _events.size()


static func clear() -> void:
	_events.clear()
	_subscriber_events.clear()
	_seq = 0
	# Explicit global reset keeps live subscribers usable after loading a match.
	for subscriber in _subscribers:
		_subscribers[subscriber] = 0
