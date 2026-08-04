from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / "scripts"
    / "persist-codex-fast-all-providers.py"
)
SPEC = importlib.util.spec_from_file_location("persist_codex_fast_all", SCRIPT_PATH)
if SPEC is None or SPEC.loader is None:
    raise ImportError(f"Unable to load migration script: {SCRIPT_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def provider_config(
    model: str | None,
    *,
    model_fast: str | None = None,
    reasoning_effort: str | None = None,
    service_tier: str | None = None,
    fast_mode: bool | None = None,
    desktop_tier: str | None = None,
    nested_features: bool = False,
) -> str:
    lines = []
    if model is not None:
        lines.append(f'model = "{model}"')
    if model_fast is not None:
        lines.append(f'model_fast = "{model_fast}"')
    if reasoning_effort is not None:
        lines.append(f'model_reasoning_effort = "{reasoning_effort}"')
    if service_tier is not None:
        lines.append(f'service_tier = "{service_tier}"')
    lines.extend(
        [
            'model_provider = "custom"',
            "[model_providers.custom]",
            'base_url = "https://provider.example/v1"',
            'wire_api = "responses"',
            'service_tier = "transport-default"',
        ]
    )
    if nested_features:
        lines.extend(["[features.multi_agent_v2]", "enabled = true"])
    else:
        lines.append("[features]")
        if fast_mode is not None:
            lines.append(f"fast_mode = {str(fast_mode).lower()}")
    if desktop_tier is not None:
        lines.extend(["[desktop]", f'default-service-tier = "{desktop_tier}"'])
    return "\n".join(lines) + "\n"


def global_config(
    *,
    model: str = "gpt-5.6-sol",
    model_fast: str = "gpt-5.6-luna",
    reasoning_effort: str = "medium",
    service_tier: str | None = "fast",
    fast_mode: bool = True,
    desktop_tier: str = "fast",
    model_catalog: Path | None = None,
) -> str:
    lines = [
        f'model = "{model}"',
        f'model_fast = "{model_fast}"',
        f'model_reasoning_effort = "{reasoning_effort}"',
    ]
    if service_tier is not None:
        lines.append(f'service_tier = "{service_tier}"')
    if model_catalog is not None:
        escaped_catalog = str(model_catalog).replace("\\", "\\\\")
        lines.append(f'model_catalog_json = "{escaped_catalog}"')
    lines.extend(
        [
            "[features]",
            f"fast_mode = {str(fast_mode).lower()}",
            "[desktop]",
            f'default-service-tier = "{desktop_tier}"',
        ]
    )
    return "\n".join(lines) + "\n"


def make_database(root: Path) -> tuple[Path, Path, dict[str, str]]:
    database = root / "cc-switch.db"
    settings_path = root / "settings.json"
    rows = [
        (
            "provider-a",
            "Provider A",
            1,
            json.dumps(
                {
                    "auth": {"OPENAI_API_KEY": "key-a"},
                    "config": provider_config(
                        "gpt-5.5",
                        model_fast="gpt-5.6-luna",
                        reasoning_effort="high",
                    ),
                },
                separators=(",", ":"),
            ),
        ),
        (
            "provider-b",
            "Provider B",
            0,
            json.dumps(
                {
                    "auth": {"OPENAI_API_KEY": "key-b"},
                    "config": provider_config(
                        "gpt-5.6-sol",
                        model_fast="gpt-5.6-sol",
                        reasoning_effort="xhigh",
                        service_tier="standard",
                        fast_mode=False,
                        desktop_tier="standard",
                    ),
                },
                separators=(",", ":"),
            ),
        ),
        (
            "provider-c",
            "Provider C",
            0,
            json.dumps(
                {
                    "auth": {"OPENAI_API_KEY": "key-c"},
                    "config": provider_config(None, nested_features=True),
                },
                separators=(",", ":"),
            ),
        ),
    ]
    connection = sqlite3.connect(database)
    try:
        connection.execute(
            "create table providers ("
            "id text, name text, app_type text, category text, is_current integer, "
            "sort_index integer, settings_config text)"
        )
        connection.executemany(
            "insert into providers values (?, ?, 'codex', null, ?, ?, ?)",
            [(row[0], row[1], row[2], index, row[3]) for index, row in enumerate(rows)],
        )
        connection.commit()
    finally:
        connection.close()
    settings_path.write_text(
        json.dumps({"currentProviderCodex": "provider-a"}), encoding="utf-8"
    )
    originals = {row[0]: row[3] for row in rows}
    return database, settings_path, originals


def provider_rows(database: Path) -> list[tuple[str, str]]:
    connection = sqlite3.connect(database)
    try:
        return connection.execute(
            "select id, settings_config from providers where app_type='codex' order by id"
        ).fetchall()
    finally:
        connection.close()


class PersistCodexGlobalRuntimeTests(unittest.TestCase):
    def test_apply_synchronizes_global_policy_and_preserves_provider_route(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database, settings_path, originals = make_database(root)
            config_path = root / "config.toml"
            config_path.write_text(global_config(), encoding="utf-8")

            preview = MODULE.run_migration(database, settings_path, config_path)
            self.assertEqual(preview["providerCount"], 3)
            self.assertEqual(preview["changedCount"], 3)
            self.assertTrue(preview["allAligned"])
            self.assertEqual(preview["policy"]["modelFast"], "gpt-5.6-luna")

            database_backup = root / "before.db"
            config_backup = root / "before.toml"
            report = MODULE.run_migration(
                database,
                settings_path,
                config_path,
                MODULE.MigrationOptions(
                    apply=True,
                    database_backup_path=database_backup,
                    config_backup_path=config_backup,
                ),
            )
            self.assertTrue(report["allAligned"])
            self.assertTrue(database_backup.is_file())
            self.assertTrue(config_backup.is_file())

            synchronized_global = MODULE.tomllib.loads(
                config_path.read_text(encoding="utf-8")
            )
            self.assert_runtime_policy(synchronized_global, "fast")
            expected_models = {
                "provider-a": ("gpt-5.5", "gpt-5.6-luna"),
                "provider-b": ("gpt-5.6-sol", "gpt-5.6-sol"),
                "provider-c": ("gpt-5.6-sol", "gpt-5.6-luna"),
            }
            for provider_id, raw_settings in provider_rows(database):
                settings = json.loads(raw_settings)
                config = MODULE.tomllib.loads(settings["config"])
                expected_model, expected_model_fast = expected_models[provider_id]
                self.assert_runtime_policy(
                    config,
                    "fast",
                    model=expected_model,
                    model_fast=expected_model_fast,
                )
                self.assertEqual(
                    config["model_providers"]["custom"]["service_tier"],
                    "transport-default",
                )
                self.assertEqual(
                    config["model_providers"]["custom"]["base_url"],
                    "https://provider.example/v1",
                )
                self.assertEqual(
                    settings["auth"], {"OPENAI_API_KEY": f"key-{provider_id[-1]}"}
                )

            self.assertEqual(
                config_backup.read_text(encoding="utf-8"),
                global_config(),
            )
            self.assertEqual(
                {provider_id: raw for provider_id, raw in provider_rows(database_backup)},
                originals,
            )

    def test_standard_removes_service_tier_and_preserves_provider_models(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database, settings_path, _ = make_database(root)
            config_path = root / "config.toml"
            config_path.write_text(global_config(), encoding="utf-8")

            report = MODULE.run_migration(
                database,
                settings_path,
                config_path,
                MODULE.MigrationOptions(apply=True),
                model="gpt-5.6-luna",
                reasoning_effort="low",
                tier="standard",
            )
            self.assertTrue(report["allAligned"])
            expected_models = {
                "provider-a": ("gpt-5.5", "gpt-5.6-luna"),
                "provider-b": ("gpt-5.6-sol", "gpt-5.6-sol"),
                "provider-c": ("gpt-5.6-luna", "gpt-5.6-luna"),
            }
            for provider_id, raw_settings in provider_rows(database):
                config = MODULE.tomllib.loads(json.loads(raw_settings)["config"])
                expected_model, expected_model_fast = expected_models[provider_id]
                self.assert_runtime_policy(
                    config,
                    "standard",
                    model=expected_model,
                    model_fast=expected_model_fast,
                    reasoning_effort="low",
                )

    def test_malformed_provider_aborts_without_partial_update(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database, settings_path, originals = make_database(root)
            config_path = root / "config.toml"
            original_global = global_config()
            config_path.write_text(original_global, encoding="utf-8")
            connection = sqlite3.connect(database)
            try:
                connection.execute(
                    "update providers set settings_config=? where id='provider-c'",
                    (
                        json.dumps(
                            {
                                "auth": {"OPENAI_API_KEY": "key-c"},
                                "config": "model = [",
                            }
                        ),
                    ),
                )
                connection.commit()
            finally:
                connection.close()

            with self.assertRaises(MODULE.FastMigrationError):
                MODULE.run_migration(
                    database,
                    settings_path,
                    config_path,
                    MODULE.MigrationOptions(apply=True),
                )
            rows = dict(provider_rows(database))
            self.assertEqual(rows["provider-a"], originals["provider-a"])
            self.assertEqual(rows["provider-b"], originals["provider-b"])
            self.assertEqual(config_path.read_text(encoding="utf-8"), original_global)

    def test_database_failure_after_first_update_rolls_back_every_resource(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database, settings_path, originals = make_database(root)
            config_path = root / "config.toml"
            original_global = global_config()
            config_path.write_text(original_global, encoding="utf-8")
            connection = sqlite3.connect(database)
            try:
                connection.execute(
                    "create trigger fail_provider_b before update on providers "
                    "when new.id='provider-b' begin select raise(abort, 'injected'); end"
                )
                connection.commit()
            finally:
                connection.close()

            with self.assertRaises(sqlite3.IntegrityError):
                MODULE.run_migration(
                    database,
                    settings_path,
                    config_path,
                    MODULE.MigrationOptions(apply=True),
                )
            self.assertEqual(dict(provider_rows(database)), originals)
            self.assertEqual(config_path.read_text(encoding="utf-8"), original_global)

    def test_quoted_toml_keys_and_tables_are_updated_without_duplicates(self) -> None:
        quoted = "\n".join(
            [
                '"model" = "gpt-5.5"',
                '"model_fast" = "gpt-5.4"',
                '"model_reasoning_effort" = "high"',
                '["features"]',
                '"fast_mode" = false',
                '["features"."multi_agent_v2"]',
                '"enabled" = true',
                '["desktop"]',
                '"followUpQueueMode" = "queue"',
                "",
            ]
        )
        policy = MODULE.RuntimePolicy(
            "gpt-5.6-sol",
            "gpt-5.6-luna",
            "medium",
            "fast",
        )
        updated_text, updated = MODULE.update_runtime_config(quoted, policy)
        self.assert_runtime_policy(updated, "fast")
        self.assertEqual(updated_text.count('["features"]'), 1)
        self.assertEqual(updated_text.count('["desktop"]'), 1)
        self.assertTrue(updated["features"]["multi_agent_v2"]["enabled"])

    def test_unknown_catalog_model_is_rejected_before_writes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            database, settings_path, originals = make_database(root)
            catalog_path = root / "models.json"
            catalog_path.write_text(
                json.dumps({"models": [{"slug": "gpt-5.6-sol"}]}),
                encoding="utf-8",
            )
            config_path = root / "config.toml"
            original_global = global_config(model_catalog=catalog_path)
            config_path.write_text(original_global, encoding="utf-8")

            with self.assertRaises(MODULE.FastMigrationError):
                MODULE.run_migration(
                    database,
                    settings_path,
                    config_path,
                    MODULE.MigrationOptions(apply=True),
                    model="missing-model",
                )
            self.assertEqual(dict(provider_rows(database)), originals)
            self.assertEqual(config_path.read_text(encoding="utf-8"), original_global)

    def assert_runtime_policy(
        self,
        config: dict,
        tier: str,
        *,
        model: str = "gpt-5.6-sol",
        model_fast: str = "gpt-5.6-luna",
        reasoning_effort: str = "medium",
    ) -> None:
        self.assertEqual(config["model"], model)
        self.assertEqual(config["model_fast"], model_fast)
        self.assertEqual(config["model_reasoning_effort"], reasoning_effort)
        self.assertEqual(config["features"]["fast_mode"], tier == "fast")
        self.assertEqual(config["desktop"]["default-service-tier"], tier)
        if tier == "fast":
            self.assertEqual(config["service_tier"], "fast")
        else:
            self.assertNotIn("service_tier", config)


if __name__ == "__main__":
    unittest.main()
