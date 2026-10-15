# term-hud architecture

Last confirmed: not yet confirmed
Product spec: [product.md](product.md)

## Target structure

目标是保留独立、普通权限的 PowerShell HUD，附着于 Windows Terminal 标题栏的可用区域。`term-hud.ps1` 包含 PowerShell 数据采样与内嵌 C# 窗口逻辑；后台读取 UI Automation、硬件数据和 Claude 会话，界面线程消费快照并绘制，不同步阻塞 WT。窗口不建立跨进程 owner，也不共享输入队列。

系统性能计数器、NVIDIA 工具和 LibreHardwareMonitor 各自拥有原始传感数据；HUD 缺少来源时显示 `--`。Claude 账户用量优先读本地缓存，过期才向官方接口请求；独立 HTTP 客户端隔离账户令牌与本地传感器请求。用户设置属于 `%APPDATA%/term-hud/settings.json`，运行文件和错误日志属于 `%LOCALAPPDATA%/term-hud/`，不进入源码。

`install.ps1` 管理用户安装、启动快捷方式及可选 LHM 服务配置。`scripts/ci.ps1` 用隔离设置与假用量验证逻辑和真实 WT 交互。详细刷新周期、布局优先级、隐藏条件由产品文档维护。

## Approach

继续使用现有 PowerShell/C# 单进程边界，避免为标题栏显示引入额外桌面框架或服务。后台快照让来源变化局限于采样侧；相对 WT 的坐标缓存须绑定尺寸、DPI 和标题，过期结果不得直接用于新窗口状态。

## Route

1. 当前已有安装、资源与 Claude 显示和本地 CI；历史验收见产品文档 Known issues。
2. (proposed) 收敛拖动卡顿及目标窗口/标签边界识别。通过专用 WT 的 full CI，并在实际多窗口使用中确认不遮挡标签、拖动后及时恢复。
3. (proposed) 验证跨显示器 DPI 切换；在不同缩放比例下确认定位、可用宽度及点击行为，再更新支持范围。

这条路线不要求迁移用户设置。若后续改变设置格式，应保留旧值可读和可回退安装；当前不新增格式。

## Open decisions

Claude 未显式记录模型窗口时的推断可靠性仍未解决，阻塞上下文百分比的完整可信承诺。其他未确认阈值以产品文档 `(proposed)` 项为准。
