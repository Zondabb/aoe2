extends SceneTree

const BUILDING := preload("res://scenes/entities/building_view.tscn")
const UNIT := preload("res://scenes/entities/unit_view.tscn")
const FARM := preload("res://scripts/entities/farm_agent.gd")
const SPRITES := preload("res://scripts/presentation/sprite_catalog.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var entities := Node2D.new()
	root.add_child(entities)
	var state := MatchState.new()
	state.setup_defaults()
	state.fog_enabled = false
	state.progression_enabled = true
	for civ_id in [&"chinese", &"teutons"]:
		var farm := BUILDING.instantiate() as BuildingAgent
		farm.set_script(FARM)
		farm.def = GameCatalog.get_building(&"farm")
		farm.civ = load("res://data/civs/%s.tres" % civ_id)
		farm.match_state = state
		farm.sim_pos = Vector2(10, 10)
		farm.start_construction()
		entities.add_child(farm)
		var worker := UNIT.instantiate() as UnitAgent
		worker.def = GameCatalog.get_unit(&"villager")
		worker.match_state = state
		worker.civ = farm.civ
		worker.sim_pos = farm.sim_pos
		entities.add_child(worker)
		worker.set_physics_process(false)
		var bare := SPRITES.foundation_sheet_base(&"farm", civ_id, 0)
		var crops := SPRITES.building_sheet_base(&"farm", civ_id, 0)
		check(not farm.farm_has_crops and farm._sprite_sheet_base == bare, "new construction is bare soil")
		check(float(farm.call("extract", 1.0)) == 0.0 and not farm.farm_has_crops, "construction cannot grow or harvest crops")
		worker.command_build(farm)
		worker._process_build(farm.def.build_time)
		check(farm.is_complete and worker.order == Enums.OrderType.GATHER, "farm builder automatically begins gathering on completion")
		check(farm._sprite_sheet_base == bare and not farm.farm_has_crops, "completion alone keeps soil bare")
		check(farm.amount == 175.0 and worker.carry_amount == 0.0, "building completion does not extract food")
		worker._process_gather(0.1)
		check(worker._gather_state == "gathering" and not farm.farm_has_crops, "reaching the field does not extract food early")
		worker._process_gather(0.1)
		check(farm.farm_has_crops and farm._sprite_sheet_base == crops, "first actual gathering tick displays crops")
		check(worker.carry_amount > 0.0 and farm.amount < 175.0, "crops appear together with actual food gathering")
		worker.command_stop()
		check(farm.farm_has_crops and farm._sprite_sheet_base == crops, "worker departure does not remove existing crops")
		for age in 4:
			state.set_age(0, age)
			check(farm._sprite_sheet_base == crops, "age changes preserve a cultivated field")
		farm.start_construction()
		check(not farm.farm_has_crops and farm._sprite_sheet_base == bare, "reconstruction resets the field to bare soil")
		farm.add_build_progress(farm.def.build_time)
		check(float(farm.call("extract", 0.0)) == 0.0 and not farm.farm_has_crops, "zero-time extraction does not grow crops")
		check(float(farm.call("extract", -1.0)) == 0.0 and not farm.farm_has_crops, "negative-time extraction does not grow crops")
		var sprite := farm.get_node("Billboard") as Sprite2D
		check(sprite.scale.is_equal_approx(Vector2.ONE * SPRITES.ORIGINAL_ART_PIXEL_SCALE_2D), "farm retains original artwork scale relative to villagers")
		check(is_equal_approx(sprite.texture.get_width() * sprite.scale.x, 345.6), "native three-tile field is no longer squeezed to 132 pixels")
		check(sprite.z_index < (worker.get_node("GroundShadow") as CanvasItem).z_index, "larger bare soil remains below villagers and their foot shadows")
		farm.is_placement_ghost = true
		farm._configure_visuals()
		check(float(farm.call("extract", 1.0)) == 0.0 and farm._sprite_sheet_base == bare, "placement preview cannot harvest or show crops")
		var house := BUILDING.instantiate() as BuildingAgent
		house.def = GameCatalog.get_building(&"house")
		house.match_state = state
		house.sim_pos = worker.sim_pos
		house.start_construction()
		entities.add_child(house)
		worker.command_build(house)
		worker._process_build(house.def.build_time)
		check(house.is_complete and worker.order == Enums.OrderType.NONE, "ordinary building completion still leaves the builder idle")
		house.free()
		worker.free()
		farm.free()
	entities.free()
	print("FARM LIFECYCLE: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
