param(
    [ValidateSet("start", "stop", "restart", "status", "connection", "models", "start-adapter", "stop-adapter", "restart-adapter", "start-tunnel", "stop-tunnel", "restart-tunnel", "help")]
    [string]$Command = "start",
    [int]$Port = 8787
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$AdapterPidFile = Join-Path $Root "adapter.pid"
$TunnelPidFile = Join-Path $Root "cloudflared.pid"
$AdapterLog = Join-Path $Root "adapter.log"
$AdapterOutLog = Join-Path $Root "adapter.out.log"
$AdapterErrLog = Join-Path $Root "adapter.err.log"
$TunnelOutLog = Join-Path $Root "cloudflared.out.log"
$TunnelErrLog = Join-Path $Root "cloudflared.err.log"
$TunnelUrlFile = Join-Path $Root "tunnel_url.txt"
$ReadmePath = Join-Path $Root "README.md"

function Show-Usage {
    Write-Host "Usage: .\adapterctl.ps1 [command]"
    Write-Host "Commands: start, stop, restart, status, connection, models"
    Write-Host "          start-adapter, stop-adapter, restart-adapter"
    Write-Host "          start-tunnel, stop-tunnel, restart-tunnel"
}

function Get-PowershellExe {
    $Pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($Pwsh) {
        $Exe = $Pwsh.Source
    }
    else {
        $Exe = (Get-Command powershell -ErrorAction Stop).Source
    }
    $Exe
}

function Read-PidFile([string]$Path) {
    $PidValue = ""
    if (Test-Path $Path) {
        $PidValue = (Get-Content $Path -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    }
    $PidValue
}

function Test-PidRunning([string]$PidValue) {
    $Running = $false
    if ($PidValue) {
        $Process = Get-Process -Id ([int]$PidValue) -ErrorAction SilentlyContinue
        if ($Process) {
            $Running = $true
        }
    }
    $Running
}

function Start-PowershellScript([string]$ScriptPath, [string[]]$ScriptArguments, [string]$PidFile, [string]$OutLog, [string]$ErrLog) {
    $ExistingPid = Read-PidFile $PidFile
    if (Test-PidRunning $ExistingPid) {
        Write-Host "Already running with PID $ExistingPid"
    }
    else {
        $PowerShellExe = Get-PowershellExe
        $Arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $ScriptArguments
        $Process = Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -WindowStyle Hidden -PassThru
        Set-Content -Path $PidFile -Value $Process.Id -Encoding ASCII
        Write-Host "Started PID $($Process.Id)"
    }
}

function Stop-PidFile([string]$Label, [string]$PidFile) {
    $PidValue = Read-PidFile $PidFile
    if (Test-PidRunning $PidValue) {
        Write-Host "Stopping $Label PID $PidValue ..."
        Stop-Process -Id ([int]$PidValue) -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "$Label is not running."
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

function Start-Adapter {
    $Script = Join-Path $Root "scripts\start_adapter.ps1"
    Start-PowershellScript $Script @("-InstallDir", $Root, "-Port", $Port) $AdapterPidFile $AdapterOutLog $AdapterErrLog
}

function Stop-Adapter {
    Stop-PidFile "adapter" $AdapterPidFile
}

function Start-Tunnel {
    $Script = Join-Path $Root "scripts\run_tunnel.ps1"
    Start-PowershellScript $Script @("-InstallDir", $Root, "-Port", $Port) $TunnelPidFile $TunnelOutLog $TunnelErrLog
    for ($Index = 0; $Index -lt 60; $Index++) {
        if ((Test-Path $TunnelUrlFile) -and ((Get-Content $TunnelUrlFile -ErrorAction SilentlyContinue | Select-Object -First 1))) {
            break
        }
        Start-Sleep -Seconds 1
    }
}

function Stop-Tunnel {
    Stop-PidFile "Cloudflare tunnel" $TunnelPidFile
}

function Get-TunnelUrl {
    $TunnelUrl = ""
    if (Test-Path $TunnelUrlFile) {
        $TunnelUrl = (Get-Content $TunnelUrlFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    }
    $TunnelUrl
}

function Show-Status {
    $AdapterPid = Read-PidFile $AdapterPidFile
    $TunnelPid = Read-PidFile $TunnelPidFile
    if (Test-PidRunning $AdapterPid) {
        Write-Host "Adapter: running (PID $AdapterPid, https://localhost:$Port)"
    }
    else {
        Write-Host "Adapter: stopped"
    }
    if (Test-PidRunning $TunnelPid) {
        Write-Host "Cloudflare tunnel: running (PID $TunnelPid)"
    }
    else {
        Write-Host "Cloudflare tunnel: stopped"
    }
    $TunnelUrl = Get-TunnelUrl
    if ($TunnelUrl) {
        Write-Host "Tunnel URL: $TunnelUrl"
        Write-Host "Tunnel URL file: $TunnelUrlFile"
        Write-Host "Warp Base URL: $TunnelUrl/v1"
    }
}

function Show-Connection {
    $TunnelUrl = Get-TunnelUrl
    if ($TunnelUrl) {
        $BaseUrl = "$TunnelUrl/v1"
    }
    else {
        $BaseUrl = "https://<start-the-tunnel-first>/v1"
    }
    Write-Host "Warp connection:"
    Write-Host "  API type/provider: OpenAI-compatible custom endpoint"
    Write-Host "  Base URL: $BaseUrl"
    Write-Host "  API key: your Kie API key"
    Write-Host "  Custom headers: none"
    Write-Host "  README: $ReadmePath"
    Write-Host "  Tunnel URL file: $TunnelUrlFile"
}

function Get-PythonExe {
    $Python = Get-Command py -ErrorAction SilentlyContinue
    if ($Python) {
        $Exe = $Python.Source
    }
    else {
        $Python = Get-Command python -ErrorAction Stop
        $Exe = $Python.Source
    }
    $Exe
}

function Show-Models {
    $PythonExe = Get-PythonExe
    $AdapterPath = Join-Path $Root "adapter.py"
    $Script = @'
import importlib.util
import pathlib
import sys

adapter_path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("warp_kie_adapter", adapter_path)
if spec is None or spec.loader is None:
    raise SystemExit("Unable to load adapter.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

print("Model IDs accepted by this adapter:")
for model in module.openai_model_catalog():
    print("  " + model["id"])
print()
print("No API key is required for this list. Warp still sends your Kie API key as the bearer token for chat requests.")
'@

    $TempScript = New-TemporaryFile
    try {
        Set-Content -Path $TempScript -Value $Script -Encoding UTF8
        if ((Split-Path -Leaf $PythonExe) -ieq "py.exe") {
            & $PythonExe -3 $TempScript $AdapterPath
        }
        else {
            & $PythonExe $TempScript $AdapterPath
        }
    }
    finally {
        Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
    }
}

switch ($Command) {
    "start" { Start-Adapter; Start-Tunnel; Show-Connection }
    "stop" { Stop-Tunnel; Stop-Adapter }
    "restart" { Stop-Tunnel; Stop-Adapter; Start-Adapter; Start-Tunnel; Show-Connection }
    "status" { Show-Status }
    "connection" { Show-Connection }
    "models" { Show-Models }
    "start-adapter" { Start-Adapter }
    "stop-adapter" { Stop-Adapter }
    "restart-adapter" { Stop-Adapter; Start-Adapter }
    "start-tunnel" { Start-Tunnel; Show-Connection }
    "stop-tunnel" { Stop-Tunnel }
    "restart-tunnel" { Stop-Tunnel; Start-Tunnel; Show-Connection }
    "help" { Show-Usage }
}
