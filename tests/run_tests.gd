# tests/run_tests.gd
extends SceneTree

func _initialize() -> void:
	var failures: Array[String] = []
	failures.append_array(load("res://tests/test_combat_math.gd").new().run())
	failures.append_array(load("res://tests/test_combat_system.gd").new().run())
	failures.append_array(load("res://tests/test_projectile_impact.gd").new().run())
	failures.append_array(load("res://tests/test_combat_visual.gd").new().run())
	failures.append_array(load("res://tests/test_combat_arena.gd").new().run())
	failures.append_array(load("res://tests/test_combat_duel_arena.gd").new().run())
	failures.append_array(load("res://tests/test_civ_defs.gd").new().run())
	failures.append_array(load("res://tests/test_match_state.gd").new().run())
	failures.append_array(load("res://tests/test_match_2d.gd").new().run())
	failures.append_array(load("res://tests/test_economy.gd").new().run())
	failures.append_array(load("res://tests/test_buildings.gd").new().run())
	failures.append_array(load("res://tests/test_ai_controller.gd").new().run())
	failures.append_array(load("res://tests/test_ai_profile.gd").new().run())
	failures.append_array(load("res://tests/test_ai_vs_ai.gd").new().run())
	failures.append_array(load("res://tests/test_sprite_catalog.gd").new().run())
	failures.append_array(load("res://tests/test_collision_resolver.gd").new().run())
	failures.append_array(load("res://tests/test_locomotion.gd").new().run())
	failures.append_array(load("res://tests/test_nav_grid_service.gd").new().run())
	failures.append_array(load("res://tests/test_vision_service.gd").new().run())
	failures.append_array(load("res://tests/test_auto_combat_director.gd").new().run())
	failures.append_array(load("res://tests/test_command_panel.gd").new().run())
	if failures.is_empty():
		print("ALL TESTS PASSED")
		quit(0)
	else:
		for f in failures:
			push_error(f)
		print("TESTS FAILED: ", failures.size())
		quit(1)
