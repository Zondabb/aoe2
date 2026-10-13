shader_type canvas_item;
render_mode unshaded;

// The authored quad only bounds the draw. These world-space edges are the
// same merged shoreline used by navigation and collision.
uniform int coast_count = 0;
uniform vec2 coast_points[192];
uniform vec2 coast_ends[192];
uniform float shore_width = 2.6;
uniform sampler2D sand_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D shallow_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D grass_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D fog_mask : filter_nearest, repeat_disable;
uniform bool fog_enabled = false;
uniform bool is_memory = false;
uniform vec2 logical_min;
uniform vec2 logical_span = vec2(1.0);
uniform vec2 screen_origin;
varying vec2 map_pixel;
varying vec4 surface_modulate;

void vertex() {
	map_pixel = VERTEX + screen_origin;
	surface_modulate = COLOR;
}

void fragment() {
	vec2 logical = vec2(map_pixel.x / 44.0 + map_pixel.y / 22.0,
		map_pixel.y / 22.0 - map_pixel.x / 44.0);
	float distance_to_coast = 100000.0;
	bool inside = false;
	for (int i = 0; i < 192; i++) {
		if (i >= coast_count) { break; }
		vec2 a = coast_points[i];
		vec2 b = coast_ends[i];
		vec2 edge = b - a;
		float t = clamp(dot(logical - a, edge) / max(dot(edge, edge), 0.000001), 0.0, 1.0);
		distance_to_coast = min(distance_to_coast, length(logical - a - t * edge));
		if ((a.y > logical.y) != (b.y > logical.y)) {
			if (logical.x < a.x + (logical.y - a.y) * edge.x / edge.y) { inside = !inside; }
		}
	}
	float coast = inside ? -distance_to_coast : distance_to_coast;
	float width = max(shore_width, 0.02);
	float alpha = 1.0 - smoothstep(width * 0.40, width, coast);
	if (alpha <= 0.001 || coast_count == 0) { discard; }
	vec3 water = texture(TEXTURE, UV).rgb;
	vec3 shallow = texture(shallow_texture, UV).rgb;
	vec3 sand = texture(sand_texture, UV).rgb;
	// Broad shallow water, a narrow wet sand edge, then pale dry sand whose
	// outer edge softly exposes the original grass underneath.
	vec3 color = mix(water, shallow, smoothstep(-width * 1.25, -width * 0.15, coast));
	color = mix(color, sand, smoothstep(-width * 0.10, width * 0.28, coast));
	// Composite against the same original world-anchored grass explicitly.
	// An opaque result is idempotent where authored water rectangles overlap;
	// repeated brush strokes cannot strengthen the fading sand edge.
	color = mix(texture(grass_texture, UV).rgb, color, alpha);
	COLOR = vec4(color, 1.0) * surface_modulate;
	if (fog_enabled) {
		vec2 fog_uv = (logical - logical_min) / logical_span;
		if (any(lessThan(fog_uv, vec2(0.0))) || any(greaterThanEqual(fog_uv, vec2(1.0)))) { discard; }
		vec2 state = texture(fog_mask, fog_uv).rg;
		if (state.g < 0.5 && state.r < 0.5) { discard; }
		if (!is_memory && state.r < 0.5) { COLOR.rgb *= 0.4; }
	}
}
