import argparse
import copy
import json
import re
import tomllib
from pathlib import Path


TABLE_HEADER = re.compile(r"^\s*\[([^]]+)]\s*(?:#.*)?$")
ROOT_ASSIGNMENT = re.compile(r"^(?P<indent>\s*)(?P<key>[A-Za-z0-9_-]+)\s*=", re.ASCII)
PROVIDER_SECRET_KEYS = {
    "auth",
    "env_key",
    "experimental_bearer_token",
    "requires_openai_auth",
}
ROUTING_KEYS = {"model", "model_provider", "model_reasoning_effort"}
RESERVED_PROVIDER_IDS = {"openai", "ollama", "lmstudio", "amazon-bedrock"}


def parse_toml(source: str, label: str) -> dict:
    try:
        parsed = tomllib.loads(source)
    except tomllib.TOMLDecodeError as error:
        raise ValueError(f"{label} is not valid TOML: {error}") from error
    if not isinstance(parsed, dict):
        raise ValueError(f"{label} must contain a TOML document")
    return parsed


def active_provider(document: dict, label: str) -> tuple[str, dict]:
    provider_id = document.get("model_provider")
    providers = document.get("model_providers")
    if not isinstance(provider_id, str) or not provider_id:
        raise ValueError(f"{label} has no model_provider")
    if not isinstance(providers, dict) or not isinstance(providers.get(provider_id), dict):
        raise ValueError(f"{label} has no active model provider table")
    return provider_id, providers[provider_id]


def provider_tokens(document: dict, settings_auth: dict | None = None) -> list[str]:
    tokens: list[str] = []
    if isinstance(settings_auth, dict):
        api_key = settings_auth.get("OPENAI_API_KEY")
        if isinstance(api_key, str) and api_key:
            tokens.append(api_key)
    try:
        _, provider = active_provider(document, "provider config")
    except ValueError:
        provider = {}
    for candidate in (
        provider.get("experimental_bearer_token"),
        document.get("experimental_bearer_token"),
    ):
        if isinstance(candidate, str) and candidate:
            tokens.append(candidate)
    return list(dict.fromkeys(tokens))


def toml_key(key: str) -> str:
    return json.dumps(key, ensure_ascii=False)


def toml_value(value: object) -> str:
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if value != value or value in (float("inf"), float("-inf")):
            raise ValueError("non-finite floating point values are not supported")
        return repr(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(element) for element in value) + "]"
    raise ValueError(f"unsupported TOML value type: {type(value).__name__}")


def serialize_table(path: list[str], values: dict) -> list[str]:
    scalar_lines: list[str] = []
    child_tables: list[tuple[str, dict]] = []
    for key, value in values.items():
        if isinstance(value, dict):
            child_tables.append((str(key), value))
        else:
            scalar_lines.append(f"{toml_key(str(key))} = {toml_value(value)}")

    lines = ["[" + ".".join(toml_key(segment) for segment in path) + "]", *scalar_lines]
    for key, child in child_tables:
        lines.extend(["", *serialize_table([*path, key], child)])
    return lines


def table_ranges(source: str) -> list[tuple[str, int, int]]:
    lines = source.splitlines(keepends=True)
    headers: list[tuple[str, int]] = []
    for index, line in enumerate(lines):
        match = TABLE_HEADER.match(line.rstrip("\r\n"))
        if match:
            headers.append((match.group(1).strip(), index))
    return [
        (name, start, headers[index + 1][1] if index + 1 < len(headers) else len(lines))
        for index, (name, start) in enumerate(headers)
    ]


def without_provider_tables(source: str) -> str:
    lines = source.splitlines(keepends=True)
    removed = {
        line_index
        for name, start, end in table_ranges(source)
        if name == "model_providers" or name.startswith("model_providers.")
        for line_index in range(start, end)
    }
    return "".join(line for index, line in enumerate(lines) if index not in removed)


def rewrite_root(
    source: str,
    replacements: dict[str, object],
    removed_keys: set[str] | None = None,
) -> str:
    lines = source.splitlines(keepends=True)
    first_table = next(
        (index for index, line in enumerate(lines) if TABLE_HEADER.match(line.rstrip("\r\n"))),
        len(lines),
    )
    managed_keys = {
        *replacements,
        *(removed_keys or set()),
        "experimental_bearer_token",
        "requires_openai_auth",
    }
    prefix = []
    for line in lines[:first_table]:
        match = ROOT_ASSIGNMENT.match(line)
        if match and match.group("key") in managed_keys:
            continue
        prefix.append(line)
    newline = "\r\n" if "\r\n" in source else "\n"
    if prefix and not prefix[-1].endswith(("\n", "\r")):
        prefix[-1] += newline
    prefix.extend(f"{key} = {toml_value(value)}{newline}" for key, value in replacements.items())
    if first_table < len(lines) and prefix and prefix[-1].strip():
        prefix.append(newline)
    return "".join([*prefix, *lines[first_table:]])


def auth_settings(powershell_exe: str, helper_script: str, storage_id: str) -> dict:
    return {
        "command": str(Path(powershell_exe).resolve()),
        "args": [
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(Path(helper_script).resolve()),
            "-ProviderId",
            storage_id,
        ],
        "timeout_ms": 5000,
        "refresh_interval_ms": 300000,
    }


def sanitized_provider(provider: dict, auth: dict | None) -> dict:
    cleaned = copy.deepcopy(provider)
    for key in PROVIDER_SECRET_KEYS:
        cleaned.pop(key, None)
    if auth is not None:
        cleaned["auth"] = auth
    return cleaned


def append_provider_tables(source: str, providers: dict[str, dict]) -> str:
    newline = "\r\n" if "\r\n" in source else "\n"
    base = source.rstrip("\r\n")
    blocks = [newline.join(serialize_table(["model_providers", provider_id], provider)) for provider_id, provider in providers.items()]
    if not blocks:
        return base + newline
    separator = newline + newline if base else ""
    return base + separator + (newline + newline).join(blocks) + newline


def rewrite_provider_auth(
    source: str,
    storage_id: str,
    powershell_exe: str,
    helper_script: str,
) -> str:
    document = parse_toml(source, "provider config")
    provider_id, provider = active_provider(document, "provider config")
    auth = auth_settings(powershell_exe, helper_script, storage_id)
    base = without_provider_tables(source)
    base = rewrite_root(base, {"model_provider": provider_id})
    updated = append_provider_tables(base, {provider_id: sanitized_provider(provider, auth)})
    parsed = parse_toml(updated, "rewritten provider config")
    updated_id, updated_provider = active_provider(parsed, "rewritten provider config")
    if updated_id != provider_id or updated_provider != sanitized_provider(provider, auth):
        raise ValueError("provider authentication rewrite changed provider semantics")
    return updated


def merge_durable_config(
    global_source: str,
    provider_source: str,
    selection_source: str,
    storage_id: str,
    powershell_exe: str,
    helper_script: str,
) -> str:
    global_document = parse_toml(global_source, "global config")
    provider_document = parse_toml(provider_source, "provider config")
    selection_document = parse_toml(selection_source, "selection config")
    provider_id, provider = active_provider(provider_document, "provider config")
    replacements: dict[str, object] = {"model_provider": provider_id}
    for key in ("model", "model_reasoning_effort"):
        selected = selection_document.get(key)
        if isinstance(selected, str) and selected:
            replacements[key] = selected

    auth = auth_settings(powershell_exe, helper_script, storage_id)
    base = without_provider_tables(global_source)
    base = rewrite_root(base, replacements, ROUTING_KEYS)
    updated = append_provider_tables(base, {provider_id: sanitized_provider(provider, auth)})
    parsed = parse_toml(updated, "merged config")
    updated_id, updated_provider = active_provider(parsed, "merged config")
    if updated_id != provider_id or updated_provider != sanitized_provider(provider, auth):
        raise ValueError("durable merge changed provider routing")
    for key, expected in replacements.items():
        if parsed.get(key) != expected:
            raise ValueError(f"durable merge did not preserve {key}")

    ignored = {"model_providers", *ROUTING_KEYS, "experimental_bearer_token", "requires_openai_auth"}
    before_global = {key: value for key, value in global_document.items() if key not in ignored}
    after_global = {key: value for key, value in parsed.items() if key not in ignored}
    if before_global != after_global:
        raise ValueError("durable merge changed unrelated global config")
    return updated


def merge_official_durable_config(global_source: str, selection_source: str) -> str:
    global_document = parse_toml(global_source, "global config")
    selection_document = parse_toml(selection_source, "selection config")
    replacements: dict[str, object] = {}
    for key in ("model", "model_reasoning_effort"):
        selected = selection_document.get(key)
        if isinstance(selected, str) and selected:
            replacements[key] = selected

    base = without_provider_tables(global_source)
    updated = rewrite_root(base, replacements, ROUTING_KEYS)
    parsed = parse_toml(updated, "merged official config")
    if "model_provider" in parsed or "model_providers" in parsed:
        raise ValueError("official durable merge retained custom provider routing")
    for key, expected in replacements.items():
        if parsed.get(key) != expected:
            raise ValueError(f"official durable merge did not preserve {key}")

    ignored = {"model_providers", *ROUTING_KEYS, "experimental_bearer_token", "requires_openai_auth"}
    before_global = {key: value for key, value in global_document.items() if key not in ignored}
    after_global = {key: value for key, value in parsed.items() if key not in ignored}
    if before_global != after_global:
        raise ValueError("official durable merge changed unrelated global config")
    return updated


def sanitize_global_config(
    source: str,
    auth_by_provider: dict[str, dict | None],
) -> str:
    document = parse_toml(source, "global config")
    providers = document.get("model_providers")
    if not isinstance(providers, dict):
        return rewrite_root(source, {})
    sanitized: dict[str, dict] = {}
    for provider_id, provider in providers.items():
        if not isinstance(provider, dict):
            raise ValueError(f"global provider {provider_id} must be a TOML table")
        auth = auth_by_provider.get(provider_id)
        sanitized[provider_id] = sanitized_provider(provider, auth)
    base = rewrite_root(without_provider_tables(source), {})
    return append_provider_tables(base, sanitized)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("merge",))
    parser.add_argument("--global-config", required=True, type=Path)
    parser.add_argument("--provider-config", required=True, type=Path)
    parser.add_argument("--selection-config", required=True, type=Path)
    parser.add_argument("--provider-id", required=True)
    parser.add_argument("--powershell-exe", required=True)
    parser.add_argument("--helper-script", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--official-provider", action="store_true")
    args = parser.parse_args()
    global_source = args.global_config.read_text(encoding="utf-8-sig")
    selection_source = args.selection_config.read_text(encoding="utf-8-sig")
    if args.official_provider:
        updated = merge_official_durable_config(global_source, selection_source)
    else:
        updated = merge_durable_config(
            global_source,
            args.provider_config.read_text(encoding="utf-8-sig"),
            selection_source,
            args.provider_id,
            args.powershell_exe,
            args.helper_script,
        )
    args.output.write_text(updated, encoding="utf-8", newline="")


if __name__ == "__main__":
    main()
