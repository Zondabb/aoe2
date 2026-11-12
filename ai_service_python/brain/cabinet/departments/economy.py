"""Economy: villagers, the buildings that feed and house them, and who gathers what."""
from __future__ import annotations

from .base import Department

VILLAGER_RANK = 104


def idle_producer(building: dict) -> bool:
    return bool(building.get("is_complete")) and not building.get("is_researching") \
        and bool(building.get("train_queue_empty", not building.get("train_queue")))


class EconomyDept(Department):
    name = "economy"
    role = "economy"
    field_roles = ("economy", "construction")

    def update(self, f, mandates, brief) -> None:
        for mandate in self.mine(mandates):
            if mandate.kind == "worker_target" and mandate.amount:
                self.tune("economy", worker_target=max(8, min(60, int(mandate.amount))))
        self.field._economy_requirements(f)

    def draft(self, f) -> None:
        engine = self.field
        self.begin()
        workers = [u for u in f.units if u.get("def_id") == "villager"]
        floor, target = engine._worker_targets(f.age)
        town_centers = [b for b in f.buildings if b.get("def_id") == "town_center" and b.get("is_complete")]
        if town_centers and len(workers) < target and not self._town_center_reserved():
            idle = sum(idle_producer(b) for b in town_centers)
            definition = f.unit_defs.get("villager", {})
            below_floor = len(workers) < floor
            self.want(("unit", "villager"), "villager", definition.get("cost", {"food": 50}), count=target - len(workers),
                      capacity=max(1, idle), pop=int(definition.get("population", 1)),
                      urgency=3 if below_floor else 2, rank=VILLAGER_RANK, floor=below_floor)
        self.building_wishes(f)
        self.settle()

    def _town_center_reserved(self) -> bool:
        # The technology department asks for a free town center shortly
        # before it can pay for the next age.
        return self.field.roles["technology"].memory.get("tc_window_until", 0) > self.field.now

    def train(self, f, town_center: dict) -> bool:
        request = self.book.get(("unit", "villager"))
        if request is None or self._town_center_reserved():
            return False
        with self.treasury.purse(f, request.id):
            ordered = self.field._emit(f, "economy", "train", {"building_id": town_center["id"], "unit_def_id": "villager"})
        if ordered:
            self.field.roles["economy"].memory["villager_ordered_at"] = self.field.now
        return ordered

    def act(self, f) -> None:
        """Gathering costs nothing: staff the resources the open requests are short of."""
        self.field._economy(f)
