#!/usr/bin/env bash
# Read-only inventory: no pulls, restarts, config changes, logs, or environment dumps.
set -euo pipefail
command -v docker > /dev/null
if ! docker info --format '{{.ServerVersion}}' > /dev/null; then
    echo 'Docker access required; run this script with sudo on the fleet host.' >&2
    exit 1
fi
printf 'Audit UTC: %s\n' "$(date -u +%FT%TZ)"
echo 'Host packages:'
if command -v rpm > /dev/null; then
    rpm -q ca-certificates docker-ce docker-ce-cli || true
elif command -v dpkg-query > /dev/null; then
    dpkg-query -W ca-certificates docker-ce docker-ce-cli 2> /dev/null || true
fi
echo 'All containers (including stopped):'
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
while IFS= read -r id; do
    [[ -n $id ]] || continue
    docker inspect --format 'Container={{.Name}} image={{.Config.Image}} image_id={{.Image}} restarts={{.RestartCount}} oom={{.State.OOMKilled}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' "$id"
    # Only selected metadata; never print Config.Env or arbitrary application logs.
    docker exec "$id" sh -c '
        echo "Runtime and trust package inventory:"
        if command -v apk >/dev/null; then
            apk list --installed ca-certificates ca-certificates-bundle 2>/dev/null || true
        elif command -v dpkg-query >/dev/null; then
            dpkg-query -W ca-certificates "php*-fpm" "libapache2-mod-php*" 2>/dev/null || true
        elif command -v rpm >/dev/null; then
            rpm -q ca-certificates php php-fpm 2>/dev/null || true
        fi
        if command -v php >/dev/null; then
            php -r '\''echo "PHP ", PHP_VERSION, " CLI upload_progress=", ini_get("session.upload_progress.enabled"), "\n"; $v=PHP_VERSION; $min=["8.2"=>"8.2.35","8.3"=>"8.3.36","8.4"=>"8.4.27","8.5"=>"8.5.12"]; $branch=PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION; echo isset($min[$branch]) && version_compare($v,$min[$branch],">=") ? "PHP2Shell: upstream version meets minimum\n" : "PHP2Shell: VERIFY vendor backport or upgrade\n";'\''
            php --ini
        fi
        for fpm in php-fpm php-fpm8.2 php-fpm8.3 php-fpm8.4 php-fpm8.5 php-fpm82 php-fpm83 php-fpm84 php-fpm85; do
            if command -v "$fpm" >/dev/null; then
                "$fpm" -i 2>/dev/null | grep -E "^(PHP Version|Loaded Configuration|Scan this dir|session.upload_progress.enabled|session.serialize_handler)" || true
            fi
        done
        if command -v node >/dev/null; then node --version; fi
        if command -v python3 >/dev/null; then
            python3 --version
            python3 -c "import importlib.metadata as m; print(\"certifi\", m.version(\"certifi\"))" 2>/dev/null || true
        fi
        if command -v java >/dev/null; then java -version 2>&1 | head -n 3; fi
        if command -v go >/dev/null; then go version; fi
    ' || echo 'Inventory incomplete: container lacks a shell or a probe failed.'
done < <(docker ps -q)
echo 'IMPORTANT: CLI/FPM probes do not prove effective Apache request settings.'
echo 'Verify Apache PHP settings privately, then remove any diagnostic endpoint.'
echo 'CA package versions do not prove bundled runtime trust is fixed; see docs/security-maintenance.md.'
