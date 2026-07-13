# TODO

## 仓库已实现

- [x] 每次常规交互或 `exec` 启动创建独立 `ccswitch-runs\ccswitch-run-*` Codex home 和持久化兼容目录 `<run home>\.prodex-runtime`，UI 后续切换不重写正在使用的快照；四个单参数根级诊断请求不创建 run home。
- [x] 一致读取 `settings.json` 与 SQLite provider 状态；无法取得一致快照时停止启动。
- [x] 原子发布 run home；默认 direct 设置独立 `CODEX_HOME` 并直接启动 focus-fixed Codex，不注册 Prodex profile；`CCSWITCH_CODEX_LAUNCH_MODE=prodex` 保留原私有 runtime 回滚，不读取或改写全局 `~\.prodex\state.json`。
- [x] 正常退出或 `Ctrl+C` 时，根据 `run-provider.json` 和 launcher 记录的 `ExitOrder`，将变化后的 `model` / `model_reasoning_effort` 写回本次 run 的 provider。
- [x] 未改模型的窗口跳过回写；已修改窗口按字段合并，并通过 `_ccswitchCodexModelExitOrder` 拒绝较旧退出序号覆盖较新结果。
- [x] 使用按 `CcSwitchRoot` 哈希命名的短生命周期 mutex 串行化 persistence，持锁完成 online backup 与 SQLite 写事务。
- [x] UI 已切到 B 时，A 窗口退出只处理 A；只有仍为当前 provider 时才尝试同步共享 mirror。
- [x] 为 PowerShell 7、Windows PowerShell 5.1、无 profile PowerShell、CMD、Windows Terminal 和 Git Bash 提供统一 launcher/profile/shim 接入。
- [x] event launcher 安装器支持 `-DryRun` 与 `-Uninstall`，并仅移除两个项目 watcher 任务。
- [x] 确认 CC Switch 3.16.5 没有可用的外部 `postSwitchCommand`；推荐架构不依赖 UI hook 或后台 watcher。

## 部署验收

- [x] 对 materialize、persist、launcher、installer 和三个 shim 完成 PowerShell 7 / Windows PowerShell 5.1 语法与退出码回归。
- [x] 用临时 SQLite fixture 验证 A/B 隔离、私有 Prodex state、全局 state 不变、切换中间态失败关闭、provider 删除、数据库 busy 和并发 materialize。
- [x] 验证同 provider 较旧 `ExitOrder` 返回 `superseded`、未改模型窗口不回滚、字段级合并，以及 A 退出时当前 UI 为 B 不会改 B。
- [x] 在全新终端分别验证 PowerShell profile、`-NoProfile`、CMD、Windows Terminal 与 Git Bash 的命令解析和参数透传。
- [x] 执行安装器 `-DryRun`，备份现有 profile/用户 `PATH`/相关任务状态后再部署。
- [x] 核对部署后的 `~\.prodex\bin`、`~\.prodex\shims` 与仓库源文件 SHA-256 一致。
- [x] 删除 `ccswitch-codex-current-watcher-user`；ACL 保护的 `ccswitch-codex-current-watcher` 无法删除但已复查为 `Disabled`，无 watcher 进程；`CCSwitchMonitor` 仍为 `Disabled`。
- [x] 不发送付费模型请求，使用 `codex --version` 验证无状态 fast path，并以隔离 fixture 验证完整 run metadata 与模型回写链。

## 2026-07-11 本地收口复核

- [x] 复核工作树：Git 默认状态为 13 项，展开后为 4 个 tracked 修改和 11 个 untracked 文件；全部归入 event launcher、legacy watcher、shim、integration fixture 或配套文档，不回退现有改动。
- [x] 回填部署版的通用兼容修复：Prodex profile 注册改为隐藏的独立 PowerShell 子进程，launcher 以子进程退出码而不是 stderr 更新提示决定结果。
- [x] PowerShell 7 / Windows PowerShell 5.1 语法检查通过；`tests/integration.ps1` 为 28 通过、0 失败、0 surface 跳过；`git diff --check` 通过。
- [x] 在继承私有 `PRODEX_HOME` 的环境中，已部署入口执行 `codex --version` 返回 `codex-cli 0.144.1`，不创建 run home，也不启动 Prodex 或 persistence。
- [x] 修复继承 run-scoped `PRODEX_HOME` 的嵌套入口：物化前恢复用户级 `~\.prodex`，模型回写显式传入用户级 `AllowedRunHomesRoot`。
- [x] 修复 PowerShell 默认大小写不敏感导致小写 Codex `-c` 被误判为大写工作目录 `-C`；integration fixture 覆盖该回归。
- [x] 将精确匹配 `Documents\Codex-Contexts` 的 trust override 回并仓库源；仓库 launcher 与部署副本 SHA-256 一致，其他目录和子目录不自动受信任。
- [x] `.prodex-paCSuj0d` 当前不存在；仅记录路径缺失，不宣称由本轮删除。
- [x] 将 event launcher、integration tests 与 README/TODO 作为同一发布边界收口；当前工作树仍未提交，本轮不提交、不推送。
- [x] 2026-07-13 将日常 `codex` 入口默认迁移为 direct；30/30 integration 通过，真实 `800刀 codex拼车1` 短调用 exit 0 并返回 `SINGLE_DIRECT_CODEX_OK_20260713`，Prodex PID 前后不变；显式 Prodex dry-run 回滚 exit 0 且未发送模型请求。

## 保留与维护

- [x] 保留 `scripts/sync-ccswitch-current-codex.ps1` 作为共享 home 漂移的手动修复工具。
- [x] 最终架构不安装或启动 watcher；旧 watcher 脚本只为迁移和历史诊断保留，不作为自动 fallback。
- [x] 新增 preview-first retention 工具与 fixture matrix：默认 30 天、仅 `-Apply` 删除直属且无 session、历史、state database、reparse point 或活跃引用的普通目录；枚举或稳定 File ID 核验失败时停止。2026-07-12 修复后的真实 Preview 检查 244 个 run home：53 个含 session/rollout、38 个含 history、58 个含 state database、7 个有活跃引用，0 eligible、0 删除。
- [x] 新增只读 provider 配置迁移检查器与真实 SQLite fixture；2026-07-12 Preview 检查 27 个 Codex provider，8 个受影响（7 个旧审批键、5 个 removed `js_repl`），数据库、settings 和 live config 均未写入。
- [ ] 等 CC Switch 自然关闭后，通过应用 UI 迁移上述 provider 源配置；运行期间不直接写 SQLite，也不覆盖当前 live config。

## 不在范围

- WSL、IDE 自定义 launcher、显式调用 Codex/Prodex 绝对路径。
- 已运行进程的 provider 热切换。
- 强杀、宿主崩溃或断电后的模型回写保证。
- 极端 OS 调度下，launcher 尚未记录 UTC ticks 时的内核级严格退出先后保证。
- 删除 Codex 历史、session、`state_*.sqlite`、`history.jsonl` 或 CC Switch provider 数据。
