# 维护工具

维护工具默认遵循“先只读或预览，再显式应用”。任何会写 CC Switch 数据库的操作都应先关闭 CC Switch，并保留脚本创建的备份。

## 认证审计

`scripts/audit-codex-provider-auth.py` 只读打开 SQLite，不输出 API key 或 token，只输出存在性、摘要哈希和兼容性问题：

```powershell
$ccSwitchRoot = Join-Path $env:USERPROFILE '.cc-switch'
$databasePath = Join-Path $ccSwitchRoot 'cc-switch.db'

python .\scripts\audit-codex-provider-auth.py $databasePath
```

审计检查：

- provider settings JSON 和 config TOML 是否可解析。
- 第三方 provider 是否有 API key 或 bearer token。
- 活动 provider 是否有 HTTPS 或本机回环 endpoint。
- `wire_api` 是否为 `responses`。
- 第三方 provider 是否仍要求 OpenAI 登录。
- 官方 provider 是否保存了可用登录材料。

审计通过只证明配置结构和认证配对一致，不证明上游余额、key 有效期或网络可达。

## 认证规范化

`scripts/normalize-ccswitch-codex-auth.py` 会：

- 为第三方 provider 设置 `auth_mode=apikey`。
- 移除第三方 provider 中残留的 ChatGPT token。
- 把 provider API key 写入活动 provider 的 `experimental_bearer_token`。
- 设置 `requires_openai_auth=false`。
- 把官方 provider 的 auth 更新为当前 Codex ChatGPT 登录快照。
- 写入前创建 SQLite online backup、settings 备份、Codex auth 备份和 manifest。
- 在单个事务中更新 provider，并用原始 settings 文本做并发变更保护。

脚本要求 `preserveCodexOfficialAuthOnSwitch=true`，且当前 Codex `auth.json` 是带 access token 的 ChatGPT 登录。

先 dry-run：

```powershell
$ccSwitchRoot = Join-Path $env:USERPROFILE '.cc-switch'
$codexHome = Join-Path $env:USERPROFILE '.codex'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $codexHome "backups\ccswitch-auth-normalize-$stamp"
$arguments = @(
    '.\scripts\normalize-ccswitch-codex-auth.py',
    '--ccswitch-root', $ccSwitchRoot,
    '--codex-home', $codexHome,
    '--backup-root', $backupRoot
)

python @arguments
```

确认 dry-run 的 provider 数量和变更范围后，在 CC Switch 已关闭时增加 `--apply`：

```powershell
$arguments += '--apply'
python @arguments
```

执行后重新运行认证审计。回滚时关闭 CC Switch，再使用 manifest 对应的 `cc-switch.db` 备份恢复；不要在 CC Switch 持有数据库时替换文件。

## Run home 保留

`scripts/invoke-run-home-retention.ps1` 默认只预览，默认最小年龄为 30 天：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-run-home-retention.ps1
```

它会保留包含 session、`history.jsonl`、`state_*.sqlite*`、reparse point 或活跃进程引用的目录。枚举或稳定 File ID 核验失败时停止。

只有检查预览结果后才使用：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-run-home-retention.ps1 -Apply
```

## Provider 配置迁移预检

`scripts/get-ccswitch-provider-config-migration.ps1` 只读检查旧审批键和已移除的 `features.js_repl`：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\get-ccswitch-provider-config-migration.ps1 -Json
```

该工具没有写入模式。需要修改 provider 源配置时，应在 CC Switch 关闭后通过应用 UI 或经过单独验证的迁移流程处理。

## 共享 mirror 修复

`scripts/sync-ccswitch-current-codex.ps1` 用于手动修复共享 `ccswitch-current` home 漂移，不属于日常启动链：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-ccswitch-current-codex.ps1 -CheckOnly
```

先使用 `-CheckOnly`。省略该参数会写目标 Codex home，并为变化文件创建备份。

## 旧 watcher 与显式切换

以下脚本为迁移和历史诊断保留，不属于推荐运行链：

- `scripts/watch-ccswitch-sync.ps1`
- `scripts/install-watcher-task.ps1`
- `scripts/launch-watcher-hidden.ps1`
- `scripts/switch-codex-provider.ps1`

event launcher 不安装或启动 watcher。新会话通过启动时物化读取 provider；不要同时启用旧 watcher 和 event launcher。
