# Puts the newest official T3 backup (and its update feed) back, then restarts T3.
# claude-quota.json stays; official T3 ignores it.
& (Join-Path $PSScriptRoot 'tools\start-swap-task.ps1') -Mode Restore -DelaySeconds 5
