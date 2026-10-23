"""Exercise external LLM strategy over real HTTP and real headless Godot gameplay.

The upstream is an in-process local OpenAI-compatible mock. No token files are
read and no paid model endpoint is used. The mock selects strategy only; the
production Python commander must scout, build, train, rally and issue attacks.
"""
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.request import urlopen


def mock_service_settings(logs: Path, upstream_url: str, model: str) -> tuple[Path, dict[str, str]]:
    """Give each harness its own server settings, without user configuration."""
    config = logs / "ai-service.toml"
    config.write_text(
        '[service]\nhost = "127.0.0.1"\napi_token = ""\nlog_observation = false\n\n'
        '[llm]\nbackend = "openai"\n'
        f'model = {json.dumps(model)}\nbase_url = {json.dumps(upstream_url)}\n'
        'token = "test-dummy-never-paid"\nmax_tokens = 2048\ntemperature = 0.2\n'
        'timeout_sec = 10\nnum_ctx = 8192\n', encoding="utf-8")
    # Empty environment values do not override config.local.toml. Select the
    # isolated config explicitly and remove all inherited provider overrides.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("AOE2_AI_", "AOE2_LLM_"))}
    # All seven roles must be observable within short opt-in/cancel tests.
    # Keep the harness quota bounded and independent of the operator's quota.
    env["AOE2_AI_MODEL_CALLS_PER_MINUTE"] = "12"
    return config, env


class MockStrategist:
    def __init__(self) -> None:
        self.calls = 0
        self.offered_strategy = False
        self.saw_rejection = False
        self.saw_commander_context = False
        self.stances: set[str] = set()
        self.samples: list[dict] = []

    def complete(self, payload: dict) -> dict:
        if payload.get("model") != "mock-strategist":
            raise ValueError("upstream model did not come from isolated server configuration")
        self.calls += 1
        tools = payload.get("tools", [])
        self.offered_strategy |= any(t.get("function", {}).get("name") == "set_strategy" for t in tools)
        text = "\n".join(str(message.get("content") or "") for message in payload.get("messages", []))
        self.saw_rejection |= "missing_unit" in text
        self.saw_commander_context |= any(word in text.lower() for word in ("commander", "frontier", "scout_missions", "recent_rejections"))
        # These values come exclusively from the offered observation / commander
        # brief. The mock has no map, unit IDs, positions, or game-side access.
        counts = re.findall(r'"military_count"\s*:\s*(\d+)', text)
        counts += re.findall(r"军事单位数\s*=\s*(\d+)", text)
        military_count = max(map(int, counts), default=0)
        for message in payload.get("messages", []):
            content = str(message.get("content") or "")
            if content.startswith("RTS decision brief:\n"):
                brief = json.loads(content.split("\n", 1)[1])
                military_count = max(military_count, sum(
                    entity.get("kind") == "unit" and entity.get("def_id") != "villager"
                    for entity in brief.get("own_entities", [])))
        stance = "develop" if self.calls <= 5 else "muster"
        if "attack" in self.stances or (military_count >= 7 and self.calls >= 60):
            stance = "attack"
        self.stances.add(stance)
        calls = [{"id": f"strategy_{self.calls}", "type": "function", "function": {
            "name": "set_strategy",
            "arguments": json.dumps({"stance": stance, "army_target": 6, "military_building": "barracks"}),
        }}]
        if self.calls == 1:
            # Malformed model control must be filtered by Python, never reach
            # gameplay as an unauthorized unit order.
            calls.append({"id": "unsafe_unit_control", "type": "function", "function": {
                "name": "stop", "arguments": '{"unit_id":2147480001}',
            }})
        if self.calls <= 3 or (stance == "attack" and not any(s["stance"] == "attack" for s in self.samples)):
            self.samples.append({"call": self.calls, "stance": stance, "military_count": military_count,
                                 "payload": payload})
        return {"id": f"chatcmpl_mock_{self.calls}", "object": "chat.completion", "model": "mock-strategist",
                "choices": [{"index": 0, "finish_reason": "tool_calls", "message": {
                    "role": "assistant", "content": None, "tool_calls": calls,
                }}], "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, help="Godot 4 console executable")
    parser.add_argument("--duration", type=float, default=900, help="Simulated match seconds")
    parser.add_argument("--timeout", type=float, default=480, help="Wall clock deadline for the Godot process")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    log_root = root / ".godot"
    log_root.mkdir(exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix="external-llm-e2e-", dir=log_root))
    mock = MockStrategist()

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            if self.path != "/v1/chat/completions":
                self.send_error(404)
                return
            try:
                payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
                response = json.dumps(mock.complete(payload)).encode("utf-8")
            except (ValueError, TypeError) as error:
                self.send_error(400, str(error))
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

        def log_message(self, _format: str, *args: object) -> None:
            pass

    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    endpoint = f"http://127.0.0.1:{port}"
    config, env = mock_service_settings(logs, f"http://127.0.0.1:{upstream.server_port}/v1", "mock-strategist")
    env.update(APPDATA=str(logs / "profile"))
    Path(env["APPDATA"]).mkdir()
    processes: list[subprocess.Popen] = []
    handles = []
    flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

    def launch(command: list[str], label: str, cwd: Path) -> subprocess.Popen:
        output = (logs / f"{label}.txt").open("w", encoding="utf-8")
        handles.append(output)
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, creationflags=flags)
        processes.append(process)
        return process

    try:
        service = launch([sys.executable, "main.py", "--config", str(config),
                          "--host", "127.0.0.1", "--port", str(port)], "service", root / "ai_service_python")
        deadline = time.monotonic() + 15
        while True:
            if service.poll() is not None:
                raise RuntimeError("Python service failed to start")
            try:
                with urlopen(endpoint + "/health", timeout=0.5) as response:
                    if response.status == 200: break
            except OSError:
                pass
            if time.monotonic() > deadline:
                raise RuntimeError("Python service startup timed out")
            time.sleep(0.1)
        client = launch([args.godot, "--headless", "--fixed-fps", "60", "--path", str(root),
                         "--log-file", (logs / "godot.log").as_posix(),
                         "--script", "res://tests/run_external_llm_match.gd", "--", endpoint,
                         str(args.duration), str(logs / "observation.json")], "game", root)
        deadline = time.monotonic() + args.timeout
        next_progress = time.monotonic() + 30
        next_error_check = time.monotonic() + 2
        while client.poll() is None:
            if time.monotonic() > deadline:
                raise RuntimeError("Godot external LLM match timed out")
            if time.monotonic() > next_error_check:
                game_output = (logs / "game.txt").read_text(encoding="utf-8", errors="replace")
                if "SCRIPT ERROR:" in game_output:
                    print(game_output[-18000:])
                    raise RuntimeError("Godot script error during external LLM match")
                next_error_check = time.monotonic() + 2
            if time.monotonic() > next_progress:
                game_output = (logs / "game.txt").read_text(encoding="utf-8", errors="replace")
                progress = [line for line in game_output.splitlines() if line.startswith("EXTERNAL LLM ")]
                print(progress[-1] if progress else f"External LLM HTTP requests: {mock.calls}", flush=True)
                next_progress = time.monotonic() + 30
            time.sleep(0.1)
        output = (logs / "game.txt").read_text(encoding="utf-8", errors="replace")
        print(output[-18000:])
        if client.returncode != 0 or "SCRIPT ERROR:" in output or not re.search(r"EXTERNAL LLM MATCH: \d+ checks, 0 failures", output):
            raise RuntimeError(f"Godot external LLM gameplay failed ({client.returncode})")
        assertions = {
            "actual upstream called": mock.calls >= 20,
            "server offered strategic tool": mock.offered_strategy,
            "server offered tactical context": mock.saw_commander_context,
            "game rejection fed back to upstream": mock.saw_rejection,
            "model chose development, muster and attack": {"develop", "muster", "attack"}.issubset(mock.stances),
        }
        for label, ok in assertions.items():
            if not ok: raise RuntimeError(label)
        print(f"EXTERNAL LLM E2E PASSED: {len(assertions)} HTTP assertions; {mock.calls} mock model calls; logs: {logs}")
        return 0
    except (OSError, RuntimeError) as error:
        print(f"EXTERNAL LLM E2E FAILED: {error}; logs: {logs}", file=sys.stderr)
        return 1
    finally:
        (logs / "upstream-samples.json").write_text(json.dumps(mock.samples, ensure_ascii=False, indent=2), encoding="utf-8")
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
