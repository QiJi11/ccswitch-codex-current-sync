import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path


SCRIPT = Path(
    os.environ.get(
        "OVERLAY_SCRIPT",
        Path(__file__).resolve().parents[1] / "scripts" / "apply-browser-trust-overlay.py",
    )
).resolve()
PINNED_HASH = "a" * 64
RUNTIME_HASH = "b" * 64
RUNTIME_VERSION = "26.0.0"
NATIVE_PIPE = r"\\.\pipe\codex-computer-use-12345678-1234-1234-1234-123456789abc"
BROWSER_CLIENT = b"trusted browser client fixture"
COMPUTER_USE_CLIENT = b"trusted computer use client fixture"
BROWSER_CLIENT_HASH = hashlib.sha256(BROWSER_CLIENT).hexdigest()
COMPUTER_USE_CLIENT_HASH = hashlib.sha256(COMPUTER_USE_CLIENT).hexdigest()
TRUSTED_RUNTIME_HASHES = ",".join(
    (RUNTIME_HASH, BROWSER_CLIENT_HASH, COMPUTER_USE_CLIENT_HASH)
)

DESTINATION = """\
model = "provider-model"
model_provider = "custom"

[model_providers.custom]
name = "Provider"
base_url = "https://provider.invalid/v1"

[mcp_servers.keep]
command = "keep-command"

[marketplaces.openai-bundled]
source_type = "local"
source = "stale-marketplace"
last_updated = "stale"

[marketplaces.keep]
source_type = "local"
source = "keep-marketplace"

[mcp_servers.node_repl]
command = "stale-node-repl"

[mcp_servers.node_repl.env]
STALE = "1"

[plugins."browser@openai-bundled"]
enabled = false

[plugins."computer-use@openai-bundled"]
enabled = false

[plugins."browser@browser-repair"]
enabled = true
"""

RUNTIME = f"""\
model = "global-model"
model_provider = "global"

[model_providers.global]
name = "Must Not Leak"

[mcp_servers.node_repl]
command = "current-node-repl"
args = []

[mcp_servers.node_repl.env]
NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S = "{TRUSTED_RUNTIME_HASHES}"
BROWSER_USE_CODEX_APP_VERSION = "{RUNTIME_VERSION}"
NODE_REPL_NODE_PATH = "current-node"
NODE_REPL_NODE_MODULE_DIRS = "current-node-modules"
CODEX_CLI_PATH = "current-codex"
SKY_CUA_NATIVE_PIPE = "1"
SKY_CUA_NATIVE_PIPE_DIRECTORY = {json.dumps(NATIVE_PIPE)}

[mcp_servers.must_not_leak]
command = "secret-command"

[plugins."browser@openai-bundled"]
enabled = true
channel = "stable"

[plugins."computer-use@openai-bundled"]
enabled = true
channel = "stable"

[plugins."computer-use@openai-bundled".settings]
mode = "native"

[plugins."chrome@openai-bundled"]
enabled = true
"""


class BrowserRuntimeOverlayTests(unittest.TestCase):
    def create_runtime_marketplace(self, root: Path) -> Path:
        resources = root / "Store Package [signed]/app/resources"
        bundle = resources / "plugins/openai-bundled"
        marketplace_path = bundle / ".agents/plugins/marketplace.json"
        marketplace_path.parent.mkdir(parents=True)

        plugins = []
        client_payloads = {
            "browser": ("browser-client.mjs", BROWSER_CLIENT),
            "computer-use": ("computer-use-client.mjs", COMPUTER_USE_CLIENT),
        }
        for plugin_name, (client_name, client_payload) in client_payloads.items():
            plugin_root = bundle / "plugins" / plugin_name
            manifest_path = plugin_root / ".codex-plugin/plugin.json"
            client_path = plugin_root / "scripts" / client_name
            manifest_path.parent.mkdir(parents=True)
            client_path.parent.mkdir(parents=True)
            manifest_path.write_text(
                json.dumps({"name": plugin_name, "version": RUNTIME_VERSION}),
                encoding="utf-8",
            )
            client_path.write_bytes(client_payload)
            plugins.append(
                {
                    "name": plugin_name,
                    "source": {
                        "source": "local",
                        "path": f"./plugins/{plugin_name}",
                    },
                }
            )

        marketplace_path.write_text(
            json.dumps({"name": "openai-bundled", "plugins": plugins}),
            encoding="utf-8",
        )
        runtime_root = resources / "cua_node"
        (runtime_root / "bin/node_modules").mkdir(parents=True)
        (runtime_root / "bin/node_repl.exe").write_bytes(b"store node_repl")
        (runtime_root / "bin/node.exe").write_bytes(b"store node")
        (resources / "codex.exe").write_bytes(b"store codex")
        (runtime_root / "manifest.json").write_text(
            json.dumps(
                {
                    "node_repl_path": "bin/node_repl.exe",
                    "node_path": "bin/node.exe",
                    "node_modules": "bin/node_modules",
                }
            ),
            encoding="utf-8",
        )
        return bundle

    def create_runtime_cache(self, root: Path, bundle: Path) -> dict[str, Path]:
        resources = bundle.parents[1]
        store_runtime = resources / "cua_node"
        cache_root = root / "App Runtime Cache [user]/OpenAI/Codex"
        runtime_root = cache_root / "runtimes/cua_node/runtime-version"
        (runtime_root / "bin/node_modules").mkdir(parents=True)
        (runtime_root / "manifest.json").write_bytes(
            (store_runtime / "manifest.json").read_bytes()
        )
        (runtime_root / "bin/node_repl.exe").write_bytes(
            (store_runtime / "bin/node_repl.exe").read_bytes()
        )
        (runtime_root / "bin/node.exe").write_bytes(
            (store_runtime / "bin/node.exe").read_bytes()
        )
        codex_path = cache_root / "bin/codex-version/codex.exe"
        codex_path.parent.mkdir(parents=True)
        codex_path.write_bytes((resources / "codex.exe").read_bytes())
        return {
            "root": cache_root,
            "node_repl": runtime_root / "bin/node_repl.exe",
            "node": runtime_root / "bin/node.exe",
            "node_modules": runtime_root / "bin/node_modules",
            "codex": codex_path,
        }

    def run_overlay(
        self,
        runtime: str,
        destination: str = DESTINATION,
        *,
        include_marketplace: bool = True,
        mutate_bundle=None,
        mutate_runtime_cache=None,
        require_bundle: bool = True,
        use_store_runtime_paths: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], str, str]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            trust_path = root / "trust.json"
            input_path = root / "provider.toml"
            runtime_path = root / "runtime.toml"
            output_path = root / "output.toml"
            trust_path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "trustedBrowserClientSha256": [PINNED_HASH],
                    }
                ),
                encoding="utf-8",
            )
            input_path.write_text(destination, encoding="utf-8")
            bundle = self.create_runtime_marketplace(root)
            runtime_cache = self.create_runtime_cache(root, bundle)
            if mutate_bundle is not None:
                mutate_bundle(bundle)
            if mutate_runtime_cache is not None:
                mutate_runtime_cache(runtime_cache)
            if use_store_runtime_paths:
                resources = bundle.parents[1]
                runtime_paths = {
                    "node_repl": resources / "cua_node/bin/node_repl.exe",
                    "node": resources / "cua_node/bin/node.exe",
                    "node_modules": resources / "cua_node/bin/node_modules",
                    "codex": resources / "codex.exe",
                }
            else:
                runtime_paths = runtime_cache
            runtime_text = runtime
            runtime_replacements = {
                "current-node-repl": runtime_paths["node_repl"],
                "current-node": runtime_paths["node"],
                "current-node-modules": runtime_paths["node_modules"],
                "current-codex": runtime_paths["codex"],
            }
            for placeholder, replacement in runtime_replacements.items():
                runtime_text = runtime_text.replace(
                    json.dumps(placeholder), json.dumps(str(replacement))
                )
            runtime_path.write_text(runtime_text, encoding="utf-8")
            arguments = [
                sys.executable,
                str(SCRIPT),
                "--trust-file",
                str(trust_path),
                "--input",
                str(input_path),
                "--output",
                str(output_path),
                "--runtime-source",
                str(runtime_path),
            ]
            if require_bundle:
                arguments.append("--require-compatible-runtime-bundle")
            if include_marketplace:
                arguments.extend(("--runtime-marketplace-source", str(bundle)))
            arguments.extend(("--runtime-cache-source", str(runtime_cache["root"])))
            completed = subprocess.run(
                arguments,
                capture_output=True,
                check=False,
                text=True,
            )
            output_text = (
                output_path.read_text(encoding="utf-8") if output_path.exists() else ""
            )
            return completed, output_text, str(bundle.resolve())

    def test_runtime_replaces_only_managed_sections(self) -> None:
        completed, output_text, bundle_path = self.run_overlay(RUNTIME)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        document = tomllib.loads(output_text)

        self.assertEqual(document["model"], "provider-model")
        self.assertEqual(document["model_provider"], "custom")
        self.assertEqual(
            document["model_providers"],
            {
                "custom": {
                    "name": "Provider",
                    "base_url": "https://provider.invalid/v1",
                }
            },
        )
        self.assertEqual(document["mcp_servers"]["keep"], {"command": "keep-command"})
        self.assertNotIn("must_not_leak", document["mcp_servers"])
        test_root = Path(bundle_path).parents[4]
        cache_root = test_root / "App Runtime Cache [user]/OpenAI/Codex"
        runtime_root = cache_root / "runtimes/cua_node/runtime-version"
        self.assertEqual(
            document["mcp_servers"]["node_repl"]["command"],
            str(runtime_root / "bin/node_repl.exe"),
        )
        runtime_env = document["mcp_servers"]["node_repl"]["env"]
        self.assertEqual(
            runtime_env["NODE_REPL_NODE_PATH"],
            str(runtime_root / "bin/node.exe"),
        )
        self.assertEqual(
            runtime_env["NODE_REPL_NODE_MODULE_DIRS"],
            str(runtime_root / "bin/node_modules"),
        )
        self.assertEqual(
            runtime_env["CODEX_CLI_PATH"],
            str(cache_root / "bin/codex-version/codex.exe"),
        )
        self.assertEqual(runtime_env["SKY_CUA_NATIVE_PIPE_DIRECTORY"], NATIVE_PIPE)
        self.assertNotIn("CODEX_HOME", runtime_env)
        hashes = document["mcp_servers"]["node_repl"]["env"][
            "NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S"
        ].split(",")
        self.assertEqual(
            hashes,
            [
                BROWSER_CLIENT_HASH,
                COMPUTER_USE_CLIENT_HASH,
            ],
        )
        self.assertEqual(
            document["marketplaces"]["openai-bundled"],
            {"source_type": "local", "source": bundle_path},
        )
        self.assertEqual(
            document["marketplaces"]["keep"],
            {"source_type": "local", "source": "keep-marketplace"},
        )
        self.assertEqual(
            document["plugins"]["browser@openai-bundled"],
            {"enabled": True, "channel": "stable"},
        )
        self.assertEqual(
            document["plugins"]["computer-use@openai-bundled"],
            {
                "enabled": True,
                "channel": "stable",
                "settings": {"mode": "native"},
            },
        )
        self.assertEqual(
            document["plugins"]["browser@browser-repair"], {"enabled": False}
        )
        self.assertNotIn("chrome@openai-bundled", document["plugins"])

    def test_incomplete_runtime_fails_closed(self) -> None:
        for broken_runtime in (
            RUNTIME.replace('command = "current-node-repl"\n', ""),
            RUNTIME.replace('command = "current-node-repl"', 'command = "   "'),
            RUNTIME.replace('command = "current-node-repl"', "command = 1"),
            RUNTIME.replace("args = []", "args = [1]"),
            RUNTIME.replace("args = []", 'args = ["--untrusted"]'),
            RUNTIME.replace('NODE_REPL_NODE_PATH = "current-node"\n', ""),
            RUNTIME.replace(
                'NODE_REPL_NODE_MODULE_DIRS = "current-node-modules"\n', ""
            ),
            RUNTIME.replace('CODEX_CLI_PATH = "current-codex"\n', ""),
            RUNTIME.replace('SKY_CUA_NATIVE_PIPE = "1"', "SKY_CUA_NATIVE_PIPE = 1"),
            RUNTIME.replace(
                f"SKY_CUA_NATIVE_PIPE_DIRECTORY = {json.dumps(NATIVE_PIPE)}\n",
                "",
            ),
            RUNTIME.replace(
                json.dumps(NATIVE_PIPE),
                json.dumps(r"\\.\pipe\untrusted-runtime"),
            ),
            RUNTIME.replace(
                f'BROWSER_USE_CODEX_APP_VERSION = "{RUNTIME_VERSION}"\n', ""
            ),
            RUNTIME.replace(BROWSER_CLIENT_HASH, "c" * 64),
            RUNTIME.replace("enabled = true", "enabled = 1", 1),
            RUNTIME.replace(
                '[plugins."computer-use@openai-bundled"]\nenabled = true\nchannel = "stable"\n',
                "",
            ),
        ):
            with self.subTest(runtime=broken_runtime):
                completed, output_text, _ = self.run_overlay(broken_runtime)
                self.assertNotEqual(completed.returncode, 0)
                self.assertEqual(output_text, "")

    def test_store_runtime_paths_are_rejected(self) -> None:
        completed, output_text, _ = self.run_overlay(
            RUNTIME, use_store_runtime_paths=True
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output_text, "")

    def test_runtime_cache_binary_mismatch_fails_closed(self) -> None:
        def change_cached_node_repl(runtime_cache: dict[str, Path]) -> None:
            runtime_cache["node_repl"].write_bytes(b"untrusted cached node_repl")

        completed, output_text, _ = self.run_overlay(
            RUNTIME, mutate_runtime_cache=change_cached_node_repl
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output_text, "")

    def test_runtime_cache_manifest_mismatch_fails_closed(self) -> None:
        def change_cached_manifest(runtime_cache: dict[str, Path]) -> None:
            manifest_path = runtime_cache["node_repl"].parents[1] / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["node_version"] = "untrusted"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        completed, output_text, _ = self.run_overlay(
            RUNTIME, mutate_runtime_cache=change_cached_manifest
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output_text, "")

    def test_bundle_version_mismatch_fails_closed(self) -> None:
        def change_browser_version(bundle: Path) -> None:
            manifest_path = bundle / "plugins/browser/.codex-plugin/plugin.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["version"] = "25.0.0"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        completed, output_text, _ = self.run_overlay(
            RUNTIME, mutate_bundle=change_browser_version
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output_text, "")

    def test_bundle_client_hash_mismatch_fails_closed(self) -> None:
        def change_browser_client(bundle: Path) -> None:
            (bundle / "plugins/browser/scripts/browser-client.mjs").write_bytes(
                b"untrusted browser client"
            )

        completed, output_text, _ = self.run_overlay(
            RUNTIME, mutate_bundle=change_browser_client
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output_text, "")

    def test_duplicate_plugin_entry_fails_closed(self) -> None:
        def duplicate_browser(bundle: Path) -> None:
            manifest_path = bundle / ".agents/plugins/marketplace.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["plugins"].append(copy.deepcopy(manifest["plugins"][0]))
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        completed, output_text, _ = self.run_overlay(
            RUNTIME, mutate_bundle=duplicate_browser
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output_text, "")

    def test_plugin_path_escape_fails_closed(self) -> None:
        def escape_browser_path(bundle: Path) -> None:
            manifest_path = bundle / ".agents/plugins/marketplace.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["plugins"][0]["source"]["path"] = "../outside"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        completed, output_text, _ = self.run_overlay(
            RUNTIME, mutate_bundle=escape_browser_path
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output_text, "")

    def test_missing_plugin_manifest_fails_closed(self) -> None:
        def remove_browser_manifest(bundle: Path) -> None:
            (bundle / "plugins/browser/.codex-plugin/plugin.json").unlink()

        completed, output_text, _ = self.run_overlay(
            RUNTIME, mutate_bundle=remove_browser_manifest
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output_text, "")

    def test_missing_store_node_repl_fails_closed(self) -> None:
        def remove_store_node_repl(bundle: Path) -> None:
            (bundle.parents[1] / "cua_node/bin/node_repl.exe").unlink()

        completed, output_text, _ = self.run_overlay(
            RUNTIME, mutate_bundle=remove_store_node_repl
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output_text, "")

    def test_missing_required_bundle_fails_closed(self) -> None:
        completed, output_text, _ = self.run_overlay(
            RUNTIME, include_marketplace=False
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output_text, "")

    def test_reparse_plugin_path_fails_closed(self) -> None:
        def replace_browser_with_link(bundle: Path) -> None:
            browser_root = bundle / "plugins/browser"
            browser_target = bundle / "plugins/browser-target"
            browser_root.rename(browser_target)
            os.symlink(browser_target, browser_root, target_is_directory=True)

        completed, output_text, _ = self.run_overlay(
            RUNTIME, mutate_bundle=replace_browser_with_link
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(output_text, "")

    def test_equivalent_quoted_table_paths_are_merged(self) -> None:
        alternate_runtime = RUNTIME.replace(
            "[mcp_servers.node_repl]", '[mcp_servers."node_repl"]'
        ).replace(
            "[mcp_servers.node_repl.env]", '[mcp_servers."node_repl".env]'
        ).replace(
            '[plugins."browser@openai-bundled"]',
            "[plugins.'browser@openai-bundled']",
        )
        alternate_destination = DESTINATION.replace(
            "[mcp_servers.node_repl]", '[mcp_servers."node_repl"]'
        ).replace(
            "[mcp_servers.node_repl.env]", '[mcp_servers."node_repl".env]'
        )
        completed, output_text, _ = self.run_overlay(
            alternate_runtime, alternate_destination
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        document = tomllib.loads(output_text)
        self.assertEqual(
            Path(document["mcp_servers"]["node_repl"]["command"]).name,
            "node_repl.exe",
        )
        self.assertEqual(document["model_provider"], "custom")

    def test_unrelated_array_table_after_managed_section_is_preserved(self) -> None:
        destination = (
            DESTINATION
            + '\n[[audit.rules]]\nname = "keep-array-table"\nenabled = true\n'
        )
        completed, output_text, _ = self.run_overlay(RUNTIME, destination)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        document = tomllib.loads(output_text)
        self.assertEqual(
            document["audit"]["rules"],
            [{"name": "keep-array-table", "enabled": True}],
        )

    def test_quoted_table_key_with_brackets_is_preserved(self) -> None:
        destination = (
            DESTINATION
            + '\n[unrelated."key]with[bracket"]\nvalue = "keep-quoted-table"\n'
        )
        completed, output_text, _ = self.run_overlay(RUNTIME, destination)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        document = tomllib.loads(output_text)
        self.assertEqual(
            document["unrelated"]["key]with[bracket"],
            {"value": "keep-quoted-table"},
        )

    def test_multiline_strings_with_header_text_are_preserved(self) -> None:
        destination = DESTINATION + '''
[unrelated.multiline]
basic = """
[mcp_servers.node_repl]
[plugins."browser@openai-bundled"]
"""
literal = \'\'\'
[[audit.rules]]
[plugins."computer-use@openai-bundled"]
\'\'\'
'''
        completed, output_text, _ = self.run_overlay(RUNTIME, destination)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        multiline = tomllib.loads(output_text)["unrelated"]["multiline"]
        self.assertIn("[mcp_servers.node_repl]", multiline["basic"])
        self.assertIn("[[audit.rules]]", multiline["literal"])

    def test_multiline_env_value_does_not_split_overlay_section(self) -> None:
        destination = DESTINATION.replace(
            'STALE = "1"\n',
            'STALE = "1"\nDETAIL = """\n[unrelated.fake]\n"""\n',
        )
        completed, output_text, _ = self.run_overlay(
            'model = "global-model"\n',
            destination,
            include_marketplace=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        runtime_env = tomllib.loads(output_text)["mcp_servers"]["node_repl"]["env"]
        self.assertIn("[unrelated.fake]", runtime_env["DETAIL"])
        self.assertEqual(runtime_env["NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S"], PINNED_HASH)

    def test_missing_runtime_preserves_cli_only_config(self) -> None:
        completed, output_text, _ = self.run_overlay(
            'model = "global-model"\n', include_marketplace=False
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        document = tomllib.loads(output_text)
        self.assertEqual(
            document["mcp_servers"]["node_repl"]["command"],
            "stale-node-repl",
        )
        self.assertEqual(
            document["plugins"]["computer-use@openai-bundled"], {"enabled": False}
        )

    def test_non_strict_runtime_merge_preserves_existing_marketplace(self) -> None:
        completed, output_text, _ = self.run_overlay(
            RUNTIME,
            include_marketplace=False,
            require_bundle=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        document = tomllib.loads(output_text)
        self.assertEqual(
            document["marketplaces"]["openai-bundled"],
            {
                "source_type": "local",
                "source": "stale-marketplace",
                "last_updated": "stale",
            },
        )


if __name__ == "__main__":
    unittest.main()
