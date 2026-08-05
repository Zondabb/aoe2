"""Decode AoE2 HD SLP 2.0N frames into Pillow images."""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

from PIL import Image

from palette import Color

_HEADER = struct.Struct("<4si24s")
_FRAME = struct.Struct("<IIIIiiii")
_EDGE = struct.Struct("<HH")

TRANSPARENT_ROW = 0x8000


@dataclass
class FrameMeta:
    width: int
    height: int
    hotspot_x: int
    hotspot_y: int


def _read_length4(cmd: int, data: bytes, pos: int) -> Tuple[int, int]:
    length = cmd >> 4
    if length == 0:
        length = data[pos]
        pos += 1
    return length, pos


def _player_index(base: int, player: int) -> int:
    # AoK/HD: player 1..8 colors start at palette 16, 32, ...
    player = max(1, min(8, player))
    return (player * 16) + (base & 0x0F)


def _decode_frame(
    data: bytes,
    frame_off: int,
    palette: Sequence[Color],
    *,
    player: int = 1,
) -> Tuple[Image.Image, FrameMeta]:
    (
        cmd_table_offset,
        outline_table_offset,
        _palette_offset,
        _properties,
        width,
        height,
        hotspot_x,
        hotspot_y,
    ) = _FRAME.unpack_from(data, frame_off)

    if width <= 0 or height <= 0:
        img = Image.new("RGBA", (1, 1), (0, 0, 0, 0))
        return img, FrameMeta(1, 1, 0, 0)

    pixels = bytearray(width * height * 4)

    def put_pixel(x: int, y: int, index: int) -> None:
        if not (0 <= x < width and 0 <= y < height):
            return
        if index < 0 or index >= len(palette):
            return
        r, g, b, a = palette[index]
        o = (y * width + x) * 4
        pixels[o : o + 4] = bytes((r, g, b, a))

    def put_shadow(x: int, y: int) -> None:
        if not (0 <= x < width and 0 <= y < height):
            return
        o = (y * width + x) * 4
        # Checkerboard-ish soft shadow for export visibility.
        if (x + y) & 1:
            pixels[o : o + 4] = bytes((0, 0, 0, 96))

    for row in range(height):
        left, right = _EDGE.unpack_from(data, outline_table_offset + row * 4)
        if left == TRANSPARENT_ROW or right == TRANSPARENT_ROW:
            continue

        cmd_off = struct.unpack_from("<I", data, cmd_table_offset + row * 4)[0]
        x = left
        pos = cmd_off

        while True:
            cmd = data[pos]
            pos += 1
            low = cmd & 0x0F

            if low == 0x0F:
                break

            if (cmd & 0x03) == 0x00:  # lesser draw
                length = cmd >> 2
                for _ in range(length):
                    put_pixel(x, row, data[pos])
                    pos += 1
                    x += 1
                continue

            if (cmd & 0x03) == 0x01:  # lesser skip
                length = cmd >> 2
                if length == 0:
                    length = data[pos]
                    pos += 1
                x += length
                continue

            if low == 0x02:  # greater draw
                length = ((cmd & 0xF0) << 4) + data[pos]
                pos += 1
                for _ in range(length):
                    put_pixel(x, row, data[pos])
                    pos += 1
                    x += 1
                continue

            if low == 0x03:  # greater skip
                length = ((cmd & 0xF0) << 4) + data[pos]
                pos += 1
                x += length
                continue

            if low == 0x06:  # player color draw
                length, pos = _read_length4(cmd, data, pos)
                for _ in range(length):
                    put_pixel(x, row, _player_index(data[pos], player))
                    pos += 1
                    x += 1
                continue

            if low == 0x07:  # fill
                length, pos = _read_length4(cmd, data, pos)
                color = data[pos]
                pos += 1
                for _ in range(length):
                    put_pixel(x, row, color)
                    x += 1
                continue

            if low == 0x0A:  # fill player color
                length, pos = _read_length4(cmd, data, pos)
                color = _player_index(data[pos], player)
                pos += 1
                for _ in range(length):
                    put_pixel(x, row, color)
                    x += 1
                continue

            if low == 0x0B:  # shadow
                length, pos = _read_length4(cmd, data, pos)
                for _ in range(length):
                    put_shadow(x, row)
                    x += 1
                continue

            if low == 0x0E:  # extended
                ext = cmd
                if ext in (0x0E, 0x1E):
                    # hint for next command (flip); ignore and continue
                    continue
                if ext in (0x2E, 0x3E):
                    continue
                if ext in (0x4E, 0x6E):
                    # Outline-only pixels (behind-tree hint); skip for normal export.
                    x += 1
                    continue
                if ext in (0x5E, 0x7E):
                    length = data[pos]
                    pos += 1
                    x += length
                    continue
                # unused / unknown extended — skip
                continue

            raise ValueError(f"unknown SLP command 0x{cmd:02x} at row {row}")

    img = Image.frombytes("RGBA", (width, height), bytes(pixels))
    return img, FrameMeta(width, height, hotspot_x, hotspot_y)


def decode(
    data: bytes,
    palette: Sequence[Color],
    *,
    player: int = 1,
    max_frames: Optional[int] = None,
) -> List[Image.Image]:
    """Decode SLP bytes into a list of RGBA frames."""
    if len(data) < _HEADER.size:
        raise ValueError("SLP too small")
    version, num_frames, _comment = _HEADER.unpack_from(data, 0)
    if version not in (b"2.0N", b"3.0\x00", b"3.0 "):
        # Accept common 2.0N; refuse unknown major formats.
        if version != b"2.0N":
            raise ValueError(f"unsupported SLP version {version!r}")
    if num_frames <= 0:
        return []

    limit = num_frames if max_frames is None else min(num_frames, max_frames)
    frames: List[Image.Image] = []
    for i in range(limit):
        frame_off = _HEADER.size + i * _FRAME.size
        img, _meta = _decode_frame(data, frame_off, palette, player=player)
        frames.append(img)
    return frames


def decode_with_meta(
    data: bytes,
    palette: Sequence[Color],
    *,
    player: int = 1,
    max_frames: Optional[int] = None,
) -> Tuple[List[Image.Image], List[FrameMeta]]:
    version, num_frames, _comment = _HEADER.unpack_from(data, 0)
    if version != b"2.0N":
        raise ValueError(f"unsupported SLP version {version!r}")
    limit = num_frames if max_frames is None else min(num_frames, max_frames)
    images: List[Image.Image] = []
    metas: List[FrameMeta] = []
    for i in range(limit):
        frame_off = _HEADER.size + i * _FRAME.size
        img, meta = _decode_frame(data, frame_off, palette, player=player)
        images.append(img)
        metas.append(meta)
    return images, metas
