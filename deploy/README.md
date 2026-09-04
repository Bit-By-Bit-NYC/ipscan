# ipscan — signed, ephemeral deployment kit

Internally-built, code-signed, self-removing copy of Angry IP Scanner for use
during client engagements. Replaces ad-hoc / winget-installed scanners that trip
EDR on auto-update and get left behind on client servers.

## Architecture

```
GitHub Actions (clean, no S1)         Signing workstation (this repo + Azure)      Target server
─────────────────────────────         ───────────────────────────────────────     ─────────────
tag push  ──► CI builds win64   ──►    package-release.ps1:                         install.ps1 (signed,
              draft release with        - download unsigned exe from release          distributed internally)
              ipscan-<ver>-win.exe      - jlink minimal JRE                           - downloads payload zip
              (UNSIGNED)                - assemble payload (exe + jre + cleanup)         from Azure blob
                                        - sign exe + scripts (Azure Artifact Sign)    - verifies signatures
                                        - zip payload ──► Azure blob                  - installs to fixed dir
                                        - emit signed install.ps1 + sweep.ps1         - schedules cleanup (TTL)
                                                                                      - self-deletes
                                                                                    cleanup.ps1 = uninstaller
                                                                                    sweep.ps1   = fleet safety net
```

Why the build runs on CI and not locally: SentinelOne on the signing workstation
injects a JVMTI Java agent and runs a network monitor that breaks the JVM NIO
selector loopback Gradle needs (`Unable to establish loopback connection`).
`javac`/`jar`/`jlink` are unaffected, but Gradle is, so the canonical build is
done on a clean GitHub runner and only signing/packaging happens locally.

## Pinned version

- **Build tag:** `3.10.0-bbb.1` (annotated, at the same commit as upstream `3.10.0`).
- The `-bbb.N` suffix gives our signed internal builds their own provenance and
  flows into the exe version string via `git describe`.
- Always build from a **tag**, never a moving branch.

## Files

| File | Runs on | Signed | Purpose |
|------|---------|--------|---------|
| `signing.config.psd1` | signing box | — | Signing account/profile, release tag, blob URL, install defaults. **Set the blob fields before signing.** |
| `package-release.ps1` | signing box | — | Download unsigned CI build → jlink → sign → zip payload → (upload). |
| `install.ps1` | target | ✅ | Self-deleting bootstrap: download payload, verify, install, schedule cleanup. |
| `cleanup.ps1` | target | ✅ | Uninstaller: remove exe, JRE, logs, `.ipscan`, JavaSoft prefs; handles "in use". |
| `sweep.ps1` | fleet | ✅ | Detect/remove stray deployments past TTL (separate RMM cadence). |

## 1. Build the unsigned artifact (CI)

Push a build tag to the fork; CI builds all three OSes and creates a **draft
release** with the `*.exe` assets:

```bash
git tag -a 3.10.0-bbb.1 <upstream-tag-commit> -m "BBB internal build lineage"
git push origin refs/tags/3.10.0-bbb.1
```

> Actions must be enabled on the fork (one-time). If a tag push produces no run,
> enable it: `gh api -X PUT repos/Bit-By-Bit-NYC/ipscan/actions/permissions -F enabled=true -f allowed_actions=all` then re-push the tag.

The asset we consume is `ipscan-<ver>-win.exe` (portable launcher + jar, unsigned).

## 2. Sign & package (local)

Prerequisites on the signing workstation:
- JDK 21+ (`JAVA_HOME`) for `jlink`. A portable Temurin unpack is fine.
- `ArtifactSigning` PowerShell module + Artifact Signing client tools (dlib),
  and `az login` as an identity holding the **Code Signing Certificate Profile
  Signer** role on the `bbbRmmScripts` account.
- `gh` authenticated with read access to the fork's releases.
- Edit `signing.config.psd1`: set `StorageAccount`, `Container`, `PayloadBlobName`.
  These form the non-secret base URL that gets baked into the signed bootstrap.
  The **SAS token is not baked** — it's supplied at run time (see below) and
  stored in IT Glue, so it never needs to be set here or re-signed on rotation.

```powershell
$env:JAVA_HOME = 'C:\path\to\jdk-21'
.\package-release.ps1            # produces build\publish\...
.\package-release.ps1 -Upload    # also uploads the payload zip to the blob
```

Outputs under `build\publish\`:
- `payload\ipscan-<ver>.zip` — upload to the Azure blob (auto with `-Upload`).
- `dist\install.ps1` — signed bootstrap; **distribute internally** (RMM/share).
- `dist\sweep.ps1` — signed fleet sweep.
- `release-manifest.json` — version, tag, hashes, payload URL.

Signing notes:
- The profile issues **3-day** certs, so a timestamp is mandatory (configured).
  Timestamped signatures stay valid after the cert rotates.
- Azure Artifact Signing certs chain to a Microsoft public root, so signatures
  are trusted on endpoints without deploying the cert to trust stores.
- Only the outer `ipscan.exe` is signed, not each bundled JRE DLL. This held for
  the launcher stub S1 flagged; re-confirm against EDR before relying on it.

## 3. Distribute & install

- Upload the payload zip to the blob (`-Upload` or manually).
- Store the read-only **SAS token in IT Glue** for techs to retrieve.
- The tech runs the signed `install.ps1` **in their own session — no admin
  required**. It prompts for the SAS token (or takes `-Sas`), downloads the
  payload, verifies Authenticode (Valid + expected signer) on `ipscan.exe` and
  `cleanup.ps1`, installs to **`%LOCALAPPDATA%\BBB\ipscan`**, schedules cleanup,
  **auto-launches the scanner**, drops a Start-Menu shortcut, and deletes itself
  regardless of where it was run from.

```powershell
# tech run: prompts for the SAS token from IT Glue, then opens the scanner
powershell -ExecutionPolicy AllSigned -File .\install.ps1 -WindowMinutes 90

# pass the token / skip auto-launch
powershell -ExecutionPolicy AllSigned -File .\install.ps1 -Sas '<sas from IT Glue>' -WindowMinutes 90 -NoLaunch
```

Notes:
- **No elevation** anywhere: per-user install path, a current-user cleanup task,
  user-scoped cleanup. `ipscan.exe` also runs fine without admin (ICMP via
  `IcmpSendEcho`, MAC via `SendARP`); only raw-socket pinger modes want admin.
- Because the SAS isn't baked in, rotating it never requires re-signing.
- `-WindowMinutes` is the deploy-to-cleanup TTL (default 60), a parameter.
- Techs should export scan results into `%LOCALAPPDATA%\BBB\ipscan\logs` so
  cleanup removes them with the tool.
- Must run **interactively** (a real user session). It refuses to run as SYSTEM,
  since per-user paths would be wrong — so don't push it via RMM-as-SYSTEM.

## 4. Uninstall / cleanup

`cleanup.ps1` runs from the per-user scheduled task, which fires on **two
triggers** so the tech needn't stay logged on for the whole window:
- a **timer at expiry** (fires if still logged on), and
- an **At-Logon trigger** (fires at the next logon if the tech signed off before
  the timer — so a sign-off effectively cleans up at next sign-in).

It removes only the current user's artifacts: the install dir, `%USERPROFILE%\.ipscan`,
the `HKCU\...\JavaSoft\Prefs\ipscan` registry node (ipscan uses Java Preferences
→ the registry, not a `.ipscan` file), the Start-Menu shortcut, and the task
itself. No admin needed.

"Still in use" policy (from `deploy-state.json`):
- **Extend** (default): if `ipscan.exe` is running, grant one grace extension of
  `GraceMinutes` (re-arming the timer, keeping the logon trigger), then
  terminate+delete on the next run.
- **Kill**: terminate `ipscan.exe` and delete immediately.

A true "at the moment of sign-off" trigger would require admin (a Security-event
or GPO logoff hook), so the At-Logon catch-up is the non-elevated equivalent; the
fleet sweep covers machines left signed off for long periods.

## 5. Fleet safety net

`sweep.ps1` is the backstop for deployments whose per-host cleanup didn't run
(reboot before trigger, RMM disconnect, task deleted). Schedule it on its own RMM
cadence. Report-only by default; `-Remove` enforces.

```powershell
.\sweep.ps1                 # report stray deployments older than 24h
.\sweep.ps1 -Remove -MaxAgeHours 12
```

## Re-signing on a version bump

Never hand-patch a previously signed binary. Full pipeline every time:

1. Cut a new build tag (`3.x.y-bbb.N`) at the upstream release commit; push it.
2. Wait for CI's draft release with the unsigned `*-win.exe`.
3. Update `ReleaseTag` and `PayloadBlobName` in `signing.config.psd1`, and mint a
   new read-only SAS for the new blob (store it in IT Glue).
4. `.\package-release.ps1 -Upload`.
5. Distribute the new signed `install.ps1`. (Re-sign changes the exe hash — update
   the S1 hash exclusion.)

## Open items to confirm

- **Interactive execution**: `install.ps1` runs per-user and **refuses to run as
  SYSTEM**. If distributing via RMM, run it **as the logged-on user**, not as
  SYSTEM. (The fleet `sweep.ps1` is the piece that runs elevated/SYSTEM.)
- **Script execution reaches the file**: if the RMM pipes script content via
  `powershell -EncodedCommand` instead of running the literal `.ps1`, the
  Authenticode signature never reaches the executing process and `AllSigned`
  won't apply. Confirm it runs the file from disk.
- **Execution policy** on target endpoints: signing only gates execution under
  `AllSigned`/`RemoteSigned`. Confirm/adjust so signing is meaningful.
- **SentinelOne on target servers**: exclude the **file hash (SHA1)** of the
  signed `ipscan.exe` — the tightest match and appropriate for this rarely-updated
  tool. Note that *signing changes the hash* (Azure Artifact Signing embeds a
  fresh cert + timestamp each run), so record the hash of the exact signed
  artifact you deploy and add a new hash only when you cut a new release. Avoid
  path exclusions (too loose) and publisher-cert exclusions (too broad — they
  whitelist every BBB-signed binary). Test the signed exe on one endpoint first;
  a valid signature may clear S1 without any exclusion.
- **EDR DLL allow-listing**: confirm signing only the outer exe (not JRE DLLs) is
  sufficient for the production EDR/AV.
