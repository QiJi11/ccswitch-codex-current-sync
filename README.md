# ccswitch-codex-current-sync

一个用于修复 **CC Switch 当前 Codex provider 与新 Codex 窗口启动配置不同步** 的小型 workaround。

## 问题

目标行为：

- 新开的 `codex` 窗口应读取 CC Switch 当前选中的 Codex provider。
- 已经打开的旧 Codex 窗口不应被后续 provider 切换热影响。
- 旧窗口退出后重新输入 `codex`，才应读取最新 provider。

实际可能出现的问题：

- CC Switch 已经切到 provider A。
- 新启动的 Codex profile home 里 `config.toml` / `auth.json` 仍停留在 provider B。
- 结果新窗口连到旧 `base_url` 或使用旧 auth。

本仓库提供的脚本会在启动 Codex 前，把 CC Switch 当前 Codex provider 的 `settings_config.config` 和 `settings_config.auth` 同步到目标 Codex home。

## 安全边界

- 不修改 CC Switch 数据库。
- 不删除历史、session、`state_*.sqlite` 或 `history.jsonl`。
- 不 kill `codex`、`node`、`pwsh` 等进程。
- 不输出 API key、token、Authorization、cookie。
- 仅当目标文件内容实际不同，才备份并重写。

## 使用方法

PowerShell:

```powershell
.\scripts\sync-ccswitch-current-codex.ps1 `
  -CodexHome "$env:USERPROFILE\.prodex\manual-homes\ccswitch-current"
```

如果你使用默认 Codex home，也可以指定：

```powershell
.\scripts\sync-ccswitch-current-codex.ps1 `
  -CodexHome "$env:USERPROFILE\.codex"
```

仅检查、不写入：

```powershell
.\scripts\sync-ccswitch-current-codex.ps1 `
  -CodexHome "$env:USERPROFILE\.prodex\manual-homes\ccswitch-current" `
  -CheckOnly
```

## 接入启动 wrapper

在你的 `codex` wrapper 调用真正的 Codex / Prodex 前加入：

```powershell
& "C:\path\to\ccswitch-codex-current-sync\scripts\sync-ccswitch-current-codex.ps1" `
  -CodexHome "$env:USERPROFILE\.prodex\manual-homes\ccswitch-current" `
  -Quiet
```

然后再启动：

```powershell
prodex run --profile ccswitch-current --no-auto-rotate --full-access
```

## 验证

```powershell
prodex run --profile ccswitch-current --no-auto-rotate --dry-run
Select-String -LiteralPath "$env:USERPROFILE\.prodex\manual-homes\ccswitch-current\config.toml" -Pattern 'base_url'
```

预期：

- `CODEX_HOME` 指向你的目标 home。
- `config.toml` 的 `base_url` 与 CC Switch 当前 Codex provider 的 `settings_config.config` 一致。
- 第二次运行脚本时显示 `config.toml unchanged` / `auth.json unchanged`，不会重复生成备份。

## English summary

This repository contains a small PowerShell workaround for syncing the currently selected CC Switch Codex provider into a target Codex home before launching a new Codex window. It copies only `settings_config.config` and `settings_config.auth` from the current Codex provider, backs up changed files, does not touch CC Switch DB state, and does not affect already running Codex windows.

## 上游状态

- 相关 issue：<https://github.com/farion1231/cc-switch/issues/4944>
- Draft PR：<https://github.com/farion1231/cc-switch/pull/5013>
