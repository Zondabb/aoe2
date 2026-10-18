# Forward AoE2 AI vs AI traffic to local Ollama qwen3:8b, and print LLM I/O.
# Usage:  .\start_qwen3_proxy.ps1

param(
    [int]$ListenPort = 8765,
    [int]$NumCtx = 8192
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
$env:AOE2_LLM_NUM_CTX = [string]$NumCtx
try { chcp 65001 | Out-Null } catch {}

function Get-PortOwner([int]$Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $conn) { return $null }
    try {
        return Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)" -ErrorAction Stop
    } catch {
        return $null
    }
}

function Clear-ListenPort([int]$Port) {
    $owner = Get-PortOwner $Port
    if (-not $owner) { return }

    $cmd = [string]$owner.CommandLine
    $isOurService = $cmd -match "ai_service_python" -or $cmd -match "main\.py.*--port\s+$Port"
    Write-Host "Port $Port is in use by PID $($owner.ProcessId) ($($owner.Name))."
    if ($isOurService) {
        Write-Host "Stopping previous AI service instance..."
        Stop-Process -Id $owner.ProcessId -Force
        Start-Sleep -Seconds 1
        if (Get-PortOwner $Port) {
            throw "Port $Port still busy after stopping PID $($owner.ProcessId)."
        }
        Write-Host "Port $Port freed."
        Write-Host ""
        return
    }
    throw "Port $Port is held by another process. Stop it or change --port. PID=$($owner.ProcessId) CMD=$cmd"
}

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

Clear-ListenPort $ListenPort

Write-Host "Upstream: http://127.0.0.1:11434/v1  model=qwen3:8b"
Write-Host "Listen:   http://127.0.0.1:$ListenPort"
Write-Host "Role planning: native Ollama JSON schema, thinking off, context=$NumCtx, concurrency=1"
Write-Host "LLM inputs, outputs and applied plan changes: logs/multi_agent.jsonl"
Write-Host ""

& .\.venv\Scripts\python.exe main.py `
    --host 127.0.0.1 `
    --port $ListenPort `
    --backend openai `
    --llm-base-url "http://127.0.0.1:11434/v1" `
    --llm-model "qwen3:8b" `
    --llm-token ollama `
    --llm-timeout-sec 90
