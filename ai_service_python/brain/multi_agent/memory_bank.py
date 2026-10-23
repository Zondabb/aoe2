"""Cross-match strategic memory: what worked, against which enemy style.

Records are compact, derived from this team's own observations, and written
atomically after an observed match result. Nothing here can issue commands;
the commander model receives the summary as planning data.
"""
from __future__ import annotations

from collections import defaultdict
import json
import os
from pathlib import Path
import threading
import time

MAX_RECORDS = 60


class StrategyMemory:
    """``path`` may be a Path, None (in-memory only) or a callable resolved at use.

    A callable lets the service follow its configured log directory, which
    tests and per-team service instances change after import.
    """

    def __init__(self, path=None, max_records: int = MAX_RECORDS) -> None:
        self._source = path
        self._loaded_from: object = object()
        self.max_records = max_records
        self._lock = threading.Lock()
        self._records: list[dict] = []

    def _path(self) -> Path | None:
        """Resolve the current file and (re)load it when it changes. Caller holds the lock."""
        source = self._source() if callable(self._source) else self._source
        path = Path(source) if source else None
        if path != self._loaded_from:
            self._loaded_from, self._records = path, []
            if path is not None and path.exists():
                try:
                    data = json.loads(path.read_text(encoding="utf-8"))
                    self._records = [r for r in data.get("records", []) if isinstance(r, dict)][-self.max_records:]
                except (OSError, ValueError, AttributeError):
                    self._records = []
        return path

    def record(self, report: dict) -> None:
        if not isinstance(report, dict) or report.get("result") not in ("victory", "defeat"):
            return
        entry = {key: report.get(key) for key in ("match_id", "team", "profile_id", "result", "duration_sec", "doctrine",
                                                  "doctrines_used", "enemy_style", "enemy_civilization_guess", "kill_value",
                                                  "loss_value", "first_sortie_sec", "final_age", "enemy_age_at_least",
                                                  "failed_sorties", "lessons")}
        entry["recorded_at"] = round(time.time())
        with self._lock:
            path = self._path()
            if any(r.get("match_id") == entry["match_id"] and r.get("team") == entry["team"] for r in self._records):
                return
            self._records.append(entry)
            self._records = self._records[-self.max_records:]
            if path is None:
                return
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
                temporary = path.with_suffix(path.suffix + ".tmp")
                temporary.write_text(json.dumps({"version": 1, "records": self._records}, ensure_ascii=False, indent=1), encoding="utf-8")
                os.replace(temporary, path)
            except OSError:
                pass  # Memory is advisory; a read-only volume never stops play.

    def snapshot(self, profile_id: str | None = None) -> dict:
        """Win/loss tables and the latest lessons, newest first."""
        with self._lock:
            self._path()
            records = list(self._records)
        by_doctrine = defaultdict(lambda: {"wins": 0, "losses": 0})
        by_style = defaultdict(lambda: defaultdict(lambda: {"wins": 0, "losses": 0}))
        for record in records:
            outcome = "wins" if record.get("result") == "victory" else "losses"
            doctrine = record.get("doctrine") or "adaptive"
            by_doctrine[doctrine][outcome] += 1
            for style in record.get("enemy_style") or ["unknown"]:
                by_style[style][doctrine][outcome] += 1
        relevant = [r for r in reversed(records) if profile_id is None or r.get("profile_id") == profile_id] or list(reversed(records))
        lessons = []
        for record in relevant:
            for lesson in record.get("lessons") or []:
                if lesson not in lessons:
                    lessons.append(lesson)
            if len(lessons) >= 5:
                break
        return {"games": len(records),
                "record_by_doctrine": {k: dict(v) for k, v in by_doctrine.items()},
                "record_vs_style": {style: {k: dict(v) for k, v in table.items()} for style, table in by_style.items()},
                "recent_lessons": lessons[:5]}


def derive_lessons(report: dict) -> list[str]:
    """Short, evidence-based lessons from one finished match."""
    lessons = []
    styles = report.get("enemy_style") or []
    doctrine = report.get("doctrine") or "adaptive"
    kills, losses = float(report.get("kill_value") or 0), float(report.get("loss_value") or 0)
    if report.get("result") == "victory":
        lessons.append(f"{doctrine} beat {'/'.join(styles) or 'unknown'} in {report.get('duration_sec', 0):.0f}s.")
    else:
        if "early_aggression" in styles and (report.get("first_sortie_sec") is None or report.get("first_sortie_sec", 0) > 400):
            lessons.append("Enemy pressured early while our army was late: field 4-6 defenders before booming.")
        if losses > 0 and losses > 1.8 * max(1.0, kills):
            lessons.append("Fights traded poorly: respect battle_forecast and fall back under the TC when outnumbered.")
        if report.get("enemy_age_at_least", 0) > report.get("final_age", 0):
            lessons.append("Fell behind in age: raise the technology budget earlier.")
        if (report.get("failed_sorties") or 0) >= 2:
            lessons.append("Several failed sorties: wait for siege or a larger force instead of repeated small waves.")
        if not lessons:
            lessons.append(f"{doctrine} lost to {'/'.join(styles) or 'unknown'}; try a different doctrine next time.")
    return lessons[:3]
