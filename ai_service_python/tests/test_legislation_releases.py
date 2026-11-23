"""Publication checks run without ever importing generated department code."""
from __future__ import annotations

import difflib
import json
from pathlib import Path
import stat

import pytest

from brain.legislation.releases import ReleaseError, ReleaseStore, WRITABLE, apply_diff


ECONOMY = "brain/cabinet/departments/economy.py"


def patch(old, new, path=ECONOMY):
    return "".join(difflib.unified_diff(old.splitlines(keepends=True), new.splitlines(keepends=True),
                    fromfile="a/ai_service_python/" + path, tofile="b/ai_service_python/" + path))


@pytest.fixture
def source(tmp_path):
    root = tmp_path / "source"
    for name in WRITABLE:
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("VALUE = 1\n", encoding="utf-8")
    for name in ("brain/cabinet/runtime.py", "brain/cabinet/departments/base.py", "brain/cabinet/models.py",
                 "brain/cabinet/treasury.py", "brain/cabinet/construction.py", "protocol/__init__.py"):
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("# trusted caller\n", encoding="utf-8")
    (root / "data").mkdir()
    (root / "data/catalog.json").write_text('{"cost": 1}', encoding="utf-8")
    (root / "config.toml").write_text('secret = "never publish"', encoding="utf-8")
    return root


def proposal(base, text=None, **overrides):
    return {"proposal_id": "wood-priority", "base_release": base,
            "unified_diff": text or patch("VALUE = 1\n", "VALUE = 2\n"),
            "state_fields": [], "explanation": "Change economic choice", **overrides}


def test_publish_full_tree_preserves_base_and_never_copies_configuration(tmp_path, source):
    store = ReleaseStore(tmp_path / "store", source)
    base = store.bootstrap()
    result = store.build(base, proposal(base))
    assert result != base
    assert (store.path(base) / ECONOMY).read_text() == "VALUE = 1\n"
    assert (store.path(result) / ECONOMY).read_text() == "VALUE = 2\n"
    assert not (store.path(result) / "config.toml").exists()
    assert store.manifest(result)["parent"] == base
    assert set(store.manifest(result)["files"]) >= WRITABLE
    assert store.manifest(result)["proposal"]["changed_files"] == [ECONOMY]
    assert store.build(base, proposal(base)) == result
    assert not list(store.staging.iterdir())


def test_full_real_source_bootstrap_and_context(tmp_path):
    store = ReleaseStore(tmp_path / "store")
    base = store.bootstrap()
    assert "class CabinetRuntime" in store.context(base)["contracts"]["brain/cabinet/runtime.py"]
    assert "def act(" in store.context(base)["sources"][ECONOMY]
    assert (store.path(base) / "data/ai/profile_default.json").exists()


@pytest.mark.parametrize("bad_path", ["../outside.py", "brain/cabinet/runtime.py", "brain/cabinet/departments/../runtime.py",
                                      "/tmp/economy.py", "brain\\cabinet\\departments\\economy.py",
                                      "brain/cabinet/departments/economy.py\tdate", "/dev/null"])
def test_patch_rejects_paths_outside_five_exact_modules(bad_path):
    with pytest.raises(ReleaseError, match="path_not_allowed"):
        apply_diff({ECONOMY: "VALUE = 1\n"}, patch("VALUE = 1\n", "VALUE = 2\n", bad_path))


def test_context_must_match_exactly_and_base_must_match(tmp_path, source):
    store = ReleaseStore(tmp_path / "store", source)
    base = store.bootstrap()
    with pytest.raises(ReleaseError, match="base_release_mismatch"):
        store.build(base, proposal("f" * 64))
    with pytest.raises(ReleaseError, match="patch_context_mismatch"):
        store.build(base, proposal(base, patch("VALUE = 3\n", "VALUE = 2\n")))
    assert len(list(store.releases.iterdir())) == 1


def test_multi_module_publication_is_atomic_on_invalid_syntax(tmp_path, source):
    store = ReleaseStore(tmp_path / "store", source)
    base = store.bootstrap()
    text = patch("VALUE = 1\n", "VALUE = 2\n") + patch("VALUE = 1\n", "def invalid(\n", "brain/cabinet/departments/general.py")
    with pytest.raises(ReleaseError, match="invalid_python"):
        store.build(base, proposal(base, text))
    assert len(list(store.releases.iterdir())) == 1
    assert (store.path(base) / ECONOMY).read_text() == "VALUE = 1\n"


@pytest.mark.parametrize("kind", ["truncated", "duplicate", "wrong_new_line", "binary", "mode_change"])
def test_malformed_patches_fail_closed(kind):
    text = patch("VALUE = 1\n", "VALUE = 2\n")
    if kind == "truncated":
        text = "\n".join(text.splitlines()[:-1]) + "\n"
    elif kind == "duplicate":
        text += text
    elif kind == "wrong_new_line":
        text = text.replace("+1 @@", "+4 @@")
    elif kind == "binary":
        text = "GIT binary patch\n" + text
    elif kind == "mode_change":
        text = "old mode 100644\nnew mode 100755\n" + text
    with pytest.raises(ReleaseError):
        apply_diff({ECONOMY: "VALUE = 1\n"}, text)


def test_git_preamble_and_multiple_nonoverlapping_hunks():
    old = "".join(f"VALUE_{i} = {i}\n" for i in range(30))
    new = old.replace("VALUE_1 = 1\n", "VALUE_1 = 2\n").replace("VALUE_25 = 25\n", "VALUE_25 = 26\n")
    text = "diff --git a/ai_service_python/" + ECONOMY + " b/ai_service_python/" + ECONOMY + "\nindex abc123..def456 100644\n" + patch(old, new)
    assert apply_diff({ECONOMY: old}, text)[ECONOMY] == new


def test_insertion_at_beginning_and_removal_at_end():
    assert apply_diff({ECONOMY: "VALUE = 1\n"}, patch("VALUE = 1\n", "OTHER = 2\nVALUE = 1\n"))[ECONOMY] == "OTHER = 2\nVALUE = 1\n"
    assert apply_diff({ECONOMY: "VALUE = 1\nOTHER = 2\n"}, patch("VALUE = 1\nOTHER = 2\n", "VALUE = 1\n"))[ECONOMY] == "VALUE = 1\n"


def test_missing_final_newline_marker():
    text = "--- a/" + ECONOMY + "\n+++ b/" + ECONOMY + "\n@@ -1 +1 @@\n-VALUE = 1\n\\ No newline at end of file\n+VALUE = 2\n\\ No newline at end of file\n"
    assert apply_diff({ECONOMY: "VALUE = 1"}, text)[ECONOMY] == "VALUE = 2"


def test_tampered_file_and_extra_bytecode_rejected(tmp_path, source):
    store = ReleaseStore(tmp_path / "store", source)
    base = store.bootstrap()
    root = store.path(base)
    target = root / ECONOMY
    target.chmod(stat.S_IREAD | stat.S_IWRITE)
    target.write_text("VALUE = 9\n", encoding="utf-8")
    with pytest.raises(ReleaseError, match="source_digest_mismatch"):
        store.path(base)
    target.write_text("VALUE = 1\n", encoding="utf-8")
    (root / "extra.pyc").write_bytes(b"stale")
    with pytest.raises(ReleaseError, match="source_digest_mismatch"):
        store.path(base)


def test_manifest_tampering_and_invalid_id_rejected(tmp_path, source):
    store = ReleaseStore(tmp_path / "store", source)
    base = store.bootstrap()
    target = store.releases / base / "manifest.json"
    data = json.loads(target.read_text())
    data["parent"] = "f" * 64
    target.chmod(stat.S_IREAD | stat.S_IWRITE)
    target.write_text(json.dumps(data), encoding="utf-8")
    with pytest.raises(ReleaseError, match="manifest_digest_mismatch"):
        store.manifest(base)
    with pytest.raises(ReleaseError, match="invalid_release_id"):
        store.path("../../source")


@pytest.mark.parametrize("fields", [[{"department": "economy", "name": "wood_priority", "type": "bool", "default": "false"}],
                                   [{"department": "economy", "name": "__class__", "type": "dict", "default": {}}],
                                   [{"department": "premier", "name": "flag", "type": "bool", "default": False}],
                                   [{"department": "tech", "name": "flag", "type": "int", "default": True}]])
def test_rejects_invalid_state_field_declarations(tmp_path, source, fields):
    store = ReleaseStore(tmp_path / "store", source)
    base = store.bootstrap()
    with pytest.raises(ReleaseError):
        store.build(base, proposal(base, state_fields=fields))


def test_persists_declared_state_default(tmp_path, source):
    store = ReleaseStore(tmp_path / "store", source)
    base = store.bootstrap()
    fields = [{"department": "economy", "name": "wood_priority", "type": "bool", "default": False}]
    result = store.build(base, proposal(base, state_fields=fields))
    assert store.manifest(result)["proposal"]["state_fields"] == fields


def test_generated_module_is_never_executed_by_release_builder(tmp_path, source):
    store = ReleaseStore(tmp_path / "store", source)
    base = store.bootstrap()
    text = patch("VALUE = 1\n", "raise RuntimeError('executed during import')\n")
    result = store.build(base, proposal(base, text))
    assert store.manifest(result)["validation"]["behavior"] == "requires_worker_validation"


def test_single_proposal_can_change_all_five_departments(tmp_path, source):
    store = ReleaseStore(tmp_path / "store", source)
    base = store.bootstrap()
    text = "".join(patch("VALUE = 1\n", f"VALUE = {index + 2}\n", name)
                   for index, name in enumerate(sorted(WRITABLE)))
    result = store.build(base, proposal(base, text))
    assert store.manifest(result)["proposal"]["changed_files"] == sorted(WRITABLE)
    for index, name in enumerate(sorted(WRITABLE)):
        assert (store.path(result) / name).read_text() == f"VALUE = {index + 2}\n"
    assert (store.path(result) / "brain/cabinet/runtime.py").read_bytes() == (source / "brain/cabinet/runtime.py").read_bytes()


def test_source_links_are_rejected_before_copying(tmp_path, source, monkeypatch):
    from brain.legislation import releases
    original = releases._linked
    monkeypatch.setattr(releases, "_linked", lambda path: path.name == "economy.py" or original(path))
    store = ReleaseStore(tmp_path / "store", source)
    with pytest.raises(ReleaseError, match="linked_source_file"):
        store.bootstrap()
    assert not list(store.releases.iterdir())
