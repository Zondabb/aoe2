import asyncio
import json

import pytest

from multiplayer_service_python.matchmaking import Matchmaker
from multiplayer_service_python.protocol import ProtocolError, parse_message
from multiplayer_service_python.settings import Settings


JOIN = {"type": "join_queue", "protocol_version": 3, "name": "Player", "civ": "chinese"}
HASH = "a" * 64


def drain(player):
    result = []
    while not player.outbox.empty():
        result.append(player.outbox.get_nowait())
    return result


async def started(mm):
    players = [await mm.register(), await mm.register()]
    for player in players:
        await mm.handle(player, JOIN)
    room = mm.rooms[players[0].room_id]
    for player in players:
        found = drain(player)[-1]
        assert found["host_team"] == room.host_team
        assert found["seed"] == room.seed
        assert found["protocol_version"] == 3
        await mm.handle(player, {"type": "ready"})
    for player in players:
        assert drain(player)[-1]["type"] == "start"
    return room, room.players[room.host_team], room.players[1 - room.host_team]


async def spectator(mm, room):
    viewer = await mm.register()
    await mm.handle(viewer, {"type": "watch_match", "match_id": room.id})
    drain(viewer)
    await mm.handle(viewer, {"type": "watch_ready"})
    return viewer


def frame(tick):
    return {"type": "frame", "tick": tick, "commands": [], "checksum": HASH}


def keyframe(request, tick=0):
    return {"type": "keyframe", "request_id": request["request_id"], "tick": tick,
            "state": {"world": {"entities": []}, "simulation": {"next_id": 1}}, "checksum": HASH}


@pytest.mark.parametrize("host_team", [0, 1])
def test_incremental_timeline_and_targeted_recovery(monkeypatch, host_team):
    monkeypatch.setattr("multiplayer_service_python.matchmaking.secrets.randbelow", lambda n: host_team if n == 2 else 123)

    async def scenario():
        now = [0.0]
        mm = Matchmaker(Settings(), clock=lambda: now[0])
        room, host, guest = await started(mm)
        viewer = await spectator(mm, room)
        await mm.handle(guest, {"type": "request_keyframe"})
        request, = drain(host)
        response = keyframe(request)
        await mm.handle(host, response)
        assert drain(guest) == [response] and not drain(viewer)
        ack = {"type": "ack", "tick": 0, "checksum": HASH}
        await mm.handle(guest, ack)
        assert drain(host) == [{**ack, "team": guest.team}]
        for tick in (3, 6, 9):
            await mm.handle(host, frame(tick))
            assert drain(guest) == drain(viewer) == [frame(tick)]
        for tick in (9, 15):
            with pytest.raises(ProtocolError, match="without gaps"):
                await mm.handle(host, frame(tick))
        assert room.tick == 9
        now[0] = 2.0
        await mm.handle(viewer, {"type": "request_keyframe"})
        request, = drain(host)
        with pytest.raises(ProtocolError, match="current completed frame"):
            await mm.handle(host, keyframe(request, 6))
        assert viewer.pending_keyframe == request["request_id"]
        response = keyframe(request, 9)
        await mm.handle(host, response)
        assert drain(viewer) == [response] and not drain(guest)
        await mm.handle(viewer, {"type": "ack", "tick": 9, "checksum": HASH})
        assert not drain(host)  # An observer cannot unblock either player.
        await mm.handle(host, frame(12))
        assert drain(guest) == drain(viewer) == [frame(12)]
        await mm.shutdown()

    asyncio.run(scenario())


def test_concurrent_spectators_share_one_capture_and_cannot_disconnect_host():
    async def scenario():
        now = [0.0]
        mm = Matchmaker(Settings(outgoing_queue_size=3), clock=lambda: now[0])
        room, host, guest = await started(mm)
        viewers = [await spectator(mm, room) for _ in range(16)]
        for viewer in viewers:
            for _ in range(10):
                await mm.handle(viewer, {"type": "request_keyframe"})
        request, = drain(host)
        assert len(room.keyframe_requests) == 1 and len(mm.players) == 18
        # Leaving one member must not cancel the capture needed by the rest.
        await mm.handle(viewers[0], {"type": "leave"})
        response = keyframe(request)
        assert await mm.admit_message(host, len(json.dumps(response).encode()))
        await mm.handle(host, response)
        assert not drain(viewers[0]) and not drain(guest)
        for viewer in viewers[1:]:
            assert drain(viewer) == [response]
            with pytest.raises(ProtocolError, match="Wait"):
                await mm.handle(viewer, {"type": "request_keyframe"})
        assert not drain(host) and not room.keyframe_requests
        # A new identity cannot evade the room-wide capture rate limit.
        await mm.handle(viewers[0], {"type": "watch_match", "match_id": room.id})
        drain(viewers[0])
        await mm.handle(viewers[0], {"type": "watch_ready"})
        with pytest.raises(ProtocolError, match="room keyframe"):
            await mm.handle(viewers[0], {"type": "request_keyframe"})
        assert host.id in mm.players and room.id in mm.rooms
        await mm.shutdown()

    asyncio.run(scenario())


def test_timed_out_and_cancelled_keyframe_responses_are_harmless():
    async def scenario():
        now = [0.0]
        mm = Matchmaker(Settings(keyframe_timeout=2), clock=lambda: now[0])
        room, host, guest = await started(mm)
        viewer = await spectator(mm, room)
        for member in (guest, viewer):
            await mm.handle(member, {"type": "request_keyframe"})
        request, = drain(host)
        now[0] = 3.0
        await mm.sweep()
        for member in (guest, viewer):
            assert drain(member)[0]["code"] == "keyframe_timeout"
            assert member.pending_keyframe is None
        await mm.handle(host, keyframe(request))
        assert not drain(host) and not drain(guest) and not drain(viewer)
        await mm.handle(viewer, {"type": "request_keyframe"})
        request, = drain(host)
        await mm.disconnect(viewer)
        assert not room.keyframe_requests
        await mm.handle(host, keyframe(request))
        assert room.id in mm.rooms and not drain(guest)
        await mm.shutdown()

    asyncio.run(scenario())


@pytest.mark.parametrize("packet", [
    {**JOIN, "protocol_version": 1},
    {**JOIN, "protocol_version": 2},
    {"type": "frame", "tick": True, "commands": [], "checksum": HASH},
    {"type": "frame", "tick": 2, "commands": [], "checksum": HASH},
    {"type": "frame", "tick": 3, "commands": [], "checksum": "bad"},
    {"type": "frame", "tick": 3, "commands": [{"team": True, "command": {"op": "stop"}}], "checksum": HASH},
    {"type": "frame", "tick": 3, "commands": [{"team": 0, "command": {"op": "stop", "team": 1}}], "checksum": HASH},
    {"type": "frame", "tick": 3, "commands": [{"team": 0, "command": {"op": "stop"}}] * 65, "checksum": HASH},
    {"type": "ack", "tick": -3, "checksum": HASH},
    {"type": "request_keyframe", "target": "someone"},
    {"type": "keyframe", "request_id": "../other", "tick": 0, "state": {"x": 1}, "checksum": HASH},
    {"type": "snapshot", "seq": 1, "state": {"x": 1}},
])
def test_incremental_wire_rejects_ambiguous_or_legacy_packets(packet):
    with pytest.raises(ProtocolError):
        parse_message(json.dumps(packet), Settings())


def test_ack_cannot_advance_beyond_host_or_replay_backward():
    async def scenario():
        mm = Matchmaker(Settings())
        room, host, guest = await started(mm)
        with pytest.raises(ProtocolError, match="replicas"):
            await mm.handle(host, {"type": "ack", "tick": 0, "checksum": HASH})
        with pytest.raises(ProtocolError, match="timeline"):
            await mm.handle(guest, {"type": "ack", "tick": 3, "checksum": HASH})
        await mm.handle(host, frame(3))
        drain(guest)
        ack = {"type": "ack", "tick": 3, "checksum": HASH}
        await mm.handle(guest, ack)
        assert drain(host) == [{**ack, "team": guest.team}]
        await mm.handle(guest, ack)
        assert not drain(host)
        with pytest.raises(ProtocolError, match="timeline"):
            await mm.handle(guest, {"type": "ack", "tick": 0, "checksum": HASH})
        await mm.shutdown()

    asyncio.run(scenario())
