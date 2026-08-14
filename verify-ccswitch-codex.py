import argparse
import hashlib
import json
import os
import socket
import sqlite3
import sys
import tomllib
from pathlib import Path
from urllib.parse import urlsplit


OFFICIAL_API_HOSTS = frozenset(
    {
        "api.openai.com",
        "chat.openai.com",
        "chatgpt.com",
        "openai.com",
        "platform.openai.com",
    }
)
RETIRED_PROXY_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})
MODEL_CATALOG_FILENAME = "provider-gpt-5.6-model-catalog.json"


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def token_digest(token: str | None) -> str | None:
    if not token:
        return None
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:12]


def expected_model_catalog_path() -> Path:
    return Path.home() / ".codex" / MODEL_CATALOG_FILENAME


def same_path(left: object, right: Path) -> bool:
    if not isinstance(left, str) or not left.strip():
        return False
    return os.path.normcase(os.path.abspath(left)) == os.path.normcase(
        os.path.abspath(right)
    )


def is_direct_third_party_base_url(base_url: object) -> bool:
    if not isinstance(base_url, str) or not base_url.strip():
        return False
    parsed = urlsplit(base_url)
    hostname = (parsed.hostname or "").lower().rstrip(".")
    return bool(
        parsed.scheme == "https"
        and hostname
        and parsed.username is None
        and parsed.password is None
        and not parsed.query
        and not parsed.fragment
        and hostname not in OFFICIAL_API_HOSTS
        and not hostname.endswith(".openai.com")
        and not hostname.endswith(".chatgpt.com")
        and hostname not in RETIRED_PROXY_HOSTS
    )


def provider_summary(row: sqlite3.Row) -> dict:
    stored = json.loads(row["settings_config"] or "{}")
    config_text = stored.get("config") if isinstance(stored.get("config"), str) else ""
    config = tomllib.loads(config_text) if config_text else {}
    auth = stored.get("auth") if isinstance(stored.get("auth"), dict) else {}
    auth_token = auth.get("OPENAI_API_KEY") if isinstance(auth, dict) else None
    provider_key = config.get("model_provider")
    provider = config.get("model_providers", {}).get(provider_key, {})
    return {
        "id": row["id"],
        "name": row["name"],
        "isCurrent": bool(row["is_current"]),
        "modelProvider": provider_key,
        "appProviderName": provider.get("name"),
        "model": config.get("model"),
        "modelFast": config.get("model_fast"),
        "modelCatalogJson": config.get("model_catalog_json"),
        "reasoningEffort": config.get("model_reasoning_effort"),
        "serviceTier": config.get("service_tier"),
        "fastMode": config.get("features", {}).get("fast_mode"),
        "desktopTier": config.get("desktop", {}).get("default-service-tier"),
        "localeOverride": config.get("localeOverride"),
        "baseUrl": provider.get("base_url"),
        "runCodexInWindowsSubsystemForLinux": config.get(
            "runCodexInWindowsSubsystemForLinux"
        ),
        "wslRemoteConnections": config.get("features", {}).get(
            "wsl_remote_connections"
        ),
        "requiresOpenAIAuth": provider.get("requires_openai_auth"),
        "hasExperimentalBearerToken": bool(provider.get("experimental_bearer_token")),
        "bearerTokenDigest": token_digest(provider.get("experimental_bearer_token")),
        "authTokenDigest": token_digest(auth_token),
    }


def current_database_providers(database_path: Path) -> tuple[list[dict], dict]:
    database_uri = database_path.resolve().as_uri() + "?mode=ro"
    with sqlite3.connect(database_uri, uri=True) as connection:
        connection.row_factory = sqlite3.Row
        rows = connection.execute(
            "select id, name, is_current, settings_config from providers "
            "where app_type='codex' order by sort_index is null, sort_index, id"
        ).fetchall()
        proxy_row = connection.execute(
            "select enabled, proxy_enabled, live_takeover_active from proxy_config "
            "where app_type='codex'"
        ).fetchone()
    proxy_flags = dict(proxy_row) if proxy_row else {}
    return [provider_summary(row) for row in rows], proxy_flags


def live_config_summary(config_path: Path) -> dict:
    config = tomllib.loads(config_path.read_text(encoding="utf-8"))
    provider_key = config.get("model_provider")
    provider = config.get("model_providers", {}).get(provider_key, {})
    return {
        "modelProvider": provider_key,
        "appProviderName": provider.get("name"),
        "model": config.get("model"),
        "modelFast": config.get("model_fast"),
        "modelCatalogJson": config.get("model_catalog_json"),
        "serviceTier": config.get("service_tier"),
        "fastMode": config.get("features", {}).get("fast_mode"),
        "desktopTier": config.get("desktop", {}).get("default-service-tier"),
        "reasoningEffort": config.get("model_reasoning_effort"),
        "localeOverride": config.get("localeOverride"),
        "baseUrl": provider.get("base_url"),
        "runCodexInWindowsSubsystemForLinux": config.get(
            "runCodexInWindowsSubsystemForLinux"
        ),
        "wslRemoteConnections": config.get("features", {}).get(
            "wsl_remote_connections"
        ),
        "requiresOpenAIAuth": provider.get("requires_openai_auth"),
        "hasExperimentalBearerToken": bool(
            provider.get("experimental_bearer_token")
        ),
        "bearerTokenDigest": token_digest(provider.get("experimental_bearer_token")),
        "modifiedAt": config_path.stat().st_mtime,
    }


def official_auth_summary(auth_path: Path) -> dict:
    auth = read_json(auth_path)
    return {
        "authMode": auth.get("auth_mode"),
        "hasTokens": isinstance(auth.get("tokens"), dict) and bool(auth["tokens"]),
        "hasApiKey": bool(auth.get("OPENAI_API_KEY")),
        "isEmpty": not bool(auth),
    }


def port_is_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.2)
        return probe.connect_ex(("127.0.0.1", port)) == 0


def prodex_environment() -> dict:
    path_entries = os.environ.get("PATH", "").split(os.pathsep)
    return {
        "pathEntries": [entry for entry in path_entries if ".prodex" in entry.lower()],
        "CODEX_HOME": os.environ.get("CODEX_HOME"),
        "PRODEX_HOME": os.environ.get("PRODEX_HOME"),
    }


def observed_state() -> dict:
    user_root = Path.home()
    switch_root = user_root / ".cc-switch"
    codex_root = user_root / ".codex"
    settings_provider_id = read_json(switch_root / "settings.json").get(
        "currentProviderCodex"
    )
    database_providers, proxy_flags = current_database_providers(
        switch_root / "cc-switch.db"
    )
    return {
        "settingsCurrentProvider": settings_provider_id,
        "databaseProviders": database_providers,
        "databaseCurrentProviders": [
            provider for provider in database_providers if provider["isCurrent"]
        ],
        "live": live_config_summary(codex_root / "config.toml"),
        "officialAuth": official_auth_summary(codex_root / "auth.json"),
        "proxy": {"port17896Open": port_is_open(17896), "flags": proxy_flags},
        "prodexEnvironment": prodex_environment(),
    }


def consistency_failures(expected_provider_id: str | None, observed: dict) -> list[str]:
    failures = []
    settings_provider_id = observed["settingsCurrentProvider"]
    database_providers = observed.get("databaseProviders") or observed["databaseCurrentProviders"]
    current_providers = [
        provider for provider in database_providers if provider.get("isCurrent")
    ]
    if len(current_providers) != 1:
        failures.append(f"database current provider count is {len(current_providers)}")
        return failures
    database_provider = current_providers[0]
    if settings_provider_id != database_provider["id"]:
        failures.append("settings and database provider IDs differ")
    if expected_provider_id and settings_provider_id != expected_provider_id:
        failures.append("current provider does not match the expected provider")
    if observed["live"]["modelProvider"] != database_provider["modelProvider"]:
        failures.append("live model provider differs from the database provider")
    if database_provider["modelProvider"] != "custom":
        failures.append("database provider is not the custom direct provider")
    for provider in database_providers:
        if provider["modelProvider"] != "custom":
            failures.append(f"provider {provider['id']} is not the custom direct provider")
        if provider["appProviderName"] != "custom":
            failures.append(f"provider {provider['id']} app provider name is not custom")
        if not isinstance(provider["model"], str) or not provider["model"].strip():
            failures.append(f"provider {provider['id']} model is missing")
        if provider["modelFast"] != provider["model"]:
            failures.append(f"provider {provider['id']} fast model differs from model")
        for field, label in (
            ("model", "model"),
            ("modelFast", "fast model"),
            ("reasoningEffort", "reasoning effort"),
            ("serviceTier", "service tier"),
            ("fastMode", "fast mode"),
            ("desktopTier", "desktop tier"),
        ):
            if provider[field] != observed["live"][field]:
                failures.append(f"provider {provider['id']} {label} differs from live config")
    if observed["live"]["appProviderName"] != "custom":
        failures.append("live app provider name is not custom")
    if observed["live"]["modelFast"] != observed["live"]["model"]:
        failures.append("live fast model differs from model")
    if database_provider["runCodexInWindowsSubsystemForLinux"] is not False:
        failures.append("database provider still enables the WSL runtime")
    if database_provider["wslRemoteConnections"] is not False:
        failures.append("database provider still enables WSL remote connections")
    if not isinstance(database_provider["modelFast"], str) or not database_provider[
        "modelFast"
    ].strip():
        failures.append("database fast model is missing")
    expected_catalog = expected_model_catalog_path()
    if not same_path(database_provider["modelCatalogJson"], expected_catalog):
        failures.append("database model catalog is not the global .codex catalog")
    elif not expected_catalog.is_file():
        failures.append("global model catalog is missing")
    if observed["live"]["baseUrl"] != database_provider["baseUrl"]:
        failures.append("live base URL differs from the database provider")
    if not is_direct_third_party_base_url(observed["live"]["baseUrl"]):
        failures.append("live base URL is not a third-party HTTPS API endpoint")
    if not is_direct_third_party_base_url(database_provider["baseUrl"]):
        failures.append("database provider base URL is not a third-party HTTPS API endpoint")
    comparable_fields = (
        ("model", "model"),
        ("modelFast", "fast model"),
        ("modelCatalogJson", "model catalog"),
        ("serviceTier", "service tier"),
        ("reasoningEffort", "reasoning effort"),
        ("localeOverride", "locale override"),
        ("fastMode", "fast mode"),
        ("desktopTier", "desktop tier"),
    )
    for field, label in comparable_fields:
        if observed["live"][field] != database_provider[field]:
            failures.append(f"live {label} differs from the database provider")
    if not isinstance(observed["live"]["modelFast"], str) or not observed["live"][
        "modelFast"
    ].strip():
        failures.append("live fast model is missing")
    if observed["live"]["runCodexInWindowsSubsystemForLinux"] is not False:
        failures.append("live config still enables the WSL runtime")
    if observed["live"]["wslRemoteConnections"] is not False:
        failures.append("live config still enables WSL remote connections")
    if observed["live"]["requiresOpenAIAuth"] is not False:
        failures.append("live provider still reuses OpenAI auth for API requests")
    if not observed["live"]["hasExperimentalBearerToken"]:
        failures.append("live provider has no isolated bearer token")
    if database_provider["authTokenDigest"] != observed["live"]["bearerTokenDigest"]:
        failures.append("live bearer token differs from the current provider auth")
    if observed["officialAuth"]["hasTokens"]:
        failures.append("global Codex auth still contains ChatGPT tokens for third-party provider")
    if observed["officialAuth"]["authMode"] == "chatgpt":
        failures.append("global Codex auth mode is still ChatGPT for third-party provider")
    if observed["officialAuth"]["hasApiKey"]:
        failures.append("global Codex auth still contains an API key for third-party provider")
    if observed["live"]["baseUrl"] in {
        "http://127.0.0.1:17896",
        "http://localhost:17896",
    }:
        failures.append("live config still points to the retired local proxy")
    if observed["proxy"]["port17896Open"]:
        failures.append("retired local proxy port 17896 is open")
    if any(bool(flag) for flag in observed["proxy"]["flags"].values()):
        failures.append("CCSwitch Codex proxy flags are enabled")
    return failures


def required_restarts(environment: dict) -> list[str]:
    reasons = []
    if environment["pathEntries"]:
        reasons.append("process PATH still contains Prodex entries")
    if environment["CODEX_HOME"] or environment["PRODEX_HOME"]:
        reasons.append("process has CODEX_HOME or PRODEX_HOME set")
    return reasons


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-provider-id")
    arguments = parser.parse_args()
    observed = observed_state()
    failures = consistency_failures(arguments.expected_provider_id, observed)
    restart_reasons = required_restarts(observed["prodexEnvironment"])
    status = "mismatch" if failures else "restart_required" if restart_reasons else "ok"
    report = {"status": status, **observed}
    report.update({"failures": failures, "restartReasons": restart_reasons})
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return {"ok": 0, "restart_required": 2, "mismatch": 3}[status]


if __name__ == "__main__":
    sys.exit(main())
