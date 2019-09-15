#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"
GITROOT="$(dirname "${SCRIPTPATH}")"
COMPOSE_FILE=/opt/flotilla/docker-compose.yml
BASE=/opt/flotilla

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
        docker docker-compose tmux neovim nodejs rsync htop git postgresql \
        pwgen suricata pulledpork
elif [[ "$(probe apt)" -eq 1 ]]; then
    elevate apt update
    elevate apt upgrade -y
    # TODO: docker-compose nodejs postgresql pwgen suricata pulledpork
    elevate apt install -y \
        docker tmux neovim rsync htop
fi

# Install Gotop.
if [[ "$(probe gotop)" -eq 0 ]]; then
    git clone --depth 1 https://github.com/cjbassi/gotop /tmp/gotop
    /tmp/gotop/scripts/download.sh
    elevate mv ./gotop /usr/local/bin/
fi

# Install pyyaml for Suricata.
elevate pip2 install pyyaml
# Install the default Suricata config tweaked for IPS instead of IDS settings.
elevate cp "${GITROOT}/config/suricata/suricata.yaml" /etc/suricata/suricata.yaml
# Setup Suricata to use the et/open set.
## I decided to only do this one because it's generally agreed that it's the
## best by far and catches the huge majority of threats. Also, performance
## reasons.
elevate suricata-update enable-source et/open
# Update the threat DB.
elevate suricata-update

# Create Flotilla directories.
elevate mkdir -p "${BASE}/data"
elevate mkdir -p "${BASE}/config"

# Setup configuration directories.
for module in $GITROOT/config/*/; do
    dest="${BASE}/config/$(basename "$module")"
    elevated_link_source $module $dest
done

# TODO: Make sure all config AND data folders are created so permissions may be set.

# Install services.
for service in $GITROOT/services/*; do
    dest="/etc/systemd/system/$(basename "$service")"
    # Must copy because symlinks to home fail.
    echo "Copying $service -> $dest ..."
    elevate cp -f $service $dest
done

elevate systemctl daemon-reload

# Enable Cockpit on Fedora systems.
if [[ "$(probe dnf)" -eq 1 ]]; then
    elevate systemctl enable --now cockpit.socket
fi

# Enable and start Docker for this host.
elevate systemctl enable docker.service
elevate systemctl status docker.service --no-pager
if [[ "$?" -eq 3 ]]; then
    echo "Docker is not online, starting ..."
    elevate systemctl start docker.service
fi

# Install the docker compose file.
elevated_link_source "${GITROOT}/alpha/docker-compose.yml" "${COMPOSE_FILE}"

# Allow permissions in SE Linux.
if [[ "$(probe chcon)" -eq 1 ]]; then
    # For volumes.
    elevate chcon -RLt svirt_sandbox_file_t "${BASE}"

    # For network tunneling.
    wget https://raw.githubusercontent.com/kylemanna/docker-openvpn/master/docs/docker-openvpn.te -O /tmp/docker-openvpn.te
    checkmodule -M -m -o /tmp/docker-openvpn.mod /tmp/docker-openvpn.te
    semodule_package -o /tmp/docker-openvpn.pp -m /tmp/docker-openvpn.mod
    elevate semodule -i /tmp/docker-openvpn.pp
    elevate modprobe tun

    # For Docker sockets.
    wget https://raw.githubusercontent.com/dpw/selinux-dockersock/master/dockersock.te -O /tmp/dockersock.te
    checkmodule -M -m -o /tmp/dockersock.mod /tmp/dockersock.te
    semodule_package -o /tmp/dockersock.pp -m /tmp/dockersock.mod
    elevate semodule -i /tmp/dockersock.pp

    rm -rf /tmp/*.{te,mod,pp}
fi
elevate chown -RLf "$USER:$USER" "${BASE}"

# Setup OpenVPN configuration.
if [[ ! -s "${BASE}/config/openvpn/crl.pem" ]]; then
    docker-compose --file "${COMPOSE_FILE}" run --rm openvpn ovpn_genconfig -u udp://vpn.maxocull.com
    docker-compose --file "${COMPOSE_FILE}" run --rm openvpn ovpn_initpki

    # Replace the original openvpn config file, if it was destroyed.
    mv -f ${BASE}/config/openvpn/openvpn.conf.* "${BASE}/config/openvpn/openvpn.conf"
else
    echo "Skipping OpenVPN as it already has keys."
fi

# Setup the cleanroom VPN.
# Prefer a VPN which: supports P2P, not thirteen eyes, ...
preferred_nord_vpn="ee22"
if [[ ! -e "${BASE}/config/cleanroom/openvpn/${preferred_nord_vpn}.nordvpn.com.udp.ovpn" ]]; then
    # Reference the server types here:
    # https://api.nordvpn.com/server
    wget https://downloads.nordcdn.com/configs/archives/servers/ovpn.zip -O /tmp/nordvpn.zip
    unzip /tmp/nordvpn.zip -d /tmp/nordvpn
    mkdir -p "${BASE}/config/cleanroom/openvpn/"
    cp "/tmp/nordvpn/ovpn_udp/${preferred_nord_vpn}.nordvpn.com.udp.ovpn" "${BASE}/config/cleanroom/openvpn/"

    rm -rf /tmp/nordvp*
fi

# Setup Gitlab database in Postgres.
if [[ ! -d "${BASE}/data/postgres" ]]; then
    #docker-compose --file "${COMPOSE_FILE}" up -d postgres
    # TODO: Needs a delay here.
    # TODO: Needs to dynamically retrieve the password from the secrets.env file.
    # TODO: Needs to not overwrite and existing database.
    echo "Please initialize the Gitlab database manually."
    #docker-compose --file "${COMPOSE_FILE}" stop postgres
fi

# Reset the permissions for any previously ran elevated commands.
if [[ "$(probe chcon)" -eq 1 ]]; then
    elevate chcon -RLt svirt_sandbox_file_t "${BASE}"
fi
elevate chown -RLf "$USER:$USER" "${BASE}"
