class_name ResourceNode
extends Node3D

const SpriteCatalogScript := preload("res://scripts/presentation/sprite_catalog.gd")

@export var resource_type: Enums.ResourceType = Enums.ResourceType.FOOD
@export var amount := 100.0
@export var gather_rate := 4.0

var _use_billboard := false

func _ready() -> void:
	add_to_group("resource_nodes")
	_setup_presentation()

func extract(delta: float) -> float:
	if delta <= 0.0 or amount <= 0.0 or gather_rate <= 0.0:
		return 0.0
	var extracted := minf(amount, gather_rate * delta)
	amount -= extracted
	if is_zero_approx(amount):
		amount = 0.0
		visible = false
	return extracted

func _setup_presentation() -> void:
	var existing_billboard := get_node_or_null("Billboard") as Sprite3D
	var existing_marker := get_node_or_null("Marker") as MeshInstance3D
	var base := SpriteCatalogScript.resource_sheet_base(resource_type)
	if SpriteCatalogScript.sheet_paths_exist(base):
		var meta := SpriteCatalogScript.load_meta(base)
		var texture := SpriteCatalogScript.load_texture(base)
		if not meta.is_empty() and texture != null:
			var billboard := existing_billboard
			if billboard == null:
				billboard = Sprite3D.new()
				billboard.name = "Billboard"
				add_child(billboard)
			billboard.texture = SpriteCatalogScript.first_atlas_texture(meta, texture)
			var hotspot := SpriteCatalogScript.average_hotspot(meta)
			var offset := SpriteCatalogScript.offset_for_hotspot(meta, hotspot)
			SpriteCatalogScript.configure_iso_sprite(
				billboard, SpriteCatalogScript.RESOURCE_PIXEL_SIZE, offset
			)
			billboard.visible = true
			_use_billboard = true
			SpriteCatalogScript.ensure_ground_shadow(self, 0.7)
			if existing_marker != null:
				existing_marker.visible = false
			return
	if existing_billboard != null:
		existing_billboard.visible = false
	if existing_marker != null:
		existing_marker.visible = true
