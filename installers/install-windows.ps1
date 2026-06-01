param(
    [string]$InstallDir = "$env:LOCALAPPDATA\warp-kie-adapter",
    [ValidateSet("manual", "service")]
    [string]$Mode = "",
    [ValidateSet("adapter", "tunnel", "both")]
    [string]$Components = "",
    [switch]$Yes,
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
$SourceDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Read-ChoiceValue([string]$Prompt, [string]$DefaultValue) {
    $Value = $DefaultValue
    if (-not $Yes) {
        $Typed = Read-Host "$Prompt [$DefaultValue]"
        if ($Typed) {
            $Value = $Typed
        }
    }
    $Value
}

function Ensure-Command([string]$CommandName, [string]$WingetId) {
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "Installing $CommandName using winget package $WingetId ..."
            winget install --id $WingetId -e --accept-package-agreements --accept-source-agreements
        }
        else {
            throw "$CommandName is required, and winget is not available to install it automatically."
        }
    }
}

function Copy-Project([string]$From, [string]$To) {
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    Get-ChildItem -Path $From -Force | Where-Object {
        $_.Name -notin @(".git", ".github", "certs", "dist", "adapter.log", "cloudflared.log", "adapter.pid", "cloudflared.pid", "tunnel_url.txt")
    } | ForEach-Object {
        $Destination = Join-Path $To $_.Name
        if ($_.PSIsContainer) {
            Copy-Item $_.FullName $Destination -Recurse -Force
        }
        else {
            Copy-Item $_.FullName $Destination -Force
        }
    }
}

function Contains-Component([string]$Name) {
    $Components -eq "both" -or $Components -eq $Name
}

function Install-CloudflaredLocal([string]$To) {
    $BinDir = Join-Path $To "bin"
    $ExePath = Join-Path $BinDir "cloudflared.exe"
    if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue) -and -not (Test-Path $ExePath)) {
        New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
        $Architecture = if ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq "Arm64") { "arm64" } else { "amd64" }
        $Url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-$Architecture.exe"
        Write-Host "Downloading cloudflared to $ExePath ..."
        Invoke-WebRequest -Uri $Url -OutFile $ExePath
    }
}

function Register-AdapterTask([string]$To) {
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$To\adapterctl.ps1`" start-adapter"
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName "WarpKieAdapter-Adapter" -Action $Action -Trigger $Trigger -Description "Start the Warp Kie.ai HTTPS adapter at logon." -Force | Out-Null
    if (-not $NoStart) {
        Start-ScheduledTask -TaskName "WarpKieAdapter-Adapter"
    }
}

function Register-TunnelTask([string]$To) {
    $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$To\adapterctl.ps1`" start-tunnel"
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName "WarpKieAdapter-Tunnel" -Action $Action -Trigger $Trigger -Description "Start Cloudflare Tunnel for Warp Kie.ai adapter at logon." -Force | Out-Null
    if (-not $NoStart) {
        Start-ScheduledTask -TaskName "WarpKieAdapter-Tunnel"
    }
}

if (-not $Mode) {
    $Mode = Read-ChoiceValue "Usage mode: manual or service" "manual"
}
if (-not $Components) {
    $Components = Read-ChoiceValue "Components: adapter, tunnel, or both" "both"
}
$InstallDir = Read-ChoiceValue "Install directory" $InstallDir

Ensure-Command "python" "Python.Python.3.12"
Ensure-Command "openssl" "ShiningLight.OpenSSL.Light"
if (Contains-Component "tunnel") {
    Install-CloudflaredLocal $InstallDir
}

Copy-Project $SourceDir $InstallDir
& (Join-Path $InstallDir "scripts\make_https_cert.ps1") -InstallDir $InstallDir

if ($Mode -eq "service") {
    if (Contains-Component "adapter") {
        Register-AdapterTask $InstallDir
    }
    if (Contains-Component "tunnel") {
        Register-TunnelTask $InstallDir
    }
}

Write-Host ""
Write-Host "Installed to: $InstallDir"
Write-Host "README: $InstallDir\README.md"
Write-Host "Tunnel URL file: $InstallDir\tunnel_url.txt"
Write-Host ""
if ($Mode -eq "manual") {
    Write-Host "Manual commands:"
    Write-Host "  cd `"$InstallDir`""
    Write-Host "  .\adapterctl.ps1 start"
    Write-Host "  .\adapterctl.ps1 connection"
    Write-Host "  .\adapterctl.ps1 stop"
}
else {
    Write-Host "Service tasks: WarpKieAdapter-Adapter and/or WarpKieAdapter-Tunnel"
    Write-Host "Status: .\adapterctl.ps1 status"
    Write-Host "Connection: .\adapterctl.ps1 connection"
}
Write-Host ""
Write-Host "Warp API key: use your Kie API key. No local Kie key file is required."
