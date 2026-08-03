#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-/opt/flotilla/config/borg/repository.env}"

if [[ -r "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
fi

BORG_REPO_PATH="${BORG_REPO_PATH:-/mnt/backup/repos/entourage}"
BORG_ARCHIVE_GLOB="${BORG_ARCHIVE_GLOB:-entourage-*}"
BORG_PASSPHRASE_FILE="${BORG_PASSPHRASE_FILE:-/opt/flotilla/secrets/borg_passphrase}"
BORG_KEEP_WEEKLY="${BORG_KEEP_WEEKLY:-8}"
BORG_KEEP_MONTHLY="${BORG_KEEP_MONTHLY:-24}"
BORG_KEEP_YEARLY="${BORG_KEEP_YEARLY:-5}"

export BORG_PASSPHRASE
BORG_PASSPHRASE="$(<"${BORG_PASSPHRASE_FILE}")"

borg prune \
    --verbose \
    --list \
    --stats \
    --glob-archives "${BORG_ARCHIVE_GLOB}" \
    --keep-weekly "${BORG_KEEP_WEEKLY}" \
    --keep-monthly "${BORG_KEEP_MONTHLY}" \
    --keep-yearly "${BORG_KEEP_YEARLY}" \
    "${BORG_REPO_PATH}"

borg compact --verbose "${BORG_REPO_PATH}"
