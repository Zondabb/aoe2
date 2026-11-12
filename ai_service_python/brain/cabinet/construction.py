"""The shared construction crew: departments say what to build, the crew picks the site and the builder."""
from __future__ import annotations

from .models import Request
from .treasury import Treasury


class ConstructionCrew:
    def __init__(self, field, treasury: Treasury) -> None:
        self.field, self.treasury = field, treasury

    def work(self, f, requests: list[Request]) -> Request | None:
        """Staff open foundations, then start the first funded building that has a legal site.

        `requests` are building requests in funding order. The game accepts
        one new foundation per decision."""
        engine = self.field
        if engine._staff_foundations(f) >= engine.roles["construction"].plan["max_builders"]:
            engine._status("construction", "running", "complete_active_foundations")
            return None
        for request in requests:
            name = request.key[1]
            # The purse would refuse it anyway; this only saves scoring sites
            # for a request that cannot pay yet.
            if not self.treasury.covers(request.id, f.building_defs[name].get("cost", {})):
                continue
            for option in engine._building_sites(f, name):
                with self.treasury.purse(f, request.id):
                    placed = engine._emit(f, "construction", "place_building",
                                          {k: option[k] for k in ("builder_id", "building_def_id", "pos")})
                if placed:
                    engine._status("construction", "running", f"build_{name}")
                    return request
        engine._status("construction", "waiting", "budget_or_legal_site")
        return None
