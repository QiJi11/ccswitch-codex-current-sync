from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "diagnose-codex-run-provider.py"
SPEC = importlib.util.spec_from_file_location("diagnose_codex_run_provider", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise ImportError(f"Unable to load diagnostic script: {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ProviderDiagnosisTests(unittest.TestCase):
    def test_equal_auth_rejections_do_not_claim_key_mismatch(self) -> None:
        for status in (401, 403):
            with self.subTest(status=status):
                diagnosis, message = MODULE.classify(
                    MODULE.ProbeResult(status), MODULE.ProbeResult(status)
                )
                self.assertEqual(diagnosis, "entry_rejection_inconclusive")
                self.assertIn("local key mismatch is not proven", message)

    def test_different_auth_rejections_identify_provider_rejection(self) -> None:
        diagnosis, _ = MODULE.classify(MODULE.ProbeResult(401), MODULE.ProbeResult(403))
        self.assertEqual(diagnosis, "authenticated_request_rejected")

    def test_diagnosis_uses_one_verified_run_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            allowed_root = Path(directory) / "runs"
            run_home = self.write_snapshot(allowed_root)
            observed_keys = []

            def fake_probe(url, api_key, timeout):
                self.assertEqual(url, "https://provider.example/v1/models")
                self.assertEqual(timeout, 2.0)
                observed_keys.append(api_key)
                return MODULE.ProbeResult(200 if api_key else 401)

            report = MODULE.diagnose(run_home, allowed_root, 2.0, fake_probe)
            self.assertEqual(report["diagnosis"], "authenticated")
            self.assertEqual(report["providerId"], "provider-a")
            self.assertEqual(report["model"], "gpt-5.6-sol")
            self.assertEqual(observed_keys, [None, "fixture-key"])
            self.assertNotIn("fixture-key", json.dumps(report))

    def test_auth_hash_mismatch_fails_before_network_probe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            allowed_root = Path(directory) / "runs"
            run_home = self.write_snapshot(allowed_root)
            auth_path = run_home / "auth.json"
            auth = json.loads(auth_path.read_text("utf-8"))
            auth["OPENAI_API_KEY"] = "different-key"
            auth_path.write_text(json.dumps(auth), encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "auth hash"):
                MODULE.diagnose(run_home, allowed_root, 2.0, self.fail_probe)

    def write_snapshot(self, allowed_root: Path) -> Path:
        run_home = allowed_root / "run-a"
        run_home.mkdir(parents=True)
        config_text = (
            'model = "gpt-5.6-sol"\n'
            'model_provider = "custom"\n'
            '[model_providers.custom]\n'
            'base_url = "https://provider.example/v1"\n'
        )
        auth = {"auth_mode": "apikey", "OPENAI_API_KEY": "fixture-key"}
        metadata = {
            "schemaVersion": 2,
            "providerId": "provider-a",
            "codexHome": str(run_home.resolve()),
            "baseUrl": "https://provider.example/v1",
            "model": "gpt-5.6-sol",
            "configSha256": MODULE.digest(config_text),
            "authSha256": MODULE.digest(auth),
        }
        (run_home / "config.toml").write_text(config_text, encoding="utf-8")
        (run_home / "auth.json").write_text(json.dumps(auth), encoding="utf-8")
        (run_home / "run-provider.json").write_text(json.dumps(metadata), encoding="utf-8")
        return run_home

    def fail_probe(self, *_args):
        self.fail("Network probe must not run for an invalid snapshot.")


if __name__ == "__main__":
    unittest.main()
