class_name GamePanelFrame
extends Control

const UiCatalogScript := preload("res://scripts/presentation/ui_catalog.gd")

@onready var _top_panel_texture := %TopPanelTexture as TextureRect
@onready var _bottom_panel_texture := %BottomPanelTexture as TextureRect

## Screen height of the top resource chrome after width-fit scaling.
var top_band_height: float = 32.0
## Screen height of the bottom command chrome after width-fit scaling.
var bottom_band_height: float = 150.0

func _ready() -> void:
	apply_textures()
	resized.connect(_on_layout_dirty)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_layout_dirty):
		vp.size_changed.connect(_on_layout_dirty)
	await get_tree().process_frame
	_sync_panel_layout()

func apply_textures() -> void:
	if _top_panel_texture == null:
		_top_panel_texture = get_node_or_null("%TopPanelTexture") as TextureRect
	if _bottom_panel_texture == null:
		_bottom_panel_texture = get_node_or_null("%BottomPanelTexture") as TextureRect
	var top_tex := UiCatalogScript.panel_band_texture("top")
	var bottom_tex := UiCatalogScript.panel_band_texture("bottom")
	if _top_panel_texture != null:
		_top_panel_texture.texture = top_tex
		_top_panel_texture.visible = top_tex != null
	if _bottom_panel_texture != null:
		_bottom_panel_texture.texture = bottom_tex
		_bottom_panel_texture.visible = bottom_tex != null
	_sync_panel_layout()

func _on_layout_dirty() -> void:
	call_deferred("_sync_panel_layout")

func _sync_panel_layout() -> void:
	var view_size := size
	if view_size.x <= 0.0 or view_size.y <= 0.0:
		view_size = get_viewport_rect().size
	if view_size.x <= 0.0:
		return
	var scale := UiCatalogScript.panel_scale_for_width(view_size.x)
	top_band_height = UiCatalogScript.panel_scaled_top_band(view_size.x)
	bottom_band_height = UiCatalogScript.panel_scaled_bottom_band(view_size.x)
	_layout_band(_top_panel_texture, true, top_band_height)
	_layout_band(_bottom_panel_texture, false, bottom_band_height)

func _layout_band(panel: TextureRect, is_top: bool, band_height: float) -> void:
	if panel == null or not panel.visible:
		return
	if is_top:
		panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		panel.offset_top = 0.0
		panel.offset_bottom = band_height
	else:
		panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		panel.offset_bottom = 0.0
		panel.offset_top = -band_height
	panel.offset_left = 0.0
	panel.offset_right = 0.0
	panel.stretch_mode = TextureRect.STRETCH_SCALE
