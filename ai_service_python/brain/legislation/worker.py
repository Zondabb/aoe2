"""Bounded JSON RPC entry point. Run only in a WorkerClient environment."""
from __future__ import annotations

import contextlib
import json
import math
import sys

MAX_MESSAGE = 32 * 1024 * 1024


def serve():
    from brain.cabinet.runtime import CabinetRuntime
    from brain.legislation.checkpoint import export_checkpoint, restore_checkpoint
    from protocol.models import ChatCompletionRequest

    runtime = None
    output = sys.stdout
    for raw in iter(lambda: sys.stdin.buffer.readline(MAX_MESSAGE + 1), b""):
        if len(raw) > MAX_MESSAGE:
            return
        try:
            message = json.loads(raw)
            method, args = message["method"], message.get("args", [])
            # Generated modules must never accidentally write into the RPC stream.
            with contextlib.redirect_stdout(sys.stderr):
                if method == "init":
                    runtime = CabinetRuntime(args[0])
                    runtime.legislative_enabled = True
                    result = {"modules": {name: sys.modules[type(getattr(runtime, name)).__module__].__file__
                                          for name in ("economy", "intel", "general", "defense", "tech")}}
                elif runtime is None:
                    raise ValueError("worker_not_initialized")
                elif method == "restore":
                    runtime = restore_checkpoint(args[0], CabinetRuntime(args[1]))
                    runtime.legislative_enabled = True
                    for field in args[2]:
                        dept = getattr(runtime, field["department"])
                        if not hasattr(dept, field["name"]):
                            setattr(dept, field["name"], field["default"])
                    result = True
                elif method == "checkpoint":
                    result = export_checkpoint(runtime)
                elif method == "planning_interval":
                    interval = runtime.planning_interval(*args)
                    result = interval if math.isfinite(interval) else None
                elif method == "tick":
                    result = runtime.tick(ChatCompletionRequest.model_validate(args[0]))
                elif method == "retire_bills":
                    for order in runtime.ledger.orders:
                        if order.legislation and order.legislation.get("status") == "installed":
                            runtime.legislation_result(order.legislation["proposal_id"], *args)
                    result = True
                elif method in {"planning_brief", "planning_context", "apply_plan", "take_journal",
                                "load_strategic_memory", "legislative_requests", "legislation_result"}:
                    result = getattr(runtime, method)(*args)
                elif method == "properties":
                    result = {"goals": runtime.goals, "match_summary": runtime.match_summary}
                else:
                    raise ValueError("unknown_worker_method")
                # Every successful mutation carries its checkpoint, so parent rollback
                # never needs to query a process after it has timed out.
                state = export_checkpoint(runtime)
            response = {"ok": True, "result": result, "checkpoint": state}
            encoded = json.dumps(response, allow_nan=False, separators=(",", ":"))
            if len(encoded.encode()) > MAX_MESSAGE:
                raise ValueError("worker_response_too_large")
        except Exception as exc:
            encoded = json.dumps({"ok": False, "error": type(exc).__name__ + ": " + str(exc)[:300]})
        output.write(encoded + "\n")
        output.flush()


if __name__ == "__main__":
    serve()
