# term-hud

[English](#english) · [中文](#中文)

A tiny resource monitor that lives in the empty space of the Windows Terminal title bar, between the tabs and the window buttons.

一个嵌在 Windows Terminal 标题栏空白处（标签和窗口按钮之间）的资源监视器。

![Resource view](docs/images/hud-resources.png)

![Claude Code view](docs/images/hud-claude.png)

---

## English

### What it shows

- **CPU**: utilization (same source as Task Manager), hottest core temperature, current frequency. Turns orange and prefixes the frequency with `↓` when the CPU is power or thermal limited, or at 90 °C or above.
- **MEM**: usage percent, used / total.
- **GPU** (NVIDIA only): utilization, temperature, VRAM used / total.
- **DSK**: active time, read and write rate.
- **NET**: download, upload, link speed.
- **Claude Code** (only when the selected tab is Claude Code): a one-line Clawd icon, 5-hour and 7-day usage of the default `~/.claude` account, and the session's progress toward auto-compact as a pie, a bar and a percentage. Usage turns red at 95% and shows the reset time; expired windows show `N/A`.

Layout is density first: entries are paired into two-row columns (CPU over MEM, GPU over DSK), and when space runs out they are dropped one at a time, lowest priority first (NET, DSK, MEM, Claude, GPU, CPU). Data refreshes every 3 seconds.

With several Windows Terminal windows open, the full HUD goes on the largest one (ties go to the top-right one). Any other window whose selected tab is Claude Code shows its own Claude column.

### Requirements

| Needed for | Dependency |
|---|---|
| Everything | Windows 10 / 11, [Windows Terminal](https://aka.ms/terminal), [PowerShell 7](https://aka.ms/powershell) (64-bit) |
| CPU temperature and package power | [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) running **as administrator** with its web server enabled on port 8085 (Options → Remote Web Server → Run) |
| GPU column | NVIDIA driver (`nvidia-smi` on `PATH`) |
| Claude column | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) logged in with the default `~/.claude` config |

Missing sources just show `--`; everything else keeps working.

### Run

```powershell
git clone https://github.com/Yongzhaooo/term-hud.git
cd term-hud
pwsh -NoProfile -File .\term-hud.ps1          # runs in the foreground; only one instance at a time
pwsh -NoProfile -File .\term-hud.ps1 -Test    # self-test of the pure logic
```

Start at login without a console window by adding a shortcut to the Startup folder:

```powershell
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut("$([Environment]::GetFolderPath('Startup'))\term-hud.lnk")
$lnk.TargetPath = 'conhost.exe'
$lnk.Arguments = "--headless `"$((Get-Command pwsh).Source)`" -NoProfile -File `"$PWD\term-hud.ps1`""
$lnk.Save()
```

### Use

- **Right-click** the HUD to toggle entries, pick which disks and network adapters to count, turn on "Always on top", or exit. Choices are saved in `%APPDATA%\term-hud\settings.json`. Menus follow the system UI language (Chinese or English).
- **Drag** the HUD to move the terminal; **double-click** to maximize or restore it.
- By default the HUD only shows while the title bar is visible, and hides while the window is being dragged or resized.
- The last timer error, if any, is written to `%LOCALAPPDATA%\term-hud\error.log`.

### Privacy

- The Claude column first reads the usage that Claude Code itself caches in `~/.claude.json`, so normally no request is made. Only when that cache is older than 5 minutes does it call `api.anthropic.com/api/oauth/usage` with the token from `~/.claude/.credentials.json`. That call costs no tokens; it backs off up to 30 minutes when rate limited. The token is sent nowhere else and is never stored or refreshed by term-hud. No Claude Code settings are changed.
- Context usage is read from the tail of the session transcripts in `~/.claude/projects/`.
- LibreHardwareMonitor's web server listens on all interfaces, so other machines on your network can read the sensor data. Add a firewall rule if that matters to you.

### Known issues

- Dragging the terminal window can still feel a bit laggy.
- Detecting which terminal window to attach to, and where its tabs end, is still not very reliable.
- Windows only. It depends on Windows Terminal, PowerShell 7, Win32 / UI Automation, Windows performance counters, and optionally LibreHardwareMonitor and `nvidia-smi`. Cross-monitor DPI changes have not been tested on real hardware.

### Contributing

Help is very welcome: bug reports, fixes, and ideas. Porting it to Linux (or to other terminals) would be great too. Pull requests are welcome.

Before sending a PR:

```powershell
pwsh -NoProfile -File scripts/ci.ps1          # fast tier: pure logic, native compile, regressions
pwsh -NoProfile -File scripts/ci.ps1 -Full    # full tier: real Windows Terminal UI checks
```

The full tier opens its own `term-hud-ci` terminal window with isolated settings and fake usage data (no Claude account is used). Leave the mouse alone for about 30 seconds while it runs. Logs and screenshots go to `build/ci/`. `git config core.hooksPath .githooks` runs the fast tier before each commit and the full tier before each push.

The product spec, in Chinese, is in [docs/product.md](docs/product.md).

### License

[GPL-3.0](LICENSE). Copyright © 2026 Yongzhao Chen.

---

## 中文

### 显示内容

- **CPU**：总占用（与任务管理器同源）、核心最高温度、当前频率。被功耗或温度限制、或温度达到 90 °C 时变橙，频率前加 `↓`。
- **MEM**：占用百分比、已用 / 总量。
- **GPU**（仅 NVIDIA）：占用、温度、显存已用 / 总量。
- **DSK**：活动时间、读写速率。
- **NET**：下行、上行、链路速率。
- **Claude Code**（仅当选中的标签是 Claude Code）：一行高的 Clawd 图标，默认 `~/.claude` 账户的 5 小时和 7 天额度，以及当前会话距自动压缩的进度（饼图、长条和百分比）。额度达到 95% 时标红并显示重置时间，已过期显示 `N/A`。

布局以信息密度优先：条目两两叠成两行一列（CPU 叠 MEM，GPU 叠 DSK）。空间不够时按优先级从低到高逐条收起：NET、DSK、MEM、Claude、GPU、CPU。数据每 3 秒刷新一次。

开着多个 Windows Terminal 窗口时，完整 HUD 显示在最大的那个上，面积相近时选最靠右上角的。其他窗口如果选中的是 Claude Code 标签，会单独显示自己的 Claude 列。

### 依赖

| 用途 | 依赖 |
|---|---|
| 全部功能 | Windows 10 / 11、[Windows Terminal](https://aka.ms/terminal)、[PowerShell 7](https://aka.ms/powershell)（64 位） |
| CPU 温度和封装功耗 | [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)，需**以管理员身份**运行并开启 8085 端口的 Web 服务（Options → Remote Web Server → Run） |
| GPU 列 | NVIDIA 驱动（`PATH` 中有 `nvidia-smi`） |
| Claude 列 | 已登录的 [Claude Code](https://docs.anthropic.com/en/docs/claude-code)，使用默认的 `~/.claude` 配置 |

缺少某个数据源时，对应格子显示 `--`，其他条目照常工作。

### 运行

```powershell
git clone https://github.com/Yongzhaooo/term-hud.git
cd term-hud
pwsh -NoProfile -File .\term-hud.ps1          # 前台运行，同时只允许一个实例
pwsh -NoProfile -File .\term-hud.ps1 -Test    # 自检纯逻辑
```

开机自启、不弹控制台窗口：在“启动”文件夹里建一个快捷方式。

```powershell
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut("$([Environment]::GetFolderPath('Startup'))\term-hud.lnk")
$lnk.TargetPath = 'conhost.exe'
$lnk.Arguments = "--headless `"$((Get-Command pwsh).Source)`" -NoProfile -File `"$PWD\term-hud.ps1`""
$lnk.Save()
```

### 操作

- **右键** HUD：勾选要显示的条目，选择统计哪些磁盘和网卡，开关“始终显示（置顶）”，或退出。设置保存在 `%APPDATA%\term-hud\settings.json`。菜单按系统界面语言显示中文或英文。
- 在 HUD 上**拖动**可以移动终端窗口，**双击**最大化或还原。
- 默认只在标题栏可见时显示，拖动或缩放窗口期间隐藏。
- 定时器的最近一次异常写在 `%LOCALAPPDATA%\term-hud\error.log`。

### 隐私

- Claude 列优先读取 Claude Code 自己缓存在 `~/.claude.json` 里的用量，通常不发任何请求。缓存超过 5 分钟时，才用 `~/.claude/.credentials.json` 里的令牌请求一次 `api.anthropic.com/api/oauth/usage`。这个请求不消耗 token，被限流时逐次退避，最长 30 分钟。令牌不会发往其他地方，term-hud 也不保存、不刷新令牌，不改动 Claude Code 的任何设置。
- 上下文用量读取自 `~/.claude/projects/` 下会话记录的尾部。
- LibreHardwareMonitor 的 Web 服务监听所有网卡，同一网络里的其他设备能读到传感器数据。介意的话请自行加防火墙规则。

### 已知问题

- 拖动终端窗口时仍有些卡顿。
- 自动识别该挂在哪个终端窗口、以及标签栏右边界的准确度还不够好。
- 只支持 Windows：依赖 Windows Terminal、PowerShell 7、Win32 / UI Automation、Windows 性能计数器，可选依赖 LibreHardwareMonitor 和 `nvidia-smi`。跨显示器 DPI 切换还没在真机上测过。

### 参与开发

欢迎一起完善：报 bug、修问题、提想法都可以。也非常欢迎把它移植到 Linux 或其他终端上。欢迎 PR。

提交 PR 前请跑一下本地 CI：

```powershell
pwsh -NoProfile -File scripts/ci.ps1          # fast：纯逻辑、原生代码编译、回归检查
pwsh -NoProfile -File scripts/ci.ps1 -Full    # full：在真实 Windows Terminal 上做 UI 检查
```

full 会打开一个独立的 `term-hud-ci` 终端窗口，使用隔离的设置和模拟额度，不使用任何 Claude 账户。运行的大约 30 秒内请不要动鼠标。日志和截图在 `build/ci/` 下。执行 `git config core.hooksPath .githooks` 后，每次提交前会自动跑 fast，推送前跑 full。

产品 spec 见 [docs/product.md](docs/product.md)（中文）。

### 许可证

[GPL-3.0](LICENSE)。Copyright © 2026 Yongzhao Chen。
