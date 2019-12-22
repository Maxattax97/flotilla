#!/usr/bin/env bash

# Select which fleet you'd like to install, e.g. alpha, devops, etc.
arg_fleet="${1:-alpha}"

SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"
GITROOT="$(dirname "${SCRIPTPATH}")"
BASE=/opt/flotilla
COMPOSE_FILE="${BASE}/docker-compose.yml"

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
        pwgen suricata pulledpork fail2ban
elif [[ "$(probe apt)" -eq 1 ]]; then
    elevate apt update
    elevate apt upgrade -y
    # TODO: docker-compose nodejs postgresql pwgen suricata pulledpork fail2ban
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
elevate cp "${GITROOT}/config/suricata/*.yaml" /etc/suricata/
elevate cp "${GITROOT}/config/suricata/*.conf" /etc/suricata/
if [[ "$(probe dnf)" -eq 1 ]]; then
    elevate echo "OPTIONS=\"-q 0\"" > /etc/sysconfig/suricata
elif [[ "$(probe apt)" -eq 1 ]]; then
    elevate echo "OPTIONS=\"-q 0\"" > /etc/default/suricata
fi

# Setup Suricata to use the et/open set.
## I decided to only do this one because it's generally agreed that it's the
## best by far and catches the huge majority of threats. Also, performance
## reasons.
elevate suricata-update enable-source et/open

# Update the threat DB.
elevate suricata-update

# Create Flotilla directories.
if [[ -d "/data/" ]]; then
    # Use extended LVM RAID storage if available.
    elevate mkdir -p "/data/flotilla"
    elevated_link_source "/data/flotilla/" "${BASE}/data"
else
    elevate mkdir -p "${BASE}/data"
fi
elevate mkdir -p "${BASE}/config"

# Setup configuration directories.
for module in $GITROOT/config/*/; do
    dest="${BASE}/config/$(basename "$module")"
    elevated_link_source $module $dest
done

# Install fail2ban ssh protection.
elevate cp "${BASE}/config/fail2ban/flotilla.local" "/etc/fail2ban/jail.d/flotilla.local"
elevate systemctl enable fail2ban.service
elevate systemctl start fail2ban.service

# TODO: Make sure all config AND data folders are created so permissions may be set.

# Install services.
for service in $GITROOT/services/*; do
    dest="/etc/systemd/system/$(basename "$service")"
    # Must copy because symlinks to home fail.
    echo "Copying $service -> $dest ..."
    elevate cp -f $service $dest
done

elevate systemctl daemon-reload

# Enable the services.
for service in $GITROOT/services/*; do
    name="$(basename "$service")"
    elevate systemctl enable "$name"
done

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
elevated_link_source "${GITROOT}/${arg_fleet}/docker-compose.yml" "${COMPOSE_FILE}"

# Install the (highly involved) mailu environment file.
elevated_link_source "${GITROOT}/mailu/mailu.env" "${BASE}/mailu.env"

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

# Setup SSH tunnelling for Gitlab.
id -u git
if [[ $? -eq 1 ]]; then
    #wget https://github.com/sameersbn/docker-gitlab/raw/master/contrib/expose-gitlab-ssh-port.sh -O /tmp/setup-git.sh
    #chmod +x /tmp/setup-git.sh
    #elevate /tmp/setup-git.sh

    if ! id -u git >> /dev/null 2>&1; then
        groupadd -g 1010 git
        useradd -m -u 9922 -g git -s /bin/sh -d /home/git git
    fi

    sudo -u git mkdir -p /home/git/.ssh/


    sudo -u git if [ ! -f /home/git/.ssh/id_rsa ]; then \
        ssh-keygen -t rsa -b 4096 -N "" -f /home/git/.ssh/id_rsa; \
    fi
    sudo -u git if [ -f /home/git/.ssh/id_rsa.pub ]; then \
        mv /home/git/.ssh/id_rsa.pub /home/git/.ssh/authorized_keys_proxy; \
    fi

    mkdir -p /home/git/gitlab-shell/bin/
    rm -f /home/git/gitlab-shell/bin/gitlab-shell
    tee -a /home/git/gitlab-shell/bin/gitlab-shell > /dev/null <<EOF
#!/bin/sh
ssh -i /home/git/.ssh/id_rsa -p 9922 -o StrictHostKeyChecking=no git@127.0.0.1 "SSH_ORIGINAL_COMMAND=\"\$SSH_ORIGINAL_COMMAND\" \$0 \$@"
EOF
    chown git:git /home/git/gitlab-shell/bin/gitlab-shell
    chmod u+x /home/git/gitlab-shell/bin/gitlab-shell

    # Symlink authorized keys (provided via web interface) so you don't get a password prompt.
    mkdir -p "${BASE}/data/gitlab/.ssh/"
    chown git:git -R "${BASE}/data/gitlab/.ssh/"
    chown git:git -R /home/git/.ssh
    sudo -u git touch "${BASE}/data/gitlab/.ssh/authorized_keys"
    rm -f /home/git/.ssh/authorized_keys
    sudo -u git ln -s "${BASE}/data/gitlab/.ssh/authorized_keys" /home/git/.ssh/authorized_keys

    rm /tmp/setup-git.sh
fi

# Reset the permissions for any previously ran elevated commands.
if [[ "$(probe chcon)" -eq 1 ]]; then
    elevate chcon -RLt svirt_sandbox_file_t "${BASE}"
fi
elevate chown -RLf "$USER:$USER" "${BASE}"
