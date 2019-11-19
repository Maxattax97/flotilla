#!/usr/bin/env bash

silence() {
    eval "$@" > /dev/null 2>&1
}

probe() {
    if silence type "$1"; then
        echo "1"
    else
        echo "0"
    fi
}

elevate() {
    if [ "$(id -u)" != 0 ]; then
        if [ "$(probe sudo)" -ne 0 ]; then
            if silence sudo -n -v; then
                sudo "$@"
            else
                echo "Attempting to elevate to root ..."
                if [ -z "$1" ]; then
                    sudo -v
                else
                    sudo "$@"
                fi
            fi
        else
            echo "This operation cannot be performed on a system without sudo. Please either execute this script as root or setup sudo."
            exit 1
        fi
    fi
}

# NOTE: The trailing slash MATTERS!
# link_source "/home/max/src/config/i3/" "/home/max/.config/i3"
link_source() {
    src="${1}"
    dest="${2}"
    elevated="${3}"
    if [ -h "$dest" ]; then
        echo "Skipping $dest because it is already linked ..."
    elif [ -f "$dest" ]; then
        echo "Skipping $dest because a file exists there ..."
    elif [ -d "$dest" ]; then
        echo "Skipping $dest because a directory exists there ..."
    else
        echo "Linking $src -> $dest ..."
        if [ "${elevated}" -ne 0 ]; then
            elevate ln -sf "$src" "$dest"
        else
            ln -sf "$src" "$dest"
        fi
    fi
}

elevated_link_source() {
    link_source "${1}" "${2}" "1"
}
