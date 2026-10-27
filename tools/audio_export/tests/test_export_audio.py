from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.audio_export.export_audio import export_audio, inspect_wav, resolve_events


def pcm_fixture() -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(22050)
        wav.writeframes(b"\x01\x00\xff\xff" * 100)
    return output.getvalue()


class ExportAudioTests(unittest.TestCase):
    def make_source(self, directory: Path) -> tuple[Path, Path, bytes]:
        resources = directory / "resources"
        archive = resources / "_common" / "drs" / "sounds"
        archive.mkdir(parents=True)
        raw = pcm_fixture()
        (archive / "1.wav").write_bytes(raw)
        catalog = {
            "source_edition": "fixture",
            "sources": {"first": {"archive": "sounds", "resource_id": 1,
                                   "sha256": hashlib.sha256(raw).hexdigest()}},
            "events": {
                "ready": {"sources": ["first"], "volume_db": -5, "cooldown": .3, "category": "ui"},
                "complete": {"alias": "ready"},
            },
        }
        path = directory / "catalog.json"
        path.write_text(json.dumps(catalog), encoding="utf-8")
        return resources, path, raw

    def test_export_preserves_wav_and_expands_shared_events(self):
        with tempfile.TemporaryDirectory(prefix=".audio_test_", suffix=".tmp", dir=ROOT) as temp:
            folder = Path(temp)
            resources, catalog, original = self.make_source(folder)
            output = folder / "export"
            result = export_audio(resources, output, catalog)
            self.assertEqual((output / "original/sounds_1.wav").read_bytes(), original)
            self.assertEqual(len(result["streams"]), 1)
            self.assertEqual(result["events"]["ready"], result["events"]["complete"])
            self.assertEqual(json.loads((output / "manifest.json").read_text()), result)
            # Re-exporting creates byte-for-byte identical manifest output.
            before = (output / "manifest.json").read_bytes()
            export_audio(resources, output, catalog)
            self.assertEqual((output / "manifest.json").read_bytes(), before)

    def test_changed_source_leaves_existing_export_untouched(self):
        with tempfile.TemporaryDirectory(prefix=".audio_test_", suffix=".tmp", dir=ROOT) as temp:
            folder = Path(temp)
            resources, catalog, original = self.make_source(folder)
            output = folder / "export"
            export_audio(resources, output, catalog)
            manifest = (output / "manifest.json").read_bytes()
            (resources / "_common/drs/sounds/1.wav").write_bytes(original + b"changed")
            with self.assertRaisesRegex(ValueError, "differs from audited"):
                export_audio(resources, output, catalog)
            self.assertEqual((output / "manifest.json").read_bytes(), manifest)
            self.assertEqual((output / "original/sounds_1.wav").read_bytes(), original)

    def test_alias_errors_are_explicit(self):
        for events, message in [({"a": {"alias": "b"}, "b": {"alias": "a"}}, "cycle"),
                                ({"a": {"alias": "missing"}}, "Unknown")]:
            with self.subTest(events=events), self.assertRaisesRegex(ValueError, message):
                resolve_events(events, {})

    def test_rejects_truncated_pcm(self):
        with self.assertRaisesRegex(ValueError, "Truncated"):
            inspect_wav(pcm_fixture()[:-20])

    def test_audited_assets_match_source_checksums_and_pcm_metadata(self):
        manifest = json.loads((ROOT / "assets/audio/manifest.json").read_text(encoding="utf-8"))
        catalog = json.loads((ROOT / "tools/audio_export/catalog.json").read_text(encoding="utf-8"))
        self.assertEqual(len(catalog["sources"]), len(manifest["streams"]))
        for path, source in manifest["streams"].items():
            with self.subTest(path=path):
                raw = (ROOT / path.removeprefix("res://")).read_bytes()
                self.assertEqual(hashlib.sha256(raw).hexdigest(), source["sha256"])
                for key, value in inspect_wav(raw).items():
                    self.assertEqual(source[key], value)
        for key, event in manifest["events"].items():
            with self.subTest(event=key):
                self.assertTrue(event["files"])
                for path in event["files"]:
                    self.assertIn(path, manifest["streams"])

    def test_specialized_voice_profiles_cover_both_civilizations_and_commands(self):
        manifest = json.loads((ROOT / "assets/audio/manifest.json").read_text(encoding="utf-8"))
        units = json.loads((ROOT / "data/civilization_catalog.json").read_text(encoding="utf-8"))["units"]
        for definition_id, role in manifest["voice_profiles"].items():
            self.assertIn(definition_id, units)
            for civilization in ("chinese", "teutons"):
                for action in ("select", "move", "attack", "stop"):
                    key = f"voice_{role}_{action}_{civilization}"
                    with self.subTest(profile=definition_id, event=key):
                        self.assertIn(key, manifest["events"])
                        self.assertEqual(manifest["events"][key]["category"], "voice")


if __name__ == "__main__":
    unittest.main()
