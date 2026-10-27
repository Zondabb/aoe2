from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager, suppress
import json
import logging
from pathlib import Path
from typing import Literal

import anyio
from fastapi import FastAPI, Query, Response, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from .leaderboard import Leaderboard
from .matchmaking import Close, Matchmaker, Player
from .protocol import ProtocolError, parse_message
from .settings import Settings

logger = logging.getLogger(__name__)


async def _receive(websocket: WebSocket, player: Player, matchmaker: Matchmaker) -> None:
    while True:
        packet = await websocket.receive()
        if packet["type"] == "websocket.disconnect":
            if packet.get("code") not in (None, 1000, 1001):
                logger.warning("multiplayer_transport_closed player=%s room=%s websocket_code=%s",
                               player.id, player.room_id, packet.get("code"))
            return
        raw = packet.get("text")
        if raw is None:
            await matchmaker.error(player, ProtocolError("invalid_payload", "Only JSON text frames are supported", 1003))
            # Let the writer deliver the terminal error and close frame.
            await asyncio.Future()
        byte_count = len(raw.encode("utf-8"))
        if not await matchmaker.admit_message(player, byte_count):
            await asyncio.Future()
        try:
            message = parse_message(raw, matchmaker.settings)
            await matchmaker.handle(player, message)
        except ProtocolError as error:
            await matchmaker.error(player, error)
            if error.close_code is not None:
                await asyncio.Future()


async def _send(websocket: WebSocket, player: Player, settings: Settings) -> None:
    while True:
        outgoing = await player.outbox.get()
        if isinstance(outgoing, Close):
            if outgoing.error:
                await asyncio.wait_for(websocket.send_json({"type": "error", "code": outgoing.error,
                                                           "message": outgoing.error.replace("_", " ")}),
                                       timeout=settings.send_timeout)
            await asyncio.wait_for(websocket.close(code=outgoing.code), timeout=settings.send_timeout)
            return
        # ASCII escaping also safely transports names to all Godot JSON parsers.
        raw = json.dumps(outgoing, ensure_ascii=True, separators=(",", ":"), allow_nan=False)
        await asyncio.wait_for(websocket.send_text(raw), timeout=settings.send_timeout)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    leaderboard = Leaderboard(settings.leaderboard_db)
    matchmaker = Matchmaker(settings, leaderboard=leaderboard)

    async def sweeper() -> None:
        while True:
            await asyncio.sleep(settings.sweep_interval)
            await matchmaker.sweep()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        task = asyncio.create_task(sweeper())
        try:
            yield
        finally:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
            await matchmaker.shutdown()
            leaderboard.close()

    app = FastAPI(title="AoE2 Multiplayer Service", version="1.0.0", lifespan=lifespan)
    app.state.matchmaker = matchmaker
    app.state.leaderboard = leaderboard
    static = Path(__file__).resolve().parent / "static"
    app.mount("/static", StaticFiles(directory=static), name="static")

    @app.get("/", include_in_schema=False)
    @app.get("/leaderboard", include_in_schema=False)
    def leaderboard_page() -> FileResponse:
        return FileResponse(static / "index.html", headers={
            "Cache-Control": "no-cache", "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; "
                                       "connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
        })

    @app.get("/api/leaderboard")
    def standings(response: Response, sort: Literal["win_rate", "wins", "games"] = "win_rate",
                  q: str = Query("", max_length=64), limit: int = Query(20, ge=1, le=100),
                  offset: int = Query(0, ge=0)) -> dict:
        response.headers["Cache-Control"] = "no-store"
        return leaderboard.standings(sort=sort, query=q, limit=limit, offset=offset)

    @app.get("/healthz")
    async def healthz() -> dict:
        return await matchmaker.status()

    @app.get("/api/matches")
    async def active_matches(response: Response) -> dict:
        response.headers["Cache-Control"] = "no-store"
        return await matchmaker.list_matches()

    @app.websocket("/ws")
    async def websocket_endpoint(websocket: WebSocket) -> None:
        await websocket.accept()
        player = await matchmaker.register()
        if player is None:
            with suppress(WebSocketDisconnect, RuntimeError, asyncio.TimeoutError, OSError):
                await asyncio.wait_for(websocket.send_json({"type": "error", "code": "server_full",
                                                           "message": "Server connection limit reached"}), settings.send_timeout)
                await asyncio.wait_for(websocket.close(code=1013), settings.send_timeout)
            return
        tasks = [asyncio.create_task(_receive(websocket, player, matchmaker)),
                 asyncio.create_task(_send(websocket, player, settings))]
        disconnect_reason = "connection_closed"
        try:
            completed, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in completed:
                task.result()
        except asyncio.TimeoutError:
            disconnect_reason = "send_timeout"
        except (WebSocketDisconnect, RuntimeError, OSError, asyncio.CancelledError):
            pass
        finally:
            # ASGI cancellation must not interrupt forfeit settlement or leave
            # relay tasks alive after their socket has closed.
            with anyio.CancelScope(shield=True):
                await matchmaker.disconnect(player, error=disconnect_reason)
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
                with suppress(WebSocketDisconnect, RuntimeError, asyncio.TimeoutError, OSError):
                    await asyncio.wait_for(websocket.close(), settings.send_timeout)

    return app


app = create_app()


if __name__ == "__main__":
    import os
    import uvicorn

    uvicorn.run(app, host=os.getenv("AOE2_MP_HOST", "127.0.0.1"),
                port=int(os.getenv("AOE2_MP_PORT", "8001")),
                ws_max_size=Settings.from_env().max_message_bytes, ws_max_queue=8)
