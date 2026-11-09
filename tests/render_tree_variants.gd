extends SceneTree
## Render the actual ResourceNode billboards at game scale for visual inspection.
const Trees := preload("res://scripts/presentation/tree_variants.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var view := SubViewport.new()
	view.size = Vector2i(1960, 1040)
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var background := ColorRect.new()
	background.color = Color("526543")
	background.size = Vector2(view.size)
	view.add_child(background)
	var positions := {}
	for x in range(0, 241, 4):
		for y in range(0, 241, 4):
			var selected := Trees.at_position(Vector2(x, y))
			positions[str(selected)] = Vector2(x, y)
	for family in Trees.BASES.size():
		var title := Label.new()
		title.text = ["Deciduous", "Pine", "Palm", "Bamboo"][family]
		title.position = Vector2(16, family * 260 + 4)
		view.add_child(title)
		for i in Trees.FRAMES[family].size():
			var selected := {"base": "res://assets/sprites/resources/" + Trees.BASES[family], "frame": Trees.FRAMES[family][i]}
			var tree := ResourceNode.new()
			tree.resource_type = Enums.ResourceType.WOOD
			tree.sim_pos = positions[str(selected)]
			view.add_child(tree)
			tree.position = Vector2(80 + i * 150, family * 260 + 228)
			var label := Label.new()
			label.text = str(selected.frame)
			label.position = tree.position + Vector2(-5, 6)
			view.add_child(label)
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw
	view.get_texture().get_image().save_png("res://.godot/tree-variants-preview.png")
	print("TREE PREVIEW SAVED")
	quit()
