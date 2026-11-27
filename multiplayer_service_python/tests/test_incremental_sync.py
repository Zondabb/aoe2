import asyncio
import json

import pytest

from multiplayer_service_python.matchmaking import Matchmaker
from multiplayer_service_python.protocol import ProtocolError, parse_message
from multiplayer_service_python.settings import Settings
from multiplayer_service_python.wire import encode_packet, parse_binary_message


JOIN = {"type": "join_queue", "protocol_version": 10, "name": "Player", "civ": "chinese"}
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
        assert found["protocol_version"] == 10
        await mm.handle(player, {"type": "ready"})
    for player in players:
        assert drain(player)[-1]["type"] == "start"
    return room, room.players[room.host_team], room.players[1 - room.host_team]


def keyframe(request, tick=0):
    return {"type": "keyframe", "request_id": request["request_id"], "tick": tick,
            "state": {"world": {"entities": []}, "simulation": {"next_id": 1}}, "checksum": HASH}


@pytest.mark.parametrize("host_team", [0, 1])
def test_heartbeat_and_targeted_keyframe_recovery(monkeypatch, host_team):
    monkeypatch.setattr("multiplayer_service_python.matchmaking.secrets.randbelow", lambda n: host_team if n == 2 else 123)

    async def scenario():
        now = [0.0]
        mm = Matchmaker(Settings(), clock=lambda: now[0])
        room, host, guest = await started(mm)
        hb0 = encode_packet({"type": "heartbeat", "tick": 0, "checksum32": 0x11223344, "sent_usec32": 10})
        await mm.handle_binary(host, parse_binary_message(hb0, Settings()), hb0)
        assert drain(guest) == [hb0]
        ack0 = encode_packet({"type": "heartbeat_ack", "ack_tick": 0, "checksum32": 0x11223344, "echo_usec32": 10})
        await mm.handle_binary(guest, parse_binary_message(ack0, Settings()), ack0)
        assert drain(host) == [ack0]

        hb60 = encode_packet({"type": "heartbeat", "tick": 60, "checksum32": 0xAABBCCDD, "sent_usec32": 20})
        await mm.handle_binary(host, parse_binary_message(hb60, Settings()), hb60)
        assert room.tick == 60 and drain(guest) == [hb60]

        # Keyframe at tick >= room.tick is accepted (host advances silently between heartbeats)
        await mm.handle(guest, {"type": "request_keyframe"})
        request, = drain(host)
        with pytest.raises(ProtocolError, match="out of bounds"):
            await mm.handle(host, keyframe(request, 57))
        assert guest.pending_keyframe == request["request_id"]
        response = keyframe(request, 72)
        await mm.handle(host, response)
        assert room.tick == 72 and drain(guest) == [response]
        ack72 = encode_packet({"type": "heartbeat_ack", "ack_tick": 72, "checksum32": 0xAAAAAAAA, "echo_usec32": 0})
        await mm.handle_binary(guest, parse_binary_message(ack72, Settings()), ack72)
        assert drain(host) == [ack72]
        await mm.shutdown()

    asyncio.run(scenario())


def test_timed_out_keyframe_response_is_harmless():
    async def scenario():
        now = [0.0]
        mm = Matchmaker(Settings(keyframe_timeout=2), clock=lambda: now[0])
        room, host, guest = await started(mm)
        await mm.handle(guest, {"type": "request_keyframe"})
        request, = drain(host)
        now[0] = 3.0
        await mm.sweep()
        assert drain(guest)[0]["code"] == "keyframe_timeout"
        assert guest.pending_keyframe is None
        await mm.handle(host, keyframe(request))
        assert not drain(host) and not drain(guest)
        await mm.shutdown()

    asyncio.run(scenario())


@pytest.mark.parametrize("packet", [
    {**JOIN, "protocol_version": 1},
    {**JOIN, "protocol_version": 8},
    {**JOIN, "protocol_version": 9},
    {"type": "frame", "results": [], "tick": 3, "commands": [], "checksum": HASH},
    {"type": "ack", "tick": 0, "checksum": HASH},
    {"type": "watch_match", "match_id": "a" * 32},
    {"type": "list_matches"},
    {"type": "request_keyframe", "target": "someone"},
    {"type": "keyframe", "request_id": "../other", "tick": 0, "state": {"x": 1}, "checksum": HASH},
    {"type": "snapshot", "seq": 1, "state": {"x": 1}},
    {"type": "finish_match", "winner": 0, "tick": 1},
])
def test_incremental_wire_rejects_legacy_or_spectator_packets(packet):
    with pytest.raises(ProtocolError):
        parse_message(json.dumps(packet), Settings())


def test_heartbeat_ack_cannot_advance_beyond_host_or_regress():
    async def scenario():
        mm = Matchmaker(Settings())
        room, host, guest = await started(mm)
        bad_role = encode_packet({"type": "heartbeat_ack", "ack_tick": 0, "checksum32": 1, "echo_usec32": 0})
        with pytest.raises(ProtocolError, match="guest"):
            await mm.handle_binary(host, parse_binary_message(bad_role, Settings()), bad_role)
        ahead = encode_packet({"type": "heartbeat_ack", "ack_tick": 3, "checksum32": 1, "echo_usec32": 0})
        with pytest.raises(ProtocolError, match="timeline"):
            await mm.handle_binary(guest, parse_binary_message(ahead, Settings()), ahead)
        hb3 = encode_packet({"type": "heartbeat", "tick": 3, "checksum32": 1, "sent_usec32": 99})
        await mm.handle_binary(host, parse_binary_message(hb3, Settings()), hb3)
        drain(guest)
        ack3 = encode_packet({"type": "heartbeat_ack", "ack_tick": 3, "checksum32": 1, "echo_usec32": 99})
        await mm.handle_binary(guest, parse_binary_message(ack3, Settings()), ack3)
        assert drain(host) == [ack3]
        back = encode_packet({"type": "heartbeat_ack", "ack_tick": 0, "checksum32": 1, "echo_usec32": 0})
        with pytest.raises(ProtocolError, match="timeline"):
            await mm.handle_binary(guest, parse_binary_message(back, Settings()), back)
        await mm.shutdown()

    asyncio.run(scenario())
