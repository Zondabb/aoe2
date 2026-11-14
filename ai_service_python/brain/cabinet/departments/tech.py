"""Technology: the next age, upgrades, and the buildings an age requires."""
from __future__ import annotations

from .base import Department

AGE_READY_RANK, AGE_SAVING_RANK, UPGRADE_RANK = 109, 103, 50
TC_WINDOW_SHARE, TC_WINDOW_SECONDS = .8, 10
AGE_PATIENCE = 90.0      # an idle town center is costly: a stalled age saving steps back sooner


class TechDept(Department):
    name = "tech"
    role = "technology"
    field_roles = ("technology",)

    def __init__(self, field, treasury) -> None:
        super().__init__(field, treasury)
        self.age: dict | None = None
        self.upgrade: tuple[dict, dict] | None = None
        self.saved: tuple[int, dict] = (-1, {})      # the age being saved for and what is put by so far

    def update(self, f, mandates, brief) -> None:
        for mandate in self.mine(mandates):
            if mandate.kind == "advance_age" and mandate.amount is not None:
                self.tune("technology", target_age=max(0, min(3, int(mandate.amount))))
        # Also asks for the buildings the next age still requires.
        self.age = self.field._age_plan(f) if f.progression_enabled else None

    def draft(self, f) -> None:
        engine = self.field
        self.begin()
        self.upgrade = None
        if self.age is None:
            engine._status("technology", "complete", "progression_disabled")
            self.settle()
            return
        age, saving = self.age, False
        ready = age["prereqs_ready"] or any(tc.get("age_upgrade_reason") == "" for tc in age["tcs"])
        if age["eligible"] and age["tcs"] and ready and not any(tc.get("is_researching") for tc in age["tcs"]):
            saving = True
            # An age the stock nearly covers goes ahead of everything routine and
            # gets a town center with an empty queue. One still far off puts by
            # the technology plan's share of what comes in, and no more: the
            # rest keeps the army growing. Taking all of it left every unit
            # request short for minutes, above all on the way to the last age.
            # A saving that has stalled steps back (see the treasury), starts
            # again from nothing and releases the town center with it.
            cost = age["cost"]
            stalled = ("age", f.age + 1) in self.book and self.book[("age", f.age + 1)].id in self.treasury.yielding
            in_reach = not stalled and all(f.budget[r] >= amount * TC_WINDOW_SHARE for r, amount in cost.items())
            if in_reach:
                engine.roles["technology"].memory["tc_window_until"] = engine.now + TC_WINDOW_SECONDS
            share = engine._technology_targets()[1]
            put_by = self.saved[1] if self.saved[0] == f.age and not stalled else {}
            put_by = {r: min(float(amount), f.budget[r], min(put_by.get(r, 0.0), f.budget[r]) + max(0.0, f.budget[r] - put_by.get(r, 0.0)) * share)
                      for r, amount in cost.items()}
            self.saved = (f.age, {} if stalled else put_by)
            self.want(("age", f.age + 1), f"age_{f.age + 1}", cost, urgency=2,
                      rank=AGE_READY_RANK if in_reach else AGE_SAVING_RANK, patience=AGE_PATIENCE,
                      instalment=None if in_reach else self.saved[1])
            for resource, amount in age["cost"].items():
                engine.demands[resource] += max(0, amount - f.budget[resource])
        else:
            self.saved = (-1, {})
        # While the age is being paid for, nothing else may occupy a town center.
        # Routine upgrades are bought from plenty only: the stock must cover the
        # price several times over, as the technology plan's budget share says.
        share = max(.1, engine._technology_targets()[1])
        for building, option in engine._tech_options(f):
            cost = f.tech_defs[option["id"]].get("cost", {})
            if saving and building.get("def_id") == "town_center" or any(f.budget[r] < amount / share for r, amount in cost.items()):
                continue
            self.upgrade = (building, option)
            self.want(("tech", option["id"]), option["id"], cost, urgency=1, rank=UPGRADE_RANK)
            break
        self.building_wishes(f)
        self.settle()

    def act(self, f) -> None:
        if self.age is None:
            return
        engine = self.field
        request = self.book.get(("age", f.age + 1))
        waiting = "requirements_or_economic_window"
        if request is not None:
            for tc in self.age["tcs"]:
                if tc.get("age_upgrade_reason") == "":
                    with self.treasury.purse(f, request.id):
                        started = engine._emit(f, "technology", "research_age", {"building_id": tc["id"]})
                    if started:
                        engine._status("technology", "running", "age_research_started")
                        return
            waiting = "reserving_age_budget_and_tc_window"
        if self.upgrade is not None:
            building, option = self.upgrade
            with self.treasury.purse(f, self.book[("tech", option["id"])].id):
                started = engine._emit(f, "technology", "research_technology",
                                       {"building_id": building["id"], "technology_id": option["id"]})
            if started:
                engine._status("technology", "running", "research_available_upgrade")
                return
        engine._status("technology", "waiting", waiting)
