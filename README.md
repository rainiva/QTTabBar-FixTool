# QTTabBar-FixTool

Windows 资源管理器 **QTTabBar** 标签页失效的一键修复工具。通过 ViVeTool 禁用冲突功能包，并清理 FeatureManagement 残留注册表键，恢复 QTTabBar 工具栏。

## 背景

Windows 11 累积更新（KB5062660、KB5072033、KB5074105 等）会启用与 QTTabBar 冲突的 Explorer 功能包，导致标签页、工具栏无法正常显示。本工具提供两阶段自动化修复流程，并附带状态查询、健康检测与模拟运行。

## 功能

| 阶段 | 说明 |
|------|------|
| **阶段一** | 使用 ViVeTool 禁用冲突功能包 |
| **阶段二** | 清理 `FeatureManagement\Overrides` 下的残留注册表键 |

菜单还支持：完整修复、仅查询状态、模拟运行（`-WhatIf`）、健康检测、快速清理残留键等。

## 支持的功能包

| 功能 ID | 注册表 ID | 对应更新 |
|---------|-----------|----------|
| 57048216 | 815149711 | 2025-08 功能包 (KB5062660) |
| 57048237 | 1519792783 | 2025-12 功能包 (KB5072033) |
| 58988972 | 1482552975 | 2026-02 功能包 (KB5074105) |

## 系统要求

- Windows 10 / 11
- PowerShell 5.1 或更高版本
- **管理员权限**（修改系统注册表与 ViVeTool 操作必需）
- 已安装 [QTTabBar](https://github.com/indiff/qttabbar)

## 快速开始

### 方式一：双击启动（推荐）

- 双击 `Run-QTTabBarFix.bat`
- 或双击 `启动修复工具.vbs`（自动请求管理员权限）

### 方式二：PowerShell

```powershell
# 以管理员身份打开 PowerShell，进入工具目录后执行
.\Run-QTTabBarFix.ps1
```

首次运行若弹出 UAC，请点击「是」。进入菜单后选择 **[1] 完整修复（阶段一 + 阶段二）** 即可。

### 命令行（高级）

```powershell
# 完整修复
.\Fix-QTTabBar.ps1 -Phase All

# 仅查询当前状态
.\Fix-QTTabBar.ps1 -QueryOnly

# 模拟运行，不实际修改
.\Fix-QTTabBar.ps1 -Phase All -WhatIf

# 健康检测
.\Fix-QTTabBar.ps1 -VerifyOnly -SkipProbe
```

## 菜单选项

| 选项 | 说明 |
|------|------|
| 1 | 完整修复（阶段一 + 阶段二）**推荐** |
| 2 | 仅阶段一（ViVeTool 禁用功能包） |
| 3 | 仅阶段二（清理冲突注册表键） |
| 4 | 仅查询当前状态 |
| 5 | 模拟运行（不实际修改） |
| 6 | 健康检测（检测 QTTabBar 是否可用） |
| 7 | 快速清理残留注册表键（不重启资源管理器） |
| 0 | 退出 |

## 目录结构

```
QTTabBar-FixTool/
├── Fix-QTTabBar.ps1          # 修复核心脚本
├── Run-QTTabBarFix.ps1       # 交互式菜单启动器
├── Run-QTTabBarFix.bat       # 批处理入口
├── 启动修复工具.vbs           # 静默提权启动
├── ViVeTool.exe              # ViVeTool 可执行文件
├── Scripts/                  # 辅助脚本
├── Tests/                    # Pester 测试
├── Logs/                     # 运行日志（自动生成，已 gitignore）
└── Backup/                   # 注册表备份（自动生成，已 gitignore）
```

## 日志与备份

- 每次运行会在 `Logs/` 目录生成带时间戳的日志文件
- 删除注册表键前会在 `Backup/` 目录自动导出 `.reg` 备份
- 上述目录已在 `.gitignore` 中排除，不会提交到仓库

## 注意事项

> **警告**：本工具会修改系统注册表并调用 ViVeTool，请在了解风险后使用。建议修复前创建系统还原点。

- 完整修复后通常需要**重启电脑**或至少重启资源管理器
- 若 ViVeTool 已成功禁用功能包，阶段二有个别键删除失败通常可忽略
- 请勿在不了解含义的情况下手动编辑 `FeatureManagement` 注册表

## 开发与测试

```powershell
Invoke-Pester .\Tests\Fix-QTTabBar.Tests.ps1
```

## 免责声明

本工具按「现状」提供，不对因使用本工具造成的任何系统问题负责。使用前请自行备份重要数据。

## 相关链接

- [QTTabBar 项目](https://github.com/indiff/qttabbar)
- [ViVeTool](https://github.com/thebookisclosed/ViVe)