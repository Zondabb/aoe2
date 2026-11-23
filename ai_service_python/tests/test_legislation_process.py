"""Real subprocess transport and state handoff, without external providers."""
import copy
from pathlib import Path
import shutil
import time

import pytest

from brain.cabinet.runtime import CabinetRuntime
from brain.legislation.checkpoint import restore_checkpoint
from brain.legislation.process import WorkerClient, WorkerError
from test_multi_agent_runtime import accept, frame

SERVICE = Path(__file__).resolve().parents[1]


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
