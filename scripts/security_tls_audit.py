#!/usr/bin/env python3
"""Read-only direct TLS probes: no response bodies, credentials or logs printed."""

import concurrent.futures
import subprocess
import sys

HOSTS = [
    "dv-g3b-emudhra.we-have-a-problem.com",
    "dv-g3b-aaa-emudhra.we-have-a-problem.com",
    "dv-g3b-noct-emudhra.we-have-a-problem.com",
    "dv-g3b-aaa-noct-emudhra.we-have-a-problem.com",
    "www.php.net",  # Positive control: trusted HTTPS must still work.
]
PYTHON_PROBE = """
import socket, ssl, sys
host, mode = sys.argv[1:]
try:
    if mode == 'certifi':
        import certifi
        context = ssl.create_default_context(cafile=certifi.where())
    else:
        context = ssl.create_default_context()
    with socket.create_connection((host,443), timeout=6) as conn:
        with context.wrap_socket(conn, server_hostname=host):
            print('EXPOSED: TLS accepted compromised chain')
except ssl.SSLCertVerificationError:
    print('REJECTED: certificate validation failed')
except ImportError:
    print('UNAVAILABLE: certifi not installed')
except Exception as exc:
    print('INCONCLUSIVE:', type(exc).__name__)
"""
NODE_PROBE = """
const tls = require('tls');
const host = process.argv[1];
const s = tls.connect({host, port:443, servername:host, rejectUnauthorized:true});
s.setTimeout(6000, () => { console.log('INCONCLUSIVE: timeout'); s.destroy(); });
s.on('secureConnect', () => { console.log('EXPOSED: TLS accepted compromised chain'); s.destroy(); });
s.on('error', e => console.log(/CERT|ISSUER|VERIFY|SELF_SIGNED/.test(e.code || '') ? 'REJECTED: certificate validation failed' : 'INCONCLUSIVE: '+e.code));
"""
PHP_PROBE = """
if (!function_exists('curl_init')) { echo "UNAVAILABLE: PHP curl missing\n"; exit; }
$c=curl_init('https://'.$argv[1].'/');
curl_setopt_array($c,[CURLOPT_PROXY=>'',CURLOPT_CONNECTTIMEOUT=>6,CURLOPT_TIMEOUT=>8,CURLOPT_NOBODY=>true,CURLOPT_RETURNTRANSFER=>true,CURLOPT_SSL_VERIFYPEER=>true,CURLOPT_SSL_VERIFYHOST=>2]);
$r=curl_exec($c); $n=curl_errno($c);
echo $n===60 ? "REJECTED: certificate validation failed\n" : ($r!==false ? "EXPOSED: TLS accepted compromised chain\n" : "INCONCLUSIVE: curl error ".$n."\n");
"""


def probe(item):
    container, engine, host, args = item
    try:
        result = subprocess.run(
            ["docker", "exec", container, *args],
            capture_output=True,
            text=True,
            timeout=12,
            check=False,
        )
        output = result.stdout.strip()
        # Do not echo arbitrary container errors or response data.
        if not output.startswith(
            ("EXPOSED:", "REJECTED:", "INCONCLUSIVE:", "UNAVAILABLE:")
        ):
            output = "UNAVAILABLE: executable missing or probe failed"
    except subprocess.TimeoutExpired:
        output = "INCONCLUSIVE: probe timeout"
    if host == "www.php.net":
        if output.startswith("EXPOSED:"):
            output = "CONTROL_OK: trusted HTTPS accepted"
        elif output.startswith("REJECTED:"):
            output = "CONTROL_FAILED: trusted HTTPS rejected"
    return f"{container}\t{engine}\t{host}\t{output}"


def main():
    result = subprocess.run(
        ["docker", "ps", "--format", "{{.Names}}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        sys.exit("Docker access required; run with sudo.")
    jobs = []
    for container in result.stdout.splitlines():
        for host in HOSTS:
            for engine, args in [
                ("python-system", ["python3", "-c", PYTHON_PROBE, host, "system"]),
                ("python-certifi", ["python3", "-c", PYTHON_PROBE, host, "certifi"]),
                ("node", ["node", "-e", NODE_PROBE, host]),
                ("php-curl", ["php", "-r", PHP_PROBE, host]),
                (
                    "java",
                    [
                        "java",
                        "-Xmx64m",
                        "-cp",
                        "/run/flotilla-trust",
                        "TrustProbe",
                        host,
                    ],
                ),
            ]:
                jobs.append((container, engine, host, args))
    print(
        "Direct TLS checks; REJECTED covers only the tested client and chain.",
        flush=True,
    )
    print("Missing engines and network failures are unknown, never a pass.", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for line in pool.map(probe, jobs):
            print(line, flush=True)
    print(
        "Java probes require the class deployed by security_java_audit.sh. Go, Rust, .NET and application-specific trust still need vendor verification."
    )


if __name__ == "__main__":
    main()
