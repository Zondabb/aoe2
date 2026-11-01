#include "sim_kernel.h"

#include <godot_cpp/core/class_db.hpp>

#include "fixed_math.h"

#include <cstring>
#include <vector>

using namespace godot;

void AoeSimKernel::_bind_methods() {
	ClassDB::bind_static_method("AoeSimKernel", D_METHOD("version"), &AoeSimKernel::version);
	ClassDB::bind_method(D_METHOD("line_clear", "solid", "width", "height", "origin_cell", "size", "start", "offset", "steps"), &AoeSimKernel::line_clear);
	ClassDB::bind_method(D_METHOD("fog_stamp", "mask", "row_min", "row_max", "sources", "origin", "size", "width", "height"), &AoeSimKernel::fog_stamp);
	ClassDB::bind_method(D_METHOD("fog_explore", "explored", "visible"), &AoeSimKernel::fog_explore);
	ClassDB::bind_method(D_METHOD("fog_rects_seen", "rects", "visible0", "visible1", "width", "height"), &AoeSimKernel::fog_rects_seen);
	ClassDB::bind_method(D_METHOD("nav_layer_border", "width", "height", "left", "top", "right", "bottom"), &AoeSimKernel::nav_layer_border);
	ClassDB::bind_method(D_METHOD("nav_mark_rects", "layer", "indices", "rects", "width", "height", "origin_cell"), &AoeSimKernel::nav_mark_rects);
}

int64_t AoeSimKernel::version() {
	return 4;
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

PackedByteArray AoeSimKernel::fog_rects_seen(const PackedInt32Array &rects, const PackedByteArray &visible0, const PackedByteArray &visible1, int64_t width, int64_t height) const {
	const int64_t count = rects.size() / 4;
	PackedByteArray result;
	result.resize(count);
	uint8_t *out = result.ptrw();
	const int32_t *values = rects.ptr();
	const uint8_t *masks[2] = { visible0.ptr(), visible1.ptr() };
	const int64_t sizes[2] = { visible0.size(), visible1.size() };
	const int64_t cells = width * height;
	for (int64_t i = 0; i < count; i++) {
		const int64_t x0 = values[i * 4];
		const int64_t y0 = values[i * 4 + 1];
		const int64_t w = values[i * 4 + 2];
		const int64_t h = values[i * 4 + 3];
		uint8_t bits = 0;
		if (x0 >= 0 && y0 >= 0 && w > 0 && h > 0 && x0 + w <= width && y0 + h <= height) {
			for (int team = 0; team < 2; team++) {
				if (sizes[team] < cells) {
					continue;
				}
				const uint8_t *mask = masks[team];
				bool seen = false;
				for (int64_t y = y0; y < y0 + h && !seen; y++) {
					const uint8_t *row = mask + y * width;
					for (int64_t x = x0; x < x0 + w; x++) {
						if (row[x] != 0) {
							seen = true;
							break;
						}
					}
				}
				if (seen) {
					bits |= uint8_t(1 << team);
				}
			}
		}
		out[i] = bits;
	}
	return result;
}

Array AoeSimKernel::nav_layer_border(int64_t width, int64_t height, int64_t left, int64_t top, int64_t right, int64_t bottom) const {
	PackedByteArray layer;
	PackedInt32Array indices;
	Array result;
	if (width <= 0 || height <= 0) {
		result.append(layer);
		result.append(indices);
		return result;
	}
	layer.resize(width * height);
	layer.fill(0);
	uint8_t *cells = layer.ptrw();
	std::vector<int32_t> marked;
	auto mark = [&](int64_t index) {
		if (cells[index] == 0) {
			cells[index] = 1;
			marked.push_back(int32_t(index));
		}
	};
	for (int64_t y = 0; y < height; y++) {
		if (y < top || y >= bottom) {
			for (int64_t x = 0; x < width; x++) {
				mark(y * width + x);
			}
		} else {
			for (int64_t x = 0; x < left; x++) {
				mark(y * width + x);
			}
			for (int64_t x = right; x < width; x++) {
				mark(y * width + x);
			}
		}
	}
	indices.resize(int64_t(marked.size()));
	if (!marked.empty()) {
		std::memcpy(indices.ptrw(), marked.data(), marked.size() * sizeof(int32_t));
	}
	result.append(layer);
	result.append(indices);
	return result;
}

Array AoeSimKernel::nav_mark_rects(const PackedByteArray &layer, const PackedInt32Array &indices, const PackedInt32Array &rects, int64_t width, int64_t height, const Vector2i &origin_cell) const {
	PackedByteArray out_layer = layer;
	Array result;
	if (width <= 0 || height <= 0 || out_layer.size() < width * height) {
		result.append(out_layer);
		result.append(indices);
		return result;
	}
	uint8_t *cells = out_layer.ptrw();
	std::vector<int32_t> marked(indices.ptr(), indices.ptr() + indices.size());
	const int32_t *values = rects.ptr();
	const int64_t count = rects.size() / 4;
	for (int64_t r = 0; r < count; r++) {
		const int64_t min_x = values[r * 4];
		const int64_t min_y = values[r * 4 + 1];
		const int64_t max_x = values[r * 4 + 2];
		const int64_t max_y = values[r * 4 + 3];
		for (int64_t cy = min_y; cy <= max_y; cy++) {
			const int64_t ly = cy - origin_cell.y;
			if (ly < 0 || ly >= height) {
				continue;
			}
			for (int64_t cx = min_x; cx <= max_x; cx++) {
				const int64_t lx = cx - origin_cell.x;
				if (lx < 0 || lx >= width) {
					continue;
				}
				const int64_t index = ly * width + lx;
				if (cells[index] == 0) {
					cells[index] = 1;
					marked.push_back(int32_t(index));
				}
			}
		}
	}
	PackedInt32Array out_indices;
	out_indices.resize(int64_t(marked.size()));
	if (!marked.empty()) {
		std::memcpy(out_indices.ptrw(), marked.data(), marked.size() * sizeof(int32_t));
	}
	result.append(out_layer);
	result.append(out_indices);
	return result;
}
