# TODO

## Done

- Implemented per-launch Codex provider snapshots with `scripts/materialize-ccswitch-codex-run.ps1`.
- Updated the local `codex` wrapper to call the materialize script before `prodex run`.
- Verified `codex --dry-run` uses a per-launch `ccswitch-runs\ccswitch-run-*` home.
- Verified the generated `config.toml` `base_url` matches the current CC Switch Codex provider.
- Closed the wrong upstream PR direction: `farion1231/cc-switch#5013`.

## Keep

- Keep `scripts/sync-ccswitch-current-codex.ps1` only as a legacy/manual repair tool for `ccswitch-current` drift.
- Keep the recommended launch path on per-window snapshots, not shared `ccswitch-current`.

## Not Planned

- Do not modify the CC Switch database from this workaround.
- Do not make CC Switch provider switching rewrite homes already used by running Codex windows.
- Do not globally kill Codex, node, or PowerShell processes.
- Do not delete Codex history, sessions, `state_*.sqlite`, or `history.jsonl`.

## Future Cleanup

- Optionally add retention cleanup for old `ccswitch-runs\ccswitch-run-*` homes after confirming they are no longer needed.
- Optionally add an install script that copies the materialize script into `~\.prodex\bin` and patches a user-selected wrapper.
