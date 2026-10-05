#!/usr/bin/env bash
# Переключение публичного режима gateway: HTTP ↔ HTTPS.
# Использование (из каталога deploy/):
#   ./scripts/switch-tls.sh http
#   ./scripts/switch-tls.sh https
#
# После HTTPS также обновите backend/src/.env (APP_URL, FRONTEND_URL, REVERB_SCHEME,
# SESSION_SECURE_COOKIE) и перезапустите PHP-контейнеры. SPA при VITE_REVERB_USE_PAGE_ORIGIN=true
# пересобирать не нужно.

set -euo pipefail

MODE="${1:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AVAILABLE="${ROOT_DIR}/nginx/sites-available"
ACTIVE="${ROOT_DIR}/nginx/conf.d/etp.conf"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

usage() {
  echo "Usage: $0 http|https"
  exit 1
}

[[ "${MODE}" == "http" || "${MODE}" == "https" ]] || usage

if [[ "${MODE}" == "https" ]]; then
  if [[ ! -f "${ROOT_DIR}/nginx/certs/fullchain.pem" || ! -f "${ROOT_DIR}/nginx/certs/privkey.pem" ]]; then
    echo "ERROR: положите fullchain.pem и privkey.pem в ${ROOT_DIR}/nginx/certs/"
    exit 1
  fi
fi

# Копируем (не symlink): надёжнее на NTFS/CI и проще в git
cp -f "${AVAILABLE}/${MODE}.conf" "${ACTIVE}"
echo "Active vhost ← sites-available/${MODE}.conf"

if docker compose -f "${COMPOSE_FILE}" ps --status running --services 2>/dev/null | grep -qx 'gateway-etp'; then
  docker compose -f "${COMPOSE_FILE}" exec -T gateway-etp nginx -t
  docker compose -f "${COMPOSE_FILE}" exec -T gateway-etp nginx -s reload
  echo "nginx reloaded (${MODE})"
else
  echo "Контейнер gateway-etp не запущен — активный vhost скопирован; конфиг применится при следующем up."
fi

echo
echo "Не забудьте синхронизировать backend/src/.env:"
if [[ "${MODE}" == "https" ]]; then
  echo "  APP_URL=https://ВАШ_ДОМЕН"
  echo "  FRONTEND_URL=https://ВАШ_ДОМЕН"
  echo "  REVERB_SCHEME=https"
  echo "  REVERB_PORT=443"
  echo "  SESSION_SECURE_COOKIE=true"
else
  echo "  APP_URL=http://ВАШ_ДОМЕН"
  echo "  FRONTEND_URL=http://ВАШ_ДОМЕН"
  echo "  REVERB_SCHEME=http"
  echo "  REVERB_PORT=80"
  echo "  SESSION_SECURE_COOKIE=false"
fi
echo "  затем: docker compose -f docker-compose.yml exec backend-etp php artisan config:clear"
echo "         docker compose -f docker-compose.yml restart backend-etp horizon-etp scheduler-etp reverb-etp"
