#!/usr/bin/env bash
set -euo pipefail

SCRIPTPATH="$(cd "$(dirname "$0")" || exit; pwd -P)"
GITROOT="$(dirname "${SCRIPTPATH}")"
BASE=/opt/flotilla

if [[ -s "${SCRIPTPATH}/sys_lib.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPTPATH}/sys_lib.sh"
else
    # shellcheck disable=SC1091
    source "/usr/local/lib/flotilla/scripts/sys_lib.sh"
fi

if [[ "$(probe dnf)" -eq 1 ]]; then
    elevate dnf install -y borgbackup openssh-clients
elif [[ "$(probe apt)" -eq 1 ]]; then
    elevate apt update
    elevate apt install -y borgbackup openssh-client
fi

elevate mkdir -p /usr/local/lib/flotilla/scripts
elevate mkdir -p "${BASE}/config/borg" "${BASE}/secrets"
elevated_link_source "${GITROOT}/config/borg/nextcloud.exclude" "${BASE}/config/borg/nextcloud.exclude"

if [[ ! -e "${BASE}/config/borg/entourage.env" ]]; then
    elevate cp "${GITROOT}/config/borg/entourage.env.template" "${BASE}/config/borg/entourage.env"
    echo "Created ${BASE}/config/borg/entourage.env; edit it before enabling backups."
fi

elevate install -m 0755 "${GITROOT}/scripts/borg_nextcloud_backup.sh" "/usr/local/lib/flotilla/scripts/borg_nextcloud_backup.sh"

for unit in flotilla-borg-nextcloud-backup.service flotilla-borg-nextcloud-backup.timer; do
    elevate cp -f "${GITROOT}/systemd/borg/${unit}" "/etc/systemd/system/${unit}"
done

elevate systemctl daemon-reload

if [[ -r "${BASE}/secrets/borg_passphrase" && -r "${BASE}/secrets/entourage_borg_ssh" ]]; then
    elevate systemctl enable --now flotilla-borg-nextcloud-backup.timer
else
    echo "Timer installed but not enabled. Install secrets, then run:"
    echo "  systemctl enable --now flotilla-borg-nextcloud-backup.timer"
    echo "Required secrets:"
    echo "  ${BASE}/secrets/borg_passphrase"
    echo "  ${BASE}/secrets/entourage_borg_ssh"
fi
