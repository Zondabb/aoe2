"""Real Godot + HTTP multi-agent test with a bounded local mock planner.

No paid requests or user token files are used. Slow planning runs independently
of the v3 simulation ticks. The harness retains diagnostics under .godot only.
"""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.request import urlopen

from test_external_llm_e2e import mock_service_settings


class RolePlanner:
    def __init__(self):
        self.roles: set[str] = set()
        self.calls = 0
        self.lock = threading.Lock()

    def complete(self, payload: dict) -> dict:
        if payload.get("model") != "mock-role-planner":
            raise ValueError("upstream model did not come from isolated server configuration")
        context = json.loads(payload["messages"][-1]["content"])
        role = context["role"]
        plan = dict(context["plan"])
        # These are plans, not unit IDs, coordinates, commands or resource grants.
        if role == "commander":
            plan.update(stance="pressure", army_target=6, muster_timeout=60)
        elif role == "combat":
            plan.update(army_target=6, producer="barracks", producer_count=2)
        elif role == "economy":
            plan.update(worker_target=18, food_workers_ratio=.4)
        elif role == "defense":
            plan.update(policy="fortify")
        with self.lock:
            self.roles.add(role)
            self.calls += 1
            number = self.calls
        return {"id": f"local-plan-{number}", "model": "mock-role-planner", "choices": [{
            "index": 0, "finish_reason": "tool_calls", "message": {"role": "assistant", "content": None,
                "tool_calls": [{"id": f"plan-{number}", "type": "function", "function": {
                    "name": "propose_plan", "arguments": json.dumps(plan)}}]}}],
            "usage": {"prompt_tokens": 100, "completion_tokens": 40, "total_tokens": 140}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--duration", type=float, default=1200)
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--intelligence", choices=("on", "off"), default="on",
                        help="Strategic intelligence layer; off reproduces the previous tactics for A/B runs")
    parser.add_argument("--planner-delay", type=float, default=2)
    parser.add_argument("--require-victory", action="store_true", help="Require actual enemy TC destruction, not only damage")
    parser.add_argument("--require-walls", action="store_true", help="Require a completed AI wall built through the defense role")
    parser.add_argument("--require-siege", action="store_true", help="Require a completed workshop and a paid ram, including in standard openings")
    parser.add_argument("--siege-scenario", action="store_true", help="Castle-age finite-stock scenario: build siege, breach walls, raid workers and destroy the TC")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    logs = Path(tempfile.mkdtemp(prefix="multi-agent-e2e-", dir=root / ".godot"))
    planner = RolePlanner()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            time.sleep(args.planner_delay)
            body = json.dumps(planner.complete(payload)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_args):
            pass

    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    config, env = mock_service_settings(logs, f"http://127.0.0.1:{upstream.server_port}/v1", "mock-role-planner")
    env.update(AOE2_AI_MODEL_CALLS_PER_MINUTE="12", APPDATA=str(logs / "profile"), LOCALAPPDATA=str(logs / "cache"))
    # Explicit A/B switch for the strategic intelligence layer (inherited
    # AOE2_AI_* variables are stripped above to isolate the harness).
    env["AOE2_AI_INTELLIGENCE"] = args.intelligence
    env["AOE2_AI_STRATEGY_MEMORY"] = "off"
    Path(env["APPDATA"]).mkdir()
    processes, handles = [], []

    def launch(command, label, cwd):
        handle = (logs / f"{label}.txt").open("w", encoding="utf-8")
        handles.append(handle)
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=handle, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        processes.append(process)
        return process

    try:
        service = launch([sys.executable, "main.py", "--config", str(config), "--host", "127.0.0.1", "--port", str(port)], "service", root / "ai_service_python")
        ready_by = time.monotonic() + 15
        while time.monotonic() < ready_by:
            if service.poll() is not None:
                raise RuntimeError("AI service exited")
            try:
                with urlopen(f"http://127.0.0.1:{port}/health", timeout=.5) as response:
                    if response.status == 200:
                        break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError("AI service startup timed out")
        game = launch([args.godot, "--headless", "--path", str(root), "--log-file", str(logs / "game.log"),
            "--script", "res://tests/run_multi_agent_match.gd", "--", f"http://127.0.0.1:{port}",
            str(args.duration), str(logs / "observation.json"), str(int(args.require_victory)), str(int(args.require_walls)), str(int(args.siege_scenario)), str(int(args.require_siege))], "game", root)
        deadline, last_print = time.monotonic() + args.timeout, time.monotonic()
        while game.poll() is None:
            output = (logs / "game.txt").read_text(encoding="utf-8", errors="replace")
            if "SCRIPT ERROR:" in output:
                raise RuntimeError(output[-7000:])
            if time.monotonic() >= deadline:
                raise RuntimeError("Godot multi-agent test timed out")
            if time.monotonic() - last_print >= 15:
                lines = [line for line in output.splitlines() if line.startswith("MULTI AGENT")]
                print(lines[-1] if lines else "Multi-agent match starting", flush=True)
                last_print = time.monotonic()
            time.sleep(.1)
        output = (logs / "game.txt").read_text(encoding="utf-8", errors="replace")
        print("\n".join(line for line in output.splitlines()
                        if line.startswith(("MULTI AGENT RESULT:", "MULTI AGENT MATCH:")) or "ERROR:" in line))
        if game.returncode != 0 or "0 failures" not in output:
            raise RuntimeError(f"Godot test failed ({game.returncode})")
        if len(planner.roles) != 7:
            raise RuntimeError(f"Not all seven planners were called: {sorted(planner.roles)}")
        print(f"MULTI AGENT E2E PASSED: roles={sorted(planner.roles)} calls={planner.calls}; logs: {logs}")
        return 0
    except (OSError, RuntimeError) as error:
        print(f"MULTI AGENT E2E FAILED: {error}; logs: {logs}", file=sys.stderr)
        return 1
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for handle in handles:
            handle.close()
        upstream.shutdown()
        upstream.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
