"""The treasury ledger: which request each part of the real stock is set aside for.

The premier decides the order (tiers); this ledger does the arithmetic. It is
recomputed from the observed stock on every tick, in funding order, so the
earmarks can never exceed what the game really holds: money the game has taken
for an order already sent is not in the stock any more, and money the player
spent by hand is lost by the requests at the back of the queue first.
"""
from __future__ import annotations

from collections import deque
from contextlib import contextmanager

from .models import RESOURCES, Request

TIER_ORDER = {"now": 0, "next": 1, "later": 2}
DEFAULT_TIER = "later"
INCOME_WINDOW = 60.0
# A request that holds money and for as long as its patience has neither
# gathered more nor bought anything, or has been holding for SAVING_LIMIT,
# steps to the back of the line for YIELD_SECONDS. Without this a purchase
# whose resource is not coming in, or one the game keeps refusing, would keep
# cheaper purchases of the same resource waiting for ever.
SAVING_LIMIT, YIELD_SECONDS = 300.0, 15.0


def funding_order(requests: list[Request], tiers: dict[str, str]) -> list[Request]:
    """Funded requests, first in line first: tier, then urgency, the department's
    own order, and age. Requests on hold are not in the line."""
    line = [r for r in requests if tiers.get(r.id, DEFAULT_TIER) in TIER_ORDER]
    return sorted(line, key=lambda r: (TIER_ORDER[tiers.get(r.id, DEFAULT_TIER)], -r.urgency, -r.rank, r.created_at, r.id))


class Treasury:
    def __init__(self) -> None:
        # escrow is what each request still holds; granted is what it was
        # given this tick, before any of it was spent.
        self.escrow: dict[str, dict[str, float]] = {}
        self.granted: dict[str, dict[str, float]] = {}
        self.tiers: dict[str, str] = {}
        self.unallocated: dict[str, float] = {r: 0.0 for r in RESOURCES}
        self.yielding: set[str] = set()
        self._saving: dict[str, dict] = {}
        self._gains: deque = deque()
        self._last_stock: dict[str, float] | None = None
        self._first_seen: float | None = None
        self._now = 0.0

    # ------------------------------------------------------------------ income
    def observe(self, now: float, stock: dict) -> None:
        """Record deliveries: every rise of the observed stock in the last minute."""
        stock = {r: float(stock.get(r, 0)) for r in RESOURCES}
        if self._first_seen is None:
            self._first_seen = now
        if self._last_stock is not None:
            gain = {r: stock[r] - self._last_stock[r] for r in RESOURCES if stock[r] > self._last_stock[r]}
            if gain:
                self._gains.append((now, gain))
        self._last_stock = stock
        while self._gains and now - self._gains[0][0] > INCOME_WINDOW:
            self._gains.popleft()
        self._now = now

    def income(self) -> dict[str, float]:
        """Resources delivered per second over the last minute."""
        if self._first_seen is None:
            return {r: 0.0 for r in RESOURCES}
        span = max(1.0, min(INCOME_WINDOW, self._now - self._first_seen))
        return {r: sum(gain.get(r, 0.0) for _, gain in self._gains) / span for r in RESOURCES}

    # ------------------------------------------------------------------ funding
    def line(self, requests: list[Request], tiers: dict[str, str]) -> list[Request]:
        """The funding order with yielding requests moved to the back."""
        line = funding_order(requests, tiers)
        return [r for r in line if r.id not in self.yielding] + [r for r in line if r.id in self.yielding]

    def allocate(self, stock: dict, requests: list[Request], tiers: dict[str, str], now: float | None = None) -> None:
        """Set the stock aside request by request, each up to its tranche."""
        now = self._now if now is None else now
        self.tiers = {r.id: tiers.get(r.id, DEFAULT_TIER) for r in requests}
        self.yielding = {rid for rid, saving in self._saving.items() if saving["yield_until"] > now}
        self._fund(stock, requests, tiers)
        if self._watch_savings(requests, now):
            self._fund(stock, requests, tiers)      # someone just stepped back

    def _fund(self, stock: dict, requests: list[Request], tiers: dict[str, str]) -> None:
        available = {r: max(0.0, float(stock.get(r, 0))) for r in RESOURCES}
        escrow: dict[str, dict[str, float]] = {r.id: {} for r in requests}
        for request in self.line(requests, tiers):
            for resource, amount in request.tranche.items():
                grant = min(float(amount), available[resource])
                if grant > 0:
                    escrow[request.id][resource] = grant
                    available[resource] -= grant
        self.escrow, self.unallocated = escrow, available
        self.granted = {rid: dict(held) for rid, held in escrow.items()}

    def _watch_savings(self, requests: list[Request], now: float) -> bool:
        """Track what each request holds without spending; True when one starts to yield."""
        stepped_back = False
        fresh = lambda start: {"best": -1.0, "progress_at": start, "started": start, "yield_until": 0.0}
        watched = {}
        for request in requests:
            saving = self._saving.get(request.id) or fresh(now)
            if request.id not in self.yielding:
                held = sum(self.escrow[request.id].values())
                if held <= 0:
                    saving = fresh(now)             # holding nothing back from anyone
                else:
                    if held > saving["best"]:
                        saving["best"], saving["progress_at"] = held, now
                    if now - saving["progress_at"] > request.patience or now - saving["started"] > SAVING_LIMIT:
                        saving = {**fresh(now + YIELD_SECONDS), "yield_until": now + YIELD_SECONDS}
                        self.yielding.add(request.id)
                        stepped_back = True
            watched[request.id] = saving
        self._saving = watched
        return stepped_back

    def held(self, request_id: str) -> dict[str, float]:
        return dict(self.escrow.get(request_id, {}))

    def spent(self, request_id: str) -> dict[str, float]:
        """What this request has paid out since the stock was last set aside."""
        granted, held = self.granted.get(request_id, {}), self.escrow.get(request_id, {})
        return {r: amount - held.get(r, 0.0) for r, amount in granted.items() if amount - held.get(r, 0.0) > 1e-9}

    def covers(self, request_id: str, cost: dict) -> bool:
        held = self.escrow.get(request_id, {})
        return all(held.get(r, 0.0) >= amount for r, amount in cost.items())

    def gap(self, request: Request) -> dict[str, float]:
        """What this request's next purchase was short of when the stock was set aside.

        Money it has spent since then is not a shortfall."""
        granted = self.granted.get(request.id, {})
        return {r: amount - granted.get(r, 0.0) for r, amount in request.tranche.items() if amount - granted.get(r, 0.0) > 1e-9}

    def eta(self, request: Request) -> float | None:
        """Seconds until the gap closes at the recent income; None when nothing is coming in."""
        gap, income = self.gap(request), self.income()
        if not gap:
            return 0.0
        if any(income[r] <= 0 for r in gap):
            return None
        return round(max(amount / income[r] for r, amount in gap.items()), 1)

    @contextmanager
    def purse(self, f, request_id: str):
        """Let the frame see only this request's money while an order is added.

        Whatever the order costs leaves both the earmark and the real stock."""
        held = self.escrow.setdefault(request_id, {})
        real = f.budget
        f.budget = {r: float(held.get(r, 0.0)) for r in RESOURCES}
        try:
            yield
        finally:
            bought = False
            for resource in RESOURCES:
                spent = float(held.get(resource, 0.0)) - f.budget[resource]
                if spent > 0:
                    held[resource] = f.budget[resource]
                    real[resource] -= spent
                    bought = True
            if bought:
                self._saving.pop(request_id, None)      # a purchase is progress
            f.budget = real

    def summary(self) -> dict:
        return {"unallocated": {r: round(v, 1) for r, v in self.unallocated.items()},
                "income_per_min": {r: round(v * 60, 1) for r, v in self.income().items()}}
