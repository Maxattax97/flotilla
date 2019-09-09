#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"
GITROOT="$(dirname "${SCRIPTPATH}")"

if [ -s "${SCRIPTPATH}/sys_lib.sh" ]; then
    source "${SCRIPTPATH}/sys_lib.sh"
else
    source "/usr/local/lib/helm/scripts/sys_lib.sh"
fi

elevate mkdir -p /usr/local/lib/helm/
elevated_link_source "${GITROOT}/scripts/" "/usr/local/lib/helm/scripts"
elevated_link_source "${GITROOT}/helm" "/usr/local/bin/helm"

if [[ "$(probe dnf)" -eq 1 ]]; then
    elevate dnf upgrade -y
    elevate dnf install -y \
        docker docker-compose tmux neovim nodejs
elif [[ "$(probe apt)" -eq 1 ]]; then
    elevate apt update
    elevate apt upgrade -y
    elevate apt install -y \
        docker tmux neovim
fi

elevate mkdir -p /opt/flotilla/data
elevate mkdir -p /opt/flotilla/config

for module in $GITROOT/config/*/; do
    dest="/opt/flotilla/config/$(basename "$module")"
    elevated_link_source $module $dest
done

elevate mkdir -p /opt/flotilla/config/heimdall/keys/

for service in $GITROOT/services/*; do
    dest="/etc/systemd/system/$(basename "$service")"
    # Must copy because symlinks to home fail.
    echo "Copying $service -> $dest ..."
    elevate cp -f $service $dest
done

elevate systemctl daemon-reload

elevated_link_source "${GITROOT}/alpha/docker-compose.yml" "/opt/flotilla/docker-compose.yml"

# Allow permission to write to volumes in SE Linux.
elevate chcon -RLt svirt_sandbox_file_t /opt/flotilla
elevate chown -RLf nobody:nobody /opt/flotilla # "${USER}:${USER}" /opt/flotilla
