"""Load AoE2 JASC-PAL / interface bina palettes."""

from __future__ import annotations

from pathlib import Path
from typing import List, Tuple

Color = Tuple[int, int, int, int]


def load_pal(path: str | Path, *, transparent_index: int = 0) -> List[Color]:
    """Load a 256-entry palette as (r, g, b, a) tuples.

    Supports JASC-PAL text (``pal_*.pal``, ``clf_pal.pal``, interface ``50500.bina``).
    Index ``transparent_index`` is forced to alpha 0; others use alpha 255.
    """
    text = Path(path).read_text(encoding="ascii", errors="replace")
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if len(lines) < 3 or not lines[0].upper().startswith("JASC-PAL"):
        raise ValueError(f"not a JASC-PAL file: {path}")

    count = int(lines[2])
    colors: List[Color] = []
    for i in range(count):
        parts = lines[3 + i].split()
        if len(parts) < 3:
            raise ValueError(f"bad palette line {3 + i} in {path}")
        r, g, b = (int(parts[0]), int(parts[1]), int(parts[2]))
        a = 0 if i == transparent_index else 255
        colors.append((r, g, b, a))

    if len(colors) != count:
        raise ValueError(f"expected {count} colors, got {len(colors)} in {path}")
    return colors
