"""Cabinet runtime: a premier above five departments (docs/cabinet_ai_design.md).

Each tick the departments say what they want to buy, the premier ranks those
requests, the treasury sets the stock aside in that order, and every
department adds orders paid only from its own earmarks. Nothing here waits
for a model: the premier's model is asked in the background (the service
calls planning_brief and, with the answer, apply_plan), and the rule book
ranks whatever it has not decided.

Observation intake, unit control and the choices inside a department still
run on the seven-role runtime's code (the "field" engine); what is new is
who decides where the resources go.
"""
from __future__ import annotations

import copy
import math

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
from .premier import OUTPUT_TOKENS, RANK_PROMPT, ROLE as PREMIER, Premier, rank_context, rank_schema
from .treasury import Treasury

GRANT_LOG_SPACING = 10.0   # game seconds between two grant summaries in the match log


class CabinetRuntime:
    # The one background model call this runtime asks the service for.
    planning_roles: tuple[str, ...] = (PREMIER,)

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
        self.stock: dict[str, float] = {r: 0.0 for r in RESOURCES}
        # Entries for the match log, taken by the service after each tick.
        self.journal: list[tuple[str, dict]] = []
        self._logged: dict = {"decision": None, "source": None, "grants": None, "grants_at": -GRANT_LOG_SPACING}

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
        self.stock = {r: float(getattr(f.obs.economy, r)) for r in RESOURCES}
        self.treasury.observe(engine.now, self.stock)
        if not engine.goals.get("match_over", False):
            self._govern(f)
        else:
            engine._end_match()
        result = engine._close_frame(f)
        result["agent_status"] = self._statuses()
        premier = self.premier.status(now=engine.now)
        result["planning"] = {"premier": {key: premier[key] for key in ("source", "posture", "thinking", "decision", "decided_at")
                                          if key in premier},
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
        tiers = self.premier.rank(self.requests, self.brief, engine.now)
        # The posture is the premier's; the commander's stance carries it into the field.
        self.intel.tune("commander", stance=self.premier.posture)
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
        moved = {rid: [previous[rid], tier] for rid, tier in tiers.items() if rid in previous and previous[rid] != tier}
        notes = [note for dept in self.departments for note in dept.notes]
        notes += [f"{rid} moved from {old} to {new}" for rid, (old, new) in moved.items()]
        self.field.debug.extend({"category": "MULTI_AGENT", "message": f"cabinet: {note}"} for note in notes)
        self._write_journal(moved, tiers)
        for dept in self.departments:
            dept.notes.clear()
            dept.opened.clear()
            dept.closed.clear()

    def _write_journal(self, moved: dict, tiers: dict) -> None:
        """The match log's view of this tick: who decided the ranking, requests filed, moved and closed, and who got money."""
        premier, now, logged = self.premier, self.field.now, self._logged
        decision = premier.in_force(now)
        version = decision["version"] if decision else None
        if premier.source != logged["source"] or version != logged["decision"]:
            # A new model decision, the rule book taking over from a stale one, or the first ranking of the match.
            entry = {"source": premier.source, "reason": premier.reason, "posture": premier.posture, "moved": dict(moved),
                     "requests": len(self.requests), "threat_level": self.brief.threat_level}
            if decision:
                entry.update(thinking=decision["thinking"], decision=decision["decision"], ignored=list(decision["ignored"]),
                             version=version, decided_at=decision["at"])
            self.journal.append(("premier_decision", entry))
            logged["source"], logged["decision"] = premier.source, version
        for dept in self.departments:
            for request in dept.opened:
                self.journal.append(("request", {"change": "opened", "id": request.id, "dept": request.dept, "item": request.line(),
                                                 "remaining": {r: round(v, 1) for r, v in request.remaining.items()},
                                                 "urgency": request.urgency, "origin": request.origin,
                                                 "tier": tiers.get(request.id)}))
        for rid, (old, new) in moved.items():
            self.journal.append(("request", {"change": "retiered", "id": rid, "from": old, "to": new, "by": premier.source}))
        for dept in self.departments:
            for request in dept.closed:
                self.journal.append(("request", {"change": "closed", "id": request.id, "dept": request.dept, "item": request.line()}))
        # Money arrives every second; the log gets a summary only when who is
        # paid in full, in part or not at all has changed, and not more often
        # than every few seconds. The tick log still has every amount.
        grants = {}
        for request in self.requests:
            held = sum(self.treasury.granted.get(request.id, {}).values())
            grants[request.id] = "none" if held <= 0 else "part" if self.treasury.gap(request) else "full"
        if grants != logged["grants"] and now - logged["grants_at"] >= GRANT_LOG_SPACING:
            self.journal.append(("grant", {
                "grants": {rid: {"state": state, "tier": tiers.get(rid),
                                 "held": {r: round(v, 1) for r, v in self.treasury.granted.get(rid, {}).items() if v}}
                           for rid, state in grants.items()},
                "unallocated": {r: round(v, 1) for r, v in self.treasury.unallocated.items()}}))
            logged["grants"], logged["grants_at"] = grants, now

    def take_journal(self) -> list[tuple[str, dict]]:
        """Hand the collected log entries to the service, once."""
        entries, self.journal = self.journal, []
        return entries

    # ------------------------------------------------------------------ the premier's model call
    def planning_interval(self, role: str) -> float:
        """Wall seconds the service waits between two calls: shorter once the picture has changed."""
        if not self.requests:
            return math.inf                                  # nothing to rank
        return self.premier.interval(self._picture())

    def planning_brief(self, role: str) -> dict | None:
        """One ranking call for the service to send, or None when there is nothing to rank.

        The service asks for this only when it is about to send the call, so
        what is asked here counts as seen by the model."""
        if role != PREMIER or not self.requests or self.field.goals.get("match_over"):
            return None
        requests = self.treasury.line(self.requests, self.premier.tiers)
        requests += [r for r in self.requests if r not in requests]             # those on hold are ranked too
        engine = self.field
        age = engine.last_req.observation.progression.age if engine.last_req and engine.last_req.observation.progression else 0
        context = rank_context(requests, self.premier.tiers, self.brief, self.stock,
                               {r: v * 60 for r, v in self.treasury.income().items()}, self.premier.posture,
                               {r.id: self.treasury.gap(r) for r in requests}, age=age)
        self.premier.asked = self._picture()
        return {"system": RANK_PROMPT, "context": context, "schema": rank_schema([row["id"] for row in context["requests"]]),
                "description": "Rank the departments' open requests and set the posture.",
                "player_orders": False, "output_tokens": OUTPUT_TOKENS}

    def planning_context(self, role: str) -> dict:
        """What the service checks a returning answer against."""
        if role != PREMIER:
            raise ValueError("unknown role")
        engine = self.field
        return {"role": role, "plan": self.premier.plan(engine.now), "plan_version": self.premier.version,
                "goal_version": engine.goal_version, "goals": copy.deepcopy(engine.goals)}

    def apply_plan(self, role: str, plan: dict) -> bool:
        """Take the model's ranking; it shows in the tiers from the next tick."""
        if role != PREMIER or self.field.goals.get("match_over"):
            return False
        return self.premier.decide(plan, self.requests, self.field.now)

    def _picture(self) -> tuple:
        return self.premier.picture(self.requests, self.brief, len(self.mandates or ()))

    def _statuses(self) -> dict:
        statuses = {"premier": self.premier.status(bool(self.field.goals.get("match_over")), self.field.now)}
        for dept in self.departments:
            statuses[dept.name] = dept.report().as_dict()
        return statuses
