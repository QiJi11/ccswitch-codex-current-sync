[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RunHome,

    [long]$ExitOrder = 0,
    [string]$CcSwitchRoot = '',
    [string]$SyncScript = (Join-Path $env:USERPROFILE '.prodex\bin\sync-ccswitch-current-codex.ps1'),
    [string]$AllowedRunHomesRoot = '',
    [string]$ChangedFieldsCsv = '',
    [switch]$DryRun,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'resolve-ccswitch-root.ps1')

$userRoot = if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    [Environment]::GetFolderPath('UserProfile')
} else {
    [System.IO.Path]::GetFullPath($env:USERPROFILE)
}
if ([string]::IsNullOrWhiteSpace($userRoot)) {
    throw 'Unable to resolve the user profile directory.'
}
$CcSwitchRoot = Resolve-CcSwitchRoot -ExplicitRoot $CcSwitchRoot -UserRoot $userRoot -AppDataRoot $env:APPDATA
$canonicalCcSwitchRoot = Resolve-CcSwitchRoot -UserRoot $userRoot -AppDataRoot $env:APPDATA
$isCanonicalCcSwitchRoot = [string]::Equals(
    $CcSwitchRoot.TrimEnd('\', '/'),
    $canonicalCcSwitchRoot.TrimEnd('\', '/'),
    [StringComparison]::OrdinalIgnoreCase
)
$prodexRoot = if ([string]::IsNullOrWhiteSpace($env:PRODEX_HOME)) {
    Join-Path $userRoot '.prodex'
} else {
    [System.IO.Path]::GetFullPath($env:PRODEX_HOME)
}
if ($ExitOrder -le 0) {
    $ExitOrder = [DateTime]::UtcNow.Ticks
}
if ([string]::IsNullOrWhiteSpace($AllowedRunHomesRoot)) {
    $AllowedRunHomesRoot = Join-Path $prodexRoot 'manual-homes\ccswitch-runs'
}
$changedFields = @($ChangedFieldsCsv -split ',' |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
foreach ($field in $changedFields) {
    if ($field -notin @('model', 'model_reasoning_effort')) {
        throw "ChangedFieldsCsv contains an unsupported field: $field"
    }
}

$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) {
    $pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
}
if ($null -eq $pythonCommand) {
    throw 'Python 3.11 or newer is required to persist a run model.'
}

$pythonCode = @'
import argparse
import copy
import datetime as dt
import json
import os
import re
import sqlite3
import sys
import time
import tomllib
import uuid
from pathlib import Path


MODEL_KEY = "model"
EFFORT_KEY = "model_reasoning_effort"
EXIT_ORDER_KEY = "_ccswitchCodexModelExitOrder"
MISSING = object()
ASSIGNMENT_PREFIX = re.compile(
    r'^(?P<indent>[ \t]*)(?P<quote>["\']?)(?P<key>model|model_reasoning_effort)(?P=quote)'
    r"(?P<before_eq>[ \t]*)=(?P<after_eq>[ \t]*)"
)


class PersistFailure(Exception):
    def __init__(self, code, message, backup_path=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.backup_path = backup_path


def write_result(path, result):
    Path(path).write_text(
        json.dumps(result, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )


def fail(code, message, backup_path=None):
    raise PersistFailure(code, message, backup_path)


def resolve_existing_directory(path, code, message):
    candidate = Path(path).expanduser()
    try:
        resolved = candidate.resolve(strict=True)
    except (OSError, RuntimeError):
        fail(code, message)
    if not resolved.is_dir():
        fail(code, message)
    return resolved


def validate_run_home(run_home, allowed_root):
    root = resolve_existing_directory(
        allowed_root,
        "invalid_allowed_root",
        "The allowed run homes root does not exist or is not a directory.",
    )
    run = resolve_existing_directory(
        run_home,
        "invalid_run_home",
        "RunHome must be an existing directory below the allowed run homes root.",
    )
    try:
        relative = run.relative_to(root)
    except ValueError:
        fail(
            "invalid_run_home",
            "RunHome must be an existing directory below the allowed run homes root.",
        )
    if not relative.parts:
        fail("invalid_run_home", "RunHome cannot be the run homes root itself.")
    return run


def read_json_object(path, code, message):
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail(code, message)
    if not isinstance(value, dict):
        fail(code, message)
    return value


def valid_optional_setting(value):
    return value is None or (isinstance(value, str) and bool(value.strip()))


def read_metadata(run_home):
    metadata = read_json_object(
        run_home / "run-provider.json",
        "invalid_metadata",
        "run-provider.json is missing or invalid.",
    )
    schema_version = metadata.get("schemaVersion")
    if isinstance(schema_version, bool) or schema_version != 2:
        fail("unsupported_metadata_schema", "run-provider.json schemaVersion must be 2.")

    provider_id = metadata.get("providerId")
    baseline_model = metadata.get("model", MISSING)
    baseline_effort = metadata.get("modelReasoningEffort", MISSING)
    if not isinstance(provider_id, str) or not provider_id.strip():
        fail("invalid_metadata", "run-provider.json has no valid providerId.")
    if baseline_model is MISSING or not valid_optional_setting(baseline_model):
        fail("invalid_metadata", "run-provider.json has no valid model baseline.")
    if baseline_effort is MISSING or not valid_optional_setting(baseline_effort):
        fail(
            "invalid_metadata",
            "run-provider.json has no valid modelReasoningEffort baseline.",
        )
    return provider_id, baseline_model, baseline_effort


def parse_toml(text, code, message):
    try:
        value = tomllib.loads(text)
    except (tomllib.TOMLDecodeError, TypeError, ValueError):
        fail(code, message)
    if not isinstance(value, dict):
        fail(code, message)
    return value


def read_run_config(run_home):
    config_path = run_home / "config.toml"
    try:
        text = config_path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError):
        fail("invalid_run_config", "Run config.toml is missing or unreadable.")
    parsed = parse_toml(
        text,
        "invalid_run_config",
        "Run config.toml is not valid TOML.",
    )
    model = parsed.get(MODEL_KEY, MISSING)
    effort = parsed.get(EFFORT_KEY, MISSING)
    if model is not MISSING and (not isinstance(model, str) or not model.strip()):
        fail("invalid_run_config", "Run config.toml has an invalid top-level model.")
    if effort is not MISSING and not isinstance(effort, str):
        fail(
            "invalid_run_config",
            "Run config.toml has an invalid top-level model_reasoning_effort.",
        )
    if isinstance(effort, str) and not effort.strip():
        fail(
            "invalid_run_config",
            "Run config.toml has an invalid top-level model_reasoning_effort.",
        )
    return None if model is MISSING else model, None if effort is MISSING else effort


def public_changes(baseline_model, baseline_effort, run_model, run_effort):
    changes = []
    if run_model != baseline_model:
        changes.append(MODEL_KEY)
    if run_effort != baseline_effort:
        changes.append(EFFORT_KEY)
    return changes


def merge_changes(detected, explicit):
    changes = list(detected)
    for field in explicit:
        if field not in changes:
            changes.append(field)
    return changes


def toml_string(value):
    return json.dumps(value, ensure_ascii=True)


def without_model_settings(parsed):
    value = copy.deepcopy(parsed)
    value.pop(MODEL_KEY, None)
    value.pop(EFFORT_KEY, None)
    return value


def new_scan_state():
    return {"string": None, "array_depth": 0, "escaped": False}


def quote_run_length(text, index, character):
    end = index
    while end < len(text) and text[end] == character:
        end += 1
    return end - index


def scan_toml_line(line, state):
    mode = state["string"]
    array_depth = state["array_depth"]
    escaped = state["escaped"]
    index = 0
    while index < len(line):
        if mode == "basic_multi":
            if line.startswith('"""', index) and not escaped:
                mode = None
                escaped = False
                index += quote_run_length(line, index, '"')
                continue
            character = line[index]
            if character == "\\" and not escaped:
                escaped = True
            else:
                escaped = False
            index += 1
            continue
        if mode == "literal_multi":
            if line.startswith("'''", index):
                mode = None
                index += quote_run_length(line, index, "'")
                continue
            index += 1
            continue
        if mode == "basic":
            character = line[index]
            if character == '"' and not escaped:
                mode = None
            if character == "\\" and not escaped:
                escaped = True
            else:
                escaped = False
            index += 1
            continue
        if mode == "literal":
            if line[index] == "'":
                mode = None
            index += 1
            continue

        character = line[index]
        if character == "#":
            break
        if line.startswith('"""', index):
            mode = "basic_multi"
            escaped = False
            index += 3
            continue
        if line.startswith("'''", index):
            mode = "literal_multi"
            index += 3
            continue
        if character == '"':
            mode = "basic"
            escaped = False
        elif character == "'":
            mode = "literal"
        elif character == "[":
            array_depth += 1
        elif character == "]" and array_depth > 0:
            array_depth -= 1
        index += 1
    return {"string": mode, "array_depth": array_depth, "escaped": escaped}


def is_table_header(line, state):
    if state["string"] is not None or state["array_depth"] != 0:
        return False
    stripped = line.lstrip(" \t")
    return bool(stripped) and stripped[0] == "["


def find_comment_index(text):
    state = new_scan_state()
    index = 0
    while index < len(text):
        mode = state["string"]
        if mode == "basic_multi":
            if text.startswith('"""', index) and not state["escaped"]:
                state["string"] = None
                state["escaped"] = False
                index += quote_run_length(text, index, '"')
                continue
            character = text[index]
            if character == "\\" and not state["escaped"]:
                state["escaped"] = True
            else:
                state["escaped"] = False
            index += 1
            continue
        if mode == "literal_multi":
            if text.startswith("'''", index):
                state["string"] = None
                index += quote_run_length(text, index, "'")
                continue
            index += 1
            continue
        if mode == "basic":
            character = text[index]
            if character == '"' and not state["escaped"]:
                state["string"] = None
            if character == "\\" and not state["escaped"]:
                state["escaped"] = True
            else:
                state["escaped"] = False
            index += 1
            continue
        if mode == "literal":
            if text[index] == "'":
                state["string"] = None
            index += 1
            continue

        character = text[index]
        if character == "#":
            return index
        if text.startswith('"""', index):
            state["string"] = "basic_multi"
            state["escaped"] = False
            index += 3
            continue
        if text.startswith("'''", index):
            state["string"] = "literal_multi"
            index += 3
            continue
        if character == '"':
            state["string"] = "basic"
            state["escaped"] = False
        elif character == "'":
            state["string"] = "literal"
        index += 1
    return None


def collect_top_level_assignments(lines):
    state = new_scan_state()
    first_table = len(lines)
    positions = {MODEL_KEY: [], EFFORT_KEY: []}
    matches = {}
    for index, line in enumerate(lines):
        if is_table_header(line, state):
            first_table = index
            break
        match = None
        if state["string"] is None and state["array_depth"] == 0:
            match = ASSIGNMENT_PREFIX.match(line)
            if match:
                key = match.group("key")
                positions[key].append(index)
        next_state = scan_toml_line(line, state)
        if match:
            matches[index] = (match, next_state)
        state = next_state
    return first_table, positions, matches


def replace_assignment_line(line, match, value):
    line_ending = ""
    content = line
    if content.endswith("\r\n"):
        line_ending = "\r\n"
        content = content[:-2]
    elif content.endswith(("\n", "\r")):
        line_ending = content[-1]
        content = content[:-1]
    remainder = content[match.end():]
    value_region = remainder.lstrip(" \t")
    value_quote = value_region[:1]
    comment_index = find_comment_index(remainder)
    if comment_index is None:
        trailing = re.search(r"[ \t]*$", remainder).group(0)
        suffix = trailing + line_ending
    else:
        before_comment = remainder[:comment_index]
        trailing = re.search(r"[ \t]*$", before_comment).group(0)
        suffix = trailing + remainder[comment_index:] + line_ending
    rendered_value = toml_string(value)
    if (
        value_region.startswith('"""')
        and '"""' not in value
        and "\r" not in value
        and "\n" not in value
    ):
        rendered_value = '"""' + value + '"""'
    elif (
        value_region.startswith("'''")
        and "'''" not in value
        and "\r" not in value
        and "\n" not in value
    ):
        rendered_value = "'''" + value + "'''"
    elif (
        value_quote == "'"
        and isinstance(value, str)
        and "'" not in value
        and "\r" not in value
        and "\n" not in value
    ):
        rendered_value = "'" + value + "'"
    return content[:match.end()] + rendered_value + suffix


def rewrite_top_level_config(original, desired_model, desired_effort):
    parsed_before = parse_toml(
        original,
        "invalid_provider_config",
        "The provider config is not valid TOML; no changes were made.",
    )
    lines = original.splitlines(keepends=True)
    first_table, positions, matches = collect_top_level_assignments(lines)

    for key in (MODEL_KEY, EFFORT_KEY):
        parsed_has_key = key in parsed_before
        if parsed_has_key and not isinstance(parsed_before[key], str):
            fail(
                "unsupported_provider_config",
                "The provider config uses a non-string top-level model assignment format; no changes were made.",
            )
        if len(positions[key]) > 1 or (parsed_has_key and len(positions[key]) != 1):
            fail(
                "unsupported_provider_config",
                "The provider config uses an unsupported top-level model assignment format; no changes were made.",
            )

    desired = {MODEL_KEY: desired_model, EFFORT_KEY: desired_effort}
    replacements = {}
    removals = set()
    insertions = []
    newline = "\r\n" if "\r\n" in original else "\n"

    for key in (MODEL_KEY, EFFORT_KEY):
        value = desired[key]
        indexes = positions[key]
        if indexes:
            index = indexes[0]
            if value is None:
                removals.add(index)
            else:
                match, state_after = matches[index]
                if state_after["string"] is not None or state_after["array_depth"] != 0:
                    fail(
                        "unsupported_provider_config",
                        "The provider config uses a multiline model assignment format; no changes were made.",
                    )
                replacements[index] = replace_assignment_line(
                    lines[index],
                    match,
                    value,
                )
        elif value is not None:
            insertions.append(f"{key} = {toml_string(value)}{newline}")

    rewritten = []
    for index, line in enumerate(lines):
        if index == first_table and insertions:
            if rewritten and not rewritten[-1].endswith(("\n", "\r")):
                rewritten[-1] += newline
            rewritten.extend(insertions)
        if index in removals:
            continue
        rewritten.append(replacements.get(index, line))
    if first_table == len(lines) and insertions:
        if rewritten and not rewritten[-1].endswith(("\n", "\r")):
            rewritten[-1] += newline
        rewritten.extend(insertions)
    updated = "".join(rewritten)

    parsed_after = parse_toml(
        updated,
        "provider_config_rewrite_failed",
        "The provider config could not be updated safely; no changes were made.",
    )
    after_model = parsed_after.get(MODEL_KEY, MISSING)
    expected_model = MISSING if desired_model is None else desired_model
    if (after_model is MISSING) != (expected_model is MISSING) or (
        after_model is not MISSING and after_model != expected_model
    ):
        fail(
            "provider_config_rewrite_failed",
            "The provider model could not be updated safely; no changes were made.",
        )
    after_effort = parsed_after.get(EFFORT_KEY, MISSING)
    expected_effort = MISSING if desired_effort is None else desired_effort
    if (after_effort is MISSING) != (expected_effort is MISSING) or (
        after_effort is not MISSING and after_effort != expected_effort
    ):
        fail(
            "provider_config_rewrite_failed",
            "The provider reasoning effort could not be updated safely; no changes were made.",
        )
    if without_model_settings(parsed_before) != without_model_settings(parsed_after):
        fail(
            "provider_config_semantics_changed",
            "Updating the provider model would change other TOML settings; no changes were made.",
        )
    return updated


def open_read_only(db_path):
    uri = db_path.as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=5.0)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout=5000")
    return connection


def load_provider(connection, provider_id):
    row = connection.execute(
        "select id, settings_config from providers where app_type='codex' and id=?",
        (provider_id,),
    ).fetchone()
    if row is None:
        fail("provider_not_found", "The run provider no longer exists in cc-switch.")
    try:
        settings = json.loads(row["settings_config"] or "{}")
    except json.JSONDecodeError:
        fail(
            "invalid_provider_settings",
            "The provider settings_config is invalid; no changes were made.",
        )
    if not isinstance(settings, dict):
        fail(
            "invalid_provider_settings",
            "The provider settings_config is invalid; no changes were made.",
        )
    config = settings.get("config")
    if not isinstance(config, str) or not config.strip():
        fail(
            "invalid_provider_settings",
            "The provider has no valid settings_config.config; no changes were made.",
        )
    return row, settings, config


def provider_exit_order(settings):
    raw_value = settings.get(EXIT_ORDER_KEY)
    if raw_value is None:
        return 0
    if not isinstance(raw_value, str) or not raw_value.isdigit() or int(raw_value) <= 0:
        fail(
            "invalid_provider_exit_order",
            "The provider model exit-order marker is invalid; no changes were made.",
        )
    return int(raw_value)


def prepare_settings(
    connection,
    provider_id,
    model,
    effort,
    changed_fields,
    exit_order=None,
):
    row, settings, config = load_provider(connection, provider_id)
    parsed = parse_toml(
        config,
        "invalid_provider_config",
        "The provider config is not valid TOML; no changes were made.",
    )
    desired_model = model if MODEL_KEY in changed_fields else parsed.get(MODEL_KEY)
    desired_effort = effort if EFFORT_KEY in changed_fields else parsed.get(EFFORT_KEY)
    updated_config = rewrite_top_level_config(config, desired_model, desired_effort)
    updated_settings = copy.deepcopy(settings)
    updated_settings["config"] = updated_config
    if exit_order is not None:
        updated_settings[EXIT_ORDER_KEY] = str(exit_order)
    if updated_settings == settings:
        return row, settings, config, None, desired_model, desired_effort

    before_other = copy.deepcopy(settings)
    after_other = copy.deepcopy(updated_settings)
    before_other.pop("config", None)
    after_other.pop("config", None)
    before_other.pop(EXIT_ORDER_KEY, None)
    after_other.pop(EXIT_ORDER_KEY, None)
    if before_other != after_other:
        fail(
            "provider_settings_semantics_changed",
            "Updating the provider model would change other provider settings; no changes were made.",
        )
    serialized = json.dumps(updated_settings, ensure_ascii=False, separators=(",", ":"))
    round_trip = json.loads(serialized)
    if round_trip != updated_settings:
        fail(
            "provider_settings_serialization_failed",
            "The provider settings could not be serialized safely; no changes were made.",
        )
    return row, settings, config, serialized, desired_model, desired_effort


def make_online_backup(db_path, backup_dir):
    try:
        backup_dir.mkdir(parents=True, exist_ok=True)
    except OSError:
        fail("backup_failed", "The cc-switch backup directory could not be created.")
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = backup_dir / (
        f"cc-switch.db.bak-model-persist-{stamp}-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    )
    source = None
    destination = None
    try:
        source = open_read_only(db_path)
        destination = sqlite3.connect(str(backup_path), timeout=5.0)
        destination.execute("PRAGMA busy_timeout=5000")
        deadline = time.monotonic() + 10.0

        def progress(status, remaining, total):
            del remaining, total
            if status in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED) and time.monotonic() > deadline:
                raise PersistFailure(
                    "database_busy",
                    "cc-switch remained busy while creating the online backup.",
                )

        source.backup(destination, pages=256, progress=progress, sleep=0.05)
        check = destination.execute("PRAGMA integrity_check").fetchone()
        if not check or check[0] != "ok":
            fail("backup_integrity_failed", "The cc-switch online backup failed integrity validation.")
        destination.commit()
    except PersistFailure:
        raise
    except sqlite3.Error:
        fail("backup_failed", "The cc-switch online backup could not be created.")
    finally:
        if destination is not None:
            destination.close()
        if source is not None:
            source.close()
    return backup_path


def settings_current_provider(settings_path):
    try:
        settings = json.loads(settings_path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(settings, dict):
        return None
    value = settings.get("currentProviderCodex")
    return value if isinstance(value, str) and value else None


def provider_is_jointly_current(db_path, settings_path, provider_id):
    settings_provider = settings_current_provider(settings_path)
    if settings_provider != provider_id:
        return False
    try:
        with open_read_only(db_path) as connection:
            active = connection.execute(
                "select id from providers where app_type='codex' and is_current=1 order by id"
            ).fetchall()
    except sqlite3.Error:
        return False
    return len(active) == 1 and active[0]["id"] == provider_id


def base_result(status, provider_id, changed_fields):
    return {
        "ok": True,
        "status": status,
        "providerId": provider_id,
        "changedFields": changed_fields,
        "databaseChanged": False,
        "backupPath": None,
        "syncEligible": False,
        "message": "",
    }


def main(args):
    run_home = validate_run_home(args.run_home, args.allowed_run_homes_root)
    provider_id, baseline_model, baseline_effort = read_metadata(run_home)
    run_model, run_effort = read_run_config(run_home)
    if baseline_model is not None and run_model is None:
        fail(
            "unsupported_model_removal",
            "Removing an existing provider model is not supported; no changes were made.",
        )
    changed_fields = merge_changes(
        public_changes(
            baseline_model,
            baseline_effort,
            run_model,
            run_effort,
        ),
        args.changed_field,
    )
    if not changed_fields:
        result = base_result("skipped", provider_id, changed_fields)
        result["message"] = "The run model settings did not change."
        return result

    cc_root = resolve_existing_directory(
        args.cc_switch_root,
        "invalid_ccswitch_root",
        "CcSwitchRoot does not exist or is not a directory.",
    )
    db_path = cc_root / "cc-switch.db"
    if not db_path.is_file():
        fail("database_not_found", "cc-switch.db was not found.")
    settings_path = cc_root / "settings.json"

    try:
        with open_read_only(db_path) as connection:
            _, initial_settings, _, serialized, _, _ = prepare_settings(
                connection,
                provider_id,
                run_model,
                run_effort,
                changed_fields,
            )
    except PersistFailure:
        raise
    except sqlite3.Error:
        fail("database_read_failed", "The cc-switch database could not be read.")

    would_change = serialized is not None
    if args.dry_run:
        result = base_result("dry_run", provider_id, changed_fields)
        result["wouldDatabaseChange"] = would_change
        result["syncEligible"] = provider_is_jointly_current(
            db_path,
            settings_path,
            provider_id,
        )
        result["message"] = "The run model change was validated without writing files."
        return result

    if provider_exit_order(initial_settings) > args.exit_order:
        result = base_result("superseded", provider_id, changed_fields)
        result["message"] = "A later-exiting run already persisted this provider."
        return result

    backup_path = None
    backup_path = make_online_backup(db_path, cc_root / "backups")

    connection = None
    database_changed = False
    try:
        connection = sqlite3.connect(str(db_path), timeout=5.0, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA busy_timeout=5000")
        connection.execute("BEGIN IMMEDIATE")
        _, transaction_settings, _ = load_provider(connection, provider_id)
        if provider_exit_order(transaction_settings) > args.exit_order:
            connection.execute("COMMIT")
            result = base_result("superseded", provider_id, changed_fields)
            result["backupPath"] = str(backup_path) if backup_path else None
            result["message"] = "A later-exiting run already persisted this provider."
            return result
        _, original_settings, _, serialized, desired_model, desired_effort = prepare_settings(
            connection,
            provider_id,
            run_model,
            run_effort,
            changed_fields,
            args.exit_order,
        )
        if serialized is not None:
            cursor = connection.execute(
                "update providers set settings_config=? where app_type='codex' and id=?",
                (serialized, provider_id),
            )
            if cursor.rowcount != 1:
                fail("database_update_failed", "The provider update affected an unexpected number of rows.")
            _, persisted_settings, persisted_config = load_provider(connection, provider_id)
            expected_settings = json.loads(serialized)
            if persisted_settings != expected_settings:
                fail("database_verification_failed", "The provider update did not verify; it was rolled back.")
            parsed_persisted = parse_toml(
                persisted_config,
                "database_verification_failed",
                "The persisted provider config did not verify; it was rolled back.",
            )
            persisted_model = parsed_persisted.get(MODEL_KEY, MISSING)
            expected_model = MISSING if desired_model is None else desired_model
            if (persisted_model is MISSING) != (expected_model is MISSING) or (
                persisted_model is not MISSING and persisted_model != expected_model
            ):
                fail("database_verification_failed", "The persisted provider model did not verify; it was rolled back.")
            persisted_effort = parsed_persisted.get(EFFORT_KEY, MISSING)
            expected_effort = MISSING if desired_effort is None else desired_effort
            if (persisted_effort is MISSING) != (expected_effort is MISSING) or (
                persisted_effort is not MISSING and persisted_effort != expected_effort
            ):
                fail(
                    "database_verification_failed",
                    "The persisted provider reasoning effort did not verify; it was rolled back.",
                )
            original_other = copy.deepcopy(original_settings)
            persisted_other = copy.deepcopy(persisted_settings)
            original_other.pop("config", None)
            persisted_other.pop("config", None)
            original_other.pop(EXIT_ORDER_KEY, None)
            persisted_other.pop(EXIT_ORDER_KEY, None)
            if original_other != persisted_other:
                fail(
                    "database_verification_failed",
                    "Other provider settings changed unexpectedly; the update was rolled back.",
                )
            integrity = connection.execute("PRAGMA integrity_check").fetchone()
            if not integrity or integrity[0] != "ok":
                fail("database_integrity_failed", "Database integrity validation failed; the update was rolled back.")
            database_changed = True
        connection.execute("COMMIT")
    except PersistFailure as exc:
        if connection is not None and connection.in_transaction:
            connection.execute("ROLLBACK")
        if exc.backup_path is None and backup_path is not None:
            exc.backup_path = str(backup_path)
        raise
    except sqlite3.OperationalError as exc:
        if connection is not None and connection.in_transaction:
            connection.execute("ROLLBACK")
        code = "database_busy" if "locked" in str(exc).lower() or "busy" in str(exc).lower() else "database_update_failed"
        message = (
            "cc-switch remained busy; no provider settings were changed."
            if code == "database_busy"
            else "The provider update failed and was rolled back."
        )
        fail(code, message, str(backup_path) if backup_path else None)
    except sqlite3.Error:
        if connection is not None and connection.in_transaction:
            connection.execute("ROLLBACK")
        fail(
            "database_update_failed",
            "The provider update failed and was rolled back.",
            str(backup_path) if backup_path else None,
        )
    finally:
        if connection is not None:
            connection.close()

    status = "updated" if database_changed else "already_persisted"
    result = base_result(status, provider_id, changed_fields)
    result["databaseChanged"] = database_changed
    result["backupPath"] = str(backup_path) if backup_path else None
    result["syncEligible"] = provider_is_jointly_current(
        db_path,
        settings_path,
        provider_id,
    )
    result["message"] = (
        "The run model settings were persisted."
        if database_changed
        else "The provider already contained the run model settings."
    )
    return result


def parse_args():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--run-home", required=True)
    parser.add_argument("--cc-switch-root", required=True)
    parser.add_argument("--allowed-run-homes-root", required=True)
    parser.add_argument("--exit-order", required=True, type=int)
    parser.add_argument("--result-path", required=True)
    parser.add_argument(
        "--changed-field",
        action="append",
        choices=(MODEL_KEY, EFFORT_KEY),
        default=[],
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


args = parse_args()
try:
    result = main(args)
    write_result(args.result_path, result)
except PersistFailure as exc:
    write_result(
        args.result_path,
        {
            "ok": False,
            "status": "failed",
            "errorCode": exc.code,
            "message": exc.message,
            "backupPath": exc.backup_path,
        },
    )
    raise SystemExit(2)
except Exception:
    write_result(
        args.result_path,
        {
            "ok": False,
            "status": "failed",
            "errorCode": "unexpected_error",
            "message": "Model persistence failed unexpectedly; no secrets were logged.",
            "backupPath": None,
        },
    )
    raise SystemExit(3)
'@

$tempPythonPath = Join-Path ([System.IO.Path]::GetTempPath()) "persist-run-model-$PID-$([guid]::NewGuid().ToString('N')).py"
$tempResultPath = Join-Path ([System.IO.Path]::GetTempPath()) "persist-run-model-$PID-$([guid]::NewGuid().ToString('N')).json"
$previousPythonIoEncoding = $env:PYTHONIOENCODING
$previousPythonUtf8 = $env:PYTHONUTF8
$pythonExitCode = 1
$persistenceMutex = [System.Threading.Mutex]::new(
    $false,
    (Get-CcSwitchRootMutexName -Root $CcSwitchRoot)
)
$persistenceLockTaken = $false

try {
    try {
        $persistenceLockTaken = $persistenceMutex.WaitOne([TimeSpan]::FromMinutes(2))
    } catch [System.Threading.AbandonedMutexException] {
        $persistenceLockTaken = $true
    }
    if (-not $persistenceLockTaken) {
        throw 'Timed out waiting for another Codex model persistence operation.'
    }

    [System.IO.File]::WriteAllText($tempPythonPath, $pythonCode, [System.Text.UTF8Encoding]::new($false))
    $env:PYTHONIOENCODING = 'utf-8'
    $env:PYTHONUTF8 = '1'
    $arguments = @(
        $tempPythonPath,
        '--run-home', $RunHome,
        '--cc-switch-root', $CcSwitchRoot,
        '--allowed-run-homes-root', $AllowedRunHomesRoot,
        '--exit-order', ([string]$ExitOrder),
        '--result-path', $tempResultPath
    )
    foreach ($field in $changedFields) {
        $arguments += @('--changed-field', [string]$field)
    }
    if ($DryRun) {
        $arguments += '--dry-run'
    }
    & $pythonCommand.Source @arguments
    $pythonExitCode = $LASTEXITCODE
} finally {
    if ($null -eq $previousPythonIoEncoding) {
        Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue
    } else {
        $env:PYTHONIOENCODING = $previousPythonIoEncoding
    }
    if ($null -eq $previousPythonUtf8) {
        Remove-Item Env:\PYTHONUTF8 -ErrorAction SilentlyContinue
    } else {
        $env:PYTHONUTF8 = $previousPythonUtf8
    }
    Remove-Item -LiteralPath $tempPythonPath -Force -ErrorAction SilentlyContinue
}

try {
try {
    if (-not (Test-Path -LiteralPath $tempResultPath)) {
        throw 'The persistence engine did not return a result.'
    }
    $result = Get-Content -Raw -LiteralPath $tempResultPath | ConvertFrom-Json
} finally {
    Remove-Item -LiteralPath $tempResultPath -Force -ErrorAction SilentlyContinue
}

$mirrorStatuses = [ordered]@{
    ccswitchCurrent = 'not_applicable'
    globalCodex = 'not_applicable'
}
$warnings = [System.Collections.Generic.List[string]]::new()

if ([bool]$result.ok -and -not $DryRun -and $isCanonicalCcSwitchRoot -and [bool]$result.syncEligible -and
    $result.status -notin @('skipped', 'superseded')) {
    if (-not (Test-Path -LiteralPath $SyncScript -PathType Leaf)) {
        $mirrorStatuses.ccswitchCurrent = 'failed'
        $mirrorStatuses.globalCodex = 'failed'
        $warnings.Add('The model was persisted, but the configured sync script was not found.')
    } else {
        $targets = [ordered]@{
            ccswitchCurrent = Join-Path $prodexRoot 'manual-homes\ccswitch-current'
            globalCodex = Join-Path $userRoot '.codex'
        }
        try {
            $targetPaths = [string[]]@($targets.Values)
            $syncSucceeded = $false
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                try {
                    $global:LASTEXITCODE = 0
                    $null = @(& $SyncScript `
                        -CcSwitchRoot $CcSwitchRoot `
                        -CodexHome $targetPaths `
                        -Quiet 2>&1)
                    if ($LASTEXITCODE -ne 0) {
                        throw 'sync failed'
                    }
                    $syncSucceeded = $true
                    break
                } catch {
                    if ($attempt -eq 2) { throw }
                    Start-Sleep -Milliseconds 100
                }
            }
            if (-not $syncSucceeded) {
                throw 'sync failed'
            }
            foreach ($key in $targets.Keys) {
                $mirrorStatuses[$key] = 'synced'
            }
        } catch {
            foreach ($key in $targets.Keys) {
                $mirrorStatuses[$key] = 'failed'
            }
            $warnings.Add('The model was persisted, but the current-provider mirrors could not be synchronized.')
        }
    }
} elseif ([bool]$result.ok -and -not $DryRun -and -not $isCanonicalCcSwitchRoot -and
    [bool]$result.syncEligible -and $result.status -notin @('skipped', 'superseded')) {
    $mirrorStatuses.ccswitchCurrent = 'non_canonical_root'
    $mirrorStatuses.globalCodex = 'non_canonical_root'
} elseif ([bool]$result.ok -and $DryRun) {
    $mirrorStatuses.ccswitchCurrent = 'dry_run'
    $mirrorStatuses.globalCodex = 'dry_run'
} elseif ([bool]$result.ok -and $result.status -notin @('skipped', 'superseded')) {
    $mirrorStatuses.ccswitchCurrent = 'provider_not_current'
    $mirrorStatuses.globalCodex = 'provider_not_current'
}
} finally {
    if ($persistenceLockTaken) {
        $persistenceMutex.ReleaseMutex()
    }
    $persistenceMutex.Dispose()
}

if ([bool]$result.ok) {
    $result | Add-Member -NotePropertyName mirrors -NotePropertyValue ([pscustomobject]$mirrorStatuses) -Force
    $result | Add-Member -NotePropertyName warnings -NotePropertyValue @($warnings) -Force
}

if ($Json) {
    $result | ConvertTo-Json -Depth 8 -Compress
} elseif (-not [bool]$result.ok) {
    Write-Error ("[persist-model] failed code={0} message={1}" -f $result.errorCode, $result.message)
} else {
    $changes = if (@($result.changedFields).Count -gt 0) { @($result.changedFields) -join ',' } else { '<none>' }
    switch ([string]$result.status) {
        'skipped' {
            Write-Output ("[persist-model] skipped provider={0} reason=model-settings-unchanged" -f $result.providerId)
        }
        'dry_run' {
            Write-Output ("[persist-model] dry-run provider={0} changes={1} database_change={2}" -f `
                $result.providerId, $changes, ([bool]$result.wouldDatabaseChange).ToString().ToLowerInvariant())
        }
        'already_persisted' {
            Write-Output ("[persist-model] already persisted provider={0} changes={1}" -f $result.providerId, $changes)
        }
        'superseded' {
            Write-Output ("[persist-model] superseded provider={0} changes={1}" -f $result.providerId, $changes)
        }
        default {
            Write-Output ("[persist-model] updated provider={0} changes={1} backup={2}" -f `
                $result.providerId, $changes, $result.backupPath)
        }
    }
    foreach ($warning in $warnings) {
        Write-Warning $warning
    }
}

if ($pythonExitCode -ne 0 -or -not [bool]$result.ok) {
    throw ("Model persistence failed ({0})." -f $result.errorCode)
}
