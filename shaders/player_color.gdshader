shader_type canvas_item;
render_mode unshaded;

// Data texture: R = shade + 1 (0 means ordinary art), G = player-color
// contribution to the final straight RGB. Do not use source_color on this mask.
uniform sampler2D player_mask : filter_nearest, repeat_disable;
uniform sampler2D player_palette : source_color, filter_nearest, repeat_disable;
uniform int source_player : hint_range(1, 8) = 3;
uniform int target_player : hint_range(1, 8) = 1;

varying vec4 sprite_modulate;

void vertex() {
	// Fragment COLOR already includes TEXTURE. Keep modulation separately so
	// ghost tint, parent modulation and alpha are applied exactly once.
	sprite_modulate = COLOR;
}

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	// AtlasTexture supplies coordinates in the underlying sheet, including
	// flip_h. The equally sized mask must use those exact same UV coordinates.
	vec2 mask = texture(player_mask, UV).rg;
	float index = floor(mask.r * 255.0 + 0.5);
	if (index > 0.0) {
		float shade_u = (index - 0.5) / 16.0;
		vec3 source = texture(player_palette, vec2(shade_u, (float(source_player) - 0.5) / 8.0)).rgb;
		vec3 target = texture(player_palette, vec2(shade_u, (float(target_player) - 0.5) / 8.0)).rgb;
		base.rgb = clamp(base.rgb + mask.g * (target - source), vec3(0.0), vec3(1.0));
	}
	COLOR = base * sprite_modulate;
}
