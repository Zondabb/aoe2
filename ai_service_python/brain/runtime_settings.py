from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import tomllib
from typing import Any

SERVICE_DIR = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG_PATH = SERVICE_DIR / "config.toml"
_cli: dict[str, str] = {}
_config: dict[str, str] = {}
_config_path = DEFAULT_CONFIG_PATH
_loaded = False
_KEYS = {
    "service": {"host": "host", "port": "port", "api_token": "ai_token",
                "log_observation": "log_observation", "log_dir": "log_dir",
                "snapshot_seconds": "snapshot_seconds"},
    "llm": {"backend": "backend", "model": "llm_model", "base_url": "llm_base_url",
            "token": "llm_token", "max_tokens": "llm_max_tokens", "temperature": "llm_temperature",
            "timeout_sec": "llm_timeout_sec", "num_ctx": "llm_num_ctx", "think": "llm_think"},
    "ai": {"runtime": "ai_runtime", "legislation_enabled": "legislation_enabled",
           "legislation_dir": "legislation_dir", "worker_mode": "worker_mode",
           "worker_image": "worker_image", "worker_timeout_sec": "worker_timeout_sec",
           "legislation_max_tokens": "legislation_max_tokens",
           "legislation_timeout_sec": "legislation_timeout_sec",
           "legislation_context_tokens": "legislation_context_tokens",
           "legislation_max_steps": "legislation_max_steps"},
}
# v3 runtimes a team session can run: the seven-role baseline, or the premier
# and five departments of docs/cabinet_ai_design.md.
AI_RUNTIMES = ("multi_agent", "cabinet")


def load_config(path: str | Path | None = None) -> None:
    """Load settings plus optional NAME.local.toml, without depending on cwd."""
    global _config_path, _loaded
    selected = path or os.environ.get("AOE2_AI_CONFIG", "").strip()
    target = Path(selected).expanduser().resolve() if selected else DEFAULT_CONFIG_PATH
    local = target.with_name(f"{target.stem}.local{target.suffix}")
    values: dict[str, str] = {}
    for candidate in (target, local):
        if not candidate.is_file():
            if candidate == target and selected:
                raise FileNotFoundError(f"AI configuration file not found: {candidate}")
            continue
        try:
            with candidate.open("rb") as source:
                document = tomllib.load(source)
        except (OSError, ValueError):
            # TOML diagnostics can contain the offending value, including a
            # secret. Report its location without echoing file contents.
            raise ValueError(f"Cannot read AI configuration: {candidate}") from None
        for section, entries in document.items():
            if section not in _KEYS or not isinstance(entries, dict):
                raise ValueError(f"Unknown AI configuration section: {section}")
            for key, value in entries.items():
                if key not in _KEYS[section]:
                    raise ValueError(f"Unknown AI configuration option: {section}.{key}")
                if not isinstance(value, (str, bool, int, float)):
                    raise ValueError(f"Invalid AI configuration type: {section}.{key}")
                values[_KEYS[section][key]] = str(value).strip()
    _config.clear()
    _config.update(values)
    _config_path = target
    _loaded = True


def config_path() -> Path:
    if not _loaded:
        load_config()
    return _config_path


def clear_cli() -> None:
    _cli.clear()


def set_cli(**kwargs: Any) -> None:
    for key, value in kwargs.items():
        if value is None:
            continue
        text = str(value).strip()
        if text:
            _cli[key] = text


def get_value(cli_key: str, *env_names: str, default: str = "") -> str:
    if not _loaded:
        load_config()
    if _cli.get(cli_key):
        return _cli[cli_key]
    for name in env_names:
        raw = os.environ.get(name, "").strip()
        if raw:
            return raw
    return _config.get(cli_key, "") or default


def _bounded_number(key: str, env: str, default: float, lower: float, upper: float) -> float:
    try:
        value = float(get_value(key, env, default=str(default)))
        return max(lower, min(upper, value)) if math.isfinite(value) else default
    except (ValueError, TypeError):
        return default


def llm_token() -> str:
    return get_value("llm_token", "AOE2_LLM_TOKEN")


def llm_base_url() -> str:
    return get_value("llm_base_url", "AOE2_LLM_BASE_URL", default="http://127.0.0.1:11434/v1")


def llm_model() -> str:
    return get_value("llm_model", "AOE2_LLM_MODEL", default="qwen3:8b")


def ai_token() -> str:
    return get_value("ai_token", "AOE2_AI_TOKEN")


def backend() -> str:
    return get_value("backend", "AOE2_AI_BACKEND", default="openai")


def ai_runtime() -> str:
    """Runtime given to each new v3 team session."""
    value = get_value("ai_runtime", "AOE2_AI_RUNTIME", default=AI_RUNTIMES[0]).lower()
    if value not in AI_RUNTIMES:
        # A mistyped name must not quietly run the baseline in an A/B duel.
        raise ValueError(f"Unknown AI runtime: {value!r} (expected one of: {', '.join(AI_RUNTIMES)})")
    return value


def llm_timeout_sec() -> float:
    return _bounded_number("llm_timeout_sec", "AOE2_LLM_TIMEOUT_SEC", 30, 2, 600)


def legislation_enabled() -> bool:
    return get_value("legislation_enabled", "AOE2_AI_LEGISLATION_ENABLED", default="false").lower() in {"1", "true", "on"}


def legislation_options() -> dict:
    path = Path(get_value("legislation_dir", "AOE2_AI_LEGISLATION_DIR", default="legislation_data"))
    return {"root": path if path.is_absolute() else config_path().parent / path,
            "mode": get_value("worker_mode", "AOE2_AI_WORKER_MODE", default="docker"),
            "image": get_value("worker_image", "AOE2_AI_WORKER_IMAGE"),
            "timeout": _bounded_number("worker_timeout_sec", "AOE2_AI_WORKER_TIMEOUT_SEC", 5, .1, 30)}


def legislation_max_tokens() -> int:
    return int(_bounded_number("legislation_max_tokens", "AOE2_AI_LEGISLATION_MAX_TOKENS", 8192, 1024, 32768))


def legislation_timeout_sec() -> float:
    """Read timeout for a bounded code-agent step, independent of ordinary plans."""
    return _bounded_number("legislation_timeout_sec", "AOE2_AI_LEGISLATION_TIMEOUT_SEC", 120, 10, 600)


def legislation_context_tokens() -> int:
    """Total context allowance, including the reserved code-agent response."""
    return int(_bounded_number("legislation_context_tokens", "AOE2_AI_LEGISLATION_CONTEXT_TOKENS", 16384, 8192, 131072))


def legislation_output_tokens() -> int:
    """Reserve room for the fixed contract and source, even in an 8k context."""
    context = legislation_context_tokens()
    return min(legislation_max_tokens(), context // 2, max(1024, context - 8192))


def legislation_max_steps() -> int:
    return int(_bounded_number("legislation_max_steps", "AOE2_AI_LEGISLATION_MAX_STEPS", 24, 4, 100))


def llm_max_tokens() -> int:
    return int(_bounded_number("llm_max_tokens", "AOE2_LLM_MAX_TOKENS", 2048, 1, 32768))


def llm_temperature() -> float:
    return _bounded_number("llm_temperature", "AOE2_LLM_TEMPERATURE", 0.2, 0, 2)


def llm_num_ctx() -> int:
    return int(_bounded_number("llm_num_ctx", "AOE2_LLM_NUM_CTX", 8192, 2048, 32768))


def llm_think() -> bool:
    return get_value("llm_think", "AOE2_LLM_THINK", default="false").lower() in {"1", "true", "yes", "on"}


def log_observation() -> bool:
    return get_value("log_observation", "AOE2_AI_LOG_OBSERVATION", default="false").lower() in {"1", "true", "yes", "on"}


def snapshot_seconds() -> float:
    """Game seconds between whole-observation snapshots of a team; 0 keeps none."""
    return _bounded_number("snapshot_seconds", "AOE2_AI_SNAPSHOT_SECONDS", 0, 0, 3600)


def log_dir() -> Path:
    path = Path(get_value("log_dir", "AOE2_AI_LOG_DIR", default="logs")).expanduser()
    return path.resolve() if path.is_absolute() else (config_path().parent / path).resolve()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="AoE2 RTS AI HTTP service")
    parser.add_argument("--config", default="", help="Server TOML settings (default: service directory/config.toml)")
    parser.add_argument("--host", default=None)
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--llm-token", default="", help="Upstream model API token (DeepSeek/OpenAI)")
    parser.add_argument("--llm-token-file", default="", help="Read --llm-token from the first line of a file")
    parser.add_argument("--llm-base-url", default="", help="OpenAI-compatible upstream base URL")
    parser.add_argument("--llm-model", default="", help="Upstream model name")
    parser.add_argument("--llm-timeout-sec", default="", help="Upstream LLM HTTP timeout")
    parser.add_argument("--llm-max-tokens", default="", help="Upstream generation token budget")
    parser.add_argument("--llm-temperature", default="", help="Upstream sampling temperature")
    parser.add_argument("--llm-num-ctx", default="", help="Local Ollama context window")
    parser.add_argument("--llm-think", action=argparse.BooleanOptionalAction, default=None, help="Local Ollama native thinking mode")
    parser.add_argument("--log-observation", action=argparse.BooleanOptionalAction, default=None)
    parser.add_argument("--log-dir", default="", help="Log directory (relative to the selected config file)")
    parser.add_argument("--ai-token", default="", help="Optional Bearer token required from the game")
    parser.add_argument("--backend", default="", help="Backend: openai | rules_compat")
    parser.add_argument("--runtime", default="", help=f"v3 runtime: {' | '.join(AI_RUNTIMES)}")
    return parser


def apply_args(args: argparse.Namespace) -> None:
    load_config(getattr(args, "config", "") or None)
    token = str(getattr(args, "llm_token", "") or "").strip()
    token_file = str(getattr(args, "llm_token_file", "") or "").strip()
    if token_file:
        path = Path(token_file)
        if not path.is_file():
            raise FileNotFoundError(f"llm token file not found: {path}")
        lines = path.read_text(encoding="utf-8").splitlines()
        token = lines[0].strip() if lines else ""
    clear_cli()
    for key in ("host", "port", "llm_base_url", "llm_model", "llm_timeout_sec", "llm_max_tokens",
                "llm_temperature", "llm_num_ctx", "llm_think", "ai_token", "backend", "log_observation", "log_dir"):
        set_cli(**{key: getattr(args, key, None)})
    set_cli(llm_token=token, ai_runtime=getattr(args, "runtime", None))
    ai_runtime()  # refuse to start on an unknown runtime name
    args.host = get_value("host", "AOE2_AI_HOST", default="127.0.0.1")
    args.port = int(_bounded_number("port", "AOE2_AI_PORT", 8765, 1, 65535))


def mask_secret(value: str) -> str:
    return "set" if value.strip() else "MISSING"


# Loading is deferred until main selects a configuration or a getter is used.
# Import-time loading would let a bad environment/default path prevent the
# higher-priority CLI --config option from ever being parsed.
