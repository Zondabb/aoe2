import asyncio
import json

import pytest

from multiplayer_service_python.matchmaking import Matchmaker
from multiplayer_service_python.protocol import ProtocolError, parse_message
from multiplayer_service_python.settings import Settings
from multiplayer_service_python.tests.test_incremental_sync import started, drain, spectator, frame
from multiplayer_service_python.tests.fair_helpers import commit


@pytest.mark.parametrize("host_team", [0, 1])
def test_prepare_commit_recovery_and_permissions(monkeypatch, host_team):
    monkeypatch.setattr("multiplayer_service_python.matchmaking.secrets.randbelow", lambda n: host_team if n == 2 else 123)

    async def scenario():
        mm = Matchmaker(Settings())
        room, host, guest = await started(mm)
        viewer = await spectator(mm, room)
        plan = {"type": "input_frame", "tick": 3, "commands": [
            {"team": guest.team, "seq": 1, "command": {"op": "move", "unit_id": 99, "pos": [3, 4]}}]}
        with pytest.raises(ProtocolError):
            await mm.handle(guest, plan)
        with pytest.raises(ProtocolError):
            await mm.handle(host, frame(3))
        with pytest.raises(ProtocolError):
            await mm.handle(host, commit(3))
        await mm.handle(host, plan)
        assert drain(guest) == [plan] and not drain(viewer)
        # Committing immediately after preparation must not need a guest RTT.
        await mm.handle(host, commit(3))
        assert room.input_ack_tick == 0 and drain(guest) == [commit(3)]
        with pytest.raises(ProtocolError):
            await mm.handle(host, {"type": "input_ack", "tick": 3})
        with pytest.raises(ProtocolError):
            await mm.handle(guest, {"type": "input_ack", "tick": 6})
        await mm.handle(guest, {"type": "input_ack", "tick": 3})
        assert drain(host)[0]["team"] == guest.team
        # Recovery replays byte-equivalent plans and timing, never new decisions.
        await mm.handle(host, plan)
        await mm.handle(host, commit(3))
        assert drain(guest) == [plan, commit(3)]
        with pytest.raises(ProtocolError, match="immutable"):
            await mm.handle(host, dict(plan, commands=[]))
        with pytest.raises(ProtocolError, match="immutable"):
            await mm.handle(host, dict(commit(3), execute_at_usec=123456))
        with pytest.raises(ProtocolError, match="immutable"):
            await mm.handle(host, dict(commit(3), delay_from_tick=60))
        result = dict(frame(3), results=[{"team": guest.team, "seq": 1, "accepted": False}])
        await mm.handle(host, result)
        assert drain(guest) == drain(viewer) == [result]
        assert room.tick == 3 and not room.input_hashes and not room.input_commits
        for sender, recipient in [(host, guest), (guest, host)]:
            probe = {"type": "clock_probe", "nonce": 1, "sent_usec": 123456}
            await mm.handle(sender, probe)
            assert drain(recipient) == [{**probe, "team": sender.team}]
            assert not drain(viewer)
        for packet in [plan, commit(3), {"type": "input_ack", "tick": 3}, probe]:
            with pytest.raises(ProtocolError):
                await mm.handle(viewer, packet)
        await mm.shutdown()

    asyncio.run(scenario())


@pytest.mark.parametrize("host_team", [0, 1])
def test_commits_pipeline_before_ack_but_cannot_skip_or_precede_preparation(monkeypatch, host_team):
    monkeypatch.setattr("multiplayer_service_python.matchmaking.secrets.randbelow", lambda n: host_team if n == 2 else 123)

    async def scenario():
        mm = Matchmaker(Settings())
        room, host, guest = await started(mm)
        viewer = await spectator(mm, room)
        plans = [{"type": "input_frame", "tick": tick, "commands": []} for tick in (3, 6)]
        for plan in plans:
            await mm.handle(host, plan)
        with pytest.raises(ProtocolError, match="consecutive prepared"):
            await mm.handle(host, commit(6))
        with pytest.raises(ProtocolError, match="Only the host"):
            await mm.handle(guest, commit(3))
        await mm.handle(host, commit(3))
        await mm.handle(host, commit(6))
        assert drain(guest) == [*plans, commit(3), commit(6)]
        assert room.committed_tick == 6 and room.input_ack_tick == 0
        assert not drain(host) and not drain(viewer)
        with pytest.raises(ProtocolError, match="consecutive prepared"):
            await mm.handle(host, commit(9))
        for tick in (3, 6):
            await mm.handle(host, frame(tick))
        assert drain(guest) == drain(viewer) == [frame(3), frame(6)]
        # A late receipt is still forwarded as diagnostics, and cannot change
        # an execution time or cause a second publication of the results.
        await mm.handle(guest, {"type": "input_ack", "tick": 6})
        await mm.handle(guest, {"type": "input_ack", "tick": 3})
        assert room.input_ack_tick == 6
        assert [packet["tick"] for packet in drain(host)] == [6, 3]
        assert not drain(guest) and not drain(viewer)
        assert not room.input_hashes and not room.input_commits
        with pytest.raises(ProtocolError):
            await mm.handle(host, commit(6))
        await mm.shutdown()

    asyncio.run(scenario())


@pytest.mark.parametrize("packet", [
    {"type": "command", "seq": 1, "source_tick": 0, "execute_tick": 0, "command": {"op": "stop"}},
    {"type": "command", "seq": 1, "source_tick": 0, "execute_tick": 183, "command": {"op": "stop"}},
    {"type": "command", "seq": 1, "source_tick": 1, "execute_tick": 6, "command": {"op": "stop"}},
    {"type": "clock_probe", "nonce": True, "sent_usec": 1},
    {"type": "clock_reply", "nonce": 1, "sent_usec": 1, "received_usec": 2**54},
    dict(commit(3), speed=float("inf")),
    dict(commit(3), input_delay_ticks=4),
    dict(commit(3), delay_from_tick=-3),
    dict(commit(3), delay_from_tick=4),
    dict(commit(3), delay_from_tick=True),
    dict(commit(3), delay_from_tick=3.0),
    dict(commit(3), delay_from_tick=2**54),
    {key: value for key, value in commit(3).items() if key != "delay_from_tick"},
    {"type": "input_frame", "tick": 3, "commands": [{"team": 0, "seq": 1, "command": {"op": "stop"}, "ai": {}}]},
    {"type": "input_frame", "tick": 3, "commands": [{"team": 0, "seq": 1, "command": {"op": "ai_instruction", "text": "private"}}]},
    {"type": "input_frame", "tick": 3, "commands": [{"team": 0, "seq": 1, "command": {"op": "stop"}}] * 2},
    dict(frame(3), results=[{"team": 0, "seq": 1, "accepted": 1}]),
    dict(frame(3), results=[{"team": 0, "seq": 1, "accepted": True}] * 2),
])
def test_invalid_scheduled_wire(packet):
    with pytest.raises(ProtocolError):
        parse_message(json.dumps(packet), Settings())


@pytest.mark.parametrize("activation", [0, 3, 180])
def test_delay_activation_is_transported_without_simulating_or_waiting(activation):
    async def scenario():
        mm = Matchmaker(Settings(), clock=lambda: 0.0)
        room, host, guest = await started(mm)
        packet = dict(commit(3), delay_from_tick=activation, input_delay_ticks=6)
        assert parse_message(json.dumps(packet), Settings()) == packet
        await mm.handle(host, {"type": "input_frame", "tick": 3, "commands": []})
        await mm.handle(host, packet)
        assert drain(guest)[-1] == packet
        assert room.tick == 0 and room.committed_tick == 3 and room.input_ack_tick == 0
        assert room.input_commits[3] == packet
        await mm.shutdown()

    asyncio.run(scenario())


def test_pending_frame_memory_is_bounded():
    async def scenario():
        mm = Matchmaker(Settings())
        room, host, guest = await started(mm)
        for tick in range(3, 181, 3):
            await mm.handle(host, {"type": "input_frame", "tick": tick, "commands": []})
            drain(guest)
        with pytest.raises(ProtocolError):
            await mm.handle(host, {"type": "input_frame", "tick": 183, "commands": []})
        assert len(room.input_hashes) == 60
        await mm.shutdown()
    asyncio.run(scenario())
