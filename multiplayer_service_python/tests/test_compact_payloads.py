import asyncio
import base64
import json
import zlib

import pytest

from multiplayer_service_python.matchmaking import Matchmaker
from multiplayer_service_python.protocol import ProtocolError, decode_keyframe_state, parse_message
from multiplayer_service_python.settings import Settings
from multiplayer_service_python.tests.test_incremental_sync import HASH, drain, started
from multiplayer_service_python.wire import encode_packet, parse_binary_message


def batch(**overrides):
    return {"type": "command_batch", "team": 0, "seq": 1, "source_tick": 0, "execute_tick": 6,
            "commands": [{"op": "move", "unit_id": i + 1, "pos": [float(i), 4.0]} for i in range(50)], **overrides}


def compressed(raw=b'{"world":{"name":"test"},"simulation":{"next_id":1}}', **overrides):
    return {"type": "keyframe", "request_id": "a" * 32, "tick": 0, "checksum": HASH,
            "codec": "zlib", "raw_size": len(raw),
            "data": base64.b64encode(zlib.compress(raw)).decode(), **overrides}


@pytest.mark.parametrize("host_team", [0, 1])
def test_binary_batched_sequence_identity_and_team_injection(monkeypatch, host_team):
    monkeypatch.setattr("multiplayer_service_python.matchmaking.secrets.randbelow", lambda n: host_team if n == 2 else 123)

    async def scenario():
        mm = Matchmaker(Settings())
        room, host, guest = await started(mm)
        raw = encode_packet(batch(team=0))
        parsed = parse_binary_message(raw, Settings())
        await mm.handle_binary(guest, parsed, raw)
        relayed = drain(host)
        assert len(relayed) == 1 and isinstance(relayed[0], bytes)
        decoded = parse_binary_message(relayed[0], Settings())
        assert decoded["team"] == guest.team and guest.seq == 50 and len(decoded["commands"]) == 50
        for old in (batch(), batch(seq=50)):
            r_old = encode_packet(old)
            with pytest.raises(ProtocolError):
                await mm.handle_binary(guest, parse_binary_message(r_old, Settings()), r_old)
        raw2 = encode_packet(batch(seq=51))
        await mm.handle_binary(guest, parse_binary_message(raw2, Settings()), raw2)
        assert guest.seq == 100 and parse_binary_message(drain(host)[0], Settings())["seq"] == 51
        await mm.shutdown()

    asyncio.run(scenario())


@pytest.mark.parametrize("packet", [
    batch(commands=[]), batch(commands=[{"op": "stop", "unit_id": 1}] * 65),
    batch(seq=0), batch(seq=True), batch(seq=2**53 - 10),
    batch(source_tick=1), batch(execute_tick=0), batch(execute_tick=183),
    batch(commands=[{"op": "stop", "unit_id": 1, "team": 1}]), batch(commands=[{"unit_id": 1}]),
    batch(commands=[{"op": "match_end", "winner": 0}]),
])
def test_invalid_binary_batch_is_rejected_atomically(packet):
    with pytest.raises(ProtocolError):
        encode_packet(packet)


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
        await mm.handle(guest, {"type": "request_keyframe"})
        request, = drain(host)
        state = {"world": {"name": "压缩", "entities": [{"pos": [1.125, -2.25]}] * 100}, "simulation": {"next_id": 9}}
        packet = compressed(json.dumps(state, ensure_ascii=False).encode(), request_id=request["request_id"])
        assert parse_message(json.dumps(packet), Settings()) == packet
        assert decode_keyframe_state(packet, Settings()) == state
        assert len(json.dumps(packet)) < packet["raw_size"]
        await mm.handle(host, packet)
        assert drain(guest) == [packet]
        assert not room.keyframe_requests and guest.pending_keyframe is None
        await mm.shutdown()

    asyncio.run(scenario())


@pytest.mark.parametrize("packet", [
    batch(commands=[{"op": "set_ai_control", "enabled": True}]),
    batch(commands=[{"op": "move", "unit_id": 1, "pos": [1, 2], "service_url": "private"}]),
])
def test_private_controller_data_is_rejected_on_binary_routes(packet):
    with pytest.raises(ProtocolError):
        encode_packet(packet)


def test_private_controller_data_is_rejected_in_keyframes():
    for packet in (
        compressed(b'{"world":{"ai_control":{"0":{"service_url":"private"}}}}'),
        compressed(b'{"fair":{"generations":{},"controls":{}}}'),
    ):
        with pytest.raises(ProtocolError):
            parse_message(json.dumps(packet), Settings())
