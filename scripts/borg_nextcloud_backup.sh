#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-/opt/flotilla/config/borg/entourage.env}"

if [[ -r "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
fi

FLOTILLA_BASE="${FLOTILLA_BASE:-/opt/flotilla}"
COMPOSE_FILE="${COMPOSE_FILE:-${FLOTILLA_BASE}/docker-compose.yml}"
NEXTCLOUD_CONTAINERS="${NEXTCLOUD_CONTAINERS:-nextcloud nextcloud-cron}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-postgres}"
BORG_BACKUP_HOST="${BORG_BACKUP_HOST:?Set BORG_BACKUP_HOST in ${CONFIG_FILE}}"
BORG_BACKUP_USER="${BORG_BACKUP_USER:-borg}"
BORG_REPO_PATH="${BORG_REPO_PATH:-/mnt/backup/repos/entourage}"
BORG_ARCHIVE_PREFIX="${BORG_ARCHIVE_PREFIX:-entourage}"
BORG_PASSPHRASE_FILE="${BORG_PASSPHRASE_FILE:-${FLOTILLA_BASE}/secrets/borg_passphrase}"
NEXTCLOUD_DB_FILE="${NEXTCLOUD_DB_FILE:-${FLOTILLA_BASE}/secrets/nextcloud_postgres_db}"
NEXTCLOUD_DB_USER_FILE="${NEXTCLOUD_DB_USER_FILE:-${FLOTILLA_BASE}/secrets/nextcloud_postgres_user}"
NEXTCLOUD_DB_PASSWORD_FILE="${NEXTCLOUD_DB_PASSWORD_FILE:-${FLOTILLA_BASE}/secrets/nextcloud_postgres_password}"
EXCLUDE_FILE="${EXCLUDE_FILE:-${FLOTILLA_BASE}/config/borg/nextcloud.exclude}"

if [[ ! -r "${BORG_PASSPHRASE_FILE}" ]]; then
    echo "Missing Borg passphrase file: ${BORG_PASSPHRASE_FILE}" >&2
    exit 1
fi

export BORG_PASSPHRASE
BORG_PASSPHRASE="$(< "${BORG_PASSPHRASE_FILE}")"
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=no
export BORG_RSH="${BORG_RSH:-ssh}"

if docker compose version > /dev/null 2>&1; then
    compose=(docker compose --file "${COMPOSE_FILE}")
elif command -v docker-compose > /dev/null 2>&1; then
    compose=(docker-compose --file "${COMPOSE_FILE}")
else
    echo "Neither docker compose nor docker-compose is available." >&2
    exit 1
fi

repo="${BORG_BACKUP_USER}@${BORG_BACKUP_HOST}:${BORG_REPO_PATH}"
archive="${BORG_ARCHIVE_PREFIX}-{now:%Y-%m-%dT%H:%M:%S}"
db_name="$(< "${NEXTCLOUD_DB_FILE}")"
db_user="$(< "${NEXTCLOUD_DB_USER_FILE}")"
db_password="$(< "${NEXTCLOUD_DB_PASSWORD_FILE}")"

backup_paths=(
    "${FLOTILLA_BASE}/docker-compose.yml"
    "${FLOTILLA_BASE}/config/nextcloud"
    "${FLOTILLA_BASE}/config/postgres"
    "${FLOTILLA_BASE}/data/nextcloud"
)

existing_paths=()
for path in "${backup_paths[@]}"; do
    if [[ -e "${path}" ]]; then
        existing_paths+=("${path}")
    else
        echo "Skipping missing path: ${path}" >&2
    fi
done

if [[ "${#existing_paths[@]}" -eq 0 ]]; then
    echo "No Nextcloud paths exist to back up." >&2
    exit 1
fi

restart_nextcloud() {
    read -r -a nextcloud_containers <<< "${NEXTCLOUD_CONTAINERS}"
    "${compose[@]}" start "${nextcloud_containers[@]}" > /dev/null
}
trap restart_nextcloud EXIT

read -r -a nextcloud_containers <<< "${NEXTCLOUD_CONTAINERS}"
"${compose[@]}" stop "${nextcloud_containers[@]}"

"${compose[@]}" exec -T \
    -e "PGPASSWORD=${db_password}" \
    "${POSTGRES_CONTAINER}" \
    pg_dump --format=custom --username "${db_user}" "${db_name}" \
	| borg create \
		--verbose \
		--filter AME \
		--progress \
		--stats \
		--compression zstd,1 \
        --exclude-from "${EXCLUDE_FILE}" \
        --stdin-name postgres/nextcloud.dump \
        "${repo}::${archive}" \
        "${existing_paths[@]}" \
        -
