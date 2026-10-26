# Applies claude-quota.patch to the installed T3 Code version, builds it, checks it
# in an isolated copy against the real accounts (observe only, nothing is sent),
# then swaps it into the installed T3 and restarts T3.
#
#   .\Update-T3-Quota.ps1              full run
#   .\Update-T3-Quota.ps1 -NoRestart   stop after the isolated check
#   .\Update-T3-Quota.ps1 -SkipBuild   reuse the last build (after a failed later step)
param([switch]$NoRestart, [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'tools\paths.ps1')
$root = $QuotaRoot
$source = $T3Source
$node = $NodeExe
$install = $T3Install
$work = Join-Path $root 'work'
$patch = Join-Path $root 'claude-quota.patch'
if (!$node) { throw 'Node.js was not found. Install the Node version T3 requires, or set nodeDir in t3-quota.local.json.' }
if (!(Test-Path -LiteralPath (Join-Path $install 'resources\app.asar'))) { throw "T3 Code is not installed at $install (set t3Install in t3-quota.local.json)." }
$env:PATH = $NodeDir + ';' + $env:PATH
New-Item -ItemType Directory -Force -Path $work | Out-Null
function Step([string]$m) { Write-Output ("== " + $m) }
# Windows PowerShell 5 turns any native stderr line into a terminating error under 'Stop',
# so native tools are judged by exit code only.
function Native([string]$what, [scriptblock]$run) {
    $ErrorActionPreference = 'Continue'
    & $run
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit $LASTEXITCODE)." }
}

# The T3 checkout the patch is applied to; cloned on first use.
if (!(Test-Path -LiteralPath (Join-Path $source '.git'))) {
    Step "Cloning T3 Code into $source"
    Native 'git clone' { git clone -q https://github.com/pingdotgg/t3code.git $source }
}
# asar-version.mjs and stage-asars.mjs load @electron/asar from the checkout's dependencies.
if (!(Test-Path -LiteralPath (Join-Path $source 'node_modules\.pnpm'))) {
    $globalVp = Get-Command vp -ErrorAction SilentlyContinue
    if (!$globalVp) { throw 'vp (Vite+) is needed once to install T3 dependencies: irm https://vite.plus/ps1 | iex' }
    Step 'Installing T3 dependencies (first run)'
    Push-Location -LiteralPath $source
    try { Native 'vp i' { & $globalVp.Source i *> (Join-Path $work 'install.log') } } finally { Pop-Location }
}
$vp = Join-Path $source 'node_modules\.bin\vp.cmd'

# 1. Which official version is this based on? The patched build is versioned <official>+quota
#    (build metadata, so the updater sees it as equal to the official release, not older).
$installedVersion = (Native 'read installed version' { & $node (Join-Path $root 'tools\asar-version.mjs') (Join-Path $install 'resources\app.asar') $source } | Select-Object -Last 1).Trim()
$official = $installedVersion -replace '[-+]quota$', ''
if ($official -eq $installedVersion) {
    $officialResources = Join-Path $install 'resources'
} else {
    $officialResources = Join-Path $root "backup\official-$official\resources"
    if (!(Test-Path -LiteralPath (Join-Path $officialResources 'server.asar'))) { throw "The installed T3 is patched and backup\official-$official is missing." }
}
$version = "$official+quota"
Step "Official T3 $official -> building $version"

# 2. Patch and build.
if (!$SkipBuild) {
    Push-Location -LiteralPath $source
    try {
        $tag = "v$official"
        git rev-parse -q --verify "refs/tags/$tag" | Out-Null
        if ($LASTEXITCODE -ne 0) { Native 'git fetch' { git fetch origin tag $tag --no-tags } }
        Native 'git checkout' { git checkout -f -q --detach $tag }
        foreach ($f in 'apps\server\src\orchestration-v2\ClaudeQuotaAutopilot.ts', 'apps\server\src\orchestration-v2\ClaudeQuotaAutopilot.test.ts') {
            if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force }
        }
        $ErrorActionPreference = 'Continue'
        git apply --check $patch 2>&1 | Out-Null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -ne 0) { throw "claude-quota.patch does not apply to $tag. See 'Porting to a new T3 release' in README.md." }
        Native 'git apply' { git apply $patch }
        $wantNode = (Get-Content -LiteralPath 'package.json' -Raw | ConvertFrom-Json).engines.node
        $haveNode = (& $node --version).TrimStart('v')
        if ($wantNode -and $haveNode -ne $wantNode) { throw "T3 $tag needs Node $wantNode, but $node is $haveNode. Install it and set nodeDir in t3-quota.local.json." }
        $lockHash = (Get-FileHash -LiteralPath 'pnpm-lock.yaml').Hash
        $lockMark = Join-Path $work 'installed-lock.sha256'
        if (!(Test-Path -LiteralPath $lockMark) -or (Get-Content -LiteralPath $lockMark -Raw).Trim() -ne $lockHash) {
            Step 'Installing dependencies'
            Native 'vp i' { & $vp i *> (Join-Path $work 'install.log') }
            Set-Content -LiteralPath $lockMark -Value $lockHash
        }
        Step 'Testing'
        Native 'tests' { & $vp test run apps/server/src/orchestration-v2/ClaudeQuotaAutopilot.test.ts apps/server/src/orchestration-v2/runtimeLayer.test.ts apps/server/src/provider/claudeUsageLimits.test.ts apps/server/src/provider/ProviderRegistry.test.ts apps/server/src/ws.test.ts packages/client-runtime/src/state/usage.test.ts apps/mobile/src/features/usage/UsageLimitsSection.test.ts *> (Join-Path $work 'tests.log') }
        Step 'Building'
        $releaseFiles = 'apps/server/package.json', 'apps/desktop/package.json', 'apps/web/package.json', 'packages/contracts/package.json'
        # Official CI bakes public config (T3 Connect sign-in, relay, telemetry channel) into the
        # bundles; without it a local build silently loses T3 Connect. Reuse the official values.
        $buildEnv = Native 'read official build config' { & $node (Join-Path $root 'tools\build-config.mjs') env $officialResources $source }
        $buildEnvNames = @()
        try {
            Native 'version update' { & $node scripts/update-release-package-versions.ts $version *> (Join-Path $work 'version.log') }
            $env:APP_VERSION = $version
            foreach ($line in $buildEnv) {
                $name, $value = $line -split '=', 2
                Set-Item -LiteralPath "Env:$name" -Value $value
                $buildEnvNames += $name
            }
            Native 'build' { & $vp run build:desktop *> (Join-Path $work 'build.log') }
        } finally {
            Remove-Item Env:APP_VERSION -ErrorAction SilentlyContinue
            foreach ($name in $buildEnvNames) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            git checkout -q -- $releaseFiles
        }
    } finally { Pop-Location }
}

# 3. Patched archives = official archives with the two compiled bundles replaced.
Step 'Packaging'
Native 'stage' { & $node (Join-Path $root 'tools\stage-asars.mjs') $officialResources $source (Join-Path $work 'stage\resources') $version }
Native 'build config check' { & $node (Join-Path $root 'tools\build-config.mjs') verify $officialResources (Join-Path $work 'stage\resources') $source }

# 4. Isolated check with the real accounts, observe only.
Step 'Checking an isolated copy against the real accounts (observe only)'
$smoke = Join-Path $work 'smoke'
if ([IO.Path]::GetFullPath($smoke) -ne [IO.Path]::GetFullPath((Join-Path $root 'work\smoke'))) { throw 'Unexpected smoke directory.' }
if (Test-Path -LiteralPath $smoke) { Remove-Item -LiteralPath $smoke -Recurse -Force }
$smokeInstall = Join-Path $smoke 'install'
$smokeHome = Join-Path $smoke 'home'
New-Item -ItemType Directory -Force -Path (Join-Path $smokeHome 'userdata'), (Join-Path $smoke 'roaming') | Out-Null
robocopy $install $smokeInstall /E /XD resources /NFL /NDL /NJH /NJS /NP | Out-Null
robocopy (Join-Path $install 'resources') (Join-Path $smokeInstall 'resources') /E /XD app.asar.unpacked server.asar.unpacked /XF app.asar server.asar app-update.yml /NFL /NDL /NJH /NJS /NP | Out-Null
Copy-Item -Path (Join-Path $work 'stage\resources\*') -Destination (Join-Path $smokeInstall 'resources') -Recurse -Force
$live = Get-Content -LiteralPath (Join-Path $T3UserData 'settings.json') -Raw | ConvertFrom-Json
@{ providerInstances = $live.providerInstances } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $smokeHome 'userdata\settings.json') -Encoding utf8
# The check uses your real config (or the example on a first install), forced to observe only.
$liveQuota = Join-Path $T3UserData 'claude-quota.json'
$quotaPath = if (Test-Path -LiteralPath $liveQuota) { $liveQuota } else { Join-Path $root 'claude-quota.example.json' }
$quota = Get-Content -LiteralPath $quotaPath -Raw | ConvertFrom-Json
$quota.observeOnly = $true
$quota | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $smokeHome 'userdata\claude-quota.json') -Encoding utf8

$saved = @{}
foreach ($name in @(Get-ChildItem Env: | Where-Object { $_.Name -match '^(CLAUDE|T3CODE_|VITE_|ELECTRON_RUN_AS_NODE|T3_)' } | ForEach-Object Name)) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name); Remove-Item "Env:$name"
}
$saved['APPDATA'] = $env:APPDATA
$env:APPDATA = Join-Path $smoke 'roaming'; $env:T3CODE_HOME = $smokeHome; $env:T3CODE_PORT = '14775'
$env:T3CODE_DISABLE_AUTO_UPDATE = 'true'; $env:T3CODE_DESKTOP_APP_USER_MODEL_ID = 'local.t3code.quota.check'; $env:T3CODE_DEV_SEED = '0'
try { $proc = Start-Process -FilePath (Join-Path $smokeInstall 'T3 Code (Beta).exe') -WindowStyle Hidden -PassThru }
finally {
    foreach ($name in 'T3CODE_HOME', 'T3CODE_PORT', 'T3CODE_DISABLE_AUTO_UPDATE', 'T3CODE_DESKTOP_APP_USER_MODEL_ID', 'T3CODE_DEV_SEED') { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
$smokeLog = Join-Path $smokeHome 'userdata\logs\claude-quota.ndjson'
$accounts = @($quota.accounts)
if ($accounts.Count -eq 0 -and $live.providerInstances) {
    # An empty pool means every Claude instance, so expect a reading from each enabled one.
    $accounts = @($live.providerInstances.PSObject.Properties | Where-Object { $_.Value.driver -eq 'claudeAgent' -and $_.Value.enabled -ne $false } | ForEach-Object Name)
}
# T3's built-in Claude instance is not listed in settings until it is edited.
if ($accounts.Count -eq 0) { $accounts = @('claudeAgent') }
$problems = @()
try {
    $deadline = (Get-Date).AddMinutes(4)
    $seen = @{}
    while ((Get-Date) -lt $deadline -and $seen.Count -lt $accounts.Count) {
        Start-Sleep -Seconds 5
        if (!(Test-Path -LiteralPath $smokeLog)) { continue }
        foreach ($line in Get-Content -LiteralPath $smokeLog -Encoding UTF8) {
            $entry = $line | ConvertFrom-Json
            if ($entry.event -eq 'account' -and $null -ne $entry.sessionRemaining) { $seen[$entry.account] = $entry }
            if ($entry.event -eq 'sweep_failed') { $problems += "sweep_failed: $($entry.cause)" }
        }
    }
    foreach ($a in $accounts) { if (!$seen.ContainsKey($a)) { $problems += "no quota reading for $a" } }
    try { $environment = Invoke-RestMethod -Uri 'http://127.0.0.1:14775/.well-known/t3/environment' -TimeoutSec 10 } catch { $problems += 'server not answering' }
    if ($environment -and $environment.serverVersion -ne $version) { $problems += "server reports $($environment.serverVersion)" }
    foreach ($a in $accounts) {
        if ($seen.ContainsKey($a)) { $e = $seen[$a]; Write-Output ("   {0,-14} 5h left {1,5}%  weekly left {2,5}%" -f $a, $e.sessionRemaining, $e.weeklyRemaining) }
    }
} finally {
    & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
}
if ($problems.Count) { throw ("Isolated check failed: " + ($problems -join '; ') + ". Log: $smokeLog") }
Step "Isolated check passed (server $version, all $($accounts.Count) accounts read)"

# 5. Swap into the installed T3 and restart it.
if ($NoRestart) { Step 'Stopped before restart (-NoRestart).'; return }
& (Join-Path $root 'tools\start-swap-task.ps1') -Mode Deploy -DelaySeconds 20
