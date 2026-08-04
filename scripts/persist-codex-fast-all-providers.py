from __future__ import annotations

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import sys
import time
import tomllib


class FastMigrationError(RuntimeError):
    pass


@dataclass(frozen=True)
class RuntimePolicy:
    model: str
    model_fast: str
    reasoning_effort: str
    tier: str

    @property
    def fast_mode(self) -> bool:
        return self.tier == "fast"


@dataclass(frozen=True)
class MigrationOptions:
    apply: bool = False
    database_backup_path: Path | None = None
    config_backup_path: Path | None = None
    report_path: Path | None = None


TABLE_HEADER = re.compile(r"(?m)^\[[^\]\r\n]+\][ \t]*$")
VALID_TIERS = {"fast", "standard"}


def bare_or_quoted(name: str) -> str:
    escaped = re.escape(name)
    return rf'(?:{escaped}|"{escaped}")'


def toml_scalar(scalar_value: object) -> str:
    if isinstance(scalar_value, str):
        return json.dumps(scalar_value, ensure_ascii=False)
    if isinstance(scalar_value, bool):
        return str(scalar_value).lower()
    raise FastMigrationError(f"Unsupported TOML scalar: {type(scalar_value).__name__}")


def newline_for(config_text: str) -> str:
    return "\r\n" if "\r\n" in config_text else "\n"


def replace_top_level_scalar(config_text: str, key: str, scalar_value: object) -> str:
    assignment = re.compile(
        rf"(?m)^[ \t]*{bare_or_quoted(key)}[ \t]*=.*(?:\r?\n|$)"
    )
    newline = newline_for(config_text)
    first_table = re.search(r"(?m)^\[", config_text)
    prefix_end = first_table.start() if first_table else len(config_text)
    prefix = assignment.sub("", config_text[:prefix_end])
    suffix = config_text[prefix_end:]
    insertion = f"{key} = {toml_scalar(scalar_value)}{newline}"
    return prefix + insertion + suffix


def remove_top_level_scalar(config_text: str, key: str) -> str:
    assignment = re.compile(
        rf"(?m)^[ \t]*{bare_or_quoted(key)}[ \t]*=.*(?:\r?\n|$)"
    )
    first_table = re.search(r"(?m)^\[", config_text)
    prefix_end = first_table.start() if first_table else len(config_text)
    return assignment.sub("", config_text[:prefix_end]) + config_text[prefix_end:]


def find_table_bounds(config_text: str, section: str) -> tuple[int, int] | None:
    section_header = re.compile(
        rf"(?m)^\[[ \t]*{bare_or_quoted(section)}[ \t]*\][ \t]*$"
    )
    section_match = section_header.search(config_text)
    if section_match is None:
        return None
    next_table = TABLE_HEADER.search(config_text, section_match.end())
    section_end = next_table.start() if next_table else len(config_text)
    return section_match.end(), section_end


def update_table_body(section_text: str, key: str, rendered: str, newline: str) -> str:
    assignment = re.compile(
        rf"(?m)^(?P<indent>[ \t]*){bare_or_quoted(key)}[ \t]*=.*(?:\r?\n|$)"
    )
    assignment_match = assignment.search(section_text)
    if assignment_match is not None:
        replacement = f"{assignment_match.group('indent')}{rendered}"
        return (
            section_text[: assignment_match.start()]
            + replacement
            + section_text[assignment_match.end() :]
        )
    return section_text.rstrip("\r\n") + newline + rendered


def insert_missing_table(config_text: str, section: str, rendered: str, newline: str) -> str:
    section_text = f"[{section}]{newline}{rendered}{newline}"
    nested_header = re.compile(
        rf"(?m)^\[[ \t]*{bare_or_quoted(section)}[ \t]*\."
    )
    nested_match = nested_header.search(config_text)
    if nested_match is not None:
        return config_text[: nested_match.start()] + section_text + config_text[nested_match.start() :]

    separator = "" if not config_text or config_text.endswith(("\n", "\r")) else newline
    blank_line = "" if not config_text or config_text.endswith(newline * 2) else newline
    return config_text + separator + blank_line + section_text


def replace_table_scalar(config_text: str, section: str, key: str, scalar_value: object) -> str:
    newline = newline_for(config_text)
    rendered = f"{key} = {toml_scalar(scalar_value)}{newline}"
    bounds = find_table_bounds(config_text, section)
    if bounds is None:
        return insert_missing_table(config_text, section, rendered, newline)
    section_start, section_end = bounds
    section_text = update_table_body(
        config_text[section_start:section_end], key, rendered, newline
    )
    return config_text[:section_start] + section_text + config_text[section_end:]


def canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def load_toml(config_text: str, source_name: str) -> dict:
    try:
        return tomllib.loads(config_text)
    except tomllib.TOMLDecodeError as exc:
        raise FastMigrationError(f"{source_name} config is invalid TOML") from exc


def required_string(config: dict, key: str, source_name: str) -> str:
    selected = config.get(key)
    if not isinstance(selected, str) or not selected.strip():
        raise FastMigrationError(f"{source_name} config has no valid {key}")
    return selected.strip()


def inferred_tier(config: dict) -> str:
    service_tier = config.get("service_tier")
    if service_tier in VALID_TIERS:
        return str(service_tier)
    fast_mode = (config.get("features") or {}).get("fast_mode")
    if isinstance(fast_mode, bool):
        return "fast" if fast_mode else "standard"
    return "standard"


def runtime_policy(
    global_config: dict,
    *,
    model: str | None = None,
    reasoning_effort: str | None = None,
    tier: str | None = None,
) -> RuntimePolicy:
    selected_model = model or required_string(global_config, "model", "Global")
    selected_model_fast = required_string(global_config, "model_fast", "Global")
    selected_effort = reasoning_effort or required_string(
        global_config, "model_reasoning_effort", "Global"
    )
    selected_tier = tier or inferred_tier(global_config)
    if selected_tier not in VALID_TIERS:
        raise FastMigrationError(f"Unsupported service tier: {selected_tier}")
    return RuntimePolicy(
        selected_model,
        selected_model_fast,
        selected_effort,
        selected_tier,
    )


def validate_catalog_model(
    global_config: dict,
    config_path: Path,
    model: str,
) -> None:
    catalog_setting = global_config.get("model_catalog_json")
    if not isinstance(catalog_setting, str) or not catalog_setting.strip():
        return
    catalog_path = Path(os.path.expandvars(catalog_setting)).expanduser()
    if not catalog_path.is_absolute():
        catalog_path = config_path.parent / catalog_path
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise FastMigrationError(f"Unable to read model catalog: {catalog_path}") from exc
    models = catalog.get("models")
    if isinstance(models, list):
        available = {
            entry.get("slug")
            for entry in models
            if isinstance(entry, dict) and isinstance(entry.get("slug"), str)
        }
    elif isinstance(models, dict):
        available = set(models)
    else:
        raise FastMigrationError(f"Model catalog has no models collection: {catalog_path}")
    if model not in available:
        raise FastMigrationError(f"Model is not present in the configured catalog: {model}")


def provider_state(config: dict) -> dict:
    return {
        "model": config.get("model"),
        "modelFast": config.get("model_fast"),
        "reasoningEffort": config.get("model_reasoning_effort"),
        "serviceTier": config.get("service_tier"),
        "fastMode": (config.get("features") or {}).get("fast_mode"),
        "desktopTier": (config.get("desktop") or {}).get("default-service-tier"),
    }


def update_runtime_config(
    config_text: str,
    policy: RuntimePolicy,
) -> tuple[str, dict]:
    return update_runtime_config_models(
        config_text,
        policy,
        (policy.model, policy.model_fast),
    )


def update_provider_runtime_config(
    config_text: str,
    policy: RuntimePolicy,
) -> tuple[str, dict]:
    original = load_toml(config_text, "Provider")
    provider_models = (
        original.get("model") or policy.model,
        original.get("model_fast") or policy.model_fast,
    )
    return update_runtime_config_models(config_text, policy, provider_models)


def update_runtime_config_models(
    config_text: str,
    policy: RuntimePolicy,
    expected_models: tuple[str, str],
) -> tuple[str, dict]:
    expected_model, expected_model_fast = expected_models
    updated = replace_top_level_scalar(config_text, "model", expected_model)
    updated = replace_top_level_scalar(updated, "model_fast", expected_model_fast)
    updated = replace_top_level_scalar(
        updated, "model_reasoning_effort", policy.reasoning_effort
    )
    if policy.fast_mode:
        updated = replace_top_level_scalar(updated, "service_tier", "fast")
    else:
        updated = remove_top_level_scalar(updated, "service_tier")
    updated = replace_table_scalar(updated, "features", "fast_mode", policy.fast_mode)
    updated = replace_table_scalar(
        updated, "desktop", "default-service-tier", policy.tier
    )
    parsed = load_toml(updated, "Updated")
    validate_runtime_config(
        parsed,
        policy,
        "Updated",
        expected_models,
    )
    return updated, parsed


def validate_runtime_config(
    config: dict,
    policy: RuntimePolicy,
    source_name: str,
    expected_models: tuple[str, str] | None = None,
) -> None:
    expected_tier = "fast" if policy.fast_mode else None
    expected_model, expected_model_fast = expected_models or (
        policy.model,
        policy.model_fast,
    )
    if config.get("model") != expected_model:
        raise FastMigrationError(f"{source_name} model was not synchronized")
    if config.get("model_fast") != expected_model_fast:
        raise FastMigrationError(f"{source_name} fast model was not preserved")
    if config.get("model_reasoning_effort") != policy.reasoning_effort:
        raise FastMigrationError(f"{source_name} reasoning effort was not synchronized")
    if config.get("service_tier") != expected_tier:
        raise FastMigrationError(f"{source_name} service tier was not normalized")
    if (config.get("features") or {}).get("fast_mode") is not policy.fast_mode:
        raise FastMigrationError(f"{source_name} Fast feature was not normalized")
    if (config.get("desktop") or {}).get("default-service-tier") != policy.tier:
        raise FastMigrationError(f"{source_name} desktop tier was not synchronized")


def load_settings_object(raw_settings: str, provider_id: str) -> tuple[dict, str, dict]:
    try:
        settings = json.loads(raw_settings or "{}")
    except json.JSONDecodeError as exc:
        raise FastMigrationError(f"Provider {provider_id} settings_config is invalid JSON") from exc
    if not isinstance(settings, dict):
        raise FastMigrationError(f"Provider {provider_id} settings_config is not an object")
    config_text = settings.get("config")
    if not isinstance(config_text, str) or not config_text.strip():
        raise FastMigrationError(f"Provider {provider_id} has no string settings_config.config")
    return settings, config_text, load_toml(config_text, f"Provider {provider_id}")


def build_provider_plan(row: sqlite3.Row, policy: RuntimePolicy) -> dict:
    provider_id = str(row["id"])
    settings, config_text, config = load_settings_object(
        str(row["settings_config"] or "{}"), provider_id
    )
    updated_config_text, updated_config = update_provider_runtime_config(
        config_text, policy
    )
    updated_settings = dict(settings)
    updated_settings["config"] = updated_config_text
    updated_settings_json = (
        str(row["settings_config"] or "{}")
        if updated_config_text == config_text
        else json.dumps(updated_settings, ensure_ascii=False, separators=(",", ":"))
    )
    return {
        "id": provider_id,
        "name": str(row["name"] or provider_id),
        "originalRaw": str(row["settings_config"] or "{}"),
        "updatedRaw": updated_settings_json,
        "originalDigest": digest_text(str(row["settings_config"] or "{}")),
        "updatedDigest": digest_text(updated_settings_json),
        "changed": canonical_json(settings) != canonical_json(updated_settings),
        "before": provider_state(config),
        "after": provider_state(updated_config),
    }


def load_provider_rows(connection: sqlite3.Connection) -> list[sqlite3.Row]:
    connection.row_factory = sqlite3.Row
    return connection.execute(
        "select id, name, is_current, settings_config "
        "from providers where app_type='codex' order by sort_index is null, sort_index, id"
    ).fetchall()


def current_provider_id(settings_path: Path) -> str:
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise FastMigrationError(f"Unable to read CC Switch settings: {settings_path}") from exc
    provider_id = settings.get("currentProviderCodex")
    if not isinstance(provider_id, str) or not provider_id.strip():
        raise FastMigrationError("CC Switch settings has no currentProviderCodex")
    return provider_id


def validate_current_selection(settings_path: Path, rows: list[sqlite3.Row]) -> None:
    selected = current_provider_id(settings_path)
    current_rows = [row for row in rows if bool(row["is_current"])]
    if len(current_rows) != 1 or str(current_rows[0]["id"]) != selected:
        raise FastMigrationError("CC Switch settings and database current provider disagree")


def backup_database(connection: sqlite3.Connection, backup_path: Path) -> None:
    if backup_path.exists():
        raise FastMigrationError(f"Backup path already exists: {backup_path}")
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    backup_connection = sqlite3.connect(backup_path)
    try:
        connection.backup(backup_connection)
    finally:
        backup_connection.close()


def backup_config(config_path: Path, backup_path: Path) -> None:
    if backup_path.exists():
        raise FastMigrationError(f"Backup path already exists: {backup_path}")
    backup_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(config_path, backup_path)


def atomic_write_text(path: Path, content: str) -> None:
    temporary_path = path.with_name(f"{path.name}.tmp-{os.getpid()}-{time.time_ns()}")
    try:
        temporary_path.write_text(content, encoding="utf-8", newline="")
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def verify_updated_rows(
    connection: sqlite3.Connection, plans: list[dict], policy: RuntimePolicy
) -> None:
    rows = {str(row["id"]): row for row in load_provider_rows(connection)}
    for plan in plans:
        row = rows.get(plan["id"])
        if row is None:
            raise FastMigrationError(f"Provider disappeared during migration: {plan['id']}")
        settings, _, config = load_settings_object(
            str(row["settings_config"] or "{}"), plan["id"]
        )
        original_settings = json.loads(plan["originalRaw"])
        if settings.get("auth") != original_settings.get("auth"):
            raise FastMigrationError(f"Provider auth changed during migration: {plan['id']}")
        validate_runtime_config(
            config,
            policy,
            f"Provider {plan['id']}",
            (plan["after"]["model"], plan["after"]["modelFast"]),
        )


def apply_plans(connection: sqlite3.Connection, plans: list[dict]) -> None:
    for plan in plans:
        if not plan["changed"]:
            continue
        current = connection.execute(
            "select settings_config from providers where app_type='codex' and id=?",
            (plan["id"],),
        ).fetchone()
        if current is None or str(current[0] or "{}") != plan["originalRaw"]:
            raise FastMigrationError(f"Provider changed during migration: {plan['id']}")
        updated_rows = connection.execute(
            "update providers set settings_config=? where app_type='codex' and id=?",
            (plan["updatedRaw"], plan["id"]),
        ).rowcount
        if updated_rows != 1:
            raise FastMigrationError(f"Expected one provider update, changed={updated_rows}")


def timestamped_backup_path(path: Path, label: str) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S-%f")
    return path.parent / "backups" / f"{path.name}.bak-{label}-{stamp}"


def public_target(plan: dict) -> dict:
    return {
        "id": plan["id"],
        "name": plan["name"],
        "status": "changed" if plan["changed"] else "unchanged",
        "before": plan["before"],
        "after": plan["after"],
        "configDigestBefore": plan["originalDigest"],
        "configDigestAfter": plan["updatedDigest"],
    }


def policy_matches(
    state: dict,
    policy: RuntimePolicy,
    expected_models: tuple[str, str],
) -> bool:
    expected_model, expected_model_fast = expected_models
    return (
        state["model"] == expected_model
        and state["modelFast"] == expected_model_fast
        and state["reasoningEffort"] == policy.reasoning_effort
        and state["serviceTier"] == ("fast" if policy.fast_mode else None)
        and state["fastMode"] is policy.fast_mode
        and state["desktopTier"] == policy.tier
    )


def public_report(
    database: Path,
    config_path: Path,
    mode: str,
    policy: RuntimePolicy,
    plans: list[dict],
    config_before: dict,
    config_after: dict,
    database_backup_path: Path | None,
    config_backup_path: Path | None,
) -> dict:
    targets = [public_target(plan) for plan in plans]
    matching_count = sum(
        policy_matches(
            plan["after"],
            policy,
            (
                plan["before"]["model"] or policy.model,
                plan["before"]["modelFast"] or policy.model_fast,
            ),
        )
        for plan in plans
    )
    return {
        "ok": True,
        "mode": mode,
        "database": str(database),
        "config": str(config_path),
        "policy": {
            "model": policy.model,
            "modelFast": policy.model_fast,
            "reasoningEffort": policy.reasoning_effort,
            "tier": policy.tier,
        },
        "providerCount": len(plans),
        "changedCount": sum(plan["changed"] for plan in plans),
        "unchangedCount": sum(not plan["changed"] for plan in plans),
        "matchingCount": matching_count,
        "allAligned": matching_count == len(plans)
        and policy_matches(
            config_after,
            policy,
            (policy.model, policy.model_fast),
        ),
        "globalConfig": {
            "status": "changed" if config_before != config_after else "unchanged",
            "before": config_before,
            "after": config_after,
        },
        "databaseBackupPath": (
            str(database_backup_path) if database_backup_path is not None else None
        ),
        "configBackupPath": (
            str(config_backup_path) if config_backup_path is not None else None
        ),
        "targets": targets,
    }


def load_migration_plans(
    connection: sqlite3.Connection,
    settings_path: Path,
    policy: RuntimePolicy,
) -> list[dict]:
    rows = load_provider_rows(connection)
    if not rows:
        raise FastMigrationError("No Codex providers found")
    validate_current_selection(settings_path, rows)
    return [build_provider_plan(row, policy) for row in rows]


def apply_migration_transaction(
    connection: sqlite3.Connection,
    plans: list[dict],
    policy: RuntimePolicy,
    config_path: Path,
    original_config_text: str,
    updated_config_text: str,
    database_backup_path: Path,
    config_backup_path: Path,
) -> None:
    backup_database(connection, database_backup_path)
    backup_config(config_path, config_backup_path)
    config_written = False
    try:
        connection.execute("begin immediate")
        apply_plans(connection, plans)
        verify_updated_rows(connection, plans, policy)
        if updated_config_text != original_config_text:
            atomic_write_text(config_path, updated_config_text)
            config_written = True
        validate_runtime_config(
            load_toml(config_path.read_text(encoding="utf-8"), "Global"),
            policy,
            "Global",
        )
        connection.commit()
    except Exception:
        connection.rollback()
        if config_written:
            atomic_write_text(config_path, original_config_text)
        raise


@contextmanager
def migration_lock(database: Path, timeout_seconds: float = 15.0):
    if os.name != "nt":
        yield
        return

    import msvcrt

    lock_path = database.with_name(f"{database.name}.global-runtime.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+b") as lock_file:
        if lock_file.tell() == 0:
            lock_file.write(b"\0")
            lock_file.flush()
        deadline = time.monotonic() + timeout_seconds
        while True:
            try:
                lock_file.seek(0)
                msvcrt.locking(lock_file.fileno(), msvcrt.LK_NBLCK, 1)
                break
            except OSError as exc:
                if time.monotonic() >= deadline:
                    raise FastMigrationError(
                        "Timed out waiting for the global runtime configuration lock"
                    ) from exc
                time.sleep(0.1)
        try:
            yield
        finally:
            lock_file.seek(0)
            msvcrt.locking(lock_file.fileno(), msvcrt.LK_UNLCK, 1)


def write_report(report_path: Path, report: dict) -> None:
    report_path = report_path.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def resolve_paths(
    database: Path,
    settings_path: Path,
    config_path: Path,
) -> tuple[Path, Path, Path]:
    database = database.resolve()
    settings_path = settings_path.resolve()
    config_path = config_path.resolve()
    if not database.is_file():
        raise FastMigrationError(f"CC Switch database does not exist: {database}")
    if not settings_path.is_file():
        raise FastMigrationError(f"CC Switch settings do not exist: {settings_path}")
    if not config_path.is_file():
        raise FastMigrationError(f"Global Codex config does not exist: {config_path}")
    return database, settings_path, config_path


def run_migration(
    database: Path,
    settings_path: Path,
    config_path: Path,
    options: MigrationOptions | None = None,
    *,
    model: str | None = None,
    reasoning_effort: str | None = None,
    tier: str | None = None,
) -> dict:
    options = options or MigrationOptions()
    database, settings_path, config_path = resolve_paths(
        database, settings_path, config_path
    )

    with migration_lock(database):
        original_config_text = config_path.read_text(encoding="utf-8")
        original_config = load_toml(original_config_text, "Global")
        policy = runtime_policy(
            original_config,
            model=model,
            reasoning_effort=reasoning_effort,
            tier=tier,
        )
        validate_catalog_model(original_config, config_path, policy.model)
        updated_config_text, updated_config = update_runtime_config(
            original_config_text, policy
        )

        connection = sqlite3.connect(database, timeout=15)
        try:
            connection.execute("pragma busy_timeout=15000")
            plans = load_migration_plans(connection, settings_path, policy)
            has_changes = any(plan["changed"] for plan in plans) or (
                updated_config_text != original_config_text
            )
            database_backup_path = None
            config_backup_path = None
            if options.apply and has_changes:
                database_backup_path = (
                    options.database_backup_path.resolve()
                    if options.database_backup_path
                    else timestamped_backup_path(database, "global-runtime")
                )
                config_backup_path = (
                    options.config_backup_path.resolve()
                    if options.config_backup_path
                    else timestamped_backup_path(config_path, "global-runtime")
                )
                apply_migration_transaction(
                    connection,
                    plans,
                    policy,
                    config_path,
                    original_config_text,
                    updated_config_text,
                    database_backup_path,
                    config_backup_path,
                )
            mode = "apply" if options.apply else "preview"
            report = public_report(
                database,
                config_path,
                mode,
                policy,
                plans,
                provider_state(original_config),
                provider_state(updated_config),
                database_backup_path,
                config_backup_path,
            )
        except Exception:
            if options.apply:
                connection.rollback()
            raise
        finally:
            connection.close()

    if options.report_path is not None:
        write_report(options.report_path, report)
    return report


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Synchronize Codex tier and reasoning settings while preserving each "
            "provider's model choices."
        )
    )
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--settings", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--model")
    parser.add_argument("--reasoning-effort")
    parser.add_argument("--tier", choices=sorted(VALID_TIERS))
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--database-backup-path", type=Path)
    parser.add_argument("--config-backup-path", type=Path)
    parser.add_argument("--report-path", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        report = run_migration(
            arguments.database,
            arguments.settings,
            arguments.config,
            MigrationOptions(
                apply=arguments.apply,
                database_backup_path=arguments.database_backup_path,
                config_backup_path=arguments.config_backup_path,
                report_path=arguments.report_path,
            ),
            model=arguments.model,
            reasoning_effort=arguments.reasoning_effort,
            tier=arguments.tier,
        )
    except (FastMigrationError, OSError, sqlite3.Error) as exc:
        print(
            json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False),
            file=sys.stderr,
        )
        return 1
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
