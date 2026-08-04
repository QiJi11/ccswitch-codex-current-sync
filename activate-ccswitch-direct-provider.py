import argparse
from contextlib import closing
import hashlib
import json
import os
import re
import shutil
import sqlite3
import tomllib
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


PROVIDER_SCALAR_KEYS = (
    "model_provider",
    "model",
    "model_fast",
    "model_reasoning_effort",
    "model_catalog_json",
    "service_tier",
    "web_search",
    "localeOverride",
    "runCodexInWindowsSubsystemForLinux",
)

APP_PROVIDER_ID = "custom"
MODEL_CATALOG_FILENAME = "provider-gpt-5.6-model-catalog.json"
APP_PROVIDER_OVERRIDES = {
    "requires_openai_auth": False,
}
APP_SCALAR_OVERRIDES = {
    "model_provider": APP_PROVIDER_ID,
    "localeOverride": "zh-CN",
    # Keep the desktop app on the same local provider runtime as the CLI.
    "runCodexInWindowsSubsystemForLinux": False,
}
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


@dataclass(frozen=True)
class StoredRoute:
    config: dict
    provider_id: str
    provider_table: dict
    api_key: str
    display_name: str


def toml_scalar(value: object) -> str:
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, int):
        return str(value)
    raise TypeError(f"Unsupported TOML scalar: {type(value).__name__}")


def validate_direct_base_url(base_url: object) -> str:
    if not isinstance(base_url, str) or not base_url.strip():
        raise ValueError("Selected provider base URL is missing.")
    parsed = urlsplit(base_url)
    hostname = (parsed.hostname or "").lower().rstrip(".")
    if (
        parsed.scheme != "https"
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("Selected provider must use an HTTPS API base URL.")
    if (
        hostname in OFFICIAL_API_HOSTS
        or hostname.endswith(".openai.com")
        or hostname.endswith(".chatgpt.com")
    ):
        raise ValueError("Selected provider must not use the official OpenAI API.")
    if hostname in RETIRED_PROXY_HOSTS:
        raise ValueError("Selected provider must not use the retired local proxy.")
    return base_url


def current_provider_settings(root: Path, provider_id: str) -> dict:
    settings = json.loads((root / "settings.json").read_text(encoding="utf-8"))
    if settings.get("currentProviderCodex") != provider_id:
        raise ValueError("CC Switch settings current provider does not match the request.")
    database_uri = (root / "cc-switch.db").resolve().as_uri() + "?mode=ro"
    with closing(sqlite3.connect(database_uri, uri=True)) as connection:
        current_ids = connection.execute(
            "select id from providers where app_type='codex' and is_current=1"
        ).fetchall()
        row = connection.execute(
            "select name, settings_config from providers where app_type='codex' and id=?",
            (provider_id,),
        ).fetchone()
    if current_ids != [(provider_id,)] or row is None:
        raise ValueError("CC Switch database current provider does not match the request.")
    provider_name = row[0]
    if not isinstance(provider_name, str) or not provider_name.strip():
        raise ValueError("CC Switch provider display name is missing.")
    return json.loads(row[1])


def replace_top_level_scalar(config_text: str, key: str, value: object | None) -> str:
    assignment = re.compile(rf"(?m)^{re.escape(key)}\s*=.*(?:\n|$)")
    updated = assignment.sub("", config_text)
    if value is None:
        return updated
    first_table = re.search(r"(?m)^\[", updated)
    insertion = f"{key} = {toml_scalar(value)}\n"
    position = first_table.start() if first_table else len(updated)
    return updated[:position] + insertion + updated[position:]


def provider_table_text(
    provider_id: str, provider_table: dict, api_key: str, display_name: str
) -> str:
    provider_values = dict(provider_table)
    provider_values.pop("http_headers", None)
    provider_values.update(APP_PROVIDER_OVERRIDES)
    provider_values["name"] = display_name
    provider_values["experimental_bearer_token"] = api_key
    lines = [f"[model_providers.{provider_id}]"]
    lines.extend(f"{key} = {toml_scalar(value)}" for key, value in provider_values.items())
    return "\n".join(lines) + "\n"


def provider_table_header_pattern(provider_id: str) -> re.Pattern[str]:
    segment = re.escape(provider_id)
    variants = (
        rf"\[model_providers\.{segment}\]",
        rf"\[model_providers\.\"{segment}\"\]",
        rf"\[\"model_providers\"\.{segment}\]",
        rf"\[\"model_providers\"\.\"{segment}\"\]",
    )
    return re.compile(r"(?m)^(?:" + "|".join(variants) + r")\s*$")


def replace_provider_table(config_text: str, provider_id: str, table_text: str) -> str:
    header = provider_table_header_pattern(provider_id)
    match = header.search(config_text)
    if match is None:
        separator = "" if not config_text or config_text.endswith("\n") else "\n"
        return f"{config_text}{separator}{table_text}"
    next_table = re.search(r"(?m)^\[", config_text[match.end() :])
    end = match.end() + next_table.start() if next_table else len(config_text)
    return config_text[: match.start()] + table_text + config_text[end:]


def replace_provider_display_name(
    config_text: str, provider_id: str, display_name: str
) -> str:
    if not isinstance(display_name, str) or not display_name.strip():
        raise ValueError("Provider display name is missing.")
    parsed = tomllib.loads(config_text)
    providers = parsed.get("model_providers", {})
    if provider_id not in providers:
        raise ValueError(f"Provider table is missing: {provider_id}")
    header = provider_table_header_pattern(provider_id)
    match = header.search(config_text)
    if match is None:
        raise ValueError(f"Provider table is missing: {provider_id}")
    next_table = re.search(r"(?m)^\[", config_text[match.end() :])
    end = match.end() + next_table.start() if next_table else len(config_text)
    section = config_text[match.end() : end]
    rendered = f"name = {json.dumps(display_name, ensure_ascii=False)}\n"
    name_assignment = re.compile(r"(?m)^(?:name|\"name\"|'name')\s*=.*(?:\n|$)")
    if name_assignment.search(section):
        section = name_assignment.sub(rendered, section, count=1)
    else:
        section = f"\n{rendered}{section.lstrip(chr(10))}"
    updated = config_text[: match.end()] + section + config_text[end:]
    tomllib.loads(updated)
    return updated


def replace_table_scalar(config_text: str, section: str, key: str, value: object) -> str:
    header = re.compile(rf"(?m)^\[{re.escape(section)}\]\s*$")
    match = header.search(config_text)
    assignment = re.compile(rf"(?m)^{re.escape(key)}\s*=.*(?:\n|$)")
    rendered = f"{key} = {toml_scalar(value)}\n"
    if match is None:
        suffix = "" if not config_text or config_text.endswith("\n") else "\n"
        return f"{config_text}{suffix}\n[{section}]\n{rendered}"

    next_table = re.search(r"(?m)^\[", config_text[match.end() :])
    end = match.end() + next_table.start() if next_table else len(config_text)
    section_text = config_text[match.end() : end]
    if assignment.search(section_text):
        section_text = assignment.sub(rendered, section_text, count=1)
    else:
        section_text = f"\n{rendered}{section_text.lstrip(chr(10))}"
    return config_text[: match.end()] + section_text + config_text[end:]


def atomic_write(path: Path, text: str) -> None:
    staging_path = path.with_name(f"{path.name}.tmp-{os.getpid()}")
    staging_path.write_text(text, encoding="utf-8", newline="\n")
    os.replace(staging_path, path)


def stored_route(provider_settings: dict) -> StoredRoute:
    auth = provider_settings.get("auth")
    stored_text = provider_settings.get("config")
    if not isinstance(auth, dict) or not isinstance(stored_text, str):
        raise ValueError("Stored provider configuration is incomplete.")
    api_key = auth.get("OPENAI_API_KEY")
    if not isinstance(api_key, str) or not api_key:
        raise ValueError("Stored provider API key is missing.")
    stored_config = tomllib.loads(stored_text)
    stored_provider_id = stored_config.get("model_provider")
    provider_table = stored_config.get("model_providers", {}).get(stored_provider_id)
    if not isinstance(stored_provider_id, str) or not isinstance(provider_table, dict):
        raise ValueError("Stored provider TOML is incomplete.")
    validate_direct_base_url(provider_table.get("base_url"))
    return StoredRoute(
        stored_config,
        stored_provider_id,
        provider_table,
        api_key,
        APP_PROVIDER_ID,
    )


def route_scalar_values(route: StoredRoute) -> dict:
    if route.provider_id != APP_PROVIDER_ID:
        raise ValueError("Selected provider must use the custom provider route.")
    model = route.config.get("model")
    if not isinstance(model, str) or not model.strip():
        raise ValueError("Selected provider model is missing.")
    return {
        **APP_SCALAR_OVERRIDES,
        "model": model,
        "model_fast": route.config.get("model_fast"),
        # Keep model discovery local; third-party /models responses are not
        # guaranteed to match Codex's catalog schema.
        "model_catalog_json": str(Path.home() / ".codex" / MODEL_CATALOG_FILENAME),
        "model_reasoning_effort": route.config.get("model_reasoning_effort"),
        "service_tier": route.config.get("service_tier"),
    }


def rendered_live_config(live_text: str, route: StoredRoute) -> tuple[str, dict]:
    tomllib.loads(live_text)
    validate_direct_base_url(route.provider_table.get("base_url"))
    route_values = route_scalar_values(route)
    updated_text = live_text
    for key in PROVIDER_SCALAR_KEYS:
        desired_value = route_values.get(key, route.config.get(key))
        updated_text = replace_top_level_scalar(updated_text, key, desired_value)
    table_text = provider_table_text(
        route.provider_id, route.provider_table, route.api_key, route.display_name
    )
    updated_text = replace_provider_table(updated_text, route.provider_id, table_text)
    updated_text = replace_table_scalar(
        updated_text,
        "features",
        "wsl_remote_connections",
        False,
    )
    updated_text = replace_table_scalar(
        updated_text,
        "features.multi_agent_v2",
        "enabled",
        False,
    )
    return updated_text, tomllib.loads(updated_text)


def activate(root: Path, codex_root: Path, provider_id: str, backup_path: Path) -> dict:
    provider_settings = current_provider_settings(root, provider_id)
    route = stored_route(provider_settings)
    config_path = codex_root / "config.toml"
    if backup_path.exists():
        raise FileExistsError(f"Backup already exists: {backup_path}")

    database_path = root / "cc-switch.db"
    db_backup_path = backup_path.with_name(
        backup_path.name.replace("config-before-", "cc-switch-before-").replace(".toml", ".db")
    )
    if db_backup_path.exists():
        raise FileExistsError(f"Database backup already exists: {db_backup_path}")

    live_text = config_path.read_text(encoding="utf-8")
    updated_text, updated_config = rendered_live_config(live_text, route)
    normalized_stored_text, _ = rendered_live_config(provider_settings["config"], route)
    normalized_provider_settings = dict(provider_settings)
    normalized_provider_settings["config"] = normalized_stored_text
    active_provider = updated_config["model_providers"][route.provider_id]
    validate_direct_base_url(active_provider.get("base_url"))
    if active_provider.get("base_url") != route.provider_table.get("base_url"):
        raise ValueError("Activated provider base URL validation failed.")
    if active_provider.get("experimental_bearer_token") != route.api_key:
        raise ValueError("Activated provider token validation failed.")
    if active_provider.get("requires_openai_auth") is not False:
        raise ValueError("Activated provider must not reuse ChatGPT auth for API requests.")
    if active_provider.get("name") != route.display_name:
        raise ValueError("Activated provider display name validation failed.")
    for key, expected in route_scalar_values(route).items():
        if updated_config.get(key) != expected:
            raise ValueError(f"Activated App {key} validation failed.")

    current_provider_settings(root, provider_id)
    shutil.copy2(config_path, backup_path)
    config_written = False
    try:
        atomic_write(config_path, updated_text)
        config_written = True

        # Perform DB backup and disable proxy flags for codex.
        with closing(sqlite3.connect(database_path, timeout=15)) as connection:
            with closing(sqlite3.connect(db_backup_path)) as backup_conn:
                connection.backup(backup_conn)
            with connection:
                current_ids = connection.execute(
                    "select id from providers where app_type='codex' and is_current=1"
                ).fetchall()
                if current_ids != [(provider_id,)]:
                    raise ValueError("CC Switch provider changed before activation commit.")
                connection.execute(
                    "update providers set settings_config=? where app_type='codex' and id=?",
                    (
                        json.dumps(normalized_provider_settings, ensure_ascii=False),
                        provider_id,
                    ),
                )
                connection.execute(
                    "update proxy_config set enabled=0, proxy_enabled=0, live_takeover_active=0 "
                    "where app_type='codex'"
                )
    except Exception:
        if config_written:
            try:
                atomic_write(config_path, live_text)
            except Exception as rollback_error:
                raise RuntimeError(
                    "Activation failed and live config rollback also failed."
                ) from rollback_error
        raise

    return {
        "providerId": provider_id,
        "providerName": route.display_name,
        "baseUrl": active_provider["base_url"],
        "model": updated_config.get("model"),
        "modelFast": updated_config.get("model_fast"),
        "modelReasoningEffort": updated_config.get("model_reasoning_effort"),
        "serviceTier": updated_config.get("service_tier"),
        "requiresOpenAIAuth": active_provider.get("requires_openai_auth"),
        "apiKeyDigest": hashlib.sha256(route.api_key.encode("utf-8")).hexdigest()[:12],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ccswitch-root", required=True, type=Path)
    parser.add_argument("--codex-root", required=True, type=Path)
    parser.add_argument("--provider-id", required=True)
    parser.add_argument("--backup", required=True, type=Path)
    arguments = parser.parse_args()
    activated = activate(
        arguments.ccswitch_root.resolve(),
        arguments.codex_root.resolve(),
        arguments.provider_id,
        arguments.backup.resolve(),
    )
    print(json.dumps(activated, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
