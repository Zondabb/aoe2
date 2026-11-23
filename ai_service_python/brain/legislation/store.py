"""Atomic per-session checkpoints and immutable tick responses."""
import json
from pathlib import Path
import sqlite3


class SessionStore:
    def __init__(self, root):
        Path(root).mkdir(parents=True, exist_ok=True)
        self.path = Path(root) / "sessions.sqlite3"
        with self.connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS sessions (identity TEXT PRIMARY KEY, payload TEXT NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS ticks (identity TEXT, seq INTEGER, fingerprint TEXT, response TEXT, PRIMARY KEY(identity,seq))")

    def connect(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.execute("PRAGMA synchronous=FULL")
        return db

    def load(self, identity):
        with self.connect() as db:
            row = db.execute("SELECT payload FROM sessions WHERE identity=?", (identity,)).fetchone()
            return json.loads(row[0]) if row else None

    def response(self, identity, seq, fingerprint):
        with self.connect() as db:
            row = db.execute("SELECT fingerprint,response FROM ticks WHERE identity=? AND seq=?", (identity, seq)).fetchone()
        if row and row[0] != fingerprint:
            raise ValueError("observation_seq_conflict")
        return json.loads(row[1]) if row else None

    def save(self, identity, record, tick=None):
        payload = json.dumps(record, allow_nan=False, separators=(",", ":"))
        with self.connect() as db:
            if tick:
                seq, fingerprint, response = tick
                db.execute("INSERT INTO ticks VALUES (?,?,?,?)", (identity, seq, fingerprint,
                           json.dumps(response, allow_nan=False, separators=(",", ":"))))
            db.execute("INSERT INTO sessions VALUES (?,?) ON CONFLICT(identity) DO UPDATE SET payload=excluded.payload",
                       (identity, payload))
