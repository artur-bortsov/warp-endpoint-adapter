# Docker Quick Start Guide

This guide is for users who want to run the adapter as containers instead of installing Python services on the host.

The easiest path is:

1. Install and start Docker.
2. Open a terminal in this repository folder.
3. Run one quick-start script.
4. Copy the printed Warp settings into Warp.

## What the containers do
- `adapter` runs the OpenAI-compatible HTTPS adapter.
- `tunnel` is optional. It runs a Cloudflare quick tunnel and gives you a public HTTPS URL that Warp can use.

Use the tunnel mode if Warp cannot use `localhost`, an IP address, or plain HTTP for custom endpoints.

## What you need
You do not need Python or OpenSSL installed on your computer for the Docker setup. They are inside the container image.

You need:
- Docker Desktop on macOS or Windows, or Docker Engine on Linux.
- Docker Compose plugin, available as `docker compose`.
- Internet access so Docker can download base images and the tunnel image can download `cloudflared`.
- A Kie API key. You enter it in Warp, not in Docker.

The adapter image does not store your Kie API key. Warp sends your Kie key as the request bearer token, and the adapter forwards it to Kie for that request.

## Step 1: Start Docker
On macOS or Windows:
- Open Docker Desktop.
- Wait until Docker says it is running.

On Linux:
- Make sure the Docker service is running.
- Make sure your user can run Docker commands.

Check:

```bash
docker --version
docker compose version
docker info
```

If Docker is missing or not reachable, the quick-start script prints next-step guidance instead of failing silently.

## Step 2: Open a terminal in the repository root
The repository root is the folder that contains:
- `Dockerfile`
- `docker-compose.yml`
- `README.md`
- `docker/`

If you downloaded a release ZIP, extract it first, then open a terminal in the extracted folder.

## Step 3: Choose how to run it
There are two common modes.

### Recommended for Warp: adapter plus Cloudflare Tunnel
This starts both containers in the background and prints the Warp connection settings.

macOS/Linux:

```bash
./docker/docker-quick-start.sh start
```

Windows PowerShell:

```powershell
.\docker\docker-quick-start.ps1 start
```

The script:
- checks Docker is installed,
- checks Docker is running,
- checks Docker Compose is available,
- builds the images,
- starts the adapter and tunnel containers,
- waits for Cloudflare to publish a quick-tunnel URL,
- prints the Warp Base URL.

The tunnel URL is also saved to:

```text
docker-data/tunnel_url.txt
```

The Warp Base URL is the tunnel URL plus `/v1`, for example:

```text
https://example-words.trycloudflare.com/v1
```

### Local adapter only
Use this if your Warp setup can call a local HTTPS endpoint.

macOS/Linux:

```bash
./docker/docker-quick-start.sh adapter
```

Windows PowerShell:

```powershell
.\docker\docker-quick-start.ps1 adapter
```

Default local Base URL:

```text
https://localhost:8788/v1
```

The helper uses host port `8788` by default to avoid conflicts with a non-Docker adapter that may use `8787`.

To use a different port:

macOS/Linux:

```bash
ADAPTER_HOST_PORT=8790 ./docker/docker-quick-start.sh start
```

Windows PowerShell:

```powershell
.\docker\docker-quick-start.ps1 start -Port 8790
```

## Step 4: Configure Warp
In Warp custom endpoint settings, use:

- API type/provider: OpenAI-compatible custom endpoint
- Base URL: the script output, usually `https://<current-trycloudflare-host>/v1`
- API key: your Kie API key
- Custom headers: none
- Recommended model ID: `claude-opus-4-8`

You can also use direct Kie model IDs such as:

```text
claude-opus-4-8
claude-opus-4-7
claude-opus-4-6
claude-sonnet-4-6
claude-opus-4-5
claude-sonnet-4-5
claude-haiku-4-5
```

Leave Warp credit fallback disabled if you want endpoint failures to stay visible instead of being retried against another Warp model.

## Step 5: Verify the containers
macOS/Linux:

```bash
./docker/docker-quick-start.sh status
./docker/docker-quick-start.sh test
```

Windows PowerShell:

```powershell
.\docker\docker-quick-start.ps1 status
.\docker\docker-quick-start.ps1 test
```

Expected checks:
- local health returns `200`,
- local models returns the adapter model list,
- public health returns `200` when the tunnel is running,
- public models returns the adapter model list when the tunnel is running.

Unauthenticated chat requests should return `401`. That is expected. Chat requests require the Kie API key from Warp.

## Common commands
Start adapter plus tunnel:

```bash
./docker/docker-quick-start.sh start
```

Show status:

```bash
./docker/docker-quick-start.sh status
```

Print current Warp URL:

```bash
./docker/docker-quick-start.sh url
```

Follow logs:

```bash
./docker/docker-quick-start.sh logs
```

Stop containers:

```bash
./docker/docker-quick-start.sh stop
```

PowerShell uses the same command names:

```powershell
.\docker\docker-quick-start.ps1 start
.\docker\docker-quick-start.ps1 status
.\docker\docker-quick-start.ps1 url
.\docker\docker-quick-start.ps1 logs
.\docker\docker-quick-start.ps1 stop
```

## Plain Docker Compose commands
The wrapper scripts are recommended for new users. If you prefer plain Compose commands, run them from the repository root.

Adapter only:

```bash
ADAPTER_HOST_PORT=8788 docker compose up --build -d adapter
```

Adapter plus tunnel:

```bash
mkdir -p docker-data
ADAPTER_HOST_PORT=8788 docker compose --profile tunnel up --build -d
cat docker-data/tunnel_url.txt
```

Status:

```bash
ADAPTER_HOST_PORT=8788 docker compose --profile tunnel ps
```

Logs:

```bash
ADAPTER_HOST_PORT=8788 docker compose --profile tunnel logs --tail=120 -f
```

Stop:

```bash
ADAPTER_HOST_PORT=8788 docker compose --profile tunnel down
```

## If Docker or Compose is missing
The quick-start scripts check dependencies before building.

If Docker is missing:
- macOS/Windows: install Docker Desktop.
- Linux: install Docker Engine.

If Docker is installed but not running:
- macOS/Windows: start Docker Desktop.
- Linux: start the Docker service.

If Compose is missing:
- Docker Desktop normally includes it.
- Linux packages may call it `docker-compose-v2` or `docker-compose-plugin`.

Ubuntu/Debian example:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

After adding yourself to the `docker` group, sign out and sign in again before rerunning the script.

## Troubleshooting
### The script says Docker is not reachable
Docker is installed, but the daemon is not available.

Try:
- start Docker Desktop,
- wait for Docker Desktop to finish starting,
- on Linux, run `sudo systemctl enable --now docker`,
- on Linux, check whether your user is in the `docker` group.

### The tunnel URL file is missing
Check logs:

```bash
./docker/docker-quick-start.sh logs
```

Cloudflare quick tunnels require internet access. They may take a short time to publish a URL.

### Warp stopped connecting after a restart
Cloudflare quick-tunnel URLs can change when the tunnel container is recreated.

Print the current URL:

```bash
./docker/docker-quick-start.sh url
```

Then update Warp with the new Base URL.

### Port 8788 is already in use
Use another host port:

```bash
ADAPTER_HOST_PORT=8790 ./docker/docker-quick-start.sh start
```

### Public `/healthz` works, but chat returns `401`
That is expected without authentication. Configure your Kie API key in Warp as the custom endpoint API key.

### The model tries to run commands or edit files
The adapter currently works best for text responses. Claude-native tools such as `Bash`, `Read`, `Write`, and `Edit` are not executed through Warp by this adapter. Unsupported native tool calls are retried with a text-only fallback.
