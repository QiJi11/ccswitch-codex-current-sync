# ccswitch-codex-current-sync

这个仓库为 CC Switch 与 Codex 提供按启动事件隔离的 provider 快照，并在 Codex 正常结束时持久化本次运行选择的模型。推荐路径不依赖常驻 watcher，也不对已经运行的 Codex 做热切换。

## 目标行为

- 在 CC Switch UI 选择 provider A 后执行 `codex`，新进程获得 A 的独立 `CODEX_HOME` 快照，并默认直接启动 focus-fixed Codex。
- 之后在 UI 切换到 provider B，已经运行的 A 仍使用自己的快照；再次执行 `codex` 才会采用 B。
- 因此两个终端可以分别保持 provider A 和 provider B，互不改写对方正在使用的 home。
- 在 Codex 内通过 `/model` 修改模型后，正常退出或按 `Ctrl+C` 返回 launcher 时，模型和 reasoning effort 会写回启动该进程的 provider，而不是退出时 UI 当前选中的 provider。

不支持运行中热切换。要采用 UI 新选择的 provider，需要结束当前 Codex 后重新执行 `codex`。

## 事件流程

### 启动

普通新会话由 `scripts/invoke-ccswitch-codex.ps1` 调用 `scripts/materialize-ccswitch-codex-run.ps1`；`resume` 会复用 session 所属的原 run home，单参数根级 `--version`、`-V`、`--help`、`-h` 则走无状态 fast path：

1. 对照 `~\.cc-switch\settings.json` 的 `currentProviderCodex` 与 `~\.cc-switch\cc-switch.db` 的当前 Codex provider。
2. 从同一份稳定的数据库快照读取 provider 配置、认证信息和 endpoint；切换状态短暂不一致时会重试，无法取得一致状态则停止启动。
3. 在 `~\.prodex\manual-homes\ccswitch-runs\ccswitch-run-*` 下发布新的 run home，写入 `config.toml`、`auth.json` 和 `run-provider.json`，并创建用于兼容模型持久化的空 `<run home>\.prodex-runtime`。
4. 默认 `direct` 模式设置 `CODEX_HOME=<run home>`，清除 `PRODEX_CODEX_BIN`、`PRODEX_HOME` 和可能串号的 `OPENAI_API_KEY`、`OPENAI_BASE_URL`、`OPENAI_API_BASE`，再直接执行 focus-fixed Codex；不会注册或启动 Prodex。
5. 仅当进程环境显式设置 `CCSWITCH_CODEX_LAUNCH_MODE=prodex` 时，才在私有 `.prodex-runtime` 中注册唯一 profile 并执行原有 `prodex run --profile ... --full-access` 回滚链。两种模式都不读取或改写全局 `~\.prodex\state.json`。

`run-provider.json` 保存 provider 身份、启动时的模型基线和配置摘要，不保存明文密钥。后续 UI 切换不会重写已经发布的 run home。

四个单参数根级诊断请求直接调用 `~\.codex\bin\codex-focusfixed-current.txt` 指向的 Codex 可执行文件，不启动 Prodex、不创建 run home，也不执行模型回写。诊断 flag 与任何其他参数组合时仍走完整启动链。

### 退出

launcher 在 Codex（或显式回滚时的 Prodex）返回后记录 UTC ticks，并在退出处理中调用 `scripts/persist-run-model.ps1 -RunHome <本次 run home> -ExitOrder <ticks>`：

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
- 默认 direct 模式不要求 Prodex；如需使用 `CCSWITCH_CODEX_LAUNCH_MODE=prodex` 回滚，`prodex.ps1` 必须可从 `%APPDATA%\npm` 使用。
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
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\retention.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\provider-config-migration.ps1
git diff --check
```

常规 PowerShell 应优先解析到 profile 中的 `codex` 函数；`where.exe` 和无 profile PowerShell 应能看到 `~\.prodex\shims` 中的入口，而且该目录应排在 `%APPDATA%\npm` 之前。CMD 可运行 `where codex`，Git Bash 可运行 `type -a codex` 做同样检查。

以下命令只检查当前固定 Codex 可执行文件的版本，不发送模型请求，也不创建 run home：

```powershell
codex --version
```

该 fast path 也不会显示 Prodex 自身的更新横幅；使用 `prodex info` 查看 Prodex 当前版本与可用更新。

常规交互或 `exec` 运行结束后，可检查最近一次 run metadata；不要输出 `auth.json`：

```powershell
$run = Get-ChildItem "$env:USERPROFILE\.prodex\manual-homes\ccswitch-runs" -Directory |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

Get-Content -Raw -LiteralPath (Join-Path $run.FullName 'run-provider.json') |
  ConvertFrom-Json |
  Select-Object launchMode, profileName, codexHome, prodexHome, providerName, providerId, model, modelReasoningEffort, materializedAt
```

`prodexHome` 应等于 `<codexHome>\.prodex-runtime`。direct 模式下该目录没有 `state.json`；Prodex 回滚模式下 `state.json` 只包含本次 run 的 profile。若全局 `~\.prodex\state.json` 已存在，需要验证它未被常规启动链改写时，可在一次常规 Codex 启动前后分别运行 `Get-FileHash "$env:USERPROFILE\.prodex\state.json"` 并比较 SHA-256。

临时回退到 Prodex：

```powershell
$env:CCSWITCH_CODEX_LAUNCH_MODE = 'prodex'
codex
```

删除该进程环境变量即可恢复默认 direct 模式。

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
- `scripts/invoke-run-home-retention.ps1`：历史 run home 保留工具。默认 `MinimumAgeDays=30` 且只预览；仅 `-Apply` 才删除直属 `ccswitch-run-*`。Apply 使用系统 `%SystemRoot%\System32\fsutil.exe` 核验稳定 File ID；该工具缺失、身份核验或文件/进程枚举失败时均停止。永久保留近期目录、任何 session、`history.jsonl`、`state_*.sqlite*`、活跃进程引用和 reparse point。使用 `-Json` 输出机器可读报告。
- `scripts/get-ccswitch-provider-config-migration.ps1`：只读检查 Codex provider 中待迁移的 `ask_for_approval` 与 `features.js_repl`，并用 TOML 解析验证候选变换。该工具没有写入模式；CC Switch 运行期间应通过 UI 修改 provider 源配置，不直接写活动 SQLite。

常规交互与 `exec` 运行链由启动事件创建独立 Codex 快照，默认直接启动 focus-fixed Codex，并在正常退出事件中按 run metadata 和退出序号回写模型；Prodex 仅作为显式回滚路径。四个单参数根级诊断请求走无状态 fast path，所有路径都不使用后台 watcher。
