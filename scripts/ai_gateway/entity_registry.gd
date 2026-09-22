class_name EntityRegistry
extends RefCounted

const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const AiEventBufferScript := preload("res://scripts/ai_gateway/event_buffer.gd")
const ObservationBuilderScript := preload("res://scripts/ai_gateway/observation_builder.gd")

static var _next_id := 1
static var _id_to_entity: Dictionary = {}
static var _entity_to_id: Dictionary = {}


static func register(entity: Node2D) -> int:
	if entity == null or not is_instance_valid(entity):
		return -1
	var instance_id := entity.get_instance_id()
	if _entity_to_id.has(instance_id):
		return int(_entity_to_id[instance_id])
	var entity_id := _next_id
	_next_id += 1
	entity.set_meta(AiProtocolScript.META_ENTITY_ID, entity_id)
	_id_to_entity[entity_id] = entity
	_entity_to_id[instance_id] = entity_id
	AiEventBufferScript.push_for_entity({
		"type": AiProtocolScript.EVENT_ENTITY_SPAWNED,
		"entity": ObservationBuilderScript.serialize_entity(entity, entity_id),
	}, entity)
	return entity_id


static func unregister(entity: Node2D, reason: String = "removed") -> void:
	if entity == null:
		return
	var entity_id := id_of(entity)
	if entity_id < 0:
		return
	_id_to_entity.erase(entity_id)
	_entity_to_id.erase(entity.get_instance_id())
	if entity.has_meta(AiProtocolScript.META_ENTITY_ID):
		entity.remove_meta(AiProtocolScript.META_ENTITY_ID)
	AiEventBufferScript.push_for_entity({
		"type": AiProtocolScript.EVENT_ENTITY_DESTROYED,
		"entity_id": entity_id,
		"reason": reason,
	}, entity)


static func resolve(entity_id: int) -> Node2D:
	if entity_id < 0:
		return null
	var entity: Variant = _id_to_entity.get(entity_id)
	if entity == null or not is_instance_valid(entity):
		_id_to_entity.erase(entity_id)
		return null
	return entity as Node2D


static func id_of(entity: Node2D) -> int:
	if entity == null or not is_instance_valid(entity):
		return -1
	if entity.has_meta(AiProtocolScript.META_ENTITY_ID):
		return int(entity.get_meta(AiProtocolScript.META_ENTITY_ID))
	var instance_id := entity.get_instance_id()
	if _entity_to_id.has(instance_id):
		return int(_entity_to_id[instance_id])
	return -1


static func clear() -> void:
	_next_id = 1
	_id_to_entity.clear()
	_entity_to_id.clear()
