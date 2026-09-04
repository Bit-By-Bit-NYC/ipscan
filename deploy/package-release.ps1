<#
.SYNOPSIS
    Package -> sign -> publish pipeline for the ephemeral Angry IP Scanner.
    Runs on the signing workstation. Pulls the UNSIGNED build from the GitHub
    Actions release, signs everything with Azure Artifact Signing, produces the
    blob payload plus the internally-distributed signed bootstrap.

.DESCRIPTION
    The build itself happens on GitHub Actions (clean, no SentinelOne). This
    script never compiles - it consumes the CI artifact and does the signing
    and packaging locally.

    Steps:
      1. Download ipscan-<ver>-win.exe (unsigned portable launcher+jar) from the
         GitHub release for the pinned tag.
      2. jlink a minimal JRE so the package is self-contained (no install).
      3. Assemble the payload dir: ipscan.exe + jre\ + cleanup.ps1 (uninstaller).
      4. Sign ipscan.exe and cleanup.ps1 (payload), plus install.ps1 (bootstrap)
         and sweep.ps1 (fleet), with the flightdeck profile. Signing is LAST for
         the scripts - the payload URL is baked into install.ps1 before signing.
      5. Zip the payload for the blob; verify every signature; write a manifest.
      6. Optionally upload the payload zip to the Azure blob (-Upload).

    Outputs under <publish>:
      payload\ipscan-<ver>.zip   -> upload to blob (or auto with -Upload)
      dist\install.ps1           -> signed bootstrap, distribute internally
      dist\sweep.ps1             -> signed fleet sweep
      release-manifest.json

    Re-run the whole pipeline on every version bump; never hand-patch a signed
    binary.

.PARAMETER JavaHome   JDK 21+ home (for jlink). Defaults to $env:JAVA_HOME.
.PARAMETER PublishDir Output root. Defaults to <repo>\build\publish.
.PARAMETER UnsignedExe Use a local unsigned exe instead of downloading from CI.
.PARAMETER Upload     Upload the payload zip to the configured Azure blob.
.PARAMETER SkipSign   Assemble only (dry run, no Azure).

.EXAMPLE
    .\package-release.ps1 -Upload
#>
[CmdletBinding()]
param(
    [string]$JavaHome    = $env:JAVA_HOME,
    [string]$PublishDir,
    [string]$UnsignedExe,
    [switch]$Upload,
    [switch]$SkipSign
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }

$scriptDir = $PSScriptRoot
$repoRoot  = Split-Path -Parent $scriptDir
$cfg       = Import-PowerShellDataFile (Join-Path $scriptDir 'signing.config.psd1')
if (-not $PublishDir) { $PublishDir = Join-Path $repoRoot 'build\publish' }
if (-not $JavaHome)   { throw "JavaHome not set. Pass -JavaHome or set JAVA_HOME to a JDK 21+." }
$jlink = Join-Path $JavaHome 'bin\jlink.exe'
if (-not (Test-Path $jlink)) { throw "Not found: $jlink" }

# Minimal runtime - mirrors the module set the upstream Windows installer ships.
$jreModules = 'java.base,java.prefs,java.logging,jdk.crypto.ec'

# --- clean output -----------------------------------------------------------
if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }
$payloadDir = Join-Path $PublishDir 'payload\ipscan'
$distDir    = Join-Path $PublishDir 'dist'
New-Item -ItemType Directory -Force -Path $payloadDir, $distDir | Out-Null

# --- 1. obtain the unsigned exe from CI -------------------------------------
if ($UnsignedExe) {
    if (-not (Test-Path $UnsignedExe)) { throw "UnsignedExe not found: $UnsignedExe" }
    Copy-Item $UnsignedExe (Join-Path $payloadDir 'ipscan.exe')
    Write-Step "Using local unsigned exe: $UnsignedExe"
}
else {
    Write-Step "Downloading unsigned exe from GitHub release $($cfg.ReleaseTag)"
    $dl = Join-Path $PublishDir '_dl'
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    & gh release download $cfg.ReleaseTag --repo $cfg.GitHubRepo --pattern 'ipscan-*-win.exe' --dir $dl
    if ($LASTEXITCODE -ne 0) { throw "gh release download failed for $($cfg.ReleaseTag)." }
    $exe = Get-ChildItem $dl -Filter 'ipscan-*-win.exe' | Select-Object -First 1
    if (-not $exe) { throw "No ipscan-*-win.exe asset on release $($cfg.ReleaseTag)." }
    Copy-Item $exe.FullName (Join-Path $payloadDir 'ipscan.exe')
    Remove-Item $dl -Recurse -Force
}
$version = (Get-Item (Join-Path $payloadDir 'ipscan.exe')).VersionInfo.ProductVersion
Write-Host "Version: $version"

# --- 2. jlink minimal JRE ---------------------------------------------------
Write-Step "jlink minimal JRE"
& $jlink --output (Join-Path $payloadDir 'jre') --add-modules $jreModules `
         --compress=zip-6 --no-header-files --no-man-pages --strip-debug
if ($LASTEXITCODE -ne 0) { throw "jlink failed." }

# --- 3. payload scripts -----------------------------------------------------
Copy-Item (Join-Path $scriptDir 'cleanup.ps1') (Join-Path $payloadDir 'cleanup.ps1')

# Bake only the NON-SECRET base URL before signing. The SAS token is supplied
# at run time (install.ps1 prompt or -Sas), distributed via IT Glue - it is
# never baked into the signed script, so rotating it needs no re-sign.
$baseUrl = "https://$($cfg.StorageAccount).blob.core.windows.net/$($cfg.Container)/$($cfg.PayloadBlobName)"
$installOut = Join-Path $distDir 'install.ps1'
# Replace only the quoted param default, not the guard's '*@@...@@*' literal,
# so the "not set" guard keeps a live sentinel to test against.
(Get-Content (Join-Path $scriptDir 'install.ps1') -Raw).
    Replace("'@@PAYLOAD_BASE_URL@@'", "'" + [string]$baseUrl + "'").
    Replace("[int]`$WindowMinutes        = 60",       "[int]`$WindowMinutes        = $([int]$cfg.WindowMinutes)").
    Replace("[int]`$GraceMinutes         = 30",       "[int]`$GraceMinutes         = $([int]$cfg.GraceMinutes)") |
    Set-Content $installOut -Encoding UTF8
# NOTE: InstallDir is computed at run time (%LOCALAPPDATA%\BBB\ipscan) inside
# install.ps1 - it is intentionally not baked here.
Copy-Item (Join-Path $scriptDir 'sweep.ps1') (Join-Path $distDir 'sweep.ps1')

# --- 4. sign ----------------------------------------------------------------
$toSign = @(
    (Join-Path $payloadDir 'ipscan.exe'),
    (Join-Path $payloadDir 'cleanup.ps1'),
    $installOut,
    (Join-Path $distDir 'sweep.ps1')
)
if ($SkipSign) {
    Write-Step "SkipSign - leaving artifacts unsigned"
}
else {
    Write-Step "Signing with Azure Artifact Signing ($($cfg.CertificateProfileName))"
    Import-Module ArtifactSigning -ErrorAction Stop
    Invoke-ArtifactSigning `
        -Endpoint               $cfg.Endpoint `
        -CodeSigningAccountName $cfg.CodeSigningAccountName `
        -CertificateProfileName $cfg.CertificateProfileName `
        -Files                  ($toSign -join ',') `
        -FileDigest             $cfg.FileDigest `
        -TimestampRfc3161       $cfg.TimestampUrl `
        -TimestampDigest        $cfg.TimestampDigest `
        -Description            $cfg.Description `
        -DescriptionUrl         $cfg.DescriptionUrl `
        -CorrelationId          "ipscan-$version"
    foreach ($f in $toSign) {
        $sig = Get-AuthenticodeSignature $f
        if ($sig.Status -ne 'Valid') { throw "Signature not Valid on $f : $($sig.Status) - $($sig.StatusMessage)" }
        Write-Host ("  OK  {0}" -f (Split-Path $f -Leaf))
    }
}

# --- 5. zip payload + manifest ---------------------------------------------
Write-Step "Zipping payload"
$zip = Join-Path $PublishDir ("payload\{0}" -f $cfg.PayloadBlobName)
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $payloadDir '*') -DestinationPath $zip -Force

$manifest = [ordered]@{
    product      = 'Angry IP Scanner (BBB internal ephemeral)'
    version      = $version
    tag          = $cfg.ReleaseTag
    builtUtc     = (Get-Date).ToUniversalTime().ToString('o')
    builtBy      = "$env:USERDOMAIN\$env:USERNAME"
    signed       = (-not $SkipSign)
    profile      = $cfg.CertificateProfileName
    payloadZip   = Split-Path $zip -Leaf
    payloadSha256 = (Get-FileHash $zip -Algorithm SHA256).Hash
    payloadBaseUrl = $baseUrl   # NOTE: SAS token intentionally omitted (secret)
    files        = @{}
}
foreach ($f in $toSign) { $manifest.files[(Split-Path $f -Leaf)] = (Get-FileHash $f -Algorithm SHA256).Hash }
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $PublishDir 'release-manifest.json') -Encoding UTF8

# --- 6. optional upload -----------------------------------------------------
if ($Upload) {
    if ($cfg.StorageAccount -like '*REQUIRED*') { throw "StorageAccount not set in signing.config.psd1." }
    Write-Step "Uploading payload to blob $($cfg.StorageAccount)/$($cfg.Container)/$($cfg.PayloadBlobName)"
    & az storage blob upload --account-name $cfg.StorageAccount --container-name $cfg.Container `
        --name $cfg.PayloadBlobName --file $zip --auth-mode login --overwrite --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Blob upload failed." }
}

Write-Step "Done."
Write-Host "Payload zip : $zip"
Write-Host "Bootstrap   : $installOut  (signed - distribute internally)"
Write-Host "Fleet sweep : $(Join-Path $distDir 'sweep.ps1')"
if (-not $Upload) { Write-Host "`nNext: upload the payload zip to the blob (or re-run with -Upload)." }
