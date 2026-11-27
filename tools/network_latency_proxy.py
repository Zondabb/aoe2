"""Ordered TCP delay proxy used by the real multiplayer regression runners.

This delays bytes in both directions without decoding or modifying WebSocket
messages. Deadlines are based on arrival time, so a burst of commands does not
incur one extra round trip per message. Jitter cannot reorder TCP bytes.
"""
from __future__ import annotations

import argparse
import asyncio
import random
from contextlib import suppress


async def _pipe(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    delay: float,
    jitter: float,
    rng: random.Random,
) -> None:
    queue: asyncio.Queue[tuple[float, bytes] | None] = asyncio.Queue(maxsize=128)

    async def receive() -> None:
        last_deadline = 0.0
        loop = asyncio.get_running_loop()
        try:
            while chunk := await reader.read(65536):
                # Preserve the stream even when later bytes get less jitter.
                last_deadline = max(last_deadline, loop.time() + delay + rng.uniform(0, jitter))
                await queue.put((last_deadline, chunk))
        finally:
            if not asyncio.current_task().cancelling():
                await queue.put(None)

    task = asyncio.create_task(receive())
    try:
        while item := await queue.get():
            deadline, chunk = item
            wait = deadline - asyncio.get_running_loop().time()
            if wait > 0:
                await asyncio.sleep(wait)
            writer.write(chunk)
            await writer.drain()
        await task
    finally:
        task.cancel()
        with suppress(asyncio.CancelledError, ConnectionError, OSError):
            await task


async def serve(args: argparse.Namespace) -> None:
    connection = 0

    async def connected(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        nonlocal connection
        connection += 1
        upstream_writer: asyncio.StreamWriter | None = None
        tasks: list[asyncio.Task[None]] = []
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection(args.host, args.upstream_port)
            seed = args.seed + connection * 2
            tasks = [
                asyncio.create_task(_pipe(reader, upstream_writer, args.delay_ms / 1000,
                                          args.jitter_ms / 1000, random.Random(seed))),
                asyncio.create_task(_pipe(upstream_reader, writer, args.delay_ms / 1000,
                                          args.jitter_ms / 1000, random.Random(seed + 1))),
            ]
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                await task
        except (ConnectionError, OSError):
            pass
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            for stream in (writer, upstream_writer):
                if stream is not None:
                    stream.close()
                    with suppress(ConnectionError, OSError):
                        await stream.wait_closed()

    server = await asyncio.start_server(connected, args.host, args.listen_port)
    print(f"LATENCY PROXY READY {args.listen_port}: each direction {args.delay_ms} ms + "
          f"0..{args.jitter_ms} ms jitter", flush=True)
    async with server:
        await server.serve_forever()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-port", type=int, required=True)
    parser.add_argument("--delay-ms", type=float, default=25)
    parser.add_argument("--jitter-ms", type=float, default=10)
    parser.add_argument("--seed", type=int, default=17)
    args = parser.parse_args()
    if args.delay_ms < 0 or args.jitter_ms < 0:
        parser.error("delay and jitter must be nonnegative")
    asyncio.run(serve(args))


if __name__ == "__main__":
    main()
