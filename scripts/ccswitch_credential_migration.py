import argparse
import ctypes
import hashlib
import json
import os
import sqlite3
import stat
import tempfile
import time
from collections.abc import Iterator
from contextlib import closing
from ctypes import wintypes
from dataclasses import dataclass, replace
from pathlib import Path

from ccswitch_config import (
    RESERVED_PROVIDER_IDS,
    active_provider,
    auth_settings,
    merge_durable_config,
    parse_toml,
    provider_tokens,
    rewrite_provider_auth,
    sanitize_global_config,
)


VAULT_HEADER = b"CCSWITCH-DPAPI-1\0"
ROLLBACK_ENTROPY = b"ccswitch-codex-database-rollback-v1"
TEXT_SUFFIXES = {
    ".cmd",
    ".json",
    ".jsonl",
    ".log",
    ".md",
    ".ps1",
    ".py",
    ".toml",
    ".txt",
    ".yaml",
    ".yml",
}


class DataBlob(ctypes.Structure):
    _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_byte))]


def data_blob(payload: bytes) -> tuple[DataBlob, ctypes.Array]:
    buffer = ctypes.create_string_buffer(payload)
    blob = DataBlob(len(payload), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_byte)))
    return blob, buffer


def protect_data(payload: bytes, entropy: bytes) -> bytes:
    input_blob, input_buffer = data_blob(payload)
    entropy_blob, entropy_buffer = data_blob(entropy)
    output_blob = DataBlob()
    succeeded = ctypes.windll.crypt32.CryptProtectData(
        ctypes.byref(input_blob),
        None,
        ctypes.byref(entropy_blob),
        None,
        None,
        0,
        ctypes.byref(output_blob),
    )
    _ = input_buffer, entropy_buffer
    if not succeeded:
        raise ctypes.WinError()
    try:
        return ctypes.string_at(output_blob.data, output_blob.size)
    finally:
        ctypes.windll.kernel32.LocalFree(output_blob.data)


def unprotect_data(payload: bytes, entropy: bytes) -> bytes:
    input_blob, input_buffer = data_blob(payload)
    entropy_blob, entropy_buffer = data_blob(entropy)
    output_blob = DataBlob()
    succeeded = ctypes.windll.crypt32.CryptUnprotectData(
        ctypes.byref(input_blob),
        None,
        ctypes.byref(entropy_blob),
        None,
        None,
        0,
        ctypes.byref(output_blob),
    )
    _ = input_buffer, entropy_buffer
    if not succeeded:
        raise ctypes.WinError()
    try:
        return ctypes.string_at(output_blob.data, output_blob.size)
    finally:
        ctypes.windll.kernel32.LocalFree(output_blob.data)


def provider_entropy(storage_id: str) -> bytes:
    return hashlib.sha256(("ccswitch-codex:" + storage_id).encode("utf-8")).digest()


def vault_path(vault_root: Path, storage_id: str) -> Path:
    filename = hashlib.sha256(storage_id.encode("utf-8")).hexdigest() + ".dpapi"
    return vault_root / filename


def atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary_name = tempfile.mkstemp(prefix=path.name + ".tmp-", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def store_token(vault_root: Path, storage_id: str, token: str) -> Path:
    if not token:
        raise ValueError(f"provider {storage_id} has an empty token")
    destination = vault_path(vault_root, storage_id)
    payload = token.encode("utf-8")
    if destination.exists():
        existing = load_token(vault_root, storage_id)
        if existing != token:
            raise ValueError(f"provider {storage_id} conflicts with its existing DPAPI credential")
        return destination
    encrypted = protect_data(payload, provider_entropy(storage_id))
    atomic_write(destination, VAULT_HEADER + encrypted)
    if load_token(vault_root, storage_id) != token:
        raise ValueError(f"provider {storage_id} DPAPI round-trip verification failed")
    return destination


def load_token(vault_root: Path, storage_id: str) -> str:
    payload = vault_path(vault_root, storage_id).read_bytes()
    if not payload.startswith(VAULT_HEADER):
        raise ValueError(f"provider {storage_id} has an invalid DPAPI credential header")
    decrypted = unprotect_data(payload[len(VAULT_HEADER) :], provider_entropy(storage_id))
    token = decrypted.decode("utf-8")
    if not token:
        raise ValueError(f"provider {storage_id} has an empty DPAPI credential")
    return token


def short_hash(payload: str | bytes) -> str:
    encoded = payload.encode("utf-8") if isinstance(payload, str) else payload
    return hashlib.sha256(encoded).hexdigest()[:16]


def content_hash(payload: str | dict) -> str:
    if not isinstance(payload, str):
        payload = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return short_hash(payload)


def read_json(path: Path) -> dict:
    parsed = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(parsed, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return parsed


def write_text(path: Path, content: str) -> None:
    atomic_write(path, content.encode("utf-8"))


@dataclass
class ProviderRecord:
    provider_id: str
    name: str
    category: str | None
    is_current: bool
    old_settings: str
    settings: dict
    config: dict
    config_text: str
    token: str | None
    issue: str | None


def provider_records(database: Path, vault_root: Path) -> list[ProviderRecord]:
    uri = database.resolve().as_uri() + "?mode=ro"
    with closing(sqlite3.connect(uri, uri=True, timeout=5.0)) as connection:
        connection.row_factory = sqlite3.Row
        rows = connection.execute(
            "select id, name, category, is_current, settings_config "
            "from providers where app_type='codex' order by is_current desc, sort_index, id"
        ).fetchall()
    records: list[ProviderRecord] = []
    for row in rows:
        settings = json.loads(row["settings_config"] or "{}")
        if not isinstance(settings, dict):
            raise ValueError(f"provider {row['id']} settings must be an object")
        config_text = settings.get("config")
        if not isinstance(config_text, str):
            raise ValueError(f"provider {row['id']} has no config string")
        config = parse_toml(config_text, f"provider {row['id']} config")
        token = None
        issue = None
        if row["category"] == "official":
            if config.get("model_provider") is not None or config.get("model_providers") is not None:
                issue = "official provider contains custom provider routing"
            elif provider_tokens(config, settings.get("auth")):
                issue = "official provider contains API-key authentication"
        else:
            tokens = provider_tokens(config, settings.get("auth"))
            if len(tokens) > 1:
                issue = "plaintext credential sources conflict"
            elif tokens:
                token = tokens[0]
            elif vault_path(vault_root, row["id"]).is_file():
                token = load_token(vault_root, row["id"])
            else:
                issue = "credential is missing"
        records.append(
            ProviderRecord(
                provider_id=row["id"],
                name=row["name"],
                category=row["category"],
                is_current=bool(row["is_current"]),
                old_settings=row["settings_config"],
                settings=settings,
                config=config,
                config_text=config_text,
                token=token,
                issue=issue,
            )
        )
    return records


def global_provider_tokens(global_config: Path, vault_root: Path) -> tuple[dict[str, str], list[str]]:
    source = global_config.read_text(encoding="utf-8-sig")
    document = parse_toml(source, "global config")
    providers = document.get("model_providers")
    if not isinstance(providers, dict):
        return {}, []
    active_id = document.get("model_provider")
    top_level = document.get("experimental_bearer_token")
    tokens: dict[str, str] = {}
    issues: list[str] = []
    for provider_id, provider in providers.items():
        if not isinstance(provider, dict):
            continue
        if provider_id in RESERVED_PROVIDER_IDS:
            secret_keys = {"auth", "env_key", "experimental_bearer_token"}
            if secret_keys.intersection(provider) or (
                provider_id == active_id and isinstance(top_level, str) and top_level
            ):
                issues.append(f"reserved global provider {provider_id} contains custom credentials")
            continue
        candidates = []
        bearer = provider.get("experimental_bearer_token")
        if isinstance(bearer, str) and bearer:
            candidates.append(bearer)
        if provider_id == active_id and isinstance(top_level, str) and top_level:
            candidates.append(top_level)
        candidates = list(dict.fromkeys(candidates))
        storage_id = "global:" + provider_id
        if len(candidates) > 1:
            issues.append(f"global provider {provider_id} plaintext credential sources conflict")
        elif candidates:
            tokens[provider_id] = candidates[0]
        elif vault_path(vault_root, storage_id).is_file():
            tokens[provider_id] = load_token(vault_root, storage_id)
        elif provider.get("auth") is not None or provider.get("env_key") is not None:
            issues.append(f"global provider {provider_id} is not backed by this DPAPI vault")
    return tokens, issues


def run_home_audit(
    run_homes: Path,
    provider_categories: dict[str, str | None],
) -> tuple[int, list[dict[str, str]]]:
    if not run_homes.is_dir():
        return 0, []
    run_count = 0
    issues: list[dict[str, str]] = []
    for home in run_homes.iterdir():
        metadata_path = home / "run-provider.json"
        if not home.is_dir() or not metadata_path.is_file():
            continue
        run_count += 1
        try:
            metadata = read_json(metadata_path)
            provider_id = metadata.get("providerId")
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
            issues.append({"runHome": home.name, "issue": "run metadata is invalid"})
            continue
        if not isinstance(provider_id, str) or provider_id not in provider_categories:
            issues.append({"runHome": home.name, "issue": "run provider is not present in the CC Switch database"})
            continue
        for key in ("model", "modelReasoningEffort"):
            value = metadata.get(key)
            if value is not None and (not isinstance(value, str) or not value.strip()):
                issues.append({"runHome": home.name, "issue": f"run metadata {key} is invalid"})
        if provider_categories[provider_id] != "official" and not (home / "config.toml").is_file():
            if not any(
                isinstance(metadata.get(key), str) and bool(metadata[key].strip())
                for key in ("model", "modelReasoningEffort")
            ):
                issues.append({"runHome": home.name, "issue": "third-party run config is missing and cannot be reconstructed"})
    return run_count, issues


def official_protected_paths(args: argparse.Namespace, records: list[ProviderRecord]) -> set[Path]:
    protected = {args.global_config.with_name("auth.json").resolve()}
    by_id = {record.provider_id: record for record in records}
    current = next((record for record in records if record.is_current), None)
    if current is not None and current.category == "official":
        protected.update({(args.current_home / name).resolve() for name in ("auth.json", "config.toml")})
    if args.run_homes.is_dir():
        for home in args.run_homes.iterdir():
            metadata_path = home / "run-provider.json"
            if not home.is_dir() or not metadata_path.is_file():
                continue
            try:
                provider_id = read_json(metadata_path).get("providerId")
            except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
                protected.update({(home / name).resolve() for name in ("auth.json", "config.toml")})
                continue
            if provider_id in by_id and by_id[provider_id].category == "official":
                protected.update({(home / name).resolve() for name in ("auth.json", "config.toml")})
    return protected


def has_expected_auth(config: dict, storage_id: str, args: argparse.Namespace) -> bool:
    try:
        _, provider = active_provider(config, "provider config")
    except ValueError:
        return False
    return provider.get("auth") == auth_settings(
        args.powershell_exe,
        str(args.helper_script),
        storage_id,
    )


def global_command_auth_count(
    args: argparse.Namespace,
    global_tokens: dict[str, str],
) -> tuple[int, list[str]]:
    document = parse_toml(args.global_config.read_text(encoding="utf-8-sig"), "global config")
    providers = document.get("model_providers")
    if not isinstance(providers, dict):
        return 0, []
    active_id = document.get("model_provider")
    top_level = document.get("experimental_bearer_token")
    count = 0
    issues: list[str] = []
    for provider_id in global_tokens:
        provider = providers.get(provider_id)
        if not isinstance(provider, dict):
            issues.append(f"global provider {provider_id} is missing")
            continue
        has_plaintext = bool(provider.get("experimental_bearer_token")) or (
            provider_id == active_id and isinstance(top_level, str) and bool(top_level)
        )
        expected = auth_settings(args.powershell_exe, str(args.helper_script), "global:" + provider_id)
        if provider.get("auth") == expected:
            count += 1
        elif not has_plaintext:
            issues.append(f"global provider {provider_id} has non-canonical command authentication")
    return count, issues


def audit(args: argparse.Namespace) -> dict:
    records = provider_records(args.database, args.vault_root)
    global_tokens, global_issues = global_provider_tokens(args.global_config, args.vault_root)
    third_party = [record for record in records if record.category != "official"]
    run_count, run_issues = run_home_audit(
        args.run_homes,
        {record.provider_id: record.category for record in records},
    )
    issues = [
        {"providerId": record.provider_id, "providerName": record.name, "issue": record.issue}
        for record in records
        if record.issue
    ]
    current_records = [record for record in records if record.is_current]
    if len(current_records) != 1:
        issues.append({"issue": f"expected exactly one current Codex provider; found {len(current_records)}"})
    else:
        settings_path = args.database.with_name("settings.json")
        try:
            selected_provider = read_json(settings_path).get("currentProviderCodex")
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError):
            issues.append({"issue": "CC Switch settings.json is invalid"})
        else:
            if selected_provider != current_records[0].provider_id:
                issues.append({"issue": "settings.json and SQLite current provider disagree"})
    plaintext_count = sum(bool(provider_tokens(record.config, record.settings.get("auth"))) for record in third_party)
    command_count = 0
    for record in third_party:
        plaintext = provider_tokens(record.config, record.settings.get("auth"))
        expected_auth = has_expected_auth(record.config, record.provider_id, args)
        command_count += int(expected_auth)
        if not plaintext and record.token and not expected_auth:
            issues.append({
                "providerId": record.provider_id,
                "providerName": record.name,
                "issue": "provider has non-canonical command authentication",
            })
    global_command_count, global_command_issues = global_command_auth_count(args, global_tokens)
    known_tokens = [record.token for record in third_party if record.token]
    known_tokens.extend(global_tokens.values())
    protected_paths = official_protected_paths(args, records)
    scan_issues: list[dict[str, str]] = []
    known_occurrences = 0
    try:
        occurrences = token_occurrences_by_path(args.scan_root, known_tokens, audit_scan_exclusions(args))
        known_occurrences = sum(occurrences.values())
        collisions = sorted(str(path) for path in occurrences if path.resolve() in protected_paths)
        scan_issues.extend({"path": path, "issue": "official authentication contains a third-party token"} for path in collisions)
    except (OSError, UnicodeError, ValueError) as error:
        scan_issues.append({"issue": f"managed credential scan failed: {error}"})
    rotation_providers: list[dict[str, str]] = []
    seen_rotation_tokens: set[str] = set()
    for record in third_party:
        if record.token and record.token not in seen_rotation_tokens:
            rotation_providers.append({"providerId": record.provider_id, "providerName": record.name})
            seen_rotation_tokens.add(record.token)
    for provider_id, token in global_tokens.items():
        if token not in seen_rotation_tokens:
            rotation_providers.append({"providerId": "global:" + provider_id, "providerName": provider_id})
            seen_rotation_tokens.add(token)
    return {
        "ok": not issues and not global_issues and not global_command_issues and not run_issues and not scan_issues,
        "schemaVersion": 1,
        "mode": "audit",
        "database": str(args.database),
        "providerCount": len(records),
        "thirdPartyProviderCount": len(third_party),
        "officialProviderCount": len(records) - len(third_party),
        "plaintextProviderCount": plaintext_count,
        "commandBackedProviderCount": command_count,
        "globalCommandBackedProviderCount": global_command_count,
        "globalCustomCredentialCount": len(global_tokens),
        "runHomeCount": run_count,
        "knownTokenOccurrenceCount": known_occurrences,
        "issues": [
            *issues,
            *({"issue": issue} for issue in global_issues),
            *({"issue": issue} for issue in global_command_issues),
            *run_issues,
            *scan_issues,
        ],
        "rotationProviders": rotation_providers,
    }


def create_rollback(database: Path, rollback_root: Path) -> dict:
    rollback_root.mkdir(parents=True, exist_ok=False)
    temporary_database = rollback_root / "cc-switch.db.plaintext.tmp"
    try:
        source = sqlite3.connect(database)
        destination = sqlite3.connect(temporary_database)
        try:
            source.backup(destination)
        finally:
            destination.close()
            source.close()
        database_payload = temporary_database.read_bytes()
        database_hash = hashlib.sha256(database_payload).hexdigest()
        encrypted = protect_data(database_payload, ROLLBACK_ENTROPY)
        encrypted_path = rollback_root / "cc-switch.db.dpapi"
        atomic_write(encrypted_path, VAULT_HEADER + encrypted)
        round_trip = unprotect_data(encrypted, ROLLBACK_ENTROPY)
        if hashlib.sha256(round_trip).hexdigest() != database_hash:
            raise ValueError("encrypted database rollback verification failed")
    finally:
        temporary_database.unlink(missing_ok=True)
    manifest = {
        "schemaVersion": 1,
        "createdUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "databaseSha256": database_hash,
        "encryptedSha256": hashlib.sha256((rollback_root / "cc-switch.db.dpapi").read_bytes()).hexdigest(),
        "databaseFile": "cc-switch.db.dpapi",
        "protection": "Windows DPAPI CurrentUser",
    }
    write_text(rollback_root / "manifest.json", json.dumps(manifest, indent=2) + "\n")
    return manifest


def migrated_provider_record(
    record: ProviderRecord,
    powershell_exe: str,
    helper_script: str,
) -> tuple[str, ProviderRecord]:
    updated_config = rewrite_provider_auth(
        record.config_text,
        record.provider_id,
        powershell_exe,
        helper_script,
    )
    updated_settings = dict(record.settings)
    updated_settings["config"] = updated_config
    updated_settings["auth"] = {}
    serialized = json.dumps(updated_settings, ensure_ascii=False, separators=(",", ":"))
    return serialized, replace(
        record,
        old_settings=serialized,
        settings=updated_settings,
        config=parse_toml(updated_config, "updated provider config"),
        config_text=updated_config,
    )


def update_database(
    database: Path,
    original_records: list[ProviderRecord],
    updated_records: list[ProviderRecord],
) -> list[ProviderRecord]:
    with closing(sqlite3.connect(database, timeout=5.0, isolation_level=None)) as connection:
        connection.execute("pragma busy_timeout=5000")
        connection.execute("begin immediate")
        try:
            for original, updated in zip(original_records, updated_records, strict=True):
                if original.category == "official":
                    continue
                cursor = connection.execute(
                    "update providers set settings_config=? "
                    "where app_type='codex' and id=? and settings_config=?",
                    (updated.old_settings, original.provider_id, original.old_settings),
                )
                if cursor.rowcount != 1:
                    raise ValueError(f"provider {original.provider_id} changed during migration")
            check = connection.execute("pragma integrity_check").fetchone()[0]
            if check != "ok":
                raise ValueError(f"database integrity check failed: {check}")
            connection.commit()
        except Exception:
            connection.rollback()
            raise
    return updated_records


def migrated_provider_records(
    records: list[ProviderRecord],
    powershell_exe: str,
    helper_script: str,
) -> list[ProviderRecord]:
    migrated: list[ProviderRecord] = []
    for record in records:
        if record.category == "official":
            migrated.append(record)
        else:
            _, updated = migrated_provider_record(record, powershell_exe, helper_script)
            migrated.append(updated)
    return migrated


def update_global_config(args: argparse.Namespace, global_tokens: dict[str, str]) -> str:
    source = args.global_config.read_text(encoding="utf-8-sig")
    auth_by_provider = {
        provider_id: auth_settings(
            args.powershell_exe,
            str(args.helper_script),
            "global:" + provider_id,
        )
        for provider_id in global_tokens
    }
    updated = sanitize_global_config(source, auth_by_provider)
    write_text(args.global_config, updated)
    return updated


def selection_source_from_metadata(metadata: dict) -> str:
    lines: list[str] = []
    for metadata_key, config_key in (
        ("model", "model"),
        ("modelReasoningEffort", "model_reasoning_effort"),
    ):
        value = metadata.get(metadata_key)
        if isinstance(value, str) and value:
            lines.append(f"{config_key} = {json.dumps(value, ensure_ascii=False)}")
    return "\n".join(lines) + "\n"


def update_isolated_home(
    home: Path,
    record: ProviderRecord,
    global_source: str,
    powershell_exe: str,
    helper_script: str,
) -> bool:
    config_path = home / "config.toml"
    metadata_path = home / "run-provider.json"
    if record.category == "official":
        if not metadata_path.is_file():
            return False
        metadata = read_json(metadata_path)
        metadata["providerCategory"] = record.category
        write_text(metadata_path, json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
        return True
    metadata = read_json(metadata_path) if metadata_path.is_file() else {}
    selection_source = (
        config_path.read_text(encoding="utf-8-sig")
        if config_path.is_file()
        else selection_source_from_metadata(metadata)
    )
    updated_config = merge_durable_config(
        global_source,
        record.config_text,
        selection_source,
        record.provider_id,
        powershell_exe,
        helper_script,
    )
    write_text(config_path, updated_config)
    write_text(home / "auth.json", "{}\n")
    if metadata_path.is_file():
        metadata["providerCategory"] = record.category
        metadata["configSha256"] = content_hash(updated_config)
        metadata["authSha256"] = content_hash({})
        parsed_config = parse_toml(updated_config, "run config")
        metadata["model"] = parsed_config.get("model")
        metadata["modelReasoningEffort"] = parsed_config.get("model_reasoning_effort")
        write_text(metadata_path, json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    return True


def redact_bytes(token: bytes) -> bytes:
    marker = b"REDACTED_CCSWITCH_TOKEN"
    if len(token) <= len(marker):
        return marker[: len(token)]
    return marker + (b"_" * (len(token) - len(marker)))


def redact_known_tokens(path: Path, token_bytes: list[bytes]) -> int:
    payload = path.read_bytes()
    replacements: list[tuple[int, bytes]] = []
    for token in token_bytes:
        start = 0
        while True:
            index = payload.find(token, start)
            if index < 0:
                break
            replacements.append((index, redact_bytes(token)))
            start = index + len(token)
    if not replacements:
        return 0
    with path.open("r+b", buffering=0) as stream:
        for offset, replacement in sorted(replacements):
            stream.seek(offset)
            stream.write(replacement)
    return len(replacements)


def is_reparse_point(path: Path) -> bool:
    attributes = getattr(path.stat(follow_symlinks=False), "st_file_attributes", 0)
    return bool(attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def managed_file_paths(roots: list[Path], excluded: set[Path]) -> Iterator[Path]:
    for root in roots:
        if not root.exists():
            continue
        pending = [root]
        while pending:
            path = pending.pop()
            if is_reparse_point(path):
                raise ValueError(f"managed credential scan encountered a reparse point: {path}")
            resolved = path.resolve(strict=True)
            if path.is_file():
                if resolved not in excluded:
                    yield path
                continue
            if not path.is_dir():
                raise ValueError(f"managed credential scan encountered an unsupported path: {path}")
            with os.scandir(path) as entries:
                pending.extend(Path(entry.path) for entry in entries)


def is_managed_text_path(path: Path) -> bool:
    name = path.name.lower()
    return (
        path.suffix.lower() in TEXT_SUFFIXES
        or name.startswith("config.toml.bak-")
        or name.startswith("auth.json.bak-")
        or not path.suffix
    )


def managed_text_paths(roots: list[Path], excluded: set[Path]) -> Iterator[Path]:
    for path in managed_file_paths(roots, excluded):
        if is_managed_text_path(path):
            yield path


def token_occurrences_by_path(
    roots: list[Path],
    tokens: list[str],
    excluded: set[Path],
) -> dict[Path, int]:
    token_bytes = [token.encode("utf-8") for token in dict.fromkeys(tokens) if token]
    occurrences: dict[Path, int] = {}
    for path in managed_file_paths(roots, excluded):
        payload = path.read_bytes()
        count = sum(payload.count(token) for token in token_bytes)
        if count:
            occurrences[path.resolve()] = count
    return occurrences


def scan_and_redact(roots: list[Path], tokens: list[str], excluded: set[Path]) -> dict:
    token_bytes = [token.encode("utf-8") for token in dict.fromkeys(tokens) if token]
    file_count = 0
    replacement_count = 0
    for path in managed_text_paths(roots, excluded):
        count = redact_known_tokens(path, token_bytes)
        if count:
            file_count += 1
            replacement_count += count
    return {"redactedFileCount": file_count, "redactedOccurrenceCount": replacement_count}


def count_known_tokens(roots: list[Path], tokens: list[str], excluded: set[Path]) -> int:
    return sum(token_occurrences_by_path(roots, tokens, excluded).values())


def migration_tokens(
    records: list[ProviderRecord],
    global_tokens: dict[str, str],
) -> dict[str, str]:
    tokens = {
        record.provider_id: record.token
        for record in records
        if record.category != "official" and record.token
    }
    tokens.update({"global:" + provider_id: token for provider_id, token in global_tokens.items()})
    return tokens


def store_migration_tokens(tokens: dict[str, str], vault_root: Path) -> None:
    for storage_id, token in tokens.items():
        store_token(vault_root, storage_id, token)


def audit_scan_exclusions(args: argparse.Namespace) -> set[Path]:
    return {
        args.database.resolve(),
        *(path.resolve() for path in args.vault_root.rglob("*") if path.is_file()),
    }
    for record in records:
        if record.category != "official" and record.token:
            store_token(vault_root, record.provider_id, record.token)
    for provider_id, token in global_tokens.items():
        store_token(vault_root, "global:" + provider_id, token)
    return known_tokens


def update_run_homes(
    args: argparse.Namespace,
    records: list[ProviderRecord],
    global_source: str,
) -> int:
    by_id = {record.provider_id: record for record in records}
    current_record = next(record for record in records if record.is_current)
    updated_count = int(
        update_isolated_home(
            args.current_home,
            current_record,
            global_source,
            args.powershell_exe,
            str(args.helper_script),
        )
    )
    if not args.run_homes.is_dir():
        return updated_count
    for home in args.run_homes.iterdir():
        metadata_path = home / "run-provider.json"
        if not home.is_dir() or not metadata_path.is_file():
            continue
        record = by_id.get(read_json(metadata_path).get("providerId"))
        if record is not None:
            updated_count += int(
                update_isolated_home(
                    home,
                    record,
                    global_source,
                    args.powershell_exe,
                    str(args.helper_script),
                )
            )
    return updated_count


def redaction_exclusions(
    args: argparse.Namespace,
    records: list[ProviderRecord],
) -> set[Path]:
    return {
        *audit_scan_exclusions(args),
        *official_protected_paths(args, records),
    }


def migration_file_paths(
    args: argparse.Namespace,
    records: list[ProviderRecord],
    token_paths: set[Path],
) -> set[Path]:
    paths = {args.global_config, *token_paths}
    by_id = {record.provider_id: record for record in records}
    current = next(record for record in records if record.is_current)
    homes = [(args.current_home, current)]
    if args.run_homes.is_dir():
        for home in args.run_homes.iterdir():
            metadata_path = home / "run-provider.json"
            if home.is_dir() and metadata_path.is_file():
                record = by_id.get(read_json(metadata_path).get("providerId"))
                if record is not None:
                    homes.append((home, record))
    for home, record in homes:
        paths.add(home / "run-provider.json")
        if record.category != "official":
            paths.update({home / "config.toml", home / "auth.json"})
    return {path.resolve() for path in paths}


def capture_file_states(paths: set[Path]) -> dict[Path, bytes | None]:
    states: dict[Path, bytes | None] = {}
    for path in paths:
        if path.exists() and not path.is_file():
            raise ValueError(f"managed migration path is not a file: {path}")
        states[path] = path.read_bytes() if path.is_file() else None
    return states


def restore_file_states(states: dict[Path, bytes | None]) -> None:
    failures: list[str] = []
    for path, payload in states.items():
        try:
            if payload is None:
                path.unlink(missing_ok=True)
            elif path.is_file() and path.read_bytes() == payload:
                continue
            else:
                atomic_write(path, payload)
        except OSError as error:
            failures.append(f"{path}: {error}")
    if failures:
        raise OSError("file compensation failed: " + "; ".join(failures))


def sqlite_integrity_check(database: Path) -> None:
    uri = database.resolve().as_uri() + "?mode=ro&immutable=1"
    with closing(sqlite3.connect(uri, uri=True, timeout=5.0)) as connection:
        check = connection.execute("pragma integrity_check").fetchone()[0]
    if check != "ok":
        raise ValueError(f"database integrity check failed: {check}")


def database_file_paths(database: Path) -> tuple[Path, Path, Path]:
    return (
        database.resolve(),
        database.with_name(database.name + "-wal").resolve(),
        database.with_name(database.name + "-shm").resolve(),
    )


def restore_database_payload(database: Path, database_payload: bytes, expected_hash: str) -> None:
    temporary_path = database.with_name(database.name + f".restore-{os.getpid()}.tmp")
    database_paths = database_file_paths(database)
    original_states: dict[Path, bytes | None] | None = None
    try:
        atomic_write(temporary_path, database_payload)
        original_states = capture_file_states(set(database_paths))
        sqlite_integrity_check(temporary_path)
        for sidecar in database_paths[1:]:
            sidecar.unlink(missing_ok=True)
        os.replace(temporary_path, database_paths[0])
        if hashlib.sha256(database_paths[0].read_bytes()).hexdigest() != expected_hash:
            raise ValueError("restored database hash does not match its manifest")
        sqlite_integrity_check(database_paths[0])
    except Exception as error:
        if original_states is not None:
            for path in database_paths:
                if path.is_file():
                    path.unlink(missing_ok=True)
            try:
                restore_file_states(original_states)
            except OSError as compensation_error:
                raise RuntimeError(f"database restore failed and compensation failed: {compensation_error}") from error
        raise
    finally:
        temporary_path.unlink(missing_ok=True)


def apply_migration(args: argparse.Namespace) -> dict:
    report = audit(args)
    if not report["ok"]:
        raise ValueError("credential audit failed; no changes were made")
    records = provider_records(args.database, args.vault_root)
    global_tokens, global_issues = global_provider_tokens(args.global_config, args.vault_root)
    if global_issues:
        raise ValueError("global credential audit failed; no changes were made")
    tokens_by_storage_id = migration_tokens(records, global_tokens)
    all_tokens = list(tokens_by_storage_id.values())
    create_rollback(args.database, args.rollback_root)
    updated_records = migrated_provider_records(
        records,
        args.powershell_exe,
        str(args.helper_script),
    )
    excluded = redaction_exclusions(args, records)
    token_paths = set(token_occurrences_by_path(args.scan_root, all_tokens, excluded))
    file_states = capture_file_states(migration_file_paths(args, records, token_paths))
    vault_states = capture_file_states({vault_path(args.vault_root, storage_id) for storage_id in tokens_by_storage_id})
    file_states.update(vault_states)
    database_updated = False
    try:
        store_migration_tokens(tokens_by_storage_id, args.vault_root)
        global_source = update_global_config(args, global_tokens)
        updated_home_count = update_run_homes(args, updated_records, global_source)
        redaction = scan_and_redact(args.scan_root, all_tokens, excluded)
        remaining_occurrences = count_known_tokens(args.scan_root, all_tokens, excluded)
        if remaining_occurrences:
            raise ValueError("known provider credentials remain in managed scan roots")
        update_database(args.database, records, updated_records)
        database_updated = True
        post_audit = audit(args)
        if (
            not post_audit["ok"]
            or post_audit["plaintextProviderCount"] != 0
            or post_audit["commandBackedProviderCount"] != post_audit["thirdPartyProviderCount"]
            or post_audit["globalCommandBackedProviderCount"] != post_audit["globalCustomCredentialCount"]
        ):
            raise ValueError("post-migration credential audit failed")
    except Exception as error:
        compensation_failures: list[str] = []
        try:
            restore_file_states(file_states)
        except OSError as compensation_error:
            compensation_failures.append(str(compensation_error))
        if database_updated:
            try:
                restore_rollback(args)
            except Exception as compensation_error:
                compensation_failures.append(f"database compensation failed: {compensation_error}")
        if compensation_failures:
            raise RuntimeError("credential migration failed and compensation was incomplete: " + "; ".join(compensation_failures)) from error
        raise
    return {
        "ok": True,
        "schemaVersion": 1,
        "mode": "applied",
        "providerCount": len(records),
        "thirdPartyProviderCount": report["thirdPartyProviderCount"],
        "updatedHomeCount": updated_home_count,
        "vaultFileCount": len(list(args.vault_root.glob("*.dpapi"))),
        "rollbackPath": str(args.rollback_root),
        **redaction,
        "remainingTokenOccurrenceCount": remaining_occurrences,
        "rotationProviders": report["rotationProviders"],
    }


def restore_rollback(args: argparse.Namespace) -> dict:
    manifest = read_json(args.rollback_root / "manifest.json")
    if manifest.get("databaseFile") != "cc-switch.db.dpapi":
        raise ValueError("rollback manifest databaseFile is invalid")
    encrypted_path = (args.rollback_root / "cc-switch.db.dpapi").resolve(strict=True)
    if encrypted_path.parent != args.rollback_root.resolve(strict=True):
        raise ValueError("rollback database file escapes its package")
    payload = encrypted_path.read_bytes()
    if hashlib.sha256(payload).hexdigest() != manifest["encryptedSha256"]:
        raise ValueError("encrypted rollback hash does not match its manifest")
    if not payload.startswith(VAULT_HEADER):
        raise ValueError("rollback package has an invalid DPAPI header")
    database_payload = unprotect_data(payload[len(VAULT_HEADER) :], ROLLBACK_ENTROPY)
    if hashlib.sha256(database_payload).hexdigest() != manifest["databaseSha256"]:
        raise ValueError("decrypted rollback hash does not match its manifest")
    restore_database_payload(args.database, database_payload, manifest["databaseSha256"])
    return {"ok": True, "mode": "restored", "database": str(args.database)}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("audit", "apply", "restore"))
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--global-config", required=True, type=Path)
    parser.add_argument("--vault-root", required=True, type=Path)
    parser.add_argument("--rollback-root", type=Path)
    parser.add_argument("--helper-script", required=True, type=Path)
    parser.add_argument("--powershell-exe", required=True)
    parser.add_argument("--current-home", required=True, type=Path)
    parser.add_argument("--run-homes", required=True, type=Path)
    parser.add_argument("--scan-root", action="append", default=[], type=Path)
    arguments = parser.parse_args()
    arguments.database = arguments.database.resolve()
    arguments.global_config = arguments.global_config.resolve()
    arguments.vault_root = arguments.vault_root.resolve()
    arguments.helper_script = arguments.helper_script.resolve()
    arguments.current_home = arguments.current_home.resolve()
    arguments.run_homes = arguments.run_homes.resolve()
    arguments.scan_root = [path.resolve() for path in arguments.scan_root]
    if arguments.rollback_root is not None:
        arguments.rollback_root = arguments.rollback_root.resolve()
    return arguments


def main() -> None:
    args = parse_args()
    if args.command == "audit":
        report = audit(args)
    elif args.command == "apply":
        if args.rollback_root is None:
            raise SystemExit("--rollback-root is required for apply")
        report = apply_migration(args)
    else:
        if args.rollback_root is None:
            raise SystemExit("--rollback-root is required for restore")
        report = restore_rollback(args)
    print(json.dumps(report, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
