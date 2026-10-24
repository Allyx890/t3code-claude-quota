param([ValidateRange(1, 5000)][int]$Tail = 60, [switch]$Follow)
. (Join-Path $PSScriptRoot 'tools\paths.ps1')
$logPath = Join-Path $T3UserData 'logs\claude-quota.ndjson'
if (!(Test-Path -LiteralPath $logPath)) { Write-Output "No log yet: $logPath"; return }
Write-Output "Log: $logPath"
Get-Content -LiteralPath $logPath -Encoding utf8 -Tail $Tail -Wait:$Follow
