#!/usr/bin/env bash
# loghunt.sh - search a curated set of host logs + docker-compose logs for patterns
#
# Examples:
#   ./loghunt.sh -p '185\.5\.46\.37|Seychelles|/ocs/v2\.php' -i
#   ./loghunt.sh -p 'Login failed|POST /login|/ocs/v2.php/cloud/users' --since '2026-01-17T00:00:00Z'
#   sudo ./loghunt.sh -p 'max|entourage' -n 500 --ctx 2
#
# Notes:
# - Uses ripgrep (rg) if available (fast). Falls back to grep.
# - Optionally searches docker compose service logs from /opt/flotilla/docker-compose.yml
# - For files requiring root (e.g. nextcloud.log), run with sudo.

set -euo pipefail

COMPOSE_DIR="/opt/flotilla"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

PATTERN=""
IGNORE_CASE=0
FIXED=0
CONTEXT=0
MAX_PER_FILE=0
SINCE=""
UNTIL=""
DO_COMPOSE=0
COMPOSE_SERVICES=""
NO_FILES=0

usage() {
    cat << 'EOF'
Usage:
  loghunt.sh -p <pattern> [options]

Required:
  -p, --pattern <pattern>     Pattern to search (regex by default)

Options:
  -i, --ignore-case           Case-insensitive
  -F, --fixed                 Fixed string (no regex)
  -C, --ctx <n>               Show <n> lines of context before/after matches (default 0)
  -n, --max <n>               Max matches per file (0 = unlimited)
  --since <time>              Only include lines after this time (best-effort; string compare)
  --until <time>              Only include lines before this time (best-effort; string compare)
  --compose                   Also search docker compose logs under /opt/flotilla
  --services "a b c"          Limit compose logs to these services (default: all)
  --no-files                  Skip filesystem log files (compose only)
  -h, --help                  Show help

Notes on --since/--until:
  This script does not parse every log format. It does a best-effort filter by
  matching the timestamp prefix as a string. Works well for ISO8601 logs and many
  app logs, less so for custom formats.

EOF
}

need_cmd() {
    command -v "$1" > /dev/null 2>&1
}

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p | --pattern)
            PATTERN="${2:-}"
            shift 2
            ;;
        -i | --ignore-case)
            IGNORE_CASE=1
            shift
            ;;
        -F | --fixed)
            FIXED=1
            shift
            ;;
        -C | --ctx)
            CONTEXT="${2:-0}"
            shift 2
            ;;
        -n | --max)
            MAX_PER_FILE="${2:-0}"
            shift 2
            ;;
        --since)
            SINCE="${2:-}"
            shift 2
            ;;
        --until)
            UNTIL="${2:-}"
            shift 2
            ;;
        --compose)
            DO_COMPOSE=1
            shift
            ;;
        --services)
            COMPOSE_SERVICES="${2:-}"
            shift 2
            ;;
        --no-files)
            NO_FILES=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ -z $PATTERN ]]; then
    echo "Error: --pattern is required" >&2
    usage
    exit 2
fi

# Curated log paths (globs allowed)
LOG_GLOBS=(
    "/opt/flotilla/config/letsencrypt/log/nginx/access.log"
    "/opt/flotilla/config/letsencrypt/log/nginx/error.log"
    "/opt/flotilla/config/bazarr/log/bazarr.log"
    "/opt/flotilla/config/calibre/calibre-web.log"
    "/opt/flotilla/config/cleanroom/supervisord.log"
    "/opt/flotilla/config/heimdall/log/nginx/access.log"
    "/opt/flotilla/config/heimdall/log/heimdall/laravel.log"
    "/opt/flotilla/config/jellyfin/log/*.log"
    "/opt/flotilla/config/lazylibrarian/log/lazylibrarian.log"
    "/opt/flotilla/config/lidarr/logs/lidarr.txt"
    "/opt/flotilla/config/prowlarr/logs/prowlarr.txt"
    "/opt/flotilla/config/qbittorrent/qBittorrent/logs/qbittorrent.log"
    "/opt/flotilla/config/radarr/logs/radarr.txt"
    "/opt/flotilla/config/sonarr/logs/sonarr.txt"
    "/opt/flotilla/data/ejabberd/logs/ejabberd.log"
    "/opt/flotilla/data/minecraft/logs/latest.log"
    "/opt/flotilla/data/monerod/bitmonero.log"
    "/opt/flotilla/data/nextcloud/data/nextcloud.log"
    "/opt/flotilla/data/open-webui/audit.log"
)

# Expand globs safely
expand_globs() {
    local out=()
    local g
    shopt -s nullglob
    for g in "${LOG_GLOBS[@]}"; do
        for f in $g; do
            out+=("$f")
        done
    done
    shopt -u nullglob
    printf '%s\n' "${out[@]}"
}

# Best-effort time filter: assumes timestamps are early in the line.
# If --since/--until not set, pass-through.
time_filter() {
    if [[ -z $SINCE && -z $UNTIL ]]; then
        cat
        return 0
    fi

    # This is intentionally simple: compares the first ~40 chars of each line as a string.
    # Works well for ISO8601 and "YYYY-MM-DD ..." style logs.
    awk -v since="$SINCE" -v until="$UNTIL" '
    {
      prefix = substr($0, 1, 40)
      ok = 1
      if (since != "" && prefix < since) ok = 0
      if (until != "" && prefix > until) ok = 0
      if (ok) print
    }
  '
}

run_search_on_file() {
    local file="$1"

    if [[ ! -r $file ]]; then
        printf 'SKIP (unreadable): %s\n' "$file" >&2
        return 0
    fi

    printf '\n=== FILE: %s ===\n' "$file"

    if need_cmd rg; then
        local args=()
        args+=("--no-heading" "--with-filename" "--line-number" "--color=never")
        [[ $IGNORE_CASE -eq 1 ]] && args+=("-i")
        [[ $FIXED -eq 1 ]] && args+=("-F")
        [[ $CONTEXT -gt 0 ]] && args+=("-C" "$CONTEXT")
        [[ $MAX_PER_FILE -gt 0 ]] && args+=("--max-count" "$MAX_PER_FILE")

        # If time filtering requested, rg alone can't do it robustly across formats; pipe through filter.
        if [[ -n $SINCE || -n $UNTIL ]]; then
            rg "${args[@]}" -- "$PATTERN" "$file" | time_filter || true
        else
            rg "${args[@]}" -- "$PATTERN" "$file" || true
        fi
    else
        # grep fallback (slower, fewer features)
        local gargs=()
        gargs+=("-nH")
        [[ $IGNORE_CASE -eq 1 ]] && gargs+=("-i")
        [[ $FIXED -eq 1 ]] && gargs+=("-F")
        if [[ $CONTEXT -gt 0 ]]; then
            gargs+=("-C" "$CONTEXT")
        fi
        if [[ -n $SINCE || -n $UNTIL ]]; then
            time_filter < "$file" | grep "${gargs[@]}" -- "$PATTERN" || true
        else
            grep "${gargs[@]}" -- "$PATTERN" "$file" || true
        fi
    fi
}

compose_logs() {
    if [[ $DO_COMPOSE -ne 1 ]]; then
        return 0
    fi

    if [[ ! -f $COMPOSE_FILE ]]; then
        printf '\n=== DOCKER COMPOSE LOGS ===\n' >&2
        printf 'SKIP (missing): %s\n' "$COMPOSE_FILE" >&2
        return 0
    fi

    if ! need_cmd docker; then
        printf '\n=== DOCKER COMPOSE LOGS ===\n' >&2
        printf 'SKIP (docker not found)\n' >&2
        return 0
    fi

    # Prefer `docker compose` but fall back to `docker-compose`.
    local compose_cmd=()
    if docker compose version > /dev/null 2>&1; then
        compose_cmd=(docker compose -f "$COMPOSE_FILE")
    elif need_cmd docker-compose; then
        compose_cmd=(docker-compose -f "$COMPOSE_FILE")
    else
        printf '\n=== DOCKER COMPOSE LOGS ===\n' >&2
        printf 'SKIP (docker compose not available)\n' >&2
        return 0
    fi

    printf '\n=== DOCKER COMPOSE LOGS: %s ===\n' "$COMPOSE_FILE"

    # Pull logs once, then search locally.
    # --no-color avoids ANSI noise.
    local tmp=""
    tmp="$(mktemp -t loghunt.compose.XXXXXX)"
    trap 't="${tmp:-}"; [[ -n "$t" ]] && rm -f "$t"' RETURN

    local logargs=("--no-color")
    [[ -n $SINCE ]] && logargs+=("--since" "$SINCE")
    [[ -n $UNTIL ]] && logargs+=("--until" "$UNTIL")

    if [[ -n $COMPOSE_SERVICES ]]; then
        # shellcheck disable=SC2206
        local svcs=($COMPOSE_SERVICES)
        "${compose_cmd[@]}" logs "${logargs[@]}" "${svcs[@]}" > "$tmp" 2> /dev/null || true
    else
        "${compose_cmd[@]}" logs "${logargs[@]}" > "$tmp" 2> /dev/null || true
    fi

    printf -- '--- searching compose logs (bytes: %s) ---\n' "$(wc -c < "$tmp" | tr -d ' ')"

    if need_cmd rg; then
        local args=()
        args+=("--no-heading" "--line-number" "--color=never")
        [[ $IGNORE_CASE -eq 1 ]] && args+=("-i")
        [[ $FIXED -eq 1 ]] && args+=("-F")
        [[ $CONTEXT -gt 0 ]] && args+=("-C" "$CONTEXT")
        [[ $MAX_PER_FILE -gt 0 ]] && args+=("--max-count" "$MAX_PER_FILE")
        rg "${args[@]}" -- "$PATTERN" "$tmp" || true
    else
        local gargs=()
        gargs+=("-n")
        [[ $IGNORE_CASE -eq 1 ]] && gargs+=("-i")
        [[ $FIXED -eq 1 ]] && gargs+=("-F")
        if [[ $CONTEXT -gt 0 ]]; then
            gargs+=("-C" "$CONTEXT")
        fi
        grep "${gargs[@]}" -- "$PATTERN" "$tmp" || true
    fi
}

main() {
    if [[ $NO_FILES -eq 0 ]]; then
        mapfile -t files < <(expand_globs | sort -u)
        if [[ ${#files[@]} -eq 0 ]]; then
            echo "No log files found from configured paths." >&2
        fi
        for f in "${files[@]}"; do
            run_search_on_file "$f"
        done
    fi

    compose_logs
}

main
