extends SceneTree

## Render actual game atlases with the production shader; no recolored PNGs.
## Run with --rendering-method gl_compatibility (not --headless).
const CATALOG := preload("res://scripts/presentation/sprite_catalog.gd")
const OUTPUT := "res://.superpowers/sdd/team-color-preview.png"
var viewport: SubViewport
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_render")


func _render() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(1440, 1060)
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	_rect(Rect2(0, 0, 1440, 1060), Color("17231f"))
	_label("PLAYER COLOR SHADER", Vector2(32, 18), 30)
	_label("Shared original atlases + semantic index masks. Only player-color pixels change.", Vector2(32, 58), 18)
	for player in [1, 2]:
		var x := float((player - 1) * 712 + 24)
		_rect(Rect2(x, 108, 680, 916), Color("3a4737"))
		_rect(Rect2(x, 108, 680, 5), Color("5493ff") if player == 1 else Color("ff6561"))
		_label("PLAYER 1 / BLUE" if player == 1 else "PLAYER 2 / RED", Vector2(x + 22, 126), 24)
		var units := ["villager_walk", "swordsman_walk", "archer_attack", "chu_ko_nu_attack", "teutonic_knight_walk"]
		var names := ["Villager", "Swordsman", "Archer", "Chu Ko Nu", "Teutonic Knight"]
		for index in units.size():
			var center := x + 76 + index * 132
			_sprite("units/" + units[index], player, Vector2(center, 295), 2.0, 2, 3)
			_label(names[index], Vector2(center - 54, 324), 15)
		_label("WORK ANIMATIONS", Vector2(x + 22, 378), 18)
		var work := ["villager_gather_food", "villager_chop", "villager_mine", "villager_build"]
		for index in work.size():
			_sprite("units/" + work[index], player, Vector2(x + 92 + index * 166, 510), 2.0, 1, 4)
		_label("MULTILAYER TOWN CENTER", Vector2(x + 22, 556), 18)
		_sprite("buildings/tc_asian_feudal", player, Vector2(x + 340, 802), 1.35, 0, 0)
		_sprite("buildings/house_dark", player, Vector2(x + 125, 956), 0.9, 0, 0)
		_label("Ordinary roofs, timber, skin and shadows retain their original colors.", Vector2(x + 22, 990), 14)
	await process_frame
	await RenderingServer.frame_post_draw
	await process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var path := ProjectSettings.globalize_path(OUTPUT)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if image.save_png(path) != OK:
		failures.append("Could not save actual sprite preview")
	for failure in failures:
		push_error(failure)
	if failures.is_empty():
		print("TEAM COLOR PREVIEW: ", path)
	quit(0 if failures.is_empty() else 1)


func _sprite(key: String, player: int, at: Vector2, pixel_scale: float, direction: int, step: int) -> void:
	var base := "res://assets/sprites/" + key
	var meta := CATALOG.load_meta(base)
	var texture := CATALOG.load_texture(base)
	if meta.is_empty() or texture == null:
		failures.append("Missing preview source: " + base)
		return
	var index := mini(direction * int(meta["frames_per_direction"]) + step, int(meta["frame_count"]) - 1)
	var sprite := Sprite2D.new()
	sprite.texture = CATALOG.atlas_frame_at(meta, texture, index)
	sprite.offset = CATALOG.offset_for_hotspot_2d(meta, CATALOG.hotspot_at_index(meta, index))
	sprite.scale = Vector2.ONE * pixel_scale
	sprite.position = at
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if not CATALOG.apply_player_color(sprite, base, player):
		failures.append("Missing preview player mask: " + base)
	viewport.add_child(sprite)


func _rect(rect: Rect2, color: Color) -> void:
	var item := ColorRect.new()
	item.position = rect.position
	item.size = rect.size
	item.color = color
	viewport.add_child(item)


func _label(value: String, at: Vector2, font_size: int) -> void:
	var item := Label.new()
	item.text = value
	item.position = at
	item.add_theme_font_size_override("font_size", font_size)
	item.add_theme_color_override("font_color", Color("e5eadf"))
	viewport.add_child(item)
