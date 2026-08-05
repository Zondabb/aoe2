"""Extract files from classic `.drs` archives or HD unpacked DRS folders."""

from __future__ import annotations

import struct
from pathlib import Path
from typing import Dict, Iterable, Optional, Tuple, Union

_DRS_HEADER = struct.Struct("<40s4s12sii")
_DRS_TABLE = struct.Struct("<4sii")
_DRS_FILE = struct.Struct("<iii")


def _normalize_ext(ext: bytes) -> str:
    # On disk table extensions are reversed + space-padded (e.g. b' pls' -> 'slp').
    raw = ext.decode("latin1")
    return raw.replace("\x00", "").strip()[::-1].strip().lower()


def _parse_drs(path: Path) -> Dict[Tuple[str, int], Tuple[int, int]]:
    data = path.read_bytes()
    copyright_, version, ftype, table_count, _file_offset = _DRS_HEADER.unpack_from(data, 0)
    del copyright_, version, ftype
    offset = _DRS_HEADER.size
    index: Dict[Tuple[str, int], Tuple[int, int]] = {}
    for _ in range(table_count):
        ext_raw, info_off, num_files = _DRS_TABLE.unpack_from(data, offset)
        offset += _DRS_TABLE.size
        ext = _normalize_ext(ext_raw)
        for i in range(num_files):
            file_id, data_off, size = _DRS_FILE.unpack_from(data, info_off + i * _DRS_FILE.size)
            index[(ext, file_id)] = (data_off, size)
    return index


def extract(
    drs_path: Union[str, Path],
    file_id: Optional[Union[int, str]] = None,
    *,
    name: Optional[str] = None,
    ext: str = "slp",
) -> bytes:
    """Return file bytes from a DRS archive or HD unpacked directory.

    Parameters
    ----------
    drs_path:
        Path to a ``.drs`` file, or an unpacked folder (e.g. ``.../drs/graphics``)
        containing ``{id}.slp`` / ``{id}.bina`` files.
    file_id:
        Numeric resource id (preferred).
    name:
        Alternate filename stem or ``\"123.slp\"`` style name.
    ext:
        Extension when looking up by id (default ``slp``).
    """
    path = Path(drs_path)
    if file_id is None and name is None:
        raise ValueError("file_id or name is required")

    target_id: Optional[int] = None
    target_ext = ext.lower().lstrip(".")
    if file_id is not None:
        if isinstance(file_id, str):
            stem = Path(file_id).stem
            if "." in file_id:
                target_ext = Path(file_id).suffix.lstrip(".").lower() or target_ext
            target_id = int(stem)
        else:
            target_id = int(file_id)
    elif name is not None:
        p = Path(name)
        target_ext = (p.suffix.lstrip(".") or target_ext).lower()
        target_id = int(p.stem)

    assert target_id is not None

    if path.is_dir():
        candidates = [
            path / f"{target_id}.{target_ext}",
            path / f"{target_id}.{target_ext.upper()}",
        ]
        for candidate in candidates:
            if candidate.is_file():
                return candidate.read_bytes()
        raise FileNotFoundError(f"{target_id}.{target_ext} not found under {path}")

    if not path.is_file():
        raise FileNotFoundError(path)

    # Classic packed DRS
    index = _parse_drs(path)
    key = (target_ext, target_id)
    if key not in index:
        # try any extension match on id
        matches = [k for k in index if k[1] == target_id]
        if not matches:
            raise KeyError(f"id {target_id} not in {path}")
        key = matches[0]
    data_off, size = index[key]
    return path.read_bytes()[data_off : data_off + size]


def list_ids(drs_path: Union[str, Path], ext: str = "slp") -> Iterable[int]:
    """Yield resource ids available in an archive or unpacked folder."""
    path = Path(drs_path)
    target_ext = ext.lower().lstrip(".")
    if path.is_dir():
        for child in sorted(path.iterdir()):
            if child.is_file() and child.suffix.lower().lstrip(".") == target_ext:
                try:
                    yield int(child.stem)
                except ValueError:
                    continue
        return
    index = _parse_drs(path)
    for (e, file_id) in sorted(index, key=lambda k: k[1]):
        if e == target_ext:
            yield file_id
