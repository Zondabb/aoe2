#pragma once
// Native counterpart of scripts/systems/unit_field.gd: the integer movement
// snapshot of every unit plus scheduled steering (LocalAvoidance
// .steer_with_field). Same update API and identical results for water-free
// inputs; iteration order never affects results.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include <unordered_map>
#include <vector>

#include "avoidance.h"

namespace godot {

class AoeUnitField : public RefCounted {
	GDCLASS(AoeUnitField, RefCounted)

	struct Unit {
		int64_t x = 0, y = 0, radius = 0, vx = 0, vy = 0;
		bool alive = false;
		int64_t cell_x = 0, cell_y = 0;
		int64_t speed = 0; // isqrt(vx^2 + vy^2), as in UnitFieldScript
	};

	std::unordered_map<int64_t, Unit> units;
	std::unordered_map<int64_t, std::vector<int64_t>> buckets;
	int64_t max_radius = 0;
	int64_t max_speed = 0;

	// Scratch buffers reused across calls.
	std::vector<aoe::Body> scratch_bodies;
	std::vector<aoe::Box> scratch_boxes;
	std::vector<int> scratch_near;

	static int64_t cell_key(int64_t cx, int64_t cy);
	void bucket_add(int64_t cx, int64_t cy, int64_t key);
	void bucket_remove(int64_t cx, int64_t cy, int64_t key);
	void gather_into(int64_t self_key, const aoe::V2 &from, int64_t radius, int64_t speed, int64_t horizon, std::vector<aoe::Body> &out) const;

protected:
	static void _bind_methods();

public:
	bool is_native() const { return true; }
	void clear();
	int64_t size() const;
	bool has_unit(int64_t key) const;
	void set_unit(int64_t key, const Vector2i &position, int64_t radius, const Vector2i &velocity, bool alive);
	void remove(int64_t key);
	PackedInt64Array gather(int64_t self_key, const Vector2i &from, int64_t radius, int64_t speed, int64_t horizon) const;
	Vector2i steer(int64_t self_key, const PackedInt64Array &motion, const PackedInt64Array &boxes, const PackedInt64Array &bounds, Dictionary cache);
};

} // namespace godot
