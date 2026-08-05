class_name ResourceNode
extends Node3D

@export var resource_type: Enums.ResourceType = Enums.ResourceType.FOOD
@export var amount := 100.0
@export var gather_rate := 4.0

func _ready() -> void:
	add_to_group("resource_nodes")

func extract(delta: float) -> float:
	if delta <= 0.0 or amount <= 0.0 or gather_rate <= 0.0:
		return 0.0
	var extracted := minf(amount, gather_rate * delta)
	amount -= extracted
	if is_zero_approx(amount):
		amount = 0.0
		visible = false
	return extracted
