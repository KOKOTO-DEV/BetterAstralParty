# Current PC 3.3.0 local-launch compatibility smoke test.
# Runtime/native updater exact-policy fixtures are independently tested by
# tools/test-catalog-compatibility.ps1.
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'test-resource-drift.ps1')
Write-Host 'Local launch compatibility fixture completed.'
