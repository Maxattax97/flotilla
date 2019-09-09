#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"
GITROOT="$(dirname "${SCRIPTPATH}")"

if [ -s "${SCRIPTPATH}/sys_lib.sh" ]; then
    source "${SCRIPTPATH}/sys_lib.sh"
else
    source "/usr/local/lib/helm/scripts/sys_lib.sh"
fi

# TODO: Docker permissions for $USER?

elevate mkdir -p /usr/local/lib/helm/
elevated_link_source "${GITROOT}/scripts/" "/usr/local/lib/helm/scripts"
elevated_link_source "${GITROOT}/helm" "/usr/local/bin/helm"

if [[ "$(probe dnf)" -eq 1 ]]; then
    elevate dnf upgrade -y
    elevate dnf install -y \
        docker docker-compose tmux neovim nodejs rsync htop git
elif [[ "$(probe apt)" -eq 1 ]]; then
    elevate apt update
    elevate apt upgrade -y
    # TODO: docker-compose nodejs
    elevate apt install -y \
        docker tmux neovim rsync htop
fi

# Gotop
if [[ "$(probe gotop)" -eq 0 ]]; then
    git clone --depth 1 https://github.com/cjbassi/gotop /tmp/gotop
    /tmp/gotop/scripts/download.sh
    elevate mv ./gotop /usr/local/bin/
fi

elevate mkdir -p /opt/flotilla/data
elevate mkdir -p /opt/flotilla/config

for module in $GITROOT/config/*/; do
    dest="/opt/flotilla/config/$(basename "$module")"
    elevated_link_source $module $dest
done

for service in $GITROOT/services/*; do
    dest="/etc/systemd/system/$(basename "$service")"
    # Must copy because symlinks to home fail.
    echo "Copying $service -> $dest ..."
    elevate cp -f $service $dest
done

elevate systemctl daemon-reload

elevated_link_source "${GITROOT}/alpha/docker-compose.yml" "/opt/flotilla/docker-compose.yml"

# Setup OpenVPN configuration.
if [[ -d /opt/flotilla/config/openvpn ]] && [[ ! -d /opt/flotilla/config/openvpn/backup ]]; then
    if [[ "$(probe chcon)" -eq 1 ]]; then
        # SELinux needs some allowances.
        wget https://raw.githubusercontent.com/kylemanna/docker-openvpn/master/docs/docker-openvpn.te -O /tmp/docker-openvpn.te
        checkmodule -M -m -o /tmp/docker-openvpn.mod /tmp/docker-openvpn.te
        semodule_package -o /tmp/docker-openvpn.pp -m /tmp/docker-openvpn.mod
        elevate semodule -i /tmp/docker-openvpn.pp
        elevate modprobe tun
    fi

    elevate docker run -v /opt/flotilla/config/openpvn:/etc/openvpn --log-driver=none --rm kylemanna/openvpn ovpn_genconfig -u udp://vpn.maxocull.com
    elevate docker run -v /opt/flotilla/config/openpvn:/etc/openvpn --log-driver=none --rm -it kylemanna/openvpn ovpn_initpki
fi

# Allow permission to write to volumes in SE Linux.
elevate chcon -RLt svirt_sandbox_file_t /opt/flotilla
elevate chown -RLf "$USER:$USER" /opt/flotilla
