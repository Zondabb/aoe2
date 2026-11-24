"""Worker startup failures are retryable and never publish half-open sessions."""
from types import SimpleNamespace

import pytest

from brain.legislation.process import WorkerError
from brain.multi_agent.scheduler import MultiAgentService, SessionError
from test_multi_agent_scheduler import Runtime, tick_request


class StartupRuntime(Runtime):
    def __init__(self, profile, *, bind_error=None, memory_error=None, close_error=None):
        super().__init__(profile)
        self.bind_error, self.memory_error, self.close_error = bind_error, memory_error, close_error
        self.last_seq, self.last_time, self.instructions = -1, -1, ()
        self.closed = False

    def bind_session(self, req):
        if self.bind_error:
            raise self.bind_error

    def load_strategic_memory(self, snapshot):
        if self.memory_error:
            raise self.memory_error

    def close(self):
        self.closed = True
        if self.close_error:
            raise self.close_error


@pytest.mark.parametrize("failure", [WorkerError("private worker diagnostic"), FileNotFoundError("private worker path")])
def test_failed_factory_returns_generic_retryable_error_without_registering_session(failure):
    attempts = []
    def factory(profile):
        attempts.append(profile)
        if len(attempts) == 1:
            raise failure
        return StartupRuntime(profile)
    service = MultiAgentService(runtime_factory=factory)
    try:
        with pytest.raises(SessionError) as caught:
            service.tick(tick_request())
        assert caught.value.status_code == 503
        assert caught.value.reason == "cabinet_worker_unavailable"
        assert not service._sessions
        assert service.tick(tick_request())["acknowledged_observation_seq"] == 1
        assert len(attempts) == 2
    finally:
        service.shutdown()


@pytest.mark.parametrize("cleanup_failure", [None, OSError("cleanup failed")])
def test_failed_bind_closes_partial_runtime_and_retry_has_fresh_session(cleanup_failure):
    workers = []
    def factory(profile):
        worker = StartupRuntime(profile, bind_error=WorkerError("restore failed") if not workers else None,
                                close_error=cleanup_failure if not workers else None)
        workers.append(worker)
        return worker
    service = MultiAgentService(runtime_factory=factory)
    try:
        with pytest.raises(SessionError, match="cabinet_worker_unavailable") as caught:
            service.tick(tick_request())
        assert caught.value.status_code == 503
        assert workers[0].closed
        assert not service._sessions
        assert service.tick(tick_request())["acknowledged_observation_seq"] == 1
        assert len(workers) == 2 and workers[1].calls == 1
    finally:
        service.shutdown()


def test_worker_dying_during_memory_load_closes_partial_session():
    worker = StartupRuntime("default", memory_error=WorkerError("worker stopped"))
    memory = SimpleNamespace(snapshot=lambda profile: {})
    service = MultiAgentService(runtime_factory=lambda profile: worker, memory=memory)
    try:
        with pytest.raises(SessionError) as caught:
            service.tick(tick_request())
        assert caught.value.status_code == 503
        assert worker.closed and not service._sessions
    finally:
        service.shutdown()


def test_unavailable_advisory_memory_does_not_close_healthy_runtime():
    worker = StartupRuntime("default")
    def snapshot(profile):
        raise OSError("memory store offline")
    service = MultiAgentService(runtime_factory=lambda profile: worker,
                                memory=SimpleNamespace(snapshot=snapshot))
    try:
        assert service.tick(tick_request())["acknowledged_observation_seq"] == 1
        assert not worker.closed
    finally:
        service.shutdown()


def test_worker_diagnostic_is_logged_but_not_returned_to_client():
    failure = WorkerError("worker_exited")
    failure.diagnostic = "bounded Docker startup diagnostic"
    logs = []
    def factory(profile):
        raise failure
    service = MultiAgentService(runtime_factory=factory, log=lambda event, data: logs.append((event, data)))
    try:
        with pytest.raises(SessionError) as caught:
            service.tick(tick_request())
        assert str(caught.value) == "cabinet_worker_unavailable"
        assert logs[-1][0] == "cabinet_worker_start_failed"
        assert logs[-1][1]["reason"] == "worker_exited"
        assert logs[-1][1]["diagnostic"] == failure.diagnostic
    finally:
        service.shutdown()


def test_http_worker_startup_failure_returns_503_without_child_diagnostics(monkeypatch):
    from fastapi.testclient import TestClient
    import main

    def factory(profile):
        raise WorkerError("worker_exited", diagnostic="private Docker startup details")
    service = MultiAgentService(runtime_factory=factory)
    monkeypatch.setattr(main, "_multi_agent_service", service)
    try:
        response = TestClient(main.app).post("/v3/ai/tick", json=tick_request().model_dump())
        assert response.status_code == 503
        assert response.json() == {"detail": "cabinet_worker_unavailable"}
        assert not service._sessions
    finally:
        service.shutdown()
