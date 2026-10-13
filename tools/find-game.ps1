# Read-only installation discovery. Never pick arbitrarily between real installs.
function Resolve-IntGameDirectory([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $Path = $Path.Trim().Trim('"').Replace('/', '\')
    # Discovery must tolerate disconnected drives recorded by Steam.
    foreach ($candidate in @($Path, [IO.Path]::Combine($Path, '8vJXnINT'))) {
        if (Test-Path -LiteralPath ([IO.Path]::Combine($candidate, 'AstralParty_INT.exe')) -PathType Leaf) {
            return [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $candidate).ProviderPath).TrimEnd('\')
        }
    }
}

function Read-IntSteamMetadata([string]$Path, [string]$Kind, [string]$PackageRoot, $Diagnostics) {
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction Stop) {
            return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        }
    } catch {
        $failure = $_
        # A single unavailable metadata file must not hide another valid library or manual selection.
        Write-Warning ('Steam metadata unavailable; other locations/manual selection remain available: ' + $Kind)
        if ($Diagnostics.Logged -lt 8) {
            $Diagnostics.Logged++
            try {
                if (Get-Command Write-InstallFailure -CommandType Function -ErrorAction SilentlyContinue) {
                    $null = Write-InstallFailure $failure ('INT discovery metadata read: ' + $Kind) $PackageRoot '' -Operation 'Discovery' -Waiting
                }
            } catch {} # Diagnostics never alter discovery.
        } else { $Diagnostics.Omitted++ }
    }
}

function Find-IntGameDirectories([string]$SteamRoot, [string]$PackageRoot) {
    $libraries = @($SteamRoot)
    $diagnostics = @{ Logged=0; Omitted=0 }
    $libraryFile = [IO.Path]::Combine($SteamRoot, 'steamapps/libraryfolders.vdf')
    $libraryText = Read-IntSteamMetadata $libraryFile 'LibraryFolders' $PackageRoot $diagnostics
    if ($null -ne $libraryText) {
        $libraries += [regex]::Matches($libraryText, '"path"\s+"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value.Replace('\\', '\') }
    }
    $candidates = @(
        Resolve-IntGameDirectory $PackageRoot
        Resolve-IntGameDirectory (Split-Path -Parent $PackageRoot)
        foreach ($library in $libraries) {
            $library = $library.Replace('/', '\')
            if (!(Test-Path -LiteralPath $library -PathType Container)) { continue }
            Resolve-IntGameDirectory (Join-Path $library 'steamapps/common/Astral Party')
            $manifest = Join-Path $library 'steamapps/appmanifest_2622000.acf'
            $manifestText = Read-IntSteamMetadata $manifest 'AppManifest' $PackageRoot $diagnostics
            if ($null -ne $manifestText) {
                $match = [regex]::Match($manifestText, '"installdir"\s+"([^"]+)"')
                # Steam installdir is a single directory name, not an arbitrary path.
                if ($match.Success -and $match.Groups[1].Value -notmatch '[\\/:]|^\.{1,2}$') {
                    Resolve-IntGameDirectory (Join-Path $library ('steamapps/common/' + $match.Groups[1].Value))
                }
            }
        }
    )
    if ($diagnostics.Omitted) {
        try {
            if (Get-Command Write-InstallFailure -CommandType Function -ErrorAction SilentlyContinue) {
                $failure = [Management.Automation.ErrorRecord]::new([IO.IOException]::new(('Additional metadata read failures omitted: ' + $diagnostics.Omitted)), 'DiscoveryDiagnosticLimit', [Management.Automation.ErrorCategory]::ReadError, $null)
                $null = Write-InstallFailure $failure 'INT discovery diagnostic coverage' $PackageRoot '' -Operation 'Discovery' -Waiting
            }
        } catch {}
    }
    $candidates | Sort-Object -Unique
}
