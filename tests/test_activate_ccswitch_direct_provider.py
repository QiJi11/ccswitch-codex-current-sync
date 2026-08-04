import importlib.util
from contextlib import closing
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "activate-ccswitch-direct-provider.py"
SPEC = importlib.util.spec_from_file_location("activate_provider", SCRIPT_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


LIVE_CONFIG = '''
model_provider = "custom"
model = "stale-model"
model_fast = "stale-fast-model"
model_reasoning_effort = "low"
service_tier = "standard"
localeOverride = "en-US"

[features]
wsl_remote_connections = true

[model_providers.custom]
base_url = "https://old.example/v1"
name = "old"
requires_openai_auth = false
wire_api = "responses"
experimental_bearer_token = "old-token"
'''

STORED_CONFIG = '''
model_provider = "custom"
model = "gpt-5.6-luna"
model_fast = "gpt-5.6-sol"
model_reasoning_effort = "xhigh"
service_tier = "fast"
localeOverride = "zh-CN"

[model_providers.custom]
base_url = "https://third-party.example/v1"
name = "BLA codex3 0.165 pro"
requires_openai_auth = false
wire_api = "responses"
'''


def stored_route(model: str, model_fast: str, display_name: str = "Provider A") -> object:
    return MODULE.StoredRoute(
        config={
            "model_provider": "custom",
            "model": model,
            "model_fast": model_fast,
            "model_reasoning_effort": "xhigh",
            "service_tier": "fast",
        },
        provider_id="custom",
        provider_table={
            "base_url": "https://third-party.example/v1",
            "name": "custom",
            "requires_openai_auth": False,
            "wire_api": "responses",
        },
        api_key="third-party-token",
        display_name=display_name,
    )


def make_activation_case(
    temporary_directory: str,
) -> tuple[Path, Path, Path, Path, Path]:
    provider_id = "provider-id"
    root = Path(temporary_directory) / "cc-switch"
    codex_root = Path(temporary_directory) / "codex"
    root.mkdir()
    codex_root.mkdir()
    (root / "settings.json").write_text(
        json.dumps({"currentProviderCodex": provider_id}), encoding="utf-8"
    )
    config_path = codex_root / "config.toml"
    config_path.write_text(LIVE_CONFIG, encoding="utf-8")
    database_path = root / "cc-switch.db"
    with closing(sqlite3.connect(database_path)) as connection:
        with connection:
            connection.executescript(
                """
                create table providers (
                    id text, app_type text, name text, is_current integer, settings_config text
                );
                create table proxy_config (
                    app_type text, enabled integer, proxy_enabled integer,
                    live_takeover_active integer
                );
                insert into providers values (
                    'provider-id', 'codex', 'BLA codex3 0.165 pro', 1, ''
                );
                insert into proxy_config values ('codex', 1, 1, 1);
                """
            )
            connection.execute(
                "update providers set settings_config=? where id=?",
                (
                    json.dumps(
                        {
                            "auth": {"OPENAI_API_KEY": "third-party-token"},
                            "config": STORED_CONFIG,
                        }
                    ),
                    provider_id,
                ),
            )
    backup_path = root / "config-before-activation.toml"
    return root, codex_root, config_path, database_path, backup_path


class DirectProviderActivationTests(unittest.TestCase):
    def test_luna_route_preserves_distinct_fast_model(self) -> None:
        _, config = MODULE.rendered_live_config(
            LIVE_CONFIG, stored_route("gpt-5.6-luna", "gpt-5.6-sol")
        )
        self.assertEqual(config["model"], "gpt-5.6-luna")
        self.assertEqual(config["model_fast"], "gpt-5.6-sol")
        self.assertEqual(
            config["model_catalog_json"],
            str(Path.home() / ".codex" / MODULE.MODEL_CATALOG_FILENAME),
        )
        self.assertEqual(config["model_reasoning_effort"], "xhigh")
        self.assertEqual(config["service_tier"], "fast")
        self.assertFalse(config["runCodexInWindowsSubsystemForLinux"])
        self.assertFalse(config["features"]["wsl_remote_connections"])
        self.assertEqual(
            config["model_providers"]["custom"]["base_url"],
            "https://third-party.example/v1",
        )
        self.assertEqual(config["model_providers"]["custom"]["name"], "Provider A")

    def test_sol_route_can_be_activated(self) -> None:
        _, config = MODULE.rendered_live_config(
            LIVE_CONFIG, stored_route("gpt-5.6-sol", "gpt-5.6-sol")
        )
        self.assertEqual(config["model"], "gpt-5.6-sol")
        self.assertEqual(config["model_fast"], "gpt-5.6-sol")

    def test_app_display_name_uses_stable_custom_route(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root, codex_root, config_path, database_path, backup_path = (
                make_activation_case(temporary_directory)
            )
            report = MODULE.activate(root, codex_root, "provider-id", backup_path)
            live_config = MODULE.tomllib.loads(config_path.read_text(encoding="utf-8"))
            with closing(sqlite3.connect(database_path)) as connection:
                name, raw_settings = connection.execute(
                    "select name, settings_config from providers where id='provider-id'"
                ).fetchone()
            stored_config = MODULE.tomllib.loads(json.loads(raw_settings)["config"])

        self.assertEqual(report["providerName"], "custom")
        self.assertEqual(live_config["model_providers"]["custom"]["name"], "custom")
        self.assertEqual(stored_config["model_providers"]["custom"]["name"], "custom")
        self.assertEqual(name, "BLA codex3 0.165 pro")

    def test_replace_provider_display_name_preserves_transport_fields(self) -> None:
        updated = MODULE.replace_provider_display_name(
            LIVE_CONFIG, "custom", "Provider B"
        )
        config = MODULE.tomllib.loads(updated)
        provider = config["model_providers"]["custom"]
        self.assertEqual(provider["name"], "Provider B")
        self.assertEqual(provider["base_url"], "https://old.example/v1")
        self.assertEqual(provider["experimental_bearer_token"], "old-token")

    def test_quoted_provider_table_header_is_supported(self) -> None:
        quoted_config = LIVE_CONFIG.replace(
            "[model_providers.custom]", '["model_providers"."custom"]'
        ).replace('name = "old"', '"name" = "old"')
        _, config = MODULE.rendered_live_config(
            quoted_config, stored_route("gpt-5.6-luna", "gpt-5.6-sol", "Provider Q")
        )
        self.assertEqual(config["model_providers"]["custom"]["name"], "Provider Q")
        self.assertEqual(
            config["model_providers"]["custom"]["base_url"],
            "https://third-party.example/v1",
        )

    def test_official_api_endpoint_is_rejected(self) -> None:
        route = stored_route("gpt-5.6-luna", "gpt-5.6-sol")
        route.provider_table["base_url"] = "https://api.openai.com/v1"
        with self.assertRaises(ValueError):
            MODULE.rendered_live_config(LIVE_CONFIG, route)

    def test_base_url_credentials_and_query_are_rejected(self) -> None:
        for base_url in (
            "https://user:pass@third-party.example/v1",
            "https://third-party.example/v1?fallback=api.openai.com",
            "https://third-party.example/v1#official",
        ):
            with self.subTest(base_url=base_url):
                with self.assertRaises(ValueError):
                    MODULE.validate_direct_base_url(base_url)

    def test_database_failure_restores_live_config(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root, codex_root, config_path, database_path, backup_path = (
                make_activation_case(temporary_directory)
            )
            with closing(sqlite3.connect(database_path)) as connection:
                with connection:
                    connection.execute(
                        """
                        create trigger fail_provider_update before update on providers
                        begin select raise(abort, 'forced activation failure'); end;
                        """
                    )

            with self.assertRaises(sqlite3.DatabaseError):
                MODULE.activate(root, codex_root, "provider-id", backup_path)

            self.assertEqual(config_path.read_text(encoding="utf-8"), LIVE_CONFIG)
            self.assertTrue(backup_path.is_file())
            self.assertTrue(
                (root / "cc-switch-before-activation.db").is_file()
            )


if __name__ == "__main__":
    unittest.main()
