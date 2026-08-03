#!/usr/bin/env bash
set -euo pipefail

SCRIPTPATH="$(
    cd "$(dirname "$0")" || exit
    pwd -P
)"
GITROOT="$(dirname "${SCRIPTPATH}")"
BASE=/opt/flotilla
BORG_SSH_KEY="${BORG_SSH_KEY:-${BASE}/secrets/entourage_borg_ssh}"

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
elevate chmod 0700 "${BASE}/secrets"
elevated_link_source "${GITROOT}/config/borg/nextcloud.exclude" "${BASE}/config/borg/nextcloud.exclude"

if [[ ! -e "${BORG_SSH_KEY}" ]]; then
    elevate ssh-keygen -t ed25519 -f "${BORG_SSH_KEY}" -N "" -C "entourage borg backup"
    elevate chmod 0600 "${BORG_SSH_KEY}"
    elevate chmod 0644 "${BORG_SSH_KEY}.pub"
fi

if [[ ! -e "${BASE}/config/borg/entourage.env" ]]; then
    elevate cp "${GITROOT}/config/borg/entourage.env.template" "${BASE}/config/borg/entourage.env"
    echo "Created ${BASE}/config/borg/entourage.env; edit it before enabling backups."
fi

install_flotilla_script "${GITROOT}/scripts/borg_nextcloud_backup.sh"

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
    echo "  ${BORG_SSH_KEY}"
fi

echo "Copy this public key to bastion at ${BASE}/secrets/entourage_borg_ssh.pub:"
elevate cat "${BORG_SSH_KEY}.pub"
