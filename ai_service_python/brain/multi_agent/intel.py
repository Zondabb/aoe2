"""Opponent model built only from this team's observations and visible events.

It answers the questions a strong player asks continuously: what has the enemy
fielded, what are they likely doing, who is winning the trades, and which age
are they in. Unit estimates use distinct entity IDs seen recently that have not
been observed dying; nothing is inferred from hidden state.
"""
from __future__ import annotations

from collections import Counter, deque
import math

from .combat_model import COMBAT_CATALOG, cost_value, unit_class

UNIT_MEMORY_SEC = 180.0
EARLY_AGGRESSION_SEC = 480.0
UNIQUE_UNIT_CIVS = {"chu_ko_nu": "chinese", "elite_chu_ko_nu": "chinese",
                    "teutonic_knight": "teutons", "elite_teutonic_knight": "teutons"}
DEFENSIVE_BUILDINGS = {"watch_tower", "guard_tower", "keep", "castle", "palisade_wall", "stone_wall",
                       "fortified_wall", "gate", "palisade_gate", "stone_gate"}
MILITARY_CLASSES = ("infantry", "spear", "archer", "skirmisher", "cavalry", "camel", "cavalry_archer", "siege", "monk")


def _required_age(def_id: str) -> int:
    for section in ("units", "buildings"):
        record = COMBAT_CATALOG.get(section, {}).get(def_id)
        if record is not None:
            return int(record.get("required_age", 0) or 0)
    return 0


class OpponentModel:
    def __init__(self) -> None:
        self.units: dict[int, dict] = {}          # enemy unit id -> sighting
        self.dead: set[int] = set()
        self.own_snapshot: dict[int, str] = {}     # own entity id -> def_id (previous frame)
        self.kills: Counter = Counter()
        self.losses: Counter = Counter()
        self.kill_value = 0.0
        self.loss_value = 0.0
        self.ledger: deque = deque(maxlen=400)     # (time, "kill"/"loss", def_id, value)
        self.stock_history: deque = deque(maxlen=180)
        self.timeline: deque = deque(maxlen=16)
        self.first_military_at: float | None = None
        self.first_near_base_at: float | None = None
        self.peak_villagers = 0
        self.max_enemy_age = 0
        self.civ_guess: str | None = None
        self.styles: list[str] = []
        self.evidence: list[str] = []
        self.seen_classes: set[str] = set()
        self.now = 0.0

    # ------------------------------------------------------------------ update
    def update(self, f, enemy_knowledge: dict, reports: list[dict], now: float) -> list[str]:
        """Consume one frame; return human-readable intelligence changes."""
        self.now = now
        notes: list[str] = []
        visible_enemy = [e for e in f.obs.entities if f.enemy(e)]
        villagers_now = 0
        for entity in visible_enemy:
            def_id = str(entity.get("def_id", "unknown"))
            age = _required_age(def_id)
            if age > self.max_enemy_age:
                self.max_enemy_age = age
                notes.append(f"enemy_age_at_least:{age} ({def_id})")
            civ = UNIQUE_UNIT_CIVS.get(def_id)
            if civ and civ != self.civ_guess:
                self.civ_guess = civ
                notes.append(f"enemy_civilization:{civ}")
            if entity.get("kind") != "unit":
                continue
            klass = unit_class(def_id)
            if klass == "villager":
                villagers_now += 1
            sighting = self.units.get(entity["id"])
            if sighting is None:
                self.units[entity["id"]] = sighting = {"def_id": def_id, "first_seen": now, "class": klass}
                if klass in MILITARY_CLASSES and klass not in self.seen_classes:
                    self.seen_classes.add(klass)
                    notes.append(f"new_enemy_unit_type:{def_id}")
                    self.timeline.append(f"{now:.0f}s first {def_id}")
            sighting.update(last_seen=now, pos=list(entity.get("pos", [0, 0])), hp=float(entity.get("hp", 0)))
            if klass in MILITARY_CLASSES:
                if self.first_military_at is None:
                    self.first_military_at = now
                if self.first_near_base_at is None and math.dist(entity.get("pos", [1e9, 1e9]), f.base) < 30:
                    self.first_near_base_at = now
                    self.timeline.append(f"{now:.0f}s enemy army near our base")
                    notes.append("enemy_military_reached_our_base")
        self.peak_villagers = max(self.peak_villagers, villagers_now)
        # Deaths: visible events for enemies, snapshot difference for our own.
        # Exhausted farms are removed by the game without any combat; skip them.
        current_own = {e["id"]: str(e.get("def_id", "unknown")) for e in f.units + f.buildings if e.get("def_id") != "farm"}
        for report in reports:
            if report.get("type") not in ("entity_died", "entity_destroyed", "building_destroyed"):
                continue
            eid = report.get("entity_id")
            if eid in self.units and eid not in self.dead:
                self._record("kill", self.units[eid]["def_id"])
                self.dead.add(eid)
                self.units.pop(eid, None)
            elif eid in self.own_snapshot and eid not in current_own:
                self._record("loss", self.own_snapshot.pop(eid))
        for eid, def_id in list(self.own_snapshot.items()):
            if eid not in current_own:
                self._record("loss", def_id)
        self.own_snapshot = current_own
        for eid, sighting in list(self.units.items()):
            if now - sighting["last_seen"] > UNIT_MEMORY_SEC * 2:
                self.units.pop(eid, None)
        economy = f.obs.economy
        self.stock_history.append((now, {r: float(getattr(economy, r, 0)) for r in ("food", "wood", "gold", "stone")}))
        previous = set(self.styles)
        self._classify(enemy_knowledge)
        for style in sorted(set(self.styles) - previous):
            notes.append(f"enemy_style:{style}")
            self.timeline.append(f"{now:.0f}s assessed {style}")
        return notes

    def _record(self, kind: str, def_id: str) -> None:
        record = COMBAT_CATALOG["units"].get(def_id) or COMBAT_CATALOG["buildings"].get(def_id) or {}
        value = cost_value(record.get("cost"))
        if kind == "kill":
            self.kills[def_id] += 1
            self.kill_value += value
        else:
            self.losses[def_id] += 1
            self.loss_value += value
        self.ledger.append((self.now, kind, def_id, value))

    # ------------------------------------------------------------- estimates
    def estimated_army(self) -> Counter:
        """Distinct, not-known-dead enemy military seen in the memory window."""
        return Counter(s["def_id"] for s in self.units.values()
                       if s["class"] in MILITARY_CLASSES and self.now - s["last_seen"] <= UNIT_MEMORY_SEC)

    def class_mix(self) -> Counter:
        mix = Counter()
        for def_id, count in self.estimated_army().items():
            mix[unit_class(def_id)] += count
        return mix

    def army_value(self) -> float:
        return sum(cost_value((COMBAT_CATALOG["units"].get(name) or {}).get("cost")) * count
                   for name, count in self.estimated_army().items())

    def _classify(self, enemy_knowledge: dict) -> None:
        styles, evidence = [], []
        army = self.estimated_army()
        mix = self.class_mix()
        total = sum(mix.values())
        if self.first_near_base_at is not None and self.first_near_base_at <= EARLY_AGGRESSION_SEC:
            styles.append("early_aggression")
            evidence.append(f"enemy army reached our base at {self.first_near_base_at:.0f}s")
        elif self.first_military_at is not None and self.first_military_at <= EARLY_AGGRESSION_SEC * .75 and total >= 3:
            styles.append("early_aggression")
            evidence.append(f"{total} enemy soldiers fielded by {self.first_military_at:.0f}s")
        families = {"archer_focus": ("archer", "cavalry_archer"), "cavalry_focus": ("cavalry", "camel"),
                    "infantry_focus": ("infantry", "spear")}
        if total >= 3:
            for style, classes in families.items():
                share = sum(mix[c] for c in classes) / total
                if share >= .55:
                    styles.append(style)
                    evidence.append(f"{share:.0%} of observed army is {'/'.join(classes)}")
        if mix["siege"]:
            styles.append("siege_push")
            evidence.append(f"{mix['siege']} enemy siege units observed")
        buildings = Counter(e.get("def_id") for e in enemy_knowledge.values() if e.get("kind") == "building")
        defensive = sum(buildings[name] for name in DEFENSIVE_BUILDINGS)
        if defensive >= 6 and total <= 4:
            styles.append("turtle")
            evidence.append(f"{defensive} enemy fortifications with a small field army")
        if (buildings["town_center"] >= 2 or self.peak_villagers >= 18) and total <= 3 and self.now >= 300:
            styles.append("boom")
            evidence.append(f"{buildings['town_center']} enemy TCs, up to {self.peak_villagers} villagers seen, little army")
        self.styles, self.evidence = styles, evidence[:5]

    def income_estimate(self, window: float = 60.0) -> dict:
        """Stock change over the window plus spending recorded by the caller."""
        if len(self.stock_history) < 2:
            return {}
        now, latest = self.stock_history[-1]
        older = next(((t, s) for t, s in self.stock_history if now - t <= window), self.stock_history[0])
        span = max(1.0, now - older[0])
        return {r: round((latest[r] - older[1][r]) * 60 / span, 1) for r in latest}

    def summary_since(self, since: float | None) -> dict:
        since = since if since is not None else -math.inf
        kills, losses, kill_value, loss_value = Counter(), Counter(), 0.0, 0.0
        for at, kind, def_id, value in self.ledger:
            if at < since:
                continue
            if kind == "kill":
                kills[def_id] += 1
                kill_value += value
            else:
                losses[def_id] += 1
                loss_value += value
        return {"kills": dict(kills.most_common(6)), "losses": dict(losses.most_common(6)),
                "kill_value": round(kill_value), "loss_value": round(loss_value)}

    def report(self) -> dict:
        army = self.estimated_army()
        return {"enemy_style": list(self.styles) or ["unknown"], "evidence": list(self.evidence),
                "enemy_age_at_least": self.max_enemy_age, "enemy_civilization_guess": self.civ_guess,
                "estimated_enemy_army": dict(army.most_common(8)), "estimated_enemy_army_value": round(self.army_value()),
                "enemy_class_mix": dict(self.class_mix()),
                "trade_ledger": {"kill_value": round(self.kill_value), "loss_value": round(self.loss_value),
                                 "kills": dict(self.kills.most_common(5)), "losses": dict(self.losses.most_common(5))},
                "timeline": list(self.timeline)[-6:]}
