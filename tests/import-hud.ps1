# Load the production definitions without starting counters, reading credentials or taking the runtime mutex.
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$hudPath = Join-Path $PSScriptRoot '..\term-hud.ps1'
$tokens = $null; $parseErrors = $null
$hudAst = [Management.Automation.Language.Parser]::ParseFile($hudPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors -join "`n") }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
$native = $hudAst.EndBlock.Statements | Where-Object { $_.Extent.Text -like 'Add-Type -Namespace W *' }
Invoke-Expression $native.Extent.Text
[void][W.U]::SetProcessDpiAwarenessContext([IntPtr]-4)
foreach ($definition in $hudAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    Invoke-Expression $definition.Extent.Text
}
$load = @('$ClaudeTitle', '$ClaudeRed', '$Zh', '$DegC', '$ClawdArt', '$flags', '$clawd', '$orange', '$orangeBrush', '$hot', '$red', '$script:dim', '$LabelRe', '$script:metrics', '$paint', '$mouse', '$worker', '$lhm', '$claude')
foreach ($assignment in $hudAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -in $load }) {
    Invoke-Expression $assignment.Extent.Text
}
$script:checkCount = 0
function Assert($condition, [string]$name) {
    if (-not $condition) { throw "FAIL: $name" }
    $script:checkCount++; Write-Output "PASS: $name"
}
