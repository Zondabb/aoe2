import asyncio
import json

import pytest

from multiplayer_service_python.matchmaking import Matchmaker
from multiplayer_service_python.protocol import ProtocolError, parse_message
from multiplayer_service_python.settings import Settings
from multiplayer_service_python.tests.fair_helpers import make_schedule, make_sync_init, send_bin
from multiplayer_service_python.tests.test_incremental_sync import drain, started
from multiplayer_service_python.wire import encode_packet, parse_binary_message


@pytest.mark.parametrize("host_team", [0, 1])
def test_binary_schedule_ack_and_reschedule(monkeypatch, host_team):
    monkeypatch.setattr("multiplayer_service_python.matchmaking.secrets.randbelow", lambda n: host_team if n == 2 else 123)

    async def scenario():
        mm = Matchmaker(Settings())
        room, host, guest = await started(mm)
        sync_pkt = make_sync_init(0, 0x12345678, 2.0)
        with pytest.raises(ProtocolError):
            await send_bin(mm, guest, sync_pkt)
        raw_sync = await send_bin(mm, host, sync_pkt)
        assert drain(guest) == [raw_sync]

        sched1 = make_schedule(1, 6)
        with pytest.raises(ProtocolError):
            await send_bin(mm, guest, sched1)
        raw_s1 = await send_bin(mm, host, sched1)
        assert drain(guest) == [raw_s1]
        assert room.last_schedule_id == 1

        # Immutable resend succeeds identically; mutated schedule is rejected.
        await send_bin(mm, host, sched1)
        assert drain(guest) == [raw_s1]
        with pytest.raises(ProtocolError, match="immutable"):
            await send_bin(mm, host, make_schedule(1, 6, commands=[] , timing={"speed": 2.0, "input_delay_ticks": 6, "delay_from_tick": 0}))

        # Consecutive schedule IDs required
        with pytest.raises(ProtocolError, match="consecutive"):
            await send_bin(mm, host, make_schedule(3, 9))

        # Guest rejects late schedule (accepted=False, guest_tick=9) -> bumps room.tick
        ack1 = {"type": "schedule_ack", "id": 1, "accepted": False, "guest_tick": 9}
        with pytest.raises(ProtocolError):
            await send_bin(mm, host, ack1)
        raw_ack1 = await send_bin(mm, guest, ack1)
        assert drain(host) == [raw_ack1]
        assert room.tick == 9

        # Rescheduled packet must be >= room.tick + 3
        with pytest.raises(ProtocolError, match="bounds"):
            await send_bin(mm, host, make_schedule(2, 9))
        raw_s2 = await send_bin(mm, host, make_schedule(2, 12, timing={"speed": 3.0, "input_delay_ticks": 9, "delay_from_tick": 12}))
        assert drain(guest) == [raw_s2]
        raw_ack2 = await send_bin(mm, guest, {"type": "schedule_ack", "id": 2, "accepted": True, "guest_tick": 9})
        assert drain(host) == [raw_ack2]

        # Clock probes and replies are exact fixed-size binary packets
        for sender, recipient in [(host, guest), (guest, host)]:
            raw_probe = await send_bin(mm, sender, {"type": "clock_probe", "nonce": 7, "sent_usec": 123456})
            assert len(raw_probe) == 13 and drain(recipient) == [raw_probe]
            raw_reply = await send_bin(mm, recipient, {"type": "clock_reply", "nonce": 7, "sent_usec": 123456, "received_usec": 234567})
            assert len(raw_reply) == 21 and drain(sender) == [raw_reply]

        await mm.shutdown()

    asyncio.run(scenario())


def test_wire_roundtrip_all_command_ops():
    commands = [
        {"op": "move", "unit_id": 1, "pos": [1.5, -2.25]},
        {"op": "move", "unit_id": 128, "pos": [10.0, 20.0], "formation_speed": 4.5},
        {"op": "stop", "unit_id": 7},
        {"op": "gather", "unit_id": 3, "target_id": 999},
        {"op": "build", "unit_id": 4, "building_id": 55},
        {"op": "attack", "unit_id": 5, "target_id": 88},
        {"op": "train", "building_id": 2, "unit_def_id": "villager"},
        {"op": "cancel_train", "building_id": 2, "queue_id": 19},
        {"op": "place_building", "builder_id": 6, "building_def_id": "house", "pos": [32.0, -16.0]},
        {"op": "place_building", "builder_id": 6, "building_def_id": "gate", "pos": [32.0, -16.0], "orientation": 2},
        {"op": "research_age", "building_id": 1},
        {"op": "cancel_research_age", "building_id": 1},
        {"op": "research_technology", "building_id": 1, "technology_id": "loom"},
        {"op": "cancel_technology", "building_id": 1, "technology_id": "loom"},
        {"op": "place_wall", "builder_id": 3, "building_def_id": "stone_wall", "start": [0.0, 0.0], "end": [12.0, 0.0], "include_gate": True, "append_queue": False},
        {"op": "set_gate_state", "building_id": 22, "gate_state": "locked"},
    ]
    raw = encode_packet({"type": "command_batch", "team": 0, "seq": 1, "source_tick": 0, "execute_tick": 6, "commands": commands})
    decoded = parse_binary_message(raw, Settings())
    assert decoded["commands"] == commands
    # match_end allowed only in schedule with seq=0
    sched = make_schedule(1, 6, commands=[{"team": 0, "seq": 0, "command": {"op": "match_end", "winner": 1}}])
    raw_sched = encode_packet(sched)
    assert parse_binary_message(raw_sched, Settings())["commands"] == sched["commands"]


@pytest.mark.parametrize("raw", [
    b"",
    b"\x01" * 12,  # truncated clock_probe
    b"\x01" + b"\x01\x00\x00\x00" + b"\x00" * 8 + b"\xff",  # trailing byte
    b"\x99\x00",  # unknown type
    b"\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",  # heartbeat sent_usec32 == 0
    b"\x04\x00\x80\x00\x00\x00\x00\x00\x06\x00\x00\x00\x01\x02\x01",  # non-canonical varint (0x80 0x00)
    b"\x04\x00\x01\x00\x00\x00\x00\x06\x00\x00\x00\x01\x0f\x00",  # match_end inside CMD_SUBMIT
    b"\x04\x00\x01\x00\x00\x00\x00\x06\x00\x00\x00\x01\x01\x01\x00\x00\xc0\x7f\x00\x00\x00\x00",  # NaN float in move
])
def test_adversarial_binary_packets_rejected(raw):
    with pytest.raises(ProtocolError):
        parse_binary_message(raw, Settings())


def test_schedule_memory_is_bounded_and_only_host_can_match_end():
    async def scenario():
        mm = Matchmaker(Settings())
        room, host, guest = await started(mm)
        for idx in range(1, 70):
            await send_bin(mm, host, make_schedule(idx, idx * 3))
            drain(guest)
        assert len(room.schedule_hashes) == 64
        with pytest.raises(ProtocolError, match="reserved for host"):
            await send_bin(mm, host, make_schedule(70, 210, commands=[{"team": guest.team, "seq": 0, "command": {"op": "match_end", "winner": 0}}]))
        await mm.shutdown()

    asyncio.run(scenario())


def test_v9_clients_are_rejected_before_matching():
    with pytest.raises(ProtocolError, match="protocol_version 10"):
        parse_message(json.dumps({"type": "join_queue", "protocol_version": 9, "name": "old", "civ": "chinese"}), Settings())
