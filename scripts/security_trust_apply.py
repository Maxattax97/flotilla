#!/usr/bin/env python3
"""Refresh managed container CA snapshots without changing Compose or images."""

import argparse
import hashlib
import json
import os
import shutil
import ssl
import subprocess
import tempfile
from pathlib import Path

TRUST_TARGET = "/run/flotilla-trust"
BLOCKED_ROOTS = {"AAA Certificate Services", "emSign ECC Root CA - G3"}


def run(*args):
    return subprocess.run(
        args, check=True, capture_output=True, text=True
    ).stdout.strip()


def managed_services(config):
    """Find consumers and their shared host trust directory in resolved Compose."""
    services = {}
    sources = set()
    for name, service in config["services"].items():
        mounts = service.get("volumes", [])
        for mount in mounts:
            if mount.get("target") == TRUST_TARGET:
                if mount.get("type") != "bind" or not mount.get("read_only"):
                    raise SystemExit(
                        f"{name}: managed trust must be a read-only bind mount."
                    )
                sources.add(Path(mount["source"]))
                services[name] = service
    if len(sources) != 1:
        raise SystemExit("Expected one shared managed trust directory in Compose.")
    return services, sources.pop()


def refresh(compose, pem_bundle, java_store):
    if os.geteuid() != 0:
        raise SystemExit("Run with sudo.")
    # Resolve the deployed configuration, retaining all local settings and symlinks.
    config = json.loads(
        run("docker", "compose", "-f", str(compose), "config", "--format", "json")
    )
    services, trust = managed_services(config)
    context = ssl.create_default_context(cafile=str(pem_bundle))
    for cert in context.get_ca_certs():
        names = {
            value
            for rdn in cert["subject"]
            for key, value in rdn
            if key == "commonName"
        }
        if names & BLOCKED_ROOTS:
            raise SystemExit(
                "Host PEM bundle still contains an affected root; update host trust first."
            )
    if not java_store.is_file() or java_store.stat().st_size < 1000:
        raise SystemExit("Host Java trust store missing or empty.")
    if (trust / "empty").exists() and any((trust / "empty").iterdir()):
        raise SystemExit("Expected empty OpenSSL certificate directory.")
    # Check runtime-specific mounts and options before writing anything.
    for name, service in services.items():
        ids = run(
            "docker", "compose", "-f", str(compose), "ps", "-q", name
        ).splitlines()
        if len(ids) != 1:
            raise SystemExit(f"{name}: expected one running container.")
        metadata = json.loads(run("docker", "inspect", ids[0]))[0]
        env = dict(
            item.split("=", 1)
            for item in metadata["Config"].get("Env", [])
            if "=" in item
        )
        desired = service.get("environment") or {}
        for key in ("NODE_OPTIONS", "JAVA_TOOL_OPTIONS"):
            if key in desired and env.get(key) and env[key] != desired[key]:
                raise SystemExit(
                    f"{name}: existing {key} needs merging before deployment."
                )
        if env.get("NODE_EXTRA_CA_CERTS"):
            raise SystemExit(f"{name}: extra Node trust requires review.")
        for mount in service.get("volumes", []):
            if mount["target"].endswith("/certifi/cacert.pem"):
                if Path(mount["source"]) != trust / "ca-bundle.crt" or not mount.get(
                    "read_only"
                ):
                    raise SystemExit(
                        f"{name}: certifi must use the read-only managed PEM snapshot."
                    )
                actual = run(
                    "docker",
                    "exec",
                    ids[0],
                    "python3",
                    "-c",
                    "import certifi; print(certifi.where())",
                )
                if actual != mount["target"]:
                    raise SystemExit(
                        f"{name}: certifi path differs from Compose; update its mount first."
                    )
    backup = Path(tempfile.mkdtemp(prefix="security-trust-backup.", dir=trust.parent))
    if trust.exists():
        shutil.copytree(trust, backup / "security-trust")
    print(f"Trust backup: {backup}", flush=True)
    trust.mkdir(mode=0o755, parents=True, exist_ok=True)
    (trust / "empty").mkdir(mode=0o755, exist_ok=True)
    for source, name in [(pem_bundle, "ca-bundle.crt"), (java_store, "cacerts")]:
        destination = trust / name
        destination.write_bytes(source.read_bytes())
        destination.chmod(0o644)
    provenance = "\n".join(
        f"{name} sha256={hashlib.sha256(source.read_bytes()).hexdigest()}"
        for source, name in [(pem_bundle, "ca-bundle.crt"), (java_store, "cacerts")]
    )
    (trust / "SOURCE.txt").write_text(provenance + "\n")
    subprocess.run(
        [
            "docker",
            "compose",
            "-f",
            str(compose),
            "up",
            "-d",
            "--no-deps",
            "--no-build",
            "--pull",
            "never",
            "--force-recreate",
            "--timeout",
            "120",
            *services,
        ],
        check=True,
    )
    print(
        "Trust refreshed using installed images. Run the TLS and health audits, then verify application operations."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--compose", type=Path, default=Path("/opt/flotilla/docker-compose.yml")
    )
    parser.add_argument(
        "--pem-bundle",
        type=Path,
        default=Path("/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"),
    )
    parser.add_argument(
        "--java-store",
        type=Path,
        default=Path("/etc/pki/ca-trust/extracted/java/cacerts"),
    )
    args = parser.parse_args()
    refresh(args.compose, args.pem_bundle, args.java_store)


if __name__ == "__main__":
    main()
