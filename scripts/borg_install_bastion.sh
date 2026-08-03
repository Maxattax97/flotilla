#!/usr/bin/env bash
set -euo pipefail

SCRIPTPATH="$(
    cd "$(dirname "$0")" || exit
    pwd -P
)"
GITROOT="$(dirname "${SCRIPTPATH}")"
BASE=/opt/flotilla
REPO_PATH="${BORG_REPO_PATH:-/mnt/backup/repos/entourage}"
PUBLIC_KEY_FILE="${BORG_ENTOURAGE_PUBLIC_KEY_FILE:-${BASE}/secrets/entourage_borg_ssh.pub}"
PASSPHRASE_FILE="${BORG_PASSPHRASE_FILE:-${BASE}/secrets/borg_passphrase}"

if [[ -s "${SCRIPTPATH}/sys_lib.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPTPATH}/sys_lib.sh"
else
    # shellcheck disable=SC1091
    source "/usr/local/lib/flotilla/scripts/sys_lib.sh"
fi

if [[ "$(probe dnf)" -eq 1 ]]; then
    elevate dnf install -y borgbackup openssh-server
elif [[ "$(probe apt)" -eq 1 ]]; then
    elevate apt update
    elevate apt install -y borgbackup openssh-server
fi

elevate mkdir -p /usr/local/lib/flotilla/borg
if ! id -u borg > /dev/null 2>&1; then
    elevate useradd --system --create-home --home-dir /var/lib/borg --shell /bin/sh borg
else
    elevate usermod --home /var/lib/borg --shell /bin/sh borg
fi

elevate mkdir -p "$(dirname "${REPO_PATH}")" "${BASE}/secrets"
elevate mkdir -p "${BASE}/config/borg"
if [[ ! -e "${BASE}/config/borg/repository.env" ]]; then
    elevate cp "${GITROOT}/config/borg/repository.env.template" "${BASE}/config/borg/repository.env"
fi
elevate chown -R borg:borg "$(dirname "${REPO_PATH}")"
elevate chmod 0750 "$(dirname "${REPO_PATH}")"

if [[ ! -d "${REPO_PATH}" ]]; then
    if ! elevate test -r "${PASSPHRASE_FILE}"; then
        echo "Missing Borg passphrase file: ${PASSPHRASE_FILE}" >&2
        exit 1
    fi
    passphrase="$(elevate cat "${PASSPHRASE_FILE}")"
    elevate runuser -u borg -- env BORG_PASSPHRASE="${passphrase}" borg init --encryption=repokey-blake2 "${REPO_PATH}"
fi

elevate install -d -m 0700 -o borg -g borg /var/lib/borg/.ssh
elevate touch /var/lib/borg/.ssh/authorized_keys
elevate chown borg:borg /var/lib/borg/.ssh/authorized_keys
elevate chmod 0600 /var/lib/borg/.ssh/authorized_keys

if elevate test -r "${PUBLIC_KEY_FILE}"; then
    key="$(elevate cat "${PUBLIC_KEY_FILE}")"
    restricted="command=\"borg serve --append-only --restrict-to-repository ${REPO_PATH}\",restrict ${key}"
    if ! elevate grep -Fxq "${restricted}" /var/lib/borg/.ssh/authorized_keys; then
        printf '%s\n' "${restricted}" | elevate tee -a /var/lib/borg/.ssh/authorized_keys > /dev/null
    fi
else
    echo "Missing Entourage Borg public key: ${PUBLIC_KEY_FILE}" >&2
    echo "Copy /opt/flotilla/secrets/entourage_borg_ssh.pub from Entourage to this path, then rerun this installer." >&2
    exit 1
fi

elevate systemctl enable --now ssh || elevate systemctl enable --now sshd
for script in borg_repo_check.sh borg_repo_prune_compact.sh; do
    elevate install -m 0755 "${GITROOT}/scripts/${script}" "/usr/local/lib/flotilla/borg/${script}"
done

for unit in flotilla-borg-repo-check.service flotilla-borg-repo-check.timer flotilla-borg-repo-prune-compact.service flotilla-borg-repo-prune-compact.timer; do
    elevate cp -f "${GITROOT}/systemd/borg/${unit}" "/etc/systemd/system/${unit}"
done

elevate systemctl daemon-reload
elevate systemctl reset-failed flotilla-borg-repo-check.service flotilla-borg-repo-check.timer flotilla-borg-repo-prune-compact.service flotilla-borg-repo-prune-compact.timer || true
elevate systemctl enable --now flotilla-borg-repo-check.timer
elevate systemctl enable --now flotilla-borg-repo-prune-compact.timer
