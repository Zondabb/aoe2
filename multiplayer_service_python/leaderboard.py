from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
import sqlite3
import threading
import unicodedata


SORTS = {
    "win_rate": "CASE WHEN games > 0 THEN 1.0 * wins / games ELSE -1 END DESC, wins DESC, games DESC, name ASC",
    "wins": "wins DESC, games DESC, name ASC",
    "games": "games DESC, wins DESC, name ASC",
}


class Leaderboard:
    """Nickname-based standings; each match and both counters commit atomically."""

    def __init__(self, path: str):
        if path != ":memory:":
            Path(path).expanduser().resolve().parent.mkdir(parents=True, exist_ok=True)
            path = str(Path(path).expanduser())
        self._lock = threading.RLock()
        self._db = sqlite3.connect(path, check_same_thread=False, timeout=2)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA foreign_keys=ON")
        self._db.executescript("""
            CREATE TABLE IF NOT EXISTS players (
                name TEXT PRIMARY KEY,
                wins INTEGER NOT NULL DEFAULT 0 CHECK (wins >= 0),
                games INTEGER NOT NULL DEFAULT 0 CHECK (games >= wins),
                last_played_at TEXT
            );
            CREATE TABLE IF NOT EXISTS match_results (
                match_id TEXT PRIMARY KEY,
                player_0 TEXT NOT NULL REFERENCES players(name),
                player_1 TEXT NOT NULL REFERENCES players(name),
                winner INTEGER NOT NULL CHECK (winner IN (0, 1)),
                reason TEXT NOT NULL,
                finished_at TEXT NOT NULL
            );
        """)

    @staticmethod
    def player_name(name: str) -> str:
        return unicodedata.normalize("NFC", name.strip())

    def register(self, name: str) -> None:
        with self._lock, self._db:
            self._db.execute("INSERT OR IGNORE INTO players(name) VALUES (?)", (self.player_name(name),))

    def record(self, match_id: str, names: tuple[str, str], winner: int, reason: str) -> bool:
        first, second = (self.player_name(name) for name in names)
        # Same-nickname games still work, but cannot create a self-win/loss.
        if first == second or not first or not second or type(winner) is not int or winner not in (0, 1):
            return False
        if reason not in ("completed", "opponent_left"):
            return False
        finished = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
        with self._lock, self._db:
            self._db.execute("BEGIN IMMEDIATE")
            if self._db.execute("SELECT 1 FROM match_results WHERE match_id = ?", (match_id,)).fetchone():
                return False
            for name in (first, second):
                self._db.execute("INSERT OR IGNORE INTO players(name) VALUES (?)", (name,))
            inserted = self._db.execute("""
                INSERT INTO match_results(match_id, player_0, player_1, winner, reason, finished_at)
                VALUES (?, ?, ?, ?, ?, ?)
            """, (match_id, first, second, winner, reason, finished))
            if inserted.rowcount == 0:
                return False
            for team, name in enumerate((first, second)):
                self._db.execute("""
                    UPDATE players SET wins = wins + ?, games = games + 1, last_played_at = ? WHERE name = ?
                """, (int(team == winner), finished, name))
        return True

    def standings(self, *, sort: str = "win_rate", query: str = "", limit: int = 20, offset: int = 0) -> dict:
        if sort not in SORTS or not 1 <= limit <= 100 or offset < 0:
            raise ValueError("Invalid leaderboard query")
        # Search is a literal substring, including any %, _ or backslashes.
        query = self.player_name(query)
        escaped = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        pattern = f"%{escaped}%"
        with self._lock:
            rows = self._db.execute(f"""
                WITH ranked AS (
                    SELECT ROW_NUMBER() OVER (ORDER BY {SORTS[sort]}) AS rank, name, wins, games FROM players
                )
                SELECT * FROM ranked WHERE name LIKE ? ESCAPE '\\' ORDER BY rank LIMIT ? OFFSET ?
            """, (pattern, limit, offset)).fetchall()
            total = self._db.execute("SELECT COUNT(*) FROM players WHERE name LIKE ? ESCAPE '\\'", (pattern,)).fetchone()[0]
            total_players = self._db.execute("SELECT COUNT(*) FROM players").fetchone()[0]
            matches, updated = self._db.execute("SELECT COUNT(*), MAX(finished_at) FROM match_results").fetchone()
        return {
            "players": [{"rank": row["rank"], "name": row["name"], "wins": row["wins"], "games": row["games"],
                         "win_rate": round(100 * row["wins"] / row["games"], 2) if row["games"] else 0.0}
                        for row in rows],
            "total": total, "total_players": total_players, "completed_matches": matches,
            "updated_at": updated, "sort": sort, "limit": limit, "offset": offset,
        }

    def close(self) -> None:
        with self._lock:
            self._db.close()
