"""Defense: walls and gates around the base, and towers ordered by the premier."""
from __future__ import annotations

from brain.land_progression import CATALOG

from ..orders import TOWER_LINE, needs_of
from ..towers import site_options, tower_type
from .base import Department, ORDERED_BUILDING_PRIORITY

URGENT_RANK, ROUTINE_RANK = 90, 55


class DefenseDept(Department):
    name = "defense"
    role = "defense"
    field_roles = ("defense",)

    def __init__(self, field, treasury) -> None:
        super().__init__(field, treasury)
        self.scene: dict | None = None
        self.options: list[dict] | None = None
        self.spare: list[dict] = []     # options the stock can pay for without touching the wall reserve
        self.tower_order = None

    def update(self, f, mandates, brief) -> None:
        mine = self.mine(mandates)
        fortify = next((m for m in mine if m.kind == "fortify"), None)
        self.tower_order = next((m for m in mine if m.kind == "towers" and m.amount), None)
        self.tune_while("defense", fortify is not None, policy="fortify")
        if fortify is not None:
            self.serve(("wall",), fortify)
        engine = self.field
        self.scene, self.options = engine._defense_scene(f), None
        if self.scene is not None and not self.scene["unfinished"]:
            self.options = engine._wall_options(f, self.scene)

    def _best(self, f, options: list[dict]) -> dict:
        return min(options, key=lambda option: self.field._wall_score(f, option, self.scene))

    def draft(self, f) -> None:
        engine = self.field
        self.begin()
        if self.tower_order is not None:
            self._draft_towers(f)
        role = engine.roles["defense"]
        # Routine walls are built from surplus: the stock keeps the plan's wood
        # reserve and a little food once the line is paid for.
        wood_floor = max(60, role.plan["reserve_wood"])
        self.spare = [o for o in self.options or [] if f.budget["wood"] - o["cost"].get("wood", 0) >= wood_floor
                      and f.budget["food"] - o["cost"].get("food", 0) >= 50]
        if self.spare:
            best = self._best(f, self.spare)
            urgent = role.memory.get("threat_until", 0) > engine.now \
                or engine.doctrine.get("defense_policy", role.plan["policy"]) == "fortify"
            self.want(("wall",), best["building_def_id"], best["cost"], count=int(best["segment_count"]), total=best["cost"],
                      urgency=2 if urgent else 1, rank=URGENT_RANK if urgent else ROUTINE_RANK)
        self.settle()

    def _draft_towers(self, f) -> None:
        engine, mandate = self.field, self.tower_order
        towers = [b for b in f.buildings if b.get("def_id") in TOWER_LINE and b.get("hp", 1) > 0]
        remaining = mandate.amount - len(towers)
        if remaining <= 0:
            return
        # A receipt can precede the foundation in the observation.
        if any(t["command"].get("op") == "place_building" and t["command"].get("building_def_id") in TOWER_LINE
               and t["status"] in ("dispatched", "accepted") for t in engine.tasks.values()):
            return
        name = tower_type(f)
        definition = {**CATALOG["buildings"][name], **f.building_defs.get(name, {})}
        f.building_defs = {**f.building_defs, name: definition}
        unlocked = engine._unlocked_for_saving(f, definition)
        if unlocked:
            # Gather for the next tower while the crew finishes the current one.
            for resource, amount in definition["cost"].items():
                engine.demands[resource] += amount
        if any(not b.get("is_complete") for b in towers):
            return
        needs = needs_of(mandate, f)
        if not unlocked:
            needs = needs or (definition.get("blocked_reason") or "tower_locked",)
        else:
            # Only this cabinet frame sees these candidates. The ordinary crew,
            # validator, treasury and game executor still handle the purchase.
            offered = f.context.get("construction_options", [])
            if not any(o.get("building_def_id") == name for o in offered):
                options = site_options(f, engine, name, towers)
                if options:
                    f.context = {**f.context, "construction_options": [*offered, *options]}
                else:
                    needs = ("visible_tower_site_and_builder",)
        key = ("building", name)
        self.serve(key, mandate)
        self.want(key, name, definition["cost"], count=remaining, needs=needs, rank=ORDERED_BUILDING_PRIORITY)

    def act(self, f) -> None:
        engine = self.field
        # Gates and unfinished sections first; they need builders, not money.
        if self.scene is None or engine._defense_upkeep(f, self.scene) or self.options is None:
            return
        request = self.book.get(("wall",))
        if request is not None:
            with self.treasury.purse(f, request.id):
                if engine._place_wall(f, self.spare, self.scene, 0, 0):
                    return
        if self.options:
            for resource, amount in self._best(f, self.options)["cost"].items():
                engine.demands[resource] += amount
        if engine._defense_reveal(f, self.scene["workers"], self.scene["enemies"], allow_new=not self.options):
            return
        engine._status("defense", "waiting", "perimeter_budget_or_hidden_or_blocked_section")
