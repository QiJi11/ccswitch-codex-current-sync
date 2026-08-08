from __future__ import annotations

import json
import importlib.util
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path


SYNC_SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "sync-codex3-config.py"
SYNC_SPEC = importlib.util.spec_from_file_location("codex3_config_sync", SYNC_SCRIPT)
if SYNC_SPEC is None or SYNC_SPEC.loader is None:
    raise ImportError(f"Unable to load sync script: {SYNC_SCRIPT}")
SYNC_MODULE = importlib.util.module_from_spec(SYNC_SPEC)
sys.modules[SYNC_SPEC.name] = SYNC_MODULE
SYNC_SPEC.loader.exec_module(SYNC_MODULE)

merge_transport_values = SYNC_MODULE.merge_transport_values
plan_sync = SYNC_MODULE.plan_sync


def provider_config(base_url: str, bearer: str | None, model: str) -> str:
    bearer_line = f'experimental_bearer_token = "{bearer}"\n' if bearer else ""
    return (
        f'model = "{model}"\n'
        'model_reasoning_effort = "max"\n'
        'model_provider = "custom"\n'
        '[features]\n'
        'remote_plugin = false\n'
        '[model_providers.custom]\n'
        f'base_url = "{base_url}"\n'
        f'{bearer_line}'
        'wire_api = "responses"\n'
        'requires_openai_auth = false\n'
    )


def provider_row(provider_id: str, name: str, config: str, key: str, current: int = 0):
    settings = {"auth": {"OPENAI_API_KEY": key}, "config": config}
    return (provider_id, name, "", current, json.dumps(settings))


class Codex3ConfigSyncTests(unittest.TestCase):
    def test_merge_preserves_target_transport_values_and_source_behavior(self) -> None:
        source = provider_config("https://source.example/v1", None, "gpt-5.6-sol")
        target = provider_config("https://target.example/v1", "target-bearer", "gpt-5.2")

        merged = merge_transport_values(source, target, "target")

        self.assertIn('model = "gpt-5.6-sol"', merged)
        self.assertIn('model_reasoning_effort = "max"', merged)
        self.assertIn('remote_plugin = false', merged)
        self.assertIn('base_url = "https://target.example/v1"', merged)
        self.assertIn('experimental_bearer_token = "target-bearer"', merged)

    def test_merge_adds_target_only_transport_table(self) -> None:
        source = provider_config("https://source.example/v1", None, "gpt-5.6-sol")
        target = (
            provider_config("https://target.example/v1", "target-bearer", "gpt-5.2")
            + "\n[mcp_servers.openaiDeveloperDocs]\n"
            + 'url = "https://docs.example/mcp"\n'
        )

        merged = merge_transport_values(source, target, "target")

        self.assertIn("[mcp_servers.openaiDeveloperDocs]", merged)
        self.assertIn('url = "https://docs.example/mcp"', merged)

    def test_merge_keeps_target_auth_object_exactly(self) -> None:
        source_config = provider_config("https://source.example/v1", None, "gpt-5.6-sol")
        target_config = provider_config("https://target.example/v1", "target-bearer", "gpt-5.2")
        source_row = provider_row("source", "codex3", source_config, "source-key", 1)
        target_row = provider_row("target", "Provider A", target_config, "target-key")

        with tempfile.TemporaryDirectory() as temp_dir:
            database = Path(temp_dir) / "cc-switch.db"
            connection = sqlite3.connect(database)
            try:
                connection.execute(
                    "create table providers (id text, name text, category text, is_current integer, settings_config text)"
                )
                connection.executemany("insert into providers values (?, ?, ?, ?, ?)", [source_row, target_row])
                connection.commit()
                connection.row_factory = sqlite3.Row
                rows = connection.execute("select * from providers order by id").fetchall()
            finally:
                connection.close()

            source_snapshot, plans = plan_sync(rows, "codex3")
            target_plan = next(plan for plan in plans if plan["id"] == "target")
            self.assertEqual(target_plan["status"], "changed")
            self.assertEqual(target_plan["authDigestBefore"], target_plan["authDigestAfter"])
            self.assertEqual(target_plan["baseHost"], "target.example")
            self.assertEqual(target_plan["baseHostAfter"], "target.example")
            self.assertEqual(target_plan["transportDigestBefore"], target_plan["transportDigestAfter"])
            self.assertEqual(target_plan["settings"]["auth"], {"OPENAI_API_KEY": "target-key"})
            self.assertEqual(source_snapshot.name, "codex3")


if __name__ == "__main__":
    unittest.main()
