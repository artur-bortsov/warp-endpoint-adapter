param(
    [string]$InstallDir = (Split-Path -Parent $PSScriptRoot),
    [int]$Port = 8787
)

$ErrorActionPreference = "Stop"
$TunnelRunner = Join-Path $InstallDir "scripts\tunnel_service.py"
$LogPath = Join-Path $InstallDir "cloudflared.log"
$UrlFile = Join-Path $InstallDir "tunnel_url.txt"
$BundledCloudflared = Join-Path $InstallDir "bin\cloudflared.exe"
$Cloudflared = "cloudflared"

if (Test-Path $BundledCloudflared) {
    $Cloudflared = $BundledCloudflared
}

$Python = Get-Command py -ErrorAction SilentlyContinue
if ($Python) {
    & $Python.Source -3 $TunnelRunner --target "https://localhost:$Port" --log $LogPath --url-file $UrlFile --cloudflared $Cloudflared
}
else {
    $Python = Get-Command python -ErrorAction Stop
    & $Python.Source $TunnelRunner --target "https://localhost:$Port" --log $LogPath --url-file $UrlFile --cloudflared $Cloudflared
}
