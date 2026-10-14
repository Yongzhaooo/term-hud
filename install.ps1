# term-hud installer. Works in Windows PowerShell 5.1 and PowerShell 7:
#   irm https://raw.githubusercontent.com/Yongzhaooo/term-hud/main/install.ps1 | iex
# With options:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Yongzhaooo/term-hud/main/install.ps1))) -NoLHM
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Yongzhaooo/term-hud/main/install.ps1))) -Uninstall
param([switch]$NoLHM, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072  # TLS 1.2 for Windows PowerShell 5.1

$raw  = 'https://raw.githubusercontent.com/Yongzhaooo/term-hud/main'
$dir  = Join-Path $env:LOCALAPPDATA 'term-hud\app'
$lnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'term-hud.lnk'
$task = 'term-hud LibreHardwareMonitor'

function Invoke-Elevated($script) {
    # One UAC prompt; the elevated part only touches LibreHardwareMonitor and its logon task
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc
    if ($p.ExitCode) { throw "Elevated step failed (exit $($p.ExitCode))." }
}
function Find-Lhm {
    $paths = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\LibreHardwareMonitor.LibreHardwareMonitor_*\LibreHardwareMonitor.exe",
             "$env:ProgramFiles\LibreHardwareMonitor\LibreHardwareMonitor.exe"
    (Get-ChildItem $paths -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}

# Stop a running instance so the script file can be replaced or removed
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like '*term-hud.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

if ($Uninstall) {
    Remove-Item $lnk, $dir -Recurse -Force -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) { Invoke-Elevated "Unregister-ScheduledTask -TaskName '$task' -Confirm:`$false" }
    Write-Host 'term-hud removed. Settings are kept in %APPDATA%\term-hud.'
    Write-Host 'LibreHardwareMonitor is still installed: winget uninstall LibreHardwareMonitor.LibreHardwareMonitor'
    return
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw 'winget is required (App Installer from the Microsoft Store).' }
$wg = '-e', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements'
if (-not (Get-AppxPackage Microsoft.WindowsTerminal*)) { Write-Warning 'Windows Terminal not found; term-hud only shows inside it.' }

# PowerShell 7
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) {
    Write-Host 'Installing PowerShell 7...'
    winget install --id Microsoft.PowerShell @wg
    $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (-not (Test-Path $pwsh)) { throw 'PowerShell 7 install failed.' }
}

# term-hud itself: a single script
Write-Host "Downloading term-hud to $dir"
New-Item -ItemType Directory -Force $dir | Out-Null
Invoke-WebRequest "$raw/term-hud.ps1" -OutFile (Join-Path $dir 'term-hud.ps1') -UseBasicParsing
$hudArgs = "--headless `"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $dir 'term-hud.ps1')`""
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath = 'conhost.exe'; $s.Arguments = $hudArgs; $s.Save()  # start at login without a console window

# LibreHardwareMonitor: CPU temperature and package power. Needs admin rights to read sensors.
if (-not $NoLHM) {
    $exe = Find-Lhm
    if (-not $exe) { Write-Host 'Installing LibreHardwareMonitor...'; winget install --id LibreHardwareMonitor.LibreHardwareMonitor @wg; $exe = Find-Lhm }
    if (-not $exe) { throw 'LibreHardwareMonitor install failed. Re-run with -NoLHM to skip it.' }
    Write-Host 'Configuring LibreHardwareMonitor (web server on port 8085, tray, start at logon as admin). Approve the UAC prompt.'
    $user = "$env:USERDOMAIN\$env:USERNAME"; $q = { param($v) $v -replace "'", "''" }
    Invoke-Elevated @"
`$ErrorActionPreference = 'Stop'
`$exe = '$(& $q $exe)'; `$task = '$task'; `$user = '$(& $q $user)'
Get-Process LibreHardwareMonitor -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1  # it rewrites its config on exit
`$cfg = Join-Path (Split-Path `$exe) 'LibreHardwareMonitor.config'
[xml]`$x = if (Test-Path `$cfg) { Get-Content `$cfg -Raw } else { '<?xml version="1.0" encoding="utf-8"?><configuration><appSettings /></configuration>' }
`$app = `$x.SelectSingleNode('/configuration/appSettings')
foreach (`$k in @{ runWebServerMenuItem = 'true'; listenerPort = '8085'; startMinMenuItem = 'true'; minTrayMenuItem = 'true'; minCloseMenuItem = 'true' }.GetEnumerator()) {
    `$n = `$app.SelectSingleNode("add[@key='`$(`$k.Key)']")
    if (-not `$n) { `$n = `$x.CreateElement('add'); `$n.SetAttribute('key', `$k.Key); [void]`$app.AppendChild(`$n) }
    `$n.SetAttribute('value', `$k.Value)
}
`$x.Save(`$cfg)
Register-ScheduledTask -TaskName `$task -Force ``
    -Action (New-ScheduledTaskAction -Execute `$exe) ``
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User `$user) ``
    -Principal (New-ScheduledTaskPrincipal -UserId `$user -LogonType Interactive -RunLevel Highest) ``
    -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)) | Out-Null
Start-ScheduledTask -TaskName `$task
"@
}

Start-Process conhost.exe -ArgumentList $hudArgs
Write-Host 'term-hud is running in the Windows Terminal title bar. Right-click it for options.'
