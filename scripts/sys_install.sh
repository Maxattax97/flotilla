#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"
GITROOT="$(dirname "${SCRIPTPATH}")"
COMPOSE_FILE=/opt/flotilla/docker-compose.yml

if [ -s "${SCRIPTPATH}/sys_lib.sh" ]; then
    source "${SCRIPTPATH}/sys_lib.sh"
else
    source "/usr/local/lib/flotilla/scripts/sys_lib.sh"
fi

# TODO: Docker permissions for $USER?

elevate mkdir -p /usr/local/lib/flotilla/
elevated_link_source "${GITROOT}/scripts/" "/usr/local/lib/flotilla/scripts"
elevated_link_source "${GITROOT}/flotilla" "/usr/local/bin/flotilla"

# Install base packages.
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

# Install Gotop.
if [[ "$(probe gotop)" -eq 0 ]]; then
    git clone --depth 1 https://github.com/cjbassi/gotop /tmp/gotop
    /tmp/gotop/scripts/download.sh
    elevate mv ./gotop /usr/local/bin/
fi

# Create Flotilla directories.
elevate mkdir -p /opt/flotilla/data
elevate mkdir -p /opt/flotilla/config

# Setup configuration directories.
for module in $GITROOT/config/*/; do
    dest="/opt/flotilla/config/$(basename "$module")"
    elevated_link_source $module $dest
done

# FIX: OpenVPN config directory. Symlink files into this dir?
#rm -rf /opt/flotilla/config/openvpn

# Install services.
for service in $GITROOT/services/*; do
    dest="/etc/systemd/system/$(basename "$service")"
    # Must copy because symlinks to home fail.
    echo "Copying $service -> $dest ..."
    elevate cp -f $service $dest
done

elevate systemctl daemon-reload

# Enable and start Docker for this host.
elevate systemctl enable docker.service
elevate systemctl status docker.service --no-pager
if [[ "$?" -eq 3 ]]; then
    echo "Docker is not online, starting ..."
    elevate systemctl start docker.service
fi

# Install the docker compose file.
elevated_link_source "${GITROOT}/alpha/docker-compose.yml" "${COMPOSE_FILE}"

# Allow permission to write to volumes in SE Linux.
if [[ "$(probe chcon)" -eq 1 ]]; then
    elevate chcon -RLt svirt_sandbox_file_t /opt/flotilla
fi
elevate chown -RLf "$USER:$USER" /opt/flotilla

# Setup OpenVPN configuration.
if [[ ! -d /opt/flotilla/config/openvpn ]] || [[ ! -d /opt/flotilla/config/openvpn/backup ]]; then
    if [[ "$(probe chcon)" -eq 1 ]]; then
        # SELinux needs some allowances.
        wget https://raw.githubusercontent.com/kylemanna/docker-openvpn/master/docs/docker-openvpn.te -O /tmp/docker-openvpn.te
        checkmodule -M -m -o /tmp/docker-openvpn.mod /tmp/docker-openvpn.te
        semodule_package -o /tmp/docker-openvpn.pp -m /tmp/docker-openvpn.mod
        elevate semodule -i /tmp/docker-openvpn.pp
        elevate modprobe tun
    fi

    # TODO: Might break if included:
    # -T 'TLS-DHE-RSA-WITH-AES-256-GCM-SHA384:TLS-DHE-RSA-WITH-AES-128-GCM-SHA256:TLS-DHE-RSA-WITH-AES-256-CBC-SHA256:TLS-DHE-RSA-WITH-AES-128-CBC-SHA256:TLS-DHE-RSA-WITH-CAMELLIA-256-CBC-SHA:TLS-DHE-RSA-WITH-AES-256-CBC-SHA'
    docker-compose --file "${COMPOSE_FILE}" run --rm openvpn ovpn_genconfig -u udp://vpn.maxocull.com -C 'AES-256-CBC' -a 'SHA384'
    docker-compose --file "${COMPOSE_FILE}" run --rm openvpn ovpn_initpki
    #elevate docker run -v /opt/flotilla/config/openpvn:/etc/openvpn --log-driver=none --rm kylemanna/openvpn ovpn_genconfig -u udp://vpn.maxocull.com
    #elevate docker run -v /opt/flotilla/config/openpvn:/etc/openvpn --log-driver=none --rm -it kylemanna/openvpn ovpn_initpki
fi

# Reset the permissions for any previously ran elevated commands.
if [[ "$(probe chcon)" -eq 1 ]]; then
    elevate chcon -RLt svirt_sandbox_file_t /opt/flotilla
fi
elevate chown -RLf "$USER:$USER" /opt/flotilla
