extends RefCounted

## Explicit fog_enabled=false keeps legacy fixtures/sandboxes usable.
static func for_node(node: Object) -> Object:
	if not is_instance_valid(node):
		return null
	var state: Variant = node.get("match_state")
	if state != null and state.get("fog_enabled") == true:
		return state.get("fog")
	var parent := node as Node
	while parent != null:
		if parent.has_meta("fog"):
			return parent.get_meta("fog")
		parent = parent.get_parent()
	return null

static func can_see(observer: Object, target: Object) -> bool:
	if not is_instance_valid(target):
		return false
	var state: Variant = observer.get("match_state")
	var team: int = observer.get("team")
	return state_can_see(state, team, target)

static func state_can_see(state: Object, team: int, target: Object) -> bool:
	if not is_instance_valid(target):
		return false
	if state == null or state.get("fog_enabled") != true:
		return true
	var fog: Object = state.get("fog")
	return fog != null and fog.can_see(team, target)

static func view_can_see(node: Node) -> bool:
	var parent: Node = node
	while parent != null:
		if parent.has_meta("fog_holder"):
			return parent.get_meta("fog_holder").view_can_see(node)
		parent = parent.get_parent()
	return true

static func local_read_only(node: Node) -> bool:
	var parent: Node = node
	while parent != null:
		if parent.has_meta("fog_holder"):
			return parent.get_meta("fog_holder").debug_mode
		parent = parent.get_parent()
	return false
