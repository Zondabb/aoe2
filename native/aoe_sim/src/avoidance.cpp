#include "avoidance.h"

namespace aoe {

namespace {

// [negative side, cos, sin] x 2^15; same order as LocalAvoidance.ANGLES.
const int64_t ANGLES[16][3] = {
	{ 0, 32768, 0 }, { 0, 31651, 8481 }, { 1, 31651, -8481 }, { 0, 28378, 16384 }, { 1, 28378, -16384 },
	{ 0, 23170, 23170 }, { 1, 23170, -23170 }, { 0, 16384, 28378 }, { 1, 16384, -28378 }, { 0, 0, 32768 },
	{ 1, 0, -32768 }, { 0, -16384, 28378 }, { 1, -16384, -28378 }, { 0, -28378, 16384 }, { 1, -28378, -16384 },
	{ 0, -32768, 0 }
};

} // namespace

V2 motion_for(const V2 &velocity, int64_t time) {
	return V2(mul_div(velocity.x, time, TIME_SCALE), mul_div(velocity.y, time, TIME_SCALE));
}

V2 rotate(const V2 &vector, int64_t cosine, int64_t sine) {
	return V2(mul_div(vector.x * cosine - vector.y * sine, 1, 32768), mul_div(vector.x * sine + vector.y * cosine, 1, 32768));
}

int64_t risk(const V2 &velocity, int64_t step_time, const std::vector<Body> &bodies, int64_t limit) {
	const V2 motion = motion_for(velocity, step_time);
	const int64_t motion_sq = motion.len_sq();
	int64_t motion_length = isqrt(motion_sq);
	if (motion_length * motion_length < motion_sq) {
		motion_length += 1;
	}
	int64_t total = 0;
	for (const Body &body : bodies) {
		const int64_t rx = body.rx;
		const int64_t ry = body.ry;
		const int64_t combined = body.combined;
		const int64_t distance_sq = rx * rx + ry * ry;
		const int64_t combined_sq = combined * combined;
		if (distance_sq < combined_sq) {
			if (motion.x * rx + motion.y * ry > 0) {
				return RISK_INF;
			}
		} else if (distance_sq < (combined + motion_length) * (combined + motion_length)) {
			const int64_t projection = clamp64(rx * motion.x + ry * motion.y, 0, motion_sq);
			int64_t cx = 0;
			int64_t cy = 0;
			if (motion_sq > 0) {
				cx = mul_div(motion.x, projection, motion_sq);
				cy = mul_div(motion.y, projection, motion_sq);
			}
			const int64_t ex = rx - cx;
			const int64_t ey = ry - cy;
			if (ex * ex + ey * ey < combined_sq) {
				return RISK_INF;
			}
		}
		const int64_t rvx = velocity.x - body.vx;
		const int64_t rvy = velocity.y - body.vy;
		const int64_t closing = rx * rvx + ry * rvy;
		if (closing <= 0) {
			continue;
		}
		const int64_t padded = combined + MARGIN_Q;
		const int64_t gap = distance_sq - padded * padded;
		int64_t term = CONTACT_WEIGHT;
		if (gap > 0) {
			const int64_t relative_sq = rvx * rvx + rvy * rvy;
			if (relative_sq == 0) {
				continue;
			}
			const int64_t discriminant = closing * closing - relative_sq * gap;
			if (discriminant < 0) {
				continue;
			}
			const int64_t numerator = closing - isqrt(discriminant);
			if (10 * numerator >= 9 * relative_sq) {
				continue;
			}
			term = CONTACT_WEIGHT - mul_div(CONTACT_WEIGHT * 10, numerator, 9 * relative_sq);
		}
		total += term;
		if (total >= limit) {
			return total;
		}
	}
	return total;
}

int64_t static_horizon(const V2 &from, int64_t speed, int64_t step_time, const V2 &goal, bool has_goal) {
	int64_t horizon = max64(HORIZON_TIME, step_time);
	if (has_goal) {
		const int64_t distance = isqrt((goal - from).len_sq());
		horizon = min64(horizon, max64(step_time, mul_div(distance, TIME_SCALE, speed)));
	}
	return horizon;
}

void nearby_boxes(const V2 &from, int64_t speed, int64_t horizon, const std::vector<Box> &boxes, std::vector<int> &near) {
	near.clear();
	const int64_t reach = mul_div(speed, horizon, TIME_SCALE);
	for (int index = 0; index < (int)boxes.size(); index++) {
		const Box &box = boxes[index];
		if (box.hx > 0 && box.hy > 0) {
			const int64_t ex = box.hx + reach;
			const int64_t ey = box.hy + reach;
			if (from.x >= box.cx - ex && from.x < box.cx + ex && from.y >= box.cy - ey && from.y < box.cy + ey) {
				near.push_back(index);
			}
		}
	}
}

bool box_hit(const V2 &origin, const V2 &motion, const V2 &extent) {
	if (extent.x <= 0 || extent.y <= 0) {
		return false;
	}
	if (abs64(origin.x) < extent.x && abs64(origin.y) < extent.y) {
		const int64_t depth_x = extent.x - abs64(origin.x);
		const int64_t depth_y = extent.y - abs64(origin.y);
		if (depth_x <= depth_y && motion.x * sign64(origin.x) >= 0) {
			return false;
		}
		if (depth_y <= depth_x && motion.y * sign64(origin.y) >= 0) {
			return false;
		}
		return true;
	}
	int64_t near_num = 0;
	int64_t near_den = 1;
	int64_t far_num = 1;
	int64_t far_den = 1;
	for (int axis = 0; axis < 2; axis++) {
		const int64_t move = axis == 0 ? motion.x : motion.y;
		const int64_t start = axis == 0 ? origin.x : origin.y;
		const int64_t half = axis == 0 ? extent.x : extent.y;
		if (move == 0) {
			if (abs64(start) >= half) {
				return false;
			}
			continue;
		}
		const int64_t denominator = abs64(move);
		int64_t first = -half - start;
		int64_t second = half - start;
		if (move < 0) {
			const int64_t swap = first;
			first = -second;
			second = -swap;
		}
		if (first * near_den > near_num * denominator) {
			near_num = first;
			near_den = denominator;
		}
		if (second * far_den < far_num * denominator) {
			far_num = second;
			far_den = denominator;
		}
		if (near_num * far_den > far_num * near_den) {
			return false;
		}
	}
	return true;
}

bool static_safe(const V2 &from, const V2 &to, const std::vector<int> &near, const std::vector<Box> &boxes) {
	for (int index : near) {
		const Box &box = boxes[index];
		const V2 center(box.cx, box.cy);
		if (box_hit(from - center, to - from, V2(box.hx - 1, box.hy - 1))) {
			return false;
		}
	}
	return true;
}

bool map_ok(const V2 &point, int64_t radius, const Bounds &bounds) {
	if (!bounds.enabled) {
		return true;
	}
	return point.x >= bounds.min_x + radius && point.x <= bounds.max_x - radius && point.y >= bounds.min_y + radius && point.y <= bounds.max_y - radius;
}

SolveResult solve(const V2 &from, int64_t radius, const V2 &preferred, const V2 &previous, int64_t step_time,
		const std::vector<Body> &bodies, const std::vector<int> &near, const std::vector<Box> &boxes,
		const Bounds &bounds, int64_t static_time) {
	const int64_t speed_sq = preferred.len_sq();
	const int64_t direct_risk = risk(preferred, step_time, bodies, RISK_INF);
	if (direct_risk == 0 && map_ok(from + motion_for(preferred, step_time), radius, bounds) && static_safe(from, from + motion_for(preferred, static_time), near, boxes)) {
		SolveResult direct;
		direct.velocity = preferred;
		direct.risk = 0;
		return direct;
	}
	V2 best;
	int64_t best_score = SCORE_INF;
	int64_t best_risk = RISK_INF;
	for (int scale = 0; scale < 3; scale++) {
		for (int index = 0; index < 16; index++) {
			if (scale == 2 && index != 0) {
				continue;
			}
			V2 velocity;
			if (scale < 2) {
				velocity = rotate(preferred, ANGLES[index][1], ANGLES[index][2]);
				if (scale == 1) {
					velocity = V2(mul_div(velocity.x, 1, 2), mul_div(velocity.y, 1, 2));
				}
			}
			const V2 destination = from + motion_for(velocity, step_time);
			if (!map_ok(destination, radius, bounds)) {
				continue;
			}
			int64_t score = mul_div((velocity - preferred).len_sq(), SCORE_ONE, speed_sq) + mul_div((velocity - previous).len_sq(), PREVIOUS_WEIGHT, speed_sq) + scale * SCORE_ONE;
			if (scale < 2 && ANGLES[index][0] != 0) {
				score += SIDE_PENALTY;
			}
			if (score >= best_score) {
				continue;
			}
			const int64_t candidate_risk = risk(velocity, step_time, bodies, best_score - score);
			score += candidate_risk;
			if (score >= best_score || !static_safe(from, destination, near, boxes)) {
				continue;
			}
			if (!static_safe(from, from + motion_for(velocity, static_time), near, boxes)) {
				score += STATIC_LOOKAHEAD_PENALTY;
			}
			if (score < best_score) {
				best_score = score;
				best = velocity;
				best_risk = candidate_risk;
			}
		}
	}
	SolveResult result;
	result.velocity = best;
	result.risk = best_risk;
	return result;
}

} // namespace aoe
