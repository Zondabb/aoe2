class_name UiCatalog
extends RefCounted

## Shared panel skin v1; swap path later for civ variants.
const PANEL_GAME_BASE := "res://assets/sprites/ui/panel_game"
const PANEL_DESIGN_WIDTH := 1280.0
const PANEL_DESIGN_HEIGHT := 1024.0
## Opaque top resource chrome inside panel_game.png (y≈0–31).
const PANEL_TOP_BAND_PX := 32.0
## Opaque bottom command chrome height inside panel_game.png (y≈819–1023).
const PANEL_BOTTOM_BAND_PX := 205.0
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
const FRAME_STOP := 0
const FRAME_BUILD_HOUSE := 34
const FRAME_BUILD_BARRACKS := 2
const FRAME_BUILD_ARCHERY := 0
const FRAME_BUILD_STABLE := 24
const FRAME_BUILD_MILL := 20
const FRAME_BUILD_LUMBER := 41
const FRAME_BUILD_MINING := 39

const FRAME_UNIT_VILLAGER := 15
const FRAME_UNIT_ARCHER := 17
const FRAME_UNIT_SWORDSMAN := 12
const FRAME_UNIT_CHU_KO_NU := 44
const FRAME_UNIT_TEUTONIC_KNIGHT := 8

static func load_meta(base: String) -> Dictionary:
	var path := "%s.json" % base
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text)
	return data if typeof(data) == TYPE_DICTIONARY else {}

static func load_texture(base: String) -> Texture2D:
	var path := "%s.png" % base
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D

static func atlas_frame(base: String, frame_index: int) -> Texture2D:
	var tex := load_texture(base)
	var meta := load_meta(base)
	if tex == null or meta.is_empty():
		return null
	var cols := int(meta.get("cols", 1))
	var fw := int(meta.get("frame_w", 0))
	var fh := int(meta.get("frame_h", 0))
	if cols <= 0 or fw <= 0 or fh <= 0:
		return null
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2((frame_index % cols) * fw, int(frame_index / cols) * fh, fw, fh)
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
