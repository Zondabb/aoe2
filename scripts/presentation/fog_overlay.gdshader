shader_type canvas_item;
render_mode unshaded;
uniform sampler2D fog_mask : filter_nearest, repeat_disable;
uniform vec2 logical_min;
uniform vec2 logical_span;
varying vec2 world_pixel;
void vertex() {
	world_pixel = VERTEX;
}
void fragment() {
	vec2 logical = vec2(world_pixel.x / 44.0 + world_pixel.y / 22.0,
		world_pixel.y / 22.0 - world_pixel.x / 44.0);
	vec2 uv = (logical - logical_min) / logical_span;
	float alpha = 1.0;
	if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
		vec2 state = texture(fog_mask, uv).rg;
		alpha = state.r > 0.5 ? 0.0 : (state.g > 0.5 ? 0.6 : 1.0);
	}
	COLOR = vec4(0.0, 0.0, 0.0, alpha);
}
