from __future__ import annotations

from pathlib import Path
import json
import os
import subprocess
import sys

import pytest

from brain import runtime_settings
from brain.llm_proxy import build_openai_payload, llm_token, upstream_model
from protocol.models import ChatCompletionRequest


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


def test_llm_model_override_replaces_game_model(monkeypatch) -> None:
    runtime_settings.clear_cli()
    monkeypatch.delenv("AOE2_LLM_MODEL", raising=False)
    monkeypatch.setenv("AOE2_LLM_BASE_URL", "http://127.0.0.1:11434/v1")
    args = runtime_settings.build_parser().parse_args(["--llm-model", "qwen3:8b"])
    runtime_settings.apply_args(args)
    try:
        req = ChatCompletionRequest.model_validate(
            {"model": "deepseek-v4-flash-0731", "messages": [{"role": "user", "content": "plan"}]}
        )
        assert upstream_model(req) == "qwen3:8b"
        payload = build_openai_payload(req)
        assert payload["model"] == "qwen3:8b"
        # Legacy requests retain the OpenAI shape. Native thinking controls are
        # applied only to the multi-agent propose_plan transport.
        assert "think" not in payload
    finally:
        runtime_settings.clear_cli()
        monkeypatch.delenv("AOE2_LLM_MODEL", raising=False)
        monkeypatch.delenv("AOE2_LLM_BASE_URL", raising=False)


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


def test_config_local_environment_and_cli_precedence(monkeypatch, tmp_path):
    config = tmp_path / "custom.toml"
    config.write_text('[service]\nhost="0.0.0.0"\nport=9001\n[llm]\nmodel="base"\nmax_tokens=500\n', encoding="utf-8")
    local = tmp_path / "custom.local.toml"
    local.write_text('[llm]\nmodel="local"\ntemperature=0.6\n', encoding="utf-8")
    runtime_settings.load_config(config)
    assert runtime_settings.llm_model() == "local"
    assert runtime_settings.llm_max_tokens() == 500
    assert runtime_settings.llm_temperature() == 0.6
    assert runtime_settings.llm_num_ctx() == 8192
    monkeypatch.setenv("AOE2_LLM_MODEL", "environment")
    assert runtime_settings.llm_model() == "environment"
    args = runtime_settings.build_parser().parse_args(["--config", str(config), "--llm-model", "cli"])
    runtime_settings.apply_args(args)
    assert runtime_settings.llm_model() == "cli"
    assert args.host == "0.0.0.0" and args.port == 9001
    # Applying CLI arguments must not mutate the caller's environment.
    assert os.environ["AOE2_LLM_MODEL"] == "environment"


def test_default_config_does_not_depend_on_working_directory(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    runtime_settings.load_config()
    assert runtime_settings.config_path() == runtime_settings.DEFAULT_CONFIG_PATH
    assert runtime_settings.llm_model() == "qwen3:8b"
    assert runtime_settings.backend() == "openai"
    assert runtime_settings.llm_temperature() == 0.2


def test_uvicorn_import_loads_environment_selected_config(tmp_path):
    config = tmp_path / "uvicorn.toml"
    config.write_text('[llm]\nmodel="import-model"\nmax_tokens=321\n', encoding="utf-8")
    env = dict(os.environ, AOE2_AI_CONFIG=str(config), PYTHONPATH=str(runtime_settings.SERVICE_DIR))
    script = ('import main, json; from brain import runtime_settings as s; '
              'print(json.dumps({"model": s.llm_model(), "tokens": s.llm_max_tokens()}))')
    process = subprocess.run([sys.executable, "-c", script], cwd=tmp_path, env=env,
                             capture_output=True, text=True, check=True)
    assert json.loads(process.stdout.strip().splitlines()[-1]) == {"model": "import-model", "tokens": 321}


@pytest.mark.parametrize("invalid_source", ["missing_env", "malformed_env", "malformed_default"])
def test_cli_config_is_selected_before_lower_priority_files(tmp_path, invalid_source):
    config = tmp_path / "good.toml"
    config.write_text('[llm]\nmodel="cli-config-model"\n', encoding="utf-8")
    broken = tmp_path / "broken.toml"
    if invalid_source != "missing_env":
        broken.write_text('[llm]\nmodel="unterminated', encoding="utf-8")
    env = dict(os.environ, PYTHONPATH=str(runtime_settings.SERVICE_DIR))
    if invalid_source == "malformed_default":
        env.pop("AOE2_AI_CONFIG", None)
    else:
        env["AOE2_AI_CONFIG"] = str(broken)
    # Run the real main.py __main__ branch and argument parser in a fresh
    # interpreter. Replace only the final server loop: no ports or providers.
    script = (
        "import json, pathlib, runpy, sys, uvicorn; "
        "from brain import runtime_settings as settings; "
        f"settings.DEFAULT_CONFIG_PATH = pathlib.Path({str(broken)!r}); "
        "uvicorn.run = lambda *a, **kw: print(json.dumps({'model': settings.llm_model()})); "
        f"sys.argv = [{str(runtime_settings.SERVICE_DIR / 'main.py')!r}, '--config', {str(config)!r}]; "
        f"runpy.run_path({str(runtime_settings.SERVICE_DIR / 'main.py')!r}, run_name='__main__')"
    )
    process = subprocess.run([sys.executable, "-c", script], cwd=tmp_path, env=env,
                             capture_output=True, text=True, check=True)
    assert json.loads(process.stdout.strip().splitlines()[-1]) == {"model": "cli-config-model"}


def test_service_and_provider_tokens_are_independent(monkeypatch, tmp_path):
    config = tmp_path / "tokens.toml"
    config.write_text('[service]\napi_token="game-test"\n[llm]\ntoken="provider-test"\n', encoding="utf-8")
    runtime_settings.load_config(config)
    assert runtime_settings.ai_token() == "game-test"
    assert runtime_settings.llm_token() == "provider-test"
    assert runtime_settings.mask_secret("provider-test") == "set"
    monkeypatch.setenv("AOE2_LLM_TOKEN", "provider-env")
    assert runtime_settings.llm_token() == "provider-env"
    assert runtime_settings.ai_token() == "game-test"


def test_log_observation_has_service_side_false_override(monkeypatch, tmp_path):
    config = tmp_path / "logging.toml"
    config.write_text('[service]\nlog_observation=true\n', encoding="utf-8")
    runtime_settings.load_config(config)
    assert runtime_settings.log_observation() is True
    monkeypatch.setenv("AOE2_AI_LOG_OBSERVATION", "false")
    assert runtime_settings.log_observation() is False
    runtime_settings.set_cli(log_observation=True)
    assert runtime_settings.log_observation() is True


def test_explicit_missing_config_is_an_error(tmp_path):
    with pytest.raises(FileNotFoundError, match="configuration file not found"):
        runtime_settings.load_config(tmp_path / "missing.toml")


def test_malformed_config_does_not_disclose_secret(tmp_path):
    config = tmp_path / "broken.toml"
    config.write_text('[llm]\ntoken="private-test-secret', encoding="utf-8")
    with pytest.raises(ValueError) as raised:
        runtime_settings.load_config(config)
    assert "private-test-secret" not in str(raised.value)


@pytest.mark.parametrize("name, configured, expected", [
    ("llm_max_tokens", "NaN", 2048), ("llm_max_tokens", "999999", 32768),
    ("llm_temperature", "Infinity", 0.2), ("llm_timeout_sec", "-1", 2),
])
def test_generation_parameters_are_finite_and_bounded(name, configured, expected):
    runtime_settings.set_cli(**{name: configured})
    assert getattr(runtime_settings, name)() == expected


def test_service_log_directory_follows_config_and_override_precedence(monkeypatch, tmp_path):
    config = tmp_path / "model-a.toml"
    config.write_text('[service]\nlog_dir="logs/model-a"\n', encoding="utf-8")
    runtime_settings.load_config(config)
    monkeypatch.chdir(tmp_path.parent)
    assert runtime_settings.log_dir() == tmp_path / "logs" / "model-a"
    monkeypatch.setenv("AOE2_AI_LOG_DIR", "logs/environment")
    assert runtime_settings.log_dir() == tmp_path / "logs" / "environment"
    args = runtime_settings.build_parser().parse_args(["--config", str(config), "--log-dir", "logs/cli"])
    runtime_settings.apply_args(args)
    assert runtime_settings.log_dir() == tmp_path / "logs" / "cli"


def test_two_service_processes_write_separate_model_logs(tmp_path):
    for model in ("model-a", "model-b"):
        config = tmp_path / f"{model}.toml"
        config.write_text(f'[service]\nlog_dir="logs/{model}"\n[llm]\nbackend="rules_compat"\n', encoding="utf-8")
        env = dict(os.environ, AOE2_AI_CONFIG=str(config), PYTHONPATH=str(runtime_settings.SERVICE_DIR))
        script = ("import main; "
                  f"main._write_multi_agent_event('isolation', {{'model': {model!r}}}); "
                  f"main._write_llm_json('isolation', {{'model': {model!r}}})")
        subprocess.run([sys.executable, "-c", script], cwd=tmp_path, env=env,
                       capture_output=True, text=True, check=True)
    for model, other in (("model-a", "model-b"), ("model-b", "model-a")):
        for name in ("multi_agent.jsonl", "llm.log"):
            content = (tmp_path / "logs" / model / name).read_text(encoding="utf-8")
            assert model in content and other not in content


def test_ai_runtime_defaults_to_the_baseline_and_follows_file_env_and_cli(monkeypatch, tmp_path: Path) -> None:
    assert runtime_settings.ai_runtime() == "multi_agent"
    config = tmp_path / "runtime.toml"
    config.write_text('[ai]\nruntime = "cabinet"\n[llm]\nbackend = "rules_compat"\n', encoding="utf-8")
    runtime_settings.load_config(config)
    assert runtime_settings.ai_runtime() == "cabinet"
    monkeypatch.setenv("AOE2_AI_RUNTIME", " Multi_Agent ")
    assert runtime_settings.ai_runtime() == "multi_agent"
    args = runtime_settings.build_parser().parse_args(["--config", str(config), "--runtime", "cabinet"])
    runtime_settings.apply_args(args)
    assert runtime_settings.ai_runtime() == "cabinet"


def test_unknown_ai_runtime_is_refused_at_startup(monkeypatch, tmp_path: Path) -> None:
    config = tmp_path / "runtime.toml"
    config.write_text('[ai]\nruntime = "cabinnet"\n', encoding="utf-8")
    runtime_settings.load_config(config)
    with pytest.raises(ValueError, match="Unknown AI runtime: 'cabinnet'"):
        runtime_settings.ai_runtime()
    args = runtime_settings.build_parser().parse_args(["--config", str(config)])
    with pytest.raises(ValueError, match="expected one of: multi_agent, cabinet"):
        runtime_settings.apply_args(args)
    config.write_text('[ai]\nmodel = "x"\n', encoding="utf-8")
    with pytest.raises(ValueError, match="Unknown AI configuration option: ai.model"):
        runtime_settings.load_config(config)
