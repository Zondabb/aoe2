extends SceneTree
## Optional graphical QA; starts no AI HTTP requests.
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var session := root.get_node("GameSession")
	session.online_active = false
	session.match_ai_mode = "sandbox"
	var world: Node = load("res://scenes/match_2d.tscn").instantiate()
	root.add_child(world)
	current_scene = world
	# A hidden QA window has no meaningful mouse position for edge scrolling.
	world.get_node("Camera2D").set_process(false)
	await create_timer(1.0).timeout
	await RenderingServer.frame_post_draw
	var args := OS.get_cmdline_user_args()
	var result := root.get_texture().get_image().save_png(args[0])
	print("AI AUTOPLAY PREVIEW: ", result)
	quit(result)
