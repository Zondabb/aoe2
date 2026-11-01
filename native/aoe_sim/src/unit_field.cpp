#include "unit_field.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>

using namespace godot;
using aoe::V2;

namespace {
constexpr int64_t CELL = 2048;
}

void AoeUnitField::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_native"), &AoeUnitField::is_native);
	ClassDB::bind_method(D_METHOD("clear"), &AoeUnitField::clear);
	ClassDB::bind_method(D_METHOD("size"), &AoeUnitField::size);
	ClassDB::bind_method(D_METHOD("has_unit", "key"), &AoeUnitField::has_unit);
	ClassDB::bind_method(D_METHOD("set_unit", "key", "position", "radius", "velocity", "alive"), &AoeUnitField::set_unit);
	ClassDB::bind_method(D_METHOD("remove", "key"), &AoeUnitField::remove);
	ClassDB::bind_method(D_METHOD("gather", "self_key", "from", "radius", "speed", "horizon"), &AoeUnitField::gather);
	ClassDB::bind_method(D_METHOD("steer", "self_key", "motion", "boxes", "bounds", "cache"), &AoeUnitField::steer);
}

int64_t AoeUnitField::cell_key(int64_t cx, int64_t cy) {
	// Unsigned shift: left-shifting a negative value is undefined in C++17.
	return (int64_t)(((uint64_t)cx << 32) ^ ((uint64_t)cy & 0xffffffffULL));
}

void AoeUnitField::bucket_add(int64_t cx, int64_t cy, int64_t key) {
	buckets[cell_key(cx, cy)].push_back(key);
}

void AoeUnitField::bucket_remove(int64_t cx, int64_t cy, int64_t key) {
	auto found = buckets.find(cell_key(cx, cy));
	if (found == buckets.end()) {
		return;
	}
	std::vector<int64_t> &bucket = found->second;
	auto position = std::find(bucket.begin(), bucket.end(), key);
	if (position != bucket.end()) {
		bucket.erase(position);
	}
	if (bucket.empty()) {
		buckets.erase(found);
	}
}

void AoeUnitField::clear() {
	units.clear();
	buckets.clear();
	max_radius = 0;
	max_speed = 0;
}

int64_t AoeUnitField::size() const {
	return (int64_t)units.size();
}

bool AoeUnitField::has_unit(int64_t key) const {
	return units.find(key) != units.end();
}

void AoeUnitField::set_unit(int64_t key, const Vector2i &p_position, int64_t radius, const Vector2i &velocity, bool alive) {
	const V2 position(aoe::clamp64(p_position.x, -aoe::POS_MAX, aoe::POS_MAX), aoe::clamp64(p_position.y, -aoe::POS_MAX, aoe::POS_MAX));
	radius = aoe::clamp64(radius, 0, aoe::RADIUS_MAX);
	const int64_t vx = aoe::clamp64(velocity.x, -aoe::V_MAX, aoe::V_MAX);
	const int64_t vy = aoe::clamp64(velocity.y, -aoe::V_MAX, aoe::V_MAX);
	const int64_t cx = aoe::floor_div(position.x, CELL);
	const int64_t cy = aoe::floor_div(position.y, CELL);
	auto found = units.find(key);
	if (found != units.end()) {
		if (found->second.cell_x != cx || found->second.cell_y != cy) {
			bucket_remove(found->second.cell_x, found->second.cell_y, key);
			bucket_add(cx, cy, key);
		}
	} else {
		bucket_add(cx, cy, key);
	}
	Unit &unit = units[key];
	unit.x = position.x;
	unit.y = position.y;
	unit.radius = radius;
	unit.vx = vx;
	unit.vy = vy;
	unit.alive = alive;
	unit.cell_x = cx;
	unit.cell_y = cy;
	unit.speed = aoe::isqrt(vx * vx + vy * vy);
	max_radius = aoe::max64(max_radius, radius);
	max_speed = aoe::max64(max_speed, unit.speed + 1);
}

void AoeUnitField::remove(int64_t key) {
	auto found = units.find(key);
	if (found == units.end()) {
		return;
	}
	bucket_remove(found->second.cell_x, found->second.cell_y, key);
	units.erase(found);
}

void AoeUnitField::gather_into(int64_t self_key, const V2 &p_from, int64_t radius, int64_t speed, int64_t horizon, std::vector<aoe::Body> &out) const {
	out.clear();
	const V2 from(aoe::clamp64(p_from.x, -aoe::POS_MAX, aoe::POS_MAX), aoe::clamp64(p_from.y, -aoe::POS_MAX, aoe::POS_MAX));
	radius = aoe::clamp64(radius, 0, aoe::RADIUS_MAX);
	speed = aoe::clamp64(speed, 0, 2 * aoe::V_MAX);
	horizon = aoe::clamp64(horizon, 0, 2 * aoe::TIME_SCALE);
	const int64_t bound = radius + max_radius + aoe::MARGIN_Q + aoe::mul_div(speed + max_speed, horizon, aoe::TIME_SCALE) + 1;
	const int64_t low_x = aoe::floor_div(from.x - bound, CELL);
	const int64_t low_y = aoe::floor_div(from.y - bound, CELL);
	const int64_t high_x = aoe::floor_div(from.x + bound, CELL);
	const int64_t high_y = aoe::floor_div(from.y + bound, CELL);
	for (int64_t cy = low_y; cy <= high_y; cy++) {
		for (int64_t cx = low_x; cx <= high_x; cx++) {
			auto bucket = buckets.find(cell_key(cx, cy));
			if (bucket == buckets.end()) {
				continue;
			}
			for (int64_t key : bucket->second) {
				if (key == self_key) {
					continue;
				}
				const Unit &unit = units.at(key);
				if (!unit.alive) {
					continue;
				}
				const int64_t rx = unit.x - from.x;
				const int64_t ry = unit.y - from.y;
				if (rx > bound || rx < -bound || ry > bound || ry < -bound) {
					continue;
				}
				const int64_t combined = radius + unit.radius;
				const int64_t reach = combined + aoe::MARGIN_Q + aoe::mul_div(speed + unit.speed, horizon, aoe::TIME_SCALE);
				if (rx * rx + ry * ry > reach * reach) {
					continue;
				}
				out.push_back(aoe::Body{ rx, ry, unit.vx, unit.vy, combined });
			}
		}
	}
}

PackedInt64Array AoeUnitField::gather(int64_t self_key, const Vector2i &from, int64_t radius, int64_t speed, int64_t horizon) const {
	std::vector<aoe::Body> bodies;
	gather_into(self_key, V2(from.x, from.y), radius, speed, horizon, bodies);
	PackedInt64Array result;
	result.resize((int64_t)bodies.size() * 5);
	int64_t index = 0;
	for (const aoe::Body &body : bodies) {
		result.set(index++, body.rx);
		result.set(index++, body.ry);
		result.set(index++, body.vx);
		result.set(index++, body.vy);
		result.set(index++, body.combined);
	}
	return result;
}

Vector2i AoeUnitField::steer(int64_t self_key, const PackedInt64Array &motion, const PackedInt64Array &boxes, const PackedInt64Array &bounds_record, Dictionary cache) {
	if (motion.size() < 12) {
		return Vector2i();
	}
	const V2 from(aoe::clamp64(motion[0], -aoe::POS_MAX, aoe::POS_MAX), aoe::clamp64(motion[1], -aoe::POS_MAX, aoe::POS_MAX));
	const int64_t radius = aoe::clamp64(motion[2], 0, aoe::RADIUS_MAX);
	const V2 preferred(aoe::clamp64(motion[3], -aoe::V_MAX, aoe::V_MAX), aoe::clamp64(motion[4], -aoe::V_MAX, aoe::V_MAX));
	const V2 previous(aoe::clamp64(motion[5], -aoe::V_MAX, aoe::V_MAX), aoe::clamp64(motion[6], -aoe::V_MAX, aoe::V_MAX));
	const int64_t step_time = aoe::clamp64(motion[7], 0, aoe::STEP_TIME_MAX);
	const V2 goal(aoe::clamp64(motion[8], -aoe::POS_MAX, aoe::POS_MAX), aoe::clamp64(motion[9], -aoe::POS_MAX, aoe::POS_MAX));
	const bool has_goal = motion[10] != 0;
	const int64_t speed_sq = preferred.len_sq();
	if (speed_sq == 0 || step_time <= 0) {
		cache.clear();
		return Vector2i((int32_t)from.x, (int32_t)from.y);
	}
	aoe::Bounds bounds;
	if (bounds_record.size() >= 5 && bounds_record[0] != 0) {
		bounds.enabled = true;
		bounds.min_x = aoe::clamp64(bounds_record[1], -aoe::POS_MAX, aoe::POS_MAX);
		bounds.min_y = aoe::clamp64(bounds_record[2], -aoe::POS_MAX, aoe::POS_MAX);
		bounds.max_x = aoe::clamp64(bounds_record[3], -aoe::POS_MAX, aoe::POS_MAX);
		bounds.max_y = aoe::clamp64(bounds_record[4], -aoe::POS_MAX, aoe::POS_MAX);
	}
	scratch_boxes.clear();
	for (int64_t index = 0; index + 4 < boxes.size(); index += 5) {
		scratch_boxes.push_back(aoe::Box{ aoe::clamp64(boxes[index], -aoe::POS_MAX, aoe::POS_MAX), aoe::clamp64(boxes[index + 1], -aoe::POS_MAX, aoe::POS_MAX),
				aoe::clamp64(boxes[index + 2], -aoe::POS_MAX, aoe::POS_MAX), aoe::clamp64(boxes[index + 3], -aoe::POS_MAX, aoe::POS_MAX) });
	}
	const int64_t speed = aoe::isqrt(speed_sq);
	const int64_t horizon = aoe::max64(aoe::HORIZON_TIME, step_time);
	gather_into(self_key, from, radius, speed, horizon, scratch_bodies);
	aoe::nearby_boxes(from, speed, horizon, scratch_boxes, scratch_near);
	const int64_t static_time = aoe::static_horizon(from, speed, step_time, goal, has_goal);
	const bool initialized = cache.has("vx");
	const int64_t remaining = int64_t(cache.get("rt", 0)) - step_time;
	cache["rt"] = remaining;
	if (initialized && remaining > 0 && int64_t(cache.get("gx", 0)) == goal.x && int64_t(cache.get("gy", 0)) == goal.y && int64_t(cache.get("hg", 0)) == (has_goal ? 1 : 0) && int64_t(cache.get("px", 0)) == from.x && int64_t(cache.get("py", 0)) == from.y) {
		const V2 old(int64_t(cache.get("ux", 0)), int64_t(cache.get("uy", 0)));
		const int64_t old_speed = aoe::isqrt(old.len_sq());
		if (old_speed > 0 && aoe::abs64(old_speed - speed) * 100 <= speed * aoe::REUSE_SPEED_PERCENT && old.dot(preferred) * 1000000 >= aoe::REUSE_DIRECTION_PPM * old_speed * speed) {
			const int64_t direct_risk = aoe::risk(preferred, step_time, scratch_bodies, aoe::RISK_INF);
			const V2 direct_to = from + aoe::motion_for(preferred, step_time);
			if (direct_risk == 0 && aoe::map_ok(direct_to, radius, bounds) && aoe::static_safe(from, from + aoe::motion_for(preferred, static_time), scratch_near, scratch_boxes)) {
				cache["vx"] = preferred.x;
				cache["vy"] = preferred.y;
				cache["ux"] = preferred.x;
				cache["uy"] = preferred.y;
				cache["px"] = direct_to.x;
				cache["py"] = direct_to.y;
				cache["risk"] = (int64_t)0;
				cache["reused"] = int64_t(cache.get("reused", 0)) + 1;
				return Vector2i((int32_t)direct_to.x, (int32_t)direct_to.y);
			}
			V2 velocity(aoe::mul_div(int64_t(cache.get("vx", 0)), speed, old_speed), aoe::mul_div(int64_t(cache.get("vy", 0)), speed, old_speed));
			int64_t velocity_sq = velocity.len_sq();
			if (velocity_sq > speed_sq) {
				const int64_t length = aoe::isqrt(velocity_sq);
				velocity = V2(aoe::mul_div(velocity.x, speed, length), aoe::mul_div(velocity.y, speed, length));
				velocity_sq = velocity.len_sq();
			}
			const V2 to = from + aoe::motion_for(velocity, step_time);
			if (velocity_sq * 100 > speed_sq && aoe::map_ok(to, radius, bounds)) {
				const int64_t retained = aoe::risk(velocity, step_time, scratch_bodies, aoe::RISK_INF);
				if (retained < aoe::RISK_INF && retained <= int64_t(cache.get("risk", 0)) + aoe::REUSE_RISK_INCREASE && direct_risk + aoe::REUSE_RISK_INCREASE >= retained && aoe::static_safe(from, to, scratch_near, scratch_boxes) && aoe::static_safe(from, from + aoe::motion_for(velocity, static_time), scratch_near, scratch_boxes)) {
					cache["px"] = to.x;
					cache["py"] = to.y;
					cache["reused"] = int64_t(cache.get("reused", 0)) + 1;
					return Vector2i((int32_t)to.x, (int32_t)to.y);
				}
			}
		}
	}
	const aoe::SolveResult result = aoe::solve(from, radius, preferred, previous, step_time, scratch_bodies, scratch_near, scratch_boxes, bounds, static_time);
	const V2 destination = from + aoe::motion_for(result.velocity, step_time);
	cache["vx"] = result.velocity.x;
	cache["vy"] = result.velocity.y;
	cache["ux"] = preferred.x;
	cache["uy"] = preferred.y;
	cache["gx"] = goal.x;
	cache["gy"] = goal.y;
	cache["hg"] = (int64_t)(has_goal ? 1 : 0);
	cache["px"] = destination.x;
	cache["py"] = destination.y;
	cache["risk"] = result.risk;
	cache["rt"] = initialized ? aoe::STEERING_INTERVAL_TIME : aoe::mul_div(aoe::STEERING_INTERVAL_TIME, aoe::posmod(motion[11], 6) + 1, 6);
	cache["solved"] = int64_t(cache.get("solved", 0)) + 1;
	return Vector2i((int32_t)destination.x, (int32_t)destination.y);
}
