#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-/opt/flotilla/config/borg/repository.env}"

if [[ -r "${CONFIG_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"
fi

BORG_REPO_PATH="${BORG_REPO_PATH:-/mnt/backup/repos/entourage}"
BORG_PASSPHRASE_FILE="${BORG_PASSPHRASE_FILE:-/opt/flotilla/secrets/borg_passphrase}"

export BORG_PASSPHRASE
BORG_PASSPHRASE="$(<"${BORG_PASSPHRASE_FILE}")"

borg check --verbose "${BORG_REPO_PATH}"
