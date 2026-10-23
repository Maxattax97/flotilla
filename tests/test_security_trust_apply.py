"""Test trust refresh without Docker, host packages, or privileged writes."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/security_trust_apply.py"


class TrustApplyTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("trust_apply", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.compose = self.root / "compose.yml"
        self.compose.write_text("services: {}\n# preserve deployment settings\n")
        self.trust = self.root / "trust"
        self.trust.mkdir()
        (self.trust / "ca-bundle.crt").write_text("old CA snapshot")
        (self.trust / "TrustProbe.class").write_bytes(b"existing diagnostic")
        self.pem = self.root / "host.pem"
        self.pem.write_text("new public CA snapshot")
        self.java = self.root / "host.jks"
        self.java.write_bytes(b"x" * 1024)
        self.certifi = "/custom/python/site-packages/certifi/cacert.pem"
        self.config = {
            "services": {
                "custom-worker": {
                    "environment": {"NODE_OPTIONS": "--use-openssl-ca"},
                    "volumes": [
                        {
                            "type": "bind",
                            "source": str(self.trust),
                            "target": "/run/flotilla-trust",
                            "read_only": True,
                        },
                        {
                            "type": "bind",
                            "source": str(self.trust / "ca-bundle.crt"),
                            "target": self.certifi,
                            "read_only": True,
                        },
                    ],
                }
            }
        }

    def fake_run(self, *args):
        if "config" in args:
            return json.dumps(self.config)
        if "inspect" in args:
            return json.dumps([{"Config": {"Env": []}}])
        if "python3" in args:
            return self.certifi
        if "-q" in args:
            return "container-id"
        self.fail(f"Unexpected Docker command: {args}")

    def refresh(self, certificates=()):
        context = Mock()
        context.get_ca_certs.return_value = certificates
        with (
            patch.object(self.module, "run", side_effect=self.fake_run),
            patch.object(self.module.os, "geteuid", return_value=0),
            patch.object(
                self.module.ssl, "create_default_context", return_value=context
            ),
            patch.object(self.module.subprocess, "run") as docker,
        ):
            self.module.refresh(self.compose, self.pem, self.java)
        return docker

    def check_refresh(self):
        original = self.compose.read_bytes()
        docker = self.refresh()
        self.assertEqual(self.compose.read_bytes(), original)
        self.assertEqual(
            (self.trust / "ca-bundle.crt").read_bytes(), self.pem.read_bytes()
        )
        self.assertEqual((self.trust / "cacerts").read_bytes(), self.java.read_bytes())
        self.assertEqual(
            (self.trust / "TrustProbe.class").read_bytes(), b"existing diagnostic"
        )
        (backup,) = self.root.glob("security-trust-backup.*")
        self.assertEqual(
            (backup / "security-trust/ca-bundle.crt").read_text(), "old CA snapshot"
        )
        command = docker.call_args.args[0]
        self.assertEqual(command[command.index("--pull") + 1], "never")
        self.assertIn("--force-recreate", command)
        self.assertEqual(command[-1], "custom-worker")

    def test_refresh_preserves_separate_compose(self):
        self.check_refresh()

    def test_refresh_preserves_compose_symlink(self):
        target = self.compose
        self.compose = self.root / "deployed.yml"
        self.compose.symlink_to(target)
        self.check_refresh()
        self.assertTrue(self.compose.is_symlink())

    def test_rejects_affected_roots_before_writes(self):
        certificates = [{"subject": ((("commonName", "AAA Certificate Services"),),)}]
        with self.assertRaisesRegex(SystemExit, "affected root"):
            self.refresh(certificates)
        self.assertEqual((self.trust / "ca-bundle.crt").read_text(), "old CA snapshot")
        self.assertFalse(list(self.root.glob("security-trust-backup.*")))

    def test_rejects_changed_certifi_path_before_writes(self):
        self.config["services"]["custom-worker"]["volumes"][1][
            "target"
        ] = "/other/certifi/cacert.pem"
        with self.assertRaisesRegex(SystemExit, "certifi path differs"):
            self.refresh()
        self.assertEqual((self.trust / "ca-bundle.crt").read_text(), "old CA snapshot")

    def test_rejects_writable_managed_trust(self):
        self.config["services"]["custom-worker"]["volumes"][0]["read_only"] = False
        with self.assertRaisesRegex(SystemExit, "read-only bind"):
            self.refresh()


if __name__ == "__main__":
    unittest.main()
