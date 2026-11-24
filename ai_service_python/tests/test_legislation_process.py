"""Real subprocess transport and state handoff, without external providers."""
import copy
import os
from pathlib import Path
import shutil
import time
from types import SimpleNamespace

import pytest

from brain.cabinet.runtime import CabinetRuntime
from brain.legislation.checkpoint import restore_checkpoint
from brain.legislation.process import WorkerClient, WorkerError, docker_source_path, MAX_DIAGNOSTIC_BYTES
from brain.legislation.releases import ReleaseStore
from test_multi_agent_runtime import accept, frame

SERVICE = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("resolved,expected", [
    ("\\\\?\\D:\\release\\ai_service_python", "D:\\release\\ai_service_python"),
    ("\\\\?\\UNC\\server\\share\\release", "\\\\server\\share\\release"),
    ("D:\\release\\ai_service_python", "D:\\release\\ai_service_python"),
    ("/srv/release/ai_service_python", "/srv/release/ai_service_python"),
])
def test_docker_mount_removes_only_windows_device_prefix(resolved, expected):
    # Test both host platform representations on any CI platform.
    assert docker_source_path(SimpleNamespace(resolve=lambda: resolved)) == expected


def test_import_failure_keeps_bounded_stderr_diagnostic(tmp_path):
    source = tmp_path / "service"
    package = source / "brain" / "legislation"
    package.mkdir(parents=True)
    (source / "brain" / "__init__.py").write_text("", encoding="utf-8")
    (package / "__init__.py").write_text("", encoding="utf-8")
    (package / "worker.py").write_text(
        "import sys\nsys.stderr.write('x' * 100000)\nsys.stderr.flush()\n"
        "raise ModuleNotFoundError('missing_worker_dependency')\n", encoding="utf-8")
    started = time.monotonic()
    with pytest.raises(WorkerError, match="worker_exited") as failure:
        WorkerClient(source, "chinese", mode="local-development", timeout=10)
    assert time.monotonic() - started < 10
    assert "ModuleNotFoundError: missing_worker_dependency" in failure.value.diagnostic
    assert len(failure.value.diagnostic.encode()) <= MAX_DIAGNOSTIC_BYTES + 30


def test_process_launch_failure_is_reported_as_worker_error(monkeypatch):
    def fail(*args, **kwargs):
        raise FileNotFoundError("missing Python executable")
    monkeypatch.setattr("brain.legislation.process.subprocess.Popen", fail)
    with pytest.raises(WorkerError, match="worker_launch_failed") as failure:
        WorkerClient(SERVICE, "chinese", mode="local-development")
    assert "missing Python executable" in failure.value.diagnostic


@pytest.mark.skipif(not os.environ.get("AOE2_TEST_WORKER_IMAGE"), reason="requires a local Docker worker image")
@pytest.mark.parametrize("profile", ["chinese", "teutons"])
def test_docker_worker_loads_published_source_and_retries(tmp_path, profile):
    store = ReleaseStore(tmp_path / "source")
    source = store.path(store.bootstrap())
    worker = WorkerClient(source, profile, mode="docker", image=os.environ["AOE2_TEST_WORKER_IMAGE"], timeout=30)
    try:
        req = frame(1)
        req.metadata = req.metadata.model_copy(update={"profile_id": profile})
        first = worker.call("tick", req.model_dump())
        assert first["commands"]
        assert worker.call("tick", req.model_dump()) == first
        req = frame(2, events=accept(first, seq=50))
        req.metadata = req.metadata.model_copy(update={"profile_id": profile})
        worker.call("tick", req.model_dump())
        state = restore_checkpoint(worker.checkpoint, CabinetRuntime(profile))
        assert state.field.last_tick == 2
    finally:
        worker.close()


def test_real_workers_continue_with_same_commands_and_inflight_state():
    continuous = CabinetRuntime("chinese")
    continuous.legislative_enabled = True
    first = WorkerClient(SERVICE, "chinese", mode="local-development", timeout=15)
    replacement = None
    try:
        req = frame(1)
        actual = first.call("tick", req.model_dump())
        assert actual == continuous.tick(copy.deepcopy(req))
        state = first.checkpoint
        assert restore_checkpoint(state, CabinetRuntime("chinese")).field.pending
        replacement = WorkerClient(SERVICE, "chinese", mode="local-development", timeout=15)
        assert replacement.process.pid != first.process.pid
        assert replacement.call("restore", state, "chinese", []) is True
        restored = restore_checkpoint(replacement.checkpoint, CabinetRuntime("chinese"))
        assert restored.field.kernel.listener is restored.field
        assert restored.economy.field is restored.general.field
        assert replacement.call("tick", req.model_dump()) == actual
        req = frame(2, events=accept(actual, seq=50))
        expected = continuous.tick(copy.deepcopy(req))
        assert replacement.call("tick", req.model_dump()) == expected
        assert first.call("tick", req.model_dump()) == expected
    finally:
        first.close()
        if replacement:
            replacement.close()


def test_worker_timeout_terminates_generated_infinite_loop(tmp_path):
    source = tmp_path / "service"
    for directory in ("brain", "protocol", "data"):
        shutil.copytree(SERVICE / directory, source / directory,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    economy = source / "brain/cabinet/departments/economy.py"
    text = economy.read_text(encoding="utf-8")
    text = text.replace("    def act(self, f) -> None:\n", "    def act(self, f) -> None:\n        while True:\n            pass\n")
    economy.write_text(text, encoding="utf-8")
    worker = WorkerClient(source, "chinese", mode="local-development", timeout=15)
    try:
        worker.timeout = .5
        started = time.monotonic()
        with pytest.raises(WorkerError, match="timeout"):
            worker.call("tick", frame(1).model_dump())
        assert time.monotonic() - started < 5
        assert worker.process.poll() is not None
        # The retained checkpoint precedes the failed tick.
        assert restore_checkpoint(worker.checkpoint, CabinetRuntime("chinese")).field.last_tick == -1
    finally:
        worker.close()


def test_worker_refuses_unknown_rpc_without_mutating_checkpoint():
    worker = WorkerClient(SERVICE, "chinese", mode="local-development", timeout=15)
    try:
        before = copy.deepcopy(worker.checkpoint)
        with pytest.raises(WorkerError, match="unknown_worker_method"):
            worker.call("__getattribute__", "__dict__")
        assert worker.checkpoint == before
        assert worker.call("properties")["goals"]["phase"] == "opening"
    finally:
        worker.close()
