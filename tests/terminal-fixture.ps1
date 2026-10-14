param([Parameter(Mandatory)][string]$StopFile)
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Write-Host 'term-hud-ci: isolated terminal fixture. No Claude account or commands are used.'
while (-not (Test-Path -LiteralPath $StopFile)) { Start-Sleep -Milliseconds 200 }
