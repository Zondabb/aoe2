#include "sim_kernel.h"

#include <godot_cpp/core/class_db.hpp>

#include "fixed_math.h"

using namespace godot;

void AoeSimKernel::_bind_methods() {
	ClassDB::bind_static_method("AoeSimKernel", D_METHOD("version"), &AoeSimKernel::version);
	ClassDB::bind_method(D_METHOD("line_clear", "solid", "width", "height", "origin_cell", "size", "start", "offset", "steps"), &AoeSimKernel::line_clear);
	ClassDB::bind_method(D_METHOD("fog_stamp", "mask", "row_min", "row_max", "sources", "origin", "size", "width", "height"), &AoeSimKernel::fog_stamp);
	ClassDB::bind_method(D_METHOD("fog_explore", "explored", "visible"), &AoeSimKernel::fog_explore);
}

int64_t AoeSimKernel::version() {
	return 2;
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

Array AoeSimKernel::fog_stamp(const PackedByteArray &mask, const PackedInt32Array &row_min, const PackedInt32Array &row_max, const PackedInt64Array &sources, const Vector2i &origin, int64_t size, int64_t width, int64_t height) const {
	PackedByteArray out_mask = mask;
	PackedInt32Array out_min = row_min;
	PackedInt32Array out_max = row_max;
	Array result;
	if (size <= 0 || width <= 0 || height <= 0 || out_mask.size() < width * height || out_min.size() < height || out_max.size() < height) {
		result.append(out_mask);
		result.append(out_min);
		result.append(out_max);
		return result;
	}
	uint8_t *cells = out_mask.ptrw();
	int32_t *lows = out_min.ptrw();
	int32_t *highs = out_max.ptrw();
	const int64_t *values = sources.ptr();
	const int64_t count = sources.size() / 3;
	const int64_t ox = origin.x;
	const int64_t oy = origin.y;
	for (int64_t source = 0; source < count; source++) {
		const int64_t px = values[source * 3];
		const int64_t py = values[source * 3 + 1];
		const int64_t radius = aoe::max64(0, values[source * 3 + 2]);
		const int64_t y0 = aoe::max64(0, aoe::floor_div(py - radius - oy, size));
		const int64_t y1 = aoe::min64(height - 1, aoe::floor_div(py + radius - oy, size));
		// Doubled lattice: cell centres are exact for odd cell sizes too.
		const int64_t diameter = 2 * radius;
		for (int64_t y = y0; y <= y1; y++) {
			const int64_t dy = 2 * oy + (2 * y + 1) * size - 2 * py;
			const int64_t remaining = diameter * diameter - dy * dy;
			if (remaining < 0) {
				continue;
			}
			const int64_t dx = aoe::isqrt(remaining);
			const int64_t x0 = aoe::max64(0, -aoe::floor_div(-(2 * px - dx - 2 * ox - size), 2 * size));
			const int64_t x1 = aoe::min64(width - 1, aoe::floor_div(2 * px + dx - 2 * ox - size, 2 * size));
			const int64_t lo = lows[y];
			const int64_t hi = highs[y];
			uint8_t *row = cells + y * width;
			if (x0 <= hi + 1 && x1 >= lo - 1) {
				for (int64_t x = x0; x < aoe::min64(lo, x1 + 1); x++) {
					row[x] = 255;
				}
				for (int64_t x = aoe::max64(hi + 1, x0); x <= x1; x++) {
					row[x] = 255;
				}
				lows[y] = int32_t(aoe::min64(x0, lo));
				highs[y] = int32_t(aoe::max64(x1, hi));
			} else {
				for (int64_t x = x0; x <= x1; x++) {
					row[x] = 255;
				}
				if (x1 - x0 > hi - lo) {
					lows[y] = int32_t(x0);
					highs[y] = int32_t(x1);
				}
			}
		}
	}
	result.append(out_mask);
	result.append(out_min);
	result.append(out_max);
	return result;
}

PackedByteArray AoeSimKernel::fog_explore(const PackedByteArray &explored, const PackedByteArray &visible) const {
	PackedByteArray out = explored;
	const int64_t count = aoe::min64(out.size(), visible.size());
	const uint8_t *seen = visible.ptr();
	uint8_t *history = out.ptrw();
	for (int64_t i = 0; i < count; i++) {
		if (seen[i] != 0) {
			history[i] = 255;
		}
	}
	return out;
}
