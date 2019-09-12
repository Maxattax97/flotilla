# Flotilla

An easily deployed server based on Docker compose, complete with privacy tools,
a media center, cloud storage, and much more.

## Credentials and Secrets

Credentials are stored in `/opt/flotilla/secrets.env`, a template exists in the
root of this repository. Fill it out so that docker containers may read them.

Unfortunately many containers have yet to accept the standard _Secrets_
feature recently added in Docker.

## Sonarr, Radarr, Lidarr

Enable *Advanced Settings*, then under *Settings > Indexers* add an entry with
at least these settings:

```
Name: Jackett All
Enable RSS Sync: Yes
Enable Search: Yes
URL: http://jackett:9117
API Path: /torznab/all/api
API Key: Get this from the Jackett web terminal
```

This should track all available indexes in Jackett.

Then under *Settings > Download Client*, add an entry with at least these
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

## Jellyfin

Add Libraries for the following internal, shared volumes:

 - `/data/tvshows` as TV Shows from Sonarr
 - `/data/movies` as Movies from Radarr
 - `/data/music` as Music from Lidarr
 - `/data/books` as Books from Calibre?
 - `/data/photos` as Photos from various uploads
