# term-hud

在 Windows Terminal 标题栏右侧空白处，用紧凑的双行表格常驻显示 CPU、内存、GPU、磁盘和网络，以及 CPU 核心最高温度和是否降频。当前选中的标签是 Claude Code 时，还会显示账户的 5 小时和 7 天额度，以及这个会话的上下文用量。产品预期见 [docs/product.md](docs/product.md)。

## 运行

```powershell
pwsh -NoProfile -File .\term-hud.ps1          # 前台运行（同时只允许一个实例）
pwsh -NoProfile -File .\term-hud.ps1 -Test    # 自检纯逻辑：温度解析、选窗、配对与收起、字段对齐、Clawd 像素、会话上下文解析
```

开机自启：`shell:startup\term-hud.lnk`，通过 `conhost.exe --headless` 启动，不弹出控制台窗口。退出：右键 HUD，选“退出”。

## 操作

- 右键：勾选要显示的条目，在子菜单里选择统计哪些磁盘和网卡，或勾选“始终显示（置顶）”。结果保存在 `%APPDATA%\term-hud\settings.json`。默认只在 WT 标题栏没被遮挡时显示。
- 左键拖动：移动 WT 窗口（拖动期间 HUD 隐藏，停稳后重新显示）。双击：最大化或还原 WT。
- 排错：定时器里的最近一次异常写在 `%LOCALAPPDATA%\term-hud\error.log`。已知问题见 spec 的 Known issues。

## 数据源

| 列 | 来源 | 说明 |
|---|---|---|
| CPU 占用、频率、降频 | 性能计数器 `Processor Information` | `% Performance Limit` 低于 100 时频率前加 `↓` 并变为橙色 |
| CPU 温度 | LibreHardwareMonitor Web 服务 `127.0.0.1:8085/data.json`，读取 `Core Max` | LHM 必须以管理员身份运行，否则显示 `--°C` |
| GPU 温度、显存 | `nvidia-smi -lms 3000` 常驻子进程 | 只支持 NVIDIA；子进程用 Job 对象绑定，HUD 退出时一起结束 |
| 内存、磁盘、网络 | 性能计数器 | 磁盘默认统计全部磁盘，活动时间取各盘中最高的；网络默认取流量最大的一块网卡；两者都可以在菜单里指定 |
| Claude 5h / 7d | 优先读 `~/.claude.json` 的 `cachedUsageUtilization`（Claude Code 自己的缓存）；超过 5 分钟才用 `~/.claude/.credentials.json` 的令牌请求 `api.anthropic.com/api/oauth/usage`，限流时加倍退避到 30 分钟，结果缓存在 `%LOCALAPPDATA%\term-hud\usage.json` | 只在选中的标签是 Claude Code 时显示；达到 95% 时标红并显示重置时间；已过重置时间显示 `N/A`。不改 Claude Code 配置 |
| Claude 上下文 | `~/.claude/projects/*/*.jsonl` 尾部：用 `ai-title` 匹配标签标题，取最后一条回复的输入、缓存与输出 token 之和，按 Claude Code 的阈值（窗口 − 20000 − 13000，窗口取 `~/.claude/settings.json` 的 `autoCompactWindow` 与模型窗口中较小的）算距自动压缩的进度 | 与 Claude Code 的 “N% until auto-compact” 相加为 100%；后台线程每 10 秒枚举最近两天的会话，其间只复查已知文件的修改时间 |

LibreHardwareMonitor 由 winget 安装。配置已改为：开启 Web 服务（端口 8085，`listenerIp` 设为 `127.0.0.1`），启动时最小化到托盘。LHM 实际仍监听所有网卡，Tailscale 上的其他设备能读到传感器数据，这一点是认可的。改动前的配置备份在同目录下的 `LibreHardwareMonitor.config.bak-20261014`。开机自启需要在 LHM 的“Options → Run On Windows Startup”里勾选一次。
