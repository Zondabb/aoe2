"""Cabinet runtime: a premier above five departments (docs/cabinet_ai_design.md).

Each tick the departments say what they want to buy, the premier ranks those
requests, the treasury sets the stock aside in that order, and every
department adds orders paid only from its own earmarks. Nothing here waits
for a model: until phase 3 the premier ranks by rule.

Observation intake, unit control and the choices inside a department still
run on the seven-role runtime's code (the "field" engine); what is new is
who decides where the resources go.
"""
from __future__ import annotations

import copy

from brain.llm_commander import MILITARY_BUILDINGS, RESOURCES
from brain.multi_agent.runtime import MultiAgentRuntime
from protocol.models import ChatCompletionRequest

from .construction import ConstructionCrew
from .departments.defense import DefenseDept
from .departments.economy import EconomyDept
from .departments.general import GeneralDept
from .departments.intel import IntelDept
from .departments.tech import TechDept
from .models import IntelBrief, Mandate, Request
from .orders import default_mandates
from .premier import Premier
from .treasury import Treasury


class CabinetRuntime:
    # The service asks a runtime which roles want a model plan. None yet.
    planning_roles: tuple[str, ...] = ()

    def __init__(self, profile_id: str = "default") -> None:
        self.field = MultiAgentRuntime(profile_id)
        self.treasury = Treasury()
        self.premier = Premier()
        self.economy = EconomyDept(self.field, self.treasury)
        self.intel = IntelDept(self.field, self.treasury)
        self.general = GeneralDept(self.field, self.treasury)
        self.defense = DefenseDept(self.field, self.treasury)
        self.tech = TechDept(self.field, self.treasury)
        self.departments = (self.economy, self.intel, self.general, self.defense, self.tech)
        self.crew = ConstructionCrew(self.field, self.treasury)
        # Standing mandates come from the civilization profile, which the
        # first observation may still correct.
        self.mandates: list[Mandate] | None = None
        self.brief = IntelBrief()
        self.requests: list[Request] = []
        self.cached: dict | None = None

    @property
    def goals(self) -> dict:
        return self.field.goals

    @property
    def match_summary(self) -> dict | None:
        return self.field.match_summary

    def load_strategic_memory(self, snapshot: dict) -> None:
        self.field.load_strategic_memory(snapshot)

    def tick(self, req: ChatCompletionRequest) -> dict:
        engine = self.field
        if req.metadata.tick == engine.last_tick and self.cached is not None:
            return copy.deepcopy(self.cached)
        if req.metadata.tick < engine.last_tick or req.observation is None:
            return {"commands": [], "debug": [], "agent_status": self._statuses(), "goals": copy.deepcopy(engine.goals)}
        f = engine._open_frame(req)
        if self.mandates is None:
            self.mandates = default_mandates(engine.validator.profile)
        self.treasury.observe(engine.now, {r: getattr(f.obs.economy, r) for r in RESOURCES})
        if not engine.goals.get("match_over", False):
            self._govern(f)
        else:
            engine._end_match()
        result = engine._close_frame(f)
        result["agent_status"] = self._statuses()
        result["planning"] = {"premier": {"source": self.premier.source, "posture": self.premier.posture},
                              "tiers": dict(self.premier.tiers), "treasury": self.treasury.summary(),
                              "intel": self.brief.as_dict()}
        self.cached = result
        return copy.deepcopy(result)

    def _govern(self, f) -> None:
        engine = self.field
        # 1. Intelligence: threats, scouting, the brief everyone else reads.
        engine._commander(f)
        self.brief = self.intel.update(f, self.mandates)
        # 2. Departments read their mandates and the field, then file requests.
        for dept in (self.general, self.tech, self.economy, self.defense):
            dept.update(f, self.mandates, self.brief)
        for dept in (self.tech, self.economy, self.general, self.defense):
            dept.draft(f)
        self.requests = [request for dept in self.departments for request in dept.requests()]
        # 3. The premier ranks, the treasury sets the stock aside.
        previous = dict(self.premier.tiers)
        tiers = self.premier.rank(self.requests, self.brief)
        self.treasury.allocate(f.budget, self.requests, tiers, engine.now)
        self._note_changes(previous, tiers)
        # 4. Orders, each paid from its own request's earmark. Units and
        # builders are claimed in the order the seven roles claimed them.
        self.tech.act(f)
        self.crew.work(f, [r for r in self.treasury.line(self.requests, tiers) if r.key[0] == "building"])
        for building in engine._production_plan(f)["ordered"]:
            if building.get("def_id") == "town_center":
                self.economy.train(f, building)
            elif building.get("def_id") in MILITARY_BUILDINGS:
                self.general.train(f, building)
        self.defense.act(f)
        self.economy.act(f)

    def _note_changes(self, previous: dict, tiers: dict) -> None:
        notes = [note for dept in self.departments for note in dept.notes]
        notes += [f"{rid} moved from {previous[rid]} to {tier}" for rid, tier in tiers.items()
                  if rid in previous and previous[rid] != tier]
        for dept in self.departments:
            dept.notes.clear()
        self.field.debug.extend({"category": "MULTI_AGENT", "message": f"cabinet: {note}"} for note in notes)

    def _statuses(self) -> dict:
        statuses = {"premier": self.premier.status(bool(self.field.goals.get("match_over")))}
        for dept in self.departments:
            statuses[dept.name] = dept.report().as_dict()
        return statuses
