# BetterAstralParty 1.2.1 original-installer integration

This project keeps the **original**, complete installation chain. It does not
replace it with a separate `Install-Local.cmd` or skip owner/signature checks.

## Included changes

- F8 > General: Auto Thanks switch (default ON), persistence and manual click preserved
- Separate confirmed `Force-Uninstall.cmd` for BetterAstralParty-specific cleanup
- `Build-Local.cmd` for plugin, Steam Launcher and Update Helper compilation
- `Build-And-Package.cmd` and `tools/build-integrated.ps1` to prepare and run
  `tools/package-ga.ps1`, the existing whole-package builder
- Original `Install.cmd`, `Uninstall.cmd`, `tools/find-game.ps1`, original Steam
  shortcut setup, signed update Helper, receipt and recovery logic retained

## Inputs you supply

1. Windows x64 PowerShell 7, Python 3, .NET SDK 8.0.425 and .NET 6 targeting pack
2. Game INT root with initialized BepInEx/interop; clean extracted BepInEx 788 root
3. Untampered original complete **installer** directory, containing
   `package-manifest.json` and `tools/approved-install-bundles.json`
4. Official unchanged BepInEx 788 upstream ZIP (SHA256
   `F4CC496BD098A0DF4164B81E3737297707F13A47C2478DBA2F60EEFAB784817A`)
5. An `export` compiler directory with `local-build-manifest.json` (or let the
   script compile it using `Build-Local.cmd`)

## Run

Use `Build-And-Package.cmd` from this source root, or:

```powershell
pwsh -NoProfile -File .\tools\build-integrated.ps1 `
  -OriginalRelease 'Z:\Downloads\BetterAstralParty-1.2.1' `
  -UpstreamArchive 'D:\Downloads\BepInEx-IL2CPP-788.zip' `
  -BuildDirectory 'Z:\Downloads\BetterAstralParty-1.2.1-modified-source-build-tools\export' `
  -Stage 'trial01'
```

The script validates original file hashes, original build identity + catalog
consistency (not independent authentication; later signature checks remain mandatory), build DLL hashes, and exact upstream archive SHA-256. It then stages
`artifacts/automatic-update-development/trial01/inputs` and runs the existing
`package-ga.ps1` in `Release` scope without any fake approval.

Result without verified signing: an `*-unsigned-candidate.zip` and a
`candidate-state.json` with `installableRelease: false`. **Do not run its
`Install.cmd`.** Source-only access cannot produce a genuinely approved whole
installer, because signature private keys and independent approval are absent.

## Authorized release signing and approval

The stock packaging pipeline requires the EXACT freshly compiled helper image
signature, the signed v3 whole-update descriptor for the new DLL/launcher/etc,
and an external review record for the calculated build identity. These are not
AuthentiCode EXE signatures, and `Set-AuthenticodeSignature` does not fulfill
them. Only an authorized key holder can produce signatures matching the public
key pinned in `updater/ProductionUpdateKeys.cs`.

Prepare a signed inventory through the repository's original authorized
`tools/sign-local-install.ps1` / `tools/prepare-local-signed-inputs.ps1` and
its reviewed signing-policy workflow. This must produce an input manifest
whose content includes the properly verified helper and update signatures,
plus a separate external release approval for the exact inventory. The
script supports an already reviewed signed input directory:

```powershell
pwsh -NoProfile -File .\tools\build-integrated.ps1 `
  -OriginalRelease '<complete original release directory>' `
  -UpstreamArchive '<clean loader ZIP>' `
  -BuildDirectory '<compiled export>' `
  -Stage 'signedtrial01' `
  -Scope 'LocalInstall' `
  -SignedInputDirectory '<reviewed signed-input directory inside artifact boundary>' `
  -SignedInputManifestSha256 '<SHA256>' `
  -ApprovalRecord '<independently approved review record path>' `
  -ApprovalSha256 '<SHA256>'
```

All four review/signing arguments are mandatory together; the original GA
compiler performs the final cryptographic verification. The resulting ZIP is
considered installable **only** if its output state confirms all four fields:
`installableRelease`, `catalogRegistered`, `helperSignatureVerified` and
`updateProofVerified` as true.

### IMPORTANT: version bump

The original installer rejects a different payload at the **same version**
and refuses downgrades. As shipped, this patch source still identifies as
`1.2.1`; a signed custom build targeting an installed 1.2.1 must have a
*distinct, strictly newer* version in `src/Plugin.cs`, then all three binaries
must be rebuilt from that same source. The historical installer baseline
receipt remains `1.2.1` as designed and must not be changed. A local install
scope also enforces a local prerelease pattern such as `1.2.2-dev.local.1`
and requires a separately reviewed local-install proof. Version changes do
not replace signing or approval.

### Updates, Steam integration and force removal

The approved original-format installer retains Steam INT discovery, Steam
shortcut registration, installation receipts, recovery handling and the
original signed update mechanism. A private custom build should not claim to
be an official GitHub release; automatic downloads should not be enabled
until an official compatible signed update for that lineage is available.

`Force-Uninstall.cmd` is separate and destructive. It can delete user settings,
logs and recovery backups; it is NOT part of normal upgrade or repair. Avoid
it as an ordinary fix for receipt/recovery errors.

## No false antivirus promise

Windows Mark-of-the-Web (`Unblock-File`) and execution policies are separate
from Authenticode signatures, installer update signatures and antivirus
heuristics. None are bypassed in this integration. Reproducible binaries,
valid publisher code signing and legitimate false-positive submissions can
reduce reputation alerts but cannot guarantee zero detections.
