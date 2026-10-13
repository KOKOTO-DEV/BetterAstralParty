param([string]$GameRoot)
$ErrorActionPreference='Stop'
if(![string]::Equals([IO.Path]::GetFullPath($GameRoot).TrimEnd('\'),[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){exit 90}
Add-Type 'using System; using System.Runtime.InteropServices; public static class FixtureConsole { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); }'
$lines=@(('Console='+[FixtureConsole]::GetConsoleWindow().ToInt64()),('SteamAppId='+$env:SteamAppId),('SteamGameId='+$env:SteamGameId),('SteamOverlayGameId='+$env:SteamOverlayGameId),('LauncherPid='+$env:BAP_UPDATER_LAUNCHER_PID),('PSModulePath='+$env:PSModulePath))
[IO.File]::WriteAllLines((Join-Path $GameRoot 'checker-observation'),$lines)
$behavior=if(Test-Path -LiteralPath (Join-Path $GameRoot 'checker-behavior')){[IO.File]::ReadAllText((Join-Path $GameRoot 'checker-behavior'))}else{'ok'}
if($behavior -ceq 'reject'){[Console]::Error.WriteLine('inert compatibility refusal');exit 23}
if($behavior -ceq 'flood'){[Console]::Out.Write(('O'*131072));[Console]::Error.Write(('E'*131072))}
exit 0

