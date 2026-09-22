extends SceneTree

## Run with a real rendering device (not --headless):
## godot --path . --rendering-method gl_compatibility --script res://tests/render_team_color.gd
## Left cells use the shader; right cells are independently computed ordinary sprites.
const PLAYER_SHADER := preload("res://shaders/player_color.gdshader")
const OUTPUT_PATH := "res://.superpowers/sdd/team-color-render-test.png"
const SCALE := 12
const ROW_HEIGHT := 20
const LEFT := 8
const RIGHT := 72
const TOP := 24
const TOLERANCE := 3.0 / 255.0

var _viewport: SubViewport
var _base_image: Image
var _palette_image: Image
var _base_texture: Texture2D
var _palette_texture: Texture2D
var _mask_texture: Texture2D
var _cases: Array[Dictionary] = [
	{"name": "red", "player": 2, "flip": false, "modulate": Color.WHITE},
	{"name": "red mirrored", "player": 2, "flip": true, "modulate": Color.WHITE},
	{"name": "blue identity", "player": 1, "flip": false, "modulate": Color.WHITE},
	{"name": "modulate alpha", "player": 2, "flip": false, "modulate": Color(0.6, 0.8, 1.0, 0.55)},
	{"name": "modulate mirrored", "player": 2, "flip": true, "modulate": Color(0.8, 1.0, 0.5, 0.55)},
]


func _initialize() -> void:
	call_deferred("_render_and_check")


func _render_and_check() -> void:
	_build_textures()
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(136, TOP + _cases.size() * ROW_HEIGHT + 8)
	_viewport.disable_3d = true
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	var background := ColorRect.new()
	background.size = Vector2(_viewport.size)
	background.color = Color(0.12, 0.16, 0.20, 1.0)
	_viewport.add_child(background)
	var label := Label.new()
	label.text = "SHADER    EXPECTED"
	label.add_theme_font_size_override("font_size", 10)
	label.position = Vector2(LEFT, 4)
	_viewport.add_child(label)
	for case_index in _cases.size():
		_add_case(case_index, _cases[case_index])
	# SubViewport textures are only ready after the frame has actually been submitted.
	await process_frame
	await RenderingServer.frame_post_draw
	await process_frame
	await RenderingServer.frame_post_draw
	var captured := _viewport.get_texture().get_image()
	var failures: Array[String] = []
	for case_index in _cases.size():
		for pixel_index in 4:
			var y := TOP + case_index * ROW_HEIGHT + SCALE / 2
			var actual := captured.get_pixel(LEFT + pixel_index * SCALE + SCALE / 2, y)
			var expected := captured.get_pixel(RIGHT + pixel_index * SCALE + SCALE / 2, y)
			if not _colors_close(actual, expected):
				failures.append("%s pixel %d: actual=%s expected=%s" % [
					_cases[case_index]["name"], pixel_index, actual, expected,
				])
	# A blank viewport must not pass the pairwise comparisons.
	var natural := captured.get_pixel(LEFT + SCALE / 2, TOP + SCALE / 2)
	if natural.g < 0.5 or natural.g <= natural.r * 2.0:
		failures.append("reference green material did not render; viewport may be blank")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_PATH.get_base_dir()))
	var save_result := captured.save_png(ProjectSettings.globalize_path(OUTPUT_PATH))
	if save_result != OK:
		failures.append("could not save renderer evidence: %s" % error_string(save_result))
	if failures.is_empty():
		print("TEAM COLOR GPU TEST PASSED: AtlasTexture region, flip, shades 0/15, weighted overlays, source alpha and modulate")
		print("Render evidence: ", ProjectSettings.globalize_path(OUTPUT_PATH))
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _build_textures() -> void:
	_palette_image = Image.create(16, 8, false, Image.FORMAT_RGBA8)
	_palette_image.fill(Color.MAGENTA)
	_palette_image.set_pixel(0, 0, Color8(32, 64, 192))
	_palette_image.set_pixel(15, 0, Color8(128, 160, 240))
	_palette_image.set_pixel(7, 0, Color8(64, 112, 208))
	_palette_image.set_pixel(0, 1, Color8(224, 32, 48))
	_palette_image.set_pixel(15, 1, Color8(240, 160, 176))
	_palette_image.set_pixel(7, 1, Color8(208, 96, 112))
	_base_image = Image.create(8, 2, false, Image.FORMAT_RGBA8)
	_base_image.fill(Color.MAGENTA)
	# The tested region starts in both a nonzero column and a nonzero row.
	_base_image.set_pixel(4, 1, Color8(32, 192, 80))
	var first_shade := _palette_image.get_pixel(0, 0)
	first_shade.a = 128.0 / 255.0
	_base_image.set_pixel(5, 1, first_shade)
	_base_image.set_pixel(6, 1, _palette_image.get_pixel(15, 0))
	var overlaid := Color8(112, 128, 96).lerp(_palette_image.get_pixel(7, 0), 128.0 / 255.0)
	overlaid.a = 192.0 / 255.0
	_base_image.set_pixel(7, 1, overlaid)
	var mask := Image.create(8, 2, false, Image.FORMAT_RGB8)
	mask.fill(Color8(16, 255, 0))
	mask.set_pixel(4, 1, Color8(0, 255, 0))
	mask.set_pixel(5, 1, Color8(1, 255, 0))
	mask.set_pixel(6, 1, Color8(16, 255, 0))
	mask.set_pixel(7, 1, Color8(8, 128, 0))
	_base_texture = ImageTexture.create_from_image(_base_image)
	_mask_texture = ImageTexture.create_from_image(mask)
	_palette_texture = ImageTexture.create_from_image(_palette_image)


func _add_case(case_index: int, test_case: Dictionary) -> void:
	var material := ShaderMaterial.new()
	material.shader = PLAYER_SHADER
	material.set_shader_parameter("player_mask", _mask_texture)
	material.set_shader_parameter("player_palette", _palette_texture)
	material.set_shader_parameter("source_player", 1)
	material.set_shader_parameter("target_player", test_case["player"])
	var atlas := AtlasTexture.new()
	atlas.atlas = _base_texture
	atlas.region = Rect2(4, 1, 4, 1)
	var actual := _sprite(atlas, LEFT, case_index, test_case)
	actual.material = material
	var expected_image := Image.create(4, 1, false, Image.FORMAT_RGBA8)
	for pixel_index in 4:
		var value := _base_image.get_pixel(4 + pixel_index, 1)
		if pixel_index > 0:
			var shade: int = [0, 0, 15, 7][pixel_index]
			var weight := 128.0 / 255.0 if pixel_index == 3 else 1.0
			var source := _palette_image.get_pixel(shade, 0)
			var target := _palette_image.get_pixel(shade, int(test_case["player"]) - 1)
			# Build an ordinary RGBA sprite without invoking the shader or catalog.
			value.r += weight * (target.r - source.r)
			value.g += weight * (target.g - source.g)
			value.b += weight * (target.b - source.b)
		expected_image.set_pixel(pixel_index, 0, value)
	_sprite(ImageTexture.create_from_image(expected_image), RIGHT, case_index, test_case)


func _sprite(texture: Texture2D, x: int, row: int, test_case: Dictionary) -> Sprite2D:
	var parent := Node2D.new()
	# Also exercise inherited CanvasItem modulation, not only self_modulate.
	parent.modulate = Color(0.95, 1.0, 0.9, 0.85) if row == 4 else Color.WHITE
	_viewport.add_child(parent)
	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.centered = false
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.position = Vector2(x, TOP + row * ROW_HEIGHT)
	sprite.scale = Vector2(SCALE, SCALE)
	sprite.flip_h = bool(test_case["flip"])
	sprite.modulate = test_case["modulate"]
	parent.add_child(sprite)
	return sprite


func _colors_close(actual: Color, expected: Color) -> bool:
	return (
		absf(actual.r - expected.r) <= TOLERANCE
		and absf(actual.g - expected.g) <= TOLERANCE
		and absf(actual.b - expected.b) <= TOLERANCE
		and absf(actual.a - expected.a) <= TOLERANCE
	)
