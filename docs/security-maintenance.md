# Security maintenance

Flotilla keeps persistent PHP settings in `config/php/security.ini` and the
LinuxServer services' `php-local.ini` files. Apply these before request parsing
and restart PHP workers after changes. Disabling session upload progress
mitigates specific attack paths; it does not replace PHP runtime patches.

Some services use managed host trust snapshots mounted at
`/run/flotilla-trust`. These support outbound TLS verification independently of
an image's bundled roots. Keep host CA packages current and refresh the
snapshots after trust changes. Continue upgrading application images and
runtimes: a trust override does not fix unrelated vulnerabilities.

## Inventory and TLS checks

Run from the repository root on the Docker host:

```sh
sudo bash scripts/security_audit.sh
sudo python3 scripts/security_tls_audit.py
```

The inventory lists container status, configured health, restarts, OOM state,
PHP versions and selected runtime/CA packages. It omits application logs and
environment dumps. Output still reveals deployment details: keep captured
reports private and review them before sharing. Lack of a healthcheck means
unknown health. CLI and FPM probes do not prove Apache's effective request
configuration; verify that privately without exposing a phpinfo endpoint.

The TLS audit checks available Python system trust, Python certifi, Node,
PHP curl and Java clients against four eMudhra incident test chains, plus a
normal HTTPS control. It sends no application credentials and prints no response
bodies. These are external endpoints; they can observe source IPs, and their
availability or certificates may change.

- `REJECTED`: validation failed for the tested chain.
- `EXPOSED`: the tested client accepted an incident chain.
- `CONTROL_OK`: the normal HTTPS control succeeded.
- `CONTROL_FAILED`: the normal HTTPS control was rejected.
- `UNAVAILABLE` / `INCONCLUSIVE`: no security conclusion can be drawn.

Interpret chain rejections alongside successful controls. These probes do not
cover every compromised chain, application-specific trust configuration or
runtime. Go, Rust, .NET and custom TLS stacks require separate checks.

## Refresh managed trust

The refresh tool defaults to Fedora's extracted PEM and Java stores. It reads
the deployed Compose configuration, discovers services mounting the shared
read-only trust directory, verifies relevant runtime options and certifi paths,
and backs up the previous snapshots. It does not replace Compose or pull images.
It recreates the discovered services using installed images, causing brief
interruptions. All managed consumers must already be running for its preflight.

```sh
sudo python3 scripts/security_trust_apply.py
```

For different host paths:

```sh
sudo python3 scripts/security_trust_apply.py \
  --compose /path/to/docker-compose.yml \
  --pem-bundle /path/to/updated-ca-bundle.pem \
  --java-store /path/to/updated-java-cacerts
```

Supply current, trusted host-generated bundles. The PEM preflight rejects the
two root CAs affected by the eMudhra incident; Java validation relies on the
subsequent JVM handshake tests. Local private CA additions must be present in
the supplied bundles if applications need them.

For a new deployment, provision the Compose-mounted trust directory before
starting its consumers: copy the updated PEM bundle as `ca-bundle.crt`, the
updated Java store as `cacerts`, and create an empty `empty/` directory. Use
readable files (0644) and traversable directories (0755). Then start services
and use the refresh tool for subsequent updates. Keep generated snapshots,
backups and audit outputs outside version control.

After refresh, rerun the TLS and inventory checks and test real application
operations. The tool prints its backup location; it does not automatically
roll back failed service recreation. For rollback, restore the previous trust
files from that backup and recreate the same consumers. Existing client
processes may cache trust, so copying files alone is insufficient.

## Java verification

```sh
sudo bash scripts/security_java_audit.sh
```

This compiles `TrustProbe.java` for Java 11+ using a pinned official JDK image,
then runs the class in the configured Minecraft and Spark/Jupyter services.
Application images may contain only a JRE. The compiler container has no network
access and only its build directory mounted; Docker may download the compiler
image first. No application services are restarted. The generated class is
stored in the managed trust mount for later TLS audits.

Override defaults with `FLOTILLA_COMPOSE_FILE`, `FLOTILLA_TRUST_DIR` and
`JAVA_COMPILER_IMAGE`, passed explicitly to sudo if needed. Supply Compose
service names as positional arguments to select different JVM consumers:

```sh
sudo env FLOTILLA_COMPOSE_FILE=/path/to/docker-compose.yml \
  FLOTILLA_TRUST_DIR=/path/to/security-trust \
  bash scripts/security_java_audit.sh java-service
```

## Tool verification

```sh
python3 -m unittest discover -s tests -v
```

Tests use temporary files and mocked Docker calls. They check trust refresh
preconditions, backups, preservation of Compose files and symlinks, and
recreation without image pulls. They do not certify a live deployment.
