from __future__ import annotations

from pathlib import Path

from brain import runtime_settings
from brain.llm_proxy import llm_token


def test_cli_llm_token_overrides_env(monkeypatch, tmp_path: Path) -> None:
    runtime_settings.clear_cli()
    monkeypatch.delenv("AOE2_LLM_TOKEN", raising=False)
    args = runtime_settings.build_parser().parse_args(
        ["--host", "0.0.0.0", "--port", "9000", "--llm-token", "sk-from-cli"]
    )
    runtime_settings.apply_args(args)
    try:
        assert args.host == "0.0.0.0"
        assert args.port == 9000
        assert llm_token() == "sk-from-cli"
        assert runtime_settings.mask_secret("sk-from-cli") != "MISSING"
    finally:
        runtime_settings.clear_cli()
        monkeypatch.delenv("AOE2_LLM_TOKEN", raising=False)


def test_cli_llm_token_file(monkeypatch, tmp_path: Path) -> None:
    runtime_settings.clear_cli()
    monkeypatch.delenv("AOE2_LLM_TOKEN", raising=False)
    token_path = tmp_path / "token.txt"
    token_path.write_text("sk-file-token\n", encoding="utf-8")
    args = runtime_settings.build_parser().parse_args(["--llm-token-file", str(token_path)])
    runtime_settings.apply_args(args)
    try:
        assert llm_token() == "sk-file-token"
    finally:
        runtime_settings.clear_cli()
        monkeypatch.delenv("AOE2_LLM_TOKEN", raising=False)
