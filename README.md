# Flotilla

An easily deployed server based on Docker compose, complete with privacy tools,
a media center, cloud storage, and much more.

Currently it is designed with Fedora Server in mind with SELinux set to
enforcing. The Flotilla is protected by Suricated, an intrusion protection
system.

## Installation

There are a handful of different configurations available. `alpha` is the
overarching one which contains nearly all services. `devops` is oriented for
production of solely code. Others may be created at a later time.

Simply run `./flotilla install [alpha | devops]` to install Flotilla. From now
on you may access Flotilla's commands from all contexts (`flotilla status`, no
more `./`)

If you have NAS storage, you can symlink `/opt/flotilla/data` to the mount point.

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

The IPS may be handled via the `flotilla ips` subcommands.

If you have issues, check that `/etc/sysconfig/suricata` is using the `-q 0`
option so that it can execute in inline (IPS) mode and intercept packets!

### Nginx & Let's Encrypt

All that should be required other than tweaking the `docker-compose` file is
adding `/opt/flotilla/config/letsencrypt/nginx/.htpasswd`:

```
# The -B <level> is for bcrypt, you can make it stronger by increasing it up to 17.
htpasswd -B -C .htpasswd <user> # Then fill in the password prompt.

# For additional users:
htpasswd -B .htpasswd <user> # Then fill in the password prompt.
```

### qBittorrent

qBittorrent's web panel is restricted to local-only access. It's default
username and password are `admin` and `adminadmin` respectively. It's
recommended you log in and change them (**Tools > Options > Web UI**) if you
don't bypass the login with whitelisted IP's.

In order for this to work using Sonarr et. al., under **Tools > Options > Downloads**
set **Default Save Path** to `/data`. Set **Monitored Folder** to `/torrents`.

It's recommened you enable Anonymous mode under **Tools > Options > BitTorrent**,
and optionally bump up your queueing and enable not counting slow torrent.

Leave the fixed port (`6881`) alone, it will break otherwise.

### Sonarr, Radarr, Lidarr

Enable **Advanced Settings**, then under **Settings > Indexers** add a
**Torznab** entry with at least these settings:

```
Name: Jackett All
Enable RSS Sync: Yes
Enable Search: Yes
URL: http://jackett:9117
API Path: /torznab/all/api
API Key: <Get this from the Jackett web terminal>
```

This should track all available indexes in Jackett.

Then under **Settings > Download Client**, add an entry with at least these
settings:

```
Name: Flotilla qBittorrent
Enable: Yes
Host: cleanroom
Port: 8800
Username: admin # Unless changed.
Password: adminadmin # Unless changed.
Use SSL: No
```

### Jellyfin

Add Libraries for the following internal, shared volumes:

 - `/data/tvshows` as TV Shows from Sonarr
 - `/data/movies` as Movies from Radarr
 - `/data/music` as Music from Lidarr
 - `/data/books` as Books from Calibre?
 - `/data/photos` as Photos from various uploads

### Postgres & PGAdmin

Login with the **email** and password you specified in the config files.

Click **Add New Server** and fill out:

```
[General]
Name: Flotilla Postgres

[Connection]
Host name/address: postgres
Password: <POSTGRES_PASSWORD from secrets.env>
Save Password: true
```

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
