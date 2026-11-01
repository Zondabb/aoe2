#include "sim_kernel.h"

#include <godot_cpp/core/class_db.hpp>

#include "fixed_math.h"

using namespace godot;

void AoeSimKernel::_bind_methods() {
	ClassDB::bind_static_method("AoeSimKernel", D_METHOD("version"), &AoeSimKernel::version);
	ClassDB::bind_method(D_METHOD("line_clear", "solid", "width", "height", "origin_cell", "size", "start", "offset", "steps"), &AoeSimKernel::line_clear);
}

int64_t AoeSimKernel::version() {
	return 1;
}

bool AoeSimKernel::line_clear(const PackedByteArray &solid, int64_t width, int64_t height, const Vector2i &origin_cell, int64_t size, const Vector2i &start, const Vector2i &offset, int64_t steps) const {
	if (steps <= 0 || size <= 0) {
		return false;
	}
	const uint8_t *cells = solid.ptr();
	const int64_t count = solid.size();
	const int64_t half = steps / 2;
	for (int64_t s = 0; s <= steps; s++) {
		const int64_t product_x = int64_t(offset.x) * s;
		const int64_t product_y = int64_t(offset.y) * s;
		const int64_t px = start.x + (product_x >= 0 ? (product_x + half) / steps : -((half - product_x) / steps));
		const int64_t py = start.y + (product_y >= 0 ? (product_y + half) / steps : -((half - product_y) / steps));
		const int64_t x = aoe::floor_div(px, size) - origin_cell.x;
		const int64_t y = aoe::floor_div(py, size) - origin_cell.y;
		if (x < 0 || y < 0 || x >= width || y >= height) {
			return false;
		}
		const int64_t index = y * width + x;
		if (index >= count || cells[index] != 0) {
			return false;
		}
	}
	return true;
}
