class_name BuildingAgent
extends Node3D

@export var team: Enums.Team = Enums.Team.PLAYER
@export var accepts_all_resources := false
@export var accepted_resource_type: Enums.ResourceType = Enums.ResourceType.FOOD

func _ready() -> void:
	add_to_group("drop_off_buildings")

func accepts_resource(resource_type: Enums.ResourceType) -> bool:
	return accepts_all_resources or accepted_resource_type == resource_type
