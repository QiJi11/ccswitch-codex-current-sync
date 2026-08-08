import argparse
import contextlib
import hmac
import http.server
import json
import os
import sqlite3
import ssl
import sys
import tomllib
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


MAX_REQUEST_BYTES = 64 * 1024 * 1024
ALLOWED_PATHS = frozenset({"/responses", "/responses/compact"})
UPSTREAM_METADATA_KEY = "_codexFastProxyUpstreamBaseUrl"
HOP_BY_HOP_HEADERS = frozenset(
    {
        "accept-encoding",
        "authorization",
        "connection",
        "content-length",
        "content-encoding",
        "host",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    }
)


@dataclass(frozen=True)
class ProviderCredentials:
    provider_id: str
    base_url: str
    api_key: str


@dataclass(frozen=True)
class ProxySettings:
    settings_path: Path
    database_path: Path
    token_file: Path


def read_json_object(path: Path) -> dict:
    parsed = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError(f"Expected a JSON object: {path}")
    return parsed


def configured_provider_base_url(config_text: str) -> str:
    config = tomllib.loads(config_text)
    provider_name = config.get("model_provider")
    providers = config.get("model_providers")
    if not isinstance(provider_name, str) or not isinstance(providers, dict):
        raise ValueError("Provider config does not identify model_provider.")
    provider = providers.get(provider_name)
    if not isinstance(provider, dict) or not isinstance(provider.get("base_url"), str):
        raise ValueError("Provider config does not contain a base_url.")
    return validate_upstream_base_url(provider["base_url"])


def validate_upstream_base_url(base_url: str) -> str:
    parsed = urlsplit(base_url.rstrip("/"))
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("The current provider must use an HTTPS base_url.")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("The current provider base_url contains unsupported components.")
    return base_url.rstrip("/")


def current_provider_id(settings_path: Path) -> str:
    provider_id = read_json_object(settings_path).get("currentProviderCodex")
    if isinstance(provider_id, str) and provider_id:
        return provider_id
    raise ValueError("CC Switch currentProviderCodex is missing.")


def current_provider_settings(database_path: Path, provider_id: str) -> dict:
    database_uri = database_path.resolve().as_uri() + "?mode=ro"
    with contextlib.closing(sqlite3.connect(database_uri, uri=True, isolation_level=None)) as connection:
        connection.execute("pragma query_only=on")
        current_ids = connection.execute(
            "select id from providers where app_type='codex' and is_current=1"
        ).fetchall()
        row = connection.execute(
            "select settings_config from providers where app_type='codex' and id=?",
            (provider_id,),
        ).fetchone()
    if current_ids != [(provider_id,)]:
        raise ValueError("CC Switch settings and database current provider disagree.")
    if row is None:
        raise ValueError("The current CC Switch provider was not found.")
    parsed = json.loads(row[0])
    if not isinstance(parsed, dict):
        raise ValueError("The current provider settings are not a JSON object.")
    return parsed


def provider_credentials(provider_id: str, provider_settings: dict) -> ProviderCredentials:
    provider_auth = provider_settings.get("auth")
    config_text = provider_settings.get("config")
    if not isinstance(provider_auth, dict) or not isinstance(config_text, str):
        raise ValueError("The current provider settings are incomplete.")
    api_key = provider_auth.get("OPENAI_API_KEY")
    if not isinstance(api_key, str) or not api_key or "\n" in api_key or "\r" in api_key:
        raise ValueError("The current provider API key is missing or malformed.")
    upstream_base_url = provider_settings.get(UPSTREAM_METADATA_KEY)
    if upstream_base_url is None:
        upstream_base_url = configured_provider_base_url(config_text)
    elif not isinstance(upstream_base_url, str):
        raise ValueError("The proxy upstream metadata is malformed.")
    return ProviderCredentials(provider_id, validate_upstream_base_url(upstream_base_url), api_key)


def current_provider_credentials(settings: ProxySettings) -> ProviderCredentials:
    provider_id = current_provider_id(settings.settings_path)
    provider_settings = current_provider_settings(settings.database_path, provider_id)
    return provider_credentials(provider_id, provider_settings)


def expected_proxy_token(token_file: Path) -> str:
    token = token_file.read_text(encoding="ascii").strip()
    if len(token) != 64 or any(character not in "0123456789abcdef" for character in token):
        raise ValueError("The local proxy token is malformed.")
    return token


def upstream_request_headers(incoming_headers, api_key: str, body_length: int) -> dict:
    headers = {
        name: value
        for name, value in incoming_headers.items()
        if name.lower() not in HOP_BY_HOP_HEADERS
    }
    headers["Authorization"] = "Bearer " + api_key
    headers["Content-Length"] = str(body_length)
    headers["Accept-Encoding"] = "identity"
    return headers


def send_json(handler: http.server.BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Connection", "close")
    handler.end_headers()
    handler.wfile.write(body)


class FastAuthProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, _format: str, *_args) -> None:
        return

    @property
    def proxy_settings(self) -> ProxySettings:
        return self.server.proxy_settings

    def do_GET(self) -> None:
        if self.path != "/health":
            send_json(self, 404, {"error": "not_found"})
            return
        try:
            provider = current_provider_credentials(self.proxy_settings)
            expected_proxy_token(self.proxy_settings.token_file)
            host = urlsplit(provider.base_url).hostname
            send_json(self, 200, {"status": "ok", "providerId": provider.provider_id, "upstreamHost": host})
        except (OSError, ValueError, json.JSONDecodeError, sqlite3.Error, tomllib.TOMLDecodeError) as error:
            send_json(self, 503, {"status": "error", "reason": type(error).__name__})

    def do_POST(self) -> None:
        if self.path not in ALLOWED_PATHS:
            send_json(self, 404, {"error": "unsupported_path"})
            return
        try:
            self.forward_authenticated_request()
        except (FileNotFoundError, PermissionError, ValueError, json.JSONDecodeError, sqlite3.Error, tomllib.TOMLDecodeError) as error:
            print(f"proxy request rejected: {type(error).__name__}", file=sys.stderr, flush=True)
            send_json(self, 502, {"error": "proxy_configuration_error"})

    def forward_authenticated_request(self) -> None:
        expected_token = expected_proxy_token(self.proxy_settings.token_file)
        supplied_token = self.headers.get("X-Codex-Fast-Proxy-Token", "")
        if not hmac.compare_digest(supplied_token, expected_token):
            send_json(self, 401, {"error": "invalid_local_authorization"})
            return
        body = self.read_request_body()
        provider = current_provider_credentials(self.proxy_settings)
        request = self.upstream_request(provider, body)
        try:
            with urllib.request.urlopen(request, timeout=300, context=ssl.create_default_context()) as response:
                self.forward_response(response)
        except urllib.error.HTTPError as error:
            with error:
                self.forward_response(error)
        except urllib.error.URLError as error:
            print(f"upstream request failed: {type(error.reason).__name__}", file=sys.stderr, flush=True)
            send_json(self, 502, {"error": "upstream_unavailable"})

    def upstream_request(self, provider: ProviderCredentials, body: bytes) -> urllib.request.Request:
        return urllib.request.Request(
            provider.base_url + self.path,
            data=body,
            headers=upstream_request_headers(self.headers, provider.api_key, len(body)),
            method="POST",
        )

    def read_request_body(self) -> bytes:
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise ValueError("Content-Length is required.")
        body_length = int(raw_length)
        if body_length < 0 or body_length > MAX_REQUEST_BYTES:
            raise ValueError("Request body size is outside the accepted range.")
        body = self.rfile.read(body_length)
        if len(body) != body_length:
            raise OSError("Request body ended before Content-Length bytes were read.")
        return body

    def forward_response(self, response) -> None:
        self.send_response(response.status)
        for name, value in response.headers.items():
            if name.lower() not in HOP_BY_HOP_HEADERS:
                self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()
        read_chunk = getattr(response, "read1", response.read)
        while chunk := read_chunk(64 * 1024):
            self.wfile.write(chunk)
            self.wfile.flush()
        self.close_connection = True


class FastAuthProxyServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], proxy_settings: ProxySettings):
        super().__init__(address, FastAuthProxyHandler)
        self.proxy_settings = proxy_settings


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Replace Codex ChatGPT auth with the current CC Switch provider key.")
    parser.add_argument("--ccswitch-root", required=True, type=Path)
    parser.add_argument("--token-file", required=True, type=Path)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=17896)
    parser.add_argument("--pid-file", type=Path)
    return parser.parse_args()


def write_pid_file(pid_file: Path | None) -> None:
    if pid_file is None:
        return
    pid_file.parent.mkdir(parents=True, exist_ok=True)
    pid_file.write_text(str(os.getpid()), encoding="ascii")


def remove_pid_file(pid_file: Path | None) -> None:
    if pid_file is not None:
        pid_file.unlink(missing_ok=True)


def main() -> int:
    arguments = parse_arguments()
    if arguments.host != "127.0.0.1":
        raise ValueError("The proxy may only listen on 127.0.0.1.")
    root = arguments.ccswitch_root.resolve()
    settings = ProxySettings(root / "settings.json", root / "cc-switch.db", arguments.token_file.resolve())
    current_provider_credentials(settings)
    expected_proxy_token(settings.token_file)
    with FastAuthProxyServer((arguments.host, arguments.port), settings) as server:
        write_pid_file(arguments.pid_file)
        print(f"Codex fast auth proxy listening on {arguments.host}:{arguments.port}", file=sys.stderr, flush=True)
        try:
            server.serve_forever(poll_interval=0.5)
        finally:
            remove_pid_file(arguments.pid_file)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
