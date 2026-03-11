#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Telegram MTProto Proxy — Diagnostics
# Checks proxy health and helps troubleshoot issues
# ============================================================

CONFIG_FILE="config.toml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN_COUNT=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; ((PASS++)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $*"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; ((WARN_COUNT++)); }
info() { echo -e "  ${CYAN}[INFO]${NC} $*"; }
section() { echo -e "\n${CYAN}=== $* ===${NC}"; }

# --- Extract bind address from config ---
get_bind_addr() {
    if [ -f "$CONFIG_FILE" ]; then
        grep -oP 'bind-to\s*=\s*"\K[^"]+' "$CONFIG_FILE" 2>/dev/null || echo "0.0.0.0:443"
    else
        echo "0.0.0.0:443"
    fi
}

# --- Extract port from config ---
get_port() {
    local addr
    addr=$(get_bind_addr)
    echo "${addr##*:}"
}

# --- Detect nginx-mode (mtg bound to 127.0.0.1) ---
is_nginx_mode() {
    local addr
    addr=$(get_bind_addr)
    [[ "$addr" == 127.0.0.1:* ]]
}

# --- Extract secret from config ---
get_secret() {
    if [ -f "$CONFIG_FILE" ]; then
        grep -oP 'secret\s*=\s*"\K[^"]+' "$CONFIG_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

main() {
    echo ""
    echo "=========================================="
    echo "  Telegram MTProto Proxy — Diagnostics"
    echo "=========================================="

    PORT=$(get_port)
    SECRET=$(get_secret)
    BIND_ADDR=$(get_bind_addr)

    if is_nginx_mode; then
        NGINX_MODE=true
        EXTERNAL_PORT=443
        info "Detected nginx-mode (mtg bound to $BIND_ADDR)"
    else
        NGINX_MODE=false
        EXTERNAL_PORT="$PORT"
    fi

    # ---- 1. Docker ----
    section "Docker"

    if command -v docker &>/dev/null; then
        pass "Docker installed: $(docker --version 2>/dev/null | head -1)"
    else
        fail "Docker is not installed"
        echo "       Install: curl -fsSL https://get.docker.com | sh"
        echo ""
        echo "Cannot continue without Docker."
        exit 1
    fi

    if docker info &>/dev/null 2>&1; then
        pass "Docker daemon is running"
    else
        fail "Docker daemon is not running or current user has no access"
        echo "       Try: sudo systemctl start docker"
        echo "       Or:  sudo usermod -aG docker \$USER"
    fi

    # ---- 2. Container ----
    section "Container"

    CONTAINER_ID=$(docker ps -q -f name=mtg-proxy 2>/dev/null || true)

    if [ -n "$CONTAINER_ID" ]; then
        pass "Container 'mtg-proxy' is running (ID: ${CONTAINER_ID:0:12})"

        UPTIME=$(docker inspect --format='{{.State.StartedAt}}' mtg-proxy 2>/dev/null || true)
        if [ -n "$UPTIME" ]; then
            info "Started at: $UPTIME"
        fi

        RESTARTS=$(docker inspect --format='{{.RestartCount}}' mtg-proxy 2>/dev/null || echo "0")
        if [ "$RESTARTS" -gt 0 ]; then
            warn "Container has restarted $RESTARTS time(s) — may indicate instability"
        else
            pass "No restarts detected"
        fi
    else
        # Check if container exists but stopped
        STOPPED=$(docker ps -aq -f name=mtg-proxy 2>/dev/null || true)
        if [ -n "$STOPPED" ]; then
            fail "Container 'mtg-proxy' exists but is NOT running"
            echo "       Start: docker compose up -d"
        else
            fail "Container 'mtg-proxy' not found"
            echo "       Run setup: bash setup.sh"
        fi
    fi

    # ---- 3. Configuration ----
    section "Configuration"

    if [ -f "$CONFIG_FILE" ]; then
        pass "config.toml exists"
    else
        fail "config.toml not found — run setup.sh first"
    fi

    if [ -n "$SECRET" ]; then
        SECRET_LEN=${#SECRET}
        if [ "$SECRET_LEN" -ge 32 ]; then
            pass "Secret is present (${SECRET_LEN} chars)"
        else
            warn "Secret seems too short (${SECRET_LEN} chars) — may be invalid"
        fi

        # Check FakeTLS prefix (ee = FakeTLS)
        if [[ "$SECRET" == ee* ]]; then
            pass "Secret has FakeTLS prefix (ee...)"
        else
            warn "Secret does not start with 'ee' — FakeTLS may not be active"
        fi
    else
        fail "Secret not found in config.toml"
    fi

    info "Configured bind address: $BIND_ADDR"
    if [ "$NGINX_MODE" = true ]; then
        info "External port: $EXTERNAL_PORT (via nginx)"
    fi

    # ---- 4. Network: port listening ----
    section "Network"

    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
            LISTENER=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | head -1)
            pass "Port $PORT is listening"
            info "$LISTENER"
        else
            fail "Port $PORT is NOT listening"
            echo "       The proxy may have failed to bind. Check logs: docker compose logs mtg"
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":${PORT} "; then
            pass "Port $PORT is listening"
        else
            fail "Port $PORT is NOT listening"
        fi
    else
        warn "Neither 'ss' nor 'netstat' available — cannot check port"
    fi

    # In standalone mode, check if another process owns the port
    if [ "$NGINX_MODE" = false ] && command -v ss &>/dev/null && [ -n "$CONTAINER_ID" ]; then
        PORT_PID=$(ss -tlnp 2>/dev/null | grep ":${PORT} " | grep -oP 'pid=\K\d+' | head -1 || true)
        if [ -n "$PORT_PID" ]; then
            PORT_PROC=$(cat /proc/"$PORT_PID"/cmdline 2>/dev/null | tr '\0' ' ' || echo "unknown")
            if echo "$PORT_PROC" | grep -qi "mtg"; then
                pass "Port $PORT is owned by mtg process"
            else
                warn "Port $PORT may be used by another process: $PORT_PROC"
            fi
        fi
    fi

    # ---- 5. Firewall ----
    section "Firewall"

    FIREWALL_CHECKED=false

    if command -v ufw &>/dev/null; then
        UFW_STATUS=$(ufw status 2>/dev/null || true)
        if echo "$UFW_STATUS" | grep -qi "active"; then
            if echo "$UFW_STATUS" | grep -q "$PORT"; then
                pass "UFW is active and port $PORT appears in rules"
            else
                fail "UFW is active but port $PORT is NOT in rules"
                echo "       Fix: sudo ufw allow ${PORT}/tcp"
            fi
            FIREWALL_CHECKED=true
        else
            info "UFW is installed but inactive"
        fi
    fi

    if command -v firewall-cmd &>/dev/null; then
        if firewall-cmd --state &>/dev/null 2>&1; then
            if firewall-cmd --list-ports 2>/dev/null | grep -q "${PORT}/tcp"; then
                pass "firewalld allows port $PORT/tcp"
            else
                warn "firewalld may be blocking port $PORT"
                echo "       Fix: sudo firewall-cmd --add-port=${PORT}/tcp --permanent && sudo firewall-cmd --reload"
            fi
            FIREWALL_CHECKED=true
        fi
    fi

    if command -v iptables &>/dev/null; then
        # Check for explicit DROP/REJECT on the port
        if iptables -L INPUT -n 2>/dev/null | grep -E "(DROP|REJECT)" | grep -q "dpt:${PORT}"; then
            fail "iptables has a DROP/REJECT rule for port $PORT"
            FIREWALL_CHECKED=true
        elif [ "$FIREWALL_CHECKED" = false ]; then
            info "iptables present, no explicit block on port $PORT detected"
            FIREWALL_CHECKED=true
        fi
    fi

    if [ "$FIREWALL_CHECKED" = false ]; then
        info "No firewall tools detected (ufw, firewalld, iptables)"
        info "Check your cloud provider's security group / firewall settings"
    fi

    info "Don't forget to check cloud provider firewall (AWS SG, DigitalOcean Firewall, etc.)"

    # ---- 6. Connectivity to Telegram DCs ----
    section "Telegram DC connectivity"

    TELEGRAM_DCS=(
        "149.154.175.50:443"
        "149.154.167.51:443"
        "149.154.175.100:443"
        "149.154.167.91:443"
        "91.108.56.100:443"
    )
    DC_NAMES=("DC1" "DC2" "DC3" "DC4" "DC5")

    DC_OK=0
    DC_FAIL=0

    for i in "${!TELEGRAM_DCS[@]}"; do
        DC="${TELEGRAM_DCS[$i]}"
        NAME="${DC_NAMES[$i]}"
        if timeout 5 bash -c "echo >/dev/tcp/${DC%:*}/${DC#*:}" 2>/dev/null; then
            ((DC_OK++))
        else
            fail "Cannot reach Telegram $NAME ($DC)"
            ((DC_FAIL++))
        fi
    done

    if [ "$DC_OK" -gt 0 ]; then
        pass "Reached $DC_OK/$((DC_OK + DC_FAIL)) Telegram data centers"
    fi
    if [ "$DC_FAIL" -gt 0 ] && [ "$DC_OK" -eq 0 ]; then
        fail "Cannot reach ANY Telegram DC — proxy cannot work"
        echo "       The server may not have outbound access to Telegram servers"
    fi

    # ---- 7. nginx stream proxy (nginx-mode only) ----
    if [ "$NGINX_MODE" = true ]; then
        section "nginx stream proxy"

        if command -v nginx &>/dev/null; then
            pass "nginx is installed"

            # Check stream module
            if nginx -V 2>&1 | grep -q "stream"; then
                pass "nginx has stream module"
            else
                fail "nginx does NOT have stream module"
                echo "       Install: sudo apt install libnginx-mod-stream (Debian/Ubuntu)"
                echo "       Or: sudo yum install nginx-mod-stream (RHEL/CentOS)"
            fi

            # Check nginx config validity
            if nginx -t 2>&1 | grep -q "successful"; then
                pass "nginx configuration is valid"
            else
                fail "nginx configuration test failed"
                echo "       Run: sudo nginx -t"
            fi

            # Check nginx is running
            if pgrep -x nginx &>/dev/null; then
                pass "nginx is running"
            else
                fail "nginx is NOT running"
                echo "       Start: sudo systemctl start nginx"
            fi

            # Check that port 443 is handled by nginx (not mtg directly)
            if command -v ss &>/dev/null; then
                LISTENER_443=$(ss -tlnp 2>/dev/null | grep ":443 " | head -1 || true)
                if echo "$LISTENER_443" | grep -qi "nginx"; then
                    pass "Port 443 is owned by nginx"
                elif [ -n "$LISTENER_443" ]; then
                    warn "Port 443 is listening but may not be nginx: $LISTENER_443"
                else
                    fail "Port 443 is NOT listening — nginx may not be configured"
                fi
            fi

            # Check mtg local port
            if command -v ss &>/dev/null; then
                if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
                    pass "mtg is listening on local port $PORT"
                else
                    fail "mtg is NOT listening on local port $PORT"
                fi
            fi
        else
            fail "nginx is NOT installed but nginx-mode is configured"
            echo "       Install: sudo apt install nginx (Debian/Ubuntu)"
        fi
    fi

    # ---- 8. TLS handshake test ----
    section "TLS handshake (local)"

    if command -v openssl &>/dev/null; then
        TLS_OUTPUT=$(echo | timeout 5 openssl s_client -connect "127.0.0.1:${PORT}" 2>&1 || true)
        if echo "$TLS_OUTPUT" | grep -qi "CONNECTED"; then
            pass "TLS connection to 127.0.0.1:${PORT} succeeded"
            SNI=$(echo "$TLS_OUTPUT" | grep -i "subject" | head -1 || true)
            if [ -n "$SNI" ]; then
                info "Certificate: $SNI"
            fi
        else
            warn "TLS handshake to 127.0.0.1:${PORT} failed (may be normal for MTProto FakeTLS)"
        fi
    else
        info "openssl not available — skipping TLS handshake test"
    fi

    # ---- 8. Container logs (last 20 lines) ----
    section "Recent container logs"

    if [ -n "$CONTAINER_ID" ] || docker ps -aq -f name=mtg-proxy | grep -q .; then
        echo ""
        docker logs --tail 20 mtg-proxy 2>&1 | while IFS= read -r line; do
            echo "  | $line"
        done
        echo ""
    else
        info "No container to show logs for"
    fi

    # ---- 9. External IP ----
    section "External access"

    EXTERNAL_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || true)
    if [ -n "$EXTERNAL_IP" ]; then
        pass "External IP: $EXTERNAL_IP"

        # Self-test: try connecting to own port from outside perspective
        if timeout 5 bash -c "echo >/dev/tcp/${EXTERNAL_IP}/${EXTERNAL_PORT}" 2>/dev/null; then
            pass "Port $EXTERNAL_PORT is reachable on external IP $EXTERNAL_IP"
        else
            warn "Port $EXTERNAL_PORT may not be reachable externally on $EXTERNAL_IP"
            echo "       This could be: firewall, cloud security group, or NAT"
        fi
    else
        warn "Could not detect external IP"
    fi

    # ---- Summary ----
    echo ""
    echo "=========================================="
    echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${WARN_COUNT} warnings${NC}"
    echo "=========================================="

    if [ "$FAIL" -gt 0 ]; then
        echo ""
        echo -e "  ${RED}There are failures that need attention.${NC}"
        echo "  Fix the [FAIL] items above and re-run: bash diagnose.sh"
    elif [ "$WARN_COUNT" -gt 0 ]; then
        echo ""
        echo -e "  ${YELLOW}No critical issues, but check the warnings.${NC}"
    else
        echo ""
        echo -e "  ${GREEN}All checks passed! Proxy should be working.${NC}"
    fi
    echo ""
}

main
