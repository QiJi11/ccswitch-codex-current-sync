# ccswitch-codex-current-sync

这个仓库最初用于修复 `ccswitch-current` home 漂移问题。当前推荐方案已经调整为：

每次启动新的 `codex` 窗口前，读取 CC Switch 当前选中的 Codex provider，把它的 `settings_config.config` 和 `settings_config.auth` 物化到一个新的独立 Codex home，然后让 Prodex 用这个 home 启动。

这样可以得到两个效果：

- 新开的 `codex` 窗口总是使用启动那一刻 CC Switch 当前选中的 Codex provider。
- 已经打开的旧窗口继续使用自己的 run home，不会被后续 CC Switch 切换热影响。

## 工作方式

`scripts/materialize-ccswitch-codex-run.ps1` 会：

- 从 `~\.cc-switch\settings.json` 读取 `currentProviderCodex`。
- 只读查询 `~\.cc-switch\cc-switch.db` 里的 `providers` / `provider_endpoints`。
- 从当前 provider 的 `settings_config.config` 和 `settings_config.auth` 写出新的启动快照。
- 创建新的 home：`~\.prodex\manual-homes\ccswitch-runs\ccswitch-run-*`。
- 写入 `config.toml`、`auth.json` 和不含密钥的 `run-provider.json`。
- 在写入新的 Prodex profile 前备份 `~\.prodex\state.json`。

## 安全边界

- 不修改 CC Switch 数据库。
- 不修改 CC Switch 当前 provider。
- 不复用或覆盖旧窗口正在使用的 run home。
- 不删除历史、session、`state_*.sqlite` 或 `history.jsonl`。
- 不 kill `codex`、`node`、`pwsh` 等进程。
- 不输出 API key、token、Authorization、cookie。

## 安装

PowerShell:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.prodex\bin" | Out-Null
Copy-Item .\scripts\materialize-ccswitch-codex-run.ps1 `
  "$env:USERPROFILE\.prodex\bin\materialize-ccswitch-codex-run.ps1" `
  -Force
```

## 接入启动 wrapper

在 `codex` wrapper 调用 `prodex run` 前先生成本次启动的 provider 快照：

```powershell
function codex {
  $snapshot = (& "$env:USERPROFILE\.prodex\bin\materialize-ccswitch-codex-run.ps1" -Quiet |
    Select-Object -Last 1 |
    ConvertFrom-Json)

  & "$env:APPDATA\npm\prodex.ps1" run `
    --profile ([string]$snapshot.profileName) `
    --no-auto-rotate `
    --full-access `
    @args
}
```

如果你的 wrapper 里还有 `PRODEX_CODEX_BIN` 固定、默认 `--cd`、focus reporting 等逻辑，可以保留；关键点是 `prodex run --profile` 使用 `$snapshot.profileName`，而不是固定的 `ccswitch-current`。

## 验证

```powershell
. "$PROFILE"
codex --dry-run
```

预期：

- dry-run 退出码为 0。
- 输出里的 `CODEX_HOME` 指向 `~\.prodex\manual-homes\ccswitch-runs\ccswitch-run-*`。
- 对应 home 里的 `config.toml` 的 `base_url` 与 CC Switch 当前 Codex provider 的 `settings_config.config` 一致。

可以检查本次 run home：

```powershell
$runHome = "$env:USERPROFILE\.prodex\manual-homes\ccswitch-runs\<ccswitch-run-name>"
Select-String -LiteralPath "$runHome\config.toml" -Pattern '^\s*base_url\s*='
Get-Content -Raw -LiteralPath "$runHome\run-provider.json" |
  ConvertFrom-Json |
  Select-Object providerName, providerId, baseUrl, configSha256, authSha256
```

## 为什么旧窗口不会被热切换影响

每次启动都会创建一个新的 run home，并把启动时的 provider 配置写入这个 home。启动后的 Codex 进程拿到的是自己的 `CODEX_HOME` 环境变量，指向这个独立目录。

后续 CC Switch 切换只会影响下一次 materialize 的输入，不会重写已经存在的 run home，所以旧窗口继续使用它启动时的 provider 快照。

## Legacy: 同步 ccswitch-current

`scripts/sync-ccswitch-current-codex.ps1` 仍保留，用于手动把当前 CC Switch Codex provider 同步到一个指定 Codex home，例如 `ccswitch-current`。

这个旧脚本适合修正 home 漂移，但它复用同一个目标 home，不是“不同窗口保持不同 provider”的推荐方案。

## 上游状态

此前错误方向的 PR `farion1231/cc-switch#5013` 已关闭。当前问题本质是启动 wrapper 的“每窗口 provider 快照隔离”，不是修改 CC Switch provider 切换时的全局 auth 同步逻辑。

## English summary

The recommended workaround is to materialize the currently selected CC Switch Codex provider into a new per-launch Codex home before calling `prodex run`. Each Codex window receives its own `CODEX_HOME`, so later provider switches only affect future launches and do not rewrite homes used by already running windows.
