param(
    [ValidateSet("start", "tunnel", "adapter", "adapter-only", "stop", "down", "restart", "status", "ps", "url", "connection", "logs", "test", "help")]
    [string]$Command = "start",
    [int]$Port = 8788
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$UrlFile = Join-Path $RepoRoot "docker-data\tunnel_url.txt"

function Show-Usage {
    Write-Host "Usage: .\docker\docker-quick-start.ps1 [command] [-Port 8788]"
    Write-Host ""
    Write-Host "Default command:"
    Write-Host "  start              Build and start adapter + Cloudflare Tunnel in the background."
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  start              Build and start adapter + tunnel, then print Warp settings."
    Write-Host "  adapter            Build and start only the local adapter."
    Write-Host "  stop               Stop and remove adapter/tunnel containers for this project."
    Write-Host "  restart            Stop, then start adapter + tunnel."
    Write-Host "  status             Show Docker Compose service status and current tunnel URL."
    Write-Host "  url                Print the current tunnel URL and Warp Base URL."
    Write-Host "  logs               Follow Docker Compose logs."
    Write-Host "  test               Test local and public health/models endpoints."
    Write-Host "  help               Show this help."
    Write-Host ""
    Write-Host "The default host port is 8788 to avoid conflicts with a non-Docker adapter on 8787."
}

function Show-DependencyHelp {
    Write-Host ""
    Write-Host "What to do next:"
    Write-Host "  - macOS/Windows: install or start Docker Desktop, then rerun this script."
    Write-Host "  - Linux: install Docker Engine and the Compose plugin."
    Write-Host ""
    Write-Host "Ubuntu/Debian example:"
    Write-Host "  sudo apt-get update"
    Write-Host "  sudo apt-get install -y docker.io docker-compose-v2"
    Write-Host "  sudo systemctl enable --now docker"
    Write-Host "  sudo usermod -aG docker `"`$USER`""
    Write-Host ""
    Write-Host "After adding yourself to the docker group, sign out and sign in again."
    Write-Host "Some distributions use docker-compose-plugin instead of docker-compose-v2."
}

function Stop-WithHelp([string]$Message) {
    Write-Host "ERROR: $Message"
    Show-DependencyHelp
    exit 1
}

function Test-Dependencies {
    $Docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $Docker) {
        Stop-WithHelp "Docker is not installed or is not in PATH."
    }

    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-WithHelp "Docker is installed, but the Docker daemon is not reachable. Docker Desktop may not be running, or this user may not have Docker permissions."
    }

    & docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-WithHelp "Docker is installed, but the Docker Compose plugin is missing."
    }
}

function Invoke-Compose([string[]]$Arguments) {
    Push-Location $RepoRoot
    try {
        $env:ADAPTER_HOST_PORT = [string]$Port
        & docker compose @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Remove-Item Env:ADAPTER_HOST_PORT -ErrorAction SilentlyContinue
        Pop-Location
    }
}

function Get-TunnelUrl {
    $Url = ""
    if (Test-Path $UrlFile) {
        $Url = (Get-Content $UrlFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    }
    $Url
}

function Wait-TunnelUrl {
    $Deadline = (Get-Date).AddSeconds(90)
    $Url = ""
    while ((-not $Url) -and ((Get-Date) -lt $Deadline)) {
        $Url = Get-TunnelUrl
        if (-not $Url) {
            Start-Sleep -Seconds 1
        }
    }
    $Url
}

function Show-WarpSettings {
    $Url = Get-TunnelUrl
    if ($Url) {
        Write-Host ""
        Write-Host "Warp settings:"
        Write-Host "  API type/provider: OpenAI-compatible custom endpoint"
        Write-Host "  Base URL: $Url/v1"
        Write-Host "  API key: your Kie API key"
        Write-Host "  Custom headers: none"
        Write-Host "  Recommended model ID: claude-opus-4-8"
        Write-Host ""
        Write-Host "The tunnel URL is saved in:"
        Write-Host "  docker-data\tunnel_url.txt"
    }
    else {
        Write-Host ""
        Write-Host "The adapter is running locally at:"
        Write-Host "  https://localhost:$Port/v1"
        Write-Host ""
        Write-Host "No Cloudflare Tunnel URL is available yet. If Warp cannot use localhost, run:"
        Write-Host "  .\docker\docker-quick-start.ps1 start"
    }
}

function Start-AdapterOnly {
    Test-Dependencies
    Write-Host "Building and starting the adapter container on https://localhost:$Port/v1 ..."
    Invoke-Compose @("up", "--build", "-d", "adapter")
    Write-Host ""
    Invoke-Compose @("ps")
    Show-WarpSettings
}

function Start-WithTunnel {
    Test-Dependencies
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $UrlFile) | Out-Null
    Remove-Item $UrlFile -Force -ErrorAction SilentlyContinue
    Write-Host "Building and starting the adapter + Cloudflare Tunnel containers..."
    Invoke-Compose @("--profile", "tunnel", "up", "--build", "-d")
    Write-Host ""
    Invoke-Compose @("--profile", "tunnel", "ps")
    Write-Host ""
    Write-Host "Waiting for Cloudflare to publish the quick-tunnel URL..."
    $Url = Wait-TunnelUrl
    if ($Url) {
        Show-WarpSettings
    }
    else {
        Write-Host "The containers started, but no tunnel URL was written within 90 seconds."
        Write-Host "Check logs with:"
        Write-Host "  .\docker\docker-quick-start.ps1 logs"
        exit 1
    }
}

function Stop-Stack {
    Test-Dependencies
    Write-Host "Stopping Docker Compose services for this project..."
    Invoke-Compose @("--profile", "tunnel", "down")
}

function Show-Status {
    Test-Dependencies
    Invoke-Compose @("--profile", "tunnel", "ps")
    Show-WarpSettings
}

function Show-Logs {
    Test-Dependencies
    Invoke-Compose @("--profile", "tunnel", "logs", "--tail=120", "-f")
}

function Test-Endpoint([string]$Label, [string]$Url, [string[]]$CurlArguments) {
    $Curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $Curl) {
        Write-Host "curl.exe is not installed, so endpoint tests were skipped."
    }
    else {
        $TempFile = Join-Path $env:TEMP "warp-kie-docker-test.json"
        $Arguments = $CurlArguments + @("-o", $TempFile, "-w", "%{http_code}", "--max-time", "30", $Url)
        $Status = & curl.exe @Arguments 2>$null
        Write-Host "$Label`: $Status"
        if ((Test-Path $TempFile) -and ($Label.EndsWith("models"))) {
            try {
                $Data = Get-Content $TempFile -Raw | ConvertFrom-Json
                $ModelCount = @($Data.data).Count
                $HasOpus = @($Data.data | Where-Object { $_.id -eq "claude-opus-4-8" }).Count -gt 0
                Write-Host "$Label`: model_count=$ModelCount, has_claude_opus_4_8=$($HasOpus.ToString().ToLowerInvariant())"
            }
            catch {
                Write-Host "$Label`: response was not valid model JSON"
            }
        }
    }
}

function Test-Stack {
    Test-Dependencies
    Test-Endpoint "local health" "https://localhost:$Port/v1/healthz" @("-sk")
    Test-Endpoint "local models" "https://localhost:$Port/v1/models" @("-sk")
    $Url = Get-TunnelUrl
    if ($Url) {
        Test-Endpoint "public health" "$Url/v1/healthz" @("-sS")
        Test-Endpoint "public models" "$Url/v1/models" @("-sS")
    }
    else {
        Write-Host "No public tunnel URL found yet."
    }
}

switch ($Command) {
    "start" { Start-WithTunnel }
    "tunnel" { Start-WithTunnel }
    "adapter" { Start-AdapterOnly }
    "adapter-only" { Start-AdapterOnly }
    "stop" { Stop-Stack }
    "down" { Stop-Stack }
    "restart" { Stop-Stack; Start-WithTunnel }
    "status" { Show-Status }
    "ps" { Show-Status }
    "url" { Show-WarpSettings }
    "connection" { Show-WarpSettings }
    "logs" { Show-Logs }
    "test" { Test-Stack }
    "help" { Show-Usage }
}
