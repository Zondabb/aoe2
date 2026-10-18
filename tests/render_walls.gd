extends SceneTree
const Walls := preload("res://scripts/systems/wall_system.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
const Building := preload("res://scenes/entities/building_view.tscn")
const Iso := preload("res://scripts/presentation/iso_math.gd")
var viewport: SubViewport
var state: MatchState
var entities: Node2D

func _initialize() -> void: call_deferred("_run")
func label_at(text: String, at: Vector2) -> void:
	var label := Label.new()
	label.text = text
	label.position = at
	label.add_theme_font_size_override("font_size", 22)
	viewport.add_child(label)

func _run() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(1440, 1180)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var background := ColorRect.new()
	background.color = Color("25332b")
	background.size = viewport.size
	viewport.add_child(background)
	state = MatchState.new()
	state.setup_defaults()
	state.set_age(0, 2)
	state.set_age(1, 2)
	state.frozen = true
	state.set_team_color_id(0, 1)
	state.set_team_color_id(1, 2)
	label_at("原版 AoE2 素材 · 四方向城墙 / 城门", Vector2(36, 22))
	for cell in 12:
		var orientation := cell % 4
		var row := cell / 4
		var origin := Vector2(180 + orientation * 360, 285 + row * 345)
		label_at(["中国石墙 · 关闭", "条顿强化城墙 · 开启", "木栅栏 · 连续连接"][row], origin - Vector2(150, 180))
		entities = Node2D.new()
		entities.y_sort_enabled = true
		entities.position = origin
		viewport.add_child(entities)
		var axis := Walls.direction(orientation)
		var plan := Walls.plan(["stone_wall", "fortified_wall", "palisade_wall"][row], -axis * 3, axis * 3, row < 2)
		if row == 2 and orientation == 3: plan.append_array(Walls.plan("palisade_wall", axis * 3 + Vector2.RIGHT, axis * 3 + Vector2.RIGHT * 3))
		for piece: Dictionary in plan:
			var entity := Building.instantiate() as BuildingAgent
			entity.def = Catalog.get_building(StringName(piece.building_def_id))
			entity.match_state = state
			entity.team = Enums.Team.AI if row == 1 else Enums.Team.PLAYER
			entity.civ = load("res://data/civs/teutons.tres" if row == 1 else "res://data/civs/chinese.tres")
			entity.sim_pos = piece.pos
			entity.wall_orientation = piece.orientation
			entities.add_child(entity)
			if entity.def.id == &"gate": entity.set_gate_state("open" if row == 1 else "locked")
	label_at("拖拽铺墙 · Shift 接着转弯 · G 插入城门 · R 旋转城门", Vector2(36, 1125))
	for frame in 4:
		await process_frame
		await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var result := image.save_png("res://.godot/walls-preview.png")
	viewport.free()
	print("WALL RENDER: " + error_string(result))
	quit(0 if result == OK else 1)
