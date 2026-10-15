# PC 3.3.0 local recovery

The original 1.2.1 baseline rejects updated GameAssembly.dll, global metadata,
settings, catalog and other resources. This local source build uses an explicit
reviewed manifest rather than removing the launcher check or changing shared
BepInEx startup behavior. The original release baseline remains the default.

Validation performed before packaging: IL2CPP metadata v31 bounds and all three
Harmony hook names, argument counts and static/instance shapes; compilation
against regenerated 3.3.0 interop with zero warnings/errors; pinned original
BepInEx payload integrity; active PC catalog JSON/hash pair and exact game
file SHA256 values. Menu/runtime and combat verification are recorded separately;
successful compilation is not proof that every feature works.

The reviewed manifest is local to this game/translation installation. Old
catalog_3.2.0 files may remain; their deletion is unnecessary. A future or
different active catalog still requires a fresh review. Existing settings are
preserved; automatic mod downloads/apply remain disabled for this local build.

Build from the source root with Build-PC-3.3.0.cmd. An existing output ZIP is
never overwritten; choose another --output path if rebuilding. Install the new
ZIP after exiting the game, then launch via Launch-BAP.cmd or the desktop link.
Do not reinstall the old ZIP as it contains the old compatibility baseline.

The source's runtime type/argument checks, feature circuit breakers and PvP
suspension remain enabled. No Android code or bundle is included in this PC build.
