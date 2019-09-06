#!/usr/bin/env bash

SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"
source "${SCRIPTPATH}/sys_lib.sh"

elevate

if [[ "$(probe dnf)" -eq 1 ]]; then
    dnf install -y \
        docker tmux neovim
elif [[ "$(probe apt)" -eq 1 ]]; then
    apt install -y \
        docker tmux neovim
fi
