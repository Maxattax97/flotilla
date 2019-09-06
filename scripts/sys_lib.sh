#!/usr/bin/env bas

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
