# Telegram MTProto Proxy

Easy-to-deploy MTProto proxy for Telegram with FakeTLS support to bypass DPI blocking.

Built on [mtg v2](https://github.com/9seconds/mtg) — a fast and reliable Go-based proxy.

## Features

- **FakeTLS** — traffic is disguised as regular HTTPS, making it indistinguishable from normal web traffic for DPI
- **Replay attack protection** — built-in defense against active probing
- **Minimal resources** — runs on a VPS with 512MB RAM and 1 vCPU
- **Single secret for everyone** — one link to connect all clients

## Requirements

- VPS outside of Russia (DigitalOcean, Hetzner, Vultr, etc.)
- Docker and Docker Compose
- Own domain with an A record pointing to server IP (optional, but recommended for better disguise)

## Quick Start

### 1. Prepare domain (optional)

For better disguise, create an A record for a subdomain pointing to your VPS IP:

```
proxy.example.com → 123.45.67.89
```

This strengthens FakeTLS — DPI will see a legitimate TLS handshake with your domain. The proxy works without your own domain too (`cloudflare.com` is used by default).

### 2. Installation

```bash
git clone https://github.com/frops/telegram-proxy.git
cd telegram-proxy
bash setup.sh
```

Or with parameters (non-interactive):

```bash
# With your own domain
bash setup.sh --domain proxy.example.com

# With a custom port
bash setup.sh --domain proxy.example.com --port 8443

# Without a domain — cloudflare.com is used
bash setup.sh --port 443
```

The script will:
1. Check for Docker
2. Ask for a FakeTLS domain (or use `--domain`)
3. Generate a secret
4. Create configuration
5. Start the proxy
6. Output a connection link

### 3. Connect client

After startup, the script will output a link like:

```
tg://proxy?server=123.45.67.89&port=443&secret=ee...
```

Open this link on a device with Telegram — the proxy will be added automatically.

**Or manually:** Telegram → Settings → Data and Storage → Proxy → Add Proxy → MTProto

## Management

```bash
# View logs
docker compose logs -f mtg

# Stop
docker compose down

# Restart
docker compose restart mtg

# Status
docker compose ps
```

## Choosing a FakeTLS domain

Best option is to use **your own domain** with an A record pointing to the server IP. Then DPI will see:
- TLS SNI: `proxy.example.com`
- Domain resolves to your server's IP
- Everything matches, no suspicion

If you don't have your own domain — no problem. `cloudflare.com` is used by default. DPI rarely checks IP-to-SNI correspondence, so the proxy will work fine.

## Security

- `config.toml` contains the secret and is not committed to git (added to `.gitignore`)
- The secret is the only authentication; do not share it in public channels
- Use port 443 for maximum HTTPS disguise

## Troubleshooting

**Container doesn't start:**
```bash
docker compose logs mtg
```

**Port 443 is occupied:**
```bash
# Find out what's using the port
ss -tlnp | grep 443
# Specify a different port during setup (e.g., 8443)
```

**Client can't connect:**
- Check that VPS firewall allows port 443 (TCP)
- Make sure the domain A record points to the correct IP
- Try connecting from a different network

## Project structure

```
├── docker-compose.yml     # Docker Compose configuration
├── config.toml.template   # mtg configuration template
├── setup.sh               # Automated setup script
├── LICENSE                 # MIT License
└── README.md              # This file
```

## License

MIT License — see [LICENSE](LICENSE).
