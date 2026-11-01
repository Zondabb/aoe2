#pragma once
// Integer local avoidance: a line-by-line port of
// scripts/systems/local_avoidance.gd (keep both in step). Only axis-aligned
// boxes are handled here; units near water use the GDScript solver.

#include <cstdint>
#include <vector>

#include "fixed_math.h"

namespace aoe {

constexpr int64_t HORIZON_TIME = 27648;
constexpr int64_t MARGIN_Q = 123;
constexpr int64_t SCORE_ONE = 65536;
constexpr int64_t RISK_INF = int64_t(1) << 60;
constexpr int64_t SCORE_INF = int64_t(1) << 62;
constexpr int64_t PREVIOUS_WEIGHT = 11796;
constexpr int64_t SIDE_PENALTY = 5243;
constexpr int64_t CONTACT_WEIGHT = 262144;
constexpr int64_t STATIC_LOOKAHEAD_PENALTY = 131072;
constexpr int64_t STEERING_INTERVAL_TIME = 7680;
constexpr int64_t REUSE_RISK_INCREASE = 16384;
constexpr int64_t REUSE_SPEED_PERCENT = 1;
constexpr int64_t REUSE_DIRECTION_PPM = 996195;
constexpr int64_t V_MAX = 8192;
constexpr int64_t RADIUS_MAX = 8192;
constexpr int64_t STEP_TIME_MAX = 30720;
constexpr int64_t POS_MAX = int64_t(1) << 24;

struct Body {
	int64_t rx, ry, vx, vy, combined;
};

struct Box {
	int64_t cx, cy, hx, hy;
};

struct Motion {
	V2 from;
	int64_t radius = 0;
	V2 preferred;
	V2 previous;
	int64_t step_time = 0;
	V2 goal;
	bool has_goal = false;
	int64_t phase_key = 0;
};

struct Bounds {
	bool enabled = false;
	int64_t min_x = 0, min_y = 0, max_x = 0, max_y = 0;
};

struct SolveResult {
	V2 velocity;
	int64_t risk = 0;
};

V2 motion_for(const V2 &velocity, int64_t time);
V2 rotate(const V2 &vector, int64_t cosine, int64_t sine);
int64_t risk(const V2 &velocity, int64_t step_time, const std::vector<Body> &bodies, int64_t limit);
int64_t static_horizon(const V2 &from, int64_t speed, int64_t step_time, const V2 &goal, bool has_goal);
void nearby_boxes(const V2 &from, int64_t speed, int64_t horizon, const std::vector<Box> &boxes, std::vector<int> &near);
bool box_hit(const V2 &origin, const V2 &motion, const V2 &extent);
bool static_safe(const V2 &from, const V2 &to, const std::vector<int> &near, const std::vector<Box> &boxes);
bool map_ok(const V2 &point, int64_t radius, const Bounds &bounds);
SolveResult solve(const V2 &from, int64_t radius, const V2 &preferred, const V2 &previous, int64_t step_time,
		const std::vector<Body> &bodies, const std::vector<int> &near, const std::vector<Box> &boxes,
		const Bounds &bounds, int64_t static_time);

} // namespace aoe
