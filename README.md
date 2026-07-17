# ccswitch-codex-current-sync

在 Windows 上把 CC Switch 当前选择的 Codex provider 固化成每次启动独立的 `CODEX_HOME`。已经运行的窗口不会被后续 provider 切换改写，正常退出时只把本窗口修改过的模型设置写回原 provider。

## 能解决什么

- 每次启动创建独立 provider 快照，避免多个 Codex 窗口互相覆盖配置和认证。
- 默认直接启动 Codex；Prodex 仅保留为显式回滚路径。
- `resume` 复用原 session 所属的 run home。
- 正常退出或 `Ctrl+C` 后，把变化过的 `model` 和 `model_reasoning_effort` 写回正确 provider。
- 为 PowerShell、无 profile PowerShell、CMD 和 Git Bash 提供统一入口。
- 提供认证规范化、只读审计、历史 run home 保留和 provider 配置迁移工具。
- 交互启动每 6 小时检查一次 Codex 稳定版；发现更新时提示，机器可读命令不插入提示。

不支持运行中热切换。要采用 CC Switch 新选择的 provider，需要结束当前 Codex 后重新启动。

## 快速开始

先阅读[运行与安装](docs/operations.md)中的前置条件。安装前先预览：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-event-launcher.ps1 -DryRun
```

确认输出后执行安装：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-event-launcher.ps1
```

安装后打开新终端，检查入口：

```powershell
Get-Command codex -All | Select-Object CommandType, Name, Source, Definition
where.exe codex
codex --version
```

`codex --version` 走无状态路径，不创建 run home，也不发送模型请求。

## 仓库验证

测试使用隔离 fixture，不读取真实 provider 凭据，也不发送模型请求：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\integration.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\retention.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\provider-config-migration.ps1
pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-update-check.ps1
python -m py_compile .\scripts\audit-codex-provider-auth.py .\scripts\normalize-ccswitch-codex-auth.py
git diff --check
```

## 文档

- [架构与数据流](docs/architecture.md)：启动快照、退出写回、并发边界和失败处理。
- [运行与安装](docs/operations.md)：前置条件、安装、验收、回滚和卸载。
- [维护工具](docs/maintenance.md)：认证整理、审计、保留策略和旧 watcher。
- [项目状态](docs/status.md)：已实现能力、剩余事项和明确不支持的范围。

## 目录

```text
.
├─ README.md
├─ docs/
│  ├─ architecture.md
│  ├─ maintenance.md
│  ├─ operations.md
│  └─ status.md
├─ scripts/
│  ├─ shims/
│  └─ *.ps1 / *.py
└─ tests/
```

运行脚本保持原路径，避免破坏已部署入口；维护工具和旧实现通过文档分类，不靠移动文件制造兼容性风险。
