# Flotilla

An easily deployed server based on Docker compose, complete with privacy tools,
a media center, cloud storage, and much more.

## Installation

There are a handful of different configurations available. `alpha` is the
overarching one which contains nearly all services. `devops` is oriented for
production of solely code. Others may be created at a later time.

Simply run `./flotilla install [alpha | devops]` to install Flotilla. From now
on you may access Flotilla's commands from all contexts (`flotilla status`, no
more `./`)

## Credentials and Secrets

Credentials are stored in `/opt/flotilla/secrets.env`, a template exists in the
root of this repository. Fill it out so that docker containers may read them.

Unfortunately many containers have yet to accept the standard _Secrets_
feature recently added in Docker.

## Services

Some special manual actions are currently are necessary to get a handful of
services running.

### Suricata

The entire swarm is defended by Suricata, an Intrusion Protection System (IPS)
which runs on the host and intercepts malicious packets before they make
contact with containers (or any other service on the host). Suricata
automatically updates rules using a cron job which is performed daily.

Suricata requires some IPTables rules to intercept these packets, so be warned
that while these rules are enabled, Suricata must also be online; otherwise, no
data will pass, and any connections (e.g., SSH) will be terminated.

The IDS may be handled via the `flotilla ids` subcommands.

### Sonarr, Radarr, Lidarr

Enable **Advanced Settings**, then under **Settings > Indexers** add a
**Torznab** entry with at least these settings:

```
Name: Jackett All
Enable RSS Sync: Yes
Enable Search: Yes
URL: http://jackett:9117
API Path: /torznab/all/api
API Key: Get this from the Jackett web terminal
```

This should track all available indexes in Jackett.

Then under **Settings > Download Client**, add an entry with at least these
settings:

```
Name: Harbor qBittorrent
Enable: Yes
Host: cleanroom
Port: 8800
Username: admin
Password: adminadmin
Use SSL: No
```

### Jellyfin

Add Libraries for the following internal, shared volumes:

 - `/data/tvshows` as TV Shows from Sonarr
 - `/data/movies` as Movies from Radarr
 - `/data/music` as Music from Lidarr
 - `/data/books` as Books from Calibre?
 - `/data/photos` as Photos from various uploads

### Gitlab

Create a database for Gitlab inside of Postgres:

```sql
CREATE ROLE gitlab with LOGIN CREATEDB PASSWORD 'password';
CREATE DATABASE gitlabhq_production;
GRANT ALL PRIVILEGES ON DATABASE gitlabhq_production to gitlab;
```

`password` should match the one provided for `POSTGRES_PASSWORD` in
`secrets.env`.

Afterward, create the `pg_trgm` extension on the database with the superuser
(who should be `postgres`).

**TODO**: Automate this procedure.
