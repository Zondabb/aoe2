"""Two configured Python AI services control separate teams in a real online match.

Uses only temporary TOML settings, a local mock model endpoint and a local relay.
No operator configs, tokens or paid model endpoints are read. Logs stay in .godot.
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

from test_multi_agent_e2e import RolePlanner


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    (root / ".godot").mkdir(exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="dual-ai-e2e-", dir=root / ".godot"))
    models = ["mock-team-zero", "mock-team-one"]
    planners = {model: RolePlanner() for model in models}
    samples: dict[str, list[dict]] = {model: [] for model in models}
    mock_errors: list[str] = []
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            try:
                if self.path != "/v1/chat/completions":
                    raise ValueError("unexpected mock endpoint")
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                model = payload["model"]
                if model not in planners:
                    raise ValueError("model did not come from either isolated service config")
                context = json.loads(payload["messages"][-1]["content"])
                if not any(tool.get("function", {}).get("name") == "propose_plan"
                           for tool in payload.get("tools", [])):
                    raise ValueError("model must receive bounded specialist planning tools")
                time.sleep(0.1)
                with lock:
                    samples[model].append(context)
                    # Reuse the existing bounded mock while retaining the actual
                    # model name in assertions and in the completion response.
                    normalized = {**payload, "model": "mock-role-planner"}
                    result = planners[model].complete(normalized)
                    result["model"] = model
                body = json.dumps(result).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except (KeyError, ValueError) as error:
                with lock:
                    mock_errors.append(str(error))
                self.send_error(400)

        def log_message(self, *_args: object) -> None:
            pass

    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    ports = [free_port() for _ in range(4)]
    while len(set(ports)) != len(ports):
        ports = [free_port() for _ in range(4)]
    ai_ports, relay_port, dead_port = ports[:2], ports[2], ports[3]
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("AOE2_AI_", "AOE2_LLM_"))}
    env.update(AOE2_AI_MODEL_CALLS_PER_MINUTE="12", AOE2_MP_HOST="127.0.0.1", AOE2_MP_PORT=str(relay_port))
    processes: list[subprocess.Popen] = []
    handles = []
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

    def launch(command: list[str], label: str, cwd: Path = root) -> subprocess.Popen:
        output = (logs / f"{label}.txt").open("w", encoding="utf-8")
        handles.append(output)
        child_env = dict(env)
        child_env["APPDATA"] = str(logs / f"profile-{label}")
        Path(child_env["APPDATA"]).mkdir()
        process = subprocess.Popen(command, cwd=cwd, env=child_env, stdout=output,
                                   stderr=subprocess.STDOUT, creationflags=flags)
        processes.append(process)
        return process

    def health(url: str, process: subprocess.Popen) -> None:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("temporary service exited")
            try:
                with urlopen(url, timeout=0.5) as response:
                    if response.status == 200:
                        return
            except OSError:
                pass
            time.sleep(0.1)
        raise RuntimeError("temporary service startup timed out")

    try:
        for team, port in enumerate(ai_ports):
            directory = logs / f"service-{team}"
            directory.mkdir()
            config = directory / "config.toml"
            config.write_text(
                '[service]\nhost = "127.0.0.1"\n'
                f'port = {port}\napi_token = ""\nlog_dir = {json.dumps(str(directory / "logs"))}\n\n'
                '[llm]\nbackend = "openai"\n'
                f'model = {json.dumps(models[team])}\n'
                f'base_url = "http://127.0.0.1:{upstream.server_port}/v1"\n'
                'token = "test-dummy-never-paid"\nmax_tokens = 2048\n'
                'temperature = 0.2\ntimeout_sec = 10\nnum_ctx = 8192\n', encoding="utf-8")
            # The port comes from the separate TOML, not a command line override.
            process = launch([sys.executable, "main.py", "--config", str(config)],
                             f"ai-{team}", root / "ai_service_python")
            health(f"http://127.0.0.1:{port}/health", process)
        relay = launch([sys.executable, "-m", "multiplayer_service_python.main"], "relay")
        health(f"http://127.0.0.1:{relay_port}/healthz", relay)
        report_file = logs / "host-report.json"
        clients = []
        for side in range(2):
            label = f"peer-{side}"
            clients.append(launch([
                args.godot, "--headless", "--path", str(root), "--log-file", str(logs / f"{label}.log"),
                "--script", "res://tests/run_dual_ai_services_peer.gd", "--",
                f"ws://127.0.0.1:{relay_port}/ws", *(f"http://127.0.0.1:{port}" for port in ai_ports),
                f"http://127.0.0.1:{dead_port}", str(report_file)], label))
        deadline = time.monotonic() + 50
        while any(client.poll() is None for client in clients):
            for side in range(2):
                output = (logs / f"peer-{side}.txt").read_text(encoding="utf-8", errors="replace")
                if "SCRIPT ERROR:" in output:
                    raise RuntimeError(f"Godot script error: {output[-8000:]}")
            if time.monotonic() > deadline:
                raise RuntimeError("Godot peer timeout")
            time.sleep(0.1)
        for side, client in enumerate(clients):
            output = (logs / f"peer-{side}.txt").read_text(encoding="utf-8", errors="replace")
            print("\n".join(line for line in output.splitlines() if "DUAL AI PEER:" in line))
            if client.returncode != 0 or "DUAL AI PEER:" not in output or "FAILED:" in output:
                print(output[-8000:])
                raise RuntimeError(f"peer {side} failed")
        report = json.loads(report_file.read_text(encoding="utf-8"))
        roster = report["entity_teams"]
        if mock_errors:
            raise RuntimeError(f"upstream validation failed: {mock_errors}")
        required_roles = {"commander", "construction", "economy", "technology", "scout", "combat", "defense"}
        for team, model in enumerate(models):
            if planners[model].roles != required_roles:
                raise RuntimeError(f"{model} did not plan every specialist role: {planners[model].roles}")
            own_ids = {str(entity["id"]) for sample in samples[model]
                       for section in ("buildings", "workers", "units", "production")
                       for entity in sample.get(section, [])}
            if not own_ids or any(roster.get(identifier) != team for identifier in own_ids):
                raise RuntimeError(f"{model} received another team's own-entity observation")
            events = [json.loads(line) for line in (logs / f"service-{team}" / "logs" / "multi_agent.jsonl")
                      .read_text(encoding="utf-8").splitlines()]
            ticks = [event for event in events if event["event"] == "tick"]
            if len(ticks) < 8 or any(event["team"] != team for event in ticks):
                raise RuntimeError(f"service {team} received missing or mixed-team ticks")
            model_io = [event for event in events if event["event"] == "llm_io"]
            if not model_io or any(event["model"] != model or event["team"] != team for event in model_io):
                raise RuntimeError(f"service {team} model attribution mismatch")
            if team == 1 and sum(event["wall_time"] > report["reroute_time"] + 1 for event in ticks) < 4:
                raise RuntimeError("healthy AI stopped ticking when the other endpoint changed")
            print(f"Team {team}: {model}, {len(ticks)} real HTTP ticks, "
                  f"{planners[model].calls} model calls, all seven roles; no team crossover")
        print(f"DUAL AI E2E PASSED; logs: {logs}")
        return 0
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        print(f"DUAL AI E2E FAILED: {error}; logs: {logs}", file=sys.stderr)
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
        thread.join(timeout=2)


if __name__ == "__main__":
    raise SystemExit(main())
