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

## 本地 CI

需要 Windows、64 位 PowerShell 7、Git；full 还需要 Windows Terminal 和可交互桌面。

```powershell
pwsh -NoProfile -File scripts/ci.ps1          # fast：纯逻辑、原生代码编译、回归检查
pwsh -NoProfile -File scripts/ci.ps1 -Full    # full：再跑真实 WT 的 UI 检查
git config core.hooksPath .githooks          # 可选：pre-commit 跑 fast，pre-push 跑 full
```

full 创建名为 `term-hud-ci` 的独立 WT 窗口，使用隔离的设置、会话和模拟额度；不启动 Claude，也不读取登录凭据。测试期间保持该窗口在前台，不操作鼠标或切窗口；结束时关闭测试窗口并恢复鼠标和原前台窗口。覆盖实际拖拽、按住停留、双击、标签切换、缩放、遮挡、最小化、置顶，以及 Clawd、5h、7d 的布局和截图。不要与另一轮 full 同时运行。

2026-10-14 本机实测：fast **33 项 / 2.7 秒**，full **59 项 / 25.9 秒**（其中真实 UI 26 项）；Windows Terminal 1.24.12741.0，3840×2160、225% 缩放。标题栏与 HUD 两种拖拽在松手后分别用 732 ms、1087 ms 恢复。正式进程另行验证了 Clawd 与实际账户的 **5h 28%、7d 25%**，截图见 `build/ci/live-title.png`；CI 模拟数据截图见 `build/ci/ui/claude-initial.png`。跨显示器 DPI 切换尚未做硬件实测。

CI 负责 `build/ci/` 下的日志、截图、隔离数据和 `full-passed` 通过凭证；它们不入库，下一次运行复用并覆盖。full 对运行前后包含未提交文件的 Git tree 做一致性检查，成功后才记录凭证，不改变暂存区。pre-push 检查每个推送提交的内容；与凭证相比仅 Markdown 不同时复用结果，其余改动重新验收。推送内容与当前工作区不一致时会拒绝用工作区的结果代替。

NAS 私有仓库使用远端 `nas`（`nas-git:root/pwsh-hud.git`），`main` 跟踪 `nas/main`。后续发布到 GitHub 时可另加 `origin`。目前执行本地 CI 和 Git hooks，尚未部署远端工作流。

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
