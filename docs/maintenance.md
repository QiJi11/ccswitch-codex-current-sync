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
- 第三方 provider 是否有迁移前的 API key/bearer，或迁移后的命令认证。
- 活动 provider 是否有 HTTPS 或本机回环 endpoint。
- `wire_api` 是否为 `responses`。
- 第三方 provider 是否仍要求 OpenAI 登录。
- 官方 provider 是否保存了可用登录材料。

审计通过只证明配置结构和认证配对一致，不证明上游余额、key 有效期或网络可达。

## DPAPI 凭据迁移

`scripts/invoke-ccswitch-credential-migration.ps1` 默认只读。它检查全部第三方 Codex provider、全局自定义 provider 和带 metadata 的历史 run；输出只包含数量、provider 身份和风险，不输出令牌或完整摘要。JSON 中的 `commandBackedProviderCount` 和 `globalCommandBackedProviderCount` 分别表示数据库第三方 provider、全局自定义 provider 已使用规范认证 helper 的数量。

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-ccswitch-credential-migration.ps1 -Json
```

应用前必须完全退出 CC Switch。`-Apply` 会持有专用互斥锁，并按以下顺序执行：

- 检查 `auth.OPENAI_API_KEY` 与配置 bearer；两处不一致时停止，不选择其中一个。
- 按 provider ID 使用 Windows DPAPI `CurrentUser` 加密令牌。
- 把 vault ACL 和 owner 限制为当前用户、SYSTEM 和 Administrators，并在只读审计和清理前复核整个 vault/rollback 树。
- 在任何迁移写入前创建并验证 DPAPI 加密的完整 SQLite 回滚包；先更新可补偿的文件，最后提交数据库事务。
- 从第三方 provider、全局自定义 provider、current 和历史 run 中移除明文认证，改用命令认证 helper。
- 把第三方 `auth.json` 缩减为 `{}`；官方 OpenAI/ChatGPT 登录记录保持不变，生成 run 时也不会注入 DPAPI helper。
- 对安全文本候选执行已知 provider 令牌的等长精确替换；候选包括已知文本后缀、`config.toml.bak-*`、`auth.json.bak-*` 和无扩展名文件。结束审计会扫描受管理根中的全部普通文件，并要求已知令牌剩余数量为 0；目录枚举、读取或 reparse point 检查失败时停止。
- 任一文件更新、数据库提交或迁移后审计失败时，执行补偿恢复迁移前文件；数据库已经提交时同时从加密回滚包恢复。补偿本身失败会明确报错，不会把半迁移状态报告为成功。

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-ccswitch-credential-migration.ps1 -Apply -Json
```

JSON 结果中的 `rollbackPath` 指向加密回滚包。需要恢复时先关闭 CC Switch，再明确指定该路径：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore-ccswitch-credential-rollback.ps1 `
    -RollbackRoot '<ROLLBACK_PATH>' `
    -Confirm:$false `
    -Json
```

恢复只还原 CC Switch SQLite 数据库，并先清除旧的 `-wal`/`-shm` sidecar，避免旧事务重放；它不会恢复已经清理的旧备份，也不会撤销远程平台上的 key。回滚包必须位于受保护的 credential vault 内。迁移完成后仍需到每个第三方 provider 后台轮换已暴露的 key。

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

先使用 `-CheckOnly`。省略该参数会原子更新 `config.toml`、`auth.json` 和受管理耐久文件；current 的 `agents`、`skills` 使用指向全局目录的 junction，旧的受管理副本会被移除。该命令不创建新的明文 config/auth 备份。

## 旧数据清理

`scripts/remove-stale-ccswitch-data.ps1` 默认只预览超过一天且名称匹配已知模式的 CC Switch 旧备份、current 的旧 config/auth 副本和超过一天的孤立 staging：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\remove-stale-ccswitch-data.ps1 -Json
```

只有 DPAPI 迁移审计无 issue、已知令牌剩余数为 0、全部第三方 provider 都使用命令认证且 vault ACL 仍合格时，`-Apply` 才允许删除。它不枚举为候选、也不删除任何 `ccswitch-run-*`：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\remove-stale-ccswitch-data.ps1 `
    -Apply `
    -Confirm:$false `
    -Json
```

CC Switch 备份文件只匹配 `cc-switch.db.bak-*`、`db_backup_*.db`、`settings.json.bak-*`；备份目录只匹配 `browser-acceptance-*`、`ccswitch-*`、`codex-*`、`portable-handoff-*`。未知目录和一天内的新备份会保留。任何候选只要包含 `sessions`、`history.jsonl` 或 `state_*.sqlite*` 就会阻断清理。历史 run 仍单独使用 30 天 retention 预览。

## 旧 watcher 与显式切换

以下脚本为迁移和历史诊断保留，不属于推荐运行链：

- `scripts/watch-ccswitch-sync.ps1`
- `scripts/install-watcher-task.ps1`
- `scripts/launch-watcher-hidden.ps1`
- `scripts/switch-codex-provider.ps1`

event launcher 不安装或启动旧的全局 provider watcher。新会话通过启动时物化读取 provider；每个 run 的模型监测器由 event launcher 独立启动，不要同时启用旧 watcher 和 event launcher。
