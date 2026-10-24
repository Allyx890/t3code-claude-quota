# Runs swap-t3.ps1 as a one-off scheduled task in the user's session, outside
# T3's process tree, so stopping T3 cannot stop the swap halfway.
param(
    [ValidateSet('Deploy', 'Restore')][string]$Mode = 'Deploy',
    [int]$DelaySeconds = 5
)
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'swap-t3.ps1'
$taskName = 'T3QuotaSwap-' + $Mode
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Mode {1} -DelaySeconds {2}' -f $script, $Mode, $DelaySeconds)
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Output ("T3 will restart in about {0} s. Log: {1}" -f $DelaySeconds, (Join-Path (Split-Path -Parent $PSScriptRoot) "work\swap-$($Mode.ToLower())-*.log"))
