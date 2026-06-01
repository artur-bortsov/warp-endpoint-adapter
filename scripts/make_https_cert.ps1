param(
    [string]$InstallDir = (Split-Path -Parent $PSScriptRoot),
    [string]$Hostname = $env:COMPUTERNAME
)

$ErrorActionPreference = "Stop"
$CertDir = Join-Path $InstallDir "certs"
$CertPath = Join-Path $CertDir "$Hostname.pem"
$KeyPath = Join-Path $CertDir "$Hostname-key.pem"

if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    throw "OpenSSL is required to generate the local HTTPS certificate. Install OpenSSL and rerun this script."
}

New-Item -ItemType Directory -Force -Path $CertDir | Out-Null
& openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes -keyout $KeyPath -out $CertPath -subj "/CN=$Hostname" -addext "subjectAltName=DNS:$Hostname"

Write-Host "Created certificate: $CertPath"
Write-Host "Created private key: $KeyPath"
Write-Host "Host URL: https://$Hostname`:8787/v1"
