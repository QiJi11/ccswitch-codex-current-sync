import argparse
import hashlib
import json
import re
import shutil
import sqlite3
import tomllib
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


@dataclass(frozen=True)
class MigrationRequest:
    database_path: Path
    settings_path: Path
    live_auth_path: Path
    backup_root: Path
    apply: bool


def sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def api_key_digest(api_key: str) -> str:
    return hashlib.sha256(api_key.encode("utf-8")).hexdigest()[:12]


def toml_string(text: str) -> str:
    return json.dumps(text, ensure_ascii=False)


def table_bounds(config_text: str, table_name: str) -> tuple[int, int]:
    header = re.compile(rf"(?m)^\[{re.escape(table_name)}\]\s*$")
    match = header.search(config_text)
    if match is None:
        raise ValueError(f"missing TOML table: {table_name}")
    next_header = re.search(r"(?m)^\[", config_text[match.end() :])
    end = match.end() + next_header.start() if next_header else len(config_text)
    return match.start(), end


def set_table_scalar(config_text: str, table_name: str, key: str, literal: str) -> str:
    start, end = table_bounds(config_text, table_name)
    table_text = config_text[start:end]
    assignment = re.compile(rf"(?m)^{re.escape(key)}\s*=.*$")
    replacement = f"{key} = {literal}"
    if assignment.search(table_text):
        updated_table = assignment.sub(replacement, table_text, count=1)
    else:
        updated_table = table_text.rstrip() + f"\n{replacement}\n"
    return config_text[:start] + updated_table + config_text[end:]


def remove_top_level_scalar(config_text: str, key: str) -> str:
    first_table = re.search(r"(?m)^\[", config_text)
    prefix_end = first_table.start() if first_table else len(config_text)
    prefix = config_text[:prefix_end]
    assignment = re.compile(rf"(?m)^{re.escape(key)}\s*=.*(?:\n|$)")
    return assignment.sub("", prefix) + config_text[prefix_end:]


def set_top_level_scalar(config_text: str, key: str, literal: str) -> str:
    updated = remove_top_level_scalar(config_text, key)
    first_table = re.search(r"(?m)^\[", updated)
    position = first_table.start() if first_table else len(updated)
    return updated[:position] + f"{key} = {literal}\n" + updated[position:]


def is_allowed_base_url(base_url: str) -> bool:
    parsed = urlsplit(base_url)
    if parsed.scheme == "https" and parsed.hostname:
        return True
    return parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost"}


def normalize_legacy_config(config_text: str, provider_name: str, api_key: str) -> str:
    parsed = tomllib.loads(config_text)
    base_url = parsed.get("base_url")
    wire_api = parsed.get("wire_api", "responses")
    if not isinstance(base_url, str) or not is_allowed_base_url(base_url):
        raise ValueError("legacy provider has no usable base_url")
    if wire_api != "responses":
        raise ValueError("legacy provider wire_api must be responses")

    updated = remove_top_level_scalar(config_text, "base_url")
    updated = remove_top_level_scalar(updated, "wire_api")
    updated = set_top_level_scalar(updated, "model_provider", toml_string("custom"))
    provider_table = legacy_provider_table(provider_name, base_url, api_key)
    return updated.rstrip() + provider_table


def legacy_provider_table(provider_name: str, base_url: str, api_key: str) -> str:
    return (
        "\n[model_providers.custom]\n"
        f"name = {toml_string(provider_name)}\n"
        f"base_url = {toml_string(base_url)}\n"
        'wire_api = "responses"\n'
        "requires_openai_auth = false\n"
        f"experimental_bearer_token = {toml_string(api_key)}\n"
    )


def active_provider(config: dict) -> tuple[str, dict]:
    provider_id = config.get("model_provider")
    providers = config.get("model_providers")
    provider = providers.get(provider_id) if isinstance(providers, dict) else None
    if not isinstance(provider_id, str) or not provider_id:
        raise ValueError("model_provider is missing")
    if not isinstance(provider, dict):
        raise ValueError(f"active provider table is missing: {provider_id}")
    return provider_id, provider


def normalize_provider_config(config_text: str, provider_name: str, api_key: str) -> str:
    parsed = tomllib.loads(config_text)
    if not parsed.get("model_provider"):
        return normalize_legacy_config(config_text, provider_name, api_key)
    provider_id, provider = active_provider(parsed)
    base_url = provider.get("base_url")
    if not isinstance(base_url, str) or not is_allowed_base_url(base_url):
        raise ValueError(f"provider has no usable base_url: {provider_id}")
    if provider.get("wire_api", "responses") != "responses":
        raise ValueError(f"provider wire_api must be responses: {provider_id}")

    table_name = f"model_providers.{provider_id}"
    updated = set_table_scalar(config_text, table_name, "requires_openai_auth", "false")
    return set_table_scalar(
        updated,
        table_name,
        "experimental_bearer_token",
        toml_string(api_key),
    )


def normalized_third_party_settings(provider_name: str, settings_text: str) -> tuple[str, str]:
    settings = json.loads(settings_text)
    auth = settings.get("auth")
    config_text = settings.get("config")
    if not isinstance(auth, dict) or not isinstance(config_text, str):
        raise ValueError("provider settings must contain auth and config")
    api_key = auth.get("OPENAI_API_KEY")
    if not isinstance(api_key, str) or not api_key:
        raise ValueError("provider API key is missing")

    normalized_auth = dict(auth)
    normalized_auth.pop("tokens", None)
    normalized_auth.pop("last_refresh", None)
    normalized_auth["auth_mode"] = "apikey"
    normalized_auth["OPENAI_API_KEY"] = api_key
    settings["auth"] = normalized_auth
    settings["config"] = normalize_provider_config(config_text, provider_name, api_key)
    validate_third_party_settings(settings, api_key)
    return json.dumps(settings, ensure_ascii=False, separators=(",", ":")), api_key_digest(api_key)


def validate_third_party_settings(settings: dict, expected_api_key: str) -> None:
    config = tomllib.loads(settings["config"])
    provider_id = config.get("model_provider")
    providers = config.get("model_providers")
    provider = providers.get(provider_id) if isinstance(providers, dict) else None
    if not isinstance(provider, dict):
        raise ValueError("normalized provider table is missing")
    if provider.get("requires_openai_auth") is not False:
        raise ValueError("normalized provider still requires OpenAI auth")
    if provider.get("experimental_bearer_token") != expected_api_key:
        raise ValueError("normalized bearer token does not match provider API key")


def normalized_official_settings(settings_text: str, live_auth: dict) -> str:
    settings = json.loads(settings_text)
    settings["auth"] = live_auth
    return json.dumps(settings, ensure_ascii=False, separators=(",", ":"))


def read_live_chatgpt_auth(path: Path) -> dict:
    live_auth = json.loads(path.read_text(encoding="utf-8"))
    if live_auth.get("auth_mode") != "chatgpt" or not isinstance(live_auth.get("tokens"), dict):
        raise ValueError("live Codex auth is not a ChatGPT token set")
    if not live_auth["tokens"].get("access_token"):
        raise ValueError("live Codex auth has no access token")
    return live_auth


def current_provider_id(connection: sqlite3.Connection) -> str:
    rows = connection.execute(
        "select id from providers where app_type='codex' and is_current=1"
    ).fetchall()
    if len(rows) != 1:
        raise ValueError("database must have exactly one current Codex provider")
    return rows[0][0]


def validate_settings(settings_path: Path, database_current_id: str) -> dict:
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    if settings.get("currentProviderCodex") != database_current_id:
        raise ValueError("settings and database current Codex provider disagree")
    if settings.get("preserveCodexOfficialAuthOnSwitch") is not True:
        raise ValueError("preserveCodexOfficialAuthOnSwitch must remain enabled")
    return settings


def provider_update(row: tuple, live_auth: dict) -> dict:
    provider_id, provider_name, category, settings_text = row
    if category == "official":
        normalized = normalized_official_settings(settings_text, live_auth)
        auth_kind = "chatgpt"
        key_digest = None
    else:
        normalized, key_digest = normalized_third_party_settings(provider_name, settings_text)
        auth_kind = "provider-bearer"
    return {
        "id": provider_id,
        "name": provider_name,
        "authKind": auth_kind,
        "keyDigest": key_digest,
        "oldSettings": settings_text,
        "newSettings": normalized,
        "changed": normalized != settings_text,
    }


def provider_updates(connection: sqlite3.Connection, live_auth: dict) -> list[dict]:
    rows = connection.execute(
        "select id, name, category, settings_config from providers "
        "where app_type='codex' order by sort_index, id"
    ).fetchall()
    return [provider_update(row, live_auth) for row in rows]


def migration_summary(current_provider: str, updates: list[dict]) -> dict:
    visible_updates = [
        {
            "id": update["id"],
            "name": update["name"],
            "authKind": update["authKind"],
            "keyDigest": update["keyDigest"],
            "changed": update["changed"],
        }
        for update in updates
    ]
    return {
        "currentProviderId": current_provider,
        "providerCount": len(updates),
        "changedCount": sum(update["changed"] for update in updates),
        "officialCount": sum(update["authKind"] == "chatgpt" for update in updates),
        "thirdPartyCount": sum(update["authKind"] == "provider-bearer" for update in updates),
        "providers": visible_updates,
    }


def create_backups(request: MigrationRequest) -> dict:
    if request.backup_root.exists():
        raise FileExistsError(f"backup root already exists: {request.backup_root}")
    request.backup_root.mkdir(parents=True)
    database_backup = request.backup_root / "cc-switch.db"
    with sqlite3.connect(request.database_path) as source:
        with sqlite3.connect(database_backup) as destination:
            source.backup(destination)
    shutil.copy2(request.settings_path, request.backup_root / "settings.json")
    shutil.copy2(request.live_auth_path, request.backup_root / "codex-auth.json")
    return {
        "databaseSha256": sha256_file(database_backup),
        "settingsSha256": sha256_file(request.backup_root / "settings.json"),
        "authSha256": sha256_file(request.backup_root / "codex-auth.json"),
    }


def apply_updates(connection: sqlite3.Connection, updates: list[dict]) -> None:
    connection.execute("begin immediate")
    try:
        for update in updates:
            if not update["changed"]:
                continue
            cursor = connection.execute(
                "update providers set settings_config=? "
                "where app_type='codex' and id=? and settings_config=?",
                (update["newSettings"], update["id"], update["oldSettings"]),
            )
            if cursor.rowcount != 1:
                raise RuntimeError(f"provider changed during migration: {update['id']}")
        connection.commit()
    except Exception:
        connection.rollback()
        raise


def write_manifest(request: MigrationRequest, backup_hashes: dict, summary: dict) -> None:
    manifest = {
        "database": str(request.database_path),
        "settings": str(request.settings_path),
        "liveAuth": str(request.live_auth_path),
        "backupHashes": backup_hashes,
        "summary": summary,
    }
    manifest_path = request.backup_root / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def migrate(request: MigrationRequest) -> dict:
    live_auth = read_live_chatgpt_auth(request.live_auth_path)
    with sqlite3.connect(request.database_path, timeout=15, isolation_level=None) as connection:
        database_current_id = current_provider_id(connection)
        validate_settings(request.settings_path, database_current_id)
        updates = provider_updates(connection, live_auth)
        summary = migration_summary(database_current_id, updates)
        if not request.apply:
            return {"mode": "dry-run", **summary}
        backup_hashes = create_backups(request)
        apply_updates(connection, updates)
    write_manifest(request, backup_hashes, summary)
    return {"mode": "applied", "backupRoot": str(request.backup_root), **summary}


def parse_arguments() -> MigrationRequest:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ccswitch-root", required=True, type=Path)
    parser.add_argument("--codex-home", required=True, type=Path)
    parser.add_argument("--backup-root", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    arguments = parser.parse_args()
    ccswitch_root = arguments.ccswitch_root.resolve()
    codex_home = arguments.codex_home.resolve()
    return MigrationRequest(
        database_path=ccswitch_root / "cc-switch.db",
        settings_path=ccswitch_root / "settings.json",
        live_auth_path=codex_home / "auth.json",
        backup_root=arguments.backup_root.resolve(),
        apply=arguments.apply,
    )


if __name__ == "__main__":
    print(json.dumps(migrate(parse_arguments()), ensure_ascii=False, indent=2))
