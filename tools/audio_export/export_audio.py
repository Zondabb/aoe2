#!/usr/bin/env python3
"""Copy audited AoE2 HD WAV resources and write the runtime sound manifest.

Only Python's standard library is required. Source game files are never modified.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
from pathlib import Path
import sys
import wave

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOG = Path(__file__).with_name("catalog.json")
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.slp_export.drs import extract


def inspect_wav(data: bytes) -> dict:
    """Validate the format Godot imports, including truncated PCM data."""
    with wave.open(io.BytesIO(data), "rb") as audio:
        if audio.getcomptype() != "NONE" or audio.getsampwidth() not in (1, 2):
            raise ValueError("Expected uncompressed 8/16-bit PCM WAV")
        channels = audio.getnchannels()
        rate = audio.getframerate()
        frames = audio.getnframes()
        if channels not in (1, 2) or rate <= 0 or frames <= 0:
            raise ValueError("Expected nonempty mono/stereo PCM WAV")
        pcm = audio.readframes(frames)
        if len(pcm) != frames * channels * audio.getsampwidth():
            raise ValueError("Truncated PCM WAV data")
        return {
            "channels": channels,
            "sample_rate": rate,
            "bits_per_sample": audio.getsampwidth() * 8,
            "duration_seconds": round(frames / rate, 6),
        }


def resolve_events(specs: dict, source_paths: dict[str, str]) -> dict:
    """Expand aliases so runtime code only needs to read a files array."""
    resolved: dict = {}
    visiting: set[str] = set()

    def resolve(key: str) -> dict:
        if key in resolved:
            return resolved[key]
        if key in visiting:
            raise ValueError(f"Audio alias cycle at {key}")
        if key not in specs:
            raise ValueError(f"Unknown audio event alias: {key}")
        visiting.add(key)
        spec = specs[key]
        event = dict(resolve(spec["alias"])) if "alias" in spec else {}
        event.update({k: v for k, v in spec.items() if k not in ("sources", "alias")})
        if "sources" in spec:
            event["files"] = [source_paths[s] for s in spec["sources"]]
        if not event.get("files"):
            raise ValueError(f"Audio event has no files: {key}")
        resolved[key] = event
        visiting.remove(key)
        return event

    for key in specs:
        resolve(key)
    return resolved


def export_audio(resources: Path, output: Path, catalog_path: Path = DEFAULT_CATALOG) -> dict:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    audio_dir = output / "original"
    streams: dict = {}
    source_paths: dict[str, str] = {}
    source_data: dict[str, bytes] = {}
    # Validate everything before writing any output. A wrong installation cannot
    # silently replace just part of the checked sound set.
    for key, source in catalog["sources"].items():
        archive = resources / "_common" / "drs" / source["archive"]
        if not archive.is_dir():
            archive = archive.with_suffix(".drs")
        raw = extract(archive, source["resource_id"], ext="wav")
        digest = hashlib.sha256(raw).hexdigest()
        if digest != source["sha256"]:
            raise ValueError(f"Source differs from audited HD resource: {key}")
        info = inspect_wav(raw)
        filename = f"{source['archive']}_{source['resource_id']}.wav"
        resource_path = f"res://assets/audio/original/{filename}"
        source_paths[key] = resource_path
        streams[resource_path] = {**source, **info}
        source_data[filename] = raw
    events = resolve_events(catalog["events"], source_paths)
    manifest = {
        "version": 1,
        "source_edition": catalog["source_edition"],
        "events": events,
        "voice_profiles": catalog.get("voice_profiles", {}),
        "streams": streams,
    }
    audio_dir.mkdir(parents=True, exist_ok=True)
    for filename, raw in source_data.items():
        (audio_dir / filename).write_bytes(raw)
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True, help="Local AoE2 HD resources folder")
    parser.add_argument("--output", type=Path, default=ROOT / "assets" / "audio")
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    args = parser.parse_args()
    manifest = export_audio(args.resources, args.output, args.catalog)
    print(f"Exported {len(manifest['streams'])} WAVs for {len(manifest['events'])} events to {args.output}")


if __name__ == "__main__":
    main()
