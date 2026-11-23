"""Content addressed cabinet source releases. Never executes proposal code.

Compilation is an early error check, not a security boundary. Importing or
running a release belongs to the separately constrained worker environment.
"""
from __future__ import annotations

import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import time


DEPARTMENTS = ("economy", "intel", "general", "defense", "tech")
WRITABLE = frozenset(f"brain/cabinet/departments/{name}.py" for name in DEPARTMENTS)
MAX_DIFF_BYTES = 256 * 1024
MAX_SOURCE_BYTES = 2 * 1024 * 1024
_HUNK = re.compile(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?:.*)\n?$")
_RELEASE = re.compile(r"[0-9a-f]{64}\Z")


class ReleaseError(ValueError):
    """A proposal or stored release failed validation."""


def _json(value) -> bytes:
    try:
        return json.dumps(value, sort_keys=True, ensure_ascii=False, allow_nan=False,
                          separators=(",", ":")).encode("utf-8")
    except (ValueError, TypeError, RecursionError) as exc:
        raise ReleaseError("invalid_json_metadata") from exc


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _linked(path: Path) -> bool:
    return path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction())


def _patch_path(line: str, prefix: str) -> str:
    raw = line[len(prefix):].rstrip("\r\n")
    if raw.startswith(("a/", "b/")):
        raw = raw[2:]
    if raw.startswith("ai_service_python/"):
        raw = raw[len("ai_service_python/"):]
    if raw not in WRITABLE:
        raise ReleaseError("patch_path_not_allowed")
    return raw


def apply_diff(sources: dict[str, str], patch: str) -> dict[str, str]:
    """Apply exact, ordered unified hunks; no fuzz, offsets, renames or creation."""
    if not isinstance(patch, str) or not patch or len(patch.encode("utf-8")) > MAX_DIFF_BYTES or "\x00" in patch:
        raise ReleaseError("invalid_patch_size")
    lines = patch.replace("\r\n", "\n").splitlines(keepends=True)
    output, seen = {}, set()
    cursor = 0
    while cursor < len(lines):
        # git's harmless file preamble; mode/rename/binary metadata is rejected.
        if lines[cursor].startswith("diff --git "):
            cursor += 1
            if cursor < len(lines) and re.fullmatch(r"index [0-9a-f]+\.\.[0-9a-f]+(?: 100644)?\n?", lines[cursor]):
                cursor += 1
        if cursor + 1 >= len(lines) or not lines[cursor].startswith("--- ") or not lines[cursor + 1].startswith("+++ "):
            raise ReleaseError("invalid_patch_header")
        path = _patch_path(lines[cursor], "--- ")
        if path != _patch_path(lines[cursor + 1], "+++ ") or path in seen or path not in sources:
            raise ReleaseError("duplicate_or_renamed_patch")
        seen.add(path)
        cursor += 2
        original = sources[path].replace("\r\n", "\n").splitlines(keepends=True)
        result, consumed, hunks = [], 0, 0
        while cursor < len(lines) and lines[cursor].startswith("@@ "):
            match = _HUNK.fullmatch(lines[cursor])
            if match is None:
                raise ReleaseError("invalid_hunk_header")
            old_start, old_count, new_start, new_count = (int(match[1]), int(match[2] or 1),
                                                        int(match[3]), int(match[4] or 1))
            position = old_start - 1 if old_count else old_start
            if position < consumed or position > len(original):
                raise ReleaseError("overlapping_or_outside_hunk")
            result.extend(original[consumed:position])
            expected_new = new_start - 1 if new_count else new_start
            if expected_new != len(result):
                raise ReleaseError("incorrect_new_hunk_position")
            cursor += 1
            before, after = [], []
            while cursor < len(lines) and (len(before) < old_count or len(after) < new_count):
                row = lines[cursor]
                if not row or row[0] not in " +-":
                    raise ReleaseError("truncated_hunk")
                sign, text = row[0], row[1:]
                cursor += 1
                if cursor < len(lines) and lines[cursor].rstrip("\n") == "\\ No newline at end of file":
                    text = text.removesuffix("\n")
                    cursor += 1
                if sign in " -":
                    before.append(text)
                if sign in " +":
                    after.append(text)
                if len(before) > old_count or len(after) > new_count:
                    raise ReleaseError("incorrect_hunk_counts")
            if len(before) != old_count or len(after) != new_count:
                raise ReleaseError("truncated_hunk")
            if original[position:position + old_count] != before:
                raise ReleaseError("patch_context_mismatch")
            result.extend(after)
            consumed = position + old_count
            hunks += 1
        if not hunks:
            raise ReleaseError("patch_has_no_hunks")
        result.extend(original[consumed:])
        changed = "".join(result)
        if changed == sources[path].replace("\r\n", "\n"):
            raise ReleaseError("patch_has_no_changes")
        if len(changed.encode("utf-8")) > MAX_SOURCE_BYTES:
            raise ReleaseError("source_too_large")
        try:
            compile(changed, path, "exec", dont_inherit=True)
        except (SyntaxError, ValueError, RecursionError) as exc:
            raise ReleaseError("invalid_python_source") from exc
        output[path] = changed
    return output


def _state_fields(fields: object) -> list:
    if not isinstance(fields, list) or len(fields) > 128:
        raise ReleaseError("invalid_state_fields")
    seen = set()
    types = {"bool": bool, "int": int, "float": (int, float), "str": str, "list": list, "dict": dict,
             "boolean": bool, "integer": int, "number": (int, float), "string": str, "array": list, "object": dict}
    for field in fields:
        if not isinstance(field, dict) or not {"department", "name", "type", "default"} <= field.keys():
            raise ReleaseError("invalid_state_field")
        name, dept, kind = field["name"], field["department"], field["type"]
        if not isinstance(name, str) or not re.fullmatch(r"[a-zA-Z][a-zA-Z0-9_]{0,79}", name) or dept not in DEPARTMENTS:
            raise ReleaseError("invalid_state_field_name")
        if not isinstance(kind, str) or kind not in types or not isinstance(field["default"], types[kind]):
            raise ReleaseError("invalid_state_default")
        if kind in ("int", "integer", "float", "number") and isinstance(field["default"], bool):
            raise ReleaseError("invalid_state_default")
        if (dept, name) in seen:
            raise ReleaseError("duplicate_state_field")
        seen.add((dept, name))
    if len(_json(fields)) > 64 * 1024:
        raise ReleaseError("state_fields_too_large")
    return fields


def _remove_tree(path: Path) -> None:
    if path.exists():
        for candidate in path.rglob("*"):
            if candidate.is_file():
                candidate.chmod(stat.S_IWRITE | stat.S_IREAD)
        shutil.rmtree(path)


class ReleaseStore:
    def __init__(self, root: str | Path, source_root: str | Path | None = None):
        self.root = Path(root).resolve()
        # Content hashes add 64 characters. Support Windows installations whose
        # service/storage path would otherwise exceed the legacy MAX_PATH limit.
        if os.name == "nt" and not str(self.root).startswith("\\\\?\\"):
            value = str(self.root)
            self.root = Path("\\\\?\\UNC\\" + value[2:] if value.startswith("\\\\") else "\\\\?\\" + value)
        self.source_root = Path(source_root).resolve() if source_root else Path(__file__).resolve().parents[2]
        self.releases = self.root / "releases"
        self.staging = self.root / "staging"
        self.releases.mkdir(parents=True, exist_ok=True)
        self.staging.mkdir(parents=True, exist_ok=True)

    def _directory(self, release: str) -> Path:
        if not isinstance(release, str) or not _RELEASE.fullmatch(release):
            raise ReleaseError("invalid_release_id")
        path = self.releases / release
        if _linked(path) or not path.is_dir():
            raise ReleaseError("release_not_found")
        return path

    @staticmethod
    def _files(source: Path) -> dict[str, bytes]:
        files = {}
        for folder, extension in (("brain", ".py"), ("protocol", ".py"), ("data", ".json")):
            tree = source / folder
            if not tree.is_dir() or _linked(tree):
                raise ReleaseError("missing_or_linked_source_tree")
            for directory, dirs, names in os.walk(tree, followlinks=False):
                current = Path(directory)
                for name in dirs + names:
                    if _linked(current / name):
                        raise ReleaseError("linked_source_file")
                dirs[:] = sorted(name for name in dirs if name != "__pycache__" and not name.startswith("."))
                for name in sorted(names):
                    candidate = current / name
                    if candidate.suffix != extension or name.startswith("."):
                        continue
                    if not candidate.is_file() or candidate.stat().st_size > MAX_SOURCE_BYTES:
                        raise ReleaseError("invalid_source_file")
                    files[candidate.relative_to(source).as_posix()] = candidate.read_bytes()
        if not WRITABLE <= files.keys():
            raise ReleaseError("missing_department_source")
        return files

    def _publish(self, files: dict[str, bytes], parent: str | None, proposal: dict | None) -> str:
        dependencies = {}
        for name in ("pydantic", "jsonschema", "requests", "httpx"):
            try:
                dependencies[name] = importlib.metadata.version(name)
            except importlib.metadata.PackageNotFoundError:
                pass
        manifest = {"format": 1, "state_format": 1, "parent": parent, "proposal": proposal,
                    "files": {name: _digest(data) for name, data in sorted(files.items())},
                    "python": list(sys.version_info[:3]), "dependencies": dependencies,
                    "validation": {"syntax": "passed", "behavior": "requires_worker_validation"}}
        encoded = _json(manifest)
        release = _digest(encoded)
        target = self.releases / release
        if target.exists():
            self.manifest(release)
            return release
        stage = Path(tempfile.mkdtemp(prefix="release-", dir=self.staging))
        try:
            source = stage / "ai_service_python"
            for name, data in sorted(files.items()):
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                path.chmod(stat.S_IREAD | stat.S_IRGRP | stat.S_IROTH)
            (stage / "manifest.json").write_bytes(encoded)
            (stage / "manifest.json").chmod(stat.S_IREAD | stat.S_IRGRP | stat.S_IROTH)
            for attempt in range(4):
                try:
                    stage.rename(target)
                    break
                except OSError:
                    if target.exists():
                        self.manifest(release)
                        break
                    if os.name != "nt" or attempt == 3:
                        raise
                    # Windows scanners can briefly retain a handle on a file
                    # just closed. Publication still happens by one rename.
                    time.sleep(0.02 * (attempt + 1))
            return release
        finally:
            _remove_tree(stage)

    def bootstrap(self) -> str:
        files = self._files(self.source_root)
        for name, content in files.items():
            if name.endswith(".py"):
                try:
                    compile(content, name, "exec", dont_inherit=True)
                except (SyntaxError, ValueError) as exc:
                    raise ReleaseError("invalid_builtin_source") from exc
        return self._publish(files, None, None)

    def manifest(self, release: str) -> dict:
        directory = self._directory(release)
        manifest_file = directory / "manifest.json"
        try:
            if _linked(manifest_file) or manifest_file.stat().st_size > 1024 * 1024:
                raise ReleaseError("invalid_manifest")
            manifest = json.loads(manifest_file.read_bytes())
            if not isinstance(manifest, dict) or _digest(_json(manifest)) != release or manifest.get("format") != 1:
                raise ReleaseError("manifest_digest_mismatch")
            source = directory / "ai_service_python"
            if _linked(source):
                raise ReleaseError("linked_release_root")
            actual = self._files(source)
            # Also reject extra files, including stale bytecode/config injected after publication.
            all_files = {p.relative_to(source).as_posix() for p in source.rglob("*") if p.is_file()}
            if all_files != set(actual) or {name: _digest(data) for name, data in actual.items()} != manifest["files"]:
                raise ReleaseError("source_digest_mismatch")
            return manifest
        except (OSError, TypeError, KeyError, json.JSONDecodeError) as exc:
            raise ReleaseError("invalid_manifest") from exc

    def path(self, release: str) -> Path:
        self.manifest(release)
        return self._directory(release) / "ai_service_python"

    def build(self, base_release: str, proposal: dict) -> str:
        if not isinstance(proposal, dict) or proposal.get("base_release") != base_release:
            raise ReleaseError("base_release_mismatch")
        if not isinstance(proposal.get("proposal_id"), str) or not 1 <= len(proposal["proposal_id"]) <= 160:
            raise ReleaseError("invalid_proposal_id")
        fields = _state_fields(proposal.get("state_fields", []))
        explanation = proposal.get("explanation", "")
        if not isinstance(explanation, str) or len(explanation) > 8192:
            raise ReleaseError("invalid_explanation")
        files = self._files(self.path(base_release))
        changes = apply_diff({name: files[name].decode("utf-8") for name in WRITABLE}, proposal.get("unified_diff"))
        for name, content in changes.items():
            files[name] = content.encode("utf-8")
        metadata = {"proposal_id": proposal["proposal_id"], "base_release": base_release,
                    "unified_diff": proposal["unified_diff"], "state_fields": fields,
                    "explanation": explanation, "changed_files": sorted(changes)}
        return self._publish(files, base_release, metadata)

    def context(self, base_release: str) -> dict:
        source = self.path(base_release)
        manifest = self.manifest(base_release)
        related = ("brain/cabinet/runtime.py", "brain/cabinet/departments/base.py", "brain/cabinet/models.py",
                   "brain/cabinet/treasury.py", "brain/cabinet/construction.py")
        return {"base_release": base_release,
                "sources": {name: (source / name).read_text(encoding="utf-8") for name in sorted(WRITABLE)},
                "contracts": {name: (source / name).read_text(encoding="utf-8") for name in related},
                "state_fields": (manifest.get("proposal") or {}).get("state_fields", [])}
