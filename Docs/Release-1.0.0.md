# MacSSH 1.0.0 Release Manifest

> **Phase 12A: Ad-hoc Release for Local / Internal Testing**
>
> This build is **not** signed with Apple Developer ID and is **not** notarized.
> Developer ID + Notarization (Phase 12B) is deferred until an Apple Developer
> Program membership is obtained.

## Product

| Field | Value |
|---|---|
| Product | MacSSH |
| Version | 1.0.0 |
| Build | 1 |
| Architecture | arm64 (Apple Silicon) |
| Minimum macOS | 14.0 |
| Bundle Identifier | com.macssh.MacSSH |
| Display Name | MacSSH |
| App Sandbox | OFF (non-Sandbox distribution) |
| Hardened Runtime | ON (`flags=0x10002(adhoc,runtime)`) |

## Signing & Distribution

| Field | Value |
|---|---|
| Signing | Ad-hoc (`Signature=adhoc`) |
| Secure Timestamp | None (ad-hoc, no Developer ID) |
| Notarization | Not performed |
| Stapling | Not performed |
| Gatekeeper `source` | Not "Notarized Developer ID" (ad-hoc) |
| Distribution mode | Local / Internal testing only |

## Entitlements

Final Release `.app` entitlements (verified via
`codesign --display --entitlements - --xml`):

```xml
<dict></dict>
```

- `get-task-allow`: **absent** (Release; `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`)
- No Sandbox, no JIT / allow-unsigned-executable-memory /
  disable-executable-page-protection / disable-library-validation / debugger
  exceptions. Static libssh2 + OpenSSL do not require library validation to be
  disabled.

## Runtime Linkage

`otool -L` on the Release executable shows only macOS system libraries /
frameworks and `/usr/lib/swift` runtime. No `/opt/homebrew`, `/usr/local`,
dynamic `libssh2`, `libssl`, or `libcrypto`.

## Dependencies

| Dependency | Version | Pinned commit |
|---|---|---|
| libssh2 | 1.11.2_DEV | `be937743a85c4064a6399cee39e606672a401069` |
| OpenSSL | 3.5.8 | — |

Phase 5.1 dependency identity assertions (`DependencyIdentityTests`) continue
to pass; the security baseline is unchanged in Phase 12A.

## Artifacts

| Artifact | Size | Notes |
|---|---|---|
| `MacSSH.app` | 13 MB | ad-hoc signed, Hardened Runtime on |
| `MacSSH-1.0.0.dmg` | 4.4 MB | UDBZ (zlib level 9), volume name `MacSSH`, ad-hoc signed |

## DMG SHA256

```
8aa9082b3a6ff3d5400f3a302115813c9580e3b57f20479937cfe34292217365  MacSSH-1.0.0.dmg
```

## DMG Contents

```
MacSSH (volume)
├── MacSSH.app
└── Applications -> /Applications
```

## Verification

`Scripts/verify-release.sh` (ad-hoc mode): **11 PASS / 0 FAIL**

- codesign `--verify --strict`: PASS
- Hardened Runtime runtime flag: PASS
- get-task-allow absent: PASS
- runtime linkage clean: PASS
- arm64: PASS
- CFBundleShortVersionString=1.0.0 / CFBundleVersion=1 /
  CFBundleIdentifier=com.macssh.MacSSH / CFBundleDisplayName=MacSSH: PASS
- app launch (process alive 5s): PASS
- DMG contains MacSSH.app + Applications symlink: PASS

## Runtime Behavior (sampled from `/Applications/MacSSH.app`)

| Metric | Observation |
|---|---|
| Launch from `/Applications` | OK (process stable 30s+) |
| Idle CPU (instantaneous, ~30s idle) | 0.0% |
| Idle memory (phys_footprint via top) | ~73 MB (consistent with Phase 11 baseline 73–75 MB) |

## Functional Smoke

- App launch from `/Applications/MacSSH.app`: **PASS** (process starts and
  stays idle).
- Local Terminal / Host Manager / SSH / Remote Terminal / SFTP / Upload /
  Download / Transfer Queue: **not tested** (require manual SwiftUI UI
  interaction; the local sshd fixture is not enabled, so the SSH/SFTP/Transfer
  integration test suite under `Scripts/run-ssh-tests.sh` was not run in this
  phase). Phase 12A did not modify any core runtime (Transfer Core /
  Scheduler / SFTP Core), so the Phase 11 full regression baseline (191 tests /
  189 pass / 1 env-attributed / 1 intended skip; four rectification rounds all
  green) continues to hold. Pure unit tests run in Phase 12A: 4 suites green
  (28 pass + 1 intended skip / 0 failure).

## Known Limitations

1. **Apple Silicon arm64 only.** Intel / Universal is not included in this
   release; it would require rebuilding libssh2 / OpenSSL for additional
   architectures and full re-validation. Tracked as a future separate effort.

2. **This build is not signed with Apple Developer ID and is not notarized.**
   It is ad-hoc signed for local / internal testing only.

3. **macOS Gatekeeper may warn or block the application when downloaded from
   the Internet.** This is expected for an ad-hoc, non-notarized build obtained
   through quarantine-enabled distribution channels. The local DMG generated on
   this machine does not carry a quarantine attribute, so the local install
   test does not reproduce the Internet-download Gatekeeper path. Do **not**
   disable system Gatekeeper (`sudo spctl --master-disable`) or strip
   quarantine (`xattr -d com.apple.quarantine`) to work around this — obtain
   Developer ID + Notarization (Phase 12B) for quarantine-safe distribution.

4. **Physical SSH disconnection can leave a transfer-owned remote `.partial`
   file** because the disconnected session cannot perform cleanup. The app
   explicitly reports the residual filename; it never silently reconnects to
   delete it. (Phase 10 known behavior, unchanged in Phase 12A.)

5. **KEX restricted-sshd automated fixture** is not固化; the Phase 11 manual
   restricted-sshd procedure is retained. This is a non-blocking tech-debt item
   and does not alter the SSH Security Baseline.

6. **Clean-machine installation test: not executed** (only one development Mac
   available). The local DMG install test (`/Applications` copy + launch) was
   performed, but this does not reproduce a clean-machine / quarantine-download
   scenario.

## Deferred (Phase 12B)

The following remain for when an Apple Developer Program membership is
obtained. The infrastructure is already in place and unchanged:

- `Scripts/build-release.sh` — `xcodebuild archive` + Developer ID export
- `Scripts/ExportOptions.plist` — Developer ID export options template
- `Scripts/notarize.sh` — `notarytool submit --keychain-profile --wait` +
  `stapler staple` + `stapler validate`
- `Scripts/package-dmg.sh developer-id` mode — Developer ID DMG signing with
  secure timestamp
- `Scripts/verify-release.sh developer-id` mode — full check incl. Developer
  ID Authority, secure Timestamp, stapler validate, spctl
  `source=Notarized Developer ID`

When Phase 12B is unblocked:

1. Install `Developer ID Application` certificate (Apple Developer Program).
2. `xcrun notarytool store-credentials "MacSSH-notary"` (interactive, in
   Terminal).
3. `MACSSH_DEVELOPMENT_TEAM=<TEAM_ID> bash Scripts/build-release.sh`
4. `bash Scripts/package-dmg.sh dist/export/MacSSH.app developer-id`
5. `bash Scripts/notarize.sh dist/MacSSH-1.0.0.dmg`
6. `bash Scripts/verify-release.sh dist/MacSSH-1.0.0.dmg developer-id`
