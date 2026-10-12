extends RefCounted

## A rectangle in simulation space projects to a parallelogram, including
## non-square regions. One water polygon / three cliff polygons per region.
const ISO := preload("res://scripts/presentation/iso_math.gd")
const WATER := "res://assets/terrain/water.png"
const ROCK := "res://assets/terrain/rock.png"
const FACE := "res://assets/terrain/cliff_face.png"
const CLIFF_FOG := preload("res://shaders/terrain_cliff_fog.gdshader")
const CLIFF_HEIGHT := 36.0
const TEXTURE_PIXELS_PER_SIM := 24.0

static func footprint(size: Vector2) -> PackedVector2Array:
	var half := size * 0.5
	return PackedVector2Array([
		ISO.world_to_screen(Vector2(-half.x, -half.y)),
		ISO.world_to_screen(Vector2(half.x, -half.y)),
		ISO.world_to_screen(Vector2(half.x, half.y)),
		ISO.world_to_screen(Vector2(-half.x, half.y)),
	])

static func ground_uv(size: Vector2, sim_pos: Vector2) -> PackedVector2Array:
	# World-anchored UVs make overlapping / adjacent water patches continuous.
	var half := size * 0.5
	return PackedVector2Array([
		(sim_pos + Vector2(-half.x, -half.y)) * TEXTURE_PIXELS_PER_SIM,
		(sim_pos + Vector2(half.x, -half.y)) * TEXTURE_PIXELS_PER_SIM,
		(sim_pos + Vector2(half.x, half.y)) * TEXTURE_PIXELS_PER_SIM,
		(sim_pos + Vector2(-half.x, half.y)) * TEXTURE_PIXELS_PER_SIM,
	])

static func _polygon(actor: Node2D, label: String, vertices: PackedVector2Array, uv: PackedVector2Array, texture_path: String, color: Color = Color.WHITE) -> Polygon2D:
	var result := Polygon2D.new()
	result.name = label
	result.polygon = vertices
	result.uv = uv
	if ResourceLoader.exists(texture_path):
		result.texture = load(texture_path) as Texture2D
	result.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	result.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	result.color = color
	actor.add_child(result)
	return result

## Called by the match-local fog holder before snapshots and after view changes.
## Memory duplicates keep the same ImageTexture object, which updates in place.
## Only this shader is touched; generic blockers and other actors are safe.
static func bind_fog(actor: Node2D, holder: Node) -> void:
	if not is_instance_valid(actor) or not is_instance_valid(holder):
		return
	var texture := holder.get("_texture") as Texture2D
	var fog: Variant = holder.get("fog")
	var enabled: bool = texture != null and fog != null and holder.get("view_team") != -1
	for child in actor.get_children():
		if child is not Polygon2D or child.material is not ShaderMaterial:
			continue
		var material := child.material as ShaderMaterial
		if material.shader != CLIFF_FOG:
			continue
		var values := {"fog_enabled":enabled, "is_memory":actor.has_meta("fog_memory"), "screen_origin":actor.position}
		if texture != null:
			values["fog_mask"] = texture
		if fog != null:
			values["logical_min"] = fog.map_origin
			values["logical_span"] = fog.map_end - fog.map_origin
		for key in values:
			if material.get_shader_parameter(key) != values[key]:
				material.set_shader_parameter(key, values[key])

static func populate(actor: Node2D, kind: StringName, size: Vector2, sim_pos: Vector2) -> void:
	var base := footprint(size)
	var uv := ground_uv(size, sim_pos)
	if kind == &"water":
		actor.z_index = 0
		var surface := _polygon(actor, "Billboard", base, uv, WATER)
		surface.z_index = -99
		return
	actor.z_index = 0
	# The front faces end exactly at the blocked ground rectangle. Height is a
	# visual lift only; it does not enlarge navigation or selection footprints.
	var lift := Vector2(0.0, -CLIFF_HEIGHT)
	var top := PackedVector2Array()
	for vertex in base: top.append(vertex + lift)
	var plateau := _polygon(actor, "Billboard", top, uv, ROCK)
	plateau.z_index = -99
	var wall_color := Color(0.86, 0.86, 0.82)
	for edge in 2:
		var from_index: int = edge + 1
		var to_index: int = edge + 2
		var length: float = base[from_index].distance_to(base[to_index])
		var wall := PackedVector2Array([top[from_index], top[to_index], base[to_index], base[from_index]])
		var wall_uv := PackedVector2Array([Vector2.ZERO, Vector2(length / 1.2, 0.0), Vector2(length / 1.2, 40.0), Vector2(0.0, 40.0)])
		var face := _polygon(actor, "Body" if edge == 0 else "Fallback", wall, wall_uv, FACE, wall_color if edge == 0 else Color(0.66, 0.66, 0.62))
		var material := ShaderMaterial.new()
		material.shader = CLIFF_FOG
		material.set_shader_parameter("screen_origin", actor.position)
		face.material = material
