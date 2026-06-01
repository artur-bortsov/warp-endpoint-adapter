param(
    [string]$InstallDir = (Split-Path -Parent $PSScriptRoot),
    [int]$Port = 8787,
    [string]$BindHost = "0.0.0.0",
    [string]$Hostname = $env:COMPUTERNAME
)

$ErrorActionPreference = "Stop"
$CertDir = Join-Path $InstallDir "certs"
$CertPath = Join-Path $CertDir "$Hostname.pem"
$KeyPath = Join-Path $CertDir "$Hostname-key.pem"
$AdapterPath = Join-Path $InstallDir "adapter.py"
$LogPath = Join-Path $InstallDir "adapter.log"

if (-not (Test-Path $CertPath) -or -not (Test-Path $KeyPath)) {
    & (Join-Path $PSScriptRoot "make_https_cert.ps1") -InstallDir $InstallDir -Hostname $Hostname
}

$Python = Get-Command py -ErrorAction SilentlyContinue
if ($Python) {
    & $Python.Source -3 $AdapterPath --host $BindHost --port $Port --cert $CertPath --key $KeyPath 2>&1 | Tee-Object -FilePath $LogPath -Append
}
else {
    $Python = Get-Command python -ErrorAction Stop
    & $Python.Source $AdapterPath --host $BindHost --port $Port --cert $CertPath --key $KeyPath 2>&1 | Tee-Object -FilePath $LogPath -Append
}
