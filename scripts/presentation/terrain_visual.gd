extends RefCounted

## Authored terrain bounds project to a parallelogram. Water's actual outline
## comes from shared shoreline contours, while cliffs retain their rectangle.
const ISO := preload("res://scripts/presentation/iso_math.gd")
const GRASS := "res://assets/terrain/grass.png"
const WATER := "res://assets/terrain/water.png"
const BEACH := "res://assets/terrain/beach.png"
const SHALLOW := "res://assets/terrain/shallow.png"
const ROCK := "res://assets/terrain/rock.png"
const FACE := "res://assets/terrain/cliff_face.png"
const CLIFF_FOG := preload("res://shaders/terrain_cliff_fog.gdshader")
const WATER_SHADER := preload("res://shaders/terrain_water.gdshader")
const MAX_COAST_EDGES := 192
const CLIFF_HEIGHT := 36.0
const TEXTURE_PIXELS_PER_SIM := 24.0
## Original 512px grass texture: approximately 20 texels per sim unit keeps
## grass detail near the original 96x48 terrain / 1.2x sprite pixel ratio.
const GRASS_TEXTURE_PIXELS_PER_SIM := 20.0

static func setup_grass(parent: Node2D, bounds: Rect2) -> Polygon2D:
	for child in parent.get_children():
		child.free()
	var vertices := PackedVector2Array()
	var uv := PackedVector2Array()
	for point in [bounds.position, Vector2(bounds.end.x, bounds.position.y), bounds.end, Vector2(bounds.position.x, bounds.end.y)]:
		vertices.append(ISO.world_to_screen(point))
		# Explicit world coordinates keep grain density, direction and phase
		# identical across map sizes, editor previews and adjacent surfaces.
		uv.append(point * GRASS_TEXTURE_PIXELS_PER_SIM)
	var surface := _polygon(parent, "GrassSurface", vertices, uv, GRASS)
	surface.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	surface.z_index = -100
	return surface

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
## Only terrain shaders are touched; generic blockers and other actors are safe.
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
		if material.shader != CLIFF_FOG and material.shader != WATER_SHADER:
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
		# All original ground textures use the same world-anchored density.
		uv = ground_uv(size, sim_pos)
		for index in uv.size(): uv[index] *= GRASS_TEXTURE_PIXELS_PER_SIM / TEXTURE_PIXELS_PER_SIM
		var surface := _polygon(actor, "Billboard", base, uv, WATER)
		surface.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		var material := ShaderMaterial.new()
		material.shader = WATER_SHADER
		material.set_shader_parameter("screen_origin", actor.position)
		material.set_shader_parameter("sand_texture", load(BEACH))
		material.set_shader_parameter("shallow_texture", load(SHALLOW))
		material.set_shader_parameter("grass_texture", load(GRASS))
		var points := PackedVector2Array()
		var ends := PackedVector2Array()
		var contours: Array = actor.get_water_contours() if actor.has_method("get_water_contours") else []
		var coast_bounds := Rect2()
		var first_point := true
		for contour: PackedVector2Array in contours:
			for index in contour.size():
				points.append(contour[index])
				ends.append(contour[(index + 1) % contour.size()])
				coast_bounds = Rect2(contour[index], Vector2.ZERO) if first_point else coast_bounds.expand(contour[index])
				first_point = false
		assert(points.size() <= MAX_COAST_EDGES, "Shoreline exceeds shader edge budget")
		material.set_shader_parameter("coast_count", points.size())
		# Upload full uniform arrays; unused slots remain zero and are not read.
		points.resize(MAX_COAST_EDGES)
		ends.resize(MAX_COAST_EDGES)
		material.set_shader_parameter("coast_points", points)
		material.set_shader_parameter("coast_ends", ends)
		material.set_shader_parameter("shore_width", minf(2.6, minf(coast_bounds.size.x, coast_bounds.size.y) * 0.24))
		surface.material = material
		# The water shader performs fog per fragment. Draw above the ground fog
		# overlay (-50), so captured 0.4 memories receive the dimming only once.
		surface.z_index = -49
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
