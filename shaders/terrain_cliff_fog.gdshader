shader_type canvas_item;
render_mode unshaded;

// Foreground rock walls must remain above units, but the low-Z ground fog
// overlay cannot cover them. Sample its match-local data texture per fragment.
uniform sampler2D fog_mask : filter_nearest, repeat_disable;
uniform bool fog_enabled = false;
uniform bool is_memory = false;
uniform vec2 logical_min;
uniform vec2 logical_span = vec2(1.0);
uniform vec2 screen_origin;
varying vec2 map_pixel;

void vertex() {
	// Relative to the match's Entities container, unaffected by the camera.
	// Memory geometry retains the same actor position and local vertices.
	map_pixel = VERTEX + screen_origin;
}

void fragment() {
	if (fog_enabled) {
		vec2 logical = vec2(map_pixel.x / 44.0 + map_pixel.y / 22.0,
			map_pixel.y / 22.0 - map_pixel.x / 44.0);
		vec2 uv = (logical - logical_min) / logical_span;
		if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) {
			discard;
		}
		vec2 state = texture(fog_mask, uv).rg;
		// A visible part of a long cliff never reveals its unexplored far end.
		if (state.g < 0.5 && state.r < 0.5) {
			discard;
		}
		// Fog memories already carry the holder's 0.4 parent modulation.
		if (!is_memory && state.r < 0.5) {
			COLOR.rgb *= 0.4;
		}
	}
}
