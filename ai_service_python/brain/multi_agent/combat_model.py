"""Battle model that mirrors this game's runtime damage rules.

Source of truth: scripts/systems/combat_system.gd and scripts/data/game_catalog.gd.

* Ordinary hit: ``max(0.5, attack - armor)``; ranged weapons use pierce armor
  unless their projectile is configured to use melee armor (mangonel family).
* Class bonuses are added only for classes the attacker *actually carries at
  runtime*. The game currently loads them for rams, projectile siege and
  building weapons only, so a spearman does not receive +15 vs cavalry here.
  Observation data (entity ``combat.attack_class_bonuses`` and the decision
  catalog) always overrides the catalog defaults, so the model follows any
  future rule change without code edits.

Nothing here reads hidden state: callers pass only observed or catalog units.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
import json
import math
from pathlib import Path
from typing import Iterable

RANGED_DISTANCE_SCALE = 4.0
MOVEMENT_SPEED_SCALE = 4.0
_PATH = Path(__file__).resolve().parents[2] / "data" / "combat_catalog.json"
try:
    COMBAT_CATALOG = json.loads(_PATH.read_text(encoding="utf-8"))
except (OSError, ValueError):  # A stripped image still runs with observation data.
    COMBAT_CATALOG = {"units": {}, "buildings": {}}
SIEGE_PROJECTILES = {"mangonel": True, "onager": True, "siege_onager": True, "trebuchet": False}
RAMS = {"battering_ram", "capped_ram", "siege_ram"}
_GENERIC_CLASSES = ("UNITS_MELEE", "UNITS_PIERCE")


def unit_class(def_id: str) -> str:
    """Coarse tactical family used for doctrine, counters and intelligence."""
    record = COMBAT_CATALOG["units"].get(def_id, {})
    source, armors = record.get("source_class", ""), record.get("source_armors", {})
    if def_id == "villager" or source == "CIVILIAN":
        return "villager"
    if source in ("SIEGE_WEAPON", "SCORPION", "PACKED_SIEGE_UNITS", "PETARD") or def_id in RAMS:
        return "siege"
    if source == "PRIEST":
        return "monk"
    if source == "CAVALRY_ARCHER":
        return "cavalry_archer"
    if source in ("ARCHER", "HAND_CANNONEER"):
        return "skirmisher" if "skirmisher" in def_id else "archer"
    if source in ("CAVALRY", "SCOUT_CAVALRY"):
        return "camel" if "SHIPS_CAMELS_SABOTEURS" in armors else "cavalry"
    if "SPEARMEN" in armors:
        return "spear"
    if source == "SOLDIER":
        return "infantry"
    return "other"


def cost_value(cost: dict | None, gold_weight: float = 1.0) -> float:
    cost = cost or {}
    return max(1.0, float(cost.get("food", 0)) + float(cost.get("wood", 0))
               + gold_weight * float(cost.get("gold", 0)) + float(cost.get("stone", 0)))


@dataclass(frozen=True)
class Profile:
    def_id: str
    hp: float
    max_hp: float
    attack: float
    cooldown: float
    range: float
    min_range: float
    is_ranged: bool
    uses_melee_armor: bool
    melee_armor: float
    pierce_armor: float
    speed: float
    cost: dict = field(default_factory=dict)
    bonuses: tuple = ()
    armor_classes: tuple = ()
    klass: str = "other"
    static: bool = False

    @property
    def bonus_map(self) -> dict:
        return dict(self.bonuses)

    @property
    def armor_map(self) -> dict:
        return dict(self.armor_classes)


def _runtime_bonuses(def_id: str, record: dict, combat: dict, catalog_units: dict, building: bool) -> dict:
    if isinstance(combat.get("attack_class_bonuses"), dict):
        return combat["attack_class_bonuses"]
    runtime = catalog_units.get(def_id, {})
    if isinstance(runtime.get("attack_class_bonuses"), dict):
        return runtime["attack_class_bonuses"]
    # Mirror game_catalog.gd for catalog-only (unseen/candidate) units.
    if building or def_id in RAMS or def_id in SIEGE_PROJECTILES:
        return dict(record.get("source_attacks", {}))
    return {}


def profile(def_id: str, entity: dict | None = None, catalog_units: dict | None = None) -> Profile | None:
    """Combat profile of an observed entity or a catalog unit/building."""
    entity, catalog_units = entity or {}, catalog_units or {}
    building = entity.get("kind") == "building" or (def_id not in COMBAT_CATALOG["units"] and def_id in COMBAT_CATALOG["buildings"])
    record = COMBAT_CATALOG["buildings" if building else "units"].get(def_id, {})
    runtime = catalog_units.get(def_id, {})
    combat = entity.get("combat") if isinstance(entity.get("combat"), dict) else {}
    attack = float(combat.get("attack", runtime.get("attack", record.get("attack", 0))) or 0)
    source_range = float(record.get("attack_range", 0) or 0)
    if building:
        ranged = attack > 0
        reach = source_range * RANGED_DISTANCE_SCALE
        min_reach = float(record.get("min_range", 0) or 0) * RANGED_DISTANCE_SCALE
        uses_melee = False
    else:
        source_range = max(.4, source_range)
        ranged = source_range > 1.5 or def_id in SIEGE_PROJECTILES
        reach = source_range * RANGED_DISTANCE_SCALE if ranged else source_range
        min_reach = float(record.get("min_range", 0) or 0) * RANGED_DISTANCE_SCALE if ranged else 0.0
        uses_melee = SIEGE_PROJECTILES.get(def_id, False)
    if "range" in combat:
        reach = float(combat["range"])
    elif "attack_range" in runtime:
        reach = float(runtime["attack_range"])
    min_reach = float(combat.get("minimum_range", runtime.get("minimum_range", min_reach)) or 0)
    ranged = bool(combat.get("is_ranged", runtime.get("is_ranged", ranged)))
    if not record and not combat and not runtime:
        return None
    max_hp = float(entity.get("max_hp", record.get("hp", 30)) or 1)
    hp = float(entity.get("hp", max_hp))
    bonuses = _runtime_bonuses(def_id, record, combat, catalog_units, building)
    return Profile(
        def_id=def_id, hp=max(0.0, hp), max_hp=max(1.0, max_hp), attack=max(0.0, attack),
        cooldown=max(.1, float(combat.get("cooldown", runtime.get("cooldown", record.get("cooldown", 2))) or 2)),
        range=max(.4, reach), min_range=max(0.0, min_reach), is_ranged=ranged, uses_melee_armor=uses_melee,
        melee_armor=float(combat.get("melee_armor", record.get("melee_armor", 0)) or 0),
        pierce_armor=float(combat.get("pierce_armor", record.get("pierce_armor", 0)) or 0),
        speed=0.0 if building else max(.1, float(record.get("speed", .8))) * MOVEMENT_SPEED_SCALE,
        cost=dict(runtime.get("cost", record.get("cost", {})) or {}),
        bonuses=tuple(sorted((str(k), float(v)) for k, v in bonuses.items() if isinstance(v, (int, float)))),
        armor_classes=tuple(sorted((str(k), float(v)) for k, v in record.get("source_armors", {}).items() if isinstance(v, (int, float)))),
        klass="building" if building else unit_class(def_id), static=building)


def damage(attacker: Profile, target: Profile) -> float:
    """One hit, exactly as CombatSystem.apply_hit computes it."""
    if attacker.attack <= 0:
        return 0.0
    armor = target.pierce_armor if attacker.is_ranged and not attacker.uses_melee_armor else target.melee_armor
    value = max(.5, attacker.attack - armor)
    armors = target.armor_map
    for armor_class, bonus in attacker.bonuses:
        if armor_class in _GENERIC_CLASSES or armor_class not in armors:
            continue
        value += max(0.0, bonus - armors[armor_class])
    return value


def dps(attacker: Profile, target: Profile) -> float:
    return damage(attacker, target) / attacker.cooldown


def _approach_bonus(shooter: Profile, runner: Profile) -> float:
    """Free volleys a ranged unit gets while a melee unit closes the distance."""
    if not shooter.is_ranged or runner.is_ranged or runner.speed <= 0:
        return 1.0
    return 1.0 + min(.6, .06 * shooter.range / max(.3, runner.speed))


def trade_efficiency(unit: Profile, enemy: Profile, gold_weight: float = 1.0) -> float:
    """Lanchester-square equal-spend duel. >1 means ``unit`` wins per resource."""
    alpha = dps(unit, enemy) / max(1.0, enemy.max_hp) * _approach_bonus(unit, enemy)
    beta = dps(enemy, unit) / max(1.0, unit.max_hp) * _approach_bonus(enemy, unit)
    if alpha <= 0:
        return .01
    if beta <= 0:
        return 100.0
    return math.sqrt(alpha / beta) * cost_value(enemy.cost, gold_weight) / cost_value(unit.cost, gold_weight)


@dataclass
class Forecast:
    winner: str
    own_survival: float
    enemy_survival: float
    seconds: float
    own_value_lost: float
    enemy_value_lost: float
    own_strength: float
    enemy_strength: float

    def as_dict(self) -> dict:
        return {"winner": self.winner, "own_survival": round(self.own_survival, 2),
                "enemy_survival": round(self.enemy_survival, 2), "seconds": round(self.seconds, 1),
                "own_value_lost": round(self.own_value_lost), "enemy_value_lost": round(self.enemy_value_lost)}

    @property
    def decisive_loss(self) -> bool:
        return self.winner == "enemy" and self.own_survival <= .05 and self.enemy_survival >= .4


class _Group:
    __slots__ = ("profile", "hp", "unit_hp", "value", "start_hp")

    def __init__(self, profile: Profile, count: float, hp: float):
        self.profile, self.hp, self.start_hp = profile, hp, hp
        self.unit_hp = profile.max_hp
        self.value = cost_value(profile.cost) * count / max(1e-6, hp) if hp > 0 else 0.0

    @property
    def alive(self) -> float:
        return 0.0 if self.hp <= 0 else self.hp / self.unit_hp


def _groups(units: Iterable[Profile]) -> list[_Group]:
    pooled: dict[str, list[Profile]] = {}
    for unit in units:
        if unit is not None and unit.hp > 0:
            pooled.setdefault(unit.def_id, []).append(unit)
    groups = []
    for members in pooled.values():
        hp = sum(m.hp for m in members)
        groups.append(_Group(members[0], len(members), hp))
    return groups


def simulate(own: Iterable[Profile], enemy: Iterable[Profile], own_support: Iterable[Profile] = (),
             enemy_support: Iterable[Profile] = (), max_seconds: float = 90.0, step: float = 1.0,
             gap: float | None = None) -> Forecast:
    """Aggregate fight between unit groups; static weapons shoot but are not targeted.

    Each group spreads fire across living enemy groups in proportion to their
    remaining unit count. Melee groups start hitting only after closing the
    distance: ``gap`` (the current distance between the forces) when known,
    otherwise the longest opposing weapon range. Once melee has closed in, a
    weapon with a minimum range (mangonel family) can no longer hit it. This is
    an estimate for decisions, not a replacement for the game's simulation.
    """
    sides = [_groups(own), _groups(enemy)]
    supports = [[s for s in own_support if s and s.attack > 0], [s for s in enemy_support if s and s.attack > 0]]
    start = [sum(g.hp for g in side) for side in sides]
    value0 = [sum(g.value * g.hp for g in side) for side in sides]
    if not sides[0] or not sides[1]:
        winner = "own" if sides[0] else "enemy" if sides[1] else "none"
        return Forecast(winner, 1.0 if sides[0] else 0.0, 1.0 if sides[1] else 0.0, 0.0, 0.0, 0.0,
                        start[0], start[1])
    reach = [max((g.profile.range for g in side if g.profile.is_ranged), default=0.0) for side in sides]

    def closing(group: _Group, index: int) -> float:
        distance = reach[1 - index] if gap is None else max(0.0, gap - group.profile.range)
        if group.profile.is_ranged and gap is None:
            return 0.0
        return min(8.0, distance / max(.3, group.profile.speed))

    delays = [{id(g): closing(g, index) for g in side} for index, side in enumerate(sides)]
    elapsed = 0.0
    while elapsed < max_seconds and all(any(g.hp > 0 for g in side) for side in sides):
        incoming = [Counter(), Counter()]
        for index, side in enumerate(sides):
            targets = [g for g in sides[1 - index] if g.hp > 0]
            weight = sum(g.alive for g in targets)
            shooters = [(g.profile, g.alive, delays[index][id(g)]) for g in side if g.hp > 0]
            shooters += [(s, 1.0, 0.0) for s in supports[index]]
            for shooter, count, delay in shooters:
                if elapsed < delay:
                    continue
                for target in targets:
                    if (shooter.min_range > 0 and not target.profile.is_ranged
                            and (elapsed >= delays[1 - index][id(target)] or gap is not None and gap < shooter.min_range)):
                        continue  # melee is inside the blind spot
                    incoming[1 - index][id(target)] += count * dps(shooter, target.profile) * step * target.alive / max(1e-6, weight)
        for index, side in enumerate(sides):
            for group in side:
                group.hp = max(0.0, group.hp - incoming[index][id(group)])
        elapsed += step
    remaining = [sum(g.hp for g in side) for side in sides]
    value_left = [sum(g.value * g.hp for g in side) for side in sides]
    survival = [remaining[i] / max(1e-6, start[i]) for i in (0, 1)]
    if survival[0] > 0 and survival[1] <= 0:
        winner = "own"
    elif survival[1] > 0 and survival[0] <= 0:
        winner = "enemy"
    else:
        winner = "own" if survival[0] > survival[1] + .1 else "enemy" if survival[1] > survival[0] + .1 else "stalemate"
    return Forecast(winner, survival[0], survival[1], elapsed, value0[0] - value_left[0], value0[1] - value_left[1],
                    start[0], start[1])
