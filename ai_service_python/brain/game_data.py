from __future__ import annotations

BUILDINGS: dict[str, dict] = {
    "house": {
        "footprint": (6.0, 6.0),
        "cost_food": 0,
        "cost_wood": 30,
        "cost_gold": 0,
        "population_provided": 5,
    },
    "barracks": {
        "footprint": (3.0, 3.0),
        "cost_food": 0,
        "cost_wood": 175,
        "cost_gold": 0,
    },
    "archery_range": {
        "footprint": (3.0, 3.0),
        "cost_food": 0,
        "cost_wood": 175,
        "cost_gold": 0,
    },
    "stable": {
        "footprint": (3.0, 3.0),
        "cost_food": 0,
        "cost_wood": 175,
        "cost_gold": 0,
    },
    "town_center": {
        "footprint": (4.0, 4.0),
        "cost_food": 0,
        "cost_wood": 0,
        "cost_gold": 0,
    },
}

UNITS: dict[str, dict] = {
    "villager": {
        "cost_food": 50,
        "cost_wood": 0,
        "cost_gold": 0,
        "population": 1,
    },
    "swordsman": {
        "cost_food": 60,
        "cost_wood": 0,
        "cost_gold": 0,
        "population": 1,
    },
    "archer": {
        "cost_food": 0,
        "cost_wood": 0,
        "cost_gold": 0,
        "population": 1,
    },
    "chu_ko_nu": {
        "cost_food": 0,
        "cost_wood": 0,
        "cost_gold": 0,
        "population": 1,
    },
    "teutonic_knight": {
        "cost_food": 80,
        "cost_wood": 0,
        "cost_gold": 0,
        "population": 1,
    },
}

CIVS: dict[str, dict] = {
    "chinese": {"unique_unit": "chu_ko_nu"},
    "teutons": {"unique_unit": "teutonic_knight"},
    "default": {"unique_unit": None},
}

UNIT_TRAIN_BUILDING: dict[str, str] = {
    "villager": "town_center",
    "swordsman": "barracks",
    "archer": "archery_range",
    "chu_ko_nu": "archery_range",
    "teutonic_knight": "stable",
}
