#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
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
};

} // namespace godot
