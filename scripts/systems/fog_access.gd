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

## Variant permits stale cached references to reach the validity guard.
static func can_see(observer: Object, target: Variant) -> bool:
	if not is_instance_valid(target):
		return false
	var state: Variant = observer.get("match_state")
	var team: int = observer.get("team")
	return state_can_see(state, team, target)

static func state_can_see(state: Object, team: int, target: Variant) -> bool:
	if not is_instance_valid(target):
		return false
	if state == null or state.get("fog_enabled") != true:
		return true
	var fog: Object = state.get("fog")
	return fog != null and fog.can_see(team, target)


## Resolve once per synchronous observation. An unrelated world or replacement
## fog mask must never lend its cached visibility to this team's observation.
static func holder_for_snapshot(state: MatchState, entities: Node2D) -> Node:
	if state == null or not state.fog_enabled or state.fog == null or entities == null:
		return null
	var parent := entities.get_parent()
	if parent == null or not parent.has_meta("fog_holder"): return null
	var holder: Variant = parent.get_meta("fog_holder")
	if not is_instance_valid(holder) or not holder is Node or not holder.has_method("entity_visible_for"):
		return null
	return holder if holder.get("fog") == state.fog and holder.get("entities") == entities else null


static func snapshot_can_see(state: MatchState, team: int, target: Node2D, holder: Node) -> bool:
	if holder != null:
		# These footprints are exactly FogOfWarService.footprint_of's runtime
		# cases. Changed geometry and revisions fall back inside the holder.
		if target is ResourceNode:
			return holder.entity_visible_for(team, target, target.sim_pos, target.block_size)
		if target is BuildingAgent and target.def != null:
			return holder.entity_visible_for(team, target, target.sim_pos, target.def.footprint)
	return state_can_see(state, team, target)

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
		if parent.get_meta("spectator", false):
			return true
		if parent.has_meta("fog_holder"):
			return parent.get_meta("fog_holder").debug_mode
		parent = parent.get_parent()
	return false
