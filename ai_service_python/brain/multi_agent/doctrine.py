"""Strategic doctrines, counter composition and doctrine recommendations.

A doctrine is a bounded strategic intent chosen by the commander model. The
executor translates it into deterministic modifiers that every specialist
reads; it never grants resources or bypasses Godot validation. ``adaptive``
keeps the established default behaviour and only adds counter composition.
"""
from __future__ import annotations

from collections import Counter
import math

from .combat_model import COMBAT_CATALOG, cost_value, profile, trade_efficiency, unit_class

DOCTRINES = ("adaptive", "rush", "boom", "fast_castle", "timing_push", "turtle")
COMPOSITIONS = ("counter", "infantry", "archers", "cavalry", "knights", "mixed")
TARGET_PRIORITIES = ("army", "economy", "buildings")
NON_COMBAT = {"villager", "petard", "trade_cart", "monk"}

DOCTRINE_EFFECTS = {
    "adaptive": {},
    # Hit before the opponent's economy pays off; raid workers, keep ages low.
    "rush": {"muster_cap": 40, "sortie_cap": 5, "age_cap_before_sortie": 1, "raid_economy": True},
    # Out-scale: more villagers, delay the first sortie, still age up.
    "boom": {"worker_bonus": 12, "muster_floor": 100, "min_target_age": 2, "tech_budget_floor": .5},
    # Reach castle-age units and siege quickly with a modest guard.
    "fast_castle": {"worker_bonus": 4, "min_target_age": 2, "tech_budget_floor": .65, "sortie_cap": 6},
    # One strong, siege-supported push instead of trickling small waves.
    "timing_push": {"worker_bonus": 6, "sortie_floor": 12, "muster_floor": 90, "min_target_age": 2, "siege_with_sortie": True},
    # Absorb pressure under the TC and walls, then counter-attack.
    "turtle": {"worker_bonus": 6, "defense_policy": "fortify", "defend_stance": True, "min_target_age": 2},
}
DOCTRINE_GUIDE = (
    "strategy picks the team doctrine: adaptive=default timing plus automatic counter-units; "
    "rush=early small raids on enemy villagers before they age up; boom=more villagers and a later, bigger army; "
    "fast_castle=prioritise castle age and siege; timing_push=one large siege-backed push; "
    "turtle=fortify and defend under the TC, then counter. Prefer intel.recommended_doctrine unless your own "
    "evidence disagrees, and use strategic_memory records of what has worked before."
)
COMPOSITION_CLASSES = {
    "infantry": {"infantry", "spear"},
    "archers": {"archer", "skirmisher", "cavalry_archer"},
    "cavalry": {"cavalry", "camel", "cavalry_archer"},
}


def effects(strategy: str) -> dict:
    return dict(DOCTRINE_EFFECTS.get(strategy, {}))


def counter_scores(candidates: list[str], enemy_army: Counter, catalog_units: dict | None = None,
                   gold_weight: float = 1.0) -> list[dict]:
    """Rank trainable units by value-weighted log trade efficiency."""
    catalog_units = catalog_units or {}
    enemies = [(profile(name, catalog_units=catalog_units), count) for name, count in enemy_army.items() if count > 0]
    enemies = [(p, count) for p, count in enemies if p is not None and p.attack >= 0]
    if not enemies:
        return []
    weights = [cost_value(p.cost) * count for p, count in enemies]
    total = max(1e-6, sum(weights))
    ranked = []
    for name in dict.fromkeys(candidates):
        if name in NON_COMBAT:
            continue
        own = profile(name, catalog_units=catalog_units)
        if own is None or own.attack <= 0 or unit_class(name) == "siege":
            continue
        score = sum(w * math.log(max(.01, trade_efficiency(own, enemy, gold_weight))) for (enemy, _), w in zip(enemies, weights)) / total
        record = COMBAT_CATALOG["units"].get(name, {})
        ranked.append({"unit": name, "score": round(score, 3), "class": unit_class(name),
                       "producer": record.get("train_at", catalog_units.get(name, {}).get("train_at", ""))})
    return sorted(ranked, key=lambda item: -item["score"])


def recommend_doctrine(styles: list[str], now: float, own_military: int, enemy_army_size: int,
                       memory: dict | None = None) -> dict:
    """Deterministic advice the commander model may accept or overrule."""
    memory = memory or {}
    by_style = memory.get("record_vs_style", {})
    for style in styles:
        best, best_rate = None, .6
        for strategy, record in by_style.get(style, {}).items():
            games = record.get("wins", 0) + record.get("losses", 0)
            rate = record.get("wins", 0) / games if games else 0
            if games >= 2 and rate >= best_rate and strategy in DOCTRINES:
                best, best_rate = strategy, rate
        if best:
            return {"strategy": best, "why": f"won {best_rate:.0%} of past games against {style}"}
    if "early_aggression" in styles and now < 720 and own_military <= enemy_army_size:
        return {"strategy": "turtle", "why": "enemy committed early; defend under TC fire, then counter-attack"}
    if "boom" in styles:
        if enemy_army_size <= 2:
            return {"strategy": "rush", "why": "greedy enemy economy with almost no army; raid villagers now"}
        return {"strategy": "timing_push", "why": "punish the boom with one strong push before it pays off"}
    if "turtle" in styles:
        return {"strategy": "fast_castle", "why": "fortifications need castle-age siege; out-scale behind them"}
    if "siege_push" in styles:
        return {"strategy": "timing_push", "why": "enemy siege is slow and fragile; meet it with a concentrated army"}
    return {"strategy": "adaptive", "why": "no decisive enemy signal yet; keep default timing and counter-build"}
