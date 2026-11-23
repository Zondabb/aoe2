"""The premier's ledger of the head of state's orders.

The game sends the player's last few instructions with every observation.
That window is only transport: an order stays in the ledger after it has
slid out of the window, until it is carried out, replaced by a later order
or the player clears the instructions (which is how managed play is ended).
"""
from __future__ import annotations

from dataclasses import dataclass, field
import copy

from .models import Mandate, order_origin
from .orders import Grounding, name_of, slot

NEW, ACTIVE, DONE, SUPERSEDED, IMPOSSIBLE = "new", "active", "done", "superseded", "impossible"
WAITING_LEGISLATION = "waiting_legislation"
LABELS = {NEW: "新下达", ACTIVE: "执行中", DONE: "已完成", SUPERSEDED: "已取代", IMPOSSIBLE: "无法执行",
          WAITING_LEGISLATION: "等待立法"}
OPEN = (NEW, ACTIVE, WAITING_LEGISLATION)
MAX_TRIES = 2               # an interpretation the catalog refuses is asked for once more
KEPT = 12                   # closed orders remembered for the panel and the log
REFUSED = "这条指令没法落到游戏里能做的事上，暂不执行。"
# Reading an order takes a model. An order nobody has read after this many game seconds says why in the ledger.
UNREAD_AFTER = 15.0
UNREAD = "没有接通模型，这条指令还没有解读。"
UNANSWERED = "模型还没有给出能用的解读，稍后再问。"


@dataclass
class Order:
    number: int
    text: str
    received_at: float
    status: str = NEW
    grasp: str | None = None
    thinking: str = ""
    decision: str = ""
    notes: list[str] = field(default_factory=list)
    mandates: list[Mandate] = field(default_factory=list)
    done: set[tuple] = field(default_factory=set)        # slots of mandates already carried out
    figures: dict[tuple, str] = field(default_factory=dict)
    tries: int = 0                                         # readings the model has given
    asked: int = 0                                         # times the order was put to the model
    problem: str = ""                                      # why the last interpretation was sent back
    refused: list = field(default_factory=list)            # the mandates of that interpretation, as the model gave them
    waiting: str = ""                                      # why it has not been interpreted yet
    legislation: dict | None = None

    def label(self) -> str:
        if self.status == ACTIVE:
            figure = next((self.figures[slot(m)] for m in self.mandates if self.figures.get(slot(m))), "")
            return f"{LABELS[ACTIVE]} {figure}".strip()
        return LABELS[self.status]

    def row(self) -> dict:
        """One line for the model: what was asked and where it stands."""
        return {"id": self.number, "text": self.text, "status": self.label()}

    def detail(self) -> dict:
        """The full entry for the game's panel and the tick log."""
        entry = {**self.row(), "state": self.status}
        if self.grasp:
            entry.update(grasp=self.grasp, thinking=self.thinking, decision=self.decision)
        if self.notes:
            entry["notes"] = list(self.notes)
        if self.mandates:
            entry["mandates"] = [describe(m, slot(m) in self.done) for m in self.mandates]
        if self.legislation:
            entry["legislation"] = dict(self.legislation)
        if self.status in (NEW, WAITING_LEGISLATION) and (self.waiting or self.problem):
            entry["waiting"] = self.waiting or self.problem
        return entry


def describe(mandate: Mandate, done: bool = False) -> dict:
    entry = {"dept": mandate.dept, "kind": mandate.kind, "urgency": mandate.urgency, "done": done}
    if mandate.subject:
        entry.update(subject=mandate.subject, name=name_of(mandate.subject))
    if mandate.amount is not None:
        entry["amount"] = mandate.amount
    return entry


class OrderLedger:
    def __init__(self) -> None:
        self.orders: list[Order] = []
        self.window: tuple[str, ...] = ()
        self.serial = 0
        # Bumped whenever the set of mandates in force may have changed.
        self.revision = 0
        self.events: list[dict] = []     # status changes since the runtime last wrote them to the match log

    # ------------------------------------------------------------------ intake
    def intake(self, window: list[str] | tuple[str, ...], now: float) -> list[Order]:
        """Read the game's instruction window; return the orders that are new."""
        window = tuple(str(text) for text in window)
        previous, self.window = self.window, window
        if not window:
            self.clear("cleared_by_player")
            return []
        fresh = [self._file(text, now) for text in window[self._overlap(previous, window):]]
        return fresh

    @staticmethod
    def _overlap(previous: tuple[str, ...], window: tuple[str, ...]) -> int:
        """How many leading entries of the new window were already at the end of the old one."""
        for kept in range(min(len(previous), len(window)), 0, -1):
            if previous[-kept:] == window[:kept]:
                return kept
        return 0

    def _file(self, text: str, now: float) -> Order:
        self.serial += 1
        order = Order(self.serial, text, float(now))
        self.orders.append(order)
        self._note(order, "received")
        return order

    def clear(self, reason: str) -> None:
        for order in self.orders:
            if order.status in OPEN:
                self._note(order, "cancelled", reason=reason)
        if self.orders:
            self.revision += 1
        self.orders = []

    # ------------------------------------------------------------------ interpretation
    def pending(self) -> Order | None:
        """The oldest order still waiting to be interpreted."""
        return next((order for order in self.orders if order.status == NEW), None)

    def note_unread(self, now: float) -> None:
        """Say why an order is still waiting: no model was asked, or it was asked and gave nothing usable."""
        for order in self.orders:
            if order.status == NEW and not order.problem and now - order.received_at >= UNREAD_AFTER:
                order.waiting = UNANSWERED if order.asked else UNREAD

    def find(self, number: int) -> Order | None:
        return next((order for order in self.orders if order.number == number), None)

    def accept(self, order: Order, grasp: str, thinking: str, decision: str, grounding: Grounding, raw: list | None = None) -> str:
        """Take the model's reading of an order. Returns "active", "impossible" or "retry"."""
        order.tries += 1
        order.waiting = ""
        if grasp != "none" and grounding.problems and order.tries < MAX_TRIES:
            order.problem, order.refused = "；".join(grounding.problems), list(raw or [])
            self._note(order, "sent_back", problem=order.problem)
            return "retry"
        order.grasp, order.thinking, order.decision = grasp, thinking, decision
        order.notes, order.problem = list(grounding.notes), ""
        if grasp == "none" or not grounding.mandates:
            if grasp != "none":
                # The catalog refused it twice: say so in the ledger's own words.
                order.grasp, order.decision = "none", REFUSED
                order.notes = list(grounding.problems)
            order.status, order.mandates = IMPOSSIBLE, []
            self._note(order, "impossible")
            return IMPOSSIBLE
        order.status, order.mandates = ACTIVE, list(grounding.mandates)
        self._supersede(order)
        self.revision += 1
        self._note(order, "interpreted")
        return ACTIVE

    def _supersede(self, latest: Order) -> None:
        """A later order takes the slots it names from every earlier one."""
        taken = {slot(m) for m in latest.mandates}
        for order in self.orders:
            if order is latest or order.status not in (ACTIVE, WAITING_LEGISLATION):
                continue
            kept = [m for m in order.mandates if slot(m) not in taken]
            if len(kept) != len(order.mandates):
                order.mandates = kept
                if not order.legislation and all(slot(m) in order.done for m in kept):
                    order.status = SUPERSEDED if not kept else DONE
                    self._note(order, order.status, by=latest.number)

    def refer_legislation(self, order: Order, grasp: str, thinking: str, decision: str,
                         grounding: Grounding, requirement: dict) -> None:
        """Freeze a code gap while its independent ordinary mandates keep running."""
        order.tries += 1
        order.grasp, order.thinking, order.decision = grasp, thinking, decision
        order.notes, order.problem = list(grounding.notes), ""
        order.status, order.mandates = WAITING_LEGISLATION, list(grounding.mandates)
        order.legislation = copy.deepcopy(requirement)
        order.waiting = "等待立法会验证并安装新的部门算法。"
        self._supersede(order)
        self.revision += 1
        self._note(order, "legislation_requested", proposal_id=requirement["proposal_id"])

    def legislation_result(self, proposal_id: str, status: str, reason: str = "") -> bool:
        """Installation is progress, never proof that the player's goal was met."""
        if status not in ("installed", "failed", "revoked"):
            return False
        order = next((o for o in self.orders if o.status in OPEN and o.legislation
                      and o.legislation["proposal_id"] == proposal_id), None)
        if order is None:
            return False
        order.legislation.update(status=status, reason=str(reason)[:1000])
        order.status = ACTIVE if status == "installed" else (SUPERSEDED if status == "revoked" else WAITING_LEGISLATION)
        order.waiting = "" if status == "installed" else (str(reason)[:1000] or "法案尚未生效，原有任务继续。")
        self.revision += 1
        self._note(order, "legislation_" + status, proposal_id=proposal_id, reason=str(reason)[:1000])
        return True

    # ------------------------------------------------------------------ every tick
    def mandates(self) -> list[Mandate]:
        """What the open orders still ask for, oldest order first."""
        return [m for order in self.orders if order.status in (ACTIVE, WAITING_LEGISLATION)
                for m in order.mandates if slot(m) not in order.done]

    def record(self, order: Order, mandate: Mandate, finished: bool, figure: str) -> None:
        """Note how far one mandate has got; close the order when all of its mandates are carried out."""
        key = slot(mandate)
        order.figures[key] = figure
        if finished and key not in order.done:
            order.done.add(key)
            self.revision += 1
            if not order.legislation and all(slot(m) in order.done for m in order.mandates):
                order.status = DONE
                self._note(order, DONE)

    def active(self) -> list[Order]:
        return [order for order in self.orders if order.status in (ACTIVE, WAITING_LEGISLATION)]

    def prune(self) -> None:
        closed = [order for order in self.orders if order.status not in OPEN]
        for order in closed[:-KEPT] if len(closed) > KEPT else []:
            self.orders.remove(order)

    # ------------------------------------------------------------------ reading
    def rows(self) -> list[dict]:
        return [order.row() for order in self.orders if order.status in OPEN]

    def details(self) -> list[dict]:
        return [order.detail() for order in self.orders]

    def origin(self, order: Order) -> str:
        return order_origin(order.number)

    def _note(self, order: Order, change: str, **extra) -> None:
        self.events.append({"change": change, "id": order.number, "text": order.text, "status": order.label(), **extra})

    def take_events(self) -> list[dict]:
        events, self.events = self.events, []
        return events
