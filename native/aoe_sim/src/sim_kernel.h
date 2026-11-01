#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

namespace godot {

// Stateless integer kernels shared by the simulation scripts.
class AoeSimKernel : public RefCounted {
	GDCLASS(AoeSimKernel, RefCounted)

protected:
	static void _bind_methods();

public:
	static int64_t version();
	// NavGridService._line_clear sample loop: true when every sample cell
	// of the segment start + offset * s / steps (s = 0..steps) is walkable.
	bool line_clear(const PackedByteArray &solid, int64_t width, int64_t height, const Vector2i &origin_cell, int64_t size, const Vector2i &start, const Vector2i &offset, int64_t steps) const;
	// FogOfWarService._stamp for every [x, y, radius] triple of `sources`
	// (fixed point), in order. Returns [mask, row_min, row_max].
	Array fog_stamp(const PackedByteArray &mask, const PackedInt32Array &row_min, const PackedInt32Array &row_max, const PackedInt64Array &sources, const Vector2i &origin, int64_t size, int64_t width, int64_t height) const;
	// explored | visible: every nonzero cell of `visible` becomes 255.
	PackedByteArray fog_explore(const PackedByteArray &explored, const PackedByteArray &visible) const;
	// FogOfWarService.rect_visible(team, rect) for both teams and every
	// [x, y, w, h] rect: bit 0 team 0, bit 1 team 1 (any covered cell visible).
	PackedByteArray fog_rects_seen(const PackedInt32Array &rects, const PackedByteArray &visible0, const PackedByteArray &visible1, int64_t width, int64_t height) const;
	// NavGridService._get_or_build_solid_for_radius, map-edge part: a new
	// width x height layer and the indices it marks, in the script's order.
	Array nav_layer_border(int64_t width, int64_t height, int64_t left, int64_t top, int64_t right, int64_t bottom) const;
	// _mark_aabb_on_layer for every [min_x, min_y, max_x, max_y] cell rect in
	// order (cells outside the grid skipped). Returns [layer, indices].
	Array nav_mark_rects(const PackedByteArray &layer, const PackedInt32Array &indices, const PackedInt32Array &rects, int64_t width, int64_t height, const Vector2i &origin_cell) const;
};

} // namespace godot
