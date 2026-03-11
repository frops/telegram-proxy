#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Telegram MTProto Proxy — автоматическая настройка
# Использует mtg v2 с FakeTLS для обхода DPI
# ============================================================

MTG_IMAGE="nineseconds/mtg:2"
CONFIG_FILE="config.toml"
TEMPLATE_FILE="config.toml.template"
DEFAULT_PORT=443

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Проверка зависимостей ---
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
        error "Не найдены зависимости: ${missing[*]}"
        echo ""
        echo "Установите Docker:"
        echo "  curl -fsSL https://get.docker.com | sh"
        exit 1
    fi

    ok "Docker найден"
}

# --- Определение внешнего IP ---
get_external_ip() {
    local ip=""
    for service in "ifconfig.me" "icanhazip.com" "ipecho.net/plain"; do
        ip=$(curl -4 -s --connect-timeout 5 "$service" 2>/dev/null || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return
        fi
    done
    error "Не удалось определить внешний IP"
    exit 1
}

# --- Docker Compose команда ---
compose_cmd() {
    if docker compose version &>/dev/null 2>&1; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# --- Основной скрипт ---
main() {
    echo ""
    echo "=========================================="
    echo "  Telegram MTProto Proxy — Настройка"
    echo "=========================================="
    echo ""

    # 1. Проверка зависимостей
    check_deps

    # 2. Проверка шаблона
    if [ ! -f "$TEMPLATE_FILE" ]; then
        error "Не найден $TEMPLATE_FILE"
        exit 1
    fi

    # 3. Запрос домена для FakeTLS
    echo ""
    info "FakeTLS маскирует трафик прокси под обычный HTTPS."
    info "Рекомендуется использовать свой домен с A-записью на IP этого сервера."
    echo ""
    read -rp "Домен для FakeTLS (напр. proxy.example.com): " DOMAIN

    if [ -z "$DOMAIN" ]; then
        error "Домен обязателен для FakeTLS"
        exit 1
    fi

    ok "Домен: $DOMAIN"

    # 4. Порт
    read -rp "Порт [${DEFAULT_PORT}]: " PORT
    PORT=${PORT:-$DEFAULT_PORT}
    ok "Порт: $PORT"

    # 5. Генерация секрета
    info "Генерация секрета..."
    SECRET=$(docker run --rm "$MTG_IMAGE" generate-secret --hex "$DOMAIN" 2>/dev/null)

    if [ -z "$SECRET" ]; then
        error "Не удалось сгенерировать секрет"
        exit 1
    fi

    ok "Секрет сгенерирован"

    # 6. Создание config.toml
    info "Создание $CONFIG_FILE..."
    sed "s|{{SECRET}}|${SECRET}|g" "$TEMPLATE_FILE" \
        | sed "s|0.0.0.0:443|0.0.0.0:${PORT}|g" \
        > "$CONFIG_FILE"

    ok "Конфигурация создана"

    # 7. Определение внешнего IP
    info "Определение внешнего IP..."
    EXTERNAL_IP=$(get_external_ip)
    ok "Внешний IP: $EXTERNAL_IP"

    # 8. Остановка предыдущего контейнера (если есть)
    if docker ps -q -f name=mtg-proxy &>/dev/null; then
        info "Остановка предыдущего контейнера..."
        compose_cmd down 2>/dev/null || true
    fi

    # 9. Запуск
    info "Запуск прокси..."
    compose_cmd up -d

    # 10. Проверка запуска
    sleep 2
    if docker ps -q -f name=mtg-proxy -f status=running | grep -q .; then
        ok "Прокси запущен!"
    else
        error "Контейнер не запустился. Проверьте логи:"
        echo "  docker compose logs mtg"
        exit 1
    fi

    # 11. Вывод ссылки для подключения
    echo ""
    echo "=========================================="
    echo -e "  ${GREEN}Прокси успешно запущен!${NC}"
    echo "=========================================="
    echo ""
    echo "Ссылка для подключения Telegram:"
    echo ""
    echo -e "  ${CYAN}tg://proxy?server=${EXTERNAL_IP}&port=${PORT}&secret=${SECRET}${NC}"
    echo ""
    echo "Или используйте эти данные вручную:"
    echo "  Сервер: ${EXTERNAL_IP}"
    echo "  Порт:   ${PORT}"
    echo "  Секрет: ${SECRET}"
    echo ""
    echo "Управление:"
    echo "  Логи:       docker compose logs -f mtg"
    echo "  Остановка:  docker compose down"
    echo "  Перезапуск: docker compose restart mtg"
    echo ""
}

main "$@"
