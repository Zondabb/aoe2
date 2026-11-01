#pragma once
// Integer helpers with exactly the semantics of scripts/core/sim_fixed.gd.
// GDScript ints are signed 64-bit; '/' and '%' truncate toward zero as in C++.

#include <cstdint>

namespace aoe {

constexpr int64_t TIME_SCALE = 30720;

inline int64_t abs64(int64_t value) {
	return value < 0 ? -value : value;
}

inline int64_t sign64(int64_t value) {
	return value > 0 ? 1 : (value < 0 ? -1 : 0);
}

inline int64_t clamp64(int64_t value, int64_t low, int64_t high) {
	return value < low ? low : (value > high ? high : value);
}

inline int64_t min64(int64_t a, int64_t b) {
	return a < b ? a : b;
}

inline int64_t max64(int64_t a, int64_t b) {
	return a > b ? a : b;
}

// Fixed.mul_div: round to nearest, halves away from zero. Callers keep the
// product within 64 bits and the denominator nonzero.
inline int64_t mul_div(int64_t a, int64_t b, int64_t denominator) {
	const int64_t product = a * b;
	const bool negative = (product < 0) != (denominator < 0);
	const int64_t result = (abs64(product) + abs64(denominator) / 2) / abs64(denominator);
	return negative ? -result : result;
}

// Fixed.floor_div for a positive denominator.
inline int64_t floor_div(int64_t value, int64_t denominator) {
	const int64_t quotient = value / denominator;
	return (value < 0 && value % denominator != 0) ? quotient - 1 : quotient;
}

// Fixed.isqrt: floor square root, bit by bit.
inline int64_t isqrt(int64_t value) {
	int64_t remainder = value;
	int64_t result = 0;
	int64_t bit = int64_t(1) << 62;
	while (bit > remainder) {
		bit >>= 2;
	}
	while (bit != 0) {
		if (remainder >= result + bit) {
			remainder -= result + bit;
			result = (result >> 1) + bit;
		} else {
			result >>= 1;
		}
		bit >>= 2;
	}
	return result;
}

// GDScript posmod for a positive modulus.
inline int64_t posmod(int64_t value, int64_t modulus) {
	const int64_t result = value % modulus;
	return result < 0 ? result + modulus : result;
}

struct V2 {
	int64_t x = 0;
	int64_t y = 0;
	V2() = default;
	V2(int64_t p_x, int64_t p_y) :
			x(p_x), y(p_y) {}
	V2 operator+(const V2 &other) const { return V2(x + other.x, y + other.y); }
	V2 operator-(const V2 &other) const { return V2(x - other.x, y - other.y); }
	bool operator==(const V2 &other) const { return x == other.x && y == other.y; }
	int64_t len_sq() const { return x * x + y * y; }
	int64_t dot(const V2 &other) const { return x * other.x + y * other.y; }
};

} // namespace aoe
