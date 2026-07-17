import hashlib
import json
import sqlite3
import sys
import tomllib
from pathlib import Path
from urllib.parse import urlparse


def digest(value: object) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def invalid_provider(row: sqlite3.Row, issue: str) -> dict[str, object]:
    return {
        "id": row["id"],
        "name": row["name"],
        "category": row["category"],
        "isCurrent": bool(row["is_current"]),
        "compatible": False,
        "issues": [issue],
    }


def provider_settings(row: sqlite3.Row) -> tuple[dict | None, dict | None]:
    try:
        settings = json.loads(row["settings_config"] or "{}")
    except json.JSONDecodeError as error:
        return None, invalid_provider(row, f"invalid settings JSON: {error.msg}")
    if not isinstance(settings, dict):
        return None, invalid_provider(row, "provider settings must be a JSON object")
    return settings, None


def provider_config(row: sqlite3.Row, settings: dict) -> tuple[dict | None, dict | None]:
    config_text = settings.get("config") if isinstance(settings.get("config"), str) else ""
    try:
        return tomllib.loads(config_text) if config_text else {}, None
    except tomllib.TOMLDecodeError as error:
        return None, invalid_provider(row, f"invalid config TOML: {error}")


def third_party_issues(model_provider: object, provider: dict, parsed_url) -> list[str]:
    issues = []
    if not model_provider:
        issues.append("model_provider is missing")
    if parsed_url is None:
        issues.append("active provider base_url is missing")
    elif not valid_provider_url(parsed_url):
        issues.append("active provider base_url is not a valid HTTPS or loopback URL")
    if provider.get("requires_openai_auth") is True:
        issues.append("third-party provider incorrectly requires OpenAI auth")
    if provider.get("wire_api") not in (None, "responses"):
        issues.append("active provider wire_api is not responses")
    return issues


def valid_provider_url(parsed_url) -> bool:
    if parsed_url.scheme == "https" and parsed_url.hostname:
        return True
    return parsed_url.scheme == "http" and parsed_url.hostname in {"127.0.0.1", "localhost"}


def provider_summary(row: sqlite3.Row, settings: dict, config: dict) -> dict[str, object]:
    auth = settings.get("auth") if isinstance(settings.get("auth"), dict) else {}
    model_provider = config.get("model_provider")
    _, provider, parsed_url = provider_route(config)
    auth_api_key = auth.get("OPENAI_API_KEY")
    bearer_token = provider.get("experimental_bearer_token")
    top_level_bearer = config.get("experimental_bearer_token")
    base_url = provider.get("base_url")
    parsed_url = urlparse(base_url) if isinstance(base_url, str) else None
    issues = authentication_issues(row["category"], auth, auth_api_key, bearer_token or top_level_bearer)
    if row["category"] != "official":
        issues.extend(third_party_issues(model_provider, provider, parsed_url))
    return provider_report(row, settings, config, issues)


def authentication_issues(category: object, auth: dict, api_key: object, bearer: object) -> list[str]:
    if category == "official":
        return [] if auth.get("tokens") or api_key else ["official provider has no stored login material"]
    return [] if api_key or bearer else ["third-party provider has no API key or bearer token"]


def provider_route(config: dict) -> tuple[object, dict, object]:
    providers = config.get("model_providers")
    provider = providers.get(config.get("model_provider"), {}) if isinstance(providers, dict) else {}
    provider = provider if isinstance(provider, dict) else {}
    base_url = provider.get("base_url")
    parsed_url = urlparse(base_url) if isinstance(base_url, str) else None
    return providers, provider, parsed_url


def route_report(config: dict) -> dict[str, object]:
    providers, provider, parsed_url = provider_route(config)
    return {
        "modelProvider": config.get("model_provider"),
        "modelProviderIds": sorted(providers) if isinstance(providers, dict) else [],
        "configTopLevelKeys": sorted(config),
        "baseUrlHost": parsed_url.hostname if parsed_url else None,
        "requiresOpenAiAuth": provider.get("requires_openai_auth"),
        "wireApi": provider.get("wire_api"),
    }


def authentication_report(settings: dict, config: dict) -> dict[str, object]:
    auth = settings.get("auth") if isinstance(settings.get("auth"), dict) else {}
    _, provider, _ = provider_route(config)
    auth_api_key = auth.get("OPENAI_API_KEY")
    bearer_token = provider.get("experimental_bearer_token") or config.get("experimental_bearer_token")
    return {
        "storedApiKeyDigest": digest(auth_api_key),
        "storedBearerDigest": digest(bearer_token),
        "authMode": auth.get("auth_mode"),
        "hasChatGptTokens": bool(auth.get("tokens")),
    }


def provider_report(row: sqlite3.Row, settings: dict, config: dict, issues: list[str]) -> dict[str, object]:
    return {
        "id": row["id"],
        "name": row["name"],
        "category": row["category"],
        "isCurrent": bool(row["is_current"]),
        "compatible": not issues,
        "issues": issues,
        **route_report(config),
        **authentication_report(settings, config),
    }


def audit_provider(row: sqlite3.Row) -> dict[str, object]:
    settings, settings_error = provider_settings(row)
    if settings_error:
        return settings_error
    config, config_error = provider_config(row, settings)
    if config_error:
        return config_error
    return provider_summary(row, settings, config)

def provider_rows(database: Path) -> list[sqlite3.Row]:
    uri = database.as_uri() + "?mode=ro"
    with sqlite3.connect(uri, uri=True) as connection:
        connection.row_factory = sqlite3.Row
        return connection.execute(
            "select id, name, category, is_current, settings_config "
            "from providers where app_type='codex' order by is_current desc, sort_index, id"
        ).fetchall()


def audit_report(database: Path) -> dict[str, object]:
    providers = [audit_provider(row) for row in provider_rows(database)]
    incompatible = [provider for provider in providers if not provider["compatible"]]
    return {
        "database": str(database),
        "providerCount": len(providers),
        "compatibleCount": len(providers) - len(incompatible),
        "incompatibleCount": len(incompatible),
        "incompatibleProviders": incompatible,
        "providers": providers,
    }


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: audit-codex-provider-auth.py <cc-switch.db>")
    database = Path(sys.argv[1]).resolve()
    print(json.dumps(audit_report(database), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
