import asyncio
from concurrent.futures import ThreadPoolExecutor
import sqlite3

from fastapi.testclient import TestClient
import pytest

from multiplayer_service_python.leaderboard import Leaderboard
from multiplayer_service_python.main import create_app
from multiplayer_service_python.matchmaking import Matchmaker
from multiplayer_service_python.protocol import ProtocolError
from multiplayer_service_python.settings import Settings


def by_name(board):
    return {row["name"]: row for row in board.standings(limit=100)["players"]}


def test_stats_accumulate_across_matches_and_restart(tmp_path):
    path = str(tmp_path / "nested" / "results.sqlite3")
    board = Leaderboard(path)
    board.register("未出战")
    board.record("one", ("阿青", "小白"), 0, "completed")
    board.record("two", ("阿青", "小白"), 1, "opponent_left")
    board.record("three", ("小白", "阿青"), 0, "completed")
    board.close()
    restored = Leaderboard(path)
    rows = by_name(restored)
    assert (rows["阿青"]["wins"], rows["阿青"]["games"], rows["阿青"]["win_rate"]) == (1, 3, 33.33)
    assert (rows["小白"]["wins"], rows["小白"]["games"], rows["小白"]["win_rate"]) == (2, 3, 66.67)
    assert rows["未出战"]["games"] == rows["未出战"]["win_rate"] == 0
    assert restored.standings()["completed_matches"] == 3
    assert restored.standings()["updated_at"].endswith("+00:00")
    restored.close()


def test_duplicate_result_is_noop_even_across_connections(tmp_path):
    path = str(tmp_path / "results.sqlite3")
    first, second = Leaderboard(path), Leaderboard(path)
    with ThreadPoolExecutor(max_workers=4) as pool:
        recorded = list(pool.map(lambda index: (first if index % 2 else second).record(
            "same-match", ("Alice", "Bob"), 1, "completed"), range(12)))
    assert recorded.count(True) == 1
    assert not second.record("same-match", ("Imposter", "Somebody"), 0, "completed")
    assert set(by_name(first)) == {"Alice", "Bob"}
    assert by_name(first)["Bob"]["wins"] == by_name(first)["Bob"]["games"] == 1
    first.close()
    second.close()


def test_failed_transaction_never_counts_only_one_player(tmp_path):
    path = str(tmp_path / "results.sqlite3")
    board = Leaderboard(path)
    for name in ("Alice", "Bob"):
        board.register(name)
    with sqlite3.connect(path) as connection:
        connection.execute("CREATE TRIGGER reject_bob BEFORE UPDATE ON players WHEN NEW.name = 'Bob' BEGIN SELECT RAISE(ABORT, 'test failure'); END")
    with pytest.raises(sqlite3.IntegrityError):
        board.record("failed", ("Alice", "Bob"), 0, "completed")
    assert all(row["games"] == 0 for row in by_name(board).values())
    assert board.standings()["completed_matches"] == 0
    with sqlite3.connect(path) as connection:
        connection.execute("DROP TRIGGER reject_bob")
    assert board.record("failed", ("Alice", "Bob"), 0, "completed")
    board.close()


def test_sort_search_and_paging_keep_global_ranks():
    board = Leaderboard(":memory:")
    board.register("Empty")
    board.record("one", ("Ace", "Busy"), 0, "completed")
    board.record("two", ("Busy", "Other"), 0, "completed")
    board.record("three", ("Busy", "Other"), 0, "completed")
    rows = board.standings()["players"]
    assert [row["name"] for row in rows] == ["Ace", "Busy", "Other", "Empty"]
    assert board.standings(sort="wins")["players"][0]["name"] == "Busy"
    assert board.standings(sort="games")["players"][0]["name"] == "Busy"
    result = board.standings(query="Bus", limit=1)
    assert result["total"] == 1 and result["players"][0]["rank"] == 2
    assert board.standings(limit=1, offset=1)["players"] == [rows[1]]
    assert board.standings(offset=100)["players"] == []
    for name in ("100%_Hero", "Another", "' OR 1=1 --"):
        board.register(name)
    assert [p["name"] for p in board.standings(query="%_")["players"]] == ["100%_Hero"]
    assert board.standings(query="' OR 1=1 --")["total"] == 1
    board.close()


def test_names_normalized_without_merging_different_case_or_counting_self_games():
    board = Leaderboard(":memory:")
    board.register(" é ")
    board.register("e\u0301")
    assert board.standings()["total_players"] == 1
    assert not board.record("same", ("é", "e\u0301"), 0, "completed")
    assert not board.record("cancelled", ("A", "B"), 0, "ready_timeout")
    assert board.record("case", ("Alice", "alice"), 0, "completed")
    board.close()


async def start_pair(matchmaker, names=("Alice", "Bob"), start=True):
    players = [await matchmaker.register(), await matchmaker.register()]
    for player, name in zip(players, names):
        await matchmaker.handle(player, {"type": "join_queue", "name": name, "civ": "chinese"})
    for player in players:
        while not player.outbox.empty():
            player.outbox.get_nowait()
    if start:
        for player in players:
            await matchmaker.handle(player, {"type": "ready"})
        for player in players:
            assert player.outbox.get_nowait()["type"] == "start"
    return players


def test_game_settlement_and_replays_use_room_identity():
    async def scenario():
        board = Leaderboard(":memory:")
        mm = Matchmaker(Settings(), leaderboard=board)
        players = await start_pair(mm)
        room = mm.rooms[players[0].room_id]
        host, guest = players[room.host_team], players[1 - room.host_team]
        with pytest.raises(ProtocolError, match="Only the host"):
            await mm.handle(guest, {"type": "finish_match", "winner": 1})
        assert board.standings()["completed_matches"] == 0
        await mm.handle(host, {"type": "finish_match", "winner": 1})
        await mm.disconnect(host)
        with pytest.raises(ProtocolError, match="not in a match"):
            await mm.handle(guest, {"type": "finish_match", "winner": 1})
        assert board.standings()["completed_matches"] == 1
        assert by_name(board)["Bob"]["wins"] == 1
        assert by_name(board)["Alice"]["games"] == 1
        await mm.shutdown()
        board.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("ending", ["disconnect", "leave", "idle_timeout"])
def test_started_forfeit_counts_once(ending):
    async def scenario():
        board = Leaderboard(":memory:")
        now = [0.0]
        mm = Matchmaker(Settings(), clock=lambda: now[0], leaderboard=board)
        host, guest = await start_pair(mm)
        if ending == "disconnect":
            await mm.disconnect(guest)
        elif ending == "leave":
            await mm.handle(guest, {"type": "leave"})
        else:
            now[0] = 31
            host.last_seen = 30
            await mm.sweep()
        await mm.disconnect(guest)
        await mm.shutdown()
        assert board.standings()["completed_matches"] == 1
        assert by_name(board)["Alice"]["wins"] == 1
        assert by_name(board)["Bob"]["games"] == 1
        board.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("ending", ["unready_leave", "ready_timeout", "match_timeout", "shutdown", "same_name"])
def test_abandoned_and_unrankable_games_do_not_affect_standings(ending):
    async def scenario():
        board = Leaderboard(":memory:")
        now = [0.0]
        mm = Matchmaker(Settings(), clock=lambda: now[0], leaderboard=board)
        names = ("Alice", "Alice") if ending == "same_name" else ("Alice", "Bob")
        players = await start_pair(mm, names, start=ending not in ("unready_leave", "ready_timeout"))
        if ending == "unready_leave":
            await mm.handle(players[0], {"type": "leave"})
        elif ending in ("ready_timeout", "match_timeout"):
            now[0] = 11000 if ending == "match_timeout" else 31
            for player in players:
                player.last_seen = now[0]
            await mm.sweep()
        elif ending == "same_name":
            await mm.handle(players[mm.rooms[players[0].room_id].host_team], {"type": "finish_match", "winner": 0})
        await mm.shutdown()
        assert board.standings()["completed_matches"] == 0
        assert all(row["games"] == 0 for row in by_name(board).values())
        board.close()
    asyncio.run(scenario())


def test_http_page_assets_and_public_stats_are_consistent():
    app = create_app(Settings(leaderboard_db=":memory:"))
    with TestClient(app) as client:
        page = client.get("/")
        assert page.status_code == 200 and "联机排行榜" in page.text
        assert "frame-ancestors 'none'" in page.headers["content-security-policy"]
        assert client.get("/leaderboard").status_code == 200
        for asset in ("leaderboard.css", "leaderboard.js", "favicon.svg"):
            assert client.get(f"/static/{asset}").status_code == 200
        assert client.get("/api/leaderboard").json()["players"] == []
        app.state.leaderboard.record("http-match", ("<img src=x onerror=alert(1)>", "普通玩家"), 1, "completed")
        response = client.get("/api/leaderboard")
        assert response.headers["cache-control"] == "no-store"
        assert response.json()["players"][0]["name"] == "普通玩家"
        assert response.json()["players"][0]["win_rate"] == 100
        assert response.json()["completed_matches"] == 1
        for params in ({"sort": "injection"}, {"limit": 0}, {"limit": 101}, {"offset": -1}, {"q": "a" * 65}):
            assert client.get("/api/leaderboard", params=params).status_code == 422
        assert client.get("/healthz").json()["status"] == "ok"


def test_env_database_path(tmp_path, monkeypatch):
    path = str(tmp_path / "other.sqlite3")
    monkeypatch.setenv("AOE2_MP_LEADERBOARD_DB", path)
    assert Settings.from_env().leaderboard_db == path
    with pytest.raises(ValueError, match="leaderboard_db"):
        Settings(leaderboard_db=" ")
