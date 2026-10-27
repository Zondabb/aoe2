from __future__ import annotations

import asyncio
from collections import deque
from dataclasses import dataclass, field
import time
import uuid
import logging
import sqlite3
from typing import Any, Callable

from .protocol import ProtocolError
from .settings import Settings
from .leaderboard import Leaderboard

logger = logging.getLogger(__name__)


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
    spectating: bool = False
    spectator_ready: bool = False


@dataclass
class Room:
    id: str
    players: tuple[Player, Player]
    created_at: float
    ready: set[int] = field(default_factory=set)
    started_at: float | None = None
    spectators: dict[str, Player] = field(default_factory=dict)
    latest_snapshot: dict | None = None


class Matchmaker:
    """All state changes are serialized; slow network writes never hold the lock."""

    def __init__(self, settings: Settings, clock: Callable[[], float] = time.monotonic,
                 leaderboard: Leaderboard | None = None):
        self.settings = settings
        self.leaderboard = leaderboard
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
                logger.warning("multiplayer_rate_limit player=%s room=%s bytes=%d bytes_available=%.0f messages_available=%.1f",
                               player.id, player.room_id, byte_count, player.byte_tokens, player.message_tokens)
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

    def _end(self, room: Room, winner: int | None, reason: str, disconnect_reason: str | None = None) -> None:
        if self.rooms.pop(room.id, None) is None:
            return
        if self.leaderboard is not None and room.started_at is not None and winner in (0, 1):
            try:
                self.leaderboard.record(room.id, tuple(player.name for player in room.players), winner, reason)
            except (sqlite3.Error, OSError):
                # A storage failure must not strand players in an ended room.
                logger.exception("Could not persist result for match %s", room.id)
        # Clear all identities before notifications, which may detect a slow peer.
        members = [*room.players, *room.spectators.values()]
        room.spectators.clear()
        room.latest_snapshot = None
        for player in members:
            player.room_id = None
            player.team = None
            player.seq = 0
            player.spectating = False
            player.spectator_ready = False
        message = {"type": "match_ended", "match_id": room.id, "winner": winner, "reason": reason}
        if disconnect_reason:
            message["disconnect_reason"] = disconnect_reason
        for player in members:
            self._emit(player, message)

    def _disconnect(self, player: Player, close_code: int | None = None, error: str | None = None) -> None:
        if self.players.pop(player.id, None) is None:
            return
        log = logger.warning if error in {"rate_limited", "slow_consumer", "idle_timeout", "send_timeout"} else logger.info
        log("multiplayer_disconnect player=%s room=%s role=%s code=%s reason=%s queue=%d seq=%d",
            player.id, player.room_id, "spectator" if player.spectating else "player",
            close_code, error or "leaving", player.outbox.qsize(), player.seq)
        self._remove_from_queue(player)
        room = self.rooms.get(player.room_id)
        if player.spectating:
            self._leave_spectating(player)
        elif room is not None:
            self._end(room, 1 - player.team, "opponent_left", error)
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
        if player.spectating:
            raise ProtocolError("forbidden", "Spectators cannot control a match")
        room = self.rooms.get(player.room_id)
        if room is None:
            raise ProtocolError("invalid_state", "Player is not in a match")
        if started and room.started_at is None:
            raise ProtocolError("invalid_state", "Both players must be ready first")
        return room

    @staticmethod
    def _roster(room: Room) -> list[dict]:
        return [{"team": team, "name": player.name, "civ": player.civ}
                for team, player in enumerate(room.players)]

    def _match_list(self) -> list[dict]:
        now = self.clock()
        return [{"match_id": room.id, "players": self._roster(room),
                 "elapsed_seconds": max(0, int(now - room.started_at)),
                 "spectator_count": len(room.spectators)}
                for room in self.rooms.values()
                if room.started_at is not None and room.latest_snapshot is not None
                ][:self.settings.max_listed_matches]

    async def list_matches(self) -> dict:
        async with self.lock:
            return {"matches": self._match_list()}

    def _watch(self, player: Player, match_id: str) -> None:
        if player.room_id is not None or player.queued_at is not None:
            raise ProtocolError("invalid_state", "Leave your current match or queue before spectating")
        room = self.rooms.get(match_id)
        if room is None or room.started_at is None or room.latest_snapshot is None:
            raise ProtocolError("match_unavailable", "This match is no longer available for spectating")
        if len(room.spectators) >= self.settings.max_spectators_per_match:
            raise ProtocolError("spectators_full", "This match has reached its spectator limit")
        player.room_id = room.id
        player.team = None
        player.spectating = True
        player.spectator_ready = False
        player.seq = 0
        room.spectators[player.id] = player
        self._emit(player, {"type": "spectate_started", "match_id": room.id,
                            "host_team": 0, "role": "spectator", "players": self._roster(room)})
        self._emit(player, room.latest_snapshot)

    def _leave_spectating(self, player: Player) -> None:
        room = self.rooms.get(player.room_id)
        if room is not None:
            room.spectators.pop(player.id, None)
        player.room_id = None
        player.team = None
        player.spectating = False
        player.spectator_ready = False
        player.seq = 0

    async def handle(self, player: Player, message: dict[str, Any]) -> None:
        async with self.lock:
            if player.id not in self.players:
                return
            kind = message["type"]
            if player.spectating and kind not in ("ping", "leave", "list_matches", "watch_ready"):
                raise ProtocolError("forbidden", "Spectators cannot control a match; leave before playing")
            if kind == "ping":
                self._emit(player, {"type": "pong"})
            elif kind == "list_matches":
                self._emit(player, {"type": "matches", "matches": self._match_list()})
            elif kind == "watch_match":
                self._watch(player, message["match_id"])
            elif kind == "watch_ready":
                if not player.spectating:
                    raise ProtocolError("forbidden", "Only spectators may finish loading a watched match")
                room = self.rooms.get(player.room_id)
                if room is None or player.id not in room.spectators:
                    raise ProtocolError("invalid_state", "Spectated match is no longer available")
                player.spectator_ready = True
                # Loading a Godot scene can block socket polling. Keep only the
                # newest room snapshot until the spectator explicitly resumes.
                if room.latest_snapshot is not None:
                    self._emit(player, room.latest_snapshot)
            elif kind == "join_queue":
                if player.room_id is not None or player.queued_at is not None:
                    raise ProtocolError("invalid_state", "Player is already queued or matched")
                if len(self.queue) >= self.settings.max_queue:
                    raise ProtocolError("queue_full", "Matchmaking queue is full")
                player.name, player.civ = message["name"], message["civ"]
                if self.leaderboard is not None:
                    try:
                        self.leaderboard.register(player.name)
                    except (sqlite3.Error, OSError):
                        logger.exception("Could not register leaderboard player")
                player.queued_at = self.clock()
                self.queue.append(player.id)
                self._emit(player, {"type": "queued"})
                self._match()
            elif kind in ("cancel_queue", "leave"):
                if player.spectating:
                    self._leave_spectating(player)
                    return
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
                else:
                    room.latest_snapshot = outgoing
                self._emit(room.players[1 - player.team], outgoing)
                if kind == "snapshot" and room.id in self.rooms:
                    for spectator in list(room.spectators.values()):
                        if spectator.spectator_ready:
                            self._emit(spectator, outgoing)
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
                    "queued": len(self.queue), "matches": len(self.rooms),
                    "spectators": sum(len(room.spectators) for room in self.rooms.values())}
