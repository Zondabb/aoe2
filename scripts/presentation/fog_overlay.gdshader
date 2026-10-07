shader_type canvas_item;
render_mode unshaded;
uniform sampler2D fog_mask : filter_linear, repeat_disable;
uniform vec2 logical_min;
uniform vec2 logical_span;
varying vec2 world_pixel;

// Filter the presentation mask only. Gameplay continues to use the original
// discrete visibility cells, so this feather never reveals hidden entities.
vec2 smooth_fog(vec2 uv) {
	vec2 step_uv = 0.75 / vec2(textureSize(fog_mask, 0));
	vec2 state = texture(fog_mask, uv).rg * 0.25;
	state += texture(fog_mask, uv + vec2(step_uv.x, 0.0)).rg * 0.125;
	state += texture(fog_mask, uv - vec2(step_uv.x, 0.0)).rg * 0.125;
	state += texture(fog_mask, uv + vec2(0.0, step_uv.y)).rg * 0.125;
	state += texture(fog_mask, uv - vec2(0.0, step_uv.y)).rg * 0.125;
	state += texture(fog_mask, uv + step_uv).rg * 0.0625;
	state += texture(fog_mask, uv - step_uv).rg * 0.0625;
	state += texture(fog_mask, uv + vec2(step_uv.x, -step_uv.y)).rg * 0.0625;
	state += texture(fog_mask, uv + vec2(-step_uv.x, step_uv.y)).rg * 0.0625;
	return smoothstep(vec2(0.08), vec2(0.92), state);
}
void vertex() {
	world_pixel = VERTEX;
}
void fragment() {
	vec2 logical = vec2(world_pixel.x / 44.0 + world_pixel.y / 22.0,
		world_pixel.y / 22.0 - world_pixel.x / 44.0);
	vec2 uv = (logical - logical_min) / logical_span;
	float alpha = 1.0;
	if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
		vec2 state = smooth_fog(uv);
		alpha = 1.0 - 0.4 * state.g - 0.6 * state.r;
	}
	COLOR = vec4(0.0, 0.0, 0.0, alpha);
}
