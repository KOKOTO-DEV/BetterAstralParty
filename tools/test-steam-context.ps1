param([string]$DotnetRoot)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'test-native-launcher.ps1') -DotnetRoot $DotnetRoot
