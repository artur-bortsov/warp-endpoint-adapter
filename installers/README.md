# Installers

Use these scripts from the repository root.

- macOS: `./installers/install-macos.sh`
- Linux: `./installers/install-linux.sh`
- Windows: `.\installers\install-windows.ps1`

Each installer asks for:
- installation directory,
- manual or service mode,
- service components: adapter, tunnel, or both.

Service mode saves the current Cloudflare quick-tunnel URL to `tunnel_url.txt` in the installed folder when the tunnel is running.
