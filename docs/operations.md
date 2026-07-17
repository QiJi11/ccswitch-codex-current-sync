# 运行与安装

## 前置条件

- Windows。
- CC Switch 已配置至少一个 Codex provider。
- CC Switch 数据根包含 `settings.json` 和 `cc-switch.db`。
- PowerShell 7 或 Windows PowerShell 5.1。
- `python` 指向 Python 3.11 或更高版本。
- `%USERPROFILE%\.codex\bin\codex-focusfixed-current.txt` 指向存在的 Codex 可执行文件。

默认 direct 模式不要求 Prodex。只有使用 `CCSWITCH_CODEX_LAUNCH_MODE=prodex` 回滚模式时，才要求 `prodex.ps1` 可从 npm 用户目录调用。

## 安装

先预览，不写 profile、PATH 或计划任务：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-event-launcher.ps1 -DryRun
```

确认后安装：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-event-launcher.ps1
```

安装器会：

- 把运行链脚本部署到 `%USERPROFILE%\.prodex\bin`。
- 把 PowerShell、CMD 和 Git Bash shim 部署到 `%USERPROFILE%\.prodex\shims`。
- 备份发生变化的 PowerShell profile，再维护带 marker 的 `codex` 函数。
- 把 shim 目录放到用户 PATH 中 npm 目录之前。
- 尝试注销项目旧 watcher 任务；无法删除但已禁用的 ACL 保护任务只告警。

安装后必须打开新终端，旧进程不会自动刷新 PATH。

## 验收

### 入口解析

```powershell
Get-Command codex -All | Select-Object CommandType, Name, Source, Definition
where.exe codex

pwsh -NoProfile -Command "Get-Command codex -All | Select-Object -First 1 CommandType,Source,Definition"
powershell.exe -NoProfile -Command "Get-Command codex -All | Select-Object -First 1 CommandType,Source,Definition"
```

常规 PowerShell 应优先解析到 profile 中的 `codex` 函数。无 profile PowerShell 和 `where.exe` 应看到 `%USERPROFILE%\.prodex\shims`，且它位于 npm shim 之前。

### 无状态诊断

```powershell
codex --version
```

该命令不创建 run home、不启动 Prodex，也不执行模型写回。

### 更新提示

普通交互启动最多每 6 小时从 npm registry 检查一次 `@openai/codex` 的稳定版，并缓存结果到 `%USERPROFILE%\.codex\codex-update-check.json`。发现新版本时显示提示，但不会自动安装。

`exec`、`review` 等机器输出命令不执行该检查，避免污染 JSON 或脚本输出。手动只读检查：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\bin\check-codex-update.ps1" -Json
```

升级前应审计精确版本并保留当前 focus-fixed 指针；不要直接运行 `npm update`。

### Run metadata

```powershell
$runHomes = Join-Path $env:USERPROFILE '.prodex\manual-homes\ccswitch-runs'
$run = Get-ChildItem -LiteralPath $runHomes -Directory |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
$metadataPath = Join-Path $run.FullName 'run-provider.json'

Get-Content -Raw -LiteralPath $metadataPath |
    ConvertFrom-Json |
    Select-Object launchMode, profileName, codexHome, prodexHome,
        providerName, providerId, model, modelReasoningEffort, materializedAt
```

不要为验收输出 `auth.json`。direct 模式下 `.prodex-runtime` 没有 `state.json`；显式 Prodex 模式只在该私有目录保存本次 run 的 profile。

### 仓库测试

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\integration.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\retention.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\provider-config-migration.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-update-check.ps1
python -m py_compile .\scripts\audit-codex-provider-auth.py .\scripts\normalize-ccswitch-codex-auth.py
git diff --check
```

## 临时回退到 Prodex

```powershell
$env:CCSWITCH_CODEX_LAUNCH_MODE = 'prodex'
codex
```

关闭当前终端或删除该进程环境变量即可恢复 direct 模式：

```powershell
Remove-Item -LiteralPath Env:CCSWITCH_CODEX_LAUNCH_MODE
```

## 卸载入口接管

先预览：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-event-launcher.ps1 -Uninstall -DryRun
```

再执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-event-launcher.ps1 -Uninstall
```

卸载会删除三个 shim、两个 profile 中的受管 block 和用户 PATH 中的 shim 项，并尝试注销两个项目 watcher。它不会删除历史 run home、Codex session、CC Switch provider 数据或已部署的 bin 脚本。

## 常见失败

- CC Switch settings 与数据库当前 provider 不一致：等待 UI 切换完成后重新启动，不要直接覆盖数据库。
- 固定 Codex 路径不存在：修复 `codex-focusfixed-current.txt` 指向后再运行。
- Python 版本过低：安装 Python 3.11 或更高版本，并确认 `python --version`。
- 旧 watcher 任务仍存在：只要任务为 `Disabled` 且没有 watcher 进程，event launcher 不依赖它。
