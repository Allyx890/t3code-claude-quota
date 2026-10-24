# Stops the installed T3 Code, swaps its resources and starts it again.
#   -Mode Deploy  : install work\stage (backs up the official files first)
#   -Mode Restore : put the newest official backup back
# Runs from a scheduled task (start-swap-task.ps1) so it survives T3, and the
# agent running inside T3, exiting. Windows PowerShell 5.1 compatible.
param(
    [ValidateSet('Deploy', 'Restore')][string]$Mode = 'Deploy',
    [int]$DelaySeconds = 0
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'paths.ps1')
$root = $QuotaRoot
$install = $T3Install
$exe = Join-Path $install 'T3 Code (Beta).exe'
$resources = Join-Path $install 'resources'
$stage = Join-Path $root 'work\stage\resources'
$node = $NodeExe
$userdata = $T3UserData
$quotaLog = Join-Path $userdata 'logs\claude-quota.ndjson'
$items = @('app.asar', 'app.asar.unpacked', 'server.asar', 'server.asar.unpacked')
$logPath = Join-Path $root ("work\swap-{0}-{1}.log" -f $Mode.ToLower(), (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Log([string]$m) { Add-Content -LiteralPath $logPath -Value ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 }
function InstallProcesses { @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($install + '\', [StringComparison]::OrdinalIgnoreCase) }) }
function Replace([string]$from, [string]$to) {
    if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }
    Copy-Item -LiteralPath $from -Destination $to -Recurse -Force
}
# Native tools report expected refusals on stderr; under 5.1 with Stop that would abort the swap.
function RunNative([string]$file, [string[]]$arguments) {
    (Start-Process -FilePath $file -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru).ExitCode
}
# explorer.exe starts T3 with the normal desktop environment, not this script's.
function Launch { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $exe); Log 'T3 started.' }
function ArchiveVersion([string]$archive) {
    $ErrorActionPreference = 'Continue'
    (& $node (Join-Path $PSScriptRoot 'asar-version.mjs') $archive $T3Source | Select-Object -Last 1)
}

try {
    Log "Mode $Mode, delay $DelaySeconds s"
    if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
    if ($Mode -eq 'Deploy') {
        $report = Get-Content -LiteralPath (Join-Path $root 'work\stage\stage-report.json') -Raw | ConvertFrom-Json
        $official = $report.archives[0].officialVersion
        $backup = Join-Path $root "backup\official-$official"
        $source = $stage
    } else {
        $backup = (Get-ChildItem -LiteralPath (Join-Path $root 'backup') -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
        $source = Join-Path $backup 'resources'
    }
    foreach ($n in $items) { if (!(Test-Path -LiteralPath (Join-Path $source $n))) { throw "$source\$n is missing." } }
    $haveBackup = Test-Path -LiteralPath (Join-Path $backup 'resources\server.asar')
    if ($Mode -eq 'Deploy' -and !$haveBackup -and ((ArchiveVersion (Join-Path $resources 'app.asar')) -match '[-+]quota$')) {
        throw 'No official backup and the installed T3 is not an official build; refusing to back up a patched build.'
    }

    # 1. Stop T3: polite close of the main process, then force only processes running from the install.
    $procs = InstallProcesses
    Log ('Running T3 processes: ' + (($procs | ForEach-Object { $_.ProcessId }) -join ','))
    $roots = $procs | Where-Object { $p = $_; -not ($procs | Where-Object { $_.ProcessId -eq $p.ParentProcessId }) }
    foreach ($r in $roots) { Log ("Polite close {0}: exit {1}" -f $r.ProcessId, (RunNative 'taskkill.exe' @('/PID', [string]$r.ProcessId))) }
    $deadline = (Get-Date).AddSeconds(20)
    while ((InstallProcesses).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    foreach ($r in $roots) { Log ("Force close {0}: exit {1}" -f $r.ProcessId, (RunNative 'taskkill.exe' @('/PID', [string]$r.ProcessId, '/T', '/F'))) }
    Start-Sleep -Seconds 1
    foreach ($p in InstallProcesses) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    $deadline = (Get-Date).AddSeconds(15)
    while ((InstallProcesses).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if ((InstallProcesses).Count -gt 0) { throw 'T3 did not exit; nothing was changed.' }
    Log 'T3 stopped.'
    Start-Sleep -Seconds 2

    # 2. Back up the official files once; an existing backup is never overwritten.
    if ($Mode -eq 'Deploy' -and !$haveBackup) {
        New-Item -ItemType Directory -Force -Path (Join-Path $backup 'resources') | Out-Null
        foreach ($n in $items + @('app-update.yml')) { Replace (Join-Path $resources $n) (Join-Path $backup "resources\$n") }
        Copy-Item -LiteralPath (Join-Path $userdata 'settings.json') -Destination (Join-Path $backup 'settings.json') -Force
        Log "Official files backed up to $backup."
    }

    # 3. Swap. Any failure puts the official files back.
    try {
        foreach ($n in $items) { Replace (Join-Path $source $n) (Join-Path $resources $n) }
        # The update feed stays: T3 only announces updates (no auto download or install), and
        # the +quota version compares equal to the official release, so only newer ones show.
        Copy-Item -LiteralPath (Join-Path $backup 'resources\app-update.yml') -Destination (Join-Path $resources 'app-update.yml') -Force
        foreach ($n in @('app.asar', 'server.asar')) {
            if ((Get-FileHash -LiteralPath (Join-Path $source $n)).Hash -ne (Get-FileHash -LiteralPath (Join-Path $resources $n)).Hash) { throw "$n hash mismatch after copy." }
        }
        Log "Resources swapped ($Mode) from $source."
    } catch {
        Log ('Swap failed: ' + $_.Exception.Message + ' -> restoring official files')
        foreach ($n in $items) { Replace (Join-Path $backup "resources\$n") (Join-Path $resources $n) }
        Copy-Item -LiteralPath (Join-Path $backup 'resources\app-update.yml') -Destination (Join-Path $resources 'app-update.yml') -Force
        throw
    }

    if ($Mode -eq 'Deploy') {
        $code = RunNative $node @(('"{0}"' -f (Join-Path $PSScriptRoot 'prepare-settings.mjs')), ('"{0}"' -f (Join-Path $userdata 'settings.json')), ('"{0}"' -f (Join-Path $userdata 'claude-quota.json')), ('"{0}"' -f (Join-Path $root 'claude-quota.example.json')))
        Log "Settings prepared: exit $code"
    }

    # 4. Start T3 again and wait for the autopilot to report in.
    $since = (Get-Date).ToUniversalTime()
    Launch
    if ($Mode -eq 'Deploy') {
        $deadline = (Get-Date).AddSeconds(180)
        $ok = $false
        while (-not $ok -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            if (Test-Path -LiteralPath $quotaLog) {
                foreach ($line in Get-Content -LiteralPath $quotaLog -Tail 40 -Encoding UTF8) {
                    if ($line -match '"at":"([^"]+)","event":"started"' -and [DateTime]::Parse($Matches[1]).ToUniversalTime() -ge $since.AddSeconds(-5)) { $ok = $true }
                }
            }
        }
        if ($ok) { Log 'Verified: the new build logged "started".' } else { Log 'WARNING: no "started" entry within 180 s.' }
        if (Test-Path -LiteralPath $quotaLog) { Get-Content -LiteralPath $quotaLog -Tail 8 -Encoding UTF8 | ForEach-Object { Log ('  ' + $_) } }
    }
    Log 'Done.'
} catch {
    Log ('ERROR: ' + $_.Exception.Message)
    if ((InstallProcesses).Count -eq 0) { Launch }
    exit 1
}
