"""The premier's words for the player: when it speaks, cut into sentences, handed to the game once.

The game shows each line as a subtitle and reads it aloud. A line travels in
exactly one tick response; asking for the same tick again returns the cached
response, so nothing is lost and nothing is said twice.
"""
from __future__ import annotations

from dataclasses import dataclass
import re
import time

# What makes the premier speak. The game plays one broadcast and keeps one
# waiting; a higher priority may cut in on a lower one.
THREAT = "threat"     # a ranking made because the danger grew: cuts in on anything
ORDER = "order"       # the answer to an order of the head of state: cuts in on routine news
CHANGE = "change"     # a ranking that moved a request or the posture
DONE = "done"         # an order has been carried out
PRIORITY = {THREAT: 2, ORDER: 1, CHANGE: 0, DONE: 0}
# Routine news is not read out more often than this (game seconds). Answers to orders and danger are never held back.
CHANGE_SPACING = 60.0
# One breath of speech and one line of subtitle; a broadcast is never longer than this many of each kind.
MAX_SENTENCES = 4
_SENTENCE_END = re.compile(r"(?<=[。！？!?；;])")


def sentences(text: str) -> list[str]:
    """Cut a text at its sentence ends, keeping the punctuation; marks on their own are dropped."""
    parts = (part.strip() for part in _SENTENCE_END.split(str(text or "").replace("\n", " ")))
    return [part for part in parts if any(ch.isalnum() for ch in part)]


def joined(*parts: str) -> str:
    """Several remarks as one text, each closed as a sentence."""
    closed = []
    for part in parts:
        part = str(part or "").strip()
        if part:
            closed.append(part if part[-1] in "。！？!?；;" else part + "。")
    return "".join(closed)


@dataclass
class Broadcast:
    id: str
    trigger: str
    thinking: str
    decision: str
    at: float                      # game seconds when it was raised
    order: int | None = None       # the order it answers
    about: str = ""                # that order's words, for the panel's heading
    since: float | None = None     # game seconds when what it answers happened
    since_wall: float | None = None

    @property
    def priority(self) -> int:
        return PRIORITY[self.trigger]

    def lines(self) -> list[dict]:
        rows = [("thinking", text) for text in sentences(self.thinking)[:MAX_SENTENCES]]
        rows += [("decision", text) for text in sentences(self.decision)[:MAX_SENTENCES]]
        lines = [{"id": self.id, "seq": seq, "kind": kind, "text": text, "trigger": self.trigger, "priority": self.priority}
                 for seq, (kind, text) in enumerate(rows)]
        for line in lines:
            if self.order is not None:
                line.update(order=self.order, about=self.about)
        if lines:
            lines[-1]["final"] = True
        return lines


class Broadcaster:
    """Collects what the premier has to say during a tick and hands the lines out with that tick's response."""

    def __init__(self, stamp: str | None = None, clock=time.monotonic) -> None:
        # Ids must not repeat after the service restarts in the middle of a match: the game drops lines it has seen.
        self.stamp = stamp if stamp is not None else format(int(time.time()) % 36 ** 4, "x")
        self.clock = clock
        self.count = 0
        self.pending: list[Broadcast] = []
        self.events: list[dict] = []         # for the match log
        self.last_change = -CHANGE_SPACING   # game seconds of the last routine news read out

    def say(self, trigger: str, thinking: str, decision: str, now: float, *, order: int | None = None, about: str = "",
            since: float | None = None, since_wall: float | None = None) -> Broadcast | None:
        """Raise a broadcast. Routine news too soon after the last, or with nothing to read, is dropped."""
        if not sentences(thinking) and not sentences(decision):
            return None
        if trigger == CHANGE:
            if now - self.last_change < CHANGE_SPACING:
                return None
            self.last_change = now
        self.count += 1
        broadcast = Broadcast(f"b{self.stamp}-{self.count}", trigger, thinking, decision, float(now), order, about, since, since_wall)
        self.pending.append(broadcast)
        return broadcast

    def take(self, now: float) -> list[dict]:
        """This tick's lines, the most urgent broadcast first. Each line is handed out once."""
        pending, self.pending = sorted(self.pending, key=lambda b: -b.priority), []
        lines = []
        for broadcast in pending:
            mine = broadcast.lines()
            lines += mine
            event = {"id": broadcast.id, "trigger": broadcast.trigger, "priority": broadcast.priority, "lines": len(mine),
                     "chars": sum(len(line["text"]) for line in mine), "thinking": broadcast.thinking, "decision": broadcast.decision}
            if broadcast.order is not None:
                event.update(order=broadcast.order, about=broadcast.about)
            if broadcast.since is not None:
                event["after_game_sec"] = round(now - broadcast.since, 2)
            if broadcast.since_wall is not None:
                event["after_wall_sec"] = round(self.clock() - broadcast.since_wall, 3)
            self.events.append(event)
        return lines

    def take_events(self) -> list[dict]:
        events, self.events = self.events, []
        return events
