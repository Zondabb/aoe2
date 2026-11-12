"""Defense: the wall around the base and its gates. Towers arrive in phase 7."""
from __future__ import annotations

from .base import Department

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

    def update(self, f, mandates, brief) -> None:
        for mandate in self.mine(mandates):
            if mandate.kind == "fortify":
                self.tune("defense", policy="fortify")
        engine = self.field
        self.scene, self.options = engine._defense_scene(f), None
        if self.scene is not None and not self.scene["unfinished"]:
            self.options = engine._wall_options(f, self.scene)

    def _best(self, f, options: list[dict]) -> dict:
        return min(options, key=lambda option: self.field._wall_score(f, option, self.scene))

    def draft(self, f) -> None:
        engine = self.field
        self.begin()
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
        if engine._defense_reveal(f, self.scene["workers"], self.scene["enemies"]):
            return
        engine._status("defense", "waiting", "perimeter_budget_or_hidden_or_blocked_section")
