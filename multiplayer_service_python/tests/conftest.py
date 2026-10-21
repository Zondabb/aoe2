import pytest


@pytest.fixture(autouse=True)
def isolated_leaderboard(tmp_path, monkeypatch):
    # WebSocket service tests must not read or modify local players' real stats.
    monkeypatch.setenv("AOE2_MP_LEADERBOARD_DB", str(tmp_path / "leaderboard.sqlite3"))
