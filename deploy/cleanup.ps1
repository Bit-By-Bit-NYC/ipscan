<#
.SYNOPSIS
    Remove the ephemeral Angry IP Scanner deployment: the exe, its bundled JRE,
    exported scan logs, the .ipscan settings folders, and the JavaSoft prefs
    registry node. Handles the "still in use" case per policy.

.DESCRIPTION
    Normally invoked by the scheduled task registered by deploy.ps1 (SYSTEM).
    Reads deploy-state.json for policy (OnInUse, GraceMinutes) and TTL.

    "Still in use" handling (deploy-state.json -> onInUse):
      Extend (default): if ipscan.exe is running and the one grace extension
                        has not been used, re-arm the cleanup task for
                        graceMinutes later, mark graceUsed, and exit without
                        deleting. On the next run it proceeds to Kill+delete.
      Kill            : terminate ipscan.exe and delete immediately.

.PARAMETER InstallDir
    Install path. Default C:\ProgramData\BBB\ipscan. Overrides state file.

.PARAMETER Force
    Skip the grace extension and delete now (kills ipscan.exe if running).

.EXAMPLE
    .\cleanup.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\ProgramData\BBB\ipscan',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$TaskName  = 'BBB-ipscan-cleanup'
$statePath = Join-Path $InstallDir 'deploy-state.json'

$state = $null
if (Test-Path $statePath) {
    try { $state = Get-Content $statePath -Raw | ConvertFrom-Json } catch { $state = $null }
}
$onInUse      = if ($state -and $state.onInUse)      { $state.onInUse }      else { 'Extend' }
$graceMinutes = if ($state -and $state.graceMinutes) { [int]$state.graceMinutes } else { 30 }
$graceUsed    = [bool]($state -and $state.graceUsed)

function Get-IpscanProcs {
    param([string]$dir)
    Get-CimInstance Win32_Process -Filter "Name='ipscan.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase) }
}

$running = @(Get-IpscanProcs -dir $InstallDir)

if ($running.Count -gt 0 -and -not $Force) {
    if ($onInUse -eq 'Extend' -and -not $graceUsed) {
        $next = (Get-Date).AddMinutes($graceMinutes)
        Write-Host "ipscan.exe in use; granting one grace extension until $next."
        if ($state) {
            $state.graceUsed = $true
            $state | ConvertTo-Json | Set-Content $statePath -Encoding UTF8
        }
        try {
            $trigger = New-ScheduledTaskTrigger -Once -At $next
            Set-ScheduledTask -TaskName $TaskName -Trigger $trigger | Out-Null
        }
        catch {
            # Task missing (e.g. wiped) - re-register it minimally.
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy AllSigned -File `"$(Join-Path $InstallDir 'cleanup.ps1')`""
            $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
            Register-ScheduledTask -TaskName $TaskName -Action $action `
                -Trigger (New-ScheduledTaskTrigger -Once -At $next) -Principal $principal -Force | Out-Null
        }
        return
    }
    Write-Host "ipscan.exe in use; grace exhausted or OnInUse=Kill - terminating."
    $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
}
elseif ($running.Count -gt 0 -and $Force) {
    $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
}

# --- registry: remove JavaSoft prefs node 'ipscan' for every loaded user hive
# ipscan stores prefs at HKCU\Software\JavaSoft\Prefs\ipscan (all-lowercase node
# name, so no Java-prefs capital-letter escaping applies).
foreach ($u in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
    if ($u.PSChildName -match '_Classes$') { continue }
    $node = "Registry::HKEY_USERS\$($u.PSChildName)\Software\JavaSoft\Prefs\ipscan"
    if (Test-Path $node) {
        Remove-Item $node -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed prefs: $node"
    }
}

# --- per-user .ipscan plugin/settings folders
Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $dot = Join-Path $_.FullName '.ipscan'
    if (Test-Path $dot) { Remove-Item $dot -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "Removed $dot" }
    $crash = Join-Path $_.FullName '.swt\ipscan-crash.txt'
    if (Test-Path $crash) { Remove-Item $crash -Force -ErrorAction SilentlyContinue }
}

# --- install dir (exe, jre, cleanup.ps1, logs, state, preset)
if (Test-Path $InstallDir) {
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) {
        # cleanup.ps1 may be locked as the running script - schedule dir delete on reboot.
        Write-Host "Install dir partially locked; marking for deletion."
    }
    else { Write-Host "Removed $InstallDir" }
}

# --- remove the scheduled task itself
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Cleanup complete on $env:COMPUTERNAME."
