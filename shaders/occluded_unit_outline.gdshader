shader_type canvas_item;
render_mode unshaded;

uniform sampler2D occlusion_map : filter_nearest, repeat_disable;
uniform vec2 mask_size = vec2(1280.0, 720.0);
uniform vec4 outline_color : source_color = vec4(0.2, 0.5, 1.0, 1.0);
uniform float unit_order;
// Atlas bounds prevent sampling the next animation frame at an edge.
uniform vec4 frame_uv = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 outline_step;
varying float opacity;
varying vec2 mask_uv;
void vertex() {
	opacity = COLOR.a;
	// Use canvas coordinates: framebuffer SCREEN_UV can be vertically flipped
	// between a Window backbuffer and a SubViewport on the GL/WebGL backend.
	mask_uv = (CANVAS_MATRIX * MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy / mask_size;
}
float solid_at(sampler2D sprite_texture, vec2 uv) {
	if (any(lessThan(uv, frame_uv.xy)) || any(greaterThanEqual(uv, frame_uv.zw))) { return 0.0; }
	return step(0.99, texture(sprite_texture, uv).a);
}
void fragment() {
	vec2 encoded = floor(texture(occlusion_map, mask_uv).rg * 255.0 + 0.5);
	float covering_order = encoded.x + encoded.y * 256.0;
	if (covering_order <= unit_order || solid_at(TEXTURE, UV) < 0.5) { discard; }
	float interior = 1.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			interior = min(interior, solid_at(TEXTURE, UV + vec2(float(x), float(y)) * outline_step));
		}
	}
	COLOR = vec4(outline_color.rgb, outline_color.a * opacity * (1.0 - interior));
}
