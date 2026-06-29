<div align="center">

# ProcMon AI Toolkit

**AI 原生的 Process Monitor 自动化工具：采集、过滤、查询 — 全程零人工干预。**

[English](README.md) | 简体中文

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows-blue.svg)](#前置条件)
[![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg)](#前置条件)
[![Python 3.8+](https://img.shields.io/badge/Python-3.8%2B-3776AB.svg)](#前置条件)

</div>

---

## 为什么需要这个工具？

AI 智能体（Claude Code、Copilot、Cursor 等）已经可以通过命令行调用 `Procmon64.exe`。但每次分析时，AI 仍然需要**从零开始编写 XML/CSV 解析代码** — 脆弱、缓慢、容易出错。

本工具包将 ProcMon 变成一个 **AI 原生工具**，解决三个核心问题：

| 场景 | 没有本工具 | 使用本工具 |
|------|-----------|-----------|
| 查询 DLL 加载 | 编写 ~15 行 Python/PS XML 解析代码 | `query_events(filter_operation="Load Image")` |
| 搜索文件访问 | 编写 XPath 或 iterparse 代码 | `find_file_access(path_contains="Project.ini")` |
| 按进程统计 | 编写 GroupBy 逻辑 | `count_events_by_process()` |
| 切换分析维度 | 重写代码并重新运行 | 换一个参数 |
| 生成过滤器 | 手动操作 ProcMon GUI | `gen-filter.py --process X.exe --path-contains Y` |

**MCP 的真正价值：AI 零代码直接查询，省掉了每次写解析脚本的往返。**

## 架构

```
┌──────────────────────────────────────────────────────┐
│                    AI 智能体                          │
│              (Claude Code 等)                         │
└───────┬─────────────────────────────────┬────────────┘
        │ 第一步：采集                     │ 第二步：查询
        ▼                                 ▼
┌───────────────┐  XML  ┌──────────────────────────────┐
│  capture.ps1  │──────▶│   ProcmonMCP (MCP 服务器)     │
│               │       │                              │
│ 启动 ProcMon  │       │  load_file    query_events   │
│ 运行目标程序  │       │  find_file_access             │
│ 停止 ProcMon  │       │  list_processes              │
│ 导出 XML      │       │  count_events_by_process     │
└───────┬───────┘       │  export_query_results  ...   │
        │               └──────────────────────────────┘
        │（可选）
        ▼
┌───────────────┐
│ gen-filter.py │
│               │
│ 进程名        │
│ 路径模式      │──▶ .pmc 过滤器文件
│ 操作类型      │
│ 结果          │
└───────────────┘
```

## 核心特性

- **一键采集** — `capture.ps1` 全自动管理 ProcMon 生命周期：启动、运行目标、停止、导出 XML、写入 manifest
- **自动过滤** — 自动提取目标进程名生成 PMC 过滤器，采集数据量缩减约 1000 倍
- **可编程过滤器** — `gen-filter.py` 通过命令行参数生成 PMC 配置（进程名、路径、操作类型、结果可自由组合）
- **MCP 集成** — 通过 [ProcmonMCP](https://github.com/JameZUK/ProcmonMCP) 提供 18 个结构化查询工具，无需编写解析代码
- **竞态安全** — 处理了 ProcMon 文件锁释放时序和 XML 导出完成检测，带重试逻辑

## 前置条件

- **Windows 10/11**
- **[Process Monitor](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon)** (Procmon64.exe) — 脚本自动搜索常见安装路径
- **PowerShell 5.1+**（Windows 自带）
- **Python 3.8+**（用于 `gen-filter.py` 和 MCP 服务器）

## 安装

```bash
git clone https://github.com/liujialu0330/procmon-ai-toolkit.git
cd procmon-ai-toolkit

# 创建虚拟环境并安装依赖
python -m venv .venv
.venv\Scripts\pip.exe install procmon-parser
.venv\Scripts\pip.exe install "git+https://github.com/JameZUK/ProcmonMCP.git#egg=procmon-mcp[all]"
```

### MCP 配置

在项目的 `.mcp.json` 中添加（适用于 Claude Code）：

```json
{
  "mcpServers": {
    "procmon": {
      "type": "stdio",
      "command": "path/to/procmon-ai-toolkit/.venv/Scripts/python.exe",
      "args": ["-m", "procmon_mcp"]
    }
  }
}
```

## 快速开始

### 1. 采集

```powershell
# 基本用法 — 自动按目标进程名过滤
.\capture.ps1 -TargetCommand "C:\path\to\your-app.exe --some-arg"

# 指定超时时间
.\capture.ps1 -TargetCommand "your-app.exe" -TimeoutSeconds 60

# 使用自定义过滤器
.\capture.ps1 -TargetCommand "your-app.exe" -FilterConfig "my-filter.pmc"
```

产出在 `captures/capture-<时间戳>/` 目录下：
- `capture.xml` — ProcMon 事件数据（供 MCP 加载）
- `manifest.json` — 元数据（退出码、stdout/stderr、耗时、文件大小）
- `stdout.txt` / `stderr.txt` — 目标命令输出

### 2. 生成自定义过滤器（可选）

```powershell
$py = ".venv\Scripts\python.exe"

# 按进程名过滤
& $py gen-filter.py -o filter.pmc --process MyApp.exe

# 进程名 + 路径模式
& $py gen-filter.py -o filter.pmc --process MyApp.exe --path-contains "config.ini"

# 进程名 + 排除噪音路径
& $py gen-filter.py -o filter.pmc --process MyApp.exe --path-excludes "\Windows\" --path-excludes "\AppData\"

# 只看 DLL 加载
& $py gen-filter.py -o filter.pmc --process MyApp.exe --operation "Load Image"

# 只看失败事件
& $py gen-filter.py -o filter.pmc --process MyApp.exe --result-excludes SUCCESS

# 查看可用过滤列名
& $py gen-filter.py --list-columns
```

### 3. 通过 MCP 查询

加载 XML 后，AI 智能体可以直接使用以下 MCP 工具：

```
load_file("captures/capture-20260629/capture.xml")

query_events(filter_operation="Load Image")          → DLL 加载顺序
find_file_access(path_contains="Project.ini")        → 配置文件访问
query_events(filter_result="NAME NOT FOUND")         → 失败的文件查找
count_events_by_process()                            → 事件分布统计
summarize_operations_by_process()                    → 操作类型分布
export_query_results(format="csv", output_path=...)  → 导出供进一步分析
```

## MCP 工具参考

| 工具 | 用途 |
|------|------|
| `load_file` | 加载 ProcMon XML 文件 |
| `close_file` | 卸载当前文件，释放内存 |
| `get_status` | 服务器状态、加载进度 |
| `clear_cache` | 清除解析缓存 |
| `get_loaded_file_summary` | 事件总数、进程数概览 |
| `get_metadata` | 文件基本元数据 |
| `list_processes` | 所有进程列表（PID、路径、父进程） |
| `get_process_details` | 指定 PID 的详细信息 |
| `query_events` | 灵活的多条件事件查询 |
| `get_event_details` | 指定事件的完整属性 |
| `get_event_stack_trace` | 事件调用栈 |
| `count_events_by_process` | 按进程统计事件数 |
| `summarize_operations_by_process` | 操作类型分布统计 |
| `get_timing_statistics` | 按操作类型的耗时统计 |
| `get_process_lifetime` | 进程生命周期 |
| `find_file_access` | 按路径搜索文件访问事件 |
| `find_network_connections` | 查询指定进程的网络连接 |
| `list_network_connections` | 所有网络连接列表 |
| `export_query_results` | 导出查询结果为 CSV 或 JSON |

## 应用场景

- **SDK/DLL 依赖分析** — 跟踪加载了哪些 DLL、来自哪个路径、加载顺序
- **配置文件访问监控** — 监控应用启动时读取了哪些配置文件
- **故障诊断** — 查找 `NAME NOT FOUND` / `ACCESS DENIED` 事件，定位缺失文件
- **运行时行为分析** — 在不修改源码的情况下理解文件 I/O 模式
- **回归测试** — 对比不同版本之间的文件访问模式差异

## 致谢

- [Process Monitor](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon) — Sysinternals (Microsoft) 出品的系统监控工具
- [ProcmonMCP](https://github.com/JameZUK/ProcmonMCP) — JameZUK 开发的 MCP 服务器，使结构化查询成为可能
- [procmon-parser](https://github.com/eronnen/procmon-parser) — eronnen 开发的 Python 库，用于读取 PML 文件和生成 PMC 过滤器

## 许可证

MIT 许可证。详见 [LICENSE](LICENSE)。
