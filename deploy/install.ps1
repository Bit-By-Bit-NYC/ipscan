<#
.SYNOPSIS
    Self-deleting, NON-ELEVATED bootstrap for the signed, ephemeral Angry IP
    Scanner. Runs entirely in the current user's context - no admin required.
    Distributed internally (share / RMM-in-user-context); downloads the signed
    payload from an Azure blob, verifies signatures, installs to the user's
    LOCALAPPDATA, schedules its own removal (at a timer AND at next logon), and
    deletes itself.

.DESCRIPTION
    This script is code-signed and intended to run under an AllSigned /
    RemoteSigned execution policy. The download base URL is baked in at sign
    time from signing.config.psd1; the SAS token is prompted (or -Sas) and
    distributed via IT Glue - never baked in.

    No elevation is used or required:
      - installs to %LOCALAPPDATA%\BBB\ipscan (user-writable),
      - registers the cleanup task in the CURRENT USER's context (users may
        create their own tasks without admin),
      - cleanup removes only this user's artifacts.

    Cleanup triggers (so the user need not stay logged on for the full window):
      - a one-time timer at expiry (fires if still logged on), and
      - an At-Logon trigger for this user (fires at the next logon if the timer
        was missed because the user signed off).
    The fleet sweep.ps1 (elevated, via RMM) is the backstop beyond that.

.PARAMETER PayloadBaseUrl  Non-secret base URL (no SAS). Baked in at sign time.
.PARAMETER Sas             Read-only SAS token (from IT Glue). Prompted if omitted.
.PARAMETER WindowMinutes   Deploy-to-cleanup TTL. Default 60.
.PARAMETER InstallDir      Defaults to %LOCALAPPDATA%\BBB\ipscan.
.PARAMETER OnInUse         'Extend' (default) grants one grace; 'Kill' removes now.
.PARAMETER GraceMinutes    Grace length when OnInUse=Extend. Default 30.
.PARAMETER NoLaunch        Do not auto-open the scanner after install.
.PARAMETER NoSelfDelete    Keep this bootstrap on disk (debugging).
.PARAMETER ExpectedSignerLike Publisher the payload must be signed by.

.EXAMPLE
    powershell -ExecutionPolicy AllSigned -File .\install.ps1 -WindowMinutes 90
#>
[CmdletBinding()]
param(
    [string]$PayloadBaseUrl    = '@@PAYLOAD_BASE_URL@@',
    [string]$Sas,
    [int]$WindowMinutes        = 60,
    [string]$InstallDir        = (Join-Path $env:LOCALAPPDATA 'BBB\ipscan'),
    [ValidateSet('Extend','Kill')][string]$OnInUse = 'Extend',
    [int]$GraceMinutes         = 30,
    [switch]$NoLaunch,
    [switch]$NoSelfDelete,
    [string]$ExpectedSignerLike = '*Bit by Bit Computer Consultants*'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$TaskName = "BBB-ipscan-cleanup-$env:USERNAME"   # per-user, avoids cross-user clash

$self = $PSCommandPath
if (-not $self) { $self = $MyInvocation.MyCommand.Definition }
function Remove-Self {
    if ($NoSelfDelete) { return }
    if ($self -and (Test-Path -LiteralPath $self)) {
        Start-Process -WindowStyle Hidden -FilePath cmd.exe `
            -ArgumentList '/c','ping 127.0.0.1 -n 3 >nul & del /f /q',"`"$self`""
    }
}

try {
    if ($PayloadBaseUrl -like '*@@PAYLOAD_BASE_URL@@*') {
        throw "PayloadBaseUrl is not set. This bootstrap must be built and signed by package-release.ps1."
    }
    # Guard against an accidental SYSTEM run (per-user paths would be wrong).
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        throw "Do not run as SYSTEM. This is a per-user install; run it in the tech's own session."
    }
    if (-not $Sas) { $Sas = Read-Host 'Paste the ipscan payload SAS token (from IT Glue)' }
    $Sas = $Sas.Trim().TrimStart('?')
    if (-not $Sas) { throw "No SAS token provided." }
    $PayloadUrl = "$PayloadBaseUrl`?$Sas"

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $tmp = Join-Path $env:TEMP ("ipscan-payload-{0}.zip" -f ([guid]::NewGuid().ToString('N')))
    Write-Host "Downloading payload..."
    Invoke-WebRequest -Uri $PayloadUrl -OutFile $tmp -UseBasicParsing

    Write-Host "Installing to $InstallDir"
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Expand-Archive -LiteralPath $tmp -DestinationPath $InstallDir -Force
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'logs') | Out-Null

    foreach ($rel in @('ipscan.exe','cleanup.ps1')) {
        $f = Join-Path $InstallDir $rel
        if (-not (Test-Path $f)) { throw "Payload missing $rel" }
        $sig = Get-AuthenticodeSignature -LiteralPath $f
        if ($sig.Status -ne 'Valid') { throw "$rel signature not Valid ($($sig.Status)): $($sig.StatusMessage)" }
        if ($sig.SignerCertificate.Subject -notlike $ExpectedSignerLike) {
            throw "$rel signed by unexpected subject: $($sig.SignerCertificate.Subject)"
        }
    }
    Write-Host "Signature verification OK."

    $now = Get-Date; $expires = $now.AddMinutes($WindowMinutes)
    [ordered]@{
        installDir    = $InstallDir
        version       = (Get-Item (Join-Path $InstallDir 'ipscan.exe')).VersionInfo.ProductVersion
        deployedUtc   = $now.ToUniversalTime().ToString('o')
        expiresUtc    = $expires.ToUniversalTime().ToString('o')
        windowMinutes = $WindowMinutes
        onInUse       = $OnInUse
        graceMinutes  = $GraceMinutes
        graceUsed     = $false
        deployedBy    = "$env:USERDOMAIN\$env:USERNAME"
        host          = $env:COMPUTERNAME
    } | ConvertTo-Json | Set-Content (Join-Path $InstallDir 'deploy-state.json') -Encoding UTF8

    # --- schedule cleanup: timer at expiry + at next logon (current user) ---
    $cleanup   = Join-Path $InstallDir 'cleanup.ps1'
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy AllSigned -File `"$cleanup`""
    $me        = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
    $triggers  = @(
        (New-ScheduledTaskTrigger -Once -At $expires),
        (New-ScheduledTaskTrigger -AtLogOn -User $me)
    )
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
        -Principal $principal -Settings $settings -Force | Out-Null

    # --- convenience: Start Menu shortcut (per-user) -----------------------
    try {
        $lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Angry IP Scanner (BBB).lnk'
        $ws  = New-Object -ComObject WScript.Shell
        $sc  = $ws.CreateShortcut($lnk)
        $sc.TargetPath = (Join-Path $InstallDir 'ipscan.exe')
        $sc.WorkingDirectory = $InstallDir
        $sc.Description = 'Angry IP Scanner (BBB internal, ephemeral)'
        $sc.Save()
    } catch { Write-Host "Shortcut creation skipped: $($_.Exception.Message)" }

    Write-Host "Installed ipscan; cleanup at $expires OR next logon (TTL ${WindowMinutes}m, OnInUse=$OnInUse)."
    Write-Host "Export scans into $InstallDir\logs so cleanup removes them with the tool."

    # --- auto-open the scanner (interactive only) --------------------------
    if (-not $NoLaunch -and [Environment]::UserInteractive) {
        Start-Process -FilePath (Join-Path $InstallDir 'ipscan.exe') -WorkingDirectory $InstallDir
        Write-Host "Launched ipscan.exe."
    }
    elseif (-not $NoLaunch) {
        Write-Host "Non-interactive session; not auto-launching. Run: $InstallDir\ipscan.exe"
    }
}
finally {
    Remove-Self
}
