# Start the Python AI service using config.toml (default: local Ollama qwen3:8b).
# Usage:  .\start_qwen3_proxy.ps1

param(
    [int]$ListenPort = 0,
    [int]$NumCtx = 0,
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
# One 8B model serves all seven roles and both teams. Concurrent requests contend
# for the same GPU and can outlive the 180-game-second plan validity window.
$env:AOE2_AI_MODEL_CONCURRENCY = "1"
$env:AOE2_AI_MODEL_CONCURRENCY_PER_MATCH = "1"
$env:AOE2_AI_MODEL_CALLS_PER_MINUTE = "6"
if ($NumCtx -gt 0) { $env:AOE2_LLM_NUM_CTX = [string]$NumCtx }
try { chcp 65001 | Out-Null } catch {}

if (-not (Test-Path ".\.venv\Scripts\python.exe")) {
    Write-Host "Creating .venv ..."
    if (Test-Path "E:\ProgramData\miniconda3\python.exe") {
        & "E:\ProgramData\miniconda3\python.exe" -m venv .venv
    } else {
        python -m venv .venv
    }
    .\.venv\Scripts\python.exe -m pip install -U pip
    .\.venv\Scripts\python.exe -m pip install -r requirements.txt
}

Write-Host "Upstream model and generation settings: config.toml / config.local.toml (see service startup log)"
Write-Host "Listen:   from selected configuration (or explicit -ListenPort)"
Write-Host "Local role planning: native Ollama JSON schema, thinking off, concurrency=1"
Write-Host "LLM inputs, outputs and applied plan changes: logs/multi_agent.jsonl"
Write-Host ""

$serviceArgs = @("main.py")
if ($ListenPort -gt 0) { $serviceArgs += @("--port", [string]$ListenPort) }
if ($ConfigPath) { $serviceArgs += @("--config", $ConfigPath) }
& .\.venv\Scripts\python.exe @serviceArgs
