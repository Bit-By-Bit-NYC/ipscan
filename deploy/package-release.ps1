<#
.SYNOPSIS
    Package -> sign -> publish pipeline for the ephemeral Angry IP Scanner.
    Runs on the signing workstation. Pulls the UNSIGNED build from the GitHub
    Actions release, repackages it with jpackage into a native app-image, signs
    everything with Azure Artifact Signing, produces the blob payload plus the
    internally-distributed signed bootstrap.

.DESCRIPTION
    IMPORTANT - why jpackage: the upstream Windows build is a self-executing jar
    (a launcher stub with the jar appended). Authenticode-signing that hybrid
    appends the signature AFTER the jar's ZIP trailer, which breaks `java -jar`
    ("Invalid or corrupt jarfile"). So we cannot sign the launcher+jar exe and
    still run it. Instead we extract the jar and rebuild with jpackage, which
    produces a real native ipscan.exe (a normal PE) alongside app\ipscan.jar and
    a minimal runtime\ - that exe signs cleanly and runs.

    Steps:
      1. Obtain ipscan-<ver>-win.exe (unsigned launcher+jar) from the GitHub
         release (or -UnsignedExe).
      2. Extract the jar by stripping the known launcher-stub prefix.
      3. jpackage --type app-image -> native ipscan.exe + app\ + runtime\.
      4. Add cleanup.ps1 (payload) and prepare install.ps1 (bootstrap, base URL
         baked) + sweep.ps1 (fleet).
      5. Sign the native ipscan.exe + all scripts (flightdeck), verify.
      6. Zip the app-image payload; write a manifest; optionally upload (-Upload).

    Outputs under <publish>:
      payload\<blob>.zip   -> upload to blob (app-image + cleanup.ps1)
      dist\install.ps1     -> signed bootstrap, distribute internally
      dist\sweep.ps1       -> signed fleet sweep
      release-manifest.json  (records the ipscan.exe SHA1 for the S1 exclusion)

    Re-run the whole pipeline on every version bump; the exe hash changes each
    time (new signature), so update the S1 hash exclusion after each release.

.PARAMETER JavaHome   JDK 21+ home (jpackage). Defaults to $env:JAVA_HOME.
.PARAMETER PublishDir Output root. Defaults to <repo>\build\publish.
.PARAMETER UnsignedExe Use a local unsigned launcher+jar exe instead of CI.
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
$jpackage = Join-Path $JavaHome 'bin\jpackage.exe'
if (-not (Test-Path $jpackage)) { throw "Not found: $jpackage" }
$jarTool = Join-Path $JavaHome 'bin\jar.exe'
if (-not (Test-Path $jarTool)) { throw "Not found: $jarTool" }
$swtVersion = '3.134.0'   # must match build.gradle's SWT version

$stubExe = Join-Path $repoRoot 'ext\win-launcher\launcher.exe'
if (-not (Test-Path $stubExe)) { throw "Launcher stub not found: $stubExe (needed to locate the jar offset)." }
$stub = (Get-Item $stubExe).Length
$appVersion = ($cfg.ReleaseTag -replace '-.*$','')          # jpackage needs MAJOR.MINOR.PATCH
$jreModules = 'java.base,java.prefs,java.logging,jdk.crypto.ec'

# --- clean output -----------------------------------------------------------
if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }
$payloadParent = Join-Path $PublishDir 'payload'
$payloadDir    = Join-Path $payloadParent 'ipscan'   # jpackage app-image lands here
$distDir       = Join-Path $PublishDir 'dist'
$work          = Join-Path $PublishDir '_work'
New-Item -ItemType Directory -Force -Path $payloadParent, $distDir, $work | Out-Null

# --- 1. obtain the unsigned launcher+jar exe --------------------------------
if ($UnsignedExe) {
    if (-not (Test-Path $UnsignedExe)) { throw "UnsignedExe not found: $UnsignedExe" }
    $srcExe = (Resolve-Path $UnsignedExe).Path
    Write-Step "Using local unsigned exe: $srcExe"
}
else {
    Write-Step "Downloading unsigned exe from GitHub release $($cfg.ReleaseTag)"
    & gh release download $cfg.ReleaseTag --repo $cfg.GitHubRepo --pattern 'ipscan-*-win.exe' --dir $work
    if ($LASTEXITCODE -ne 0) { throw "gh release download failed for $($cfg.ReleaseTag)." }
    $srcExe = (Get-ChildItem $work -Filter 'ipscan-*-win.exe' | Select-Object -First 1).FullName
    if (-not $srcExe) { throw "No ipscan-*-win.exe asset on release $($cfg.ReleaseTag)." }
}

# --- 2. extract the jar (strip launcher stub) -------------------------------
Write-Step "Extracting jar (stub = $stub bytes)"
$jarPath = Join-Path $work 'ipscan.jar'
$fin = [IO.File]::OpenRead($srcExe); $fin.Seek($stub, 'Begin') | Out-Null
$fout = [IO.File]::Create($jarPath); $fin.CopyTo($fout); $fout.Close(); $fin.Close()

# --- 2b. inject SWT GDI+ native --------------------------------------------
# The upstream Gradle build excludes swt-gdip-*.dll, but SWT needs the GDI+
# helper at startup on Windows (UnsatisfiedLinkError otherwise). Pull it from
# the matching SWT artifact and add it to the jar root (where SWT extracts its
# natives from).
Write-Step "Injecting swt-gdip native (SWT $swtVersion)"
$swtJar   = Join-Path $work "swt-win64-$swtVersion.jar"
$swtCache = Join-Path $repoRoot "build\_cache\swt-win64-$swtVersion.jar"
if (Test-Path $swtCache) { Copy-Item $swtCache $swtJar }
else {
    New-Item -ItemType Directory -Force (Split-Path $swtCache) | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://repo1.maven.org/maven2/org/eclipse/platform/org.eclipse.swt.win32.win32.x86_64/$swtVersion/org.eclipse.swt.win32.win32.x86_64-$swtVersion.jar" -OutFile $swtJar -UseBasicParsing
    Copy-Item $swtJar $swtCache
}
$exdir = Join-Path $work 'swt'; New-Item -ItemType Directory -Force $exdir | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipf = [IO.Compression.ZipFile]::OpenRead($swtJar)
try {
    $entry = $zipf.Entries | Where-Object { $_.FullName -match '^swt-gdip-win32.*\.dll$' } | Select-Object -First 1
    if (-not $entry) { throw "swt-gdip-win32*.dll not found in SWT $swtVersion jar" }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $exdir $entry.FullName), $true)
    $gdipName = $entry.FullName
} finally { $zipf.Dispose() }
Push-Location $exdir
& $jarTool uf $jarPath $gdipName
$rc = $LASTEXITCODE; Pop-Location
if ($rc -ne 0) { throw "jar uf (add $gdipName) failed" }
Write-Host "  added $gdipName to jar"

# --- 3. jpackage app-image (native exe + app jar + minimal runtime) ---------
Write-Step "jpackage app-image (version $appVersion)"
$jpArgs = @(
    '--type','app-image','--name','ipscan','--dest',$payloadParent,
    '--input',$work,'--main-jar','ipscan.jar','--main-class','net.azib.ipscan.Main',
    '--app-version',$appVersion,'--add-modules',$jreModules,
    '--java-options','--add-opens=java.base/java.net=ALL-UNNAMED',
    '--icon',(Join-Path $repoRoot 'resources\images\icon.ico'),
    '--vendor','Bit by Bit Computer Consultants'
)
& $jpackage @jpArgs
if ($LASTEXITCODE -ne 0) { throw "jpackage failed (exit $LASTEXITCODE)." }
$exe = Join-Path $payloadDir 'ipscan.exe'
if (-not (Test-Path $exe)) { throw "jpackage produced no $exe" }
Remove-Item $jarPath -Force -ErrorAction SilentlyContinue

# --- 4. payload + bootstrap scripts -----------------------------------------
Copy-Item (Join-Path $scriptDir 'cleanup.ps1') (Join-Path $payloadDir 'cleanup.ps1')
$baseUrl = "https://$($cfg.StorageAccount).blob.core.windows.net/$($cfg.Container)/$($cfg.PayloadBlobName)"
$installOut = Join-Path $distDir 'install.ps1'
# Replace only the quoted param default, not the guard's sentinel.
(Get-Content (Join-Path $scriptDir 'install.ps1') -Raw).
    Replace("'@@PAYLOAD_BASE_URL@@'", "'" + [string]$baseUrl + "'").
    Replace("[int]`$WindowMinutes        = 30",       "[int]`$WindowMinutes        = $([int]$cfg.WindowMinutes)").
    Replace("[int]`$GraceMinutes         = 30",       "[int]`$GraceMinutes         = $([int]$cfg.GraceMinutes)") |
    Set-Content $installOut -Encoding UTF8
Copy-Item (Join-Path $scriptDir 'sweep.ps1') (Join-Path $distDir 'sweep.ps1')

# --- 5. sign (native exe + scripts) -----------------------------------------
$toSign = @($exe, (Join-Path $payloadDir 'cleanup.ps1'), $installOut, (Join-Path $distDir 'sweep.ps1'))
if ($SkipSign) {
    Write-Step "SkipSign - leaving artifacts unsigned"
}
else {
    Write-Step "Signing native exe + scripts via Azure Artifact Signing ($($cfg.CertificateProfileName))"
    Import-Module ArtifactSigning -ErrorAction Stop
    & attrib -R $exe 2>$null   # freshly built exe can be read-only / AV-locked
    $signed = $false
    for ($i=1; $i -le 3 -and -not $signed; $i++) {
        try {
            Invoke-ArtifactSigning -Endpoint $cfg.Endpoint -CodeSigningAccountName $cfg.CodeSigningAccountName `
                -CertificateProfileName $cfg.CertificateProfileName -Files ($toSign -join ',') `
                -FileDigest $cfg.FileDigest -TimestampRfc3161 $cfg.TimestampUrl -TimestampDigest $cfg.TimestampDigest `
                -Description $cfg.Description -DescriptionUrl $cfg.DescriptionUrl -CorrelationId "ipscan-$appVersion" | Out-Null
            $signed = $true
        }
        catch {
            if ($i -eq 3) { throw }
            Write-Host "  signing attempt $i failed ($($_.Exception.Message)); retrying..."; Start-Sleep -Seconds 4
        }
    }
    foreach ($f in $toSign) {
        $sig = Get-AuthenticodeSignature $f
        if ($sig.Status -ne 'Valid') { throw "Signature not Valid on $f : $($sig.Status) - $($sig.StatusMessage)" }
        Write-Host ("  OK  {0}" -f (Split-Path $f -Leaf))
    }
}

# --- 6. zip payload (app-image + cleanup.ps1) + manifest --------------------
Write-Step "Zipping payload"
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
$zip = Join-Path $payloadParent $cfg.PayloadBlobName
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $payloadDir '*') -DestinationPath $zip -Force

$exeSha1 = (Get-FileHash $exe -Algorithm SHA1).Hash
$manifest = [ordered]@{
    product       = 'Angry IP Scanner (BBB internal ephemeral)'
    version       = $appVersion
    tag           = $cfg.ReleaseTag
    builtUtc      = (Get-Date).ToUniversalTime().ToString('o')
    builtBy       = "$env:USERDOMAIN\$env:USERNAME"
    signed        = (-not $SkipSign)
    profile       = $cfg.CertificateProfileName
    format        = 'jpackage app-image (native launcher)'
    exeSha1       = $exeSha1          # <-- S1 hash exclusion value
    payloadZip    = Split-Path $zip -Leaf
    payloadSha256 = (Get-FileHash $zip -Algorithm SHA256).Hash
    payloadBaseUrl = $baseUrl         # SAS token intentionally omitted (secret)
    files         = @{}
}
foreach ($f in $toSign) { $manifest.files[(Split-Path $f -Leaf)] = (Get-FileHash $f -Algorithm SHA256).Hash }
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $PublishDir 'release-manifest.json') -Encoding UTF8

# --- 7. optional upload -----------------------------------------------------
if ($Upload) {
    if ($cfg.StorageAccount -like '*REQUIRED*') { throw "StorageAccount not set in signing.config.psd1." }
    Write-Step "Uploading payload to blob $($cfg.StorageAccount)/$($cfg.Container)/$($cfg.PayloadBlobName)"
    & az storage blob upload --account-name $cfg.StorageAccount --container-name $cfg.Container `
        --name $cfg.PayloadBlobName --file $zip --auth-mode login --overwrite --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Blob upload failed (try --account-key, or check RBAC)." }
}

Write-Step "Done."
Write-Host "Payload zip   : $zip"
Write-Host "Bootstrap     : $installOut  (signed - distribute internally)"
Write-Host "Fleet sweep   : $(Join-Path $distDir 'sweep.ps1')"
Write-Host "ipscan.exe SHA1 (S1 hash exclusion): $exeSha1"
if (-not $Upload) { Write-Host "`nNext: upload the payload zip to the blob (or re-run with -Upload)." }
