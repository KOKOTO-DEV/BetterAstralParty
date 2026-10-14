# BetterAstralParty 1.2.1 — Simple offline local installation (R6.3)

This is a **local development installation**, not an official approved 1.2.1
release. It keeps the requested F8 Auto Thanks switch from the modified source.
It does not impersonate or overwrite the original signed launcher/update system.

## What changed to minimize false-positive opportunities

- A small, source-available **.NET Framework 4.8** console installer, instead of
  a long PowerShell bootstrap, PowerShell `-ExecutionPolicy Bypass`, an updater
  helper process, or an injected self-extracting executable.
- No automatic downloads, elevated permission requests, new registry entries,
  background service, scheduled tasks, or exclusions to Defender.
- Uses pristine files from the original release's BepInEx dependency bundle;
  verifies each against the original package-manifest SHA-256 before repacking.
- Verifies the locally built mod DLL against local-build-manifest.json and every
  payload file at installation. Does not modify or delete foreign game files.
- Auto-detects Steam `libraryfolders.vdf` plus known registry paths. Multiple
  installations require choosing one; no silently guessed game destination.
- Disables auto download and apply-after-exit in the existing BepInEx config,
  while preserving all other settings and an uninstall-restorable original.
- Optional real publisher Authenticode code signing using `signtool.exe` and
  `--sign-thumbprint`; this is not a fake CA or an AV bypass.

## SDK selection for `Build-And-Package.cmd`

The source `global.json` selects .NET SDK 8.0.425 or the latest installed patch
in the same 8.0.4xx feature band. **8.0.426 is supported**; .NET 9 will not be
silently selected. The .NET 6 reference pack used by the plugin is still needed.
From this source folder, run `dotnet --version` to verify the selected SDK.

## One-click packaging using the already compiled DLL

1. Extract this source ZIP alongside the **complete original** 1.2.1 installer
   folder (`package-manifest.json`, `.deps/bepinex/...`). Do **not** point to
   source-only folders for the original release.
2. Keep your existing `export/` compilation output with
   `local-build-manifest.json`. For example, it may be inside a previous R2 or
   R3 source folder next to this extracted R6 source folder.
3. Double-click **`OneClick-Package.cmd`**. The tool auto-detects unique input
   locations, or prompts you once to choose. Requires Python 3 (`py` launcher)
   and Windows .NET Framework 64-bit `csc.exe` (included on typical Windows 11).
4. It creates `BetterAstralParty-1.2.1-SimpleInstall.zip` next to this source.
   It **does not** modify your game.
5. After using the original package's `Uninstall.cmd` to remove the previously
   installed official version, extract the ZIP **to a local drive** (for example,
   `D:\BAP-SimpleInstall`, not a mapped/network `Z:` drive), then double-click
   **`Install.cmd`**.
   The installer detects the game's INT folder, validates its contents, and installs without requiring a typed `INSTALL` token.
6. Installation creates `BetterAstralParty_1.2.1.lnk` on the current
   user's Windows desktop and points it at the installed `Launch-BAP.cmd` in
   `8vJXnINT`. Double-click the desktop shortcut to start the game. If the
   desktop shortcut could not be created, the installer prints a warning;
   start with `Launch-BAP.cmd` directly instead. In-game press F8 to adjust
   **자동 감사합니다**.
7. For normal removal, double-click **`Uninstall.cmd`** and answer `Y` to the
   confirmation. It deletes only intact installed files, restores the original
   config when safe, and removes the desktop shortcut only if its recorded hash
   and launch destination still match. Existing/modified shortcuts are preserved.
8. If installation records are missing or damaged, **`Force-Uninstall.cmd`** is
   included in the same **generated installation ZIP**. It uses the same installer
   EXE, shows a fixed list of BetterAstralParty-specific files and user data,
   and requires a `Y` confirmation before permanent deletion. This also removes
   `%LOCALAPPDATA%\BetterAstralParty` including settings, logs and recovery
   backups by default. To retain it, run `Force-Uninstall.cmd --keep-user-data`.
   A desktop shortcut targeting this exact game's Launch-BAP.cmd is also
   removed (other shortcuts are preserved). Shared BepInEx, unrelated plugins,
   the original game, and Steam shortcuts are preserved. No administrative elevation, PowerShell policy bypass or
   antivirus exclusions are used.

### Direct script invocation (to specify exact inputs)

```
py -3 tools\oneclick-package.py --build "Z:\Downloads\YOUR-PREVIOUS-SOURCE\export" --release "Z:\Downloads\BetterAstralParty-1.2.1" --output "Z:\Downloads\BAP-SimpleInstall.zip"
```

To use an actual trusted, publisher-controlled Authenticode code-signing
certificate already installed for the current user, add
`--sign-thumbprint` with the certificate's 40-digit SHA-1 thumbprint. This
requires `signtool.exe` on PATH. There is no private key in the source.
Unsigned applications can still produce SmartScreen warnings. A newly signed
application can too; there is no guarantee that Defender will not flag it.

## Limitations and safeguards

- **Not a drop-in official 1.2.1 update.** Official install/update ownership and
  signed helper records are deliberately *not* faked or bypassed. The simple
  installer refuses an existing official receipt/helper/launcher or an existing
  BetterAstralParty plugin. Uninstall the official release first using its own
  verified uninstaller, without deleting recovery evidence.
- No Steam shortcut registration and no built-in automatic update. Game launch
  is via the explicit `Launch-BAP.cmd` command. No Windows service.
- This cannot remove antivirus warnings caused by the game mod loader itself,
  BepInEx proxy DLLs or the game's anti-cheat policies. Only distribute/execute
  software that is permitted by the game's terms and your security policy.
- Do not submit files to antivirus with embedded secrets. If you encounter a
  Windows Defender **false positive**, submit the specific SHA-256/sample as a
  software developer: https://www.microsoft.com/wdsi/filesubmission .
  For SmartScreen reputation, see Microsoft's developer guidance and sign every
  release consistently using an organization-approved certificate.
- The built installer EXE and full game launch **have not been run in this Linux
  workspace**. Source checks and synthetic manifest/ZIP tests are not a
  replacement for a real Windows + game test. If Windows compilation fails,
  inspect the compiler output before executing anything.

## One-click complete source build + package (no previous export required)

Double-click **`Build-And-Package.cmd`** instead of `OneClick-Package.cmd`.
This also auto-detects the Steam game (or asks for its path), extracts verified
BepInEx build files *from the complete original installer* into a disposable
local build folder, compiles **only the plugin DLL** with the pinned SDK using
an offline NuGet configuration, compiles the .NET Framework installer, and
packages the ZIP. It does not build or ship the old launcher/update helper.

Requires the original 1.2.1 installer directory, Windows Python 3,
.NET SDK 8.0.425, .NET 6 reference pack, and previously initialized game
`BepInEx/interop` reference DLLs. If any prerequisite is missing, the command
stops before touching your game. To provide the Steam game folder explicitly:

```
Build-And-Package.cmd --release "Z:\Downloads\BetterAstralParty-1.2.1" --game "D:\SteamLibrary\steamapps\common\Astral Party\8vJXnINT"
```

For already compiled output, `OneClick-Package.cmd` is faster and does not
require the SDK. Both produce the same install package layout.

## R6.2 installer manifest fix

R6.1 incorrectly rejected a fully SHA-256-verified loader payload whenever
`PAYLOAD-MANIFEST.tsv` contained more than 150 entries. R6.2 allows up to 2048
verified files, validates the same upper limit during packaging, and prints the
entry count during both steps. This is a source/installer fix; the game plugin
DLL does not need to be recompiled if you have a valid previous build export.

**Important:** the earlier generated SimpleInstall ZIP contains the old
`BetterAstralParty.Setup.exe`; editing a `.cs` file does not patch that EXE.
Repackage from this R6.2 source with `OneClick-Package.cmd` (using the existing
`export` folder) or `Build-And-Package.cmd`, and use a fresh output ZIP name.
If `Install.cmd` previously stopped at `Incomplete payload manifest`, its
installation procedure did not copy game files. Do not delete game files to fix
this particular error.

## R6.3 installer UX and package layout

- `Build-And-Package.cmd` is the only required source-build entry point.
- `Build-Local.cmd` and the old one-off `Fix-Installer.cmd` were removed from
  the R6.3 source package. `OneClick-Package.cmd` remains optional when reusing
  an already compiled DLL.
- The generated install ZIP contains `Install.cmd`, `Uninstall.cmd`,
  `Force-Uninstall.cmd` and `BetterAstralParty.Setup.exe`; it does **not** ship
  any source-build/repair CMD tools. The EXE is the transparent, offline
  file-copy / hash-verification / removal engine invoked by the CMD wrappers.
- The standard install automatically starts after SHA-256 validation and
  conflict checks (no typed `INSTALL`). Force removal still requests `Y`.
- The force-removal command works with a missing or corrupt receipt, but
  intentionally does not remove shared BepInEx/doorstop runtime components.
- Old already-generated SimpleInstall ZIP files do not update themselves;
  regenerate the installation ZIP with the R6.3 `Build-And-Package.cmd` or
  `OneClick-Package.cmd`. Windows installation and antivirus results require
  actual testing on the user's computer.


## R6.3: launch gate and F8 menu fix

The original plugin requires a completed game compatibility review before it
loads. R6.2 launched the game directly without transferring that reviewed
state, so the game ran normally but F8 and all plugin features remained OFF.

R6.3 ships the **same** .NET Framework `BetterAstralParty.Setup.exe` in the
installation package and installs a verified copy into the game directory.
`Launch-BAP.cmd` invokes its `launch` operation, which checks the local install
receipt, plugin/setup/compatibility file hashes, original compatibility manifest
against the installed game and Addressables cache, and **only after all checks
pass** starts `AstralParty_INT.exe` with the required one-launch activation
marker. No PowerShell, extra helper executable, elevation or antivirus exception
is involved. An unsupported game update is blocked with a reason rather than
being silently allowed.

**Upgrade from R6.2:** close the game, run the existing local
`Uninstall.cmd`, then install the R6.3 package. Leave unrelated BepInEx
plugins and shared loader files untouched. `Build-And-Package.cmd` builds from
source and packages; `OneClick-Package.cmd` can package an existing compiled
plugin (no plugin recompilation). Do not patch the activation argument alone:
that would skip the required compatibility review.

Windows game launch and Defender detection are not verifiable on the source
packaging host. Confirm in-game F8 and `BepInEx/LogOutput.log` after installing.

## R6.4 — C# 5 installer compilation fix

R6.3 can compile the plugin but fail to compile the installer with
`CS1525` / `CS1002` at `simple-installer/BetterAstralParty.Setup.cs:265`.
The Windows .NET Framework CSC used by the one-click packager does not
support the C# 7 null-coalescing throw expression. R6.4 uses a regular
null check and explicitly compiles the installer with `/langversion:5`.

For an already successful R6.3 **plugin** build, reuse the existing output:

```powershell
py -3 .\tools\oneclick-package.py `
  --build 'Z:\Downloads\BetterAstralParty-1.2.1-R6.3-F8-Launch-Fix-Source\artifacts\simple-build-20261014-041938' `
  --release 'Z:\Downloads\BetterAstralParty-1.2.1' `
  --output 'Z:\Downloads\BetterAstralParty-1.2.1-SimpleInstall-R6.4.zip'
```

Adjust `--build` to the folder containing `local-build-manifest.json`.
This reuses the compiled DLL and creates the setup EXE and installer ZIP;
it does not modify game files. Full compilation is also available through
`Build-And-Package.cmd`. The real Windows C# compilation and game launch
are **not** covered by non-Windows fixture tests.
