#!/usr/bin/env/ bash

# Update base system.
if [[ "$(probe dnf)" -eq 1 ]]; then
    elevate dnf upgrade -y
elif [[ "$(probe apt)" -eq 1 ]]; then
    elevate apt update
    elevate apt upgrade -y
fi

# Update the containers.
docker-compose --file "${COMPOSE_FILE}" stop
# TODO: Perform backup.
# TODO: Pull latest containers.
docker-compose --file "${COMPOSE_FILE}" up -d
