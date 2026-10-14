. "$PSScriptRoot\import-hud.ps1"

$w = [pscustomobject]@{ L = 100; T = 500; R = 1500; B = 1300; Dpi = 96; Shape = '1400,800,96|* test' }
$tabs = @{ Right = 500; Bottom = 40; Selected = '◐ test'; Shape = $w.Shape }
Assert (Test-TabSnapshot $w $tabs) 'matching tab snapshot accepted'
$w.T = 300; $w.B = 1100
Assert ((Test-TabSnapshot $w $tabs) -and ($tabs.Bottom - 2) -eq 38) 'moving up does not inflate HUD height'
foreach ($shape in '1500,800,96|* test', '1400,900,96|* test', '1400,800,144|* test', '1400,800,96|pwsh') {
    $w.Shape = $shape
    Assert (-not (Test-TabSnapshot $w $tabs)) "reject stale dimensions, DPI or selected title: $shape"
}
Assert (-not (Test-TabSnapshot $w $null)) 'unknown tab geometry stays hidden'

Add-Type -TypeDefinition @'
public sealed class RecordingHandler : System.Net.Http.HttpMessageHandler {
    public readonly System.Collections.Generic.List<string> Requests = new System.Collections.Generic.List<string>();
    protected override System.Threading.Tasks.Task<System.Net.Http.HttpResponseMessage> SendAsync(System.Net.Http.HttpRequestMessage request, System.Threading.CancellationToken cancel) {
        Requests.Add(request.RequestUri.Host + ":" + (request.Headers.Authorization == null ? "none" : request.Headers.Authorization.ToString()));
        return System.Threading.Tasks.Task.FromResult(new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new System.Net.Http.StringContent("{}") });
    }
}
'@
$handler = [RecordingHandler]::new()
$http = [Net.Http.HttpClient]::new($handler, $false)
$claudeHttp = [Net.Http.HttpClient]::new($handler, $false)
function Get-Content { '{"claudeAiOauth":{"accessToken":"TEST_ONLY"}}' }
try {
    $task = & $claude; [void]$task.GetAwaiter().GetResult()
    $task = & $lhm; [void]$task.GetAwaiter().GetResult()
    Assert ($handler.Requests[0] -eq 'api.anthropic.com:Bearer TEST_ONLY') 'Anthropic request has its bearer'
    Assert ($handler.Requests[1] -eq '127.0.0.1:none') 'LHM request never inherits the bearer'
} finally { Remove-Item function:Get-Content; $http.Dispose(); $claudeHttp.Dispose(); $handler.Dispose() }

$script:show = @('claude')
$script:usage = @{ five_hour = @{ utilization = 14; resets_at = [datetime]::Now.AddHours(1) }; seven_day = @{ utilization = 23; resets_at = [datetime]::Now.AddDays(1) } }
function Get-Usage { $script:usage }
$shared = @{ Sessions = @(); AcWindow = 0 }
$item = Get-ClaudeItem $tabs
Assert ($item.Rows[0].Fields[0].Icon -eq 'clawd' -and $item.Rows[0].Fields[2].Trim() -eq '14%' -and $item.Rows[0].Fields[4].Trim() -eq '23%') 'Clawd and both quota windows survive missing session data'
Assert (@(Get-ClaudeItem @{Selected = 'pwsh'}).Count -eq 0) 'non-Claude tabs omit the Claude column'
$script:usage.five_hour.resets_at = [datetime]::Now.AddSeconds(-1)
Assert ((Get-ClaudeItem $tabs).Rows[0].Fields[2] -eq 'N/A') 'expired quota is not displayed as current'
$script:usage.seven_day.utilization = 96
Assert ((Get-ClaudeItem $tabs).Rows[0].Color -eq $red) 'weekly exhaustion turns Claude red'
$script:usage = $null
Assert ((Get-ClaudeItem $tabs).Rows[0].Fields[2] -eq '--') 'unavailable quota retains Clawd and placeholders'
Write-Output "OK ($script:checkCount regression checks)"
