# 架构与数据流

## 目标

CC Switch 的共享配置会随 UI 选择变化。这个项目不让已运行的 Codex 窗口继续读取共享配置，而是在启动时创建不可变的 run home。每个窗口只使用自己的 `config.toml`、`auth.json` 和 session 状态。

## 启动流程

`scripts/invoke-ccswitch-codex.ps1` 是统一入口，常规启动会调用 `scripts/materialize-ccswitch-codex-run.ps1`：

1. 读取 CC Switch `settings.json` 中的 `currentProviderCodex`。
2. 对照 SQLite `providers` 表中唯一的当前 Codex provider。
3. 从同一数据库快照读取 provider 配置、认证和 endpoint；状态不一致时停止启动。
4. 在 `%USERPROFILE%\.prodex\manual-homes\ccswitch-runs\ccswitch-run-*` 原子发布 run home。
5. 设置 `CODEX_HOME` 为新 run home，并清除可能串号的 OpenAI 和 Prodex 进程环境变量。
6. 默认直接执行固定的 Codex 可执行文件。

每个 run home 包含：

- `config.toml`
- `auth.json`
- `run-provider.json`
- `.prodex-runtime\`

`run-provider.json` 保存 provider 身份、启动模型基线和配置摘要，不保存明文密钥。

根级单参数 `--version`、`-V`、`--help`、`-h` 直接调用固定 Codex，可避免为诊断命令创建 run home。

## 启动模式

默认模式是 `direct`：

- 设置独立 `CODEX_HOME`。
- 直接运行 Codex。
- 不注册 Prodex profile。
- 不读取或写入全局 `%USERPROFILE%\.prodex\state.json`。

只有进程环境显式设置 `CCSWITCH_CODEX_LAUNCH_MODE=prodex` 时，入口才使用 run home 内的私有 `.prodex-runtime` 并执行 Prodex 回滚链。

## Session 恢复

`resume` 和 `fork` 会根据 session UUID 查找原 run home。未提供 UUID 且不是 `--last` 时，交互入口显示可恢复 session 列表；无交互环境应使用明确 UUID 或 `--last`。

恢复时会验证：

- run metadata 的必需字段存在。
- `codexHome` 和 `prodexHome` 指向同一个受允许的 run home。
- run home、私有 Prodex 目录和 session 文件仍存在。

验证失败的历史 run 不参与恢复。

## 退出与模型写回

Codex 返回后，launcher 调用 `scripts/persist-run-model.ps1`：

- 只写回相对启动基线发生变化的 `model` 或 `model_reasoning_effort`。
- provider 来自本次 run 的 metadata，不来自退出时的 CC Switch 当前选择。
- 未修改模型的旧窗口不会回滚 provider 的新值。
- 同一 provider 的并发写回按退出序号合并，较旧结果不能覆盖较新结果。
- 写入前创建 SQLite online backup，并在事务中回读验证。

模型写回失败会记录 warning，但不会替换 Codex 自身退出码。

## 并发与失败边界

- 物化时要求 `settings.json` 与数据库当前 provider 一致，否则失败关闭。
- persistence 使用按 CC Switch 数据根命名的互斥锁，串行化备份和数据库事务。
- 只有 provider 在 settings 与数据库中仍同时为当前项时，才同步共享 mirror。
- 任务管理器强杀、宿主崩溃或断电可能跳过退出写回。
- launcher 记录的是恢复执行后的 UTC ticks，不承诺极端调度情况下的内核级严格墙钟顺序。

## 入口覆盖范围

安装器接管：

- PowerShell 7 profile
- Windows PowerShell 5.1 profile
- 无 profile PowerShell 的 shim
- CMD 的 `codex.cmd`
- Git Bash 的无扩展名 `codex`

不覆盖：

- WSL 内部入口
- IDE 自行指定的 Codex launcher
- 显式调用 Codex 或 Prodex 绝对路径
- 已运行进程的 provider 热切换
