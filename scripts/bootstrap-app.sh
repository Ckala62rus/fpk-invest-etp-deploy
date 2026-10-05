#!/usr/bin/env bash
# Подготавливает Laravel после docker compose up без миграций и сидов.
# Для изменения схемы БД используйте scripts/release.sh с явным подтверждением.
# Запуск из deploy/: ./scripts/bootstrap-app.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "${ROOT_DIR}/docker-compose.yml")

if ! "${COMPOSE[@]}" exec -T backend-etp sh -lc 'test -n "$APP_KEY"'; then
  echo "APP_KEY must be set in backend/src/.env before production bootstrap." >&2
  exit 1
fi

echo "==> composer install (production)"
"${COMPOSE[@]}" exec -T backend-etp composer install --no-dev --optimize-autoloader --no-interaction

echo "==> Права storage / bootstrap/cache"
"${COMPOSE[@]}" exec -T -u root backend-etp sh -c \
  "chown -R www-data:www-data /var/www/storage /var/www/bootstrap/cache && chmod -R ug+rwX /var/www/storage /var/www/bootstrap/cache"

echo "==> storage:link"
"${COMPOSE[@]}" exec -T backend-etp php artisan storage:link

echo "==> config/route/view cache"
"${COMPOSE[@]}" exec -T backend-etp php artisan config:cache
"${COMPOSE[@]}" exec -T backend-etp php artisan route:cache
"${COMPOSE[@]}" exec -T backend-etp php artisan view:cache

echo "==> Готово. Миграции: scripts/release.sh --apply-migrations --confirm --backup-dir DIRECTORY"
