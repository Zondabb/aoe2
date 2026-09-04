extends RefCounted

const EntityRegistryScript := preload("res://scripts/ai_gateway/entity_registry.gd")
const AiEventBufferScript := preload("res://scripts/ai_gateway/event_buffer.gd")
const AiProtocolScript := preload("res://scripts/ai_gateway/ai_protocol.gd")
const RESOURCE_NODE_SCRIPT := preload("res://scripts/entities/resource_node.gd")


func run() -> Array[String]:
	var failures: Array[String] = []
	EntityRegistryScript.clear()
	AiEventBufferScript.clear()
	_test_register_resolve_meta(failures)
	EntityRegistryScript.clear()
	AiEventBufferScript.clear()
	_test_unregister_and_destroyed_event(failures)
	EntityRegistryScript.clear()
	AiEventBufferScript.clear()
	_test_resource_depleted_event(failures)
	return failures


func _test_register_resolve_meta(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)

	var resource := RESOURCE_NODE_SCRIPT.new()
	resource.resource_type = Enums.ResourceType.FOOD
	resource.sim_pos = Vector2(1.0, 2.0)
	root.add_child(resource)
	if EntityRegistryScript.id_of(resource) < 0:
		EntityRegistryScript.register(resource)

	var entity_id := EntityRegistryScript.id_of(resource)
	if entity_id < 1:
		failures.append("registry should assign positive entity_id")
	if EntityRegistryScript.resolve(entity_id) != resource:
		failures.append("resolve should return registered entity")
	if int(resource.get_meta(AiProtocolScript.META_ENTITY_ID)) != entity_id:
		failures.append("entity meta should store entity_id")

	var again := EntityRegistryScript.register(resource)
	if again != entity_id:
		failures.append("register should be idempotent for same entity")

	root.free()


func _test_unregister_and_destroyed_event(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)

	var resource := RESOURCE_NODE_SCRIPT.new()
	root.add_child(resource)
	if EntityRegistryScript.id_of(resource) < 0:
		EntityRegistryScript.register(resource)
	AiEventBufferScript.clear()

	var entity_id := EntityRegistryScript.id_of(resource)
	EntityRegistryScript.unregister(resource, "test_removed")

	if EntityRegistryScript.resolve(entity_id) != null:
		failures.append("resolve should return null after unregister")
	if resource.has_meta(AiProtocolScript.META_ENTITY_ID):
		failures.append("meta entity_id should be removed after unregister")

	var events := AiEventBufferScript.drain()
	var found_destroyed := false
	for event in events:
		if (
			String(event.get("type")) == String(AiProtocolScript.EVENT_ENTITY_DESTROYED)
			and int(event.get("entity_id")) == entity_id
		):
			found_destroyed = true
	if not found_destroyed:
		failures.append("unregister should push entity_destroyed event")

	root.free()


func _test_resource_depleted_event(failures: Array[String]) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var root := Node2D.new()
	tree.root.add_child(root)

	var resource := RESOURCE_NODE_SCRIPT.new()
	resource.amount = 1.0
	resource.gather_rate = 10.0
	root.add_child(resource)
	if EntityRegistryScript.id_of(resource) < 0:
		EntityRegistryScript.register(resource)
	AiEventBufferScript.clear()

	resource.extract(1.0)
	var events := AiEventBufferScript.drain()
	var found_depleted := false
	for event in events:
		if String(event.get("type")) == String(AiProtocolScript.EVENT_RESOURCE_DEPLETED):
			found_depleted = true
	if not found_depleted:
		failures.append("resource extract to zero should push resource_depleted event")

	root.free()
