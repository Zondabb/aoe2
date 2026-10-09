extends SceneTree
## Native GPU smoke test: real team-color shaders, every siege animation step,
## a physical ranged launch, and original stone flight/impact art.
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const SPRITES := preload("res://scripts/presentation/sprite_catalog.gd")
const BG := Color("536b3c")
var view: SubViewport
var entities: Node2D
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func frame() -> void:
	for i in 3:
		await process_frame
		await RenderingServer.frame_post_draw

func stage(size: Vector2i) -> void:
	if is_instance_valid(view):
		view.free()
	view = SubViewport.new()
	view.size = size
	view.disable_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(view)
	var ground := ColorRect.new()
	ground.size = size
	ground.color = BG
	ground.z_index = -100
	view.add_child(ground)
	entities = Node2D.new()
	entities.y_sort_enabled = true
	view.add_child(entities)

func label_at(text_value: String, at: Vector2) -> void:
	var label := Label.new()
	label.text = text_value
	label.position = at
	view.add_child(label)

func unit_at(id: StringName, at: Vector2, side: Enums.Team = Enums.Team.PLAYER) -> UnitAgent:
	var unit := UNIT.instantiate() as UnitAgent
	unit.def = GameCatalog.get_unit(id)
	unit.sim_pos = at
	unit.team = side
	entities.add_child(unit)
	unit.set_physics_process(false)
	return unit

func ink_in(image: Image, rect: Rect2i) -> int:
	var count := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var color := image.get_pixel(x, y)
			# Count solid actor pixels; ignore almost-black ground shadows.
			if color.r > BG.r + 0.08 or color.b > BG.b + 0.08:
				count += 1
	return count

func _run() -> void:
	stage(Vector2i(1100, 730))
	var ids: Array[StringName] = [&"mangonel", &"onager", &"siege_onager", &"battering_ram", &"capped_ram", &"siege_ram"]
	var actors: Array[UnitAgent] = []
	var minimums: Array[int] = []
	var maximums: Array[int] = []
	for column in 3:
		label_at(["Original idle", "Moving - fixed facing", "Attacking - fixed facing"][column], Vector2(170 + column * 330, 18))
	for row in ids.size():
		label_at(String(ids[row]), Vector2(18, 75 + row * 105))
		for column in 3:
			var actor := unit_at(ids[row], Vector2.ONE)
			actor.position = Vector2(225 + column * 330, 126 + row * 105)
			actor._facing_dir = 2
			actors.append(actor)
			minimums.append(1000000)
			maximums.append(0)
	for step in 15:
		for index in actors.size():
			var actor := actors[index]
			var column := index % 3
			actor._anim_frame = step
			actor._combat_anim_time = step / actor._animation_fps(&"attack")
			actor._apply_billboard_frame(column != 0, [&"idle", &"", &"attack"][column], column == 1)
		await frame()
		var image := view.get_texture().get_image()
		for index in actors.size():
			var box := Rect2i(Vector2i(actors[index].position) - Vector2i(85, 86), Vector2i(170, 98))
			var ink := ink_in(image, box)
			minimums[index] = mini(minimums[index], ink)
			maximums[index] = maxi(maximums[index], ink)
		if step in [0, 5, 9]:
			image.save_png("res://.godot/siege-animation-%02d.png" % step)
	for index in actors.size():
		check(minimums[index] > 150, "%s action %d never vanishes under the actual shader" % [ids[index / 3], index % 3])
		check(minimums[index] >= maximums[index] * 0.55, "%s action %d keeps a coherent body throughout its cycle" % [ids[index / 3], index % 3])
	stage(Vector2i(1100, 540))
	entities.position = Vector2(550, 330)
	label_at("Mangonel: original stone cluster, non-homing arc and ground shadow", Vector2(35, 20))
	var siege := unit_at(&"mangonel", Vector2(-10, 0))
	var target := unit_at(&"battering_ram", Vector2(10, 0), Enums.Team.AI)
	siege.command_attack(target)
	siege._physics_process(1.0 / 60.0)
	var shot: ProjectileAgent
	for node in entities.get_children():
		if node is ProjectileAgent:
			shot = node
	check(shot != null, "actual ranged order launches a stone in the native renderer")
	if shot != null:
		shot.set_physics_process(false)
		shot._physics_process(0.6)
		await frame()
		var flight := view.get_texture().get_image()
		flight.save_png("res://.godot/siege-flight.png")
		var shot_screen := Vector2i(entities.position + shot.position)
		check(ink_in(flight, Rect2i(shot_screen - Vector2i(16, 16), Vector2i(32, 32))) > 5, "airborne stone cluster is visible in the framebuffer")
		var hp_before := target.hp
		shot._physics_process(2.0)
		shot._physics_process(0.14)
		await frame()
		var impact_image := view.get_texture().get_image()
		impact_image.save_png("res://.godot/siege-impact.png")
		check(target.hp < hp_before, "the displayed landing coincides with actual damage")
		check((shot.get_node("Sprite") as Sprite2D).texture != null, "original impact texture renders")
		shot.hide()
		await frame()
		var hidden_image := view.get_texture().get_image()
		var changed := 0
		for y in 540:
			for x in 1100:
				if impact_image.get_pixel(x, y) != hidden_image.get_pixel(x, y):
					changed += 1
		check(changed > 100, "impact cloud changes visible framebuffer pixels (%d)" % changed)
	view.free()
	await process_frame
	print("SIEGE GPU: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
