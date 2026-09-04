<#
.SYNOPSIS
    Remove the ephemeral Angry IP Scanner for the CURRENT USER. Non-elevated:
    touches only this user's install dir, settings, prefs, task, and shortcut.

.DESCRIPTION
    Invoked by the per-user scheduled task registered by install.ps1 - which
    fires at the expiry timer AND at the user's next logon, so cleanup happens
    even if the user signed off before the timer. Also runnable by hand.

    "Still in use" handling (deploy-state.json -> onInUse):
      Extend (default): if ipscan.exe is running and the one grace extension has
                        not been used, re-arm the timer for graceMinutes later,
                        mark graceUsed, and exit without deleting.
      Kill            : terminate ipscan.exe and delete now.

.PARAMETER InstallDir  Defaults to %LOCALAPPDATA%\BBB\ipscan.
.PARAMETER Force       Skip grace; delete now (terminating ipscan.exe if running).

.EXAMPLE
    .\cleanup.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'BBB\ipscan'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$TaskName  = "BBB-ipscan-cleanup-$env:USERNAME"
$statePath = Join-Path $InstallDir 'deploy-state.json'

$state = $null
if (Test-Path $statePath) { try { $state = Get-Content $statePath -Raw | ConvertFrom-Json } catch { $state = $null } }
$onInUse      = if ($state -and $state.onInUse)      { $state.onInUse }        else { 'Extend' }
$graceMinutes = if ($state -and $state.graceMinutes) { [int]$state.graceMinutes } else { 30 }
$graceUsed    = [bool]($state -and $state.graceUsed)

# Only our own instance, running from this install dir.
$running = @(Get-CimInstance Win32_Process -Filter "Name='ipscan.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) })

if ($running.Count -gt 0 -and -not $Force) {
    if ($onInUse -eq 'Extend' -and -not $graceUsed) {
        $next = (Get-Date).AddMinutes($graceMinutes)
        Write-Host "ipscan.exe in use; granting one grace extension until $next."
        if ($state) { $state.graceUsed = $true; $state | ConvertTo-Json | Set-Content $statePath -Encoding UTF8 }
        try {
            # Keep the logon trigger; refresh the timer to $next.
            $me = "$env:USERDOMAIN\$env:USERNAME"
            $triggers = @((New-ScheduledTaskTrigger -Once -At $next), (New-ScheduledTaskTrigger -AtLogOn -User $me))
            Set-ScheduledTask -TaskName $TaskName -Trigger $triggers | Out-Null
        } catch { Write-Host "Could not re-arm task: $($_.Exception.Message)" }
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

# --- current user's prefs node (Java Preferences -> HKCU registry) ----------
$node = 'HKCU:\Software\JavaSoft\Prefs\ipscan'
if (Test-Path $node) { Remove-Item $node -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "Removed prefs: $node" }

# --- current user's .ipscan / crash file ------------------------------------
$dot = Join-Path $env:USERPROFILE '.ipscan'
if (Test-Path $dot) { Remove-Item $dot -Recurse -Force -ErrorAction SilentlyContinue; Write-Host "Removed $dot" }
$crash = Join-Path $env:USERPROFILE '.swt\ipscan-crash.txt'
if (Test-Path $crash) { Remove-Item $crash -Force -ErrorAction SilentlyContinue }

# --- Start Menu shortcut ----------------------------------------------------
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Angry IP Scanner (BBB).lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue }

# --- install dir (exe, jre, cleanup.ps1, logs, state) -----------------------
if (Test-Path $InstallDir) {
    Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) { Write-Host "Install dir partially locked (running script); will clear on next run." }
    else { Write-Host "Removed $InstallDir" }
}

# --- remove this user's scheduled task --------------------------------------
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Cleanup complete for $env:USERNAME on $env:COMPUTERNAME."
