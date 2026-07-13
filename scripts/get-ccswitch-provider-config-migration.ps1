[CmdletBinding()]
param(
    [string]$CcSwitchRoot = (Join-Path $env:USERPROFILE '.cc-switch'),
    [string]$CodexHome = (Join-Path $env:USERPROFILE '.codex'),
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) {
    $pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
}
if ($null -eq $pythonCommand) {
    throw 'Python 3.11 or newer is required to inspect provider configs.'
}

$pythonCode = @'
import argparse
import copy
import hashlib
import json
import re
import sqlite3
import sys
import tomllib
from pathlib import Path


TABLE_HEADER = re.compile(
    r"^[ \t]*\[(?P<table>[^\[\]\r\n]+)\][ \t]*(?:#.*)?(?:\r?\n)?$"
)
ROOT_APPROVAL = re.compile(
    r"^(?P<prefix>[ \t]*)(?P<key>ask_for_approval|approval_policy)"
    r"(?P<spacing>[ \t]*)=(?P<suffix>.*?)(?P<newline>\r?\n)?$"
)
FEATURE_JS_REPL = re.compile(
    r"^(?P<prefix>[ \t]*)js_repl(?P<spacing>[ \t]*)="
    r"(?P<suffix>.*?)(?P<newline>\r?\n)?$"
)


class PreviewFailure(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def fail(code, message):
    raise PreviewFailure(code, message)


def read_json(path, code):
    try:
        parsed = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        fail(code, f"Unable to read valid JSON from {path}.")
    if not isinstance(parsed, dict):
        fail(code, f"Expected a JSON object in {path}.")
    return parsed


def parse_toml(text, provider_id):
    try:
        return tomllib.loads(text)
    except (tomllib.TOMLDecodeError, UnicodeError):
        fail("invalid_provider_config", f"Provider {provider_id} has invalid TOML config.")


def sanitized_config(parsed):
    sanitized = copy.deepcopy(parsed)
    sanitized.pop("ask_for_approval", None)
    sanitized.pop("approval_policy", None)
    features = sanitized.get("features")
    if isinstance(features, dict):
        features.pop("js_repl", None)
    return sanitized


def rewrite_config_lines(text, official_present):
    current_table = None
    legacy_matches = 0
    js_repl_matches = 0
    migrated_lines = []
    for line in text.splitlines(keepends=True):
        table_match = TABLE_HEADER.match(line)
        if table_match:
            current_table = table_match.group("table").strip()
            migrated_lines.append(line)
            continue

        approval_match = ROOT_APPROVAL.match(line) if current_table is None else None
        if approval_match and approval_match.group("key") == "ask_for_approval":
            legacy_matches += 1
            if official_present:
                continue
            line = (
                approval_match.group("prefix")
                + "approval_policy"
                + approval_match.group("spacing")
                + "="
                + approval_match.group("suffix")
                + (approval_match.group("newline") or "")
            )

        js_match = FEATURE_JS_REPL.match(line) if current_table == "features" else None
        if js_match:
            js_repl_matches += 1
            continue
        migrated_lines.append(line)
    return "".join(migrated_lines), legacy_matches, js_repl_matches


def validate_match_counts(before, legacy_matches, js_repl_matches, provider_id):
    legacy_present = "ask_for_approval" in before
    features = before.get("features")
    js_repl_present = isinstance(features, dict) and "js_repl" in features
    if legacy_present and legacy_matches != 1:
        fail("unsupported_provider_config", f"Provider {provider_id} uses an unsupported legacy approval layout.")
    if js_repl_present and js_repl_matches != 1:
        fail("unsupported_provider_config", f"Provider {provider_id} uses an unsupported js_repl layout.")


def verify_migration(before, after, provider_id):
    expected_approval = before.get("approval_policy", before.get("ask_for_approval"))
    if after.get("approval_policy") != expected_approval or "ask_for_approval" in after:
        fail("migration_verification_failed", f"Provider {provider_id} approval migration did not verify.")
    after_features = after.get("features")
    if isinstance(after_features, dict) and "js_repl" in after_features:
        fail("migration_verification_failed", f"Provider {provider_id} js_repl removal did not verify.")
    if sanitized_config(before) != sanitized_config(after):
        fail("migration_verification_failed", f"Provider {provider_id} would change unrelated config semantics.")


def config_changes(parsed):
    changes = []
    if "ask_for_approval" in parsed:
        change = "remove_ask_for_approval" if "approval_policy" in parsed else "rename_ask_for_approval"
        changes.append(change)
    features = parsed.get("features")
    if isinstance(features, dict) and "js_repl" in features:
        changes.append("remove_features_js_repl")
    return changes


def migrate_config_text(text, provider_id):
    before = parse_toml(text, provider_id)
    changes = config_changes(before)
    if not changes:
        return text, changes
    migrated, legacy_matches, js_repl_matches = rewrite_config_lines(
        text,
        "approval_policy" in before,
    )
    validate_match_counts(before, legacy_matches, js_repl_matches, provider_id)
    after = parse_toml(migrated, provider_id)
    verify_migration(before, after, provider_id)
    return migrated, changes


def open_read_only(db_path):
    connection = sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True, timeout=5.0)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    return connection


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_provider_rows(db_path):
    with open_read_only(db_path) as connection:
        return connection.execute(
            "select id, name, is_current, settings_config "
            "from providers where app_type='codex' order by name, id"
        ).fetchall()


def provider_config(row):
    try:
        provider_settings = json.loads(row["settings_config"] or "{}")
    except json.JSONDecodeError:
        fail("invalid_provider_settings", f"Provider {row['id']} settings_config is invalid JSON.")
    if not isinstance(provider_settings, dict) or not isinstance(provider_settings.get("config"), str):
        fail("invalid_provider_settings", f"Provider {row['id']} has no string settings_config.config.")
    return provider_settings["config"]


def validate_current_provider(rows, settings_provider):
    current_rows = [row for row in rows if int(row["is_current"] or 0) == 1]
    if len(current_rows) != 1 or current_rows[0]["id"] != settings_provider:
        fail("current_provider_mismatch", "settings.json and the Codex database current provider do not match.")


def new_provider_preview(row, settings_provider, config_text, migrated_text, changes):
    return {
        "providerId": row["id"],
        "providerName": row["name"],
        "isCurrent": row["id"] == settings_provider,
        "changes": changes,
        "currentSha256": sha256_text(config_text),
        "migratedSha256": sha256_text(migrated_text),
    }


def settings_provider_id(settings_path):
    settings = read_json(settings_path, "invalid_settings")
    settings_provider = settings.get("currentProviderCodex")
    if not isinstance(settings_provider, str) or not settings_provider:
        fail("invalid_settings", "settings.json does not define currentProviderCodex.")
    return settings_provider


def preview_providers(rows, settings_provider):
    affected = []
    legacy_count = 0
    js_repl_count = 0
    current_config = None
    for row in rows:
        config_text = provider_config(row)
        migrated_text, changes = migrate_config_text(config_text, row["id"])
        if row["id"] == settings_provider:
            current_config = config_text
        if not changes:
            continue
        legacy_count += int(any(change.endswith("ask_for_approval") for change in changes))
        js_repl_count += int("remove_features_js_repl" in changes)
        affected.append(new_provider_preview(row, settings_provider, config_text, migrated_text, changes))
    return affected, legacy_count, js_repl_count, current_config


def read_live_config(codex_home):
    try:
        return (Path(codex_home) / "config.toml").read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError):
        return None


def build_preview(args):
    cc_root = Path(args.cc_switch_root).resolve(strict=True)
    db_path = cc_root / "cc-switch.db"
    if not db_path.is_file():
        fail("database_not_found", f"cc-switch.db was not found under {cc_root}.")
    settings_provider = settings_provider_id(cc_root / "settings.json")
    rows = load_provider_rows(db_path)
    validate_current_provider(rows, settings_provider)
    affected, legacy_count, js_repl_count, current_config = preview_providers(rows, settings_provider)

    live_config = read_live_config(args.codex_home)
    return {
        "ok": True,
        "schemaVersion": 1,
        "mode": "preview",
        "providerCount": len(rows),
        "affectedProviderCount": len(affected),
        "legacyApprovalCount": legacy_count,
        "removedJsReplCount": js_repl_count,
        "currentProviderId": settings_provider,
        "liveConfigMatchesCurrentProvider": live_config == current_config,
        "databaseChanged": False,
        "filesChanged": False,
        "items": affected,
    }


def parse_args():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--cc-switch-root", required=True)
    parser.add_argument("--codex-home", required=True)
    parser.add_argument("--result-path", required=True)
    return parser.parse_args()


def write_result(path, result):
    Path(path).write_text(
        json.dumps(result, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )


arguments = parse_args()
try:
    preview = build_preview(arguments)
    write_result(arguments.result_path, preview)
except PreviewFailure as exc:
    write_result(
        arguments.result_path,
        {"ok": False, "mode": "preview", "errorCode": exc.code, "message": exc.message},
    )
    raise SystemExit(2)
except (OSError, RuntimeError, sqlite3.Error) as exc:
    write_result(
        arguments.result_path,
        {
            "ok": False,
            "mode": "preview",
            "errorCode": "preview_failed",
            "message": f"Provider config preview failed: {type(exc).__name__}.",
        },
    )
    raise SystemExit(3)
'@

$tempPrefix = "ccswitch-provider-config-preview-$PID-$([guid]::NewGuid().ToString('N'))"
$tempPythonPath = Join-Path ([IO.Path]::GetTempPath()) "$tempPrefix.py"
$tempResultPath = Join-Path ([IO.Path]::GetTempPath()) "$tempPrefix.json"
$previousPythonIoEncoding = $env:PYTHONIOENCODING
$previousPythonUtf8 = $env:PYTHONUTF8
$pythonExitCode = 1

try {
    [IO.File]::WriteAllText($tempPythonPath, $pythonCode, [Text.UTF8Encoding]::new($false))
    $env:PYTHONIOENCODING = 'utf-8'
    $env:PYTHONUTF8 = '1'
    & $pythonCommand.Source $tempPythonPath `
        --cc-switch-root $CcSwitchRoot `
        --codex-home $CodexHome `
        --result-path $tempResultPath
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
    if (-not (Test-Path -LiteralPath $tempResultPath -PathType Leaf)) {
        throw 'The provider config preview did not return a result.'
    }
    $preview = Get-Content -LiteralPath $tempResultPath -Raw | ConvertFrom-Json
} finally {
    Remove-Item -LiteralPath $tempResultPath -Force -ErrorAction SilentlyContinue
}

if ($Json) {
    $preview | ConvertTo-Json -Depth 8
} elseif ([bool]$preview.ok) {
    $preview.items | Select-Object providerName, providerId, isCurrent, @{n='changes';e={$_.changes -join ','}} | Format-Table -AutoSize
    Write-Host ("Provider config preview: providers={0} affected={1} legacy_approval={2} removed_js_repl={3} live_matches_current={4}" -f `
        $preview.providerCount, $preview.affectedProviderCount, $preview.legacyApprovalCount, `
        $preview.removedJsReplCount, $preview.liveConfigMatchesCurrentProvider)
}

if ($pythonExitCode -ne 0 -or -not [bool]$preview.ok) {
    throw ([string]$preview.message)
}
