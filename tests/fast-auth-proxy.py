import importlib.util
import json
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from contextlib import closing, contextmanager
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "codex-fast-auth-proxy.py"
SPEC = importlib.util.spec_from_file_location("codex_fast_auth_proxy", SCRIPT_PATH)
PROXY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROXY)


class HeaderCollection:
    def __init__(self, values):
        self.values = values

    def items(self):
        return self.values.items()


class FastAuthProxyTests(unittest.TestCase):
    def test_outgoing_headers_replace_chatgpt_authorization(self):
        incoming = HeaderCollection({"Authorization": "Bearer chatgpt", "Content-Type": "application/json"})
        headers = PROXY.upstream_request_headers(incoming, "provider-key", 17)
        self.assertEqual(headers["Authorization"], "Bearer provider-key")
        self.assertEqual(headers["Content-Length"], "17")
        self.assertEqual(headers["Accept-Encoding"], "identity")

    def test_current_provider_requires_settings_database_agreement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = self.write_fixture(root, "settings-provider", "database-provider")
            with self.assertRaisesRegex(ValueError, "disagree"):
                PROXY.current_provider_credentials(settings)

    def test_current_provider_reads_https_endpoint_and_api_key(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = self.write_fixture(root, "provider-1", "provider-1")
            credentials = PROXY.current_provider_credentials(settings)
            self.assertEqual(credentials.provider_id, "provider-1")
            self.assertEqual(credentials.base_url, "https://example.test/v1")
            self.assertEqual(credentials.api_key, "fixture-key")

    def test_proxy_metadata_preserves_original_upstream(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            settings = self.write_fixture(root, "provider-1", "provider-1")
            with closing(sqlite3.connect(root / "cc-switch.db")) as connection:
                raw_settings = connection.execute("select settings_config from providers").fetchone()[0]
                provider_settings = json.loads(raw_settings)
                provider_settings["config"] = provider_settings["config"].replace(
                    "https://example.test/v1", "http://127.0.0.1:17896"
                )
                provider_settings[PROXY.UPSTREAM_METADATA_KEY] = "https://example.test/v1"
                connection.execute("update providers set settings_config=?", (json.dumps(provider_settings),))
            credentials = PROXY.current_provider_credentials(settings)
            self.assertEqual(credentials.base_url, "https://example.test/v1")

    def test_health_reports_provider_without_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = self.write_fixture(Path(directory), "provider-1", "provider-1")
            with self.running_proxy(settings) as base_url:
                with urllib.request.urlopen(base_url + "/health") as response:
                    health = json.load(response)
            self.assertEqual(health, {"status": "ok", "providerId": "provider-1", "upstreamHost": "example.test"})

    def test_wrong_local_authorization_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = self.write_fixture(Path(directory), "provider-1", "provider-1")
            with self.running_proxy(settings) as base_url:
                request = urllib.request.Request(
                    base_url + "/responses",
                    data=b"{}",
                    headers={"X-Codex-Fast-Proxy-Token": "0" * 64},
                    method="POST",
                )
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(request)
            self.assertEqual(caught.exception.code, 401)

    @staticmethod
    @contextmanager
    def running_proxy(settings):
        server = PROXY.FastAuthProxyServer(("127.0.0.1", 0), settings)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_address[1]}"
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    @staticmethod
    def write_fixture(root: Path, settings_id: str, database_id: str):
        (root / "settings.json").write_text(json.dumps({"currentProviderCodex": settings_id}), encoding="utf-8")
        auth_path = root / "auth.json"
        auth_path.write_text("1" * 64, encoding="ascii")
        connection = sqlite3.connect(root / "cc-switch.db")
        connection.execute("create table providers (id text, app_type text, is_current integer, settings_config text)")
        provider_settings = {
            "auth": {"OPENAI_API_KEY": "fixture-key", "auth_mode": "apikey"},
            "config": 'model_provider = "custom"\n[model_providers.custom]\nbase_url = "https://example.test/v1"\n',
        }
        connection.execute(
            "insert into providers values (?, 'codex', 1, ?)",
            (database_id, json.dumps(provider_settings)),
        )
        connection.commit()
        connection.close()
        return PROXY.ProxySettings(root / "settings.json", root / "cc-switch.db", auth_path)


if __name__ == "__main__":
    unittest.main()
