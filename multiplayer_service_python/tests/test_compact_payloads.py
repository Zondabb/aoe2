import asyncio
import base64
import json
import zlib

import pytest

from multiplayer_service_python.matchmaking import Matchmaker
from multiplayer_service_python.protocol import ProtocolError, decode_keyframe_state, parse_message
from multiplayer_service_python.settings import Settings
from multiplayer_service_python.tests.fair_helpers import publish
from multiplayer_service_python.tests.test_incremental_sync import HASH, drain, frame, spectator, started


def batch(**overrides):
    return {"type": "command_batch", "seq": 1, "source_tick": 0, "execute_tick": 6,
            "commands": [{"op": "move", "unit_id": i + 1, "pos": [i, 4]} for i in range(50)], **overrides}


def compressed(raw=b'{"world":{"name":"test"},"simulation":{"next_id":1}}', **overrides):
    return {"type": "keyframe", "request_id": "a" * 32, "tick": 0, "checksum": HASH,
            "codec": "zlib", "raw_size": len(raw),
            "data": base64.b64encode(zlib.compress(raw)).decode(), **overrides}


@pytest.mark.parametrize("host_team", [0, 1])
def test_batched_sequence_identity_and_player_frame_deduplication(monkeypatch, host_team):
    monkeypatch.setattr("multiplayer_service_python.matchmaking.secrets.randbelow", lambda n: host_team if n == 2 else 123)

    async def scenario():
        mm = Matchmaker(Settings())
        room, host, guest = await started(mm)
        viewer = await spectator(mm, room)
        packet = parse_message(json.dumps(batch()), Settings())
        await mm.handle(guest, packet)
        assert drain(host) == [{**packet, "team": guest.team}] and guest.seq == 50
        assert not drain(viewer)
        for old in (packet, batch(seq=50)):
            with pytest.raises(ProtocolError):
                await mm.handle(guest, old)
        await mm.handle(guest, batch(seq=51))
        assert guest.seq == 100 and drain(host)[0]["seq"] == 51
        with pytest.raises(ProtocolError):
            await mm.handle(viewer, batch())
        move = {"team": guest.team, "command": {"op": "move", "unit_id": 1, "pos": [1, 4]}}
        updates = [{"team": host.team, "command": {"op": "match_speed", "speed": 2.0}},
                   {"team": host.team, "command": {"op": "ai_control_state", "states": {}}}]
        outcome = {"team": guest.team, "seq": 1, "accepted": True}
        completed = dict(frame(3), commands=[move, *updates], results=[outcome])
        await publish(mm, host, completed)
        assert drain(guest) == [{**completed, "commands": updates}]
        assert drain(viewer) == [completed]
        assert completed["commands"][0] == move  # filtering cannot mutate the observer's frame
        await mm.shutdown()

    asyncio.run(scenario())


@pytest.mark.parametrize("packet", [
    batch(commands=[]), batch(commands=[{"op": "stop"}] * 65),
    batch(seq=0), batch(seq=True), batch(seq=2**53 - 10),
    batch(source_tick=1), batch(execute_tick=0), batch(execute_tick=183),
    batch(commands=[{"op": "stop", "team": 1}]), batch(commands=[{"unit_id": 1}]),
    batch(commands=[{"op": "stop", "blob": "x" * 16000}] * 20),
])
def test_invalid_batch_is_rejected_atomically(packet):
    with pytest.raises(ProtocolError):
        parse_message(json.dumps(packet), Settings())


@pytest.mark.parametrize("packet", [
    compressed(codec="gzip"), compressed(raw_size=0), compressed(raw_size=True),
    compressed(raw_size=4_194_305), compressed(raw_size=1), compressed(data="not base64!"),
    compressed(data=base64.b64encode(b"not zlib").decode()),
    compressed(data=base64.b64encode(zlib.compress(b"{}") + b"trailing").decode(), raw_size=2),
    compressed(data=base64.b64encode(zlib.compress(b"x" * 1_000_000)).decode(), raw_size=32),
    compressed(b'{"world":{},"world":{}}'), compressed(b'{"bad":NaN}'),
    compressed(b'{}'), compressed(b'[]'), compressed(b'[' * 35 + b'0' + b']' * 35),
])
def test_invalid_or_expanding_compressed_state_is_bounded(packet):
    with pytest.raises(ProtocolError):
        parse_message(json.dumps(packet), Settings())


def test_compressed_keyframe_remains_compressed_in_targeted_relay():
    async def scenario():
        mm = Matchmaker(Settings())
        room, host, guest = await started(mm)
        viewer = await spectator(mm, room)
        await mm.handle(guest, {"type": "request_keyframe"})
        request, = drain(host)
        state = {"world": {"name": "压缩", "entities": [{"pos": [1.125, -2.25]}] * 100}, "simulation": {"next_id": 9}}
        packet = compressed(json.dumps(state, ensure_ascii=False).encode(), request_id=request["request_id"])
        assert parse_message(json.dumps(packet), Settings()) == packet
        assert decode_keyframe_state(packet, Settings()) == state
        assert len(json.dumps(packet)) < packet["raw_size"]
        await mm.handle(host, packet)
        assert drain(guest) == [packet] and not drain(viewer)
        assert not room.keyframe_requests and guest.pending_keyframe is None
        await mm.shutdown()

    asyncio.run(scenario())
