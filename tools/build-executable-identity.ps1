param([Parameter(Mandatory)][string]$OutputDirectory,[Parameter(Mandatory)][ValidateSet('Launcher','Helper')][string]$Role)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$match=[regex]::Match([IO.File]::ReadAllText((Join-Path $root 'src/Plugin.cs')),'(?m)^    public const string Version = "(?<tag>(?<base>[0-9]+\.[0-9]+\.[0-9]+)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)";\r?$')
if(!$match.Success){throw 'Canonical plugin version is required for executable metadata.'}
$version=[version]$match.Groups['base'].Value
if($version.Major -gt 65535 -or $version.Minor -gt 65535 -or $version.Build -gt 65535){throw 'Version exceeds Windows file-version component bounds.'}
$fileVersion=$version.ToString()+'.0'
$title=if($Role -ceq 'Launcher'){'BetterAstralParty native launch host'}else{'BetterAstralParty Update Helper'}
$text='using System.Reflection;'+[Environment]::NewLine+'[assembly: AssemblyProduct("BetterAstralParty")]'+[Environment]::NewLine+'[assembly: AssemblyTitle("'+$title+'")]'+[Environment]::NewLine+'[assembly: AssemblyVersion("'+$fileVersion+'")]'+[Environment]::NewLine+'[assembly: AssemblyFileVersion("'+$fileVersion+'")]'+[Environment]::NewLine+'[assembly: AssemblyInformationalVersion("'+$match.Groups['tag'].Value+'")]'+[Environment]::NewLine
$path=Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) 'ExecutableIdentity.cs'
[IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
return $path
