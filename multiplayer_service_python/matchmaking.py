from __future__ import annotations

import asyncio
from collections import deque
from dataclasses import dataclass, field
import time
import uuid
from typing import Any, Callable

from .protocol import ProtocolError
from .settings import Settings


@dataclass
class Close:
    code: int
    error: str | None = None


@dataclass(eq=False)
class Player:
    id: str
    outbox: asyncio.Queue
    last_seen: float
    tokens_updated: float
    message_tokens: float
    byte_tokens: float
    name: str = ""
    civ: str = ""
    queued_at: float | None = None
    room_id: str | None = None
    team: int | None = None
    seq: int = 0


@dataclass
class Room:
    id: str
    players: tuple[Player, Player]
    created_at: float
    ready: set[int] = field(default_factory=set)
    started_at: float | None = None


class Matchmaker:
    """All state changes are serialized; slow network writes never hold the lock."""

    def __init__(self, settings: Settings, clock: Callable[[], float] = time.monotonic):
        self.settings = settings
        self.clock = clock
        self.players: dict[str, Player] = {}
        self.queue: deque[str] = deque()
        self.rooms: dict[str, Room] = {}
        self.lock = asyncio.Lock()

    async def register(self) -> Player | None:
        async with self.lock:
            if len(self.players) >= self.settings.max_connections:
                return None
            now = self.clock()
            player = Player(
                id=uuid.uuid4().hex,
                outbox=asyncio.Queue(maxsize=self.settings.outgoing_queue_size),
                last_seen=now,
                tokens_updated=now,
                message_tokens=self.settings.message_burst,
                byte_tokens=self.settings.byte_burst,
            )
            self.players[player.id] = player
            return player

    async def admit_message(self, player: Player, byte_count: int) -> bool:
        async with self.lock:
            if player.id not in self.players:
                return False
            now = self.clock()
            elapsed = max(0.0, now - player.tokens_updated)
            player.tokens_updated = now
            player.message_tokens = min(self.settings.message_burst,
                                        player.message_tokens + elapsed * self.settings.messages_per_second)
            player.byte_tokens = min(self.settings.byte_burst,
                                     player.byte_tokens + elapsed * self.settings.bytes_per_second)
            if player.message_tokens < 1 or player.byte_tokens < byte_count:
                self._disconnect(player, 1008, "rate_limited")
                return False
            player.message_tokens -= 1
            player.byte_tokens -= byte_count
            player.last_seen = now
            return True

    def _emit(self, player: Player, message: dict) -> None:
        if player.id not in self.players:
            return
        try:
            player.outbox.put_nowait(message)
        except asyncio.QueueFull:
            self._disconnect(player, 1008, "slow_consumer")

    def _remove_from_queue(self, player: Player) -> None:
        try:
            self.queue.remove(player.id)
        except ValueError:
            pass
        player.queued_at = None

    def _end(self, room: Room, winner: int | None, reason: str) -> None:
        if self.rooms.pop(room.id, None) is None:
            return
        # Clear both identities before notifications, which may detect a slow peer.
        for player in room.players:
            player.room_id = None
            player.team = None
            player.seq = 0
        message = {"type": "match_ended", "match_id": room.id, "winner": winner, "reason": reason}
        for player in room.players:
            self._emit(player, message)

    def _disconnect(self, player: Player, close_code: int | None = None, error: str | None = None) -> None:
        if self.players.pop(player.id, None) is None:
            return
        self._remove_from_queue(player)
        room = self.rooms.get(player.room_id)
        if room is not None:
            self._end(room, 1 - player.team, "opponent_left")
        if close_code is not None:
            while not player.outbox.empty():
                player.outbox.get_nowait()
            player.outbox.put_nowait(Close(close_code, error))

    async def disconnect(self, player: Player, close_code: int | None = None, error: str | None = None) -> None:
        async with self.lock:
            self._disconnect(player, close_code, error)

    async def error(self, player: Player, error: ProtocolError) -> None:
        async with self.lock:
            if error.close_code is not None:
                self._disconnect(player, error.close_code, error.code)
            else:
                self._emit(player, {"type": "error", "code": error.code, "message": error.message})

    def _match(self) -> None:
        while len(self.queue) >= 2:
            ids = [self.queue.popleft(), self.queue.popleft()]
            pair = tuple(self.players[player_id] for player_id in ids)
            room = Room(uuid.uuid4().hex, pair, self.clock())
            self.rooms[room.id] = room
            for team, player in enumerate(pair):
                player.queued_at = None
                player.room_id = room.id
                player.team = team
                player.seq = 0
            roster = [{"team": team, "name": player.name, "civ": player.civ}
                      for team, player in enumerate(pair)]
            for team, player in enumerate(pair):
                # An outbound failure may have already ended the room.
                if room.id not in self.rooms:
                    break
                self._emit(player, {"type": "match_found", "match_id": room.id,
                                    "team": team, "host_team": 0, "players": roster})

    def _room(self, player: Player, *, started: bool = False) -> Room:
        room = self.rooms.get(player.room_id)
        if room is None:
            raise ProtocolError("invalid_state", "Player is not in a match")
        if started and room.started_at is None:
            raise ProtocolError("invalid_state", "Both players must be ready first")
        return room

    async def handle(self, player: Player, message: dict[str, Any]) -> None:
        async with self.lock:
            if player.id not in self.players:
                return
            kind = message["type"]
            if kind == "ping":
                self._emit(player, {"type": "pong"})
            elif kind == "join_queue":
                if player.room_id is not None or player.queued_at is not None:
                    raise ProtocolError("invalid_state", "Player is already queued or matched")
                if len(self.queue) >= self.settings.max_queue:
                    raise ProtocolError("queue_full", "Matchmaking queue is full")
                player.name, player.civ = message["name"], message["civ"]
                player.queued_at = self.clock()
                self.queue.append(player.id)
                self._emit(player, {"type": "queued"})
                self._match()
            elif kind in ("cancel_queue", "leave"):
                self._remove_from_queue(player)
                room = self.rooms.get(player.room_id)
                if room is not None:
                    self._end(room, 1 - player.team, "opponent_left")
                if kind == "cancel_queue":
                    self._emit(player, {"type": "queue_cancelled"})
            elif kind == "ready":
                room = self._room(player)
                if room.started_at is not None:
                    raise ProtocolError("invalid_state", "Match has already started")
                room.ready.add(player.team)
                if len(room.ready) == 2:
                    room.started_at = self.clock()
                    for member in room.players:
                        if room.id not in self.rooms:
                            break
                        self._emit(member, {"type": "start", "match_id": room.id})
            elif kind in ("command", "snapshot"):
                room = self._room(player, started=True)
                expected_team = 1 if kind == "command" else 0
                if player.team != expected_team:
                    raise ProtocolError("forbidden", f"Only team {expected_team} may send {kind}")
                if message["seq"] <= player.seq:
                    raise ProtocolError("invalid_sequence", "seq must increase during each match")
                player.seq = message["seq"]
                outgoing = dict(message)
                if kind == "command":
                    outgoing["team"] = player.team
                self._emit(room.players[1 - player.team], outgoing)
            elif kind == "finish_match":
                room = self._room(player, started=True)
                if player.team != 0:
                    raise ProtocolError("forbidden", "Only the host may finish a match")
                self._end(room, message["winner"], "completed")

    async def sweep(self) -> None:
        async with self.lock:
            now = self.clock()
            for player in list(self.players.values()):
                if now - player.last_seen >= self.settings.idle_timeout:
                    self._disconnect(player, 1001, "idle_timeout")
                elif player.queued_at is not None and now - player.queued_at >= self.settings.queue_timeout:
                    self._remove_from_queue(player)
                    self._emit(player, {"type": "queue_cancelled", "reason": "queue_timeout"})
            for room in list(self.rooms.values()):
                if room.started_at is None and now - room.created_at >= self.settings.ready_timeout:
                    self._end(room, None, "ready_timeout")
                elif room.started_at is not None and now - room.started_at >= self.settings.match_timeout:
                    self._end(room, None, "match_timeout")

    async def shutdown(self) -> None:
        async with self.lock:
            for room in list(self.rooms.values()):
                self._end(room, None, "server_shutdown")
            for player in list(self.players.values()):
                self._disconnect(player, 1001, "server_shutdown")

    async def status(self) -> dict:
        async with self.lock:
            return {"status": "ok", "protocol_version": 1, "connections": len(self.players),
                    "queued": len(self.queue), "matches": len(self.rooms)}
