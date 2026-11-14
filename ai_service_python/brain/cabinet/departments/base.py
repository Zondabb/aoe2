"""What every department shares: mandates in, requests out, orders paid from grants.

A department never spends from the common stock. It files requests, and each
tick it may add orders only inside the purse the treasury opened for one of
them. What it does in the field without money (moving, gathering, gates) is
not rationed.

The choices themselves (which unit, which site, which wall line) are still
made by the methods of the seven-role runtime, the "field" engine, so a fully
funded department orders what the matching old role would have ordered.
"""
from __future__ import annotations

from ..models import DeptReport, Mandate, Request, ROUTINE
from ..treasury import Treasury

MAX_REQUESTS = 3
# Who files the request for a building the field engine asks for, by the
# engine's own reason for asking.
BUILDING_OWNER = {
    "population_headroom": "economy", "farm_prerequisite": "economy", "staffed_food_supply": "economy",
    "long_wood_delivery": "economy", "wood_delivery": "economy", "gold_delivery": "economy",
    "opening_military_capacity": "general", "military_plan_capacity": "general", "counter_unit_capacity": "general",
    "siege_infrastructure": "general", "age_prerequisite": "tech",
}
DEFAULT_OWNER = "economy"  # a reason not listed above must not leave its building unrequested
POPULATION_CAPPED = 120   # the engine's priority for a house when no population is free


def urgency_of(priority: int) -> int:
    """The engine's building priorities (45..120) on the request scale 0..3."""
    return 3 if priority >= 110 else 2 if priority >= 100 else 1 if priority >= 55 else 0


class Department:
    name = ""
    role = ""                 # the field role whose status explains this department
    field_roles: tuple[str, ...] = ()   # every field role this department drives, for the tick log

    def __init__(self, field, treasury: Treasury) -> None:
        self.field, self.treasury = field, treasury
        self.book: dict[tuple, Request] = {}
        self.notes: list[str] = []
        self._wanted: set[tuple] = set()
        self._serial = 0

    # ------------------------------------------------------------ the tick, in order
    def update(self, f, mandates: list[Mandate], brief) -> None:
        """Read the mandates and the field; say what is wanted."""

    def draft(self, f) -> None:
        """Turn what is wanted into requests, once every department has spoken."""

    def requests(self) -> list[Request]:
        """Open requests, most pressing first; at most three reach the premier.

        A request that can buy nothing yet (a missing requirement, no legal
        site) does not take a place from one that can."""
        return sorted(self.book.values(), key=lambda r: (not r.tranche, -r.urgency, -r.rank, r.created_at, r.id))[:MAX_REQUESTS]

    def act(self, f) -> None:
        """Add orders, paying only from this department's purses."""

    def report(self) -> DeptReport:
        state = self.field.roles[self.role] if self.role else None
        rows, waiting_funds, waiting_needs = [], False, False
        for request in self.requests():
            gap = self.treasury.gap(request)
            waiting_funds |= bool(gap)
            waiting_needs |= bool(request.needs)
            rows.append({"id": request.id, "item": request.line(), "tier": self.treasury.tiers.get(request.id, "later"),
                         "urgency": request.urgency, "origin": request.origin, "needs": list(request.needs),
                         "yielding": request.id in self.treasury.yielding,
                         "held": {r: round(v, 1) for r, v in self.treasury.granted.get(request.id, {}).items() if v},
                         "spent": {r: round(v, 1) for r, v in self.treasury.spent(request.id).items()},
                         "gap": {r: round(v, 1) for r, v in gap.items()}, "eta_sec": self.treasury.eta(request)})
        if state is not None and state.status == "complete":
            status = "complete"
        elif waiting_funds or waiting_needs:
            status = "waiting_funds" if waiting_funds else "waiting_needs"
        elif state is None:
            status = "running"
        else:
            # Waiting on something money cannot buy (a hidden wall section, a
            # blocked route) is the field role's own word, not idleness.
            status = state.status if state.status in ("running", "waiting", "blocked") else "idle"
        roles = {role: {"status": self.field.roles[role].status, "reason": self.field.roles[role].reason}
                 for role in self.field_roles}
        return DeptReport(self.name, status, state.reason if state is not None else "", rows, roles)

    # ------------------------------------------------------------ helpers
    def mine(self, mandates: list[Mandate]) -> list[Mandate]:
        return [m for m in mandates if m.dept == self.name]

    def tune(self, role: str, **values) -> None:
        """Set field parameters a mandate fixes; counts as a new plan only when something changed."""
        state = self.field.roles[role]
        changed = {k: v for k, v in values.items() if state.plan.get(k) != v}
        if changed:
            state.plan.update(changed)
            state.version += 1
            state.plan_source, state.reason = "mandate", "mandate_applied"

    def begin(self) -> None:
        self._wanted = set()

    def want(self, key: tuple, item: str, price: dict, *, count: int = 1, capacity: int = 1, total: dict | None = None,
             pop: int = 0, needs: tuple = (), urgency: int = 1, rank: int = 50, origin: str = ROUTINE,
             floor: bool = False, emergency: bool = False, patience: float | None = None) -> Request:
        """File or refresh the request for `count` purchases at `price` each, `capacity` of them possible now."""
        request = self.book.get(key)
        if request is None:
            self._serial += 1
            request = self.book[key] = Request(id=f"{self.name}-{self._serial}", dept=self.name, key=key, item=item,
                                               created_at=self.field.now)
            self.notes.append(f"request {request.id} opened: {item}")
        price = {r: float(a) for r, a in price.items() if a}
        request.count, request.pop, request.needs = count, pop, tuple(needs)
        request.remaining = dict(total) if total is not None else {r: a * count for r, a in price.items()}
        request.tranche = {} if needs else {r: a * min(count, capacity) for r, a in price.items() if min(count, capacity) > 0}
        request.urgency, request.rank, request.origin = max(0, min(3, urgency)), rank, origin
        request.floor, request.emergency = floor, emergency
        if patience is not None:
            request.patience = patience
        self._wanted.add(key)
        return request

    def settle(self) -> None:
        """Close every request nobody asked for again this tick."""
        for key in [k for k in self.book if k not in self._wanted]:
            self.notes.append(f"request {self.book.pop(key).id} closed")

    def building_wishes(self, f) -> None:
        """File a request for each building the field engine asked for on this department's behalf."""
        engine = self.field
        sites = {o.get("building_def_id") for o in f.context.get("construction_options", []) if isinstance(o, dict)}
        # Highest priority first, so equal ranks keep the builders' old order.
        for priority, name, reason in sorted(engine.build_requests, reverse=True):
            if BUILDING_OWNER.get(reason, DEFAULT_OWNER) != self.name:
                continue
            # One foundation of a kind at a time, as the builders always worked.
            if engine._foundation_under_way(f, name):
                continue
            definition = f.building_defs[name]
            locked = not engine._unlocked_for_saving(f, definition)
            self.want(("building", name), name, definition.get("cost", {}), capacity=1 if name in sites else 0,
                      needs=(str(definition.get("blocked_reason") or "locked"),) if locked else (),
                      urgency=urgency_of(priority), rank=priority,
                      floor=reason == "population_headroom" and priority >= POPULATION_CAPPED)
