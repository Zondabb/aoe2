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

from .broadcast import CHANGE, DONE as CARRIED_OUT, ORDER, THREAT, Broadcaster, joined
from .construction import ConstructionCrew
from .departments.defense import DefenseDept
from .departments.economy import EconomyDept
from .departments.general import GeneralDept
from .departments.intel import IntelDept
from .departments.tech import TechDept
from .ledger import NEW, OrderLedger
from .models import IntelBrief, Mandate, Request, order_origin
from .orders import default_mandates, derive, ground, ground_reading, load_policy, policy_entries, progress, slot
from .premier import (INTERPRET_PROMPT, ORDER_RETRY_LIMIT, ORDER_RETRY_PAUSE, ORDERS_ROLE, OUTPUT_TOKENS, RANK_PROMPT, ROLE as PREMIER, Premier,
                      interpret_context, interpret_schema, rank_context, rank_schema, reading)
from .treasury import Treasury

GRANT_LOG_SPACING = 10.0   # game seconds between two grant summaries in the match log


class CabinetRuntime:
    # The background model calls this runtime asks the service for: ranking the requests, and reading a new order.
    planning_roles: tuple[str, ...] = (PREMIER, ORDERS_ROLE)

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
        # The head of state: a player's orders in the ledger, or the profile's policy script.
        self.ledger = OrderLedger()
        self.policy: list[dict] | None = None
        self.policy_done: set[int] = set()
        self.policy_since: dict[int, float] = {}
        self.in_force: list[Mandate] = []      # this tick's mandates, with what they need first
        self._reading: int | None = None       # the order the model was last asked to read
        self.legislative_enabled = False       # enabled only by the host's isolated runtime
        # What the premier says to the player (planning.broadcasts), and what the player has heard so far:
        # the model ranking last weighed for a broadcast, and the danger they have been told about.
        self.voice = Broadcaster()
        self._heard: dict = {"version": 0, "threat": 0, "level": 0, "rose_at": 0.0}
        self._asked_threat = 0                           # the danger in the picture the ranking call in flight was shown
        self._decision_threat: dict[int, int] = {}       # model ranking version -> the danger its model saw
        self._order_wall: dict[int, float] = {}          # order number -> wall clock when it arrived
        self._waiting_said: dict[int, str] = {}          # order number -> the reason for waiting already read out
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
        if self.policy is None:
            profile = engine.validator.profile
            self.policy = load_policy(list(profile.national_policy), profile.civ_id)
            if self.mandates is None:
                # The profile's old targets stand in where no policy script was written.
                self.mandates = [] if self.policy else default_mandates(profile)
        self.stock = {r: float(getattr(f.obs.economy, r)) for r in RESOURCES}
        self.treasury.observe(engine.now, self.stock)
        if not engine.goals.get("match_over", False):
            self._govern(f)
        else:
            engine._end_match()
        result = engine._close_frame(f)
        lines = self.voice.take(engine.now)
        self.journal.extend(("broadcast", event) for event in self.voice.take_events())
        result["agent_status"] = self._statuses()
        premier = self.premier.status(now=engine.now)
        result["planning"] = {"premier": {key: premier[key] for key in ("source", "posture", "thinking", "decision", "decided_at")
                                          if key in premier},
                              "tiers": dict(self.premier.tiers), "treasury": self.treasury.summary(),
                              "intel": self.brief.as_dict(), "orders": self.ledger.rows()}
        if lines:
            # Each line travels with this one response; the game shows it and reads it aloud.
            result["planning"]["broadcasts"] = lines
        self.cached = result
        return copy.deepcopy(result)

    def _govern(self, f) -> None:
        engine = self.field
        # 0. The head of state: new orders into the ledger, progress on the open ones, this tick's mandates.
        for order in self.ledger.intake(f.obs.player_instructions, engine.now):
            self._order_wall[order.number] = self.voice.clock()
        self.ledger.note_unread(engine.now)
        self.in_force = self._mandates(f)
        # 1. Intelligence: threats, scouting, the brief everyone else reads.
        engine._commander(f)
        self.brief = self.intel.update(f, self.in_force)
        # 2. Departments read their mandates and the field, then file requests.
        for dept in (self.general, self.tech, self.economy, self.defense):
            dept.update(f, self.in_force, self.brief)
        for dept in (self.tech, self.economy, self.general, self.defense):
            dept.draft(f)
        self.requests = [request for dept in self.departments for request in dept.requests()]
        # 3. The premier ranks, the treasury sets the stock aside.
        previous, posture = dict(self.premier.tiers), self.premier.posture
        tiers = self.premier.rank(self.requests, self.brief, engine.now)
        # The posture is the premier's, unless the head of state has ordered an attack or a halt;
        # the commander's stance carries it into the field.
        self.intel.tune("commander", stance={"attack": "pressure", "hold": "defend"}.get(self.general.stance, self.premier.posture))
        self.treasury.allocate(f.budget, self.requests, tiers, engine.now)
        self._note_changes(previous, tiers, posture)
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

    def _note_changes(self, previous: dict, tiers: dict, posture: str) -> None:
        moved = {rid: [previous[rid], tier] for rid, tier in tiers.items() if rid in previous and previous[rid] != tier}
        events = self.ledger.take_events()
        self._speak(moved, posture, events)
        notes = [note for dept in self.departments for note in dept.notes]
        notes += [f"{rid} moved from {old} to {new}" for rid, (old, new) in moved.items()]
        self.field.debug.extend({"category": "MULTI_AGENT", "message": f"cabinet: {note}"} for note in notes)
        self._write_journal(moved, tiers, events)
        for dept in self.departments:
            dept.notes.clear()
            dept.opened.clear()
            dept.closed.clear()

    def _speak(self, moved: dict, posture: str, events: list[dict]) -> None:
        """What this tick gives the premier to say: answers to orders, and a model ranking that changed something."""
        now, voice, ledger, heard = self.field.now, self.voice, self.ledger, self._heard
        self._order_wall = {number: at for number, at in self._order_wall.items() if ledger.find(number) is not None}
        self._waiting_said = {number: said for number, said in self._waiting_said.items() if ledger.find(number) is not None}
        for event in events:
            order = ledger.find(event["id"])
            if order is None:
                continue
            about = {"order": order.number, "about": order.text}
            if event["change"] in ("interpreted", "impossible"):
                # The answer to an order is always read out: how it was understood, what will be done, what was changed.
                voice.say(ORDER, order.thinking, joined(order.decision, *order.notes), now, since=order.received_at,
                          since_wall=self._order_wall.get(order.number), **about)
            elif event["change"] == "done":
                voice.say(CARRIED_OUT, "", f"“{order.text}”已经办完。", now, **about)
        for order in ledger.orders:
            # An order no model has read says why once, so the player is not left waiting for an answer that will not come.
            if order.status == NEW and order.waiting and self._waiting_said.get(order.number) != order.waiting:
                self._waiting_said[order.number] = order.waiting
                voice.say(ORDER, "", order.waiting, now, since=order.received_at, since_wall=self._order_wall.get(order.number),
                          order=order.number, about=order.text)
        level = self.brief.threat_level
        if level > heard["level"]:
            heard["rose_at"] = now
        heard["level"] = level
        heard["threat"] = min(heard["threat"], level)    # the danger passed: when it comes back it is news again
        decision = self.premier.in_force(now)
        if decision is not None and decision["version"] != heard["version"]:
            heard["version"] = decision["version"]
            seen = self._decision_threat.get(decision["version"], level)
            if seen > heard["threat"]:
                # The model ranked with a danger in view that the player has not been told about.
                voice.say(THREAT, decision["thinking"], decision["decision"], now, since=heard["rose_at"])
            elif moved or self.premier.posture != posture:
                voice.say(CHANGE, decision["thinking"], decision["decision"], now, since=decision["at"])
            # Otherwise a routine re-ranking that changed nothing: planning.premier carries its time, nothing is said.
            heard["threat"] = max(heard["threat"], seen)

    def _write_journal(self, moved: dict, tiers: dict, events: list[dict]) -> None:
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
        self.journal.extend(("order", event) for event in events)
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

    # ------------------------------------------------------------------ the head of state's mandates
    def _mandates(self, f) -> list[Mandate]:
        """This tick's mandates: the standing ones and the policy script, a player's orders over both, and what each needs first."""
        engine, ledger = self.field, self.ledger
        for order in ledger.active():
            for mandate in order.mandates:
                if slot(mandate) not in order.done:
                    ledger.record(order, mandate, *progress(mandate, f, engine, order.received_at))
        ledger.prune()
        scripted = []
        for entry in policy_entries(self.policy or [], f.age, self.policy_done):
            since = self.policy_since.setdefault(entry["number"], engine.now)
            if progress(entry["mandate"], f, engine, since)[0]:
                self.policy_done.add(entry["number"])
            else:
                scripted.append(entry["mandate"])
        ordered = ledger.mandates()
        taken = {slot(m) for m in ordered}
        return derive([*[m for m in [*(self.mandates or []), *scripted] if slot(m) not in taken], *ordered], f)

    def _order_brief(self) -> dict | None:
        """One call that reads the oldest order nobody has read yet."""
        order = self.ledger.pending()
        if order is None:
            return None
        engine = self.field
        previous = {"mandates": order.refused, "problem": order.problem} if order.problem else None
        if previous is not None and getattr(order, "rejected_reading", None) is not None:
            previous["response"] = copy.deepcopy(order.rejected_reading)
        context = interpret_context(order.text, [o.row() for o in self.ledger.active()], engine.validator.profile.civ_id,
                                    self._age(), previous)
        self._reading = order.number
        order.asked += 1
        prompt = INTERPRET_PROMPT
        if self.legislative_enabled:
            from brain.legislation.planning import INTAKE_PROMPT
            prompt += INTAKE_PROMPT
        return {"system": prompt, "context": context, "schema": interpret_schema(self.legislative_enabled),
                "description": "Read the head of state's order into mandates for the departments.",
                "player_orders": False, "output_tokens": 1024 if self.legislative_enabled else OUTPUT_TOKENS}

    def _read_order(self, plan: dict) -> bool:
        """Take the model's reading of the order it was asked about; False when it has to be asked again."""
        order = self.ledger.find(self._reading) if self._reading is not None else None
        if order is None or order.status != NEW:
            return False
        if self.legislative_enabled:
            from jsonschema import Draft202012Validator, ValidationError
            try:
                Draft202012Validator(interpret_schema(True)).validate(plan)
            except (ValidationError, TypeError):
                self.plan_rejected(ORDERS_ROLE, "invalid_resolution_or_fields", plan)
                return False
        read = reading(plan)
        if read is None:
            return False
        grasp, thinking, decision, raw = read
        gap = plan.get("legislation")
        grounding = (ground(raw, self.field.validator.profile.civ_id, self._age(), order_origin(order.number))
                     if gap is not None else ground_reading(grasp, raw, self.field.validator.profile.civ_id,
                                                          self._age(), order_origin(order.number)))
        if self.legislative_enabled and grounding.problems:
            self.plan_rejected(ORDERS_ROLE, "；".join(grounding.problems), plan)
            return False
        if gap is not None:
            from brain.legislation.planning import valid_gap
            if not self.legislative_enabled or not valid_gap(gap) or grasp == "none" or grounding.problems:
                return False
            requirement = {**copy.deepcopy(gap), "proposal_id": f"order-{order.number}", "order_id": order.number,
                           "instruction": order.text, "target_revision": self.ledger.revision + 1, "status": "waiting"}
            self.ledger.refer_legislation(order, grasp, thinking, decision, grounding, requirement)
            return True
        return self.ledger.accept(order, grasp, thinking, decision, grounding, raw) != "retry"

    def plan_rejected(self, role: str, reason: str, response: dict | None = None) -> bool:
        """The host reports schema/length errors so the next reading can repair them."""
        if role != ORDERS_ROLE or not self.legislative_enabled:
            return False
        order = self.ledger.find(self._reading) if self._reading is not None else None
        if order is None or order.status != NEW:
            return False
        problem = (
            "保留原指令的目标，不要用无关的普通任务替换它。必须填写 resolution 和 legislation。"
            "resolution=legislation 时提交完整 legislation（部门、证据、正反例、撤销条件），mandates 可以为空；"
            "resolution=mandates 时 legislation=null，至少一条任务书且确实能实现原目标；"
            "resolution=unsupported 时 grasp=none、mandates=[]、legislation=null，说明缺少的能力。"
            "只在 thinking/decision 里承诺立法不构成立案。错误：" + str(reason)[:400])
        self.ledger.reject_reading(order, problem, response)
        return True

    def legislative_requests(self) -> list[dict]:
        """Frozen requests for the host; cancelled orders can never be submitted."""
        if not self.legislative_enabled or self.field.goals.get("match_over"):
            return []
        return [copy.deepcopy(order.legislation) for order in self.ledger.active()
                if order.legislation and order.legislation.get("status") == "waiting"]

    def legislation_result(self, proposal_id: str, status: str, reason: str = "") -> bool:
        return self.ledger.legislation_result(proposal_id, status, reason)

    def legislation_progress(self, proposal_id: str, phase: str, reason: str = "", step: int = 0) -> bool:
        return self.ledger.legislation_progress(proposal_id, phase, reason, step)

    def _age(self) -> int:
        last = self.field.last_req
        return last.observation.progression.age if last and last.observation and last.observation.progression else 0

    # ------------------------------------------------------------------ the premier's model calls
    def planning_interval(self, role: str) -> float:
        """Wall seconds the service waits between two calls: shorter once the picture has changed."""
        if role == ORDERS_ROLE:
            # A new order is read at once; the pause only spaces out repeated tries, longer each time.
            order = self.ledger.pending()
            if order is None:
                return math.inf
            return min(ORDER_RETRY_LIMIT, ORDER_RETRY_PAUSE * 2 ** (order.asked - 1)) if order.asked else 0.0
        if not self.requests:
            return math.inf                                  # nothing to rank
        return self.premier.interval(self._picture())

    def planning_brief(self, role: str) -> dict | None:
        """One ranking call for the service to send, or None when there is nothing to rank.

        The service asks for this only when it is about to send the call, so
        what is asked here counts as seen by the model."""
        if self.field.goals.get("match_over"):
            return None
        if role == ORDERS_ROLE:
            return self._order_brief()
        if role != PREMIER or not self.requests:
            return None
        requests = self.treasury.line(self.requests, self.premier.tiers)
        requests += [r for r in self.requests if r not in requests]             # those on hold are ranked too
        context = rank_context(requests, self.premier.tiers, self.brief, self.stock,
                               {r: v * 60 for r, v in self.treasury.income().items()}, self.premier.posture,
                               {r.id: self.treasury.gap(r) for r in requests}, self.ledger.rows(), self._age())
        self.premier.asked = self._picture()
        self._asked_threat = self.brief.threat_level
        return {"system": RANK_PROMPT, "context": context, "schema": rank_schema([row["id"] for row in context["requests"]]),
                "description": "Rank the departments' open requests and set the posture.",
                "player_orders": False, "output_tokens": OUTPUT_TOKENS}

    def planning_context(self, role: str) -> dict:
        """What the service checks a returning answer against."""
        if role not in self.planning_roles:
            raise ValueError("unknown role")
        engine = self.field
        if role == ORDERS_ROLE:
            return {"role": role, "plan": {}, "plan_version": self.ledger.revision, "goal_version": engine.goal_version,
                    "goals": copy.deepcopy(engine.goals)}
        return {"role": role, "plan": self.premier.plan(engine.now), "plan_version": self.premier.version,
                "goal_version": engine.goal_version, "goals": copy.deepcopy(engine.goals)}

    def apply_plan(self, role: str, plan: dict) -> bool:
        """Take the model's ranking; it shows in the tiers from the next tick."""
        if self.field.goals.get("match_over"):
            return False
        if role == ORDERS_ROLE:
            return self._read_order(plan)
        if role != PREMIER or not self.premier.decide(plan, self.requests, self.field.now):
            return False
        self._decision_threat = {self.premier.version: self._asked_threat}
        return True

    def _picture(self) -> tuple:
        return self.premier.picture(self.requests, self.brief, (len(self.in_force), self.ledger.revision))

    def _statuses(self) -> dict:
        statuses = {"premier": {**self.premier.status(bool(self.field.goals.get("match_over")), self.field.now),
                               "orders": self.ledger.details()}}
        for dept in self.departments:
            statuses[dept.name] = dept.report().as_dict()
        return statuses
