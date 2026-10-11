extends SceneTree

const Ui := preload("res://scripts/presentation/ui_catalog.gd")
const Catalog := preload("res://scripts/data/game_catalog.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error(message)

func _run() -> void:
	var first := Ui.atlas_frame(Ui.ICONS_UNITS_BASE, Ui.FRAME_UNIT_VILLAGER) as AtlasTexture
	check(first != null, "packaged villager portrait loads")
	if first != null:
		var reused := true
		for _repeat in 120:
			reused = reused and Ui.atlas_frame(Ui.ICONS_UNITS_BASE, Ui.FRAME_UNIT_VILLAGER) == first
		check(reused, "repeated HUD refresh reuses the existing portrait")
		var other := Ui.atlas_frame(Ui.ICONS_UNITS_BASE, Ui.FRAME_UNIT_ARCHER) as AtlasTexture
		check(other != first and other.atlas == first.atlas, "different icon frames share the sheet without sharing the crop")
		var meta := Ui.load_meta(Ui.ICONS_UNITS_BASE)
		check(is_same(meta, Ui.load_meta(Ui.ICONS_UNITS_BASE)), "packaged metadata is parsed once")
		var columns := int(meta.cols)
		var expected := Rect2((Ui.FRAME_UNIT_VILLAGER % columns) * int(meta.frame_w),
			int(Ui.FRAME_UNIT_VILLAGER / columns) * int(meta.frame_h), int(meta.frame_w), int(meta.frame_h))
		check(first.region == expected, "cached portrait retains the original exported frame crop")
		var reference := AtlasTexture.new()
		reference.atlas = Ui.load_texture(Ui.ICONS_UNITS_BASE)
		reference.region = expected
		check(first.get_image().get_data() == reference.get_image().get_data(), "cached portrait keeps the same visible pixels")
	check(_test_portrait_switches(), "all selection, civilization, and age checks complete")
	var missing := "res://assets/sprites/ui/missing_cache_fixture"
	check(Ui.atlas_frame(missing, 0) == null and Ui.atlas_frame(missing, 0) == null,
		"missing optional UI art stays safe on repeated refresh")
	check(Ui.load_meta(missing).is_empty() and Ui.load_texture(missing) == null,
		"missing optional sheet preserves the fallback behavior")
	print("UI asset cache: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _test_portrait_switches() -> bool:
	var state := MatchState.new()
	state.setup_defaults()
	state.progression_enabled = true
	# Load after autoload startup, like the scene-based HUD regression runners.
	var hud := load("res://scripts/ui/hud_controller.gd").new() as Control
	hud.set("match_state", state)
	var town := BuildingAgent.new()
	town.def = load("res://data/buildings/town_center.tres")
	town.civ = load("res://data/civs/teutons.tres")
	var dark: Texture2D = hud.call("_entity_portrait", town)
	check(dark == Ui.atlas_frame(Catalog.building_sheet(&"town_center", &"teutons", Enums.Age.DARK), 0),
		"selected town center uses its civilization and current age")
	state.set_age(Enums.Team.PLAYER, Enums.Age.FEUDAL)
	var feudal: Texture2D = hud.call("_entity_portrait", town)
	check(feudal != dark and feudal == Ui.atlas_frame(Catalog.building_sheet(&"town_center", &"teutons", Enums.Age.FEUDAL), 0),
		"age upgrade changes selected portrait to the new building sheet")
	town.civ = load("res://data/civs/chinese.tres")
	var chinese: Texture2D = hud.call("_entity_portrait", town)
	check(chinese != feudal and chinese == Ui.atlas_frame(Catalog.building_sheet(&"town_center", &"chinese", Enums.Age.FEUDAL), 0),
		"switching civilizations does not reuse the previous civilization portrait")
	town.civ = load("res://data/civs/teutons.tres")
	state.set_age(Enums.Team.PLAYER, Enums.Age.DARK)
	check(hud.call("_entity_portrait", town) == dark, "returning to a sheet reuses its correct portrait")
	var unit := UnitAgent.new()
	unit.def = load("res://data/units/villager.tres")
	check(hud.call("_entity_portrait", unit) == Ui.atlas_frame(Ui.ICONS_UNITS_BASE, Ui.FRAME_UNIT_VILLAGER),
		"switching selection from a building to a unit uses the unit icon")
	unit.free()
	town.free()
	hud.free()
	return true
