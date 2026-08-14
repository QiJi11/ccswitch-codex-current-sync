# 项目状态

## 已实现

- 每次常规交互或 `exec` 创建独立 run home。
- 诊断 flag 的无状态快速路径。
- CC Switch settings 与 SQLite 当前 provider 的一致性检查。
- 原子发布 provider 配置和认证快照。
- 默认 direct 启动与显式 Prodex 回滚模式。
- 运行中以及正常退出和 `Ctrl+C` 后按字段写回模型设置。
- 同 provider 并发退出的顺序保护和 SQLite online backup。
- PowerShell、无 profile PowerShell、CMD 和 Git Bash 入口。
- preview-first 安装、卸载和 run home 保留。
- provider 配置迁移预检。
- 第三方 provider 的 DPAPI `CurrentUser` 凭据存储、命令认证和只读审计；官方登录保持原机制。
- 全局耐久配置、全部 agents/skills、hooks、rules 和 prompts 的 current/run 同步。
- 生成式 `ccswitch-current`、受管理陈旧文件移除和预览式旧备份清理。
- 带缓存的 Codex 稳定版更新提示，并隔离机器可读命令输出。

## 验证覆盖

- 独立 provider A/B 快照。
- settings 与数据库切换中间态。
- provider 删除和数据库 busy。
- 并发 materialize 与并发模型写回。
- 未修改模型的窗口不回滚新值。
- 继承私有 `PRODEX_HOME` 的嵌套启动。
- PowerShell `-c` 与 Codex `-C` 参数区分。
- session UUID、`--last` 和交互 picker 恢复。
- retention 的年龄、session、history、state、reparse point 和活跃引用边界。
- provider 配置迁移的正向、无变化和非法配置路径。
- 更新可用、无需更新、拒绝降级、断网缓存和交互/机器输出边界。
- DPAPI 往返、ACL/owner、空令牌、损坏密文、双来源冲突、官方认证碰撞、不可读扫描文件、文件与数据库事务补偿、WAL/SHM 安全回滚和输出不泄密。
- current/run 耐久文件同步、陈旧受管文件移除和运行态目录排除。
- 旧备份与孤立 staging 的 preview/apply，以及可恢复 run 零删除。

## 运行环境待处理

- 首次真实凭据迁移必须在 CC Switch 完全退出后执行。
- 本地收口不会使已经暴露的远程 key 失效；迁移报告中的第三方 provider 仍需在各平台后台轮换。

## 明确不支持

- WSL 或 IDE 自定义 launcher。
- 显式调用其他 Codex/Prodex 绝对路径。
- 已运行进程的 provider 热切换。
- 强杀、宿主崩溃或断电后的模型写回保证。
- 极端 OS 调度下的内核级严格退出先后保证。
- 自动删除 Codex 历史、session、state database 或 CC Switch provider 数据。
- 自动调用第三方 provider 或验证远程 key、余额和网络可达性。
