# Where the T3 checkout, Node and the installed T3 live. Dot-source it.
# Defaults suit a fresh clone; t3-quota.local.json (never committed) can override any of them:
#   { "t3Source": "D:\\src\\t3code", "nodeDir": "D:\\tools\\node-26", "t3Install": "..." }
# Windows PowerShell 5.1 compatible.
$QuotaRoot = Split-Path -Parent $PSScriptRoot
$localConfigPath = Join-Path $QuotaRoot 't3-quota.local.json'
# A broken file must stop the run rather than silently fall back to other paths.
$localConfig = if (Test-Path -LiteralPath $localConfigPath) { Get-Content -LiteralPath $localConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop } else { $null }
function LocalSetting([string]$name, [string]$default) {
    if ($null -ne $localConfig -and $localConfig.PSObject.Properties[$name] -and $localConfig.$name) { return [string]$localConfig.$name }
    return $default
}

$T3Source = LocalSetting 't3Source' (Join-Path $QuotaRoot 'work\t3code')
$T3Install = LocalSetting 't3Install' (Join-Path $env:LOCALAPPDATA 'Programs\t3code')
$nodeDir = LocalSetting 'nodeDir' ''
$NodeExe = if ($nodeDir) { Join-Path $nodeDir 'node.exe' } else {
    $found = Get-Command node -ErrorAction SilentlyContinue
    if ($found) { $found.Source } else { $null }
}
$NodeDir = if ($NodeExe) { Split-Path -Parent $NodeExe } else { $null }
# T3 keeps its state under T3CODE_HOME (default ~\.t3); runtime state is in its userdata folder.
$t3Home = if ($env:T3CODE_HOME) { $env:T3CODE_HOME } else { Join-Path $env:USERPROFILE '.t3' }
$T3UserData = Join-Path $t3Home 'userdata'
