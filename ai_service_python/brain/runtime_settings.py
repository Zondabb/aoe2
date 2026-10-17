from __future__ import annotations

import argparse
import os
from pathlib import Path

_cli: dict[str, str] = {}


def clear_cli() -> None:
    _cli.clear()


def set_cli(**kwargs: str | None) -> None:
    for key, value in kwargs.items():
        if value is None:
            continue
        text = str(value).strip()
        if text:
            _cli[key] = text


def get_value(cli_key: str, *env_names: str, default: str = "") -> str:
    if _cli.get(cli_key):
        return _cli[cli_key]
    for name in env_names:
        raw = os.environ.get(name, "").strip()
        if raw:
            return raw
    return default


def llm_token() -> str:
    return get_value("llm_token", "AOE2_LLM_TOKEN")


def llm_base_url() -> str:
    return get_value("llm_base_url", "AOE2_LLM_BASE_URL")


def llm_model() -> str:
    """Upstream model override. Empty means forward the name sent by the game."""
    return get_value("llm_model", "AOE2_LLM_MODEL")


def ai_token() -> str:
    return get_value("ai_token", "AOE2_AI_TOKEN")


def backend() -> str:
    return get_value("backend", "AOE2_AI_BACKEND")


def llm_timeout_sec() -> float:
    raw = get_value("llm_timeout_sec", "AOE2_LLM_TIMEOUT_SEC")
    if not raw:
        return 30.0
    try:
        return max(2.0, float(raw))
    except ValueError:
        return 30.0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="AoE2 RTS AI HTTP service")
    parser.add_argument("--host", default=os.environ.get("AOE2_AI_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("AOE2_AI_PORT", "8765")))
    parser.add_argument("--llm-token", default="", help="Upstream model API token (DeepSeek/OpenAI)")
    parser.add_argument("--llm-token-file", default="", help="Read --llm-token from the first line of a file")
    parser.add_argument("--llm-base-url", default="", help="OpenAI-compatible base, e.g. https://api.deepseek.com")
    parser.add_argument("--llm-model", default="", help="Override the model name sent upstream, e.g. qwen3:8b")
    parser.add_argument("--llm-timeout-sec", default="", help="Upstream LLM HTTP timeout (default 30)")
    parser.add_argument("--ai-token", default="", help="Optional Bearer token required from the game")
    parser.add_argument("--backend", default="", help="Force backend: openai | rules_compat")
    return parser


def apply_args(args: argparse.Namespace) -> None:
    token = str(getattr(args, "llm_token", "") or "").strip()
    token_file = str(getattr(args, "llm_token_file", "") or "").strip()
    if token_file:
        path = Path(token_file)
        if not path.is_file():
            raise FileNotFoundError(f"llm token file not found: {path}")
        token = path.read_text(encoding="utf-8").strip().splitlines()[0].strip()
    set_cli(
        llm_token=token,
        llm_base_url=getattr(args, "llm_base_url", ""),
        llm_model=getattr(args, "llm_model", ""),
        llm_timeout_sec=str(getattr(args, "llm_timeout_sec", "") or ""),
        ai_token=getattr(args, "ai_token", ""),
        backend=getattr(args, "backend", ""),
    )
    if token:
        os.environ["AOE2_LLM_TOKEN"] = token
    base = str(getattr(args, "llm_base_url", "") or "").strip()
    if base:
        os.environ["AOE2_LLM_BASE_URL"] = base
    model = str(getattr(args, "llm_model", "") or "").strip()
    if model:
        os.environ["AOE2_LLM_MODEL"] = model
    timeout = str(getattr(args, "llm_timeout_sec", "") or "").strip()
    if timeout:
        os.environ["AOE2_LLM_TIMEOUT_SEC"] = timeout
    game_token = str(getattr(args, "ai_token", "") or "").strip()
    if game_token:
        os.environ["AOE2_AI_TOKEN"] = game_token
    backend_name = str(getattr(args, "backend", "") or "").strip()
    if backend_name:
        os.environ["AOE2_AI_BACKEND"] = backend_name


def mask_secret(value: str) -> str:
    text = value.strip()
    if not text:
        return "MISSING"
    if len(text) <= 8:
        return "set"
    return f"{text[:4]}...{text[-4:]}"
