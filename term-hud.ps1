# term-hud：在 Windows Terminal 标题栏右侧空白处显示资源状态。产品预期见 docs/product.md。
# 数据源：系统性能计数器；CPU 温度来自 LibreHardwareMonitor 本地 Web 服务；GPU 来自 nvidia-smi；
# Claude 额度来自本机 Claude Code 登录凭据对应的 /api/oauth/usage。
param([switch]$Test)

$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$ClaudeTitle = '^[·✢✳✶✻✽◐◓◑◒]'  # Claude Code 写在标签标题开头的状态符号
$ClaudeRed = 95                  # 额度达到该百分比时标红并显示重置时间
$Zh = [Globalization.CultureInfo]::CurrentUICulture.Name -like 'zh*'
function L($zh, $en) { if ($Zh) { $zh } else { $en } }

# LHM 的 data.json 约 90 KB：用正则直接取传感器值，不整份解析。° 在原文里转义为 \u00B0
$DegC = '(?:°|\\u00B0)C'
function Find-Value($raw, $name, $unit) {
    $m = [regex]::Match($raw, '"Text":"' + [regex]::Escape($name) + '"[^{}]*?"Value":"([\d.,]+) ' + $unit + '"')
    if ($m.Success) { [double]($m.Groups[1].Value -replace ',', '.') }
}
function Find-Temp($raw) {
    foreach ($n in 'Core Max', 'Core (Tctl/Tdie)', 'CPU Package') { $v = Find-Value $raw $n $DegC; if ($null -ne $v) { return $v } }
}
# 面积最大的窗口；面积相差不到 5% 时取最靠右上角的
function Select-Target($wins) {
    $wins = @($wins); if (-not $wins) { return }
    $max = ($wins | ForEach-Object { ($_.R - $_.L) * ($_.B - $_.T) } | Measure-Object -Maximum).Maximum
    @($wins | Where-Object { ($_.R - $_.L) * ($_.B - $_.T) -ge $max * 0.95 } | Sort-Object { $_.R - $_.T } -Descending)[0]
}
# 单行条目两两叠成一列；落单的条目改用自己的两行排法（Tall），不留空行；带 Rows 的条目（Claude）自成一列
function New-Col($its) {
    $its = @($its); $colors = [object[]]::new($its.Count)  # 逐行保留空颜色；用管道收集会丢掉 $null，颜色就错位了
    for ($i = 0; $i -lt $its.Count; $i++) { $colors[$i] = $its[$i].Color }
    [pscustomobject]@{ Rows = @($its | ForEach-Object { , $_.Fields }); Colors = $colors; SubX = @(); W = 0; X = 0 }
}
function New-Single($it) {
    if (-not $it.Tall) { return New-Col @($it) }
    New-Col @($it.Tall | ForEach-Object { [pscustomobject]@{ Fields = $_; Color = $it.Color } })
}
function Group-Items($items) {
    $cols = [Collections.Generic.List[object]]::new(); $buf = [Collections.Generic.List[object]]::new()
    $flush = { if ($buf.Count -eq 1) { $cols.Add((New-Single $buf[0])) } elseif ($buf.Count) { $cols.Add((New-Col $buf)) }; $buf.Clear() }
    foreach ($it in $items) {
        if ($it.Rows) { . $flush; $cols.Add((New-Col $it.Rows)); continue }
        $buf.Add($it); if ($buf.Count -eq 2) { . $flush }
    }
    . $flush
    , $cols.ToArray()
}
# 列内子列：同一位置的字段左对齐；空格按数字宽度计，数值位数变化时列宽不跳。
# 带 Span 的字段（长条、重置时间）铺满它跨过的子列，不参与定宽
function Measure-Column($col, [scriptblock]$measure, $subGap) {
    $n = ($col.Rows | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
    $x = 0; $col.SubX = @()
    for ($i = 0; $i -lt $n; $i++) {
        $w = ($col.Rows | ForEach-Object { $f = if ($i -lt $_.Count) { $_[$i] }; if ($f -is [string]) { if ($f) { & $measure ($f -replace ' ', '0') } else { 0 } } elseif ($f -and -not $f.Span) { & $measure $f } else { 0 } } | Measure-Object -Maximum).Maximum
        $col.SubX += $x; if ($w) { $x += $w + $subGap }
    }
    $col.W = $x - $subGap
}
# 放不下时按优先级从低到高去掉条目，重新配对后再量，直到放得下
function Fit-Items($items, $avail, $gap, [scriptblock]$measureCol) {
    $kept = [Collections.Generic.List[object]]::new(); foreach ($i in $items) { $kept.Add($i) }
    while ($kept.Count) {
        $cols = Group-Items $kept
        foreach ($c in $cols) { & $measureCol $c }
        if (($cols | Measure-Object W -Sum).Sum + $gap * ($cols.Count - 1) -le $avail) { return , $cols }
        [void]$kept.Remove(($kept | Sort-Object Prio)[0])
    }
    , @()
}
# 会话文件尾部：最后的 ai-title（与标签标题一致）和最后一条回复的上下文 token 数
function Read-SessionTail($path, $prev) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try { $n = [int][math]::Min($fs.Length, 512KB); [void]$fs.Seek(-$n, 'End'); $buf = [byte[]]::new($n); [void]$fs.Read($buf, 0, $n) } finally { $fs.Dispose() }
    $lines = [Text.Encoding]::UTF8.GetString($buf) -split "`n"
    $r = @{ Title = $prev.Title; Used = $prev.Used; Model = $prev.Model }; $gotT = $false; $gotU = $false
    for ($i = $lines.Count - 1; $i -ge 1 -and -not ($gotT -and $gotU); $i--) {  # 第 0 行可能被截断
        $l = $lines[$i]
        if (-not $gotT -and $l.Contains('"type":"ai-title"')) { $r.Title = ($l | ConvertFrom-Json).aiTitle; $gotT = $true }
        elseif (-not $gotU -and $l.Contains('"type":"assistant"') -and $l.Contains('"usage"')) {
            $m = ($l | ConvertFrom-Json).message; $u = $m.usage
            $r.Used = $u.input_tokens + $u.cache_creation_input_tokens + $u.cache_read_input_tokens + $u.output_tokens; $r.Model = $m.model; $gotU = $true  # 输出也会进入下一轮上下文
        }
    }
    $r
}
# shortcut: 会话文件不记录上下文窗口大小，按型号推断（5 代与 [1m] 为 1M，其余 200K）；型号规则变化时更新
function Get-ModelWindow($used, $model) {
    if ($model -match 'opus-5|sonnet-5|fable-5|\[1m\]' -or $used -gt 200000) { 1000000 } else { 200000 }
}
# 距自动压缩的进度，与 Claude Code 的 “N% until auto-compact” 同算法：
# 窗口取 autoCompactWindow（不超过模型窗口）；阈值 = 窗口 − 20000（输出预留）− 13000（缓冲）
function Get-CompactPct($used, $window, $acWindow) {
    $win = if ($acWindow -gt 0) { [math]::Min($acWindow, $window) } else { $window }
    $th = $win - 20000 - 13000
    [math]::Min(100, [math]::Max(0, 100 - [math]::Round(($th - $used) / $th * 100, [MidpointRounding]::AwayFromZero)))
}
# Claude Code 启动横幅里的 Clawd，按四分块字符拆成像素（每个字符 2×2）
$ClawdArt = ' ▐▛███▜▌', '▝▜█████▛▘', '  ▘▘ ▝▝'
function Get-ClawdPixels {
    $q = @{ ' ' = 0; '▐' = 5; '▌' = 10; '█' = 15; '▛' = 14; '▜' = 13; '▝' = 4; '▘' = 8; '▀' = 12; '▄' = 3; '▖' = 2; '▗' = 1 }  # 位：左上8 右上4 左下2 右下1
    for ($r = 0; $r -lt $ClawdArt.Count; $r++) {
        for ($c = 0; $c -lt $ClawdArt[$r].Length; $c++) {
            $b = $q[[string]$ClawdArt[$r][$c]]
            if ($b -band 8) { , @((2 * $c), (2 * $r)) }; if ($b -band 4) { , @((2 * $c + 1), (2 * $r)) }
            if ($b -band 2) { , @((2 * $c), (2 * $r + 1)) }; if ($b -band 1) { , @((2 * $c + 1), (2 * $r + 1)) }
        }
    }
}

if ($Test) {
    $j = '{"Text":"CPU","Children":[{"Text":"Load","Children":[{"id":1,"Text":"Core Max","Min":"1.0 %","Value":"40.0 %","Children":[]}]},{"Text":"Temperatures","Children":[{"id":2,"Text":"CPU Package","Value":"60.0 \u00B0C","Children":[]},{"id":3,"Text":"Core Max","Min":"50.0 \u00B0C","Value":"71.0 \u00B0C","Max":"99.0 \u00B0C","Children":[]}]},{"Text":"Powers","Children":[{"id":4,"Text":"CPU Package","Value":"144.7 W","Children":[]}]}]}'
    if ((Find-Temp $j) -ne 71) { throw "Find-Temp: $(Find-Temp $j)" }
    if ((Find-Value $j 'CPU Package' 'W') -ne 144.7) { throw 'Find-Value power' }
    if ($null -ne (Find-Temp '{"Text":"x","Children":[]}')) { throw 'Find-Temp should be empty' }
    $nc = New-Col @([pscustomobject]@{ Fields = @('a'); Color = $null }, [pscustomobject]@{ Fields = @('b'); Color = 'hot' })
    if ($null -ne $nc.Colors[0] -or $nc.Colors[1] -ne 'hot') { throw 'New-Col colors shifted' }
    $l = [pscustomobject]@{ H = 1; L = 0; T = 0; R = 1920; B = 2000 }; $r = [pscustomobject]@{ H = 2; L = 1920; T = 0; R = 3840; B = 2000 }
    if ((Select-Target $l, $r).H -ne 2) { throw 'equal size should pick right' }
    $top = [pscustomobject]@{ H = 3; L = 0; T = 0; R = 3840; B = 1000 }; $bot = [pscustomobject]@{ H = 4; L = 0; T = 1000; R = 3840; B = 2000 }
    if ((Select-Target $bot, $top).H -ne 3) { throw 'equal size should pick top' }
    $big = [pscustomobject]@{ H = 5; L = 0; T = 0; R = 2400; B = 2000 }
    if ((Select-Target $r, $big).H -ne 5) { throw 'larger should win' }
    if ('◐ task' -notmatch $ClaudeTitle -or '✳ Claude Code' -notmatch $ClaudeTitle -or 'pwsh' -match $ClaudeTitle) { throw 'claude title' }
    $c = [pscustomobject]@{ Rows = @(@('CPU', '9%  ', '5.3G'), @('MEM', '55% ', '34.7/64G')); SubX = @(); W = 0 }
    Measure-Column $c { param($s) "$s".Length } 1
    if (($c.SubX -join ',') -ne '0,4,9' -or $c.W -ne 17) { throw "Measure-Column: $($c.SubX -join ',') W=$($c.W)" }
    $it = @{ K = 'cpu'; Prio = 6 }, @{ K = 'mem'; Prio = 3 }, @{ K = 'gpu'; Prio = 5 }, @{ K = 'net'; Prio = 1 } | ForEach-Object { [pscustomobject]($_ + @{ Fields = @($_.K, '12345') }) }
    $mc = { param($c) Measure-Column $c { param($s) "$s".Length } 1 }
    $g = Group-Items $it
    if ($g.Count -ne 2 -or ($g[0].Rows | ForEach-Object { $_[0] }) -join ',' -ne 'cpu,mem') { throw 'pairing' }
    if ((Fit-Items $it 100 2 $mc).Count -ne 2) { throw 'all should fit' }
    $f = Fit-Items $it 9 2 $mc   # 一列宽 9：只剩一列两条，去掉 net 和 mem
    if ($f.Count -ne 1 -or ($f[0].Rows | ForEach-Object { $_[0] }) -join ',' -ne 'cpu,gpu') { throw "drop order: $(($f.Rows | ForEach-Object { $_[0] }) -join ',')" }
    if ((Fit-Items $it 3 2 $mc).Count -ne 0) { throw 'nothing fits' }
    $tmp = [IO.Path]::GetTempFileName()
    Set-Content $tmp -Encoding utf8 -Value @(
        '{"type":"ai-title","aiTitle":"旧标题"}'
        '{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":1000,"cache_read_input_tokens":99000,"output_tokens":500}}}'
        '{"type":"ai-title","aiTitle":"桌面悬浮资源检测器"}'
        '{"type":"user","message":{}}')
    $s = Read-SessionTail $tmp $null; Remove-Item $tmp
    if ($s.Title -ne '桌面悬浮资源检测器' -or $s.Used -ne 100502 -or $s.Model -ne 'claude-opus-5-5') { throw "Read-SessionTail: $($s | ConvertTo-Json -Compress)" }
    if ((Get-ModelWindow 100000 'claude-opus-5-5') -ne 1000000 -or (Get-ModelWindow 100000 'claude-haiku-4-5-20251001') -ne 200000 -or (Get-ModelWindow 300000 'x') -ne 1000000) { throw 'Get-ModelWindow' }
    if ((Get-CompactPct 448000 1000000 500000) -ne 96 -or (Get-CompactPct 445000 1000000 500000) -ne 95 -or (Get-CompactPct 83500 200000 $null) -ne 50) { throw "Get-CompactPct: $(Get-CompactPct 448000 1000000 500000)" }
    $net = [pscustomobject]@{ Prio = 1; Fields = @('NET', 'a', 'b'); Tall = @(@('↓', 'a'), @('↑', 'b')); Color = 'c' }
    $g = Group-Items @($it[0], $it[1], $net)
    if ($g.Count -ne 2 -or $g[1].Rows.Count -ne 2 -or $g[1].Rows[1][0] -ne '↑' -or $g[1].Colors[1] -ne 'c') { throw 'tall single' }
    $sp = [pscustomobject]@{ Rows = @(@('5h', '6%'), @(@{ Span = 2 })); SubX = @(); W = 0 }
    Measure-Column $sp { param($s) "$s".Length } 1
    if ($sp.W -ne 5) { throw "span should not widen: $($sp.W)" }
    $px = @(Get-ClawdPixels)
    if ($px.Count -ne 54 -or ($px | ForEach-Object { $_[0] } | Measure-Object -Maximum).Maximum -ne 16) { throw "Clawd pixels: $($px.Count)" }
    'OK (19 legacy checks)'; return
}

$mutex = [Threading.Mutex]::new($false, 'Local\term-hud')
if (-not $mutex.WaitOne(0)) { return }  # 已有实例在运行

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type -Namespace W -Name U -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr after, string c, string t);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
[DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int ht, uint f);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
[DllImport("user32.dll")] public static extern bool ReleaseCapture();
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, int m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);
[DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
[DllImport("user32.dll")] static extern uint SendInput(uint count, INPUT[] inputs, int size);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
[DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
[DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr dc, int x, int y);
[DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetProp(IntPtr h, string name);
[DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr process);
[DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
[DllImport("kernel32.dll")] static extern IntPtr CreateJobObject(IntPtr a, string n);
[DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j, int c, byte[] info, int len);
[DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
public struct RECT { public int L, T, R, B; }
public struct POINT { public int X, Y; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
struct MOUSEINPUT { public int X, Y; public uint Data, Flags, Time; public UIntPtr Extra; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit)]
struct INPUT { [System.Runtime.InteropServices.FieldOffset(0)] public uint Type; [System.Runtime.InteropServices.FieldOffset(8)] public MOUSEINPUT Mouse; }
struct GUITHREADINFO { public uint Size, Flags; public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret; public RECT CaretRect; }
// 拖动或缩放 WT 时先隐藏浮窗：线程池每 100 毫秒读一次各 WT 的位置（只读 DWM 属性，不给 WT 发消息），
// 变了就隐藏对应浮窗并记下时间；PowerShell 每秒的定时器在停稳后重新显示。放在 C# 里是因为高频调用 PowerShell 脚本块本身就很费 CPU。
[DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr h, int cmd);
static readonly System.Collections.Generic.Dictionary<IntPtr, IntPtr> watch = new System.Collections.Generic.Dictionary<IntPtr, IntPtr>();  // WT -> 浮窗
static readonly System.Collections.Generic.Dictionary<IntPtr, RECT> lastRect = new System.Collections.Generic.Dictionary<IntPtr, RECT>();
static readonly System.Collections.Generic.Dictionary<IntPtr, long> movedAt = new System.Collections.Generic.Dictionary<IntPtr, long>();
static readonly System.Collections.Generic.HashSet<IntPtr> settling = new System.Collections.Generic.HashSet<IntPtr>();
static readonly System.Collections.Generic.HashSet<IntPtr> pinned = new System.Collections.Generic.HashSet<IntPtr>();
public static readonly System.Threading.AutoResetEvent Changed = new System.Threading.AutoResetEvent(false);
static System.Threading.Timer moveTimer;
public static void Watch(IntPtr wt, IntPtr hud, bool pin) { lock (watch) {
    if (!watch.ContainsKey(wt)) { movedAt[wt] = Environment.TickCount64; settling.Add(wt); Changed.Set(); }
    watch[wt] = hud; if (pin) pinned.Add(wt); else pinned.Remove(wt);
    if (moveTimer == null) moveTimer = new System.Threading.Timer(_ => CheckMoves(), null, 100, 100);
} }
public static void Unwatch(IntPtr wt) { lock (watch) { watch.Remove(wt); lastRect.Remove(wt); movedAt.Remove(wt); settling.Remove(wt); pinned.Remove(wt); } }
public static bool InMoveSize(IntPtr wt) {
    var info = new GUITHREADINFO { Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<GUITHREADINFO>() };
    uint thread = GetWindowThreadProcessId(wt, IntPtr.Zero);
    return thread != 0 && GetGUIThreadInfo(thread, ref info) && info.MoveSize == wt && (info.Flags & 2) != 0;
}
public static bool Moving(IntPtr wt) { if (InMoveSize(wt)) return true; lock (watch) { long t; return movedAt.TryGetValue(wt, out t) && Environment.TickCount64 - t < 500; } }
public static void Above(IntPtr wt, IntPtr hud, bool pin) {
    IntPtr after = pin ? new IntPtr(-1) : GetWindow(wt, 3); // GW_HWNDPREV: insert immediately above WT without an owner/input-queue link.
    if (after != hud) SetWindowPos(hud, after, 0, 0, 0, 0, 0x10 | 0x1 | 0x2);
}
public static void BeginDrag(IntPtr wt, IntPtr hud) {
    ReleaseCapture();
    lock (watch) { movedAt[wt] = Environment.TickCount64; settling.Add(wt); }
    ShowWindow(hud, 0);
    POINT point;
    // PostMessage cannot update another input queue's button state; hand the held press to WT's native hit testing.
    if (GetAsyncKeyState(1) >= 0 || !GetCursorPos(out point) || GetAncestor(WindowFromPoint(point), 2) != wt) return;
    var inputs = new[] { new INPUT { Mouse = new MOUSEINPUT { Flags = 4 } }, new INPUT { Mouse = new MOUSEINPUT { Flags = 2 } } };
    SendInput(2, inputs, System.Runtime.InteropServices.Marshal.SizeOf<INPUT>());
}
static void CheckMoves() {
    System.Collections.Generic.KeyValuePair<IntPtr, IntPtr>[] entries;
    lock (watch) {
        entries = new System.Collections.Generic.KeyValuePair<IntPtr, IntPtr>[watch.Count];
        ((System.Collections.Generic.ICollection<System.Collections.Generic.KeyValuePair<IntPtr, IntPtr>>)watch).CopyTo(entries, 0);
    }
    foreach (var p in entries) {
        bool absent = !IsWindowVisible(p.Key) || IsIconic(p.Key);
        RECT r = default; if (!absent && DwmGetWindowAttribute(p.Key, 9, out r, 16) != 0) continue;
        bool dragging = !absent && InMoveSize(p.Key), hide = false;
        // Never hold the state lock across window-system calls: the UI thread also reads this state.
        lock (watch) {
            IntPtr current; if (!watch.TryGetValue(p.Key, out current) || current != p.Value) continue;
            if (absent) { hide = !pinned.Contains(p.Key); }
            else {
            RECT o; bool had = lastRect.TryGetValue(p.Key, out o); lastRect[p.Key] = r;
            if (dragging || (had && (o.L != r.L || o.T != r.T || o.R != r.R || o.B != r.B))) {
                movedAt[p.Key] = Environment.TickCount64; settling.Add(p.Key);
                hide = true;
            } else if (settling.Contains(p.Key) && Environment.TickCount64 - movedAt[p.Key] >= 500) { settling.Remove(p.Key); Changed.Set(); }
            }
        }
        if (hide && IsWindowVisible(p.Value)) ShowWindowAsync(p.Value, 0);
    }
}
// 子进程随本进程退出（含被强制结束），否则 nvidia-smi -lms 会成为孤儿常驻
public static void KillWithMe(IntPtr proc) {
    var j = CreateJobObject(IntPtr.Zero, null);
    var info = new byte[144];                         // JOBOBJECT_EXTENDED_LIMIT_INFORMATION (x64)
    BitConverter.GetBytes(0x2000).CopyTo(info, 16);   // LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    SetInformationJobObject(j, 9, info, info.Length);
    AssignProcessToJobObject(j, proc);
}
'@
[void][W.U]::SetProcessDpiAwarenessContext([IntPtr]-4)  # 按物理像素定位，和 WT 窗口坐标一致

# ---------- 数据源 ----------
function New-Counter($cat, $name, $inst = '') { $c = [Diagnostics.PerformanceCounter]::new($cat, $name, $inst, $true); [void]$c.NextValue(); $c }
function Instances($cat) { [Diagnostics.PerformanceCounterCategory]::new($cat).GetInstanceNames() | Where-Object { $_ -ne '_Total' } | Sort-Object }
$cpu   = New-Counter 'Processor Information' '% Processor Utility' '_Total'  # 与任务管理器的 CPU 利用率同源
$perf  = New-Counter 'Processor Information' '% Processor Performance' '_Total'
$limit = New-Counter 'Processor Information' '% Performance Limit' '_Total'
$avail = New-Counter 'Memory' 'Available MBytes'
# shortcut: 磁盘和网卡列表只在启动时取一次，热插拔的设备要重启 HUD 才会计入
$disks = [ordered]@{}; foreach ($i in Instances 'PhysicalDisk') { $disks[$i] = @((New-Counter 'PhysicalDisk' 'Disk Read Bytes/sec' $i), (New-Counter 'PhysicalDisk' 'Disk Write Bytes/sec' $i), (New-Counter 'PhysicalDisk' '% Idle Time' $i)) }
$nics  = [ordered]@{}; foreach ($i in Instances 'Network Interface') { $nics[$i] = @((New-Counter 'Network Interface' 'Bytes Received/sec' $i), (New-Counter 'Network Interface' 'Bytes Sent/sec' $i), (New-Counter 'Network Interface' 'Current Bandwidth' $i)) }
$totalGB = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
$baseMHz = (Get-CimInstance Win32_Processor | Select-Object -First 1).MaxClockSpeed

# GPU 只支持 NVIDIA（nvidia-smi），用户已确认够用
$script:smi = $null; $script:smiLine = $null
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $psi = [Diagnostics.ProcessStartInfo]@{ FileName = 'nvidia-smi'; Arguments = '--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits -lms 3000'; RedirectStandardOutput = $true; UseShellExecute = $false; CreateNoWindow = $true }
    $script:smi = [Diagnostics.Process]::Start($psi); [W.U]::KillWithMe($script:smi.Handle)
    $script:smiTask = $script:smi.StandardOutput.ReadLineAsync()
}

# 异步请求：每次 tick 只取已完成的结果，不阻塞界面
$http = [Net.Http.HttpClient]@{ Timeout = [TimeSpan]::FromSeconds(10) }
$claudeHttp = [Net.Http.HttpClient]@{ Timeout = [TimeSpan]::FromSeconds(10) }
$claudeHttp.DefaultRequestHeaders.Add('anthropic-beta', 'oauth-2025-04-20')
$script:async = @{}
# -Keep：失败时保留上次的值，并把下次请求的间隔翻倍（最长 30 分钟），成功后恢复；用于有限流的接口
function Update-Async($name, $everySec, [scriptblock]$start, [switch]$Keep) {
    if (-not $script:async[$name]) { $script:async[$name] = @{ At = [DateTime]::MinValue; Wait = $everySec } }
    $s = $script:async[$name]
    if ($s.Task -and $s.Task.IsCompleted) {
        if ($s.Task.Status -eq 'RanToCompletion') { $s.Value = $s.Task.Result; $s.Wait = $everySec; $s.Ok = $true }
        elseif ($Keep) { $s.Wait = [math]::Min(1800, 2 * $s.Wait) }
        else { $s.Value = $null }
        $s.Task = $null
    }
    if (-not $s.Task -and ([DateTime]::Now - $s.At).TotalSeconds -ge $s.Wait) {
        $s.At = [DateTime]::Now; $s.Task = try { & $start } catch { $null }
    }
    $s.Value
}
$lhm = { $http.GetStringAsync('http://127.0.0.1:8085/data.json') }
$claude = {
    # 只读默认 ~/.claude 的账户，用户已确认够用
    $tok = (Get-Content (Join-Path $HOME '.claude\.credentials.json') -Raw -Encoding utf8 | ConvertFrom-Json).claudeAiOauth.accessToken
    $claudeHttp.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $tok)
    $claudeHttp.GetStringAsync('https://api.anthropic.com/api/oauth/usage')
}
# 额度接口有限流（429）：每 5 分钟查一次；成功结果存盘，重启后先用缓存，未到间隔不重复请求
$ClaudeEvery = 300
$usageCache = Join-Path $env:LOCALAPPDATA 'term-hud\usage.json'
if (Test-Path $usageCache) { $script:async['claude'] = @{ At = (Get-Item $usageCache).LastWriteTime; Wait = $ClaudeEvery; Value = (Get-Content $usageCache -Raw -Encoding utf8) } }

# ---------- 设置 ----------
$names = [ordered]@{ cpu = 'CPU'; gpu = 'GPU'; mem = (L '内存' 'Memory'); disk = (L '磁盘' 'Disk'); net = (L '网络' 'Network'); claude = (L 'Claude 额度' 'Claude usage') }
$cfgPath = Join-Path $env:APPDATA 'term-hud\settings.json'
$cfg = try { Get-Content $cfgPath -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json } catch { $null }
$script:show  = if ($cfg.show) { @($cfg.show) } else { @($names.Keys) }
$script:pickD = @($cfg.disks | Where-Object { $_ -and $disks.Contains($_) })  # 空 = 全部磁盘
$script:pinned = [bool]$cfg.pinned                                  # 始终显示：置顶，不随 WT 遮挡或最小化隐藏
$script:pickN = @($cfg.nics | Where-Object { $_ -and $nics.Contains($_) })    # 空 = 自动取流量最大的网卡
function Save-Settings {
    [void](New-Item -ItemType Directory -Force (Split-Path $cfgPath))
    @{ show = $script:show; disks = $script:pickD; nics = $script:pickN; pinned = $script:pinned } | ConvertTo-Json | Set-Content $cfgPath -Encoding utf8
}

# ---------- 窗口 ----------
$WtClass = 'CASCADIA_HOSTING_WINDOW_CLASS'
function Get-WtWindow($hw) {
    $r = [W.U+RECT]::new()
    if ([W.U]::DwmGetWindowAttribute($hw, 9, [ref]$r, 16) -ne 0) { return }
    $sb = [Text.StringBuilder]::new(256); [void][W.U]::GetWindowText($hw, $sb, 256)
    $dpi = [W.U]::GetDpiForWindow($hw)
    $title = $sb.ToString() -replace '^[·✢✳✶✻✽◐◓◑◒]', '*'
    $shape = "$($r.R - $r.L),$($r.B - $r.T),$dpi|$title"
    [pscustomobject]@{ H = $hw; L = $r.L; T = $r.T; R = $r.R; B = $r.B; Dpi = $dpi; Shape = $shape; Sig = "$($r.L),$($r.T)|$shape" }
}
function Get-WtWindows {
    $hw = [IntPtr]::Zero
    while (($hw = [W.U]::FindWindowEx([IntPtr]::Zero, $hw, $WtClass, [NullString]::Value)) -ne [IntPtr]::Zero) {
        if ([W.U]::GetProp($hw, "term-hud-ci") -ne [IntPtr]::Zero) { continue }  # 专用 CI 窗口由隔离的测试 HUD 接管。
        $cloaked = 0; [void][W.U]::DwmGetWindowAttribute($hw, 14, [ref]$cloaked, 4)  # 其他虚拟桌面上的窗口是 cloaked
        if (-not [W.U]::IsWindowVisible($hw) -or [W.U]::IsIconic($hw) -or $cloaked) { continue }
        Get-WtWindow $hw
    }
}
function Test-TabSnapshot($w, $tabs) { $tabs -and $tabs.Shape -eq $w.Shape -and $tabs.Bottom -gt 0 -and $tabs.Bottom -le 60 * $w.Dpi / 96 }
# ---------- 后台线程 ----------
# UI Automation 是跨进程同步调用，WT 忙时会卡住调用线程；放在界面线程上曾导致 HUD 无响应被系统关闭。
# 标签查询和会话文件扫描都在后台线程做，界面线程只读 $shared 里的最新结果。
$shared = [hashtable]::Synchronized(@{ Wins = @(); Tabs = @{}; Sessions = @(); AcWindow = 0; Stop = $false; Error = $null })
$worker = {
    param($shared, $readTail, $readWindow, $claudeDir)
    Set-Item function:Read-SessionTail ([scriptblock]::Create($readTail))
    Set-Item function:Get-WtWindow ([scriptblock]::Create($readWindow))
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $AutomationElement = [Windows.Automation.AutomationElement]; $CT = [Windows.Automation.ControlType]
    $tabCond = [Windows.Automation.OrCondition]::new(
        [Windows.Automation.PropertyCondition]::new($AutomationElement::ControlTypeProperty, $CT::TabItem),
        [Windows.Automation.PropertyCondition]::new($AutomationElement::ControlTypeProperty, $CT::Button),
        [Windows.Automation.PropertyCondition]::new($AutomationElement::ControlTypeProperty, $CT::SplitButton))
    $uia = @{}; $asked = @{}; $cache = @{}; $scanAt = [DateTime]::MinValue; $recent = @()
    $projects = Join-Path $claudeDir 'projects'
    while (-not $shared.Stop) {
        try {
            $tabs = @{}
            foreach ($key in @($shared.Wins)) {
                $w = Get-WtWindow ([IntPtr]$key)
                if (-not $w) { continue }
                if ([W.U]::IsIconic($w.H)) { if ($shared.Tabs[$key]) { $tabs[$key] = $shared.Tabs[$key] }; continue }
                # WT 的标签是 XAML 控件，只能经 UI Automation 取得位置和选中状态
                $old = $shared.Tabs[$key]; $askedEntry = $asked[$key]
                if ([W.U]::Moving($w.H)) { if ($old) { $tabs[$key] = $old }; continue }
                if ($old -and $old.Shape -eq $w.Shape -and ([DateTime]::Now - $askedEntry.At).TotalSeconds -lt 10) { $tabs[$key] = $old; continue }
                $info = @{ Right = 0; Selected = ''; Bottom = 0; Shape = $w.Shape }
                try {
                    if (-not $uia[$key]) { $uia[$key] = $AutomationElement::FromHandle($w.H) }
                    foreach ($e in $uia[$key].FindAll('Descendants', $tabCond)) {
                        $b = $e.Current.BoundingRectangle
                        if ($b.IsEmpty -or $b.Top -ge $w.T + 40 * $w.Dpi / 96) { continue }
                        # 最大化时窗口按钮进入 WT 的 UIA 树；它们不属于标签占用的宽度。
                        if ($e.Current.ControlType -ne $CT::TabItem -and $b.Right -gt $w.R - 138 * $w.Dpi / 96) { continue }
                        $info.Right = [math]::Max($info.Right, $b.Right - $w.L)
                        if ($e.Current.ControlType -eq $CT::TabItem) { $info.Bottom = [math]::Max($info.Bottom, $b.Bottom - $w.T) }
                        if ($e.Current.ControlType -eq $CT::TabItem -and $e.GetCurrentPropertyValue([Windows.Automation.SelectionItemPattern]::IsSelectedProperty)) { $info.Selected = $e.Current.Name }
                    }
                    if ((Get-WtWindow $w.H).Sig -eq $w.Sig -and -not [W.U]::Moving($w.H)) {
                        $tabs[$key] = $info; $asked[$key] = @{ At = [DateTime]::Now }
                    }
                } catch { $uia.Remove($key); $shared.Error = "UIA: $($_.Exception.Message)" }
            }
            $shared.Tabs = $tabs
            # 会话文件：每 10 秒用 .NET 枚举一次最近两天的会话（Get-ChildItem 遍历全部项目要几百毫秒）；
            # 其余轮次只复查已知文件的修改时间，有变化才读尾部
            if (([DateTime]::Now - $scanAt).TotalSeconds -ge 10) {
                $scanAt = [DateTime]::Now
                $recent = @(foreach ($d in [IO.Directory]::EnumerateDirectories($projects)) { foreach ($f in [IO.Directory]::EnumerateFiles($d, '*.jsonl')) { if ([IO.File]::GetLastWriteTime($f) -gt [DateTime]::Now.AddDays(-2)) { $f } } })
                $shared.AcWindow = try { [int64](Get-Content (Join-Path $claudeDir 'settings.json') -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json).autoCompactWindow } catch { 0 }
            }
            foreach ($f in $recent) {
                $st = [IO.File]::GetLastWriteTimeUtc($f); $c = $cache[$f]
                if ($c -and $c.Stamp -eq $st) { continue }
                try { $n = Read-SessionTail $f $c; $n.Stamp = $st; $cache[$f] = $n } catch {}
            }
            $shared.Sessions = @($cache.Values | Where-Object { $_.Title -and $_.Used })
        } catch { $shared.Error = "Worker: $($_.Exception.Message)" }
        [void][W.U]::Changed.WaitOne(2000)
    }
}
$bgWorker = [powershell]::Create()
[void]$bgWorker.AddScript($worker).AddArgument($shared).AddArgument(${function:Read-SessionTail}.ToString()).AddArgument(${function:Get-WtWindow}.ToString()).AddArgument((Join-Path $HOME '.claude'))
[void]$bgWorker.BeginInvoke()

$flags = [Windows.Forms.TextFormatFlags]'NoPadding, SingleLine'
$clawd = @(Get-ClawdPixels)
$orange = [Drawing.Color]::FromArgb(215, 119, 87)  # Claude 橙
$orangeBrush = [Drawing.SolidBrush]::new($orange)
$hot = [Drawing.Color]::Orange; $red = [Drawing.Color]::FromArgb(255, 85, 85); $script:dim = [Drawing.Color]::Gray
$LabelRe = '^([A-Z]{3}|\d[hd]|[↓↑RW])$'              # 列标签用暗色，数值用亮色

# 每种缩放一套字体与图标尺寸（多显示器 DPI 可能不同）
$script:metrics = @{}
function Get-Metrics($sc) {
    if (-not $script:metrics[$sc]) {
        $font = [Drawing.Font]::new('Cascadia Mono', 12 * $sc, [Drawing.GraphicsUnit]::Pixel); $lh = $font.Height
        $cw = [Windows.Forms.TextRenderer]::MeasureText('0000000000', $font, [Drawing.Size]::Empty, $flags).Width / 10
        $ph = [math]::Max(1, [int][math]::Floor($lh / 6))
        $script:metrics[$sc] = @{ Scale = $sc; Font = $font; Lh = $lh; CharW = $cw; Ph = $ph; Pw = [math]::Max(1, [int][math]::Round($ph * $cw / $lh)); Pie = [int]($lh * 0.7); SubGap = [int]($cw * 0.5) }
    }
    $script:metrics[$sc]
}
# 图标字段：Clawd 一行高，像素宽高比同终端字符格；饼图在同一子列里居中，与 Clawd 对齐
function Measure-Field($f) {
    if ($f -is [string]) { return [Windows.Forms.TextRenderer]::MeasureText($f, $script:m.Font, [Drawing.Size]::Empty, $flags).Width }
    if ($f.Icon -eq 'clawd') { 18 * $script:m.Pw } else { $script:m.Pie }
}
$paint = { param($s, $e)
    $hud = $s.Tag; $m = $hud.M; if (-not $m) { return }
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $lh = $m.Lh; $y0 = [int](($s.ClientSize.Height - 2 * $lh) / 2)
    foreach ($c in $hud.Layout) {
        for ($r = 0; $r -lt $c.Rows.Count; $r++) {
            $row = @($c.Rows[$r]); $y = $y0 + $r * $lh
            $color = $c.Colors[$r]; if (-not $color) { $color = $hud.Val }  # 未指定颜色的条目按背景取亮色
            for ($i = 0; $i -lt $row.Count; $i++) {
                $f = $row[$i]; $x = $c.X + $c.SubX[$i]
                # 子列宽：到下一子列（或跨过 Span 个子列）为止
                $j = $i + [math]::Max(1, [int]$f.Span)
                $cw = $(if ($j -lt $c.SubX.Count) { $c.SubX[$j] - $m.SubGap } else { $c.W }) - $c.SubX[$i]
                if ($f -is [string]) {
                    if ($f) { [Windows.Forms.TextRenderer]::DrawText($g, $f, $m.Font, [Drawing.Point]::new($x, $y), $(if ($f -cmatch $LabelRe) { $script:dim } else { $color }), $flags) }
                } elseif ($f.Icon -eq 'clawd') {
                    $top = $y + [int](($lh - 6 * $m.Ph) / 2)
                    foreach ($p in $clawd) { $g.FillRectangle($orangeBrush, $x + $p[0] * $m.Pw, $top + $p[1] * $m.Ph, $m.Pw, $m.Ph) }
                } elseif ($f.Icon -eq 'pie') {
                    $d = $m.Pie; $rc = [Drawing.Rectangle]::new($x + [int](($cw - $d) / 2), $y + [int](($lh - $d) / 2), $d, $d)
                    $g.FillPie($orangeBrush, $rc, -90, [float](3.6 * $f.Pct))
                    $g.DrawEllipse([Drawing.Pen]::new($orange, [math]::Max(1, $m.Scale)), $rc)
                } elseif ($f.Icon -eq 'bar') {
                    $bh = [int]($lh * 0.36); $by = $y + [int](($lh - $bh) / 2)
                    $g.FillRectangle([Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(70, $script:dim)), $x, $by, $cw, $bh)
                    $g.FillRectangle($orangeBrush, $x, $by, [int]($cw * $f.Pct / 100), $bh)
                } elseif ($f.Text) {
                    [Windows.Forms.TextRenderer]::DrawText($g, $f.Text, $m.Font, [Drawing.Point]::new($x, $y), $color, $flags)
                }
            }
        }
    }
}
# 左键拖动、双击最大化交给所在的 WT；右键弹设置菜单
$mouse = { param($s, $e)
    $wt = $s.Tag.Wt
    if ($e.Button -eq 'Right') { $menu.Show([Windows.Forms.Cursor]::Position); return }
    if ($e.Button -ne 'Left') { return }
    if ($e.Clicks -ge 2) { [void][W.U]::PostMessage($wt, 0x112, [IntPtr]$(if ([W.U]::IsZoomed($wt)) { 0xF120 } else { 0xF030 }), 0) }
    else { [W.U]::BeginDrag($wt, $s.Tag.H) }
}
# 每个 WT 窗口一个浮窗：最大的显示全部条目，其余只在选中 Claude 标签时显示该标签的 Claude 列
$huds = @{}
function New-Hud {
    $f = [Windows.Forms.Form]@{ FormBorderStyle = 'None'; ShowInTaskbar = $false; StartPosition = 'Manual' }
    $hh = $f.Handle
    [void][W.U]::SetWindowLongPtr($hh, -20, [IntPtr]([int64][W.U]::GetWindowLongPtr($hh, -20) -bor 0x80 -bor 0x08000000))  # 不进 Alt+Tab、不抢焦点
    $f.add_Paint($paint); $f.add_MouseDown($mouse)
    $f.Tag = @{ Form = $f; H = $hh; Wt = [IntPtr]::Zero; Pinned = $null; Layout = @(); Bounds = $null; Tabs = $null; M = $null; Val = [Drawing.Color]::Gainsboro }
    $f.Tag
}
function Hide-Hud($hud) { if ([W.U]::IsWindowVisible($hud.H)) { [void][W.U]::SetWindowPos($hud.H, [IntPtr]::Zero, 0, 0, 0, 0, 0x80 -bor 0x10 -bor 0x4 -bor 0x1 -bor 0x2) }; $hud.Shown = $false }
# 标题栏被其他窗口盖住：浮窗左右两侧的点不属于这个 WT
function Test-Covered($w, $left, $capLeft, $sc) {
    foreach ($x in ($left - [int](4 * $sc)), ($capLeft + [int](4 * $sc))) {
        $pt = [W.U+POINT]::new(); $pt.X = $x; $pt.Y = $w.T + [int](6 * $sc)
        if ([W.U]::GetAncestor([W.U]::WindowFromPoint($pt), 3) -ne $w.H) { return $true }  # GA_ROOTOWNER：WT 的标题按钮也是独立的 owned window。
    }
    $false
}
# ---------- 右键菜单 ----------
$menu = [Windows.Forms.ContextMenuStrip]::new()
foreach ($k in $names.Keys) {
    $it = [Windows.Forms.ToolStripMenuItem]@{ Text = $names[$k]; Tag = $k; CheckOnClick = $true; Checked = $script:show -contains $k }
    $it.add_CheckedChanged({ $script:show = @($menu.Items | Where-Object { $names.Contains("$($_.Tag)") -and $_.Checked } | ForEach-Object Tag); Save-Settings })
    [void]$menu.Items.Add($it)
}
# 磁盘/网卡子菜单：第一项是“全部/自动”，其余逐个勾选；一个都不勾时回到第一项
function Add-PickMenu($title, $allText, $keys, $var) {
    $sub = [Windows.Forms.ToolStripMenuItem]@{ Text = $title; Tag = $var }  # Tag 记住对应的脚本变量名
    [void]$sub.DropDownItems.Add([Windows.Forms.ToolStripMenuItem]@{ Text = $allText })
    [void]$sub.DropDownItems.Add([Windows.Forms.ToolStripSeparator]::new())
    foreach ($k in $keys) { [void]$sub.DropDownItems.Add([Windows.Forms.ToolStripMenuItem]@{ Text = $k; Tag = $k }) }
    $sub.add_DropDownOpening({ param($s)
        $p = (Get-Variable $s.Tag -Scope Script).Value
        $s.DropDownItems[0].Checked = -not $p
        foreach ($i in $s.DropDownItems) { if ($i.Tag) { $i.Checked = $p -contains $i.Tag } }
    })
    $sub.add_DropDownItemClicked({ param($s, $e)
        $p = @((Get-Variable $s.Tag -Scope Script).Value); $k = $e.ClickedItem.Tag
        $p = if (-not $k) { @() } elseif ($p -contains $k) { @($p | Where-Object { $_ -ne $k }) } else { $p + $k }
        Set-Variable $s.Tag $p -Scope Script; Save-Settings
    })
    [void]$menu.Items.Add($sub)
}
[void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
Add-PickMenu (L '选择磁盘' 'Disks') (L '全部磁盘' 'All disks') $disks.Keys 'pickD'
Add-PickMenu (L '选择网卡' 'Network adapters') (L '自动（流量最大）' 'Auto (busiest)') $nics.Keys 'pickN'
[void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
$pin = [Windows.Forms.ToolStripMenuItem]@{ Text = (L '始终显示（置顶）' 'Always on top'); CheckOnClick = $true; Checked = $script:pinned }
$pin.add_CheckedChanged({ param($s) $script:pinned = $s.Checked; Save-Settings }); [void]$menu.Items.Add($pin)
$quit = [Windows.Forms.ToolStripMenuItem]@{ Text = (L '退出' 'Exit') }; $quit.add_Click({ [Windows.Forms.Application]::Exit() }); [void]$menu.Items.Add($quit)


# ---------- 刷新 ----------
function Pct($v) { '{0,-4}' -f ('{0:N0}%' -f $v) }
function MBs($v) { '{0:N1}M' -f ($v / 1MB) }

# 资源条目：每 4 格，配对时上下对齐、不留空；落单时用 Tall 的两行排法。显示顺序即配对顺序，Prio 越小越先收起。
# Color 为空时按所在浮窗的背景取亮色
function Get-ResourceItems {
    $items = [Collections.Generic.List[object]]::new()
    function Item($key, $prio, $fields, $tall, $color) { if ($script:show -contains $key) { $items.Add([pscustomobject]@{ Prio = $prio; Fields = $fields; Tall = $tall; Color = $color }) } }

    $lim = $limit.NextValue(); $thr = $lim -lt 99.5
    $lj = Update-Async 'lhm' 0 $lhm
    $t = if ($lj) { Find-Temp $lj }
    $pw = if ($lj) { $v = Find-Value $lj 'CPU Package' 'W'; if ($null -ne $v) { '{0:N0}W' -f $v } }
    $ts = if ($t) { '{0:N0}°C' -f $t } else { '--°C' }
    $cu = Pct ([math]::Min(100, $cpu.NextValue()))
    $fq = $(if ($thr) { '↓' } else { '' }) + ('{0:N1}G' -f ($baseMHz * $perf.NextValue() / 100000))  # 降频时频率前加 ↓
    Item cpu 7 @('CPU', $cu, $ts, $fq) @(@('CPU', $cu, $fq), @('TMP', $ts, $(if ($pw) { $pw } else { '--W' }))) $(if ($thr -or $t -ge 90) { $hot })

    $mu = $totalGB - $avail.NextValue() / 1KB; $mp = Pct ($mu / $totalGB * 100)
    Item mem 4 @('MEM', $mp, ('{0:N1}G' -f $mu), ('/{0:N0}G' -f $totalGB)) @(@('MEM', $mp), @('USE', ('{0:N1}/{1:N0}G' -f $mu, $totalGB)))

    if ($script:smi) { while ($script:smiTask.IsCompleted -and $null -ne $script:smiTask.Result) { $script:smiLine = $script:smiTask.Result; $script:smiTask = $script:smi.StandardOutput.ReadLineAsync() } }
    $gv = if ($script:smiLine) { $script:smiLine -split ',\s*' | ForEach-Object { [double]$_ } }
    $gu = if ($gv) { Pct $gv[0] } else { '--' }; $gt = if ($gv) { '{0:N0}°C' -f $gv[1] } else { '--°C' }; $gm = if ($gv) { '{0:N1}G' -f ($gv[2] / 1024) } else { '--' }; $gx = if ($gv) { '/{0:N0}G' -f ($gv[3] / 1024) } else { '' }
    Item gpu 6 @('GPU', $gu, $gt, ($gm + $gx)) @(@('GPU', $gu, $gt), @('VRM', $gm, $gx))

    $dv = foreach ($k in $disks.Keys) { $c = $disks[$k]; [pscustomobject]@{ K = $k; R = $c[0].NextValue(); W = $c[1].NextValue(); Act = 100 - $c[2].NextValue() } }
    $dsel = @($dv | Where-Object { -not $script:pickD -or $script:pickD -contains $_.K })
    $dr = MBs ($dsel | Measure-Object R -Sum).Sum; $dw = MBs ($dsel | Measure-Object W -Sum).Sum
    Item disk 2 @('DSK', (Pct ([math]::Max(0, ($dsel | Measure-Object Act -Maximum).Maximum))), ('R' + $dr), ('W' + $dw)) @(@('R', $dr), @('W', $dw))

    # 未指定网卡时取流量最大的一块，避免虚拟网卡与物理网卡重复计数
    $nv = foreach ($k in $nics.Keys) { $c = $nics[$k]; [pscustomobject]@{ K = $k; Rx = $c[0].NextValue(); Tx = $c[1].NextValue(); Bw = $c[2].NextValue() } }
    $nsel = if ($script:pickN) { @($nv | Where-Object { $script:pickN -contains $_.K }) } else { @($nv | Sort-Object { $_.Rx + $_.Tx } -Descending | Select-Object -First 1) }
    $nr = MBs ($nsel | Measure-Object Rx -Sum).Sum; $nt = MBs ($nsel | Measure-Object Tx -Sum).Sum
    $bw = ($nsel | Measure-Object Bw -Sum).Sum; $bws = if ($bw -ge 1e9) { '{0:0.#}Gb' -f ($bw / 1e9) } else { '{0:N0}Mb' -f ($bw / 1e6) }  # 链路速率
    Item net 1 @('NET', ('↓' + $nr), ('↑' + $nt), $bws) @(@('↓', $nr), @('↑', $nt))
    , $items.ToArray()
}

# Claude：上行 Clawd + 5h/7d 额度；下行饼图、长条和百分比都是该标签会话距自动压缩的进度。
# 额度到 95% 时整列标红，长条位置改为重置时间
# 额度来源：先用 Claude Code 自己缓存在 ~/.claude.json 的 cachedUsageUtilization（不发请求，每 30 秒读一次）；
# 它只是偶尔更新，超过 $ClaudeEvery 秒才请求接口（不消耗 token，但有限流）
$script:ccAt = [DateTime]::MinValue; $script:cc = $null
function Get-Usage {
    if (([DateTime]::Now - $script:ccAt).TotalSeconds -ge 30) {
        $script:ccAt = [DateTime]::Now
        $script:cc = try { (Get-Content (Join-Path $HOME '.claude.json') -Raw -Encoding utf8 | ConvertFrom-Json).cachedUsageUtilization } catch { $null }
    }
    $fresh = $script:cc -and ([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $script:cc.fetchedAtMs) -lt $ClaudeEvery * 1000
    $api = $script:async['claude']
    if ($fresh -and -not ($api.Value -and $api.At -gt [DateTimeOffset]::FromUnixTimeMilliseconds($script:cc.fetchedAtMs).LocalDateTime)) { return $script:cc.utilization }
    $raw = Update-Async 'claude' $ClaudeEvery $claude -Keep
    if ($script:async['claude'].Ok) { $script:async['claude'].Ok = $false; try { [void](New-Item -ItemType Directory -Force (Split-Path $usageCache)); Set-Content $usageCache $raw -Encoding utf8 } catch {} }
    if ($raw) { try { $raw | ConvertFrom-Json } catch { $null } } elseif ($script:cc) { $script:cc.utilization }
}
# 数据里的重置时间已过（缓存过期、尚未拿到新数据）时显示 N/A，不挂着旧数值
function Get-LimitText($lim) {
    if (-not $lim) { return '--' }
    if ($lim.resets_at -and [datetime]$lim.resets_at -lt [DateTime]::Now) { return 'N/A' }
    Pct $lim.utilization
}

function Get-ClaudeItem($tabs) {
    if ($script:show -notcontains 'claude' -or $tabs.Selected -notmatch $ClaudeTitle) { return }
    $u = Get-Usage
    $s5 = Get-LimitText $u.five_hour; $s7 = Get-LimitText $u.seven_day
    $p5 = if ($s5 -match '%') { $u.five_hour.utilization } else { 0 }; $p7 = if ($s7 -match '%') { $u.seven_day.utilization } else { 0 }
    $reset = @($(if ($p5 -ge $ClaudeRed) { '↻' + ([datetime]$u.five_hour.resets_at).ToString('HH:mm') }), $(if ($p7 -ge $ClaudeRed) { '↻' + ([datetime]$u.seven_day.resets_at).ToString('MM-dd') })) -ne $null
    $title = $tabs.Selected -replace "$ClaudeTitle\s*", ''
    $ctx = $shared.Sessions | Where-Object { $_.Title -eq $title } | Sort-Object Stamp -Descending | Select-Object -First 1
    $win = if ($ctx) { Get-ModelWindow $ctx.Used $ctx.Model } else { 1 }
    $acp = if ($ctx) { Get-CompactPct $ctx.Used $win $shared.AcWindow } else { 0 }
    $mid = if ($reset) { @{ Text = ($reset -join ' '); Span = 3 } } else { @{ Icon = 'bar'; Span = 3; Pct = $acp } }
    $col = if ($reset) { $red }
    [pscustomobject]@{ Prio = 5; Rows = @(
        [pscustomobject]@{ Fields = @(@{ Icon = 'clawd' }, '5h', $s5, '7d', $s7); Color = $col }
        [pscustomobject]@{ Fields = @(@{ Icon = 'pie'; Pct = $acp }, $mid, '', '', $(if ($ctx) { Pct $acp } else { '--' })); Color = $(if ($reset) { $red } elseif ($acp -ge 80) { $hot }) }
    ) }
}

# 把一组条目排进某个 WT 窗口标题栏的空白处
function Show-Hud($hud, $w, $items) {
    $hud.Wt = $w.H; $hud.Bounds = $null
    $tabs = $shared.Tabs[[int64]$w.H]
    if (-not $items -or -not (Test-TabSnapshot $w $tabs)) { Hide-Hud $hud; return }
    $sc = $w.Dpi / 96; $m = Get-Metrics $sc; $script:m = $m; $hud.M = $m
    $capLeft = $w.R - [int](3 * 46 * $sc)  # 让出最小化/最大化/关闭三个按钮
    $left = $w.L + $tabs.Right + [int](8 * $sc)

    if (-not $script:pinned -and (Test-Covered $w $left $capLeft $sc)) { Hide-Hud $hud; $hud.Sig = $null; return }
    # 背景取标题栏空白处的颜色，整块不透明才能接收右键
    $dc = [W.U]::GetDC([IntPtr]::Zero); $px = [W.U]::GetPixel($dc, $left - [int](4 * $sc), $w.T + [int](6 * $sc)); [void][W.U]::ReleaseDC([IntPtr]::Zero, $dc)
    $bg = [Drawing.Color]::FromArgb($px -band 0xFF, ($px -shr 8) -band 0xFF, ($px -shr 16) -band 0xFF)
    if ($hud.Form.BackColor -ne $bg) { $hud.Form.BackColor = $bg }
    $hud.Val = if ($bg.GetBrightness() -gt 0.5) { [Drawing.Color]::FromArgb(40, 40, 40) } else { [Drawing.Color]::Gainsboro }

    $gap = [int]($m.CharW * 1.5); $pad = [int](4 * $sc)
    $kept = Fit-Items $items ($capLeft - $left - 2 * $pad) $gap { param($c) Measure-Column $c ${function:Measure-Field} $script:m.SubGap }
    if (-not $kept) { Hide-Hud $hud; return }
    $x = $pad; foreach ($c in $kept) { $c.X = $x; $x += $c.W + $gap }
    $wd = $x - $gap + $pad
    $hud.Layout = $kept
    # 高度贴合标签栏：以标签实际下沿为准，上下让开窗口顶边框和标签栏底部分隔线（各约 1 DIP）
    $inset = [int][math]::Ceiling($sc)
    $hud.Bounds = @(($capLeft - $wd), ($w.T + $inset), $wd, ($tabs.Bottom - 2 * $inset))
    $hud.Tabs = $tabs
    $hud.Form.Invalidate()
}

# 浮窗保持独立顶层窗口；只在同一份有效几何快照上显示，每次检查遮挡与层级。
function Sync-Hud($hud, $w) {
    if (-not $hud.Bounds -or -not (Test-TabSnapshot $w $hud.Tabs)) { Hide-Hud $hud; return }
    $frozen = $script:pinned -and [W.U]::IsIconic($w.H)
    if (-not $frozen -and ([W.U]::Moving($w.H) -or (Get-WtWindow $w.H).Sig -ne $w.Sig)) { Hide-Hud $hud; return }
    $sc = $w.Dpi / 96
    if (-not $script:pinned -and (Test-Covered $w ($w.L + $hud.Tabs.Right + [int](8 * $sc)) ($w.R - [int](138 * $sc)) $sc)) {
        Hide-Hud $hud; $hud.Sig = $null; return
    }
    if ($hud.Pinned -ne $script:pinned) {
        [void][W.U]::SetWindowPos($hud.H, [IntPtr]$(if ($script:pinned) { -1 } else { -2 }), 0, 0, 0, 0, 0x10 -bor 0x1 -bor 0x2)
        $hud.Pinned = $script:pinned
    }
    [W.U]::Above($w.H, $hud.H, $script:pinned)
    $b = $hud.Bounds
    [void][W.U]::SetWindowPos($hud.H, [IntPtr]::Zero, $b[0], $b[1], $b[2], $b[3], 0x40 -bor 0x10 -bor 0x4)
    $hud.Shown = $true
}

# 每秒跟随窗口位置（拖动中由 C# 侧隐藏，停稳 0.5 秒后在这里重新显示）；资源数据每 3 秒采一次。位置、标签、设置都没变且没有新数据时不重新排版
$script:dataAt = [DateTime]::MinValue; $script:res = @()
function Update-Huds { try {
    $wins = @(Get-WtWindows)
    foreach ($w in $wins) {
        $key = [int64]$w.H
        if (-not $huds[$key]) { $huds[$key] = New-Hud }
        [W.U]::Watch($w.H, $huds[$key].H, $script:pinned)
        $w | Add-Member Moving ([W.U]::Moving($w.H))
    }
    $target = Select-Target $wins
    if ($target) { $script:lastTarget = $target } elseif ($script:pinned -and $script:lastTarget) { $target = $script:lastTarget; $wins = @($target) }  # 置顶时 WT 最小化也留在原处
    $shared.Wins = @($wins | ForEach-Object { [int64]$_.H })
    $windowSig = ($wins.Sig -join ';')
    if ($windowSig -ne $script:windowSig) { $script:windowSig = $windowSig; [void][W.U]::Changed.Set() }
    $data = ([DateTime]::Now - $script:dataAt).TotalSeconds -ge 3
    if ($data) { $script:dataAt = [DateTime]::Now; $script:res = Get-ResourceItems }  # 计数器只在这里采样，所有浮窗共用
    foreach ($w in $wins) {
        $k = [int64]$w.H
        if (-not $huds[$k]) { $huds[$k] = New-Hud }
        $hud = $huds[$k]; $tabs = $shared.Tabs[$k]
        if ($w.Moving) { Hide-Hud $hud; $hud.Sig = $null; continue }
        $sig = "$($w.L),$($w.T),$($w.R),$($w.B)|$($tabs.Right),$($tabs.Bottom),$($tabs.Selected)|$($w.H -eq $target.H)|$script:pinned|$($script:show -join ',')"
        if ($data -or $sig -ne $hud.Sig) {
            $hud.Sig = $sig
            $items = @(if ($w.H -eq $target.H) { $script:res }; Get-ClaudeItem $tabs)
            Show-Hud $hud $w $items
        }
        Sync-Hud $hud $w
    }
    foreach ($k in @($huds.Keys)) { if (-not ($wins | Where-Object { [int64]$_.H -eq $k })) { $huds[$k].Form.Dispose(); $huds.Remove($k); [W.U]::Unwatch([IntPtr]$k) } }  # 窗口已关闭或最小化
    if ($shared.Error) { throw $shared.Error }
} catch {
    $errorDir = Join-Path $env:LOCALAPPDATA 'term-hud'
    [void](New-Item -ItemType Directory -Force $errorDir)
    "$(Get-Date -Format s) $_ $($_.InvocationInfo.PositionMessage)" | Set-Content (Join-Path $errorDir 'error.log') -Encoding utf8
    $shared.Error = $null
}
}
$timer = [Windows.Forms.Timer]@{ Interval = 1000 }
$timer.add_Tick({ Update-Huds })
$timer.Start()
[Windows.Forms.Application]::Run()
[Environment]::Exit(0)  # 结束后台线程
