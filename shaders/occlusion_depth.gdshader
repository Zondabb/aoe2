shader_type canvas_item;
render_mode unshaded, blend_disabled;

// Byte-encoded drawing order in an unfiltered RGBA8 viewport (not a color).
uniform vec2 drawing_order;
varying float opacity;
void vertex() { opacity = COLOR.a; }
void fragment() {
	// Solid SLP pixels occlude; transparent holes and ground shadows do not.
	if (texture(TEXTURE, UV).a * opacity < 0.99) { discard; }
	COLOR = vec4(drawing_order, 0.0, 1.0);
}
