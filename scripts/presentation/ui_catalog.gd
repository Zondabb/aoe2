class_name UiCatalog
extends RefCounted

## Shared panel skin v1; swap path later for civ variants.
const PANEL_GAME_BASE := "res://assets/sprites/ui/panel_game"
const ICONS_UNITS_BASE := "res://assets/sprites/ui/icons_units"
const ICONS_BUILDINGS_BASE := "res://assets/sprites/ui/icons_buildings"
const ICONS_COMMANDS_BASE := "res://assets/sprites/ui/icons_commands"

## Provisional frame indices — adjust after inspecting exported sheets in-editor.
const FRAME_STOP := 0
const FRAME_BUILD_HOUSE := 0
const FRAME_BUILD_BARRACKS := 1
const FRAME_BUILD_ARCHERY := 2
const FRAME_BUILD_STABLE := 3
const FRAME_BUILD_MILL := 4
const FRAME_BUILD_LUMBER := 5
const FRAME_BUILD_MINING := 6

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
