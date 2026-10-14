param([switch]$Full, [switch]$PrePush)
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Set-Location (Join-Path $PSScriptRoot '..')
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7) { throw 'Use PowerShell 7 on Windows: pwsh -NoProfile -File scripts/ci.ps1' }
foreach ($tool in @('git','pwsh') + $(if ($Full -or $PrePush) { @('wt') })) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing $tool. Install it before running local CI." }
}
$outputDir = Join-Path $PWD 'build\ci'
[void](New-Item -ItemType Directory -Force $outputDir)
$stampFile = Join-Path $outputDir 'full-passed'

function Get-WorkTreeId {
    $indexPath = Join-Path $outputDir 'stamp.index'
    $originalIndex = $env:GIT_INDEX_FILE
    try {
        $realIndex = git rev-parse --path-format=absolute --git-path index
        if ($LASTEXITCODE -ne 0) { throw 'Cannot locate the Git index.' }
        if (Test-Path -LiteralPath $realIndex) { Copy-Item -LiteralPath $realIndex -Destination $indexPath -Force }
        $env:GIT_INDEX_FILE = $indexPath
        git add -A
        if ($LASTEXITCODE -ne 0) { throw 'Cannot snapshot working content.' }
        $tree = git write-tree
        if ($LASTEXITCODE -ne 0) { throw 'Cannot write the test tree.' }
        $tree
    } finally {
        $env:GIT_INDEX_FILE = $originalIndex
        if (Test-Path -LiteralPath $indexPath) { Remove-Item -LiteralPath $indexPath }
    }
}
function Matches-Stamp($stamp, $tree) {
    if ($stamp -notmatch '^[0-9a-f]{40,64}$') { return $false }
    git diff --quiet $stamp $tree -- . ':(exclude)*.md' 2>$null
    $LASTEXITCODE -eq 0
}
$pushed = @()
if ($PrePush) {
    foreach ($line in ([Console]::In.ReadToEnd() -split '\r?\n')) {
        if (-not $line.Trim()) { continue }
        $fields = $line -split ' '
        if ($fields.Count -ne 4 -or $fields[1] -notmatch '^[0-9a-f]{40,64}$') { throw 'Invalid pre-push input.' }
        if ($fields[1] -match '^0+$') { continue }
        $pushed += "$($fields[1])^{tree}"
    }
    if (-not $pushed) { Write-Output 'No content pushed; CI skipped.'; exit 0 }
    $stamp = try { (Get-Content -LiteralPath $stampFile -Raw -Encoding utf8 -ErrorAction Stop).Trim() } catch { $null }
    if (@($pushed | Where-Object { -not (Matches-Stamp $stamp $_) }).Count -eq 0) {
        Write-Output "Full CI already passed for tree $stamp; skipping."; exit 0
    }
    $working = Get-WorkTreeId
    if (@($pushed | Where-Object { -not (Matches-Stamp $working $_) }).Count) { throw 'Pushed content differs from this checkout. Check out and run full CI on each pushed tree first.' }
    $Full = $true
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$total = 0
if ($Full) {
    $treeBefore = Get-WorkTreeId
    if (Test-Path -LiteralPath $stampFile) { Remove-Item -LiteralPath $stampFile }
}
function Run-Checks([string]$name, [string[]]$arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=$start.StandardErrorEncoding=[Text.Encoding]::UTF8
    foreach($arg in @('-NoProfile','-File') + $arguments) { $start.ArgumentList.Add($arg) }
    $process=[Diagnostics.Process]::Start($start)
    $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
    try {
        $timedOut = -not $process.WaitForExit(90000)
        if ($timedOut) {
            $process.Kill($true); $process.WaitForExit()
            if ($name -eq 'ui') { Set-Content -LiteralPath (Join-Path $outputDir 'ui\stop') -Value 'CI timeout' -Encoding utf8 }
        }
        $text=$stdout.GetAwaiter().GetResult()+$stderr.GetAwaiter().GetResult()
        Set-Content -LiteralPath (Join-Path $outputDir "$name.log") -Value $text -Encoding utf8
        Write-Output $text.TrimEnd()
        if ($timedOut) { throw "$name timed out after 90 seconds; see build/ci/$name.log" }
        $summary=[regex]::Match($text,'(?m)^OK \((\d+) [^)]+\)\s*$')
        if ($process.ExitCode -ne 0 -or -not $summary.Success) { throw "$name failed (exit $($process.ExitCode)); see build/ci/$name.log" }
        $script:total += [int]$summary.Groups[1].Value
    } finally { $process.Dispose() }
}
Run-Checks legacy @('term-hud.ps1','-Test')
Run-Checks regression @('tests/regression.ps1')
if ($Full) {
    Write-Output "Fast tier: $total checks in $([math]::Round($clock.Elapsed.TotalSeconds,1))s"
    Run-Checks ui @('tests/ui.ps1','-Target','term-hud-ci')
    if ((Get-WorkTreeId) -ne $treeBefore) { throw 'Content changed during full CI; no pass stamp written.' }
    Set-Content -LiteralPath $stampFile -Value $treeBefore -Encoding utf8 -NoNewline
}
Write-Output "OK ($total checks; tier=$(if($Full){'full'}else{'fast'}); $([math]::Round($clock.Elapsed.TotalSeconds,1))s)"
