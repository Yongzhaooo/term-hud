param([Parameter(Mandatory)][ValidateSet('term-hud-ci')][string]$Target)
. "$PSScriptRoot\import-hud.ps1"
Add-Type -Path "$PSScriptRoot\Native.cs"
$testMutex=[Threading.Mutex]::new($false,'Local\term-hud-ci')
if (-not $testMutex.WaitOne(0)) { throw 'Another term-hud CI run owns the desktop target; wait for it to finish.' }
$out = Join-Path $PSScriptRoot '..\build\ci\ui'
[void](New-Item -ItemType Directory -Force $out)
$out = (Resolve-Path -LiteralPath $out).Path
$env:LOCALAPPDATA = Join-Path $out 'local'
$env:APPDATA = Join-Path $out 'roaming'
$claudeDir = Join-Path $out 'claude'
[void](New-Item -ItemType Directory -Force (Join-Path $claudeDir 'projects\fixture'))
'{"autoCompactWindow":500000}' | Set-Content -LiteralPath (Join-Path $claudeDir 'settings.json') -Encoding utf8
@(
    '{"type":"user","message":{}}'
    '{"type":"ai-title","aiTitle":"term-hud-ci"}'
    '{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":1000,"cache_read_input_tokens":99000,"output_tokens":500}}}'
) | Set-Content -LiteralPath (Join-Path $claudeDir 'projects\fixture\session.jsonl') -Encoding utf8
$stopFile = Join-Path $out 'stop'
if (Test-Path -LiteralPath $stopFile) { Remove-Item -LiteralPath $stopFile }
$failureShot = Join-Path $out 'failure.png'
if (Test-Path -LiteralPath $failureShot) { Remove-Item -LiteralPath $failureShot }
$logFile = Join-Path $env:LOCALAPPDATA 'term-hud\error.log'
if (Test-Path -LiteralPath $logFile) { Remove-Item -LiteralPath $logFile }
$script:fixtureH = [IntPtr]::Zero
$script:huds = @{}; $script:show = @('cpu', 'claude'); $script:pinned = $false
$script:dataAt = [DateTime]::MinValue; $script:res = @()
$script:shared = [hashtable]::Synchronized(@{Wins=@();Tabs=@{};Sessions=@();AcWindow=0;Stop=$false;Error=$null})
$script:usage = @{five_hour=@{utilization=14;resets_at=[datetime]::Now.AddHours(2)};seven_day=@{utilization=23;resets_at=[datetime]::Now.AddDays(2)}}
function Get-Usage { $script:usage }
function Get-ResourceItems { , @([pscustomobject]@{ Prio=7; Fields=@('CPU','12%','55°C','3.5G'); Tall=@(@('CPU','12%','3.5G'),@('TMP','55°C','20W')); Color=$null }) }
function Get-WtWindows {
    if ($script:fixtureH -ne [IntPtr]::Zero -and [W.U]::IsWindowVisible($script:fixtureH) -and -not [W.U]::IsIconic($script:fixtureH)) { Get-WtWindow $script:fixtureH }
}
function Find-Fixture {
    $h = [IntPtr]::Zero; $found = @()
    while (($h = [W.U]::FindWindowEx([IntPtr]::Zero,$h,'CASCADIA_HOSTING_WINDOW_CLASS',[NullString]::Value)) -ne [IntPtr]::Zero) {
        $name = [Text.StringBuilder]::new(256); [void][W.U]::GetWindowText($h,$name,256)
        if ($name.ToString() -eq '◐ term-hud-ci') { $found += $h }
    }
    if ($found.Count -gt 1) { throw 'More than one term-hud-ci window; another test may be running.' }
    if ($found.Count) { $found[0] } else { [IntPtr]::Zero }
}
function Pump([int]$ms) {
    [TestDesktop]::Pump($ms)
    if (Test-Path -LiteralPath $logFile) { throw (Get-Content -LiteralPath $logFile -Raw -Encoding utf8) }
}
function Wait-For([scriptblock]$condition, [string]$name, [int]$timeout=6000) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $condition)) {
        if ($watch.ElapsedMilliseconds -gt $timeout) {
            Write-Host "TIMEOUT: $name ($($watch.ElapsedMilliseconds)ms)"
            $frame=Get-WtWindow $script:fixtureH; $tab=$shared.Tabs[[int64]$script:fixtureH]; $currentHud=$script:huds[[int64]$script:fixtureH]
            Write-Host "frame=$($frame.Sig); tab=$($tab.Shape); Right=$($tab.Right); Bottom=$($tab.Bottom); Selected=$($tab.Selected)"
            Write-Host "bounds=$($currentHud.Bounds -join ','); sig=$($currentHud.Sig); foreground=$([TestDesktop]::GetForegroundWindow()); worker=$($runner.InvocationStateInfo.State)"
            Save-TitleShot 'failure'
            throw "Timeout: $name"
        }
        Pump 20
    }
    [int]$watch.ElapsedMilliseconds
}
function Visible-Hud { $hud=$script:huds[[int64]$script:fixtureH]; $hud -and [W.U]::IsWindowVisible($hud.H) }
function Save-TitleShot([string]$name) {
    Pump 150
    if ([TestDesktop]::GetForegroundWindow() -ne $script:fixtureH) { return }
    $w = Get-WtWindow $script:fixtureH
    $image = [Drawing.Bitmap]::new(($w.R-$w.L), [int](60*$w.Dpi/96))
    $g = [Drawing.Graphics]::FromImage($image)
    try {
        $g.CopyFromScreen($w.L,$w.T,0,0,$image.Size); $image.Save((Join-Path $out "$name.png"))
        if ($name -eq 'claude-initial') {
            $hud=$script:huds[[int64]$script:fixtureH]; $pixels=0
            $column=@($hud.Layout | Where-Object { $_.Rows[0][0].Icon -eq 'clawd' })[0]
            $top=[int](($hud.Form.ClientSize.Height-2*$hud.M.Lh)/2)
            for ($y=$top;$y -lt $top+$hud.M.Lh;$y++) {
                for ($x=$column.X;$x -lt $column.X+18*$hud.M.Pw;$x++) {
                    if ($image.GetPixel([int]($hud.Bounds[0]-$w.L+$x),[int]($hud.Bounds[1]-$w.T+$y)).ToArgb() -eq $orange.ToArgb()) { $pixels++ }
                }
            }
            Assert ($pixels -gt 25) 'rendered title-bar screenshot contains the orange Clawd icon'
        }
    } finally { $g.Dispose(); $image.Dispose() }
}
function Drag([int]$x,[int]$y,[int]$dx,[int]$dy,[string]$name) {
    if ([TestDesktop]::GetForegroundWindow() -ne $script:fixtureH) { throw 'Desktop target lost focus; rerun with the dedicated WT in front.' }
    $before = Get-WtWindow $script:fixtureH
    $point=[W.U+POINT]::new();$point.X=$x;$point.Y=$y
    if ($name -eq 'HUD drag') { Assert ([W.U]::GetAncestor([W.U]::WindowFromPoint($point),2) -eq $script:huds[[int64]$script:fixtureH].H) 'drag starts on the rendered HUD' }
    [void][TestDesktop]::SetCursorPos($x,$y); Pump 50
    [TestDesktop]::Button($true)
    try {
        [void](Wait-For {[W.U]::InMoveSize($script:fixtureH)} "$name starts the native move loop" 1000)
        for ($step=1;$step -le 20;$step++) {
            [void][TestDesktop]::SetCursorPos(($x+[int]($dx*$step/20)),($y+[int]($dy*$step/20))); Pump 25
            if ($step -eq 10) {
                Assert (-not (Visible-Hud)) "$name hides HUD during drag"
            }
        }
        $during = Get-WtWindow $script:fixtureH
        Assert ([math]::Abs(($during.L-$before.L)-$dx) -lt 12 -and [math]::Abs(($during.T-$before.T)-$dy) -lt 12) "$name follows pointer before button release"
        Pump 600
        Assert (-not (Visible-Hud)) "$name stays hidden while the drag is held still"
    } finally { [TestDesktop]::Button($false) }
    $elapsed = Wait-For { Visible-Hud } "$name restore"
    Assert ($elapsed -le 1700) "$name restores after settling (${elapsed}ms, includes polling tolerance)"
    $hud=$script:huds[[int64]$script:fixtureH]; $after=Get-WtWindow $script:fixtureH
    Assert ($hud.Bounds[3] -le 60*$after.Dpi/96 -and $hud.Bounds[1] -ge $after.T) "$name keeps HUD inside the title bar"
}

$timer=$null; $runner=$null; $cover=$null; $launched=$false
$cursor=[TestDesktop+Point]::new(); [void][TestDesktop]::GetCursorPos([ref]$cursor)
$foreground=[TestDesktop]::GetForegroundWindow()
try {
    if ((Find-Fixture) -ne [IntPtr]::Zero) { throw 'term-hud-ci is already open; close the previous fixture before running full CI.' }
    & wt.exe -w $Target new-tab --title '◐ term-hud-ci' --suppressApplicationTitle pwsh.exe -NoProfile -File "$PSScriptRoot\terminal-fixture.ps1" -StopFile $stopFile
    if ($LASTEXITCODE -ne 0) { throw "Windows Terminal launcher failed: $LASTEXITCODE" }
    $launched=$true
    [void](Wait-For { $script:fixtureH=Find-Fixture; $script:fixtureH -ne [IntPtr]::Zero } 'fixture startup')
    Assert ([TestDesktop]::SetProp($script:fixtureH,'term-hud-ci',[IntPtr]1)) 'dedicated fixture excluded from personal HUD'
    [void][TestDesktop]::ShowWindow($script:fixtureH,9)
    [void][W.U]::SetWindowPos($script:fixtureH,[IntPtr]::Zero,160,260,2200,1100,0x10)
    [void][TestDesktop]::SetForegroundWindow($script:fixtureH)
    $runner=[powershell]::Create()
    [void]$runner.AddScript($worker).AddArgument($shared).AddArgument(${function:Read-SessionTail}.ToString()).AddArgument(${function:Get-WtWindow}.ToString()).AddArgument($claudeDir)
    [void]$runner.BeginInvoke()
    $timer=[Windows.Forms.Timer]@{Interval=1000}; $timer.add_Tick({Update-Huds}); $timer.Start()
    [void](Wait-For { Visible-Hud } 'initial HUD')
    $hud=$script:huds[[int64]$script:fixtureH]
    Assert ($shared.Tabs[[int64]$script:fixtureH].Selected -eq '◐ term-hud-ci') 'real WT UIA selects Claude tab (A/a regression)'
    $owner = [W.U]::GetWindowLongPtr($hud.H,-8)
    Assert ($owner -eq [IntPtr]::Zero -or [TestDesktop]::ProcessId($owner) -eq $PID) 'HUD has no cross-process owner'
    Assert ([TestDesktop]::GetForegroundWindow() -eq $script:fixtureH) 'HUD does not steal keyboard focus'
    $row=@($hud.Layout.Rows | Where-Object { $_[0].Icon -eq 'clawd' })
    Assert ($row.Count -eq 1 -and $row[0][2].Trim() -eq '14%' -and $row[0][4].Trim() -eq '23%') 'paint layout contains Clawd, 5h 14%, 7d 23%'
    Save-TitleShot 'claude-initial'
    $w=Get-WtWindow $script:fixtureH
    Drag ([int]($w.L+850)) ([int]($w.T+20*$w.Dpi/96)) 140 100 'WT title-bar drag'
    $hud=$script:huds[[int64]$script:fixtureH]
    Drag ([int]($hud.Bounds[0]+$hud.Bounds[2]/2)) ([int]($hud.Bounds[1]+$hud.Bounds[3]/2)) -80 -140 'HUD drag'
    Save-TitleShot 'after-drag'
    foreach ($maximize in $true,$false) {
        $hud=$script:huds[[int64]$script:fixtureH]
        if ([TestDesktop]::GetForegroundWindow() -ne $script:fixtureH) { throw 'Desktop target lost focus before double-click.' }
        [void][TestDesktop]::SetCursorPos([int]($hud.Bounds[0]+$hud.Bounds[2]/2),[int]($hud.Bounds[1]+$hud.Bounds[3]/2))
        [TestDesktop]::Button($true); Pump 70; [TestDesktop]::Button($false); Pump 70
        [TestDesktop]::Button($true); Pump 70; [TestDesktop]::Button($false)
        [void](Wait-For { [W.U]::IsZoomed($script:fixtureH) -eq $maximize } 'HUD double-click')
        [void](Wait-For { Visible-Hud } 'HUD after double-click')
        Assert ([W.U]::IsZoomed($script:fixtureH) -eq $maximize) "HUD double-click toggles maximize=$maximize"
    }
    & wt.exe -w $Target new-tab --title 'term-hud-ci shell' --suppressApplicationTitle pwsh.exe -NoProfile -File "$PSScriptRoot\terminal-fixture.ps1" -StopFile $stopFile
    if ($LASTEXITCODE -ne 0) { throw 'Cannot open isolated non-Claude tab.' }
    [void](Wait-For { $shared.Tabs[[int64]$script:fixtureH].Selected -eq 'term-hud-ci shell' -and (Visible-Hud) } 'non-Claude tab selection')
    Assert (@($script:huds[[int64]$script:fixtureH].Layout.Rows | Where-Object { $_[0].Icon -eq 'clawd' }).Count -eq 0) 'switching away from Claude removes its column'
    & wt.exe -w $Target focus-tab -t 0
    if ($LASTEXITCODE -ne 0) { throw 'Cannot return to isolated Claude tab.' }
    [void](Wait-For { $shared.Tabs[[int64]$script:fixtureH].Selected -eq '◐ term-hud-ci' -and (Visible-Hud) } 'Claude tab selection')
    Assert (@($script:huds[[int64]$script:fixtureH].Layout.Rows | Where-Object { $_[0].Icon -eq 'clawd' }).Count -eq 1) 'switching back to Claude restores its column'
    $w=Get-WtWindow $script:fixtureH
    [void][W.U]::SetWindowPos($script:fixtureH,[IntPtr]::Zero,$w.L,$w.T,1900,1000,0x4000 -bor 0x10 -bor 0x4)
    [void](Wait-For { $h=$script:huds[[int64]$script:fixtureH]; (Visible-Hud) -and $h.Tabs.Shape -eq (Get-WtWindow $script:fixtureH).Shape } 'resize snapshot')
    Assert ($script:huds[[int64]$script:fixtureH].Bounds[3] -lt 150) 'resize uses a matching tab snapshot'
    $cover=[Windows.Forms.Form]@{Text='term-hud-ci cover';StartPosition='Manual';Bounds=[Drawing.Rectangle]::new(100,150,2400,300)}
    $cover.Show(); $cover.Activate()
    [void](Wait-For {-not (Visible-Hud)} 'occlusion hide')
    Assert (-not (Visible-Hud)) 'covered title bar hides the independent HUD'
    $cover.Close(); $cover.Dispose(); $cover=$null
    [void][TestDesktop]::SetForegroundWindow($script:fixtureH)
    [void](Wait-For {Visible-Hud} 'uncovered restore')
    [void][TestDesktop]::ShowWindow($script:fixtureH,6)
    [void](Wait-For {-not (Visible-Hud)} 'minimize hide')
    Assert (-not (Visible-Hud)) 'minimized WT hides HUD without an owner'
    [void][TestDesktop]::ShowWindow($script:fixtureH,9); [void][TestDesktop]::SetForegroundWindow($script:fixtureH)
    [void](Wait-For {Visible-Hud} 'restore from minimized')
    $script:pinned=$true; Update-Huds
    [void][TestDesktop]::ShowWindow($script:fixtureH,6); Pump 2200
    Assert (Visible-Hud) 'pinned HUD remains visible when WT is minimized'
    [void][TestDesktop]::ShowWindow($script:fixtureH,9); $script:pinned=$false; [void][TestDesktop]::SetForegroundWindow($script:fixtureH)
    [void](Wait-For {Visible-Hud} 'unpin restore')
    Assert (-not $shared.Error -and $runner.Streams.Error.Count -eq 0) 'background worker reports no swallowed failures'
    Write-Output "OK ($script:checkCount UI checks)"
} finally {
    [TestDesktop]::Button($false)
    if ($timer) {$timer.Stop();$timer.Dispose()}
    $shared.Stop=$true; [void][W.U]::Changed.Set()
    if ($runner) {
        $stopping=$runner.BeginStop($null,$null); $deadline=[Environment]::TickCount64+3000
        while (-not $stopping.IsCompleted -and [Environment]::TickCount64 -lt $deadline) { [TestDesktop]::Pump(20) }
        if ($stopping.IsCompleted) { $runner.EndStop($stopping); $runner.Dispose() }
    }
    foreach($entry in @($script:huds.GetEnumerator())) {[W.U]::Unwatch([IntPtr]$entry.Key);$entry.Value.Form.Dispose()}
    if ($cover) {$cover.Dispose()}
    if ($launched) {Set-Content -LiteralPath $stopFile -Value 'complete' -Encoding utf8}
    [void][TestDesktop]::SetCursorPos($cursor.X,$cursor.Y)
    if ($foreground -ne [IntPtr]::Zero) {[void][TestDesktop]::SetForegroundWindow($foreground)}
    $testMutex.ReleaseMutex(); $testMutex.Dispose()
}
