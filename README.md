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

## Using with nginx reverse proxy

If port 443 is already occupied by nginx (serving other sites), you can route Telegram proxy traffic through nginx using the `stream` module with SNI-based routing.

**Why not a regular `proxy_pass`?** mtg operates at the TCP/TLS level (FakeTLS), not HTTP. A standard nginx `http` block reverse proxy will not work. You need the `stream` module with `ssl_preread` to inspect the TLS SNI header and route traffic accordingly.

### Architecture

```
Client -> your-domain.com:443
  -> nginx stream (ssl_preread reads SNI)
    -> SNI = your-domain.com -> 127.0.0.1:8443 (mtg)
    -> SNI = anything else   -> 127.0.0.1:8444 (nginx HTTPS)
```

### Setup

1. Run mtg on a non-standard port with your domain as the FakeTLS domain:
   ```bash
   bash setup.sh --domain your-domain.com --port 8443
   ```

2. Copy the stream block from [`nginx-stream.conf.example`](nginx-stream.conf.example) into your nginx's main `nginx.conf` (at the top level, next to the `http` block).

3. Replace `proxy.example.com` with your actual domain in the `map` block.

4. Change all existing HTTPS server blocks from `listen 443 ssl` to `listen 8444 ssl`. Port 8444 is internal only.

5. Test and reload nginx:
   ```bash
   nginx -t && nginx -s reload
   ```

**Important:** The FakeTLS domain in mtg must match the domain in the nginx `map` block. If they don't match, SNI routing will not work.

See [`nginx-stream.conf.example`](nginx-stream.conf.example) for the full configuration with comments.

## Diagnostics

Run the diagnostic script to check proxy health:

```bash
bash diagnose.sh
```

It checks:
- Docker status and container health
- Port binding and firewall rules
- Connectivity to Telegram data centers
- TLS handshake
- Config validity (secret format, FakeTLS prefix)
- External reachability

The proxy also has a built-in Docker healthcheck via the stats endpoint (`127.0.0.1:3129`). Check health status:

```bash
docker inspect --format='{{.State.Health.Status}}' mtg-proxy
```

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
- Run `bash diagnose.sh` for a full check
- Check that VPS firewall allows port 443 (TCP)
- Check cloud provider firewall (AWS Security Groups, DigitalOcean Firewall, etc.)
- Make sure the domain A record points to the correct IP
- Try connecting from a different network

**Status: unavailable in Telegram:**
- Most common cause: firewall blocking the port (both OS-level and cloud provider)
- Verify the port is reachable: `curl -v telnet://YOUR_IP:443` from another machine
- Check that the proxy can reach Telegram DCs: `bash diagnose.sh` (see "Telegram DC connectivity" section)

## Project structure

```
├── docker-compose.yml            # Docker Compose configuration
├── config.toml.template          # mtg configuration template
├── setup.sh                      # Automated setup script
├── diagnose.sh                   # Diagnostic and troubleshooting script
├── nginx-stream.conf.example     # Example nginx stream config for SNI routing
├── LICENSE                       # MIT License
└── README.md                     # This file
```

## License

MIT License — see [LICENSE](LICENSE).
