#!/usr/bin/env bash
# Controlled production release for separate backend and frontend repositories.
# Example:
# ./scripts/release.sh --backend-ref v1.2.0 --frontend-ref v1.2.0
# ./scripts/release.sh --backend-ref <sha> --frontend-ref <sha> \
#   --apply-migrations --confirm --backup-dir /srv/etp-backups

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  release.sh --backend-ref REF --frontend-ref REF [options]

Required:
  --backend-ref REF       Existing backend Git ref (tag or commit SHA).
  --frontend-ref REF      Existing frontend Git ref (tag or commit SHA).

Options:
  --apply-migrations      Run php artisan migrate --force after a verified backup.
  --backup-dir DIRECTORY  Required together with --apply-migrations.
  --health-url URL        Public application origin; defaults to APP_URL from backend/src/.env.
  --confirm               Required together with --apply-migrations.
  --help                  Show this help.

The script requires every production Compose service to be stopped before it starts.
This creates a maintenance window and prevents serving a mixed application version.

The script never generates APP_KEY, runs general seeders, switches TLS mode, resets data,
or prunes Docker resources.
USAGE
}

BACKEND_REF=""
FRONTEND_REF=""
HEALTH_URL=""
BACKUP_DIR=""
APPLY_MIGRATIONS=false
CONFIRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-ref)
      BACKEND_REF="${2:-}"
      shift 2
      ;;
    --frontend-ref)
      FRONTEND_REF="${2:-}"
      shift 2
      ;;
    --health-url)
      HEALTH_URL="${2:-}"
      shift 2
      ;;
    --backup-dir)
      BACKUP_DIR="${2:-}"
      shift 2
      ;;
    --apply-migrations)
      APPLY_MIGRATIONS=true
      shift
      ;;
    --confirm)
      CONFIRM=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$BACKEND_REF" || -z "$FRONTEND_REF" ]]; then
  echo "--backend-ref and --frontend-ref are required." >&2
  usage >&2
  exit 2
fi

if [[ "$APPLY_MIGRATIONS" == true && ( "$CONFIRM" != true || -z "$BACKUP_DIR" ) ]]; then
  echo "Migrations require --apply-migrations --confirm --backup-dir DIRECTORY." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "${ROOT_DIR}/.." && pwd)"
BACKEND_DIR="${PROJECT_DIR}/backend"
FRONTEND_DIR="${PROJECT_DIR}/frontend"
COMPOSE=(docker compose -f "${ROOT_DIR}/docker-compose.yml")

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "Missing required file: $1" >&2
    exit 1
  fi
}

update_repository() {
  local directory="$1"
  local ref="$2"
  local name="$3"

  if [[ ! -d "${directory}/.git" ]]; then
    echo "${name} is not a Git repository: ${directory}" >&2
    exit 1
  fi

  if [[ -n "$(git -C "$directory" status --porcelain)" ]]; then
    echo "${name} repository has uncommitted changes: ${directory}" >&2
    exit 1
  fi

  echo "==> Fetching ${name} ref ${ref}"
  git -C "$directory" fetch --tags origin
  git -C "$directory" checkout --detach "$ref"
}

read_env_value() {
  local file="$1"
  local key="$2"
  local value
  value="$(grep -E "^${key}=" "$file" | tail -n 1 | cut -d= -f2- || true)"
  value="${value%$'\r'}"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "$value"
}

require_file "${ROOT_DIR}/.env"
require_file "${BACKEND_DIR}/src/.env"
require_file "${FRONTEND_DIR}/.env.production"
require_file "${ROOT_DIR}/scripts/backup.sh"

if [[ -n "$("${COMPOSE[@]}" ps --status running -q)" ]]; then
  echo "Production services are running. Stop the entire Compose stack before release:" >&2
  echo "  cd ${ROOT_DIR} && docker compose down" >&2
  exit 1
fi

STACK_STARTED=false
on_release_error() {
  local status="$1"
  trap - ERR INT TERM
  if [[ "$STACK_STARTED" == true ]]; then
    echo "Release failed; stopping the partially started production stack." >&2
    "${COMPOSE[@]}" down || true
  fi
  exit "$status"
}
trap 'on_release_error $?' ERR INT TERM

update_repository "$BACKEND_DIR" "$BACKEND_REF" "Backend"
update_repository "$FRONTEND_DIR" "$FRONTEND_REF" "Frontend"

if [[ -z "$(read_env_value "${BACKEND_DIR}/src/.env" "APP_KEY")" ]]; then
  echo "APP_KEY must be set in ${BACKEND_DIR}/src/.env before release." >&2
  exit 1
fi

if [[ -z "$HEALTH_URL" ]]; then
  HEALTH_URL="$(read_env_value "${BACKEND_DIR}/src/.env" "APP_URL")"
fi
if [[ -z "$HEALTH_URL" ]]; then
  echo "--health-url is required when APP_URL is not set." >&2
  exit 1
fi
HEALTH_URL="${HEALTH_URL%/}"

echo "==> Validating production Compose configuration"
"${COMPOSE[@]}" config --quiet

echo "==> Building SPA"
docker run --rm -v "${FRONTEND_DIR}:/app" -w /app node:22-alpine \
  sh -c 'npm ci --no-audit --no-fund && npm run build'

echo "==> Starting database, Redis, PHP-FPM, and internal nginx"
STACK_STARTED=true
"${COMPOSE[@]}" up -d --build postgres-etp redis-etp backend-etp nginx-etp

echo "==> Validating PHP version and Composer dependencies"
"${COMPOSE[@]}" exec -T backend-etp php -r 'exit(PHP_VERSION_ID >= 80400 ? 0 : 1);'
"${COMPOSE[@]}" exec -T backend-etp composer install --no-dev --optimize-autoloader --no-interaction --no-progress

# The bind mount may contain files created by a host user after a previous release.
echo "==> Applying Laravel filesystem permissions"
"${COMPOSE[@]}" exec -T -u root backend-etp sh -lc \
  'chown -R www-data:www-data /var/www/storage /var/www/bootstrap/cache && chmod -R ug+rwX /var/www/storage /var/www/bootstrap/cache'
"${COMPOSE[@]}" exec -T backend-etp php artisan storage:link

if [[ "$APPLY_MIGRATIONS" == true ]]; then
  BACKEND_SHA="$(git -C "$BACKEND_DIR" rev-parse --short HEAD)"
  LABEL="pre-release-${BACKEND_SHA}-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "==> Backing up data before migrations"
  "${ROOT_DIR}/scripts/backup.sh" --destination "$BACKUP_DIR" --label "$LABEL"

  echo "==> Applying production migrations"
  "${COMPOSE[@]}" exec -T backend-etp php artisan migrate --force
else
  echo "==> Migrations skipped; use --apply-migrations --confirm --backup-dir DIRECTORY to apply them."
fi

echo "==> Caching Laravel configuration"
"${COMPOSE[@]}" exec -T backend-etp php artisan config:cache
"${COMPOSE[@]}" exec -T backend-etp php artisan route:cache
"${COMPOSE[@]}" exec -T backend-etp php artisan view:cache

echo "==> Starting gateway and background services"
"${COMPOSE[@]}" up -d
"${COMPOSE[@]}" restart horizon-etp scheduler-etp reverb-etp

echo "==> Checking ${HEALTH_URL}/api/health"
health_ready=false
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error "${HEALTH_URL}/api/health" > /dev/null; then
    health_ready=true
    break
  fi
  sleep 2
done
if [[ "$health_ready" != true ]]; then
  "${COMPOSE[@]}" logs --tail 100 gateway-etp nginx-etp backend-etp >&2
  exit 1
fi

"${COMPOSE[@]}" ps
echo "Release complete."
printf '  backend:  %s\n' "$(git -C "$BACKEND_DIR" rev-parse --short HEAD)"
printf '  frontend: %s\n' "$(git -C "$FRONTEND_DIR" rev-parse --short HEAD)"
