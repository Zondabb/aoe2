"""Publish v6 prepare/commit packets before an execution report."""

def commit(tick):
    return {"type": "input_commit", "tick": tick, "execute_at_usec": tick * 100000,
            "speed": 1.0, "input_delay_ticks": 18, "delay_from_tick": 0}


def consume_control(player, kind, tick):
    keep, found = [], []
    while not player.outbox.empty():
        item = player.outbox.get_nowait()
        if isinstance(item, dict) and item.get("type") == kind and item.get("tick") == tick:
            found.append(item)
        else:
            keep.append(item)
    for item in keep:
        player.outbox.put_nowait(item)
    assert len(found) == 1


async def publish(mm, host, frame):
    room = mm.rooms[host.room_id]
    tick = frame["tick"]
    if tick == room.announced_tick + 3:
        guest = room.players[1 - room.host_team]
        await mm.handle(host, {"type": "input_frame", "tick": tick, "commands": []})
        consume_control(guest, "input_frame", tick)
        await mm.handle(host, commit(tick))
        consume_control(guest, "input_commit", tick)
    await mm.handle(host, frame)


def prepare_socket(host, guest, tick):
    host.send_json({"type": "input_frame", "tick": tick, "commands": []})
    assert guest.receive_json()["type"] == "input_frame"
    host.send_json(commit(tick))
    assert guest.receive_json()["type"] == "input_commit"
