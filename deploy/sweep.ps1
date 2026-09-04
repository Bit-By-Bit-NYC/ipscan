<#
.SYNOPSIS
    Fleet-wide safety-net sweep: find and optionally remove stray Angry IP
    Scanner deployments older than a TTL. Runs on its own RMM cadence,
    independent of any single deployment's cleanup task.

.DESCRIPTION
    Per-deployment cleanup (deploy.ps1 -> scheduled task -> cleanup.ps1) can fail
    to run: reboot before the trigger, RMM disconnect, task deleted, etc. This
    sweep is the backstop. For each server it runs on it:
      1. Locates deployments by deploy-state.json under known roots, plus any
         loose ipscan.exe under those roots.
      2. Computes age from deploy-state.json (expiresUtc) when present, else from
         the exe's last-write time.
      3. Reports every find; with -Remove, deletes those past TTL by invoking the
         local cleanup.ps1 when present (-Force), or a built-in fallback wipe.

    Default is report-only (safe). Pass -Remove to act. Emits one JSON object per
    finding to the pipeline and a summary to the host, so the RMM can collect it.

.PARAMETER MaxAgeHours
    A deployment is "stray" if older than this. Default 24.

.PARAMETER SearchRoots
    Roots to scan. Default: every user's %LOCALAPPDATA%\BBB (the per-user install
    location), plus C:\Users\*\AppData\Local\Temp, C:\ProgramData\BBB (legacy),
    and C:\Windows\Temp to catch copies left in temp locations.

.PARAMETER Remove
    Actually remove stray deployments. Without it, report only.

.EXAMPLE
    .\sweep.ps1                 # report
    .\sweep.ps1 -Remove         # enforce
#>
[CmdletBinding()]
param(
    [int]$MaxAgeHours = 24,
    [string[]]$SearchRoots = @(
        'C:\ProgramData\BBB',
        'C:\Windows\Temp'
    ),
    [switch]$Remove
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

$now = (Get-Date).ToUniversalTime()
$roots = [System.Collections.Generic.List[string]]::new()
$SearchRoots | ForEach-Object { $roots.Add($_) }
Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $roots.Add((Join-Path $_.FullName 'AppData\Local\BBB'))
    $roots.Add((Join-Path $_.FullName 'AppData\Local\Temp'))
}

$findings = [System.Collections.Generic.List[object]]::new()
$seenDirs = [System.Collections.Generic.HashSet[string]]::new()

function Add-Finding($dir, $exePath, $ageHours, $reason, $source) {
    if (-not $seenDirs.Add($dir.ToLowerInvariant())) { return }
    $findings.Add([pscustomobject]@{
        Host      = $env:COMPUTERNAME
        Dir       = $dir
        Exe       = $exePath
        AgeHours  = [math]::Round($ageHours, 1)
        Stray     = ($ageHours -gt $MaxAgeHours)
        Reason    = $reason
        AgeSource = $source
    })
}

foreach ($root in ($roots | Select-Object -Unique)) {
    if (-not (Test-Path $root)) { continue }

    # 1) deployments identified by state file
    Get-ChildItem $root -Recurse -Filter 'deploy-state.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $dir = Split-Path $_.FullName -Parent
        $exe = Join-Path $dir 'ipscan.exe'
        $ageH = $null; $src = 'expiresUtc'
        try {
            $st = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $ageH = ($now - ([datetime]$st.expiresUtc).ToUniversalTime()).TotalHours
        } catch { $ageH = ($now - $_.LastWriteTimeUtc).TotalHours; $src = 'state-mtime' }
        Add-Finding $dir (Test-Path $exe ? $exe : '') $ageH 'has deploy-state.json' $src
    }

    # 2) loose ipscan.exe without state (unmanaged / manual copy)
    Get-ChildItem $root -Recurse -Filter 'ipscan.exe' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $dir = Split-Path $_.FullName -Parent
        if ($seenDirs.Contains($dir.ToLowerInvariant())) { return }
        $ageH = ($now - $_.LastWriteTimeUtc).TotalHours
        Add-Finding $dir $_.FullName $ageH 'loose ipscan.exe (no state)' 'exe-mtime'
    }
}

$strays = @($findings | Where-Object Stray)

if ($Remove -and $strays.Count -gt 0) {
    foreach ($s in $strays) {
        Write-Host "Removing stray: $($s.Dir) (age $($s.AgeHours)h)"
        # Sweep is the elevated (RMM/SYSTEM) fleet backstop: it removes the install
        # dir directly. A stray belonging to another user is disabled by removing
        # the dir; that user's own prefs node / task are left for their next
        # logon-cleanup (harmless settings, and not reachable cross-user here).
        Get-CimInstance Win32_Process -Filter "Name='ipscan.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($s.Dir,[StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep 1
        Remove-Item $s.Dir -Recurse -Force -ErrorAction SilentlyContinue
        $s | Add-Member -NotePropertyName Removed -NotePropertyValue (-not (Test-Path $s.Dir)) -Force
    }
}

# Emit findings (objects to pipeline for RMM capture) + human summary
$findings
Write-Host ("`nSweep on {0}: {1} deployment(s), {2} stray (TTL {3}h), Remove={4}." -f `
    $env:COMPUTERNAME, $findings.Count, $strays.Count, $MaxAgeHours, [bool]$Remove)
