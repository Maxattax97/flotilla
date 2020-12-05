# Flotilla

An easily deployed server based on Docker compose, complete with privacy tools,
a media center, cloud storage, and much more.

Currently it is designed with Fedora Server in mind with SELinux set to
enforcing. The Flotilla is protected by Suricata, an intrusion prevention
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

The entire swarm is defended by Suricata, an Intrusion Prevention System (IPS)
which runs on the host and intercepts malicious packets before they make
contact with containers (or any other service on the host). Suricata
automatically updates rules using a cron job which is performed daily.

Suricata requires some IPTables rules to intercept these packets, so be warned
that while these rules are enabled, Suricata must also be online; otherwise, no
data will pass, and any connections (e.g., SSH) will be terminated.

The IPS may be handled via the `flotilla ips` subcommands.

If you have issues, check that `/etc/sysconfig/suricata` is using the `-q 0`
option so that it can execute in inline (IPS) mode and intercept packets! It
must also be running in repeat mode (with masks), or else it will skip all
other filters (effectively making your firewall useless).

### FirewallD

FirewallD is used to intelligently manage IPTables. It will not manage Docker
services due to it's independent firewall, and it does not manage Suricata.

Firewall commands are accessible via `flotilla fw` subcommands.

### Nginx & Let's Encrypt

All that should be required other than tweaking the `docker-compose` file is
adding `/opt/flotilla/config/letsencrypt/nginx/.htpasswd`:

```
# The -C <level> is for bcrypt, you can make it stronger by increasing it up to 17.
htpasswd -B -C 10 -c .htpasswd <user> # Then fill in the password prompt.

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
Username: admin         # Unless changed.
Password: adminadmin    # Unless changed.
Use SSL: No
```

Connect your download client folder under **Settings > Download Client > Remote
Path Mappings** by filling in these settings:

```
Host: cleanroom
Remote Path: /data/
Local Path: /data/
```

When you add a new `{Series,Movie,Song}`, you'll want to set the path it gets
placed in to `{/tv/,/movies/,/music/}` respectively.

If this is exposed to the internet, you'll likely want to add authentication as
well, which is configurable under **Settings > General > Security**. You'll
likely also want to turn some quality settings down since they start on
unlimited.

### Jellyfin

Add Libraries for the following internal, shared volumes:

 - `/data/tvshows` as TV Shows from Sonarr
 - `/data/movies` as Movies from Radarr
 - `/data/music` as Music from Lidarr
 - `/data/books` as Books from Calibre?
 - `/data/photos` as Photos from various uploads

If you see an endlessly spinning circle on the webpage, clear your browser cache
for the page.

Optionally enable hardware accelerated transcoding under
**Dashboard > Playback > Transcoding**, VAAPI-enabled devices should already be
mounted into the Jellyfin container.

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

### Nextcloud

Create a database for Nextcloud inside of Postgres:

```sql
CREATE USER nextcloud WITH PASSWORD 'password';
CREATE DATABASE nextcloud TEMPLATE template0 ENCODING 'UNICODE';
ALTER DATABASE nextcloud OWNER TO nextcloud;
GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
```

`password` should match the one provided for `POSTGRES_PASS` in
`secrets.env`.

Any extra domains must be added to `config/nextcloud/config.php` in addition to
a few extra settings like so:
```php
  'trusted_proxies' =>
  array (
    0 => 'letsencrypt',
  ),
  'trusted_domains' =>
  array (
    0 => 'cloud.maxocull.com',
    1 => 'cloud.maxocull.net',
  ),
  'overwriteprotocol' => "https",
  'overwritehost' => "cloud.maxocull.com",
  'overwrite.cli.url' => 'https://cloud.maxocull.com/',
```

### Gitlab

Create a database for Gitlab inside of Postgres:

```sql
CREATE ROLE gitlab with LOGIN CREATEDB PASSWORD 'password';
CREATE DATABASE gitlabhq_production;
GRANT ALL PRIVILEGES ON DATABASE gitlabhq_production to gitlab;
```

`password` should match the one provided for `DB_PASS` in
`secrets.env`. This use should have permission to create databases, but he does
not have to be superuser. Afterward, create the `pg_trgm` extension on the
database with the superuser (who should be `postgres`).

Since the host will be using port 22, this container will share it by creating a
`git` user on the host and SSH tunnelling into the Docker network's Gitlab
instance. This requires ~symlinking~ manually copying  SSH keys from the
container volume bind mount into the local `git` user's `.ssh` folder. See
[here](https://github.com/sameersbn/docker-gitlab/blob/master/docs/exposing-ssh-port.md)
for more details. It must be manually copied because of SELinux permissions;
container security contexts may not mix with `sshd` contexts of a different user.

The Gitlab Runner must be connected to the Gitlab instance. Paste the key from
the web UI into the `REGISTRATION_TOKEN` environment variable.

Gitlab must also connect to a Docker registry to host Docker images. This shares
the letsencrypt certificates to make API calls.

**TODO**: Automate this procedure.
**TODO**: Automate update of SSH keys, possibly with inotify/crond/incrontab.

### Heimdall

Any services you add which contact an API will require the hostname of the
_Docker container_ and their port listed. As an example, for qBittorrent you
would enter:

```
URL: cleanroom:8800
Username: admin         # Unless changed.
Password: adminadmin    # Unless changed.
```

### LazyLibrarian

Some configuration options should be set.

- **Config > Interface > Access Control**: Set a WebServer login
- **Config > Interface > Startup**: Enable API
- **Config > Interface > Appearance**: Set to `flatly`
- **Config > Interface > OPDS Server**: Enable, require credentials, leave credentials empty, enable metadata
- **Config > Downloaders > Torrents**: Enable qBittorrent, `cleanroom:8800`, `admin` and `adminadmin` (unless changed), `/downloads`
- **Config > Providers > Torznab Providers**: Name it `Jackett All`, enable, `http://jackett:9117/torznab/all`, enter the API key from the Jackett webpage
- **Config > Providers > Direct Download Providers**: You may have to change the mirror (`libgen.pw`, `gen.lib.rus.ec`, ...), set one to use `search.php` and the other `foreignfiction/index.php`, enable Z-Library as well with `b-ok.cc`
- **Config > Processing > Calibre**: Set the `calibredb` import program to `/usr/bin/calibredb`

### Calibre

Setup LazyLibrarian first to generate a databse. Otherwise, you must manually
generate a metadata.db file and upload it to `/books` using Calibre desktop. It
is unfortunate that the main project does not support automatically generating
this file.

At the setup menu, enter these values:

```
Location of Calibre databse: /books
Enable uploading: true
Use Calibre's ebook converter: true
Path to convertertool: /usr/bin/ebook-convert
Location of Unrar binary: /usr/bin/unrar
```

The default login is `admin` and `admin123`. Change these.

### Mayan EDMS

Mayan needs a database, create one in our existing Postgres DB. First make a
user `mayan` with the password you specified (`$MAYAN_DATABASE_PASSWORD`), then
make a database named `mayan` owned by the `mayan` user.

If after first run it doesn't provide a web dialog with a password, the
initialization failed. Try again by running: `docker-compose exec mayan /opt/mayan-edms/bin/mayan-edms.py initialsetup`.

Configure the email account:

```
Label: maxocull.com Gmail
Default: true
Enabled: true
Host: smtp.gmail.com
Port: 587
Use TLS: true
Use SSL: false
Username: maxocull.com
Password: <Gmail password, does not need an app password, should match $SMTP_PASSWORD>
From: max.ocull@gmail.com
```

### BigBlueButton and Greenlight

Create a database for Greenlight inside of Postgres:

```sql
CREATE USER greenlight WITH PASSWORD 'password';
CREATE DATABASE greenlight_production;
ALTER DATABASE greenlight_production OWNER TO greenlight;
GRANT ALL PRIVILEGES ON DATABASE greenlight_production TO greenlight;
```

`password` should match the one provided for `DB_PASSWORD` in
`secrets.env`.

You'll need to generate secret keys for BBB and Greenlight and place them in `secrets.env`.

### Wireguard

Fedora does not load the wireguard module by default. To load it on boot,
create a file at `/etc/modules-load.d/wireguard.conf` with contents:

```
wireguard
```

Then run `sudo modprobe wireguard` to load it without rebooting.

**TODO**: Document config process.

## TODO List

- [NordVPN router](https://hub.docker.com/r/bubuntux/nordvpn)
- Switching to [Deluge](https://hub.docker.com/r/linuxserver/deluge)
- Set Jackett to use VPN rather than proxy
- [Shadowsocks](https://hub.docker.com/r/shadowsocks/shadowsocks-libev) proxy server through the VPN (does this gain me anything?)
- Matomo/Piwik for analytics
- A TOR node, then hosting an onion site
- An IRC server
