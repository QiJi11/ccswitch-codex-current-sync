import argparse
import copy
import hashlib
import json
import os
import re
import stat
import tomllib
from pathlib import Path


TRUST_ENV_KEY = "NODE_REPL_TRUSTED_BROWSER_CLIENT_SHA256S"
RUNTIME_VERSION_ENV_KEY = "BROWSER_USE_CODEX_APP_VERSION"
TARGET_SECTION = "mcp_servers.node_repl.env"
OPENAI_BUNDLED_MARKETPLACE = "openai-bundled"
MARKETPLACE_MANIFEST_PATH = Path(".agents/plugins/marketplace.json")
PLUGIN_CLIENT_PATHS = {
    "browser": Path("scripts/browser-client.mjs"),
    "computer-use": Path("scripts/computer-use-client.mjs"),
}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
NATIVE_PIPE_PATTERN = re.compile(
    r"^\\\\\.\\pipe\\codex-computer-use-"
    r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$"
)
TABLE_HEADER_PATTERN = re.compile(
    r"^\s*(?:\[\[(.+?)\]\]|\[(.+?)\])\s*(?:#.*)?$"
)
TRUST_ASSIGNMENT_PATTERN = re.compile(rf"^(\s*){TRUST_ENV_KEY}\s*=")
FILE_ATTRIBUTE_REPARSE_POINT = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
BROWSER_INSTRUCTION = "Control the in-app browser in conjunction with the Browser Plugin."
CHROME_INSTRUCTION = (
    "Control the Chrome browser in conjunction with the Chrome Plugin. Prefer this "
    "method of controlling Chrome over alternatives (such as Computer Use) unless the "
    "user explicitly mentions an alternative."
)
STRICT_PLUGIN_TOML = """\
[plugins."browser@openai-bundled"]
enabled = true
channel = "stable"

[plugins."computer-use@openai-bundled"]
enabled = true
channel = "stable"

[plugins."computer-use@openai-bundled".settings]
mode = "native"
"""


def read_text(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as stream:
        return stream.read()


def write_text(path: Path, content: str) -> None:
    with path.open("w", encoding="utf-8", newline="") as stream:
        stream.write(content)


def table_header_name(line: str) -> str | None:
    header = TABLE_HEADER_PATTERN.match(line.rstrip("\r\n"))
    if not header:
        return None
    return (header.group(1) or header.group(2)).strip()


def table_headers(source: str) -> list[tuple[str, int]]:
    lines = source.splitlines(keepends=True)
    headers = []
    for index, line in enumerate(lines):
        header_name = table_header_name(line)
        if header_name is None:
            continue
        try:
            tomllib.loads("".join(lines[:index]))
        except tomllib.TOMLDecodeError:
            continue
        headers.append((header_name, index))
    return headers


def read_json_object(path: Path, description: str) -> dict:
    try:
        json_document = json.loads(read_text(path))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"Unable to read {description}: {path}") from error
    if not isinstance(json_document, dict):
        raise ValueError(f"{description} must be a JSON object: {path}")
    return json_document


def is_reparse_point(path: Path) -> bool:
    try:
        path_metadata = path.lstat()
    except OSError as error:
        raise ValueError(f"Unable to inspect runtime bundle path: {path}") from error
    attributes = getattr(path_metadata, "st_file_attributes", 0)
    return path.is_symlink() or bool(attributes & FILE_ATTRIBUTE_REPARSE_POINT)


def validated_existing_path(path: Path, description: str) -> Path:
    absolute = Path(os.path.abspath(path))
    current = Path(absolute.anchor)
    for component in absolute.parts[1:]:
        current /= component
        if not current.exists():
            raise ValueError(f"{description} is missing: {path}")
        if is_reparse_point(current):
            raise ValueError(f"{description} contains a reparse point: {current}")
    return absolute.resolve(strict=True)


def validated_directory(path: Path, description: str) -> Path:
    resolved = validated_existing_path(path, description)
    if not resolved.is_dir():
        raise ValueError(f"{description} is not a directory: {resolved}")
    return resolved


def validated_file(path: Path, description: str) -> Path:
    resolved = validated_existing_path(path, description)
    if not resolved.is_file():
        raise ValueError(f"{description} is not a file: {resolved}")
    return resolved


def resolve_local_plugin_root(bundle_root: Path, raw_path: str, plugin_name: str) -> Path:
    relative_path = Path(raw_path)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValueError(f"{plugin_name} marketplace path must stay within the bundle")
    plugin_root = validated_directory(
        bundle_root / relative_path,
        f"{plugin_name} plugin directory",
    )
    try:
        plugin_root.relative_to(bundle_root)
    except ValueError as error:
        raise ValueError(
            f"{plugin_name} marketplace path escapes the runtime bundle"
        ) from error
    return plugin_root


def required_marketplace_plugins(marketplace: dict) -> dict[str, dict]:
    if marketplace.get("name") != OPENAI_BUNDLED_MARKETPLACE:
        raise ValueError("Runtime marketplace name must be openai-bundled")
    plugins = marketplace.get("plugins")
    if not isinstance(plugins, list):
        raise ValueError("Runtime marketplace plugins must be an array")
    required_plugins = {}
    for plugin_name in PLUGIN_CLIENT_PATHS:
        matching_plugins = [
            plugin
            for plugin in plugins
            if isinstance(plugin, dict) and plugin.get("name") == plugin_name
        ]
        if len(matching_plugins) != 1:
            raise ValueError(
                f"Runtime marketplace must contain exactly one {plugin_name} plugin"
            )
        required_plugins[plugin_name] = matching_plugins[0]
    return required_plugins


def validated_plugin_root(bundle_root: Path, plugin: dict, plugin_name: str) -> Path:
    plugin_source = plugin.get("source")
    if (
        not isinstance(plugin_source, dict)
        or plugin_source.get("source") != "local"
        or not isinstance(plugin_source.get("path"), str)
        or not plugin_source["path"].strip()
    ):
        raise ValueError(f"{plugin_name} must use a non-empty local marketplace path")
    return resolve_local_plugin_root(bundle_root, plugin_source["path"], plugin_name)


def validate_plugin_manifest(plugin_root: Path, plugin_name: str) -> str:
    manifest_path = validated_file(
        plugin_root / ".codex-plugin/plugin.json",
        f"{plugin_name} plugin manifest",
    )
    plugin_manifest = read_json_object(manifest_path, f"{plugin_name} plugin manifest")
    if plugin_manifest.get("name") != plugin_name:
        raise ValueError(f"{plugin_name} plugin manifest has the wrong name")
    plugin_version = plugin_manifest.get("version")
    if not isinstance(plugin_version, str) or not plugin_version.strip():
        raise ValueError(f"{plugin_name} plugin manifest has no version")
    return plugin_version


def validate_plugin_client(
    plugin_root: Path,
    plugin_name: str,
    client_relative_path: Path,
) -> str:
    client_path = validated_file(
        plugin_root / client_relative_path,
        f"{plugin_name} client",
    )
    return hashlib.sha256(client_path.read_bytes()).hexdigest()


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def relative_runtime_manifest_path(
    runtime_root: Path, raw_path: object, description: str
) -> Path:
    if not isinstance(raw_path, str) or not raw_path.strip():
        raise ValueError(f"Runtime manifest has no {description} path")
    relative_path = Path(raw_path)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValueError(f"Runtime {description} path escapes its bundle")
    resolved = validated_existing_path(runtime_root / relative_path, description)
    try:
        resolved.relative_to(runtime_root)
    except ValueError as error:
        raise ValueError(f"Runtime {description} path escapes its bundle") from error
    return resolved


def validated_store_runtime(bundle_root: Path) -> dict[str, Path]:
    resources_root = validated_directory(bundle_root.parent.parent, "Store resources")
    expected_bundle = resources_root / "plugins" / OPENAI_BUNDLED_MARKETPLACE
    if bundle_root != expected_bundle:
        raise ValueError("OpenAI bundled marketplace has an unexpected Store path")
    runtime_root = validated_directory(resources_root / "cua_node", "Store cua_node")
    manifest_path = validated_file(
        runtime_root / "manifest.json", "Store cua_node manifest"
    )
    manifest = read_json_object(
        manifest_path,
        "Store cua_node manifest",
    )
    node_repl = relative_runtime_manifest_path(
        runtime_root, manifest.get("node_repl_path"), "node_repl"
    )
    node = relative_runtime_manifest_path(runtime_root, manifest.get("node_path"), "node")
    node_modules = relative_runtime_manifest_path(
        runtime_root, manifest.get("node_modules"), "node_modules"
    )
    if not node_repl.is_file() or not node.is_file() or not node_modules.is_dir():
        raise ValueError("Store cua_node manifest paths have the wrong type")
    return {
        "resources_root": resources_root,
        "runtime_root": runtime_root,
        "manifest": manifest,
        "manifest_sha256": file_sha256(manifest_path),
        "node_repl": node_repl,
        "node": node,
        "node_modules": node_modules,
        "codex": validated_file(resources_root / "codex.exe", "Store Codex CLI"),
    }


def validate_runtime_marketplace(source: Path | None) -> dict:
    if source is None:
        raise ValueError("Compatible OpenAI Store runtime bundle is required")
    bundle_root = validated_directory(source, "OpenAI Store runtime bundle")
    marketplace_path = validated_file(
        bundle_root / MARKETPLACE_MANIFEST_PATH,
        "OpenAI bundled marketplace manifest",
    )
    marketplace = read_json_object(
        marketplace_path, "OpenAI bundled marketplace manifest"
    )
    required_plugins = required_marketplace_plugins(marketplace)
    plugin_versions = {}
    client_hashes = []
    for plugin_name, client_relative_path in PLUGIN_CLIENT_PATHS.items():
        plugin_root = validated_plugin_root(
            bundle_root, required_plugins[plugin_name], plugin_name
        )
        plugin_versions[plugin_name] = validate_plugin_manifest(
            plugin_root, plugin_name
        )
        client_hashes.append(
            validate_plugin_client(plugin_root, plugin_name, client_relative_path)
        )
    if len(set(plugin_versions.values())) != 1:
        raise ValueError("Browser and Computer Use plugin versions do not match")
    return {
        "bundle_root": bundle_root,
        "version": next(iter(plugin_versions.values())),
        "client_hashes": client_hashes,
        **validated_store_runtime(bundle_root),
    }


def load_pinned_hashes(path: Path) -> list[str]:
    trust_payload = json.loads(read_text(path))
    expected_keys = {"schemaVersion", "trustedBrowserClientSha256"}
    if not isinstance(trust_payload, dict) or set(trust_payload) != expected_keys:
        raise ValueError("Browser trust file must contain only the documented schema keys")
    if trust_payload["schemaVersion"] != 1:
        raise ValueError("Unsupported browser trust schemaVersion")
    hashes = trust_payload["trustedBrowserClientSha256"]
    if not isinstance(hashes, list) or not hashes:
        raise ValueError("trustedBrowserClientSha256 must be a non-empty array")
    if any(
        not isinstance(hash_value, str) or not SHA256_PATTERN.fullmatch(hash_value)
        for hash_value in hashes
    ):
        raise ValueError("Every trusted browser client hash must be 64 lowercase hex characters")
    return list(dict.fromkeys(hashes))


def trust_env(document: dict) -> dict:
    servers = document.get("mcp_servers", {})
    node_repl = servers.get("node_repl", {}) if isinstance(servers, dict) else {}
    env = node_repl.get("env", {}) if isinstance(node_repl, dict) else {}
    if not isinstance(env, dict):
        raise ValueError(f"[{TARGET_SECTION}] must be a TOML table")
    return env


def existing_hashes(document: dict) -> list[str]:
    raw_hashes = trust_env(document).get(TRUST_ENV_KEY, "")
    if not isinstance(raw_hashes, str):
        raise ValueError(f"{TRUST_ENV_KEY} must be a string")
    hashes = [item.strip().lower() for item in raw_hashes.split(",") if item.strip()]
    if any(not SHA256_PATTERN.fullmatch(item) for item in hashes):
        raise ValueError(f"{TRUST_ENV_KEY} contains an invalid SHA-256 value")
    return hashes


def validated_runtime_transport(runtime: dict) -> tuple[dict, dict]:
    node_repl = runtime.get("mcp_servers", {}).get("node_repl")
    if not isinstance(node_repl, dict):
        raise ValueError("Runtime config has no node_repl transport")
    runtime_command = node_repl.get("command")
    runtime_args = node_repl.get("args", [])
    runtime_env = node_repl.get("env", {})
    if not isinstance(runtime_command, str) or not runtime_command.strip():
        raise ValueError("Runtime config has no complete node_repl transport")
    if not isinstance(runtime_args, list) or any(
        not isinstance(argument, str) for argument in runtime_args
    ):
        raise ValueError("Runtime node_repl args must be an array of strings")
    if not isinstance(runtime_env, dict) or any(
        not isinstance(key, str) or not isinstance(env_value, str)
        for key, env_value in runtime_env.items()
    ):
        raise ValueError("Runtime node_repl env must contain only string values")
    return node_repl, runtime_env


def validate_runtime_plugins(runtime: dict) -> None:
    plugins = runtime.get("plugins", {})
    browser = plugins.get("browser@openai-bundled")
    computer_use = plugins.get("computer-use@openai-bundled")
    if not isinstance(browser, dict) or browser.get("enabled") is not True:
        raise ValueError("Runtime config must enable browser@openai-bundled")
    if not isinstance(computer_use, dict) or computer_use.get("enabled") is not True:
        raise ValueError("Runtime config must enable computer-use@openai-bundled")


def require_path_within(path: Path, root: Path, description: str) -> None:
    try:
        path.relative_to(root)
    except ValueError as error:
        raise ValueError(f"{description} is outside the approved runtime cache") from error


def require_matching_file(
    runtime_path: Path, store_path: Path, description: str
) -> None:
    if file_sha256(runtime_path) != file_sha256(store_path):
        raise ValueError(f"{description} does not match the Store package")


def validated_runtime_cache(
    runtime: dict, store_runtime: dict, runtime_cache_source: Path | None
) -> dict[str, Path]:
    if runtime_cache_source is None:
        raise ValueError("Approved OpenAI Codex runtime cache is required")
    cache_root = validated_directory(runtime_cache_source, "OpenAI Codex runtime cache")
    cua_cache_root = validated_directory(
        cache_root / "runtimes" / "cua_node", "OpenAI Codex cua_node cache"
    )
    codex_cache_root = validated_directory(
        cache_root / "bin", "OpenAI Codex CLI cache"
    )
    node_repl, runtime_env = validated_runtime_transport(runtime)
    if node_repl.get("args", []) != []:
        raise ValueError("Runtime node_repl args must be empty")

    runtime_node_repl = validated_file(
        Path(node_repl["command"]), "Runtime node_repl cache"
    )
    runtime_node = validated_file(
        Path(runtime_env.get("NODE_REPL_NODE_PATH", "")), "Runtime Node cache"
    )
    runtime_node_modules = validated_directory(
        Path(runtime_env.get("NODE_REPL_NODE_MODULE_DIRS", "")),
        "Runtime node_modules cache",
    )
    runtime_codex = validated_file(
        Path(runtime_env.get("CODEX_CLI_PATH", "")), "Runtime Codex CLI cache"
    )
    require_path_within(runtime_node_repl, cua_cache_root, "Runtime node_repl")
    require_path_within(runtime_node, cua_cache_root, "Runtime Node")
    require_path_within(runtime_node_modules, cua_cache_root, "Runtime node_modules")
    require_path_within(runtime_codex, codex_cache_root, "Runtime Codex CLI")

    runtime_root = validated_directory(
        runtime_node_repl.parent.parent, "Runtime cua_node version cache"
    )
    runtime_manifest_path = validated_file(
        runtime_root / "manifest.json", "Runtime cua_node manifest"
    )
    if file_sha256(runtime_manifest_path) != store_runtime["manifest_sha256"]:
        raise ValueError("Runtime cua_node manifest does not match the Store package")
    runtime_manifest = read_json_object(
        runtime_manifest_path, "Runtime cua_node manifest"
    )
    if runtime_manifest != store_runtime["manifest"]:
        raise ValueError("Runtime cua_node manifest content does not match the Store package")
    expected_node_repl = relative_runtime_manifest_path(
        runtime_root, runtime_manifest.get("node_repl_path"), "runtime node_repl"
    )
    expected_node = relative_runtime_manifest_path(
        runtime_root, runtime_manifest.get("node_path"), "runtime node"
    )
    expected_node_modules = relative_runtime_manifest_path(
        runtime_root, runtime_manifest.get("node_modules"), "runtime node_modules"
    )
    if (
        runtime_node_repl != expected_node_repl
        or runtime_node != expected_node
        or runtime_node_modules != expected_node_modules
    ):
        raise ValueError("Runtime cua_node paths do not match the verified manifest")

    require_matching_file(
        runtime_node_repl, store_runtime["node_repl"], "Runtime node_repl"
    )
    require_matching_file(runtime_node, store_runtime["node"], "Runtime Node")
    require_matching_file(runtime_codex, store_runtime["codex"], "Runtime Codex CLI")
    return {
        "node_repl": runtime_node_repl,
        "node": runtime_node,
        "node_modules": runtime_node_modules,
        "codex": runtime_codex,
    }


def validated_native_pipe(runtime: dict, store_runtime: dict) -> str:
    _, runtime_env = validated_runtime_transport(runtime)
    if runtime_env.get(RUNTIME_VERSION_ENV_KEY) != store_runtime["version"]:
        raise ValueError("Runtime config does not match the Store plugin version")
    if runtime_env.get("SKY_CUA_NATIVE_PIPE") != "1":
        raise ValueError("Runtime config has no Computer Use native pipe")
    pipe_directory = runtime_env.get("SKY_CUA_NATIVE_PIPE_DIRECTORY")
    if not isinstance(pipe_directory, str) or not NATIVE_PIPE_PATTERN.fullmatch(
        pipe_directory
    ):
        raise ValueError("Runtime Computer Use native pipe has an invalid name")
    if not set(store_runtime["client_hashes"]).issubset(existing_hashes(runtime)):
        raise ValueError("Runtime config does not trust the Store plugin clients")
    validate_runtime_plugins(runtime)
    return pipe_directory


def strict_runtime_environment(
    store_runtime: dict, runtime_cache: dict, pipe_directory: str
) -> dict:
    return {
        "NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS": "1000",
        "NODE_REPL_NODE_MODULE_DIRS": str(runtime_cache["node_modules"]),
        "NODE_REPL_NODE_PATH": str(runtime_cache["node"]),
        "NODE_REPL_TRUSTED_CODE_PATHS": str(store_runtime["resources_root"]),
        TRUST_ENV_KEY: ",".join(store_runtime["client_hashes"]),
        "BROWSER_USE_AVAILABLE_BACKENDS": "chrome,iab",
        "NODE_REPL_INSTRUCTIONS_USE_CASE_BROWSER": BROWSER_INSTRUCTION,
        "NODE_REPL_INSTRUCTIONS_USE_CASE_CHROME": CHROME_INSTRUCTION,
        "BROWSER_USE_CODEX_APP_BUILD_FLAVOR": "prod",
        RUNTIME_VERSION_ENV_KEY: store_runtime["version"],
        "SKY_CUA_NATIVE_PIPE": "1",
        "CODEX_CLI_PATH": str(runtime_cache["codex"]),
        "SKY_CUA_NATIVE_PIPE_DIRECTORY": pipe_directory,
    }


def strict_runtime_source(
    runtime: dict, store_runtime: dict, runtime_cache_source: Path | None
) -> str:
    runtime_cache = validated_runtime_cache(
        runtime, store_runtime, runtime_cache_source
    )
    pipe_directory = validated_native_pipe(runtime, store_runtime)
    runtime_env = strict_runtime_environment(
        store_runtime, runtime_cache, pipe_directory
    )
    env_assignments = "\n".join(
        f"{key} = {json.dumps(env_value)}" for key, env_value in runtime_env.items()
    )
    return (
        "[mcp_servers.node_repl]\n"
        f"command = {json.dumps(str(runtime_cache['node_repl']))}\n"
        "args = []\n\n"
        "[mcp_servers.node_repl.env]\n"
        f"{env_assignments}\n\n"
        f"{STRICT_PLUGIN_TOML}"
    )


def line_ending(source: str) -> str:
    return "\r\n" if "\r\n" in source else "\n"


def parsed_table_path(header: str) -> tuple[str, ...]:
    document = tomllib.loads(f"[{header}]\n")
    path = []
    while isinstance(document, dict) and len(document) == 1:
        key, document = next(iter(document.items()))
        path.append(key)
    if document != {}:
        raise ValueError(f"Unable to parse TOML table header: {header}")
    return tuple(path)


def updated_assignment(source: str, joined_hashes: str) -> str:
    lines = source.splitlines(keepends=True)
    section_start = None
    section_end = len(lines)
    for header_name, index in table_headers(source):
        if parsed_table_path(header_name) == (
            "mcp_servers",
            "node_repl",
            "env",
        ):
            section_start = index
            continue
        if section_start is not None and header_name is not None:
            section_end = index
            break

    assignment = f'{TRUST_ENV_KEY} = {json.dumps(joined_hashes)}{line_ending(source)}'
    if section_start is None:
        separator = (
            "" if not source or source.endswith(("\n", "\r")) else line_ending(source)
        )
        return (
            f"{source}{separator}{line_ending(source)}"
            f"[{TARGET_SECTION}]{line_ending(source)}{assignment}"
        )

    for index in range(section_start + 1, section_end):
        match = TRUST_ASSIGNMENT_PATTERN.match(lines[index])
        if match:
            lines[index] = f"{match.group(1)}{assignment}"
            return "".join(lines)
    lines.insert(section_end, assignment)
    return "".join(lines)


def without_trust_key(document: dict) -> dict:
    normalized = copy.deepcopy(document)
    servers = normalized.get("mcp_servers")
    node_repl = servers.get("node_repl") if isinstance(servers, dict) else None
    env = node_repl.get("env") if isinstance(node_repl, dict) else None
    if isinstance(env, dict):
        env.pop(TRUST_ENV_KEY, None)
        if not env:
            node_repl.pop("env", None)
        if not node_repl:
            servers.pop("node_repl", None)
        if not servers:
            normalized.pop("mcp_servers", None)
    return normalized


def has_node_repl_section(document: dict) -> bool:
    servers = document.get("mcp_servers")
    return isinstance(servers, dict) and "node_repl" in servers


def apply_overlay(source: str, pinned_hashes: list[str]) -> str:
    original = tomllib.loads(source)
    if not has_node_repl_section(original):
        return source

    merged_hashes = list(dict.fromkeys([*existing_hashes(original), *pinned_hashes]))
    updated_source = updated_assignment(source, ",".join(merged_hashes))
    updated_document = tomllib.loads(updated_source)
    if without_trust_key(original) != without_trust_key(updated_document):
        raise ValueError("Browser trust overlay changed unrelated TOML settings")
    if existing_hashes(updated_document) != merged_hashes:
        raise ValueError("Browser trust overlay verification failed")
    return updated_source


def table_ranges(source: str) -> list[tuple[str, int, int]]:
    lines = source.splitlines(keepends=True)
    headers = table_headers(source)
    return [
        (name, start, headers[index + 1][1] if index + 1 < len(headers) else len(lines))
        for index, (name, start) in enumerate(headers)
    ]


def is_browser_runtime_section(name: str) -> bool:
    path = parsed_table_path(name)
    return path[:2] == ("mcp_servers", "node_repl") or path[:2] in {
        ("plugins", "browser@openai-bundled"),
        ("plugins", "computer-use@openai-bundled"),
    }


def is_managed_browser_section(name: str) -> bool:
    path = parsed_table_path(name)
    return is_browser_runtime_section(name) or path == (
        "plugins",
        "browser@browser-repair",
    )


def is_strict_browser_section(name: str) -> bool:
    path = parsed_table_path(name)
    return is_managed_browser_section(name) or path[:2] == (
        "marketplaces",
        OPENAI_BUNDLED_MARKETPLACE,
    )


def browser_runtime_blocks(source: str) -> str:
    lines = source.splitlines(keepends=True)
    blocks = [
        "".join(lines[start:end]).strip("\r\n")
        for name, start, end in table_ranges(source)
        if is_browser_runtime_section(name)
    ]
    return line_ending(source).join(block for block in blocks if block)


def without_browser_runtime_sections(document: dict) -> dict:
    normalized = copy.deepcopy(document)
    servers = normalized.get("mcp_servers")
    if isinstance(servers, dict):
        servers.pop("node_repl", None)
        if not servers:
            normalized.pop("mcp_servers", None)
    plugins = normalized.get("plugins")
    if isinstance(plugins, dict):
        plugins.pop("browser@openai-bundled", None)
        plugins.pop("computer-use@openai-bundled", None)
        plugins.pop("browser@browser-repair", None)
        if not plugins:
            normalized.pop("plugins", None)
    return normalized


def without_strict_browser_sections(document: dict) -> dict:
    normalized = without_browser_runtime_sections(document)
    marketplaces = normalized.get("marketplaces")
    if isinstance(marketplaces, dict):
        marketplaces.pop(OPENAI_BUNDLED_MARKETPLACE, None)
        if not marketplaces:
            normalized.pop("marketplaces", None)
    return normalized


def merge_browser_runtime(
    destination_source: str,
    runtime_source: str,
    pinned_hashes: list[str],
) -> str:
    return merge_runtime_sections(
        destination_source, runtime_source, pinned_hashes, None
    )


def merge_compatible_browser_runtime(
    destination_source: str,
    runtime_source: str,
    pinned_hashes: list[str],
    runtime_marketplace_source: Path | None,
    runtime_cache_source: Path | None,
) -> str:
    raw_runtime = tomllib.loads(runtime_source)
    if not has_node_repl_section(raw_runtime):
        return apply_overlay(destination_source, pinned_hashes)
    store_runtime = validate_runtime_marketplace(runtime_marketplace_source)
    trusted_runtime_source = strict_runtime_source(
        raw_runtime, store_runtime, runtime_cache_source
    )
    return merge_runtime_sections(
        destination_source,
        trusted_runtime_source,
        [],
        store_runtime["bundle_root"],
    )


def merge_runtime_sections(
    destination_source: str,
    runtime_source: str,
    pinned_hashes: list[str],
    validated_marketplace_source: Path | None,
) -> str:
    destination = tomllib.loads(destination_source)
    raw_runtime = tomllib.loads(runtime_source)
    if not has_node_repl_section(raw_runtime):
        return apply_overlay(destination_source, pinned_hashes)
    overlaid_runtime_source = apply_overlay(runtime_source, pinned_hashes)
    runtime = tomllib.loads(overlaid_runtime_source)
    runtime_node_repl = runtime.get("mcp_servers", {}).get("node_repl")
    runtime_browser = runtime.get("plugins", {}).get("browser@openai-bundled")
    runtime_computer_use = runtime.get("plugins", {}).get(
        "computer-use@openai-bundled"
    )
    runtime_command = (
        runtime_node_repl.get("command")
        if isinstance(runtime_node_repl, dict)
        else None
    )
    runtime_args = (
        runtime_node_repl.get("args", [])
        if isinstance(runtime_node_repl, dict)
        else []
    )
    runtime_env = (
        runtime_node_repl.get("env", {})
        if isinstance(runtime_node_repl, dict)
        else {}
    )
    if not isinstance(runtime_command, str) or not runtime_command.strip():
        raise ValueError("Runtime config has no complete node_repl transport")
    if not isinstance(runtime_args, list) or any(
        not isinstance(arg, str) for arg in runtime_args
    ):
        raise ValueError("Runtime node_repl args must be an array of strings")
    if not isinstance(runtime_env, dict) or any(
        not isinstance(key, str) or not isinstance(value, str)
        for key, value in runtime_env.items()
    ):
        raise ValueError("Runtime node_repl env must contain only string values")
    if (
        not isinstance(runtime_browser, dict)
        or runtime_browser.get("enabled") is not True
    ):
        raise ValueError("Runtime config must enable browser@openai-bundled")
    if (
        not isinstance(runtime_computer_use, dict)
        or runtime_computer_use.get("enabled") is not True
    ):
        raise ValueError("Runtime config must enable computer-use@openai-bundled")
    if not set(pinned_hashes).issubset(existing_hashes(runtime)):
        raise ValueError("Runtime config is missing a pinned Browser hash")

    section_predicate = (
        is_strict_browser_section
        if validated_marketplace_source is not None
        else is_managed_browser_section
    )
    lines = destination_source.splitlines(keepends=True)
    removed_indexes = {
        line_index
        for name, start, end in table_ranges(destination_source)
        if section_predicate(name)
        for line_index in range(start, end)
    }
    remaining = "".join(
        line for index, line in enumerate(lines) if index not in removed_indexes
    ).rstrip("\r\n")
    newline = line_ending(destination_source)
    runtime_blocks = browser_runtime_blocks(overlaid_runtime_source)
    repair_block = '[plugins."browser@browser-repair"]' + newline + "enabled = false"
    managed_blocks = []
    if validated_marketplace_source is not None:
        managed_blocks.append(
            newline.join(
                (
                    f'[marketplaces."{OPENAI_BUNDLED_MARKETPLACE}"]',
                    'source_type = "local"',
                    f"source = {json.dumps(str(validated_marketplace_source))}",
                )
            )
        )
    managed_blocks.extend((runtime_blocks, repair_block))
    updated_source = (
        f"{remaining}{newline}{newline}"
        f"{newline.join(managed_blocks)}{newline}"
    )
    updated = tomllib.loads(updated_source)

    normalize_document = (
        without_strict_browser_sections
        if validated_marketplace_source is not None
        else without_browser_runtime_sections
    )
    if normalize_document(destination) != normalize_document(updated):
        raise ValueError("Browser runtime merge changed unrelated TOML settings")
    if updated.get("mcp_servers", {}).get("node_repl") != runtime_node_repl:
        raise ValueError("Browser runtime node_repl verification failed")
    if updated.get("plugins", {}).get("browser@openai-bundled") != runtime_browser:
        raise ValueError("Official Browser plugin verification failed")
    if (
        updated.get("plugins", {}).get("computer-use@openai-bundled")
        != runtime_computer_use
    ):
        raise ValueError("Computer Use plugin verification failed")
    if updated.get("plugins", {}).get("browser@browser-repair") != {"enabled": False}:
        raise ValueError("Local Browser repair plugin must remain disabled")
    if validated_marketplace_source is not None:
        expected_marketplace = {
            "source_type": "local",
            "source": str(validated_marketplace_source),
        }
        if (
            updated.get("marketplaces", {}).get(OPENAI_BUNDLED_MARKETPLACE)
            != expected_marketplace
        ):
            raise ValueError("OpenAI bundled marketplace verification failed")
    return updated_source


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trust-file", required=True, type=Path)
    parser.add_argument("--input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--require-compatible-runtime-bundle", action="store_true")
    parser.add_argument("--runtime-marketplace-source", type=Path)
    parser.add_argument("--runtime-cache-source", type=Path)
    parser.add_argument("--runtime-source", type=Path)
    args = parser.parse_args()
    pinned_hashes = load_pinned_hashes(args.trust_file)

    if args.input is None or args.output is None:
        parser.error("--input and --output are required for file overlay mode")
    source = read_text(args.input)
    if args.runtime_source is None:
        updated_source = apply_overlay(source, pinned_hashes)
    elif args.require_compatible_runtime_bundle:
        updated_source = merge_compatible_browser_runtime(
            source,
            read_text(args.runtime_source),
            pinned_hashes,
            args.runtime_marketplace_source,
            args.runtime_cache_source,
        )
    else:
        updated_source = merge_browser_runtime(
            source,
            read_text(args.runtime_source),
            pinned_hashes,
        )
    write_text(args.output, updated_source)


if __name__ == "__main__":
    main()
