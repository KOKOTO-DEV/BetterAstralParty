"""Read-only source fixture checks (not Windows runtime validation)."""
import pathlib, re, json, hashlib
root=pathlib.Path(__file__).resolve().parents[1]
r=lambda x:(root/x).read_text(encoding='utf-8-sig')
plugin=r('src/Plugin.cs'); thanks=r('src/AutoThanksUi.cs'); ui=r('src/ModUi.cs'); layout=r('src/MenuLayout.cs'); texts=r('src/ModText.cs')
assert 'Config.Bind("일반", "자동 감사합니다", true' in plugin
assert 'Enabled, AutoThanks, ShowDetails' in r('src/Observability/SafeDiagnosticEvent.cs')
assert '!Plugin.AutoThanks.Value' in thanks
assert 'AddToggle("AutoThanks", 440, MenuLayout.ToggleY(18))' in ui
assert 'case "AutoThanks": Plugin.AutoThanks.Value = !Plugin.AutoThanks.Value; AutoThanksUi.Clear(); break;' in ui
assert '"AutoThanks" or "Language"' in layout
assert '"AutoThanks" => enabled ? "게임의 PvE 기본 감사합니다 빠른 응답을 자동으로 누릅니다.\\n직접' in layout
assert '"AutoThanks" => ("자동 감사합니다", "기본 ON.' in layout
assert '"자동 감사합니다"] = "Auto Thanks"' in texts
assert 'F8' in r('docs/LOCAL-DEVELOPMENT.md')
force=r('tools/force-uninstall.ps1')
assert 'SupportsShouldProcess=$true' in force and "if ($WhatIfPreference)" in force
assert "Read-Host 'Type ERASE BETTERASTRALPARTY" in force
assert "'AstralParty_INT.exe'" not in force.split('$files=@(')[1].split(')')[0]
assert 'Assert-BapInside' in force and 'Assert-BapSafeTree' in force
assert 'Get-Process -Name AstralParty_INT' in force
assert 'Remove-Item -LiteralPath $target' in force
assert 'BepInEx\\plugins\\BetterAstralParty' in force
assert 'BepInEx\\core' not in force.split('$files=@(')[1].split(')')[0]
assert '$KeepLocalData' in force
builder=r('tools/build-local.ps1')
assert 'dotnet restore' in builder and 'dotnet build' in builder
assert 'build-launcher.ps1' in builder and 'build-update-helper.ps1' in builder
assert 'Get-AuthenticodeSignature' in builder and 'Get-FileHash' in builder
assert 'Set-AuthenticodeSignature' in builder and 'SigningCertificateThumbprint' in builder
assert 'installerApproved=$false' in builder and 'Compress-Archive' in builder
assert 'ExecutionPolicy Bypass' not in r('Force-Uninstall.cmd')
assert 'ExecutionPolicy Bypass' not in r('Build-And-Package.cmd')
assert 'ExecutionPolicy Bypass' not in r('OneClick-Package.cmd')
assert 'ExecutionPolicy Bypass' not in r('Check-Security.cmd')
assert not (root/'package-manifest.json').exists()
print('PASS: source-level feature/build/removal/security assertions')
