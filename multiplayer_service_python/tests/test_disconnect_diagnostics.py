import asyncio
import logging

from multiplayer_service_python.matchmaking import Matchmaker
from multiplayer_service_python.settings import Settings


def test_slow_receiver_cause_reaches_opponent_without_changing_result_semantics(caplog):
    async def scenario():
        matchmaker = Matchmaker(Settings())
        host, guest = await matchmaker.register(), await matchmaker.register()
        for player, name in ((host, "Host"), (guest, "Guest")):
            await matchmaker.handle(player, {"type": "join_queue", "name": name, "civ": "chinese"})
        for player in (host, guest):
            await matchmaker.handle(player, {"type": "ready"})
        while not host.outbox.empty():
            host.outbox.get_nowait()
        with caplog.at_level(logging.WARNING):
            await matchmaker.disconnect(guest, 1008, "slow_consumer")
        result = host.outbox.get_nowait()
        assert result["reason"] == "opponent_left" and result["winner"] == 0
        assert result["disconnect_reason"] == "slow_consumer"
        assert not matchmaker.rooms and host.room_id is None
        assert "reason=slow_consumer" in caplog.text and "code=1008" in caplog.text
        assert "Guest" not in caplog.text  # diagnostics contain IDs, never player payloads
        await matchmaker.shutdown()

    asyncio.run(scenario())


def test_bandwidth_rejection_logs_byte_budget_without_payloads(caplog):
    async def scenario():
        matchmaker = Matchmaker(Settings())
        player = await matchmaker.register()
        with caplog.at_level(logging.WARNING):
            admitted = await matchmaker.admit_message(player, int(matchmaker.settings.byte_burst) + 1)
        assert not admitted and player.id not in matchmaker.players
        assert "multiplayer_rate_limit" in caplog.text and "bytes_available=" in caplog.text
        assert player.outbox.get_nowait().error == "rate_limited"

    asyncio.run(scenario())
