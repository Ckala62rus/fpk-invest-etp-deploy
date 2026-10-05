#!/usr/bin/env bash
# Создаёт проверяемый backup production PostgreSQL и storage/app.
# Запуск из любого каталога:
# ./deploy/scripts/backup.sh --destination /srv/etp-backups --label pre-release-20260917

set -euo pipefail
umask 077

usage() {
  cat <<'USAGE'
Usage:
  backup.sh --destination DIRECTORY --label LABEL

Creates:
  LABEL.postgres.dump        PostgreSQL custom-format dump
  LABEL.storage-app.tar.gz   uploaded application files
  LABEL.sha256               checksums for both files
USAGE
}

DESTINATION=""
LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination)
      DESTINATION="${2:-}"
      shift 2
      ;;
    --label)
      LABEL="${2:-}"
      shift 2
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

if [[ -z "$DESTINATION" || -z "$LABEL" ]]; then
  echo "Both --destination and --label are required." >&2
  usage >&2
  exit 2
fi

if [[ ! "$LABEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Label may contain only letters, digits, dot, underscore, and hyphen." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(cd "${ROOT_DIR}/.." && pwd)"
COMPOSE=(docker compose -f "${ROOT_DIR}/docker-compose.yml")
STORAGE_DIR="${PROJECT_DIR}/backend/src/storage/app"

if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  echo "Missing ${ROOT_DIR}/.env." >&2
  exit 1
fi

if [[ ! -d "$STORAGE_DIR" ]]; then
  echo "Missing Laravel storage directory: $STORAGE_DIR" >&2
  exit 1
fi

mkdir -p "$DESTINATION"
DB_NAME="${LABEL}.postgres.dump"
STORAGE_NAME="${LABEL}.storage-app.tar.gz"
CHECKSUM_NAME="${LABEL}.sha256"
DB_DUMP="${DESTINATION}/${DB_NAME}"
STORAGE_ARCHIVE="${DESTINATION}/${STORAGE_NAME}"
CHECKSUMS="${DESTINATION}/${CHECKSUM_NAME}"

for output in "$DB_DUMP" "$STORAGE_ARCHIVE" "$CHECKSUMS"; do
  if [[ -e "$output" ]]; then
    echo "Refusing to overwrite existing backup: $output" >&2
    exit 1
  fi
done

STAGING_DIR="$(mktemp -d "${DESTINATION}/.${LABEL}.staging.XXXXXX")"
COMMITTED=false
cleanup() {
  rm -rf "$STAGING_DIR"
  if [[ "$COMMITTED" != true ]]; then
    rm -f "$DB_DUMP" "$STORAGE_ARCHIVE" "$CHECKSUMS"
  fi
}
trap cleanup EXIT

STAGED_DB_DUMP="${STAGING_DIR}/${DB_NAME}"
STAGED_STORAGE_ARCHIVE="${STAGING_DIR}/${STORAGE_NAME}"
STAGED_CHECKSUMS="${STAGING_DIR}/${CHECKSUM_NAME}"

echo "==> PostgreSQL backup"
"${COMPOSE[@]}" exec -T postgres-etp sh -lc \
  'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom' > "$STAGED_DB_DUMP"

if [[ ! -s "$STAGED_DB_DUMP" ]]; then
  echo "PostgreSQL dump is empty." >&2
  exit 1
fi

echo "==> Validating PostgreSQL backup"
docker run --rm -i postgres:16-alpine pg_restore --list < "$STAGED_DB_DUMP" > /dev/null

echo "==> storage/app backup"
tar --create --gzip --file "$STAGED_STORAGE_ARCHIVE" --directory "$STORAGE_DIR" .
tar --list --gzip --file "$STAGED_STORAGE_ARCHIVE" > /dev/null

(
  cd "$STAGING_DIR"
  sha256sum "$DB_NAME" "$STORAGE_NAME" > "$CHECKSUM_NAME"
  sha256sum --check "$CHECKSUM_NAME" > /dev/null
)

mv "$STAGED_DB_DUMP" "$DB_DUMP"
mv "$STAGED_STORAGE_ARCHIVE" "$STORAGE_ARCHIVE"
mv "$STAGED_CHECKSUMS" "$CHECKSUMS"
COMMITTED=true

echo "Backup complete:"
printf '  %s\n' "$DB_DUMP" "$STORAGE_ARCHIVE" "$CHECKSUMS"
