# ccswitch-codex-current-sync

这个仓库为 CC Switch 与 Codex 提供按启动事件隔离的 provider 快照，并在 Codex 正常结束时持久化本次运行选择的模型。推荐路径不依赖常驻 watcher，也不对已经运行的 Codex 做热切换。

## 目标行为

- 在 CC Switch UI 选择 provider A 后执行 `codex`，新进程获得 A 的独立 `CODEX_HOME` 快照和私有 Prodex runtime。
- 之后在 UI 切换到 provider B，已经运行的 A 仍使用自己的快照；再次执行 `codex` 才会采用 B。
- 因此两个终端可以分别保持 provider A 和 provider B，互不改写对方正在使用的 home。
- 在 Codex 内通过 `/model` 修改模型后，正常退出或按 `Ctrl+C` 返回 launcher 时，模型和 reasoning effort 会写回启动该进程的 provider，而不是退出时 UI 当前选中的 provider。

不支持运行中热切换。要采用 UI 新选择的 provider，需要结束当前 Codex 后重新执行 `codex`。

## 事件流程

### 启动

`scripts/invoke-ccswitch-codex.ps1` 每次运行时调用 `scripts/materialize-ccswitch-codex-run.ps1`：

1. 对照 `~\.cc-switch\settings.json` 的 `currentProviderCodex` 与 `~\.cc-switch\cc-switch.db` 的当前 Codex provider。
2. 从同一份稳定的数据库快照读取 provider 配置、认证信息和 endpoint；切换状态短暂不一致时会重试，无法取得一致状态则停止启动。
3. 在 `~\.prodex\manual-homes\ccswitch-runs\ccswitch-run-*` 下发布新的 run home，写入 `config.toml`、`auth.json` 和 `run-provider.json`，并创建 `<run home>\.prodex-runtime`。
4. 临时将 `PRODEX_HOME` 指向该 run 的 `.prodex-runtime`，通过官方 `prodex profile add <profile> --codex-home <run home>` 注册唯一 profile。
5. launcher 再以同一个私有 `PRODEX_HOME` 执行 `prodex run --profile <profile> --no-auto-rotate --full-access`。启动链不读取或改写全局 `~\.prodex\state.json`。

`run-provider.json` 保存 provider 身份、启动时的模型基线和配置摘要，不保存明文密钥。后续 UI 切换不会重写已经发布的 run home。

### 退出

launcher 在 Prodex 返回时记录 UTC ticks，并在退出处理中调用 `scripts/persist-run-model.ps1 -RunHome <本次 run home> -ExitOrder <ticks>`：

- 仅回写 run home 中相对 `run-provider.json` 启动基线发生变化的 `model` 或 `model_reasoning_effort`；未变化的字段保留 provider 当时的值。没有修改模型的旧窗口会跳过，不会把 provider 回滚到旧值。
- provider 由本次 run metadata 确定。即使 A 退出时 UI 已切到 B，也只更新 A，不会更新 B。
- 同一 provider 的已修改窗口使用内部字段 `_ccswitchCodexModelExitOrder` 保存 launcher 观察到的退出时间。数据库中已有更大的退出序号时，较旧写回返回 `superseded`，不会覆盖较晚退出窗口的选择。
- persistence 通过按 `CcSwitchRoot` 哈希命名的短生命周期 mutex 串行执行；持锁范围覆盖 online backup 和 SQLite 写事务，避免已进入 persistence 的多个进程发生 backup/commit 反序。
- 更新数据库前创建 online backup，并在事务内再次检查退出序号、更新和回读验证。只有该 provider 仍同时是 `settings.json` 与数据库中的当前 provider 时，才尝试同步共享 mirror。
- 回写失败不会篡改 Codex 原退出码；launcher 会发出 warning，并写入 `~\.prodex\logs\ccswitch-event-launcher.log`。

正常退出，以及通过 `Ctrl+C` 结束 Codex 并返回 launcher 时，会进入退出处理。任务管理器强杀、`Stop-Process -Force`、终端宿主崩溃、断电等情况可能来不及回写本次模型选择。

退出序号是 launcher 在恢复执行后读取的 UTC ticks。极端 OS 调度下，较早结束的 Codex 子进程如果其 launcher 长时间未获调度，记录时间可能晚于另一个实际更晚结束的子进程；本方案不承诺这种情况下的内核级严格墙钟顺序。

## 入口范围

安装器通过 PowerShell profile 和用户 `PATH` 两条入口接管 `codex`：

| 入口 | 接入方式 |
| --- | --- |
| PowerShell 7 | `Documents\PowerShell\Microsoft.PowerShell_profile.ps1` 中的受管 `codex` 函数 |
| Windows PowerShell 5.1 | `Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` 中的受管 `codex` 函数 |
| `pwsh -NoProfile`、`powershell -NoProfile` | `~\.prodex\shims\codex.ps1` / `codex.cmd` |
| CMD、Windows Terminal 中的 CMD | `~\.prodex\shims\codex.cmd` |
| Git Bash | `~\.prodex\shims\codex` |

安装器把 `~\.prodex\shims` 放到用户 `PATH` 中 npm 目录之前，不修改 `%APPDATA%\npm` 下的原始 Codex/Prodex shim。安装后必须打开新终端，旧进程不会自动刷新自己的 `PATH`。

以下入口不在覆盖范围：WSL、IDE 内置且自行指定的 Codex launcher，以及显式调用 Codex/Prodex 绝对路径。Windows Terminal 是终端宿主；其中使用上表所列 shell 时才属于覆盖范围。

## 前置条件

- Windows 上已配置 CC Switch Codex provider，并存在 `~\.cc-switch\settings.json` 与 `~\.cc-switch\cc-switch.db`。
- `prodex.ps1` 可从 `%APPDATA%\npm` 使用。
- `~\.codex\bin\codex-focusfixed-current.txt` 指向同目录下存在的 `.exe`。
- PowerShell 7 或 Windows PowerShell 5.1 可用。
- `python` 命令指向 Python 3.11 或更高版本；快照校验和模型回写会调用它。

本方案按 CC Switch 3.16.5 的实际接口实现。该版本没有可供本方案调用的外部 `postSwitchCommand`，因此不能依靠 UI 切换后的外部 hook；provider 选择在下一次 `codex` 启动时读取。

## 安装

在仓库根目录先预览，不写文件、不改 profile、`PATH` 或计划任务：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-event-launcher.ps1 -DryRun
```

只有 Windows PowerShell 5.1 时，可将示例中的 `pwsh` 替换为 `powershell.exe`。

确认输出后执行安装：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-event-launcher.ps1
```

`scripts/install-event-launcher.ps1` 会：

- 将 `invoke-ccswitch-codex.ps1`、`materialize-ccswitch-codex-run.ps1`、`persist-run-model.ps1` 和 `sync-ccswitch-current-codex.ps1` 部署到 `~\.prodex\bin`。
- 将 `codex.ps1`、`codex.cmd` 和无扩展名的 `codex` 部署到 `~\.prodex\shims`。
- 备份有变化的 PowerShell profile，再维护带明确 marker 的 `codex` 函数。
- 将 shim 目录插到用户 `PATH` 的 npm 目录之前。
- 在 Windows `ScheduledTasks` 模块可用时，仅以 `ccswitch-codex-current-watcher` 和 `ccswitch-codex-current-watcher-user` 两个项目计划任务为注销目标；模块不可用时只输出 warning。若 Windows 因任务 ACL 拒绝删除，安装器只会在复查确认该任务仍为 `Disabled` 后告警继续；启用状态或其他注销错误仍会中止安装。

安装器不会查询、停止或删除名为 `CCSwitchMonitor` 的其他任务。仓库中的 watcher 脚本仅为迁移和历史诊断保留，不属于最终运行链，也不会由 event launcher 安装器注册或启动。

## 验证

先打开一个新终端检查常规 PowerShell 与无 profile 入口。launcher 在物化前会把可能继承的 run-scoped `PRODEX_HOME` 恢复为用户级 `~\.prodex`，因此从 Codex 子进程再次调用入口也会创建新的独立 run；新终端仍是最直观的人工验收环境：

```powershell
Get-Command codex -All | Select-Object CommandType, Name, Source, Definition
where.exe codex

pwsh -NoProfile -Command "Get-Command codex -All | Select-Object -First 1 CommandType,Source,Definition"
powershell.exe -NoProfile -Command "Get-Command codex -All | Select-Object -First 1 CommandType,Source,Definition"
```

仓库级回归使用隔离 fixture，不读取真实 provider 凭据，也不发送模型请求：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\integration.ps1
git diff --check
```

常规 PowerShell 应优先解析到 profile 中的 `codex` 函数；`where.exe` 和无 profile PowerShell 应能看到 `~\.prodex\shims` 中的入口，而且该目录应排在 `%APPDATA%\npm` 之前。CMD 可运行 `where codex`，Git Bash 可运行 `type -a codex` 做同样检查。

以下命令只检查版本，不发送模型请求，同时会完整经过一次“启动快照 -> Codex 退出 -> 模型回写检查”流程：

```powershell
codex --version
```

检查最近一次 run metadata 和私有 Prodex home；不要输出 `auth.json`：

```powershell
$run = Get-ChildItem "$env:USERPROFILE\.prodex\manual-homes\ccswitch-runs" -Directory |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

Get-Content -Raw -LiteralPath (Join-Path $run.FullName 'run-provider.json') |
  ConvertFrom-Json |
  Select-Object profileName, codexHome, prodexHome, providerName, providerId, model, modelReasoningEffort, materializedAt
```

`prodexHome` 应等于 `<codexHome>\.prodex-runtime`，其 `state.json` 只包含本次 run 的 profile。若全局 `~\.prodex\state.json` 已存在，需要验证它未被启动链改写时，可在执行 `codex --version` 前后分别运行 `Get-FileHash "$env:USERPROFILE\.prodex\state.json"` 并比较 SHA-256。

在 `Get-ScheduledTask` 可用时检查两个项目 watcher。正常情况下没有输出；ACL 保护的旧任务可能保留，但必须是 `Disabled`：

```powershell
@('ccswitch-codex-current-watcher', 'ccswitch-codex-current-watcher-user') |
  ForEach-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue } |
  Select-Object TaskName, State
```

## 卸载入口接管

先预览卸载动作：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-event-launcher.ps1 -Uninstall -DryRun
```

再执行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-event-launcher.ps1 -Uninstall
```

卸载会删除三个 shim、两个 profile 中的受管 block 和用户 `PATH` 中的 shim 目录项，并再次尝试注销上述两个项目 watcher。它不会删除 `~\.prodex\bin` 中已部署的脚本、历史 run home、Codex session、CC Switch provider 数据或 `CCSwitchMonitor`。

## 非运行链工具

- `scripts/sync-ccswitch-current-codex.ps1`：手动修复共享 `ccswitch-current` home 漂移。
- `scripts/watch-ccswitch-sync.ps1` 与 `scripts/install-watcher-task.ps1`：旧的后台 watcher 实现，仅为迁移和历史诊断保留；最终架构不安装或启动它们。
- `scripts/switch-codex-provider.ps1`：旧的显式切换路径，不是 UI 自动隔离的推荐入口。

最终运行链始终是启动事件创建独立 Codex/Prodex 快照，并在正常退出事件中按 run metadata 和退出序号回写模型；不使用后台 watcher。
