# Release / signing / distribution configuration for the ipscan pipeline.
# Consumed by package-release.ps1 on the signing workstation. NOT shipped to
# target servers.
#
# The certificate profile issues short-lived (3-day) certificates, so an
# RFC3161 timestamp is mandatory on every signature - without it the signature
# stops validating three days after signing.
@{
    # --- Azure Artifact Signing -------------------------------------------
    Endpoint               = 'https://eus.codesigning.azure.net'
    CodeSigningAccountName = 'bbbRmmScripts'
    CertificateProfileName = 'flightdeck'
    TimestampUrl           = 'http://timestamp.acs.microsoft.com'
    FileDigest             = 'SHA256'
    TimestampDigest        = 'SHA256'
    Description            = 'Bit by Bit - internal network scanner (ephemeral)'
    DescriptionUrl         = 'https://bitxbit.com'

    # --- Source of the UNSIGNED build (GitHub Actions release) -------------
    GitHubRepo             = 'Bit-By-Bit-NYC/ipscan'
    ReleaseTag             = '3.10.0-bbb.1'          # pinned build tag CI released

    # --- Distribution (Azure Blob) ----------------------------------------
    # These 3 fields form the NON-SECRET base URL and are safe to commit.
    # package-release.ps1 bakes ONLY that base URL into the signed install.ps1.
    # The SAS token is never baked or committed - install.ps1 prompts for it at
    # run time (or accepts -Sas). Distribute the token via IT Glue.
    StorageAccount         = 'bbbrmmsasscripts'
    Container              = 'ipscan'
    PayloadBlobName        = 'ipscan-3.10.0-bbb.1.zip'

    # --- Install defaults baked into the signed bootstrap -----------------
    # InstallDir is per-user (%LOCALAPPDATA%\BBB\ipscan), computed at run time -
    # not baked. OnInUse default ('Extend') lives in install.ps1.
    WindowMinutes          = 30      # deploy-to-cleanup TTL (baked)
    GraceMinutes           = 30      # grace extension when in use (baked)
}
