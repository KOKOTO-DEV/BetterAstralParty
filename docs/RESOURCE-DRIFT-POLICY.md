# PC 3.3.0 content-only updates — conditional compatibility

This local-source variant changes **compatibility behavior**, not game files or any
updater authentication. The launcher still checks the exact hashes of all
native executables, IL2CPP metadata, Unity engine, BepInEx and other runtime
files listed in the reviewed 3.3.0 baseline. A native file mismatch **blocks**.

Only these resources may change without requiring a new mod build:

- `AstralParty_INT_Data/data.unity3d`: valid UnityFS structure required.
- `AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle`: valid UnityFS
  structure required if the reviewed hash changes.
- `AstralParty_INT_Data/StreamingAssets/aa/settings.json`: valid JSON object
  required if the reviewed hash changes.
- `AppData/LocalLow/feimo/AstralParty_INT/com.unity.addressables/catalog_X.Y.Z.json`
  and matching `.hash`: valid current pair with a version equal to or newer
  than the reviewed catalog baseline, valid JSON and nonempty bounded hash.
  A superseded older pair may be absent; an incomplete newly downloading pair
  is only warned about while the older active pair is complete.

Warning instead of blocking a content-only update **does not imply** that all
features will behave correctly. Existing UI/IL2CPP hook guards remain active
and should disable incompatible features independently. If an executable or
metadata changes, the reviewed binary baseline must be updated and tested.

The original **signed update/repair transaction** in `updater/UpdateCompatibility.cs`
continues to enforce exact manifests and signatures. This change applies to
local launch compatibility checks; it neither weakens updater verification
nor changes release signing/trust.

## Usage

Extract the new source and run `Build-PC-3.3.0.cmd` with the original release
and target PC game present. The new install ZIP will carry the modified setup
EXE and plugin with its relaxed *content-only* policy. A previously compiled
plugin/installer is **not** updated by only changing this source.

Windows regression check: `pwsh -NoProfile -File tools/test-resource-drift.ps1`
(or Windows PowerShell 5.1); all cases use a disposable synthetic fixture.
No installed game is read or altered by these tests.

## Validation limitations

We can inspect the source and run source/package tests here, but cannot compile
Windows C# Framework installer or launch the actual Unity game in this
container. Build-PC-3.3.0.cmd and in-game testing on Windows are required.
