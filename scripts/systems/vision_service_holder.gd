class_name VisionServiceHolder
extends Node

## Owns VisionService, rebuilds from units/buildings, exposes group lookup.

const VisionServiceScript := preload("res://scripts/systems/vision_service.gd")
const DEFAULT_CELL_SIZE := 2.0

var vision: VisionServiceScript


func setup(cell_size: float = DEFAULT_CELL_SIZE) -> void:
	vision = VisionServiceScript.new()
	vision.setup(cell_size)
	set_meta("vision", vision)
	add_to_group("vision_service")


func _ready() -> void:
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	call_deferred("_try_register", node)


func rebuild_from_scene() -> void:
	if vision == null:
		return
	vision.rebuild_from_tree(get_tree())


func _try_register(node: Node) -> void:
	if vision == null or node == null or not is_instance_valid(node):
		return
	if node.is_in_group("units") or node.is_in_group("buildings"):
		vision.register(node)
