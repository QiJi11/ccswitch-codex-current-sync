# 项目状态

## 已实现

- 每次常规交互或 `exec` 创建独立 run home。
- 诊断 flag 的无状态快速路径。
- CC Switch settings 与 SQLite 当前 provider 的一致性检查。
- 原子发布 provider 配置和认证快照。
- 默认 direct 启动与显式 Prodex 回滚模式。
- 正常退出和 `Ctrl+C` 后按字段写回模型设置。
- 同 provider 并发退出的顺序保护和 SQLite online backup。
- PowerShell、无 profile PowerShell、CMD 和 Git Bash 入口。
- preview-first 安装、卸载和 run home 保留。
- provider 配置迁移预检。
- 第三方与官方 provider 认证规范化和只读审计。

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

## 待处理

- 旧 provider 中的审批键和 `features.js_repl` 迁移仍需在 CC Switch 关闭后处理。

## 明确不支持

- WSL 或 IDE 自定义 launcher。
- 显式调用其他 Codex/Prodex 绝对路径。
- 已运行进程的 provider 热切换。
- 强杀、宿主崩溃或断电后的模型写回保证。
- 极端 OS 调度下的内核级严格退出先后保证。
- 自动删除 Codex 历史、session、state database 或 CC Switch provider 数据。
