from brain.build_placement import can_place, can_plan_settlement, next_build_position, footprint_visible


DEFINITIONS = {
    "town_center": {"footprint": [4, 4]},
    "house": {"footprint": [2, 2]},
    "barracks": {"footprint": [3, 3]},
    "castle": {"footprint": [4, 4]},
}
BOUNDS = (-240.0, -180.0, 240.0, 180.0)


def test_planned_spacing_does_not_change_player_build_legality():
    tc = {"def_id": "town_center", "pos": [0, 0]}
    assert can_place("house", (6, 0), [tc], DEFINITIONS)
    assert not can_plan_settlement("house", (6, 0), [tc], DEFINITIONS)
    assert can_plan_settlement("house", (16, 0), [tc], DEFINITIONS)
    assert not can_plan_settlement("house", (15.99, 0), [tc], DEFINITIONS)


def test_settlement_keeps_clear_lanes_between_mixed_buildings():
    tc = {"def_id": "town_center", "pos": [-100, -80]}
    buildings = [tc]
    for slot, name in enumerate(["house", "barracks", "house", "castle", "house"] * 5):
        position = next_build_position(name, tc, buildings, slot, DEFINITIONS, map_bounds=BOUNDS)
        assert position is not None
        assert position == next_build_position(name, tc, buildings, slot, DEFINITIONS, map_bounds=BOUNDS)
        assert can_plan_settlement(name, position, buildings, DEFINITIONS, map_bounds=BOUNDS)
        buildings.append({"def_id": name, "pos": list(position)})
    for index, building in enumerate(buildings[1:], 1):
        assert can_plan_settlement(building["def_id"], tuple(building["pos"]), buildings[:index], DEFINITIONS)


def test_observed_resources_keep_gathering_space_and_empty_nodes_release_it():
    tree = {"kind": "resource", "resource_type": "WOOD", "pos": [16, 0], "amount": 100}
    assert not can_plan_settlement("house", (16, 0), [], DEFINITIONS, [tree])
    assert not can_plan_settlement("house", (24, 0), [], DEFINITIONS, [tree])
    assert can_plan_settlement("house", (32, 0), [], DEFINITIONS, [tree])
    tree["amount"] = 0
    assert can_plan_settlement("house", (16, 0), [], DEFINITIONS, [tree])
    farm = {"kind": "building", "def_id": "farm", "pos": [16, 0], "amount": 100}
    assert can_plan_settlement("house", (16, 0), [], DEFINITIONS, [farm])


def test_resource_blocked_first_slot_moves_to_other_side_of_town_center():
    tc = {"def_id": "town_center", "pos": [-100, -80]}
    resource = {"kind": "resource", "resource_type": "GOLD", "pos": [-84, -80], "amount": 800}
    assert next_build_position("house", tc, [tc], 0, DEFINITIONS, [resource], BOUNDS) == (-100, -64)


def test_rectangular_boundaries_keep_visual_extent_and_lane_inside_map():
    assert can_plan_settlement("house", (232, 172), [], DEFINITIONS, map_bounds=BOUNDS)
    assert not can_plan_settlement("house", (232.01, 172), [], DEFINITIONS, map_bounds=BOUNDS)
    assert not can_plan_settlement("house", (232, 172.01), [], DEFINITIONS, map_bounds=BOUNDS)
    tc = {"def_id": "town_center", "pos": [225, 165]}
    position = next_build_position("house", tc, [tc], 0, DEFINITIONS, map_bounds=BOUNDS)
    assert position is not None
    assert position[0] < 225 or position[1] < 165
    assert can_plan_settlement("house", position, [tc], DEFINITIONS, map_bounds=BOUNDS)


def test_small_map_returns_none_instead_of_building_outside_map():
    tc = {"def_id": "town_center", "pos": [0, 0]}
    assert next_build_position("house", tc, [tc], 0, DEFINITIONS, map_bounds=(-10, -10, 10, 10)) is None
    assert next_build_position("unknown", tc, [tc], 0, DEFINITIONS) is None


def test_fog_checks_entire_footprint_and_can_use_overlapping_sight_sources():
    visibility = {"origin": [-20, -20], "cell_size": 4, "grid_size": [10, 10], "sources": [[0, 0, 5]]}
    assert footprint_visible((0, 0), (2, 2), visibility)
    assert not footprint_visible((4, 0), (8, 8), visibility)
    visibility["sources"].append([4, 0, 5])
    assert footprint_visible((4, 0), (8, 8), visibility)
    assert not footprint_visible((20, 0), (2, 2), visibility)


def test_planner_skips_unseen_site_for_a_visible_alternative():
    tc = {"def_id": "town_center", "pos": [0, 0]}
    visibility = {"origin": [-100, -100], "cell_size": 4, "grid_size": [50, 50], "sources": [[0, 16, 5]]}
    assert next_build_position("house", tc, [tc], 0, DEFINITIONS, placement_visibility=visibility) == (0, 16)
    visibility["sources"] = []
    assert next_build_position("house", tc, [tc], 0, DEFINITIONS, placement_visibility=visibility) is None
