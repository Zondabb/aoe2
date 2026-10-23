"""Isolate server configuration and keep unit tests away from real providers."""
from __future__ import annotations

import os

import pytest

from brain import runtime_settings


@pytest.fixture(autouse=True)
def isolated_server_settings(monkeypatch, tmp_path):
    # Individual tests explicitly opt into the mocked OpenAI transport. Do not
    # inherit developer credentials, a local override, or an actual model URL.
    for name in tuple(os.environ):
        if name.startswith(("AOE2_LLM_", "AOE2_AI_")):
            monkeypatch.delenv(name, raising=False)
    path = tmp_path / "test-service.toml"
    path.write_text('[llm]\nbackend = "rules_compat"\n', encoding="utf-8")
    runtime_settings.clear_cli()
    runtime_settings.load_config(path)
    yield
    runtime_settings.clear_cli()
    runtime_settings.load_config(path)
