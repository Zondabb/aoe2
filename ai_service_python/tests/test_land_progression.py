import json
from pathlib import Path

import jsonschema
import pytest

from brain.command_builder import CommandContext
from brain.land_progression import CATALOG, LandProgression
from brain.profile_loader import profile_for_id
from brain.stores import Blackboard, ObservationStore
from brain.tool_call_mapper import command_to_tool_call, tool_call_to_command
from protocol.models import Command, TickRequest
from tools.export_land_catalog import project_catalog

ROOT = Path(__file__).resolve().parents[2]


def building(name, entity_id=1, **extra):
    return dict(id=entity_id, kind="building", def_id=name, team=1, pos=[40, 40],
                hp=1000, max_hp=1000, is_complete=True, train_queue_empty=True,
                build_progress=0, **extra)


def board(age=0, buildings=None):
    return Blackboard(food=5000, wood=5000, gold=5000, stone=5000,
                      pop_cap=50, progression={"age": age},
                      team_buildings=buildings or [])


@pytest.mark.parametrize("op", ["research_age", "cancel_research_age", "research_technology", "cancel_technology"])
def test_research_command_round_trip_and_schema(op):
    command = Command(command_id="r1", op=op, building_id=7,
                      technology_id="man_at_arms" if op == "research_technology" else None)
    wire = tool_call_to_command(command_to_tool_call(command, 0), 1, 0)
    assert wire == command.model_dump(exclude_none=True)
    schema = json.loads((ROOT / "protocol/ai_v1.schema.json").read_text(encoding="utf8"))
    jsonschema.validate(wire, {"$ref": "#/$defs/command", "$defs": schema["$defs"]})


def test_catalog_matches_export_and_keeps_pierce_damage():
    source = json.loads((ROOT / "data/civilization_catalog.json").read_text(encoding="utf8"))
    assert CATALOG == project_catalog(source)
    assert CATALOG["units"]["chu_ko_nu"]["attack"] == 8
    assert CATALOG["units"]["scorpion"]["attack"] == 12


def test_upgrade_uses_observed_permission_and_reserves_tc():
    bb = board(buildings=[building("town_center", age_upgrade_reason="", trainable=["villager"])])
    ctx = CommandContext(tick=1)
    LandProgression().tick(ctx, bb, profile_for_id("teutons"))
    assert [(c.op, c.building_id) for c in ctx.commands] == [("research_age", 1)]
    assert bb.food == 4500


def test_training_uses_observed_tier_and_skips_research_busy():
    for busy in (True, False):
        bb = board(3, [building("barracks", trainable=["champion"], is_researching=busy)])
        ctx = CommandContext(tick=1)
        LandProgression().tick(ctx, bb, profile_for_id("chinese"))
        assert [c.unit_def_id for c in ctx.commands if c.op == "train"] == ([] if busy else ["champion"])


def test_observation_keeps_stone_progression_and_farm_building():
    request = json.loads((Path(__file__).parent / "fixtures/opening_eco.json").read_text(encoding="utf8"))["request"]
    obs = request["observation"]
    obs["economy"]["stone"] = 650
    obs["progression"] = {"age": 2, "researched_technologies": {"man_at_arms": True}}
    obs["entities"].append(building("farm", 99, resource_type="FOOD", amount=175))
    restored = TickRequest.model_validate(request).model_dump()["observation"]
    store = ObservationStore()
    store.load_from_dict(restored)
    bb = Blackboard()
    store.apply_to_blackboard(bb, 1, 0)
    assert bb.stone == 650 and bb.progression["age"] == 2
    assert any(b["id"] == 99 for b in bb.team_buildings)
    assert any(r["id"] == 99 for r in bb.resource_nodes)
