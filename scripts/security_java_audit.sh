#!/usr/bin/env bash
# Compile and deploy a TLS diagnostic into the existing shared mount; no restarts.
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="${FLOTILLA_COMPOSE_FILE:-/opt/flotilla/docker-compose.yml}"
trust_dir="${FLOTILLA_TRUST_DIR:-/opt/flotilla/config/security-trust}"
compiler_image="${JAVA_COMPILER_IMAGE:-eclipse-temurin:17-jdk@sha256:fe947d993c32dd9cf651a4353a6ed723c2370b3a9d034ea4cab4775404ea531a}"
[[ $EUID -eq 0 ]] || {
    echo 'Run with sudo.' >&2
    exit 1
}
install -m 644 "$repo_dir/scripts/TrustProbe.java" "$trust_dir/TrustProbe.java"
# Compile once for Java 11+; application images may intentionally contain only a JRE.
# The compiler has no network access and sees only the probe source and output dir.
compile_dir="$(mktemp -d /tmp/flotilla-java-probe.XXXXXXXX)"
trap 'rm -rf -- "$compile_dir"' EXIT
cp "$repo_dir/scripts/TrustProbe.java" "$compile_dir/TrustProbe.java"
docker run --rm --network none --read-only --cap-drop ALL \
    --security-opt no-new-privileges --tmpfs /tmp \
    -v "$compile_dir:/probe:Z" -w /probe \
    "$compiler_image" javac --release 11 TrustProbe.java
install -m 644 "$compile_dir/TrustProbe.class" "$trust_dir/TrustProbe.class"
printf 'Java TLS audit UTC: %s\n' "$(date -u +%FT%TZ)"
if [[ $# -eq 0 ]]; then
    set -- minecraft spark-master spark-worker jupyterlab
fi
container_ids=()
for service in "$@"; do
    container_id="$(docker compose -f "$compose_file" ps -q "$service")"
    [[ -n $container_id ]] || {
        echo "Missing container: $service"
        exit 1
    }
    container_ids+=("$container_id")
    for host in dv-g3b-emudhra.we-have-a-problem.com dv-g3b-aaa-emudhra.we-have-a-problem.com dv-g3b-noct-emudhra.we-have-a-problem.com dv-g3b-aaa-noct-emudhra.we-have-a-problem.com www.php.net; do
        printf '%s\t%s\t' "$service" "$host"
        # Keep compiler errors visible: a failed probe must never look like a pass.
        result="$(docker exec "$container_id" java -Xmx64m -cp /run/flotilla-trust TrustProbe "$host")"
        if [[ $host == www.php.net ]]; then
            case "$result" in
                EXPOSED:*) result='CONTROL_OK: trusted HTTPS accepted' ;;
                REJECTED:*) result='CONTROL_FAILED: trusted HTTPS rejected' ;;
            esac
        fi
        printf '%s\n' "$result"
    done
done
echo 'For www.php.net, CONTROL_OK is the expected successful handshake.'
echo 'For the other four hosts, REJECTED is the expected result.'
docker inspect --format '{{.Name}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}} restarts={{.RestartCount}} oom={{.State.OOMKilled}}' "${container_ids[@]}"
