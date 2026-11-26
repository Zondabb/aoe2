"""Tests for tools/check_legislation.py read-only diagnostics."""
import json
from pathlib import Path
import sqlite3
import subprocess
import sys


def test_check_legislation_displays_rollbacks_grouped_steps_and_coding_state(tmp_path):
    match_id = "m_test_diag_1"
    logs_dir = tmp_path / "logs"
    data_dir = tmp_path / "legislation_data"
    logs_dir.mkdir()
    data_dir.mkdir()

    rows = [
        {"event": "order", "match_id": match_id, "sim_time": 63.0, "team": 0, "id": 1,
         "change": "received", "status": "新下达", "text": "农田紧贴建造"},
        {"event": "model_result", "match_id": match_id, "sim_time": 90.0, "team": 0,
         "agent": "legislative_council", "legislation_step": 1, "state": "applied",
         "plan": {"proposal_id": "order-1", "action": "read",
                  "path": "brain/cabinet/departments/economy.py", "start_line": 65}},
        {"event": "legislation_rollback", "match_id": match_id, "sim_time": 367.0, "team": 0,
         "release": "666569af0995dee16ff2e11d", "reason": "AttributeError: 'list' object has no attribute 'get'"},
        {"event": "order", "match_id": match_id, "sim_time": 367.0, "team": 0, "id": 1,
         "change": "legislation_failed", "status": "立法失败", "text": "农田紧贴建造",
         "reason": "source_rolled_back"},
        {"event": "order", "match_id": match_id, "sim_time": 1850.0, "team": 0, "id": 5,
         "change": "legislation_progress", "status": "等待立法", "text": "多种田",
         "proposal_id": "order-5", "phase": "retrying", "step": 7, "reason": "edit_requires_current_read"},
        {"event": "model_result", "match_id": match_id, "sim_time": 1820.0, "team": 0,
         "agent": "legislative_council", "legislation_step": 7, "state": "invalid_plan",
         "plan": {"proposal_id": "order-5", "action": "edit",
                  "path": "brain/cabinet/departments/economy.py"}},
    ]
    (logs_dir / "multi_agent.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")

    db = data_dir / "sessions.sqlite3"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE sessions (identity TEXT PRIMARY KEY, payload TEXT NOT NULL)")
    payload = {
        "base": "a" * 64,
        "release": "a" * 64,
        "coding": {
            "requirement": {"proposal_id": "order-5"},
            "data": {"status": "failed", "steps": 9, "failures": 3,
                     "feedback": {"error": "edit_requires_current_read"}},
        },
    }
    con.execute("INSERT INTO sessions VALUES (?, ?)",
                (json.dumps([match_id, 0, "1", "chinese"]), json.dumps(payload)))
    con.commit()
    con.close()

    script = Path(__file__).resolve().parents[1] / "tools" / "check_legislation.py"
    proc = subprocess.run([sys.executable, str(script), match_id, str(tmp_path)],
                          capture_output=True, text=True, encoding="utf-8", check=True)
    out = proc.stdout
    assert "AttributeError: 'list' object has no attribute 'get'" in out
    assert "edit_requires_current_read" in out
    assert "[order-1]" in out and "[order-5]" in out
    assert "economy.py:L65" in out
    assert "coding : proposal=order-5 status=failed steps=9 failures=3" in out
