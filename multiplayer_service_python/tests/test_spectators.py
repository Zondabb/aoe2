import asyncio
import json

from fastapi.testclient import TestClient
import pytest

from multiplayer_service_python.leaderboard import Leaderboard
from multiplayer_service_python.main import create_app
from multiplayer_service_python.matchmaking import Close, Matchmaker
from multiplayer_service_python.protocol import ProtocolError, parse_message
from multiplayer_service_python.settings import Settings


JOIN = {"type": "join_queue", "protocol_version": 3, "name": "Host", "civ": "chinese"}


def drain(player):
    messages = []
    while not player.outbox.empty():
        messages.append(player.outbox.get_nowait())
    return messages


def frame(tick):
    return {"type": "frame", "tick": tick, "commands": [], "checksum": "a" * 64}


async def pair(mm, *, start=True, snapshot=True):
    players = [await mm.register(), await mm.register()]
    await mm.handle(players[0], JOIN)
    await mm.handle(players[1], dict(JOIN, name="Guest", civ="teutons"))
    room = mm.rooms[players[0].room_id]
    host, guest = players[room.host_team], players[1 - room.host_team]
    drain(host)
    drain(guest)
    if start:
        await mm.handle(host, {"type": "ready"})
        await mm.handle(guest, {"type": "ready"})
        drain(host)
        drain(guest)
    if snapshot:
        await mm.handle(host, frame(3))
        drain(guest)
    return host, guest


async def watch(mm, host, *, ready=True):
    viewer = await mm.register()
    await mm.handle(viewer, {"type": "watch_match", "match_id": host.room_id})
    joined, = drain(viewer)
    assert joined["type"] == "spectate_started" and joined["role"] == "spectator"
    assert joined["host_team"] == host.team and joined["match_id"] == host.room_id
    assert joined["protocol_version"] == 3 and joined["tick_rate"] == 30 and joined["frame_ticks"] == 3
    assert "team" not in joined and "state" not in joined
    if ready:
        await mm.handle(viewer, {"type": "watch_ready"})
        assert drain(viewer) == []
    return viewer


def test_loading_spectator_does_not_accumulate_frames_and_gets_fresh_keyframe_after_ready():
    async def scenario():
        mm = Matchmaker(Settings(outgoing_queue_size=3))
        host, guest = await pair(mm)
        viewer = await watch(mm, host, ready=False)
        assert viewer.spectating and not viewer.spectator_ready
        with pytest.raises(ProtocolError, match="finish loading"):
            await mm.handle(viewer, {"type": "request_keyframe"})
        for tick in range(6, 61, 3):
            await mm.handle(host, frame(tick))
            drain(guest)
            assert drain(viewer) == []
        assert viewer.id in mm.players
        for _ in range(2):
            await mm.handle(viewer, {"type": "watch_ready"})
            assert viewer.spectator_ready and drain(viewer) == []
        await mm.handle(viewer, {"type": "request_keyframe"})
        request, = drain(host)
        assert request["type"] == "keyframe_request"
        keyframe = {"type": "keyframe", "request_id": request["request_id"], "tick": 60, "state": {"tick": 60}, "checksum": "a" * 64}
        await mm.handle(host, keyframe)
        assert drain(viewer) == [keyframe] and drain(guest) == []
        await mm.handle(host, frame(63))
        assert drain(viewer) == drain(guest) == [frame(63)]
        await mm.handle(viewer, {"type": "ack", "tick": 63, "checksum": "a" * 64})
        assert drain(host) == []  # viewers cannot stall or acknowledge for players
        await mm.handle(viewer, {"type": "leave"})
        assert not viewer.spectating and not viewer.spectator_ready
        await mm.shutdown()
    asyncio.run(scenario())


def test_players_and_idle_clients_cannot_send_watch_ready():
    async def scenario():
        mm = Matchmaker(Settings())
        host, guest = await pair(mm)
        idle = await mm.register()
        for player in (host, guest, idle):
            with pytest.raises(ProtocolError) as caught:
                await mm.handle(player, {"type": "watch_ready"})
            assert caught.value.code == "forbidden"
        assert drain(host) == drain(guest) == drain(idle) == []
        await mm.shutdown()
    asyncio.run(scenario())


def test_list_started_matches_without_full_state_and_fanout_incremental_frames():
    async def scenario():
        now = [100.0]
        mm = Matchmaker(Settings(), clock=lambda: now[0])
        host, guest = await pair(mm, start=False, snapshot=False)
        browser = await mm.register()
        await mm.handle(browser, {"type": "list_matches"})
        assert drain(browser) == [{"type": "matches", "matches": []}]
        for participant in (host, guest):
            await mm.handle(participant, {"type": "ready"})
        drain(host)
        drain(guest)
        now[0] += 12
        room = mm.rooms[host.room_id]
        listing = (await mm.list_matches())["matches"]
        assert listing == [{"match_id": room.id, "players": [
            {"team": 0, "name": "Host", "civ": "chinese"},
            {"team": 1, "name": "Guest", "civ": "teutons"}],
            "elapsed_seconds": 12, "spectator_count": 0}]
        viewer = await watch(mm, host)
        assert (await mm.list_matches())["matches"][0]["spectator_count"] == 1
        await mm.handle(host, frame(3))
        assert drain(guest) == drain(viewer) == [frame(3)]
        assert drain(host) == []
        await mm.handle(guest, {"type": "command", "seq": 1, "command": {"op": "stop"}})
        assert drain(host)[0]["team"] == guest.team and drain(viewer) == []
        await mm.shutdown()
    asyncio.run(scenario())


@pytest.mark.parametrize("message", [
    {"type": "ready"}, {"type": "cancel_queue"}, JOIN,
    {"type": "command", "seq": 1, "command": {"op": "move", "unit_id": 1, "pos": [1, 2]}},
    {"type": "command", "seq": 1, "command": {"op": "set_ai_control", "enabled": True}},
    {"type": "frame", "tick": 999, "commands": [], "checksum": "a" * 64},
    {"type": "finish_match", "winner": 1},
    {"type": "watch_match", "match_id": "0" * 32},
])
def test_spectator_cannot_issue_any_player_messages(message):
    async def scenario():
        mm = Matchmaker(Settings())
        host, guest = await pair(mm)
        viewer = await watch(mm, host)
        with pytest.raises(ProtocolError) as caught:
            await mm.handle(viewer, message)
        assert caught.value.code == "forbidden"
        assert viewer.seq == 0 and viewer.team is None
        assert host.room_id in mm.rooms and drain(host) == drain(guest) == []
        await mm.handle(viewer, {"type": "ping"})
        assert drain(viewer) == [{"type": "pong"}]
        await mm.shutdown()
    asyncio.run(scenario())


@pytest.mark.parametrize("ending", ["leave", "disconnect", "timeout", "slow_consumer"])
def test_spectator_departure_never_ends_match_or_records_a_result(ending):
    async def scenario():
        board = Leaderboard(":memory:")
        now = [0.0]
        mm = Matchmaker(Settings(outgoing_queue_size=3), clock=lambda: now[0], leaderboard=board)
        host, guest = await pair(mm)
        viewer = await watch(mm, host)
        room_id = host.room_id
        if ending == "leave":
            await mm.handle(viewer, {"type": "leave"})
            assert not viewer.spectating and viewer.room_id is None
            await mm.handle(viewer, dict(JOIN, name="Former Viewer"))
            assert drain(viewer) == [{"type": "queued"}]
        elif ending == "disconnect":
            await mm.disconnect(viewer)
        elif ending == "timeout":
            now[0] = 31.0
            host.last_seen = guest.last_seen = 31.0
            await mm.sweep()
            assert viewer.id not in mm.players
        else:
            for tick in range(6, 18, 3):
                await mm.handle(host, frame(tick))
                drain(guest)
            assert viewer.id not in mm.players
            assert isinstance(drain(viewer)[0], Close)
        assert room_id in mm.rooms and len(mm.rooms[room_id].spectators) == 0
        assert drain(host) == [] and board.standings()["completed_matches"] == 0
        await mm.handle(host, {"type": "finish_match", "winner": 0})
        assert board.standings()["completed_matches"] == 1
        await mm.shutdown()
        board.close()
    asyncio.run(scenario())


@pytest.mark.parametrize("ending", ["completed", "disconnect"])
def test_all_spectators_receive_end_once_and_leave_can_queue_again(ending):
    async def scenario():
        mm = Matchmaker(Settings())
        host, guest = await pair(mm)
        viewers = [await watch(mm, host), await watch(mm, host)]
        room_id = host.room_id
        if ending == "completed":
            await mm.handle(host, {"type": "finish_match", "winner": 1})
        elif ending == "disconnect":
            await mm.disconnect(host)
        assert room_id not in mm.rooms
        for viewer in viewers:
            messages = drain(viewer)
            ended = [m for m in messages if isinstance(m, dict) and m.get("type") == "match_ended"]
            assert len(ended) == 1 and ended[0]["match_id"] == room_id
            assert not viewer.spectating and viewer.team is None and viewer.room_id is None
        await mm.shutdown()
    asyncio.run(scenario())


def test_watch_limits_unavailable_rooms_and_queued_clients_are_recoverable():
    async def scenario():
        mm = Matchmaker(Settings(max_spectators_per_match=1, max_listed_matches=1))
        host, guest = await pair(mm)
        viewer = await watch(mm, host)
        other = await mm.register()
        with pytest.raises(ProtocolError) as caught:
            await mm.handle(other, {"type": "watch_match", "match_id": host.room_id})
        assert caught.value.code == "spectators_full" and caught.value.close_code is None
        assert other.room_id is None and not other.spectating
        with pytest.raises(ProtocolError) as caught:
            await mm.handle(other, {"type": "watch_match", "match_id": "0" * 32})
        assert caught.value.code == "match_unavailable"
        await mm.handle(viewer, {"type": "leave"})
        await mm.handle(other, JOIN)
        drain(other)
        with pytest.raises(ProtocolError, match="Leave"):
            await mm.handle(other, {"type": "watch_match", "match_id": host.room_id})
        await mm.handle(other, {"type": "cancel_queue"})
        drain(other)
        await mm.handle(other, {"type": "watch_match", "match_id": host.room_id})
        assert other.spectating
        second_host, _ = await pair(mm)
        assert len((await mm.list_matches())["matches"]) == 1
        await mm.shutdown()
    asyncio.run(scenario())


@pytest.mark.parametrize("payload", [
    {"type": "list_matches", "team": 0},
    {"type": "watch_match", "match_id": "0" * 32, "role": "player"},
    {"type": "watch_match", "match_id": 1},
    {"type": "watch_match", "match_id": "../private"},
    {"type": "watch_match", "match_id": "a" * 33},
])
def test_spectator_protocol_rejects_identity_spoof_and_invalid_match_ids(payload):
    with pytest.raises(ProtocolError):
        parse_message(json.dumps(payload), Settings())


def test_http_and_websocket_spectator_lifecycle():
    with TestClient(create_app()) as client, client.websocket_connect("/ws") as host, client.websocket_connect("/ws") as guest, client.websocket_connect("/ws") as viewer:
        assert client.get("/api/matches").json() == {"matches": []}
        host.send_json(JOIN)
        host.receive_json()
        guest.send_json(dict(JOIN, name="Guest", civ="teutons"))
        guest.receive_json()
        found = host.receive_json()
        guest.receive_json()
        if found["host_team"] == 1:
            host, guest = guest, host
        host.send_json({"type": "ready"})
        guest.send_json({"type": "ready"})
        host.receive_json()
        guest.receive_json()
        host.send_json(frame(3))
        guest.receive_json()
        listing = client.get("/api/matches")
        assert listing.headers["cache-control"] == "no-store"
        assert listing.json()["matches"][0]["match_id"] == found["match_id"]
        viewer.send_json({"type": "list_matches"})
        assert viewer.receive_json()["matches"] == listing.json()["matches"]
        viewer.send_json({"type": "watch_match", "match_id": found["match_id"]})
        assert viewer.receive_json()["type"] == "spectate_started"
        viewer.send_json({"type": "watch_ready"})
        viewer.send_json({"type": "request_keyframe"})
        request = host.receive_json()
        keyframe = {"type": "keyframe", "request_id": request["request_id"], "tick": 3, "state": {"x": 1}, "checksum": "a" * 64}
        host.send_json(keyframe)
        assert viewer.receive_json() == keyframe
        viewer.send_json({"type": "finish_match", "winner": 0})
        assert viewer.receive_json()["code"] == "forbidden"
        host.send_json({"type": "finish_match", "winner": 1})
        assert viewer.receive_json()["type"] == "match_ended"
        assert client.get("/api/matches").json() == {"matches": []}
