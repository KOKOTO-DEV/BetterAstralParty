$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -Path (Join-Path $root '.deps/bepinex/BepInEx/core/Mono.Cecil.dll')
$assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((Join-Path $root '.research/extracted/AstralParty.Runtime.dll.dll'))
try {
    # RuntimeObject resolves overloads by name/argument count: validate the chosen overload.
    $method = $assembly.MainModule.GetType('FairyGUI.GObject').Methods |
        Where-Object { $_.Name -eq 'LocalToGlobal' -and $_.Parameters.Count -eq 1 } | Select-Object -First 1
    if ($method.Parameters[0].ParameterType.FullName -ne 'UnityEngine.Vector2' -or
        $method.ReturnType.FullName -ne 'UnityEngine.Vector2') { throw 'Diagnostic coordinate overload changed' }
    $source = Get-Content (Join-Path $root 'src/ModUi.cs') -Raw
    foreach ($required in @('if (!Plugin.Diagnostics.IsRecording) return;', 'TraceInput("down", current)',
        'TraceInput("up", current)', 'TraceInput("applied", _pressed)', 'var enabled = ToggleEnabled(action)',
        '// Detailed input trace reads no extra native controls, captions or bounds.',
        'Plugin.Diagnostics.Error("SettingsInputTrace", ex)', '"FieldBuffs" => Plugin.FieldBuffs.Value',
        '"FieldZoom" => Plugin.FieldZoom.Value', '"MatchFocus" => Plugin.MatchFocus.Value',
        'MenuLayout.StateHelp(action, ToggleEnabled(action), mode)',
        'case "MatchFocus": Plugin.MatchFocus.Value = !Plugin.MatchFocus.Value; break;',
        'case "FieldZoom": Plugin.FieldZoom.Value = !Plugin.FieldZoom.Value; if (!Plugin.FieldZoom.Value) FieldZoomUi.Clear(); break;'
)) {
        if (!$source.Contains($required)) { throw "Settings diagnostic regression: $required" }
    }
    $trace = [regex]::Match($source, '(?s)private static void TraceInput\(.*?(?=    private static bool ToggleEnabled)')
    if (!$trace.Success -or !$trace.Value.Contains('Plugin.Diagnostics.Write(') -or
        $trace.Value -match '(?:\.Call\(|\.Get<|\.Get\(|\.Field\()') {
        throw 'Settings input trace must retain sampled action data without extra native control reads.'
    }
    foreach ($size in @(60, 84, 340, 480)) {
        foreach ($pivot in @(0, 0.5, 1)) {
            if (-$size * $pivot + $size * $pivot -ne 0) { throw 'Anchored visual origin regression' }
        }
    }
    $features = @('Enabled', 'Details', 'KoMinimum', 'CardPopups', 'BattleStatus', 'ShushuShield', 'FieldBuffs', 'Names', 'HandLayout', 'FieldZoom')
    for ($row = 0; $row -lt $features.Count; $row++) {
        $placement = 'AddToggle("{0}", 440, MenuLayout.ToggleY({1}));' -f $features[$row], $row
        if (!$source.Contains($placement)) { throw "Feature setting left the right column: $($features[$row])" }
    }
    $general = @('UpdateChannel', 'UpdateCheck', 'UpdateDownload', 'AutoDownload', 'AfterExit',
        'UpdateGet', 'UpdateCancel', 'UpdateAuth', 'UpdateSignOut', 'DiagnosticsOpen', 'DiagnosticsCollect')
    for ($row = 0; $row -lt $general.Count; $row++) {
        $placement = 'AddToggle("{0}", 440, MenuLayout.ToggleY({1}));' -f $general[$row], ($row + 7)
        if (!$source.Contains($placement)) { throw "General setting row regression: $($general[$row])" }
    }
    foreach ($placement in @('AddToggle("MatchFocus", 440, MenuLayout.ToggleY(4));',
        'AddStepper("Scale", ModText.Text("표시 크기"), MenuLayout.ToggleY(5));',
        'AddStepper("Opacity", ModText.Text("배경 불투명도"), MenuLayout.ToggleY(6));', 'AddToggle("Diagnostics", 440, 190);',
        'AddToggle("MuteUnfocused", 440, 255);', 'AddToggle("InputAttention", 440, 320);', 'MoveIntoSettings(button)')) {
        if (!$source.Contains($placement)) { throw "Utility setting layout regression: $placement" }
    }
    $layout = Get-Content -LiteralPath (Join-Path $root 'src/MenuLayout.cs') -Raw
    foreach ($required in @('ToggleY(int row) => 125 + 65 * row;', 'ToggleHeight = 60;',
        'Math.Min((width - 48f) / Width, (height - 48f) / Height)')) {
        if (!$layout.Contains($required)) { throw "Settings spacing/screen-fit regression: $required" }
    }
    # The exact source rows above give InputAttention -> MatchFocus -> Scale -> Opacity -> updater,
    # a 65px pitch with separate 60px control rows. Native scroll/input ownership is unchanged.
    if (!$source.Contains('toggle.Call("SetSize", width, MenuLayout.ToggleHeight);') -or
        !$source.Contains('if (!MenuLayout.FixedControl(action)) MoveIntoSettings(button);') -or
        !$source.Contains('MoveIntoSettings(Labels[key]);')) { throw 'Settings geometry or native scroll ownership changed' }
    foreach ($required in @('Labels["Saved"] = NativeUi.Label(_sheet, "", 675, MenuLayout.FooterY + 7, 315, 30, 18);',
        'Labels["HelpTitle"] = NativeUi.Label(helpArea, "", 18, 22, 324, 44, 27);',
        'Labels["HelpTitle"].Set("singleLine", true);', 'Labels["HelpTitle"].Set("autoSize", 3);',
        'Labels["Saved"].Set("singleLine", true);', 'Labels["Saved"].Set("autoSize", 3);',
        'var saved = Time.unscaledTime - _changedAt < 1.6f ? ModText.Text("✓ 저장됨") : $"BetterAstralParty {Plugin.Version}";',
        'if (_savedText != saved) { _savedText = saved; Labels["Saved"].Set("text", saved); }')) {
        if (!$source.Contains($required)) { throw "Full version footer regression: $required" }
    }
    if ([regex]::Matches($source, 'Labels\["Saved"\]\.Set\("(?:singleLine|autoSize)"').Count -ne 2) {
        throw 'Footer fitting must be initialized once, not rewritten on idle frames.'
    }
    if ([regex]::Matches($source, 'Labels\["HelpTitle"\]\.Set\("(?:singleLine|autoSize)"').Count -ne 2) {
        throw 'Help-title fitting must initialize once without resizing its native area.'
    }
    foreach ($shape in @(@('set_autoSize', 'FairyGUI.AutoSizeType'), @('set_singleLine', 'System.Boolean'))) {
        $setter = @($assembly.MainModule.GetType('FairyGUI.GTextField').Methods | Where-Object Name -eq $shape[0])
        if ($setter.Count -ne 1 -or !$setter[0].IsPublic -or $setter[0].IsStatic -or $setter[0].Parameters.Count -ne 1 -or
            $setter[0].Parameters[0].ParameterType.FullName -ne $shape[1] -or $setter[0].ReturnType.FullName -ne 'System.Void') {
            throw "Native footer setter ABI changed: $($shape[0])"
        }
    }
    $shrink = $assembly.MainModule.GetType('FairyGUI.AutoSizeType').Fields | Where-Object Name -eq 'Shrink'
    if (!$shrink.HasConstant -or $shrink.Constant -ne 3) { throw 'Native footer Shrink enum changed' }
    $plugin = Get-Content -LiteralPath (Join-Path $root 'src/Plugin.cs') -Raw
    foreach ($setting in @('MatchFocus', 'FieldZoom')) {
        if ($plugin -notmatch ($setting + '\s*=\s*Config\.Bind\([^,]+,[^,]+,\s*true\s*,')) {
            throw "Fresh setting must default ON without overriding saved choices: $setting"
        }
    }
    $focusTick = $source.IndexOf('MatchFocus.Tick();')
    $pvpGate = $source.IndexOf('PvpSafety.Poll()')
    $zoomTick = $source.IndexOf('FieldZoomUi.Tick();', $source.IndexOf('UpdateNotificationUi.Tick();'))
    $notificationTick = if ($zoomTick -ge 0) { $source.LastIndexOf('UpdateNotificationUi.Tick();', $zoomTick) } else { -1 }
    if ($focusTick -lt 0 -or $focusTick -ge $pvpGate -or $zoomTick -le $pvpGate -or
        $notificationTick -lt 0 -or $zoomTick -le $notificationTick -or
        $zoomTick -ge $source.IndexOf('CardTargetButtonsUi.Tick();')) {
        throw 'Focus must poll before PvP gate; field zoom must run after notifications and before card input.'
    }
    $pvpCleanup = [regex]::Match($source, '(?s)Action\[\] PvpCleanup\s*=\s*\{.*?\};').Value
    $failCleanup = [regex]::Match($source, '(?s)internal static void FailUi\(.*?(?=    private static RuntimeObject Button)').Value
    if (!$pvpCleanup.Contains('FieldZoomUi.Clear') -or !$failCleanup.Contains('FieldZoomUi.Clear')) {
        throw 'Owned field zoom must clear on PvP and CoreUi failure.'
    }
    if ($source -notmatch 'if \(!Compatibility\.Allowed\("CoreUi"\)\) \{ FieldZoomUi\.Tick\(\);') {
        throw 'Blocked CoreUi must keep retrying owned field-camera cleanup.'
    }
    $zoom = Get-Content -LiteralPath (Join-Path $root 'src/FieldZoomUi.cs') -Raw
    if (!$zoom.Contains('!Plugin.FieldZoom.Value || PvpSafety.Suspended') -or
        !$zoom.Contains('Compatibility.Block("FieldZoom", ex, Clear)')) {
        throw 'Field zoom setting/PvP gate or independent cleanup breaker missing.'
    }
    $compatibility = Get-Content -LiteralPath (Join-Path $root 'src/Compatibility.cs') -Raw
    if ($compatibility -notmatch 'feature is not \([^\)]*"MatchFocus"[^\)]*\)') {
        throw 'Match focus must remain independently available after a CoreUi failure.'
    }
    [xml]$project = Get-Content -LiteralPath (Join-Path $root 'src/BetterAstralParty.csproj') -Raw
    $excluded = @($project.SelectNodes('//Compile[@Remove]') | ForEach-Object { $_.Remove -split ';' })
    foreach ($file in @('MatchFocus.cs', 'MatchFocusState.cs', 'WindowsMatchFocus.cs', 'FieldZoomUi.cs', 'FieldZoomGeometry.cs')) {
        if (!(Test-Path -LiteralPath (Join-Path $root ('src/' + $file))) -or $file -in $excluded) {
            throw "Feature source missing or excluded from production compilation: $file"
        }
    }
    $defaultCompile = $project.SelectSingleNode('//EnableDefaultCompileItems')
    if ($null -ne $defaultCompile -and $defaultCompile.InnerText -eq 'false') {
        throw 'Feature compilation guard requires default source inclusion.'
    }
    Write-Host 'PASS: settings phases/native coordinate ABI; feature/general rows with MatchFocus immediately below InputAttention and before steppers/updater; unchanged scroll ownership; full-version/saved footer with once-only native singleLine/Shrink ABI; ON defaults; focus/PvP ordering; zoom cleanup/breaker; production source inclusion. Actual font fitting/rendering remains unverified.'
} finally { $assembly.Dispose() }
