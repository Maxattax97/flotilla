#!/usr/bin/env bash
set -euo pipefail

SCRIPTPATH="$(
    cd "$(dirname "$0")" || exit
    pwd -P
)"
GITROOT="$(dirname "${SCRIPTPATH}")"
BASE=/opt/flotilla
BORG_SSH_KEY="${BORG_SSH_KEY:-${BASE}/secrets/entourage_borg_ssh}"
BORG_SSH_CONFIG="${BORG_SSH_CONFIG:-${BASE}/config/borg/ssh_config}"
BORG_KNOWN_HOSTS="${BORG_KNOWN_HOSTS:-${BASE}/config/borg/known_hosts}"

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

elevate mkdir -p /usr/local/lib/flotilla/borg
elevate mkdir -p "${BASE}/config/borg" "${BASE}/secrets"
elevate chmod 0700 "${BASE}/secrets"
elevated_link_source "${GITROOT}/config/borg/nextcloud.exclude" "${BASE}/config/borg/nextcloud.exclude"

if [[ ! -e "${BORG_SSH_CONFIG}" ]]; then
    elevate cp "${GITROOT}/config/borg/ssh_config.template" "${BORG_SSH_CONFIG}"
    echo "Created ${BORG_SSH_CONFIG}; edit HostName if bastion is not resolvable."
fi
elevate chmod 0644 "${BORG_SSH_CONFIG}"
elevate touch "${BORG_KNOWN_HOSTS}"
elevate chmod 0644 "${BORG_KNOWN_HOSTS}"
if ! elevate grep -q '^    HostKeyAlias bastion$' "${BORG_SSH_CONFIG}"; then
    elevate tee -a "${BORG_SSH_CONFIG}" > /dev/null << EOF
    HostKeyAlias bastion
EOF
fi
if ! elevate grep -q '^    UserKnownHostsFile /opt/flotilla/config/borg/known_hosts$' "${BORG_SSH_CONFIG}"; then
    elevate tee -a "${BORG_SSH_CONFIG}" > /dev/null << EOF
    UserKnownHostsFile /opt/flotilla/config/borg/known_hosts
    StrictHostKeyChecking yes
    BatchMode yes
EOF
fi

bastion_hostname="$(ssh -F "${BORG_SSH_CONFIG}" -G bastion | while read -r key value; do
    if [[ "${key}" == "hostname" ]]; then
        printf '%s\n' "${value}"
        break
    fi
done)"
if [[ -n "${bastion_hostname}" ]] && ! elevate grep -q '^bastion ' "${BORG_KNOWN_HOSTS}"; then
    ssh-keyscan "${bastion_hostname}" 2> /dev/null | while read -r host key_type key_value; do
        if [[ "${host}" == \#* || -z "${key_value}" ]]; then
            continue
        fi
        printf 'bastion %s %s\n' "${key_type}" "${key_value}"
    done | elevate tee -a "${BORG_KNOWN_HOSTS}" > /dev/null
fi

if [[ ! -e "${BORG_SSH_KEY}" ]]; then
    elevate ssh-keygen -t ed25519 -f "${BORG_SSH_KEY}" -N "" -C "entourage borg backup"
    elevate chmod 0600 "${BORG_SSH_KEY}"
    elevate chmod 0644 "${BORG_SSH_KEY}.pub"
fi

if [[ ! -e "${BASE}/config/borg/entourage.env" ]]; then
    elevate cp "${GITROOT}/config/borg/entourage.env.template" "${BASE}/config/borg/entourage.env"
    echo "Created ${BASE}/config/borg/entourage.env; edit it before enabling backups."
elif ! elevate grep -q '^BORG_RSH="ssh -F /opt/flotilla/config/borg/ssh_config"$' "${BASE}/config/borg/entourage.env"; then
    elevate cp "${BASE}/config/borg/entourage.env" "${BASE}/config/borg/entourage.env.bak"
    elevate sed -i 's|^BORG_RSH=.*|BORG_RSH="ssh -F /opt/flotilla/config/borg/ssh_config"|' "${BASE}/config/borg/entourage.env"
    echo "Updated BORG_RSH in ${BASE}/config/borg/entourage.env; backup saved as entourage.env.bak."
fi

elevate install -m 0755 "${GITROOT}/scripts/borg_nextcloud_backup.sh" "/usr/local/lib/flotilla/borg/borg_nextcloud_backup.sh"

for unit in flotilla-borg-nextcloud-backup.service flotilla-borg-nextcloud-backup.timer; do
    elevate cp -f "${GITROOT}/systemd/borg/${unit}" "/etc/systemd/system/${unit}"
done

elevate systemctl daemon-reload
elevate systemctl reset-failed flotilla-borg-nextcloud-backup.service flotilla-borg-nextcloud-backup.timer || true

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
