from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


PRESERVED_CONFIG_KEYS = frozenset(
    {
        "access_token",
        "api_key",
        "api_key_env",
        "base_url",
        "bearer_token",
        "endpoint",
        "experimental_bearer_token",
        "openai_api_key",
        "openai_api_key_env",
        "token",
        "url",
    }
)
TABLE_TOKEN = re.compile(r'"((?:\\.|[^"\\])*)"|\'([^\']*)\'|([A-Za-z0-9_-]+)')
KEY_LINE = re.compile(
    r"^(?P<indent>\s*)(?P<key>[A-Za-z0-9_-]+|\"(?:\\.|[^\"\\])*\"|'[^']+')\s*="
)


class SyncError(RuntimeError):
    pass


@dataclass(frozen=True)
class SensitiveRecord:
    table_path: tuple[str, ...]
    key: str
    line_index: int
    indent: str
    key_token: str
    value: str


@dataclass(frozen=True)
class ProviderSnapshot:
    provider_id: str
    name: str
    category: str | None
    is_current: bool
    settings: dict
    config: dict


def read_json_object(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SyncError(f"Unable to read JSON object: {path}") from exc
    if not isinstance(value, dict):
        raise SyncError(f"Expected a JSON object: {path}")
    return value


def parse_config(config_text: str, provider_id: str) -> dict:
    try:
        config = __import__("tomllib").loads(config_text)
    except (UnicodeError, __import__("tomllib").TOMLDecodeError) as exc:
        raise SyncError(f"Provider {provider_id} has invalid TOML config") from exc
    if not isinstance(config, dict):
        raise SyncError(f"Provider {provider_id} config is not an object")
    return config


def provider_snapshot(row: sqlite3.Row) -> ProviderSnapshot:
    try:
        settings = json.loads(row["settings_config"] or "{}")
    except json.JSONDecodeError as exc:
        raise SyncError(f"Provider {row['id']} settings_config is invalid JSON") from exc
    if not isinstance(settings, dict) or not isinstance(settings.get("config"), str):
        raise SyncError(f"Provider {row['id']} has no string settings_config.config")
    config = parse_config(settings["config"], str(row["id"]))
    auth = settings.get("auth")
    if not isinstance(auth, dict):
        raise SyncError(f"Provider {row['id']} settings_config.auth is not an object")
    return ProviderSnapshot(
        provider_id=str(row["id"]),
        name=str(row["name"] or row["id"]),
        category=str(row["category"]) if row["category"] is not None else None,
        is_current=bool(row["is_current"]),
        settings=settings,
        config=config,
    )


def table_path_tokens(table_text: str) -> tuple[str, ...]:
    tokens: list[str] = []
    for match in TABLE_TOKEN.finditer(table_text.strip()):
        quoted_double, quoted_single, bare = match.groups()
        if quoted_double is not None:
            tokens.append(json.loads(f'"{quoted_double}"'))
        elif quoted_single is not None:
            tokens.append(quoted_single)
        else:
            tokens.append(bare)
    if not tokens:
        raise SyncError(f"Invalid TOML table header: [{table_text}]")
    return tuple(tokens)


def unquote_key(key_token: str) -> str:
    if key_token.startswith('"'):
        return json.loads(key_token)
    if key_token.startswith("'"):
        return key_token[1:-1]
    return key_token


def table_value(config: dict, table_path: tuple[str, ...], key: str) -> object:
    current: object = config
    for segment in table_path:
        if not isinstance(current, dict) or segment not in current:
            raise SyncError(f"TOML table is missing: {'.'.join(table_path)}")
        current = current[segment]
    if not isinstance(current, dict) or key not in current:
        raise SyncError(f"TOML key is missing: {'.'.join((*table_path, key))}")
    return current[key]


def toml_string(value: object, path: str) -> str:
    if not isinstance(value, str):
        raise SyncError(f"Preserved transport field is not a string: {path}")
    return json.dumps(value, ensure_ascii=False)


def sensitive_records(config_text: str, provider_id: str) -> dict[tuple[tuple[str, ...], str], SensitiveRecord]:
    config = parse_config(config_text, provider_id)
    records: dict[tuple[tuple[str, ...], str], SensitiveRecord] = {}
    current_table: tuple[str, ...] = ()
    for line_index, line in enumerate(config_text.splitlines(keepends=True)):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            current_table = table_path_tokens(stripped[1:-1])
            continue
        match = KEY_LINE.match(line)
        if match is None:
            continue
        key = unquote_key(match.group("key"))
        if key.casefold() not in PRESERVED_CONFIG_KEYS:
            continue
        record_key = (current_table, key)
        if record_key in records:
            raise SyncError(f"Duplicate preserved transport field: {record_key}")
        value = table_value(config, current_table, key)
        records[record_key] = SensitiveRecord(
            table_path=current_table,
            key=key,
            line_index=line_index,
            indent=match.group("indent"),
            key_token=match.group("key"),
            value=toml_string(value, ".".join((*current_table, key))),
        )
    return records


def table_bounds(lines: list[str]) -> dict[tuple[str, ...], tuple[int, int]]:
    starts: list[tuple[int, tuple[str, ...]]] = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            starts.append((index, table_path_tokens(stripped[1:-1])))
    bounds: dict[tuple[str, ...], tuple[int, int]] = {}
    first_table = starts[0][0] if starts else len(lines)
    bounds[()] = (0, first_table)
    for position, (start, path) in enumerate(starts):
        end = starts[position + 1][0] if position + 1 < len(starts) else len(lines)
        if path in bounds:
            raise SyncError(f"Duplicate TOML table: {'.'.join(path)}")
        bounds[path] = (start, end)
    return bounds


def replace_line_value(line: str, record: SensitiveRecord, value: str) -> str:
    newline = "\r\n" if line.endswith("\r\n") else "\n" if line.endswith("\n") else ""
    return f"{record.indent}{record.key_token} = {value}{newline}"


def toml_table_header(table_path: tuple[str, ...]) -> str:
    segments = []
    for segment in table_path:
        if re.fullmatch(r"[A-Za-z0-9_-]+", segment):
            segments.append(segment)
        else:
            segments.append(json.dumps(segment, ensure_ascii=False))
    return f"[{'.'.join(segments)}]"


def merge_transport_values(source_text: str, target_text: str, provider_id: str) -> str:
    source_records = sensitive_records(source_text, provider_id)
    target_records = sensitive_records(target_text, provider_id)
    source_lines = source_text.splitlines(keepends=True)
    target_by_key = target_records
    source_keys = set(source_records)
    target_keys = set(target_records)

    merged_lines: list[str | None] = list(source_lines)
    for record_key, source_record in source_records.items():
        target_record = target_by_key.get(record_key)
        if target_record is None:
            merged_lines[source_record.line_index] = None
        else:
            merged_lines[source_record.line_index] = replace_line_value(
                source_lines[source_record.line_index], source_record, target_record.value
            )

    filtered_lines = [line for line in merged_lines if line is not None]
    missing_keys = target_keys - source_keys
    if missing_keys:
        bounds = table_bounds(filtered_lines)
        for table_path in sorted({path for path, _ in missing_keys}):
            if table_path not in bounds:
                if filtered_lines and not filtered_lines[-1].endswith("\n"):
                    filtered_lines[-1] += "\n"
                if filtered_lines and filtered_lines[-1].strip():
                    filtered_lines.append("\n")
                filtered_lines.append(f"{toml_table_header(table_path)}\n")
                for path, key in sorted(missing_keys):
                    if path != table_path:
                        continue
                    record = target_records[(path, key)]
                    filtered_lines.append(f"{record.indent}{record.key_token} = {record.value}\n")
                bounds = table_bounds(filtered_lines)
                continue
            insert_at = bounds[table_path][1]
            additions = []
            for path, key in sorted(missing_keys):
                if path != table_path:
                    continue
                record = target_records[(path, key)]
                additions.append(f"{record.indent}{record.key_token} = {record.value}\n")
            filtered_lines[insert_at:insert_at] = additions
            bounds = table_bounds(filtered_lines)

    merged_text = "".join(filtered_lines)
    merged_records = sensitive_records(merged_text, provider_id)
    target_values = {key: record.value for key, record in target_records.items()}
    merged_values = {key: record.value for key, record in merged_records.items()}
    if merged_values != target_values:
        raise SyncError("Merged config did not preserve every target URL/key field")
    parse_config(merged_text, provider_id)
    return merged_text


def merged_settings(source: ProviderSnapshot, target: ProviderSnapshot) -> dict:
    merged = copy.deepcopy(source.settings)
    merged["config"] = merge_transport_values(
        str(source.settings["config"]),
        str(target.settings["config"]),
        target.provider_id,
    )
    merged["auth"] = copy.deepcopy(target.settings["auth"])
    if merged["auth"] != target.settings["auth"]:
        raise SyncError(f"Provider {target.provider_id} auth material changed during merge")
    return merged


def canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value: object) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()[:12]


def transport_digest(config_text: str, provider_id: str) -> str:
    records = sensitive_records(config_text, provider_id)
    payload = [
        {"table": list(table_path), "key": key, "value": record.value}
        for (table_path, key), record in sorted(records.items())
    ]
    return digest(payload)


def base_host(config: dict) -> str | None:
    provider_name = config.get("model_provider")
    providers = config.get("model_providers")
    if not isinstance(provider_name, str) or not isinstance(providers, dict):
        return None
    provider = providers.get(provider_name)
    if not isinstance(provider, dict) or not isinstance(provider.get("base_url"), str):
        return None
    return urlsplit(provider["base_url"]).hostname


def resolve_provider(rows: list[sqlite3.Row], query: str) -> sqlite3.Row:
    exact_id = [row for row in rows if str(row["id"]) == query]
    exact_name = [row for row in rows if str(row["name"] or "").casefold() == query.casefold()]
    contains_name = [
        row for row in rows if query.casefold() in str(row["name"] or "").casefold()
    ]
    matches = exact_id or exact_name or contains_name
    if len(matches) != 1:
        names = ", ".join(str(row["name"] or row["id"]) for row in matches)
        raise SyncError(f"Provider selector is ambiguous or missing: {query}; matches={names}")
    return matches[0]


def load_provider_rows(connection: sqlite3.Connection) -> list[sqlite3.Row]:
    connection.row_factory = sqlite3.Row
    return connection.execute(
        "select id, name, category, is_current, settings_config "
        "from providers where app_type='codex' order by id"
    ).fetchall()


def plan_sync(rows: list[sqlite3.Row], source_selector: str) -> tuple[ProviderSnapshot, list[dict]]:
    source = provider_snapshot(resolve_provider(rows, source_selector))
    if source.category == "official":
        raise SyncError("The source provider must be a third-party Codex provider")
    plans: list[dict] = []
    for row in rows:
        target_id = str(row["id"])
        if target_id == source.provider_id:
            continue
        if str(row["category"] or "") == "official":
            plans.append({"status": "skipped", "id": target_id, "name": str(row["name"]), "reason": "official provider"})
            continue
        try:
            target = provider_snapshot(row)
            merged = merged_settings(source, target)
            merged_config_text = str(merged["config"])
            merged_config = parse_config(merged_config_text, target.provider_id)
        except SyncError as exc:
            plans.append({"status": "skipped", "id": target_id, "name": str(row["name"]), "reason": str(exc)})
            continue
        current_json = canonical_json(target.settings)
        merged_json = canonical_json(merged)
        plans.append(
            {
                "status": "changed" if current_json != merged_json else "unchanged",
                "id": target.provider_id,
                "name": target.name,
                "baseHost": base_host(target.config),
                "baseHostAfter": base_host(merged_config),
                "authDigestBefore": digest(target.settings["auth"]),
                "authDigestAfter": digest(merged["auth"]),
                "transportDigestBefore": transport_digest(str(target.settings["config"]), target.provider_id),
                "transportDigestAfter": transport_digest(merged_config_text, target.provider_id),
                "configDigestBefore": digest(target.settings["config"]),
                "configDigestAfter": digest(merged["config"]),
                "settings": merged,
            }
        )
    return source, plans


def public_report(database: Path, source: ProviderSnapshot, plans: list[dict], backup_path: Path | None) -> dict:
    public_plans = []
    for plan in plans:
        public_plan = {key: value for key, value in plan.items() if key != "settings"}
        public_plans.append(public_plan)
    return {
        "ok": True,
        "mode": "apply" if backup_path else "preview",
        "database": str(database),
        "source": {
            "id": source.provider_id,
            "name": source.name,
            "baseHost": base_host(source.config),
            "isCurrent": source.is_current,
        },
        "changedCount": sum(plan["status"] == "changed" for plan in plans),
        "unchangedCount": sum(plan["status"] == "unchanged" for plan in plans),
        "skippedCount": sum(plan["status"] == "skipped" for plan in plans),
        "backupPath": str(backup_path) if backup_path else None,
        "targets": public_plans,
    }


def backup_database(connection: sqlite3.Connection, backup_path: Path) -> None:
    if backup_path.exists():
        raise SyncError(f"Backup path already exists: {backup_path}")
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(backup_path) as backup_connection:
        connection.backup(backup_connection)


def apply_plans(connection: sqlite3.Connection, rows: list[sqlite3.Row], plans: list[dict]) -> None:
    original_by_id = {str(row["id"]): str(row["settings_config"] or "{}") for row in rows}
    connection.execute("begin immediate")
    try:
        for plan in plans:
            if plan["status"] != "changed":
                continue
            current = connection.execute(
                "select settings_config from providers where app_type='codex' and id=?",
                (plan["id"],),
            ).fetchone()
            if current is None or str(current[0] or "{}") != original_by_id[plan["id"]]:
                raise SyncError(f"Provider changed during sync: {plan['id']}")
            payload = json.dumps(plan["settings"], ensure_ascii=False, separators=(",", ":"))
            updated = connection.execute(
                "update providers set settings_config=? where app_type='codex' and id=?",
                (payload, plan["id"]),
            ).rowcount
            if updated != 1:
                raise SyncError(f"Expected one provider update, changed={updated}")
        connection.commit()
    except Exception:
        connection.rollback()
        raise


def next_backup_path(database: Path) -> Path:
    stamp = __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y%m%d-%H%M%S")
    return database.with_name(f"{database.name}.bak-codex3-sync-{stamp}")


def run_sync(database: Path, settings_path: Path, source_selector: str, apply: bool, backup_path: Path | None) -> dict:
    settings = read_json_object(settings_path)
    with sqlite3.connect(database, timeout=10) as connection:
        rows = load_provider_rows(connection)
        source, plans = plan_sync(rows, source_selector)
        current_selector = settings.get("currentProviderCodex")
        if source.is_current and current_selector not in (None, source.provider_id):
            raise SyncError("settings.json currentProviderCodex does not match the selected source")
        changed = any(plan["status"] == "changed" for plan in plans)
        chosen_backup = None
        if apply and changed:
            chosen_backup = backup_path or next_backup_path(database)
            backup_database(connection, chosen_backup)
            apply_plans(connection, rows, plans)
        return public_report(database, source, plans, chosen_backup)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Copy codex3 Codex settings while preserving target transport credentials.")
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--settings", type=Path, required=True)
    parser.add_argument("--source-provider", default="codex3")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--backup-path", type=Path)
    parser.add_argument("--json", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        report = run_sync(
            arguments.database.resolve(),
            arguments.settings.resolve(),
            arguments.source_provider,
            arguments.apply,
            arguments.backup_path.resolve() if arguments.backup_path else None,
        )
    except (OSError, sqlite3.Error, SyncError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    if arguments.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"mode={report['mode']} source={report['source']['name']} changed={report['changedCount']}")
        for target in report["targets"]:
            print(f"{target['status']} {target['name']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
