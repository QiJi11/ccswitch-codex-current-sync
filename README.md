# ccswitch-codex-current-sync

> 归档说明：本仓库的有效能力将迁移到 `QiJi11/cc-switch` 的原生 Codex 路由实现。此仓库只保留历史脚本、验证记录和回滚参考，不再作为日常切换入口。

这个仓库为 CC Switch 与 Codex 提供 provider 快照，并维护一套统一的 Codex 全局运行策略。模型、Fast 模型、reasoning effort 和 service tier 由 `persist-codex-fast-all-providers.py` 原子同步到全局 `config.toml` 及全部 Codex provider；provider 的 endpoint、认证和名称仍保持独立。

## 目标行为

- 在 CC Switch UI 选择 provider A 后执行 `codex`，新进程获得 A 的独立 `CODEX_HOME` 快照，并默认直接启动 focus-fixed Codex。
- 之后在 UI 切换到 provider B，provider 路由会切换到 B，但模型、Fast 模型、reasoning effort 和 service tier 仍沿用同一套全局策略。
- 通过 Fast 菜单或模型选择器修改全局策略后，配置 watcher 会同步全部 provider，并由 App shell 受控重启 Codex App 使新策略生效。
- 在 Codex 内通过 `/model` 修改模型后，模型和 reasoning effort 会在运行期间写回启动该进程的 provider；退出时仍执行最终兜底，而不是写到退出时 UI 当前选中的 provider。

不支持无中断的进程内热切换。策略修改会在同步成功后自动执行受控重启；正在生成的任务可能被中断。

## 事件流程

### 启动

普通新会话由 `scripts/invoke-ccswitch-codex.ps1` 调用 `scripts/materialize-ccswitch-codex-run.ps1`；`resume` 会复用 session 所属的原 run home，单参数根级 `--version`、`-V`、`--help`、`-h` 则走无状态 fast path：

1. 优先使用 `%APPDATA%\com.ccswitch.desktop`，不存在时回退到 `~\.cc-switch`；对照同一根目录下 `settings.json` 的 `currentProviderCodex` 与 `cc-switch.db` 的当前 Codex provider。
2. 从同一份稳定的数据库快照读取 provider 配置、认证信息和 endpoint；切换状态短暂不一致时会重试，无法取得一致状态则停止启动。
3. 在 `~\.prodex\manual-homes\ccswitch-runs\ccswitch-run-*` 下发布新的 run home，写入 `config.toml`、`auth.json` 和 `run-provider.json`，并创建用于兼容模型持久化的空 `<run home>\.prodex-runtime`。
4. 默认 `direct` 模式设置 `CODEX_HOME=<run home>`，清除 `PRODEX_CODEX_BIN`、`PRODEX_HOME` 和可能串号的 `OPENAI_API_KEY`、`OPENAI_BASE_URL`、`OPENAI_API_BASE`，再直接执行 focus-fixed Codex；不会注册或启动 Prodex。未显式指定 sandbox 时保持原有 full-access 启动；传入 `--sandbox <mode>` 或 `-s <mode>` 时保留该 sandbox，且不再自动追加 bypass。`prodex` 回滚链同样不会用 `--full-access` 覆盖显式 sandbox。
5. 仅当进程环境显式设置 `CCSWITCH_CODEX_LAUNCH_MODE=prodex` 时，才在私有 `.prodex-runtime` 中注册唯一 profile 并执行 Prodex 回滚链；未指定 sandbox 时使用 `--full-access`，显式 sandbox 时不追加该参数。两种模式都不读取或改写全局 `~\.prodex\state.json`。

`run-provider.json` 保存 provider 身份、启动时的模型基线和配置摘要，不保存明文密钥。后续 UI 切换不会重写已经发布的 run home。

四个单参数根级诊断请求直接调用 `~\.codex\bin\codex-focusfixed-current.txt` 指向的 Codex 可执行文件，不启动 Prodex、不创建 run home，也不执行模型回写。诊断 flag 与任何其他参数组合时仍走完整启动链。

### 运行中与退出

launcher 在 Codex 启动前创建 run-scoped `watch-run-model.ps1`，并在 Codex（或显式回滚时的 Prodex）返回后执行最终持久化：

- watcher 使用 Python `tomllib` 只读取顶层 `model` 和 `model_reasoning_effort`。模型发生变化时立即写回；`database_busy` 会进行有限重试。
- watcher 把尚未成功写回的字段保存在 run home 内。即使用户执行 `A -> B -> A`，最终选择重新等于启动基线，也不会错误地把 provider 留在 B。
- 退出时 launcher 先停止 watcher，再读取 pending 字段并调用 `persist-run-model.ps1` 做最终兜底。成功后删除 watcher 状态文件；失败时保留状态以便诊断。
- 没有修改模型的旧窗口会跳过，不会把 provider 回滚到旧值。
- provider 由本次 run metadata 确定。即使 A 退出时 UI 已切到 B，也只更新 A，不会更新 B。
- 同一 provider 的已修改窗口使用内部字段 `_ccswitchCodexModelExitOrder` 保存 launcher 观察到的退出时间。数据库中已有更大的退出序号时，较旧写回返回 `superseded`，不会覆盖较晚退出窗口的选择。
- persistence 通过按 `CcSwitchRoot` 哈希命名的短生命周期 mutex 串行执行；持锁范围覆盖 online backup 和 SQLite 写事务，避免已进入 persistence 的多个进程发生 backup/commit 反序。
- 更新数据库前创建 online backup，并在事务内再次检查退出序号、更新和回读验证。只有该 provider 仍同时是 `settings.json` 与数据库中的当前 provider 时，才尝试同步共享 mirror。
- 回写失败不会篡改 Codex 原退出码；launcher 会发出 warning，并把 `source`、`status`、`errorCode`、退出码和脱敏消息以 JSONL 写入 `~\.prodex\logs\ccswitch-event-launcher.log`。

正常退出，以及通过 `Ctrl+C` 结束 Codex 并返回 launcher 时，会进入退出处理。任务管理器强杀 launcher 进程树、终端宿主崩溃或断电时，刚发生且 watcher 尚未观察到的模型选择仍可能来不及写回。

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

- Windows 上已配置 CC Switch Codex provider，并在 `%APPDATA%\com.ccswitch.desktop` 或 `~\.cc-switch` 下存在 `settings.json` 与 `cc-switch.db`。
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

- 将启动、物化、持久化、run-scoped watcher、同步、手动切换和根目录解析脚本部署到 `~\.prodex\bin`。
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
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\ccswitch-root-resolution.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\hooks-smoke.ps1
python .\tests\fast-auth-proxy.py
python -m unittest tests.test_diagnose_codex_run_provider
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\fast-hybrid-config.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\fast-hybrid-provider.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-update-check.ps1
git diff --check
```

常规 PowerShell 应优先解析到 profile 中的 `codex` 函数；`where.exe` 和无 profile PowerShell 应能看到 `~\.prodex\shims` 中的入口，而且该目录应排在 `%APPDATA%\npm` 之前。CMD 可运行 `where codex`，Git Bash 可运行 `type -a codex` 做同样检查。

以下命令只检查当前固定 Codex 可执行文件的版本，不发送模型请求，也不创建 run home：

```powershell
codex --version
```

该 fast path 也不会显示 Prodex 自身的更新横幅；使用 `prodex info` 查看 Prodex 当前版本与可用更新。

日常 `invoke-ccswitch-codex.ps1` 交互入口和 direct 窗口池会调用 `~\.codex\bin\check-codex-update.ps1`，每 6 小时从官方 npm registry 查询一次 `@openai/codex` 的 `latest` 版本并缓存到 `~\.codex\codex-update-check.json`。这条回退不依赖容易触发匿名限流的 GitHub Releases API；`exec`、`review` 等机器输出路径不会插入更新提示。手动只读检查可运行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.codex\bin\check-codex-update.ps1" -Json
```

常规交互或 `exec` 运行结束后，可检查最近一次 run metadata；不要输出 `auth.json`：

```powershell
$run = Get-ChildItem "$env:USERPROFILE\.prodex\manual-homes\ccswitch-runs" -Directory |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

Get-Content -Raw -LiteralPath (Join-Path $run.FullName 'run-provider.json') |
  ConvertFrom-Json |
  Select-Object launchMode, profileName, codexHome, prodexHome, providerName, providerId, model, modelReasoningEffort, materializedAt
```

需要区分本地凭据问题与供应商入口拒绝时，对一个已物化 run 执行只读诊断；输出只包含 provider ID、模型、host、HTTP 状态和诊断，不包含 Key：

```powershell
python .\scripts\diagnose-codex-run-provider.py --run-home '<ccswitch-run-home>'
```

诊断器先校验 `config.toml`、`auth.json` 和 `run-provider.json` 属于同一个 provider 快照，再分别请求 `/models`。如果带认证和不带认证都返回相同的 `401` 或 `403`，结果为 `entry_rejection_inconclusive`：入口网关、WAF 或供应商策略可能在认证判断前拒绝请求，不能据此认定本地 Key 串错。

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

- `scripts/codex-fast-auth-proxy.py`：仅监听 `127.0.0.1`，验证 Codex 当前 ChatGPT access token 后，将发往 `/responses` 的 `Authorization` 替换为 CC Switch 当前 provider 的 API Key。它不记录请求正文或凭据，只接受 HTTPS 上游。
- `scripts/install-codex-fast-auth-proxy.ps1`：将代理部署到 `~\.prodex\bin`，写入当前用户 `Run` 启动项并立即执行健康检查；`-Uninstall` 只移除启动项和已验证的代理进程，不回退 Codex 配置。
- `scripts/enable-codex-fast-hybrid.ps1`：备份全局 `config.toml` / `auth.json`，启用 `gpt-5.6-sol`、`priority`、ChatGPT 登录态和本地代理 endpoint。必须传入由官方设备授权刚生成的 `ChatGptAuthPath`。
- `scripts/persist-codex-fast-hybrid-provider.ps1`：对当前 CC Switch provider 做 SQLite online backup，再持久化本地代理 endpoint、ChatGPT 登录态和原 HTTPS 上游元数据；原 API Key 保留在 provider 内供代理按请求读取。
- `scripts/persist-codex-fast-all-providers.py`：以全局 `config.toml` 为运行策略基线，原子同步模型、Fast 模型、reasoning effort 和 service tier 到全部 Codex provider；`--apply` 前会创建 SQLite 与 config 备份。
- `scripts/sync-ccswitch-current-codex.ps1`：手动修复共享 `ccswitch-current` home 漂移。
- `scripts/watch-ccswitch-sync.ps1` 与 `scripts/install-watcher-task.ps1`：旧的后台 watcher 实现，仅为迁移和历史诊断保留；最终架构不安装或启动它们。
- `scripts/switch-codex-provider.ps1`：旧的显式切换路径，不是 UI 自动隔离的推荐入口。
- `scripts/invoke-run-home-retention.ps1`：历史 run home 保留工具。默认 `MinimumAgeDays=30` 且只预览；仅 `-Apply` 才删除直属 `ccswitch-run-*`。Apply 使用系统 `%SystemRoot%\System32\fsutil.exe` 核验稳定 File ID；该工具缺失、身份核验或文件/进程枚举失败时均停止。永久保留近期目录、任何 session、`history.jsonl`、`state_*.sqlite*`、活跃进程引用和 reparse point。使用 `-Json` 输出机器可读报告。
- `scripts/get-ccswitch-provider-config-migration.ps1`：只读检查 Codex provider 中待迁移的 `ask_for_approval` 与 `features.js_repl`，并用 TOML 解析验证候选变换。该工具没有写入模式；CC Switch 运行期间应通过 UI 修改 provider 源配置，不直接写活动 SQLite。

常规交互与 `exec` 运行链由启动事件创建独立 Codex 快照，默认直接启动 focus-fixed Codex，并通过 run-scoped watcher 和退出兜底按 run metadata 回写模型；Prodex 仅作为显式回滚路径。四个单参数根级诊断请求走无状态 fast path，所有路径都不使用常驻全局 watcher。

### Codex App 的 Fast 与自定义 provider

Codex App 只在 ChatGPT 登录态显示 Fast；自定义 provider 的 API Key 不能通过 `env_http_headers.Authorization` 覆盖，因为 `requires_openai_auth=true` 会在发送前重新写入 ChatGPT Token。代理方案把这两个职责分开：App 保持 ChatGPT 登录态和 Fast UI，本地回环代理在验证该登录态后才换成 CC Switch 当前 provider Key。

部署顺序如下；`$freshAuth` 指向本机刚完成官方设备代码授权的隔离 `auth.json`：

```powershell
$freshAuth = '<fresh Codex auth.json>'
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\persist-codex-fast-hybrid-provider.ps1 -ChatGptAuthPath $freshAuth
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\enable-codex-fast-hybrid.ps1 -ChatGptAuthPath $freshAuth
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-codex-fast-auth-proxy.ps1
```

部署后可用以下命令检查，不输出凭据：

```powershell
Invoke-RestMethod http://127.0.0.1:17896/health
codex exec --disable hooks --skip-git-repo-check --json '只输出 FAST_PROXY_OK，不使用工具。'
```

代理只转发 `/responses` 与 `/responses/compact`，上游必须来自当前 CC Switch Codex provider 且使用 HTTPS。切换到没有 API Key、配置损坏或与数据库当前项不一致的 provider 时，代理失败关闭并返回 `502`。
