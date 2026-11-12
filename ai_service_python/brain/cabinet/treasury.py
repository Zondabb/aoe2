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


def funding_order(requests: list[Request], tiers: dict[str, str]) -> list[Request]:
    """Funded requests, first in line first: tier, then urgency, the department's
    own order, and age. Requests on hold are not in the line."""
    line = [r for r in requests if tiers.get(r.id, DEFAULT_TIER) in TIER_ORDER]
    return sorted(line, key=lambda r: (TIER_ORDER[tiers.get(r.id, DEFAULT_TIER)], -r.urgency, -r.rank, r.created_at, r.id))


class Treasury:
    def __init__(self) -> None:
        self.escrow: dict[str, dict[str, float]] = {}
        self.tiers: dict[str, str] = {}
        self.unallocated: dict[str, float] = {r: 0.0 for r in RESOURCES}
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
    def allocate(self, stock: dict, requests: list[Request], tiers: dict[str, str]) -> None:
        """Set the stock aside request by request, each up to its tranche."""
        available = {r: max(0.0, float(stock.get(r, 0))) for r in RESOURCES}
        escrow: dict[str, dict[str, float]] = {r.id: {} for r in requests}
        for request in funding_order(requests, tiers):
            for resource, amount in request.tranche.items():
                grant = min(float(amount), available[resource])
                if grant > 0:
                    escrow[request.id][resource] = grant
                    available[resource] -= grant
        self.escrow, self.unallocated = escrow, available
        self.tiers = {r.id: tiers.get(r.id, DEFAULT_TIER) for r in requests}

    def held(self, request_id: str) -> dict[str, float]:
        return dict(self.escrow.get(request_id, {}))

    def covers(self, request_id: str, cost: dict) -> bool:
        held = self.escrow.get(request_id, {})
        return all(held.get(r, 0.0) >= amount for r, amount in cost.items())

    def gap(self, request: Request) -> dict[str, float]:
        """What the next purchase of this request is still short of."""
        held = self.escrow.get(request.id, {})
        return {r: amount - held.get(r, 0.0) for r, amount in request.tranche.items() if amount - held.get(r, 0.0) > 1e-9}

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
            for resource in RESOURCES:
                spent = float(held.get(resource, 0.0)) - f.budget[resource]
                if spent > 0:
                    held[resource] = f.budget[resource]
                    real[resource] -= spent
            f.budget = real

    def summary(self) -> dict:
        return {"unallocated": {r: round(v, 1) for r, v in self.unallocated.items()},
                "income_per_min": {r: round(v * 60, 1) for r, v in self.income().items()}}
