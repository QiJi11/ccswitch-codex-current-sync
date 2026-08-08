from __future__ import annotations

import argparse
import hashlib
import json
import sys
import tomllib
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit, urlunsplit


Probe = Callable[[str, str | None, float], "ProbeResult"]


@dataclass(frozen=True)
class ProbeResult:
    status: int | None
    error: str | None = None


@dataclass(frozen=True)
class RunSnapshot:
    provider_id: str
    model: str
    base_url: str
    api_key: str


def digest(value: object) -> str:
    text = value if isinstance(value, str) else json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def require_run_path(run_home: Path, allowed_root: Path) -> Path:
    absolute_home = run_home.absolute()
    absolute_root = allowed_root.absolute()
    if not absolute_home.is_relative_to(absolute_root) or absolute_home == absolute_root:
        raise ValueError("Run home is outside the allowed run-home root.")
    current = absolute_root
    for component in absolute_home.relative_to(absolute_root).parts:
        current /= component
        if current.is_symlink() or (hasattr(current, "is_junction") and current.is_junction()):
            raise ValueError("Run home cannot contain a reparse point.")
    resolved_home = run_home.resolve(strict=True)
    resolved_root = allowed_root.resolve(strict=True)
    if not resolved_home.is_relative_to(resolved_root) or resolved_home == resolved_root:
        raise ValueError("Run home is outside the allowed run-home root.")
    return resolved_home


def read_run_text(run_home: Path, name: str) -> str:
    path = run_home / name
    if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
        raise ValueError(f"Run file cannot be a reparse point: {name}")
    if not path.is_file():
        raise ValueError(f"Run file is missing: {name}")
    return path.read_text("utf-8")


def read_snapshot(run_home: Path, allowed_root: Path) -> RunSnapshot:
    resolved_home = require_run_path(run_home, allowed_root)
    metadata = json.loads(read_run_text(resolved_home, "run-provider.json"))
    auth = json.loads(read_run_text(resolved_home, "auth.json"))
    config_text = read_run_text(resolved_home, "config.toml")
    config = validate_snapshot(resolved_home, metadata, auth, config_text)
    provider_name = config.get("model_provider")
    provider = config.get("model_providers", {}).get(provider_name, {})
    return RunSnapshot(
        provider_id=metadata["providerId"],
        model=config["model"],
        base_url=provider["base_url"],
        api_key=auth["OPENAI_API_KEY"],
    )


def validate_snapshot(run_home: Path, metadata: dict, auth: dict, config_text: str) -> dict:
    config = tomllib.loads(config_text)
    if metadata.get("schemaVersion") != 2 or metadata.get("codexHome") != str(run_home):
        raise ValueError("Run metadata does not identify this run home.")
    if metadata.get("configSha256") != digest(config_text):
        raise ValueError("Run config hash does not match its provider snapshot.")
    if metadata.get("authSha256") != digest(auth):
        raise ValueError("Run auth hash does not match its provider snapshot.")
    provider_name = config.get("model_provider")
    provider = config.get("model_providers", {}).get(provider_name, {})
    validate_provider_fields(metadata, auth, config, provider)
    return config


def validate_provider_fields(metadata: dict, auth: dict, config: dict, provider: dict) -> None:
    if not isinstance(metadata.get("providerId"), str) or not metadata["providerId"]:
        raise ValueError("Run metadata has no provider ID.")
    if auth.get("auth_mode") != "apikey" or not isinstance(auth.get("OPENAI_API_KEY"), str):
        raise ValueError("Run auth is not a valid apikey snapshot.")
    if not auth["OPENAI_API_KEY"]:
        raise ValueError("Run auth snapshot has no API key.")
    if config.get("model") != metadata.get("model") or not isinstance(config.get("model"), str):
        raise ValueError("Run model does not match its provider snapshot.")
    if provider.get("base_url") != metadata.get("baseUrl"):
        raise ValueError("Run URL does not match its provider snapshot.")
    validate_base_url(provider.get("base_url"))


def validate_base_url(base_url: object) -> None:
    if not isinstance(base_url, str) or not base_url:
        raise ValueError("Provider snapshot has no base URL.")
    parsed = urlsplit(base_url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise ValueError("Provider base URL must use HTTPS.")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Provider base URL contains unsupported credentials or suffixes.")


def models_url(base_url: str) -> str:
    parsed = urlsplit(base_url)
    path = parsed.path.rstrip("/") + "/models"
    return urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


def probe_status(url: str, api_key: str | None, timeout: float) -> ProbeResult:
    headers = {"Accept": "application/json"}
    if api_key is not None:
        headers["Authorization"] = "Bearer " + api_key
    request = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return ProbeResult(response.status)
    except urllib.error.HTTPError as error:
        try:
            return ProbeResult(error.code)
        finally:
            error.close()
    except (TimeoutError, urllib.error.URLError) as error:
        return ProbeResult(None, type(error).__name__)


def classify(authenticated: ProbeResult, unauthenticated: ProbeResult) -> tuple[str, str]:
    if authenticated.status is not None and 200 <= authenticated.status < 300:
        return "authenticated", "The provider accepted the run snapshot credentials."
    if authenticated.status == unauthenticated.status and authenticated.status in (401, 403):
        return (
            "entry_rejection_inconclusive",
            "Authenticated and unauthenticated requests received the same rejection; "
            "an entry gateway, WAF, or provider policy may be rejecting both, so a local key mismatch is not proven.",
        )
    if authenticated.status in (401, 403) and unauthenticated.status in (401, 403):
        return (
            "authenticated_request_rejected",
            "The authenticated request reached a different rejection path; the credential or provider account may be rejected, "
            "but the run snapshot binding remains intact.",
        )
    if authenticated.status is None:
        return "network_error", "The authenticated request did not receive an HTTP response."
    if authenticated.status >= 500:
        return "provider_error", "The provider returned a server-side error."
    return "http_rejection", "The provider rejected the authenticated request."


def diagnose(run_home: Path, allowed_root: Path, timeout: float, probe: Probe = probe_status) -> dict:
    snapshot = read_snapshot(run_home, allowed_root)
    endpoint = models_url(snapshot.base_url)
    unauthenticated = probe(endpoint, None, timeout)
    authenticated = probe(endpoint, snapshot.api_key, timeout)
    diagnosis, message = classify(authenticated, unauthenticated)
    return {
        "providerId": snapshot.provider_id,
        "model": snapshot.model,
        "baseHost": urlsplit(snapshot.base_url).hostname,
        "authenticatedStatus": authenticated.status,
        "authenticatedError": authenticated.error,
        "unauthenticatedStatus": unauthenticated.status,
        "unauthenticatedError": unauthenticated.error,
        "diagnosis": diagnosis,
        "message": message,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Diagnose one isolated Codex run provider without exposing its key.")
    parser.add_argument("--run-home", type=Path, required=True)
    parser.add_argument(
        "--allowed-run-homes-root",
        type=Path,
        default=Path.home() / ".prodex" / "manual-homes" / "ccswitch-runs",
    )
    parser.add_argument("--timeout", type=float, default=10.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.timeout <= 0 or args.timeout > 60:
        raise ValueError("Timeout must be greater than zero and at most 60 seconds.")
    report = diagnose(args.run_home, args.allowed_run_homes_root, args.timeout)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["diagnosis"] == "authenticated" else 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError, tomllib.TOMLDecodeError) as error:
        print(json.dumps({"diagnosis": "invalid_snapshot", "message": str(error)}, ensure_ascii=False))
        sys.exit(3)
