"""Palette loader tests (requires AOE2_RES or default HD resources path)."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from palette import load_pal  # noqa: E402

DEFAULT_RES = Path(r"D:/BaiduNetdiskDownload/gaoqingban2/gaoqingban2/resources")


def _resources() -> Path:
    env = os.environ.get("AOE2_RES")
    return Path(env) if env else DEFAULT_RES


@pytest.fixture(scope="module")
def resources() -> Path:
    path = _resources()
    if not path.is_dir():
        pytest.skip(f"AoE2 resources not found: {path}")
    return path


def test_pal_len(resources: Path) -> None:
    pal = load_pal(resources / "_common/dat/pal_2.pal")
    assert len(pal) == 256


def test_clf_pal_len(resources: Path) -> None:
    pal = load_pal(resources / "_common/dat/clf_pal.pal")
    assert len(pal) == 256


def test_interface_palette_transparent_zero(resources: Path) -> None:
    pal = load_pal(resources / "_common/drs/interface/50500.bina")
    assert len(pal) == 256
    assert pal[0][3] == 0
    assert pal[1][3] == 255
