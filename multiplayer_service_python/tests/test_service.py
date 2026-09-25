import asyncio
import json

from fastapi.testclient import TestClient
import pytest

from multiplayer_service_python.main import create_app
from multiplayer_service_python.matchmaking import Close, Matchmaker
from multiplayer_service_python.protocol import ProtocolError, parse_message
from multiplayer_service_python.settings import Settings


JOIN = {"type": "join_queue", "protocol_version": 1, "name": "玩家", "civ": "chinese"}


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


def test_match_relay_complete_and_rematch():
    with TestClient(create_app()) as client, client.websocket_connect("/ws") as host, client.websocket_connect("/ws") as guest:
        previous = None
        for _ in range(2):
            match_id = pair(host, guest)
            assert match_id != previous
            previous = match_id
            # Neither an unready client nor a one-sided ready can issue orders.
            guest.send_json({"type": "command", "seq": 1, "command": {"op": "stop", "unit_id": 2}})
            assert guest.receive_json()["code"] == "invalid_state"
            start(host, guest)
            guest.send_json({"type": "command", "seq": 1, "command": {"op": "move", "unit_id": 2, "pos": [4, 5]}})
            message = host.receive_json()
            assert message["team"] == 1 and message["seq"] == 1 and message["command"]["pos"] == [4, 5]
            snapshot = {"type": "snapshot", "seq": 1, "state": {"entities": [], "winner": -1}}
            host.send_json(snapshot)
            assert guest.receive_json() == snapshot
            host.send_json({"type": "finish_match", "winner": 1})
            for peer in [host, guest]:
                assert peer.receive_json() == {"type": "match_ended", "match_id": match_id, "winner": 1, "reason": "completed"}
            assert client.get("/healthz").json()["matches"] == 0


def test_role_spoofing_and_replayed_sequence_are_rejected():
    with TestClient(create_app()) as client, client.websocket_connect("/ws") as host, client.websocket_connect("/ws") as guest:
        pair(host, guest)
        start(host, guest)
        for peer, message in [
            (guest, {"type": "snapshot", "seq": 1, "state": {"winner": 1}}),
            (guest, {"type": "finish_match", "winner": 1}),
            (host, {"type": "command", "seq": 1, "command": {"op": "stop"}}),
        ]:
            peer.send_json(message)
            assert peer.receive_json()["code"] == "forbidden"
        guest.send_json({"type": "command", "seq": 1, "command": {"op": "stop", "team": 0}})
        assert guest.receive_json()["code"] == "invalid_payload"
        command = {"type": "command", "seq": 1, "command": {"op": "stop", "unit_id": 2}}
        guest.send_json(command)
        assert host.receive_json()["team"] == 1
        guest.send_json(command)
        assert guest.receive_json()["code"] == "invalid_sequence"
        guest.send_json({"type": "ping"})
        assert guest.receive_json() == {"type": "pong"}


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
    ('{"type":"snapshot","seq":true,"state":{"x":1}}', "invalid_sequence"),
    ('{"type":"snapshot","seq":1,"state":{"x":NaN}}', "invalid_json"),
    ('{"type":"snapshot","seq":1,"state":{"x":1e999}}', "invalid_payload"),
    (json.dumps(dict(JOIN, protocol_version=2)), "protocol_mismatch"),
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
        parse_message('{"type":"snapshot","seq":1,"state":{"x":' + '[' * 30 + '0' + ']' * 30 + '}}', Settings())


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
