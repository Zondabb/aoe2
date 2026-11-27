from __future__ import annotations

import asyncio
from collections import deque
from dataclasses import dataclass, field
import hashlib
import logging
import secrets
import sqlite3
import time
from typing import Any, Callable
import uuid

from .leaderboard import Leaderboard
from .protocol import FRAME_TICKS, PROTOCOL_VERSION, TICK_RATE, ProtocolError
from .settings import Settings

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
    ack_tick: int = -1
    pending_keyframe: str | None = None
    last_keyframe_request: float | None = None


@dataclass
class Room:
    id: str
    players: tuple[Player, Player]
    created_at: float
    ready: set[int] = field(default_factory=set)
    started_at: float | None = None
    host_team: int = field(default_factory=lambda: secrets.randbelow(2))
    seed: int = field(default_factory=lambda: secrets.randbelow(2_147_483_647))
    tick: int = 0
    last_schedule_id: int = 0
    schedule_hashes: dict[int, bytes] = field(default_factory=dict)
    keyframe_requests: dict[str, tuple[set[str], float]] = field(default_factory=dict)
    last_keyframe_dispatch: float | None = None


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

    def _emit(self, player: Player, message: dict | bytes) -> None:
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

    def _end(self, room: Room, winner: int | None, reason: str,
             disconnect_reason: str | None = None, final_tick: int | None = None) -> None:
        if self.rooms.pop(room.id, None) is None:
            return
        if self.leaderboard is not None and room.started_at is not None and winner in (0, 1):
            try:
                self.leaderboard.record(room.id, tuple(player.name for player in room.players), winner, reason)
            except (sqlite3.Error, OSError):
                # A storage failure must not strand players in an ended room.
                logger.exception("Could not persist result for match %s", room.id)
        members = [*room.players]
        room.keyframe_requests.clear()
        for player in members:
            player.room_id = None
            player.team = None
            player.seq = 0
            player.ack_tick = -1
            player.pending_keyframe = None
            player.last_keyframe_request = None
        message: dict[str, Any] = {"type": "match_ended", "match_id": room.id, "winner": winner, "reason": reason}
        if disconnect_reason:
            message["disconnect_reason"] = disconnect_reason
        if final_tick is not None:
            message["tick"] = final_tick
        for player in members:
            self._emit(player, message)

    def _disconnect(self, player: Player, close_code: int | None = None, error: str | None = None) -> None:
        if self.players.pop(player.id, None) is None:
            return
        log = logger.warning if error in {"rate_limited", "slow_consumer", "idle_timeout", "send_timeout"} else logger.info
        log("multiplayer_disconnect player=%s room=%s role=player code=%s reason=%s queue=%d seq=%d",
            player.id, player.room_id, close_code, error or "leaving", player.outbox.qsize(), player.seq)
        self._remove_from_queue(player)
        room = self.rooms.get(player.room_id)
        if room is not None:
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
                player.ack_tick = -1
                player.pending_keyframe = None
                player.last_keyframe_request = None
            roster = [{"team": team, "name": player.name, "civ": player.civ}
                      for team, player in enumerate(pair)]
            for team, player in enumerate(pair):
                if room.id not in self.rooms:
                    break
                self._emit(player, {"type": "match_found", "match_id": room.id,
                                    "team": team, "players": roster, **self._simulation_info(room)})

    def _room(self, player: Player, *, started: bool = False) -> Room:
        room = self.rooms.get(player.room_id)
        if room is None:
            raise ProtocolError("invalid_state", "Player is not in a match")
        if started and room.started_at is None:
            raise ProtocolError("invalid_state", "Both players must be ready first")
        return room

    @staticmethod
    def _simulation_info(room: Room) -> dict:
        return {"protocol_version": PROTOCOL_VERSION, "host_team": room.host_team,
                "seed": room.seed, "tick_rate": TICK_RATE, "frame_ticks": FRAME_TICKS}

    def _request_keyframe(self, player: Player) -> None:
        room = self._room(player, started=True)
        if player.team == room.host_team:
            raise ProtocolError("forbidden", "The host already owns the authoritative state")
        if player.pending_keyframe is not None:
            return
        now = self.clock()
        if player.last_keyframe_request is not None and now - player.last_keyframe_request < self.settings.keyframe_request_interval:
            raise ProtocolError("keyframe_rate_limited", "Wait before requesting another keyframe")
        if room.keyframe_requests:
            request_id = next(iter(room.keyframe_requests))
            room.keyframe_requests[request_id][0].add(player.id)
        else:
            interval = max(self.settings.keyframe_request_interval,
                           self.settings.max_message_bytes / (self.settings.bytes_per_second * 0.75))
            if room.last_keyframe_dispatch is not None and now - room.last_keyframe_dispatch < interval:
                raise ProtocolError("keyframe_rate_limited", "Wait before requesting another room keyframe")
            request_id = uuid.uuid4().hex
            room.keyframe_requests[request_id] = ({player.id}, now)
            room.last_keyframe_dispatch = now
            self._emit(room.players[room.host_team], {"type": "keyframe_request", "request_id": request_id})
        player.pending_keyframe = request_id
        player.last_keyframe_request = now
        player.ack_tick = -1

    async def handle(self, player: Player, message: dict[str, Any]) -> None:
        async with self.lock:
            if player.id not in self.players:
                return
            kind = message["type"]
            if kind == "ping":
                self._emit(player, {"type": "pong"})
            elif kind == "request_keyframe":
                self._request_keyframe(player)
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
                        self._emit(member, {"type": "start", "match_id": room.id, **self._simulation_info(room)})
            elif kind == "keyframe":
                room = self._room(player, started=True)
                if player.team != room.host_team:
                    raise ProtocolError("forbidden", "Only the host may send a keyframe")
                request = room.keyframe_requests.get(message["request_id"])
                if request is None:
                    return
                if message["tick"] < room.tick or message["tick"] > room.tick + 360:
                    raise ProtocolError("invalid_sequence", "Keyframe tick is out of bounds")
                room.tick = message["tick"]
                room.schedule_hashes.clear()
                room.keyframe_requests.pop(message["request_id"])
                for player_id in list(request[0]):
                    target = self.players.get(player_id)
                    if target is not None and target.room_id == room.id and target.pending_keyframe == message["request_id"]:
                        target.pending_keyframe = None
                        self._emit(target, dict(message))
            elif kind == "finish_match":
                room = self._room(player, started=True)
                if player.team != room.host_team:
                    raise ProtocolError("forbidden", "Only the host may finish a match")
                final_tick = message.get("tick")
                if final_tick is not None:
                    if final_tick < room.tick or final_tick > room.tick + 360:
                        raise ProtocolError("invalid_sequence", "Finish tick is out of bounds")
                    room.tick = final_tick
                self._end(room, message["winner"], "completed", final_tick=final_tick)

    async def handle_binary(self, player: Player, message: dict[str, Any], raw_bytes: bytes) -> None:
        async with self.lock:
            if player.id not in self.players:
                return
            room = self._room(player, started=True)
            kind = message["type"]
            if kind in ("clock_probe", "clock_reply"):
                self._emit(room.players[1 - player.team], bytes(raw_bytes))
            elif kind == "sync_init":
                if player.team != room.host_team:
                    raise ProtocolError("forbidden", "Only the host may initialize sync")
                tick = message["tick"]
                if tick < room.tick or tick > room.tick + 360:
                    raise ProtocolError("invalid_sequence", "Sync tick is out of bounds")
                room.tick = max(room.tick, tick)
                self._emit(room.players[1 - room.host_team], bytes(raw_bytes))
            elif kind == "command_batch":
                if message["seq"] <= player.seq:
                    raise ProtocolError("invalid_sequence", "seq must increase during each match")
                if message["source_tick"] > room.tick + 360 or message["execute_tick"] > room.tick + 360:
                    raise ProtocolError("invalid_sequence", "Input is too far ahead of the match")
                player.seq = message["seq"] + len(message["commands"]) - 1
                patched = bytearray(raw_bytes)
                patched[1] = player.team
                self._emit(room.players[room.host_team], bytes(patched))
            elif kind == "schedule":
                if player.team != room.host_team:
                    raise ProtocolError("forbidden", "Only the host may schedule inputs")
                for entry in message["commands"]:
                    if entry["seq"] == 0 and (entry["command"]["op"] != "match_end" or entry["team"] != room.host_team):
                        raise ProtocolError("invalid_payload", "Sequence 0 is reserved for host match_end")
                sched_id = message["id"]
                tick = message["tick"]
                digest = hashlib.sha256(raw_bytes).digest()
                if sched_id in room.schedule_hashes:
                    if room.schedule_hashes[sched_id] != digest:
                        raise ProtocolError("invalid_sequence", "Scheduled inputs and deadlines are immutable")
                elif sched_id != room.last_schedule_id + 1:
                    raise ProtocolError("invalid_sequence", "Schedule IDs must be consecutive")
                elif tick < room.tick + FRAME_TICKS or tick > room.tick + 360:
                    raise ProtocolError("invalid_sequence", "Scheduled tick is out of bounds")
                else:
                    room.last_schedule_id = sched_id
                    room.schedule_hashes[sched_id] = digest
                    if len(room.schedule_hashes) > 64:
                        room.schedule_hashes.pop(min(room.schedule_hashes), None)
                self._emit(room.players[1 - room.host_team], bytes(raw_bytes))
            elif kind == "schedule_ack":
                if player.team == room.host_team:
                    raise ProtocolError("forbidden", "Only the guest acknowledges schedules")
                if message["id"] > room.last_schedule_id:
                    raise ProtocolError("invalid_sequence", "Cannot acknowledge an unscheduled ID")
                if not message["accepted"]:
                    room.tick = max(room.tick, message["guest_tick"])
                self._emit(room.players[room.host_team], bytes(raw_bytes))
            elif kind == "heartbeat":
                if player.team != room.host_team:
                    raise ProtocolError("forbidden", "Only the host may send heartbeats")
                tick = message["tick"]
                if tick < room.tick:
                    raise ProtocolError("invalid_sequence", "Heartbeat tick cannot go backward")
                room.tick = tick
                self._emit(room.players[1 - room.host_team], bytes(raw_bytes))
            elif kind == "heartbeat_ack":
                if player.team == room.host_team:
                    raise ProtocolError("forbidden", "Only the guest may acknowledge heartbeats")
                ack_tick = message["ack_tick"]
                if ack_tick < player.ack_tick or ack_tick > room.tick:
                    raise ProtocolError("invalid_sequence", "Acknowledgement is outside the replicated timeline")
                player.ack_tick = ack_tick
                self._emit(room.players[room.host_team], bytes(raw_bytes))

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
                for request_id, (player_ids, requested_at) in list(room.keyframe_requests.items()):
                    if now - requested_at >= self.settings.keyframe_timeout:
                        room.keyframe_requests.pop(request_id, None)
                        for player_id in list(player_ids):
                            target = self.players.get(player_id)
                            if target is not None and target.pending_keyframe == request_id:
                                target.pending_keyframe = None
                                self._emit(target, {"type": "error", "code": "keyframe_timeout", "message": "Host did not answer the keyframe request"})
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
            return {"status": "ok", "protocol_version": PROTOCOL_VERSION, "connections": len(self.players),
                    "queued": len(self.queue), "matches": len(self.rooms)}
