# Docker usage

The Docker setup provides two services:

- `adapter`: local HTTPS OpenAI-compatible adapter on container port `8787`.
- `tunnel`: optional Cloudflare quick-tunnel sidecar that saves the current public URL to `docker-data/tunnel_url.txt`.

For a step-by-step beginner walkthrough, start with [Docker Quick Start Guide](QUICK_START.md).

## Recommended quick start
macOS/Linux:

```bash
./docker/docker-quick-start.sh start
```

Windows PowerShell:

```powershell
.\docker\docker-quick-start.ps1 start
```

The quick-start scripts:

- check Docker is installed,
- check Docker is running,
- check Docker Compose is available,
- build the adapter and tunnel images,
- start the containers in the background,
- print the Warp Base URL when the Cloudflare quick tunnel is ready.

## Build and run adapter only
macOS/Linux:

```bash
./docker/docker-quick-start.sh adapter
```

Windows PowerShell:

```powershell
.\docker\docker-quick-start.ps1 adapter
```

Test endpoints:

```bash
./docker/docker-quick-start.sh test
```

From the repository root, you can also list the adapter's accepted model IDs without starting the adapter or using a local Kie API key file:

```bash
./adapterctl.sh models
```

## Run adapter plus Cloudflare Tunnel
macOS/Linux:

```bash
./docker/docker-quick-start.sh start
```

Windows PowerShell:

```powershell
.\docker\docker-quick-start.ps1 start
```

When Cloudflare publishes the quick-tunnel URL, it is written to:

```text
docker-data/tunnel_url.txt
```

Use this Warp Base URL:

```text
https://<current-trycloudflare-host>/v1
```

Use your Kie API key as the Warp custom endpoint API key. The adapter forwards Warp's bearer token to Kie per request.

## Stop
macOS/Linux:

```bash
./docker/docker-quick-start.sh stop
```

Windows PowerShell:

```powershell
.\docker\docker-quick-start.ps1 stop
```

## Plain Docker Compose commands
Run these from the repository root if you do not want to use the helper scripts.

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

## Notes

- The adapter image does not store a Kie key.
- The local `adapterctl` models command reads the adapter's static catalog; Warp still sends your Kie API key only when making chat requests.
- The tunnel image downloads `cloudflared` at build time.
- Generated certificates are stored in the `adapter-certs` Docker volume.
- The optional tunnel data file is host-mounted at `docker-data/tunnel_url.txt`.
- Cloudflare quick-tunnel URLs can change when the tunnel container is recreated; rerun the `url` command after restarts.
