import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "verify-ccswitch-codex.py"
SPEC = importlib.util.spec_from_file_location("verify_codex", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class VerifyCodexConfigurationTests(unittest.TestCase):
    def make_observed(self) -> dict:
        provider = {
            "id": "provider-a",
            "isCurrent": True,
            "modelProvider": "custom",
            "appProviderName": "custom",
            "model": "gpt-5.6-sol",
            "modelFast": "gpt-5.6-sol",
            "modelCatalogJson": str(MODULE.expected_model_catalog_path()),
            "reasoningEffort": "medium",
            "serviceTier": "fast",
            "fastMode": True,
            "desktopTier": "fast",
            "localeOverride": "zh-CN",
            "baseUrl": "https://provider.example/v1",
            "runCodexInWindowsSubsystemForLinux": False,
            "wslRemoteConnections": False,
            "requiresOpenAIAuth": False,
            "hasExperimentalBearerToken": True,
            "bearerTokenDigest": "digest",
            "authTokenDigest": "digest",
        }
        live = dict(provider)
        live["modifiedAt"] = 0
        return {
            "settingsCurrentProvider": "provider-a",
            "databaseProviders": [provider],
            "databaseCurrentProviders": [provider],
            "live": live,
            "officialAuth": {
                "authMode": None,
                "hasTokens": False,
                "hasApiKey": False,
                "isEmpty": True,
            },
            "proxy": {
                "port17896Open": False,
                "flags": {"enabled": False, "proxy_enabled": False},
            },
            "prodexEnvironment": {
                "pathEntries": [],
                "CODEX_HOME": None,
                "PRODEX_HOME": None,
            },
        }

    def test_global_fast_model_matches_global_model(self) -> None:
        failures = MODULE.consistency_failures("provider-a", self.make_observed())
        self.assertEqual(failures, [])

    def test_distinct_fast_model_is_rejected(self) -> None:
        observed = self.make_observed()
        observed["live"]["modelFast"] = "gpt-5.6-luna"
        observed["databaseCurrentProviders"][0]["modelFast"] = "gpt-5.6-luna"
        observed["databaseProviders"][0]["modelFast"] = "gpt-5.6-luna"
        failures = MODULE.consistency_failures("provider-a", observed)
        self.assertIn("live fast model differs from model", failures)
        self.assertIn("provider provider-a fast model differs from model", failures)
    def test_non_global_catalog_is_rejected(self) -> None:
        observed = self.make_observed()
        observed["live"]["modelCatalogJson"] = "C:\\old\\profile\\catalog.json"
        observed["databaseCurrentProviders"][0]["modelCatalogJson"] = (
            "C:\\old\\profile\\catalog.json"
        )
        failures = MODULE.consistency_failures("provider-a", observed)
        self.assertIn("database model catalog is not the global .codex catalog", failures)

    def test_stored_app_provider_name_drift_is_rejected(self) -> None:
        observed = self.make_observed()
        observed["databaseCurrentProviders"][0]["appProviderName"] = "Provider A"
        failures = MODULE.consistency_failures("provider-a", observed)
        self.assertIn("provider provider-a app provider name is not custom", failures)

    def test_live_app_provider_name_drift_is_rejected(self) -> None:
        observed = self.make_observed()
        observed["live"]["appProviderName"] = "Provider A"
        failures = MODULE.consistency_failures("provider-a", observed)
        self.assertIn("live app provider name is not custom", failures)


if __name__ == "__main__":
    unittest.main()
