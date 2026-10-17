class_name UiCatalog
extends RefCounted

## Shared panel skin v1; swap path later for civ variants.
const Catalog := preload("res://scripts/data/game_catalog.gd")

const PANEL_GAME_BASE := "res://assets/sprites/ui/panel_game"
const PANEL_DESIGN_WIDTH := 1280.0
const PANEL_DESIGN_HEIGHT := 1024.0
## Opaque top resource chrome inside panel_game.png (y≈0–31).
const PANEL_TOP_BAND_PX := 32.0
## Opaque bottom command chrome height inside panel_game.png (y≈819–1023).
const PANEL_BOTTOM_BAND_PX := 205.0
## Inner diamond bounds in the original 1280 x 1024 panel artwork.
const PANEL_MINIMAP_RECT := Rect2(868.0, 820.0, 392.0, 196.0)
## Text inset inside the top band (design pixels at 1280 width).
const PANEL_TOP_TEXT_LEFT_PX := 96.0
const PANEL_TOP_TEXT_TOP_PX := 6.0
const PANEL_TOP_TEXT_RIGHT_PX := 12.0
## Number slot rects in panel_game top band (wood, food, gold, stone, pop).
## Icons are baked into panel_game; these rects cover only the numeric area to the right.
const PANEL_TOP_RESOURCE_SLOTS := [
	{"left": 38.0, "top": 9.0, "width": 35.0},
	{"left": 115.0, "top": 9.0, "width": 35.0},
	{"left": 192.0, "top": 9.0, "width": 35.0},
	{"left": 269.0, "top": 9.0, "width": 35.0},
	{"left": 318.0, "top": 9.0, "width": 62.0},
]
const ICONS_UNITS_BASE := "res://assets/sprites/ui/icons_units"
const ICONS_BUILDINGS_BASE := "res://assets/sprites/ui/icons_buildings"
const ICONS_COMMANDS_BASE := "res://assets/sprites/ui/icons_commands"

## Frame indices verified against exported SLP sheets (50705 / 50721 / 50730).
const FRAME_STOP := 3
const FRAME_BACK := 0
const FRAME_ECONOMY := 30
const FRAME_MILITARY := 31
## Last row of the original 50721 command sheet, verified visually.
const FRAME_FORMATION_LINE := 65
const FRAME_FORMATION_BOX := 66
const FRAME_FORMATION_STAGGERED := 67
const FRAME_FORMATION_FLANK := 68
const FRAME_BUILD_TOWN_CENTER := 28
const FRAME_BUILD_HOUSE := 34
const FRAME_BUILD_BARRACKS := 2
const FRAME_BUILD_ARCHERY := 0
const FRAME_BUILD_STABLE := 23
const FRAME_BUILD_MILL := 19
const FRAME_BUILD_LUMBER := 40
const FRAME_BUILD_MINING := 39

const FRAME_UNIT_VILLAGER := 15
const FRAME_UNIT_ARCHER := 17
const FRAME_UNIT_SWORDSMAN := 12
const FRAME_UNIT_CHU_KO_NU := 44
const FRAME_UNIT_TEUTONIC_KNIGHT := 8

## HUD portraits refresh every frame. Share immutable packaged UI assets across
## those refreshes; the sheet base remains part of the key for age/civ changes.
static var _meta_cache: Dictionary = {}
static var _texture_cache: Dictionary = {}
static var _frame_cache: Dictionary = {}

static func load_meta(base: String) -> Dictionary:
	if _meta_cache.has(base):
		return _meta_cache[base]
	var path := "%s.json" % base
	if not FileAccess.file_exists(path):
		_meta_cache[base] = {}
		return _meta_cache[base]
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text)
	_meta_cache[base] = data if typeof(data) == TYPE_DICTIONARY else {}
	return _meta_cache[base]

static func load_texture(base: String) -> Texture2D:
	if _texture_cache.has(base):
		return _texture_cache[base]
	var path := "%s.png" % base
	_texture_cache[base] = load(path) as Texture2D if ResourceLoader.exists(path) else null
	return _texture_cache[base]

static func atlas_frame(base: String, frame_index: int) -> Texture2D:
	if not _frame_cache.has(base):
		_frame_cache[base] = {}
	var frames: Dictionary = _frame_cache[base]
	if frames.has(frame_index):
		return frames[frame_index]
	var tex := load_texture(base)
	var meta := load_meta(base)
	if tex == null or meta.is_empty():
		frames[frame_index] = null
		return null
	var cols := int(meta.get("cols", 1))
	var fw := int(meta.get("frame_w", 0))
	var fh := int(meta.get("frame_h", 0))
	if cols <= 0 or fw <= 0 or fh <= 0:
		frames[frame_index] = null
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2((frame_index % cols) * fw, int(frame_index / cols) * fh, fw, fh)
	frames[frame_index] = atlas
	return atlas

static func panel_texture() -> Texture2D:
	return load_texture(PANEL_GAME_BASE)

static func panel_bottom_band_px() -> float:
	return PANEL_BOTTOM_BAND_PX

static func panel_top_band_px() -> float:
	return PANEL_TOP_BAND_PX

static func panel_band_texture(band: String) -> Texture2D:
	var base_tex := load_texture(PANEL_GAME_BASE)
	if base_tex == null:
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = base_tex
	match band:
		"top":
			atlas.region = Rect2(0.0, 0.0, PANEL_DESIGN_WIDTH, PANEL_TOP_BAND_PX)
		"bottom":
			atlas.region = Rect2(
				0.0,
				PANEL_DESIGN_HEIGHT - PANEL_BOTTOM_BAND_PX,
				PANEL_DESIGN_WIDTH,
				PANEL_BOTTOM_BAND_PX
			)
		_:
			return null
	return atlas

static func panel_scale_for_width(view_width: float) -> float:
	if view_width <= 0.0:
		return 1.0
	return view_width / PANEL_DESIGN_WIDTH

static func panel_scaled_height(view_width: float) -> float:
	return PANEL_DESIGN_HEIGHT * panel_scale_for_width(view_width)

static func panel_scaled_bottom_band(view_width: float) -> float:
	return PANEL_BOTTOM_BAND_PX * panel_scale_for_width(view_width)

static func panel_scaled_top_band(view_width: float) -> float:
	return PANEL_TOP_BAND_PX * panel_scale_for_width(view_width)

static func panel_resource_slots() -> Array:
	return PANEL_TOP_RESOURCE_SLOTS

static func unit_icon_frame(unit_id: StringName) -> int:
	var record := Catalog.unit_record(unit_id)
	if not record.is_empty(): return int(record.get("icon_id", 0))
	match unit_id:
		&"villager":
			return FRAME_UNIT_VILLAGER
		&"archer":
			return FRAME_UNIT_ARCHER
		&"swordsman":
			return FRAME_UNIT_SWORDSMAN
		&"chu_ko_nu":
			return FRAME_UNIT_CHU_KO_NU
		&"teutonic_knight":
			return FRAME_UNIT_TEUTONIC_KNIGHT
		_:
			return 0

static func unit_display_name(unit_id: StringName) -> String:
	if not Catalog.unit_record(unit_id).is_empty(): return Catalog.display_name(unit_id)
	match unit_id:
		&"villager": return "村民"
		&"archer": return "弓箭手"
		&"swordsman": return "剑士"
		&"chu_ko_nu": return "诸葛弩"
		&"teutonic_knight": return "条顿武士"
		_: return String(unit_id)

static func unit_train_hotkey(unit_id: StringName) -> Key:
	match unit_id:
		&"villager": return KEY_C
		&"archer": return KEY_A
		&"swordsman": return KEY_S
		_: return KEY_T
