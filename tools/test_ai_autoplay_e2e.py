"""Test real single-player and online opt-in through Python LLM and a local mock.

Starts temporary AI/relay services and Godot peers, uses no paid endpoint or token
file, and cleans up every helper process. Run with the AI service Python venv.
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

from test_external_llm_e2e import MockStrategist, mock_service_settings
from test_multi_agent_e2e import RolePlanner


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--protocol", choices=("v3", "v2"), default="v3",
                        help="v3 specialist planning (default), or legacy v2 commander regression")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    logs = Path(tempfile.mkdtemp(prefix="ai-autoplay-e2e-", dir=root / ".godot"))
    mock = MockStrategist()
    planner = RolePlanner()
    offered_plan = set()
    saw_instructions = threading.Event()
    online_instructions = set()
    mock_lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            if self.path != "/v1/chat/completions":
                self.send_error(404)
                return
            payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            # Ensure cancellation occurs while a real upstream HTTP call is pending.
            time.sleep(0.25)
            with mock_lock:
                if args.protocol == "v3":
                    tools = [tool.get("function", {}).get("name") for tool in payload.get("tools", [])]
                    if "propose_plan" not in tools:
                        self.send_error(400, "v3 must offer propose_plan")
                        return
                    context = json.loads(payload["messages"][-1]["content"])
                    offered_plan.add(context["role"])
                    if context.get("player_instructions") == ["多生产一些骑士", "增加食物采集"]:
                        saw_instructions.set()
                    for team in (0, 1):
                        if context.get("player_instructions") == [f"队伍{team}：增加食物采集"]:
                            online_instructions.add(team)
                    result = planner.complete(payload)
                else:
                    brief = payload["messages"][-1]["content"]
                    instructions = json.loads(brief.split("\n", 1)[1]).get("player_instructions", []) if brief.startswith("RTS decision brief:\n") else []
                    if instructions == ["多生产一些骑士", "增加食物采集"]: saw_instructions.set()
                    for team in (0, 1):
                        if instructions == [f"队伍{team}：增加食物采集"]: online_instructions.add(team)
                    result = mock.complete(payload)
                response = json.dumps(result).encode("utf-8")
            try:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(response)))
                self.end_headers()
                self.wfile.write(response)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_args: object) -> None:
            pass

    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    ai_port, relay_port, dead_port = free_port(), free_port(), free_port()
    config, env = mock_service_settings(logs, f"http://127.0.0.1:{upstream.server_port}/v1",
                                        "mock-role-planner" if args.protocol == "v3" else "mock-strategist")
    env.update(AOE2_AI_URL=f"http://127.0.0.1:{ai_port}", AOE2_MP_HOST="127.0.0.1", AOE2_MP_PORT=str(relay_port))
    # The game URL override would defeat the explicit dead-endpoint test.
    game_env = dict(env)
    game_env.pop("AOE2_AI_URL", None)
    processes: list[subprocess.Popen] = []
    handles = []
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

    def launch(command: list[str], label: str, cwd: Path = root, game: bool = False) -> subprocess.Popen:
        output = (logs / f"{label}.txt").open("w", encoding="utf-8")
        handles.append(output)
        child_env = dict(game_env if game else env)
        child_env["APPDATA"] = str(logs / f"profile-{label}")
        Path(child_env["APPDATA"]).mkdir()
        process = subprocess.Popen(command, cwd=cwd, env=child_env, stdout=output,
                                   stderr=subprocess.STDOUT, creationflags=flags)
        processes.append(process)
        return process

    def wait_health(url: str, process: subprocess.Popen) -> None:
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

    def wait_clients(clients: list[subprocess.Popen], labels: list[str], marker: str) -> None:
        deadline = time.monotonic() + 120
        while any(client.poll() is None for client in clients):
            if time.monotonic() > deadline:
                raise RuntimeError("Godot autoplay timed out")
            for label in labels:
                output = (logs / f"{label}.txt").read_text(encoding="utf-8", errors="replace")
                if "SCRIPT ERROR:" in output:
                    print(output[-12000:])
                    raise RuntimeError("Godot script error")
            time.sleep(0.1)
        for client, label in zip(clients, labels):
            output = (logs / f"{label}.txt").read_text(encoding="utf-8", errors="replace")
            print(output[-8000:])
            if client.returncode != 0 or marker not in output or "failures" not in output or "FAILED:" in output:
                raise RuntimeError(f"{label} failed ({client.returncode})")

    def godot(script: str, label: str, script_args: list[str]) -> subprocess.Popen:
        return launch([args.godot, "--headless", "--path", str(root),
                       "--log-file", (logs / f"{label}.log").as_posix(),
                       "--script", f"res://tests/{script}", "--", *script_args], label, game=True)

    try:
        service = launch([sys.executable, "main.py", "--config", str(config),
                          "--host", "127.0.0.1", "--port", str(ai_port)], "ai-service", root / "ai_service_python")
        relay = launch([sys.executable, "-m", "multiplayer_service_python.main"], "relay")
        wait_health(f"http://127.0.0.1:{ai_port}/health", service)
        wait_health(f"http://127.0.0.1:{relay_port}/healthz", relay)
        ai_url = f"http://127.0.0.1:{ai_port}"
        single = godot("run_ai_autoplay.gd", "single", [ai_url, f"http://127.0.0.1:{dead_port}", args.protocol])
        wait_clients([single], ["single"], "AI AUTOPLAY SINGLE:")
        if not saw_instructions.is_set():
            raise RuntimeError("Player instructions did not reach the upstream model")
        peers = [godot("run_ai_autoplay_peer.gd", f"peer-{side}",
                       [f"ws://127.0.0.1:{relay_port}/ws", ai_url, args.protocol]) for side in range(2)]
        wait_clients(peers, ["peer-0", "peer-1"], "AI AUTOPLAY PEER:")
        if online_instructions != {0, 1}:
            raise RuntimeError(f"Both online teams' instructions must reach separate model contexts: {online_instructions}")
        if args.protocol == "v3":
            expected = {"commander", "construction", "economy", "technology", "scout", "combat", "defense"}
            if planner.calls < 6 or planner.roles != expected or offered_plan != expected:
                raise RuntimeError(f"six role planners did not reach real propose_plan HTTP calls: {planner.roles}")
            calls = planner.calls
        else:
            if mock.calls < 4 or not mock.offered_strategy or not mock.saw_commander_context:
                raise RuntimeError("external Python commander did not reach the mock strategic model")
            calls = mock.calls
        print(f"AI AUTOPLAY E2E PASSED ({args.protocol}); {calls} local model calls; logs: {logs}")
        return 0
    except (OSError, RuntimeError) as error:
        print(f"AI AUTOPLAY E2E FAILED: {error}; logs: {logs}", file=sys.stderr)
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
