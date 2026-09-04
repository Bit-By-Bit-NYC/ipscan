<#
.SYNOPSIS
    Self-deleting bootstrap installer for the signed, ephemeral Angry IP Scanner.
    Distributed internally (RMM / share); downloads the signed payload from an
    Azure blob, verifies signatures, installs to a fixed path, schedules
    removal after a fixed window, then deletes itself.

.DESCRIPTION
    This script is code-signed and intended to run under an AllSigned /
    RemoteSigned execution policy. Because the signature block is appended to
    the file, the download URL and install defaults below are baked in at sign
    time from signing.config.psd1 - do not edit a signed copy.

    Flow:
      1. Download the payload zip from -PayloadUrl (default baked in).
      2. Extract to the install dir. Verify Authenticode on ipscan.exe and
         cleanup.ps1 (Valid + expected signer) before arming anything.
      3. Write deploy-state.json (version, deploy time, TTL, in-use policy).
      4. Register a one-time SYSTEM scheduled task that runs cleanup.ps1 at
         expiry (the uninstaller).
      5. Self-delete (regardless of where this bootstrap was run from).

.PARAMETER PayloadBaseUrl
    Non-secret HTTPS base URL of the payload zip (no SAS). Baked in at sign time.

.PARAMETER Sas
    The read-only SAS token for the payload blob (distributed via IT Glue). If
    omitted, the script prompts for it. Accepts the token with or without a
    leading '?'. Not baked into the signed script, so rotating it needs no
    re-sign.

.PARAMETER WindowMinutes
    Deploy-to-cleanup TTL in minutes. Default baked in (60). A parameter, not
    hardcoded, so a caller/RMM can widen the window per engagement.

.PARAMETER InstallDir
    Fixed install path. Default baked in (C:\ProgramData\BBB\ipscan).

.PARAMETER OnInUse
    Cleanup behavior if ipscan.exe is running at cleanup time:
    'Extend' (default) grants one grace extension; 'Kill' terminates + deletes.

.PARAMETER GraceMinutes
    Grace length used when OnInUse=Extend. Default baked in (30).

.PARAMETER ExpectedSignerLike
    Wildcard the downloaded payload's signer subject must match, as a
    tamper/authenticity check on top of the transport. Default matches the BBB
    signing subject.

.PARAMETER NoSelfDelete
    Keep this bootstrap on disk after running (debugging).

.EXAMPLE
    powershell -ExecutionPolicy AllSigned -File .\install.ps1 -WindowMinutes 90
#>
[CmdletBinding()]
param(
    [string]$PayloadBaseUrl    = '@@PAYLOAD_BASE_URL@@',
    [string]$Sas,
    [int]$WindowMinutes        = 60,
    [string]$InstallDir        = 'C:\ProgramData\BBB\ipscan',
    [ValidateSet('Extend','Kill')][string]$OnInUse = 'Extend',
    [int]$GraceMinutes         = 30,
    [string]$ExpectedSignerLike = '*Bit by Bit Computer Consultants*',
    [switch]$NoSelfDelete
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$TaskName = 'BBB-ipscan-cleanup'

# --- resolve own path up front (for self-delete), independent of cwd --------
$self = $PSCommandPath
if (-not $self) { $self = $MyInvocation.MyCommand.Definition }

function Remove-Self {
    if ($NoSelfDelete) { return }
    if ($self -and (Test-Path -LiteralPath $self)) {
        # Detached child waits for this process to exit, then deletes the file.
        Start-Process -WindowStyle Hidden -FilePath cmd.exe `
            -ArgumentList '/c','ping 127.0.0.1 -n 3 >nul & del /f /q',"`"$self`""
    }
}

try {
    if ($PayloadBaseUrl -like '*@@PAYLOAD_BASE_URL@@*') {
        throw "PayloadBaseUrl is not set. This bootstrap must be built and signed by package-release.ps1."
    }
    if (-not $Sas) {
        $Sas = Read-Host 'Paste the ipscan payload SAS token (from IT Glue)'
    }
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

    # --- verify signatures on the extracted, security-relevant files -------
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

    # --- state file for cleanup.ps1 / sweep.ps1 ----------------------------
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

    # --- schedule the uninstaller at expiry --------------------------------
    $cleanup = Join-Path $InstallDir 'cleanup.ps1'
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy AllSigned -File `"$cleanup`""
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $TaskName `
        -Trigger (New-ScheduledTaskTrigger -Once -At $expires) `
        -Action $action -Principal $principal -Settings $settings -Force | Out-Null

    Write-Host "Installed ipscan; cleanup scheduled for $expires (TTL ${WindowMinutes}m, OnInUse=$OnInUse)."
    Write-Host "Techs: export scans into $InstallDir\logs so cleanup removes them with the tool."
}
finally {
    Remove-Self
}
