#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Telegram MTProto Proxy — automated setup
# Uses mtg v2 with FakeTLS to bypass DPI
# ============================================================

MTG_IMAGE="nineseconds/mtg:2"
CONFIG_FILE="config.toml"
TEMPLATE_FILE="config.toml.template"
DEFAULT_PORT=443
DEFAULT_DOMAIN="cloudflare.com"

# CLI arguments (override interactive input)
ARG_DOMAIN=""
ARG_PORT=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Check dependencies ---
check_deps() {
    local missing=()

    if ! command -v docker &>/dev/null; then
        missing+=("docker")
    fi

    if ! docker compose version &>/dev/null 2>&1; then
        if ! command -v docker-compose &>/dev/null; then
            missing+=("docker-compose")
        fi
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install Docker:"
        echo "  curl -fsSL https://get.docker.com | sh"
        exit 1
    fi

    ok "Docker found"
}

# --- Get external IP ---
get_external_ip() {
    local ip=""
    for service in "ifconfig.me" "icanhazip.com" "ipecho.net/plain"; do
        ip=$(curl -4 -s --connect-timeout 5 "$service" 2>/dev/null || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
    error "Failed to detect external IP"
    exit 1
}

# --- Docker Compose command ---
compose_cmd() {
    if docker compose version &>/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# --- Main script ---
main() {
    echo ""
    echo "=========================================="
    echo "  Telegram MTProto Proxy — Setup"
    echo "=========================================="
    echo ""

    # 1. Check dependencies
    check_deps

    # 2. Check template
    if [ ! -f "$TEMPLATE_FILE" ]; then
        error "$TEMPLATE_FILE not found"
        exit 1
    fi

    # 3. FakeTLS domain
    if [ -n "$ARG_DOMAIN" ]; then
        DOMAIN="$ARG_DOMAIN"
    else
        echo ""
        info "FakeTLS disguises proxy traffic as regular HTTPS."
        info "It is recommended to use your own domain with an A record pointing to this server."
        info "Press Enter to use the default domain (${DEFAULT_DOMAIN})."
        echo ""
        read -rp "FakeTLS domain [${DEFAULT_DOMAIN}]: " DOMAIN
        DOMAIN=${DOMAIN:-$DEFAULT_DOMAIN}
    fi

    if [ "$DOMAIN" = "$DEFAULT_DOMAIN" ]; then
        warn "Using default domain ($DEFAULT_DOMAIN)."
        warn "For better disguise, use your own domain with an A record pointing to server IP."
    fi

    ok "Domain: $DOMAIN"

    # 4. Port
    if [ -n "$ARG_PORT" ]; then
        PORT="$ARG_PORT"
    else
        read -rp "Port [${DEFAULT_PORT}]: " PORT
        PORT=${PORT:-$DEFAULT_PORT}
    fi
    ok "Port: $PORT"

    # 5. Generate secret
    info "Generating secret..."
    SECRET=$(docker run --rm "$MTG_IMAGE" generate-secret --hex "$DOMAIN" 2>/dev/null)

    if [ -z "$SECRET" ]; then
        error "Failed to generate secret"
        exit 1
    fi

    ok "Secret generated"

    # 6. Create config.toml
    info "Creating $CONFIG_FILE..."
    sed "s|{{SECRET}}|${SECRET}|g" "$TEMPLATE_FILE" \
        | sed "s|0.0.0.0:443|0.0.0.0:${PORT}|g" \
        > "$CONFIG_FILE"

    ok "Configuration created"

    # 7. Detect external IP
    info "Detecting external IP..."
    EXTERNAL_IP=$(get_external_ip)
    ok "External IP: $EXTERNAL_IP"

    # 8. Stop previous container (if any)
    if docker ps -q -f name=mtg-proxy &>/dev/null; then
        info "Stopping previous container..."
        compose_cmd down 2>/dev/null || true
    fi

    # 9. Start
    info "Starting proxy..."
    compose_cmd up -d

    # 10. Verify startup
    info "Waiting for proxy to start..."
    READY=false
    for i in $(seq 1 10); do
        sleep 1
        if curl -s -o /dev/null -w '' http://127.0.0.1:3129/ 2>/dev/null; then
            READY=true
            break
        fi
    done

    if [ "$READY" = true ]; then
        ok "Proxy is running and healthy!"
    elif docker ps -q -f name=mtg-proxy -f status=running | grep -q .; then
        warn "Container is running but stats endpoint not responding yet"
        warn "It may need more time. Check: docker compose logs mtg"
    else
        error "Container failed to start. Check logs:"
        echo "  docker compose logs mtg"
        exit 1
    fi

    # 11. Output connection link
    echo ""
    echo "=========================================="
    echo -e "  ${GREEN}Proxy successfully started!${NC}"
    echo "=========================================="
    echo ""
    echo "Telegram connection link:"
    echo ""
    echo -e "  ${CYAN}tg://proxy?server=${EXTERNAL_IP}&port=${PORT}&secret=${SECRET}${NC}"
    echo ""
    echo "Or use these details manually:"
    echo "  Server: ${EXTERNAL_IP}"
    echo "  Port:   ${PORT}"
    echo "  Secret: ${SECRET}"
    echo ""
    echo "Management:"
    echo "  Logs:    docker compose logs -f mtg"
    echo "  Stop:    docker compose down"
    echo "  Restart: docker compose restart mtg"
    echo ""
}

# --- Parse CLI arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)
            ARG_DOMAIN="$2"
            shift 2
            ;;
        --port)
            ARG_PORT="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: bash setup.sh [--domain DOMAIN] [--port PORT]"
            echo ""
            echo "Options:"
            echo "  --domain DOMAIN  FakeTLS domain (default: ${DEFAULT_DOMAIN})"
            echo "  --port PORT      Listening port (default: ${DEFAULT_PORT})"
            echo "  --help, -h       Show this help"
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            echo "Use --help for usage info"
            exit 1
            ;;
    esac
done

main
