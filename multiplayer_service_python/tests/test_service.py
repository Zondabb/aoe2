from multiplayer_service_python.tests.fair_helpers import prepare_socket
import asyncio
import json

from fastapi.testclient import TestClient
import pytest

from multiplayer_service_python.main import create_app
from multiplayer_service_python.matchmaking import Close, Matchmaker
from multiplayer_service_python.protocol import ProtocolError, parse_message
from multiplayer_service_python.settings import Settings


JOIN = {"type": "join_queue", "protocol_version": 6, "name": "玩家", "civ": "chinese"}


def pair(host, guest):
    host.send_json(JOIN)
    assert host.receive_json()["type"] == "queued"
    guest.send_json(dict(JOIN, name="Guest", civ="teutons"))
    assert guest.receive_json()["type"] == "queued"
    first, second = host.receive_json(), guest.receive_json()
    assert first["type"] == second["type"] == "match_found"
    assert first["team"] == 0 and second["team"] == 1
    assert first["match_id"] == second["match_id"]
    assert first["players"][1]["civ"] == "teutons"
    return first["match_id"]


def start(host, guest):
    host.send_json({"type": "ready"})
    guest.send_json({"type": "ready"})
    assert host.receive_json()["type"] == guest.receive_json()["type"] == "start"


@pytest.mark.parametrize("host_team", [0, 1])
def test_match_relay_complete_and_rematch(monkeypatch, host_team):
    monkeypatch.setattr("multiplayer_service_python.matchmaking.secrets.randbelow", lambda n: host_team if n == 2 else 12345)
    with TestClient(create_app()) as client, client.websocket_connect("/ws") as host, client.websocket_connect("/ws") as guest:
        previous = None
        for _ in range(2):
            match_id = pair(host, guest)
            assert match_id != previous
            previous = match_id
            # Neither an unready client nor a one-sided ready can issue orders.
            guest.send_json({"type": "command", "source_tick": 0, "execute_tick": 30, "seq": 1, "command": {"op": "stop", "unit_id": 2}})
            assert guest.receive_json()["code"] == "invalid_state"
            start(host, guest)
            guest.send_json({"type": "command", "source_tick": 0, "execute_tick": 30, "seq": 1, "command": {"op": "move", "unit_id": 2, "pos": [4, 5]}})
            authority, replica = (host, guest) if host_team == 0 else (guest, host)
            message = authority.receive_json()
            assert message["team"] == 1 and message["seq"] == 1 and message["command"]["pos"] == [4, 5]
            frame = {"type": "frame", "results": [], "tick": 3, "commands": [], "checksum": "a" * 64}
            prepare_socket(authority, replica, 3)
            authority.send_json(frame)
            assert replica.receive_json() == frame
            authority.send_json({"type": "finish_match", "winner": 1})
            for peer in [host, guest]:
                assert peer.receive_json() == {"type": "match_ended", "match_id": match_id, "winner": 1, "reason": "completed"}
            assert client.get("/healthz").json()["matches"] == 0


@pytest.mark.parametrize("host_team", [0, 1])
def test_role_spoofing_and_replayed_sequence_are_rejected(monkeypatch, host_team):
    monkeypatch.setattr("multiplayer_service_python.matchmaking.secrets.randbelow", lambda n: host_team if n == 2 else 42)
    with TestClient(create_app()) as client, client.websocket_connect("/ws") as first, client.websocket_connect("/ws") as second:
        pair(first, second)
        start(first, second)
        host, guest = (first, second) if host_team == 0 else (second, first)
        for message in [
            {"type": "frame", "results": [], "tick": 3, "commands": [], "checksum": "a" * 64},
            {"type": "finish_match", "winner": 1},
            {"type": "keyframe", "request_id": "0" * 32, "tick": 0, "state": {"x": 1}, "checksum": "a" * 64},
        ]:
            guest.send_json(message)
            assert guest.receive_json()["code"] == "forbidden"
        guest.send_json({"type": "command", "source_tick": 0, "execute_tick": 30, "seq": 1, "command": {"op": "stop", "team": 0}})
        assert guest.receive_json()["code"] == "invalid_payload"
        command = {"type": "command", "source_tick": 0, "execute_tick": 30, "seq": 1, "command": {"op": "stop", "unit_id": 2}}
        for peer, team in ((first, 0), (second, 1)):
            peer.send_json(command)
            assert host.receive_json()["team"] == team
            peer.send_json(command)
            assert peer.receive_json()["code"] == "invalid_sequence"
        guest.send_json({"type": "ping"})
        assert guest.receive_json() == {"type": "pong"}


def test_external_ai_control_relay_is_bound_to_sending_team():
    async def scenario():
        mm = Matchmaker(Settings())
        players = [await mm.register(), await mm.register()]
        for player in players:
            await mm.handle(player, JOIN)
        room = mm.rooms[players[0].room_id]
        authority = players[room.host_team]
        for player in players:
            while not player.outbox.empty():
                player.outbox.get_nowait()
        request = {"type": "command", "source_tick": 0, "execute_tick": 30, "seq": 1, "command": {"op": "set_ai_control", "enabled": True}}
        with pytest.raises(ProtocolError, match="ready"):
            await mm.handle(players[0], request)
        assert players[0].seq == 0
        for player in players:
            await mm.handle(player, {"type": "ready"})
        for player in players:
            assert player.outbox.get_nowait()["type"] == "start"
        for player in players:
            await mm.handle(player, parse_message(json.dumps(request), Settings()))
            assert authority.outbox.get_nowait() == {**request, "team": player.team}
        await mm.handle(authority, {"type": "finish_match", "winner": 1})
        with pytest.raises(ProtocolError, match="not in a match"):
            await mm.handle(players[0], dict(request, seq=2))
        await mm.shutdown()
    asyncio.run(scenario())


@pytest.mark.parametrize("command", [
    {"op": "set_ai_control"},
    {"op": "set_ai_control", "enabled": 1},
    {"op": "set_ai_control", "enabled": "false"},
    {"op": "set_ai_control", "enabled": None},
    {"op": "set_ai_control", "enabled": True, "team": 0},
    {"op": "set_ai_control", "enabled": True, "unit_id": 5},
])
def test_external_ai_control_rejects_ambiguous_flags_and_spoofed_identity(command):
    with pytest.raises(ProtocolError, match="AI control|identity"):
        parse_message(json.dumps({"type": "command", "source_tick": 0, "execute_tick": 30, "seq": 1, "command": command}), Settings())


def test_player_instruction_is_private_and_bounded():
    settings = Settings()
    command = {"op": "ai_instruction", "text": "增加食物采集"}
    assert parse_message(json.dumps({"type": "command", "source_tick": 0, "execute_tick": 30, "seq": 1, "command": command}), settings)["command"] == command
    for invalid in [dict(command, team=0), dict(command, text="  "), dict(command, text=42), dict(command, text="a" * 241)]:
        with pytest.raises(ProtocolError):
            parse_message(json.dumps({"type": "command", "source_tick": 0, "execute_tick": 30, "seq": 1, "command": invalid}), settings)
    with pytest.raises(ProtocolError, match="private"):
        parse_message(json.dumps({"type": "frame", "results": [], "tick": 3, "checksum": "0" * 64,
                                  "commands": [{"team": 0, "command": command}]}), settings)


def test_queue_cancel_and_cancel_after_match_race_cleanup():
    with TestClient(create_app()) as client, client.websocket_connect("/ws") as host, client.websocket_connect("/ws") as guest:
        host.send_json(JOIN)
        host.receive_json()
        host.send_json({"type": "cancel_queue"})
        assert host.receive_json()["type"] == "queue_cancelled"
        assert client.get("/healthz").json()["queued"] == 0
        pair(host, guest)
        host.send_json({"type": "cancel_queue"})
        for peer in [host, guest]:
            ended = peer.receive_json()
            assert ended["winner"] == 1 and ended["reason"] == "opponent_left"
        assert host.receive_json()["type"] == "queue_cancelled"
        status = client.get("/healthz").json()
        assert status["matches"] == status["queued"] == 0
        pair(host, guest)
        start(host, guest)


def test_disconnect_awards_opponent_and_removes_room():
    with TestClient(create_app()) as client, client.websocket_connect("/ws") as host:
        with client.websocket_connect("/ws") as guest:
            pair(host, guest)
            start(host, guest)
        ended = host.receive_json()
        assert ended["winner"] == 0 and ended["reason"] == "opponent_left"
        assert client.get("/healthz").json()["matches"] == 0


@pytest.mark.parametrize("payload,code", [
    ('{', "invalid_json"), ('[]', "invalid_payload"),
    ('{"type":"ping","type":"leave"}', "invalid_json"),
    ('{"type":"unknown"}', "unknown_type"),
    ('{"type":"ping","team":0}', "invalid_payload"),
    ('{"type":"command","source_tick":0,"execute_tick":30,"seq":true,"command":{"op":"stop"}}', "invalid_sequence"),
    ('{"type":"command","source_tick":0,"execute_tick":30,"seq":1,"command":{"op":"stop","x":NaN}}', "invalid_json"),
    ('{"type":"command","source_tick":0,"execute_tick":30,"seq":1,"command":{"op":"stop","x":1e999}}', "invalid_payload"),
    (json.dumps(dict(JOIN, protocol_version=1)), "protocol_mismatch"),
    (json.dumps(dict(JOIN, name="\n")), "invalid_name"),
    (json.dumps(dict(JOIN, civ="unknown")), "invalid_civ"),
])
def test_invalid_messages_keep_service_alive(payload, code):
    with TestClient(create_app()) as client, client.websocket_connect("/ws") as peer:
        peer.send_text(payload)
        assert peer.receive_json()["code"] == code
        peer.send_json({"type": "ping"})
        assert peer.receive_json()["type"] == "pong"


def test_payload_size_and_depth_limits():
    with pytest.raises(ProtocolError, match="size limit"):
        parse_message(" " * 600, Settings(max_message_bytes=500))
    with pytest.raises(ProtocolError, match="too complex"):
        parse_message('{"type":"command","source_tick":0,"execute_tick":30,"seq":1,"command":{"op":"stop","x":' + '[' * 40 + '0' + ']' * 40 + '}}', Settings())


def test_capacity_timeout_and_slow_consumer_cleanup():
    async def scenario():
        now = [0.0]
        mm = Matchmaker(Settings(max_connections=2, outgoing_queue_size=4, idle_timeout=100,
                                 ready_timeout=5, queue_timeout=5), clock=lambda: now[0])
        host, guest = await mm.register(), await mm.register()
        assert await mm.register() is None
        await mm.handle(host, JOIN)
        host.outbox.get_nowait()
        now[0] = 6
        await mm.sweep()
        assert host.outbox.get_nowait()["reason"] == "queue_timeout"
        for player in [host, guest]:
            await mm.handle(player, JOIN)
        for player in [host, guest]:
            while not player.outbox.empty():
                player.outbox.get_nowait()
        now[0] = 12
        await mm.sweep()
        for player in [host, guest]:
            assert player.outbox.get_nowait()["reason"] == "ready_timeout"
            assert player.room_id is None
        # Slow peers are detached without blocking or leaking a queue entry.
        for _ in range(5):
            await mm.handle(host, {"type": "ping"})
        assert host.id not in mm.players
        close = host.outbox.get_nowait()
        assert isinstance(close, Close) and close.error == "slow_consumer"
        now[0] = 101
        await mm.sweep()
        assert (await mm.status())["connections"] == 0
    asyncio.run(scenario())


def test_rate_limit_disconnects_and_notifies_opponent():
    async def scenario():
        mm = Matchmaker(Settings(message_burst=1))
        host, guest = await mm.register(), await mm.register()
        await mm.handle(host, JOIN)
        await mm.handle(guest, JOIN)
        while not guest.outbox.empty():
            guest.outbox.get_nowait()
        assert await mm.admit_message(host, 10)
        assert not await mm.admit_message(host, 10)
        assert not mm.rooms and not mm.queue
        assert guest.outbox.get_nowait()["winner"] == 1
    asyncio.run(scenario())
