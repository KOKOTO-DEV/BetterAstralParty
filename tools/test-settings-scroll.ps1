$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Add-Type -Path "$root/.deps/bepinex/BepInEx/core/Mono.Cecil.dll"
$assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly("$root/.research/extracted/AstralParty.Runtime.dll.dll")
try {
    $checks = @{
        'FairyGUI.ScrollPane' = @('set_mouseWheelEnabled','set_bouncebackEffect','set_scrollStep','ScrollTop','SetPosY','get_scrollingPosY','get_isDragged','get_viewHeight','get_contentHeight')
        'FairyGUI.GList' = @('set_autoResizeItem','set_layout')
        'FairyGUI.Relations' = @('ClearAll')
        'FairyGUI.GComponent' = @('RemoveChildren','EnsureBoundsCorrect')
    }
    foreach ($name in $checks.Keys) {
        $type = $assembly.MainModule.GetType($name)
        foreach ($method in $checks[$name]) {
            if ($method -notin $type.Methods.Name) { throw "Missing native method: $name.$method" }
        }
    }
    if ('selectionMode' -notin $assembly.MainModule.GetType('FairyGUI.GList').Fields.Name) { throw 'Native list selection mode field changed' }
    $list = $assembly.MainModule.GetType('FairyGUI.GList')
    $autoScroll = $list.Fields | Where-Object Name -eq 'scrollItemToViewOnClick'
    if ($autoScroll.FieldType.FullName -ne 'System.Boolean') { throw 'Native click auto-scroll switch changed' }
    $click = ($list.Methods | Where-Object Name -eq '__clickItem').Body.Instructions
    $guard = @($click | Where-Object { $_.Operand -is [Mono.Cecil.FieldReference] -and $_.Operand.Name -eq 'scrollItemToViewOnClick' })
    if ($guard.Count -ne 1 -or $guard[0].Next.OpCode.Code -notin @('Brfalse','Brfalse_S')) { throw 'Click auto-scroll no longer guarded by native switch' }
    $scrollCall = @($click | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'ScrollToView' })
    if ($scrollCall.Count -ne 1 -or $guard[0].Next.Operand.Offset -le $scrollCall[0].Offset) { throw 'Disabled auto-scroll must bypass ScrollToView' }
    $source = Get-Content "$root/src/ModUi.cs" -Raw
    foreach ($phase in @('open begin', 'open complete', 'close begin', 'close complete', 'select', 'applied')) {
        if (!$source.Contains('settingsDropdown ' + $phase)) { throw "Missing dropdown crash breadcrumb: $phase" }
    }
    foreach ($required in @('if (_dropdown != null) { HandleDropdown(); return; }',
        'if (_dropdown != null) CloseDropdown(); else ClosePanel();',
        'if (!path.Any(item => item.Pointer == _dropdown!.Pointer)) CloseDropdown();',
        'if (current == IntPtr.Zero || current != _pressed)',
        'if (!Compatibility.Allowed(_dropdownAction!))',
        'Plugin.Language.Value = value', 'Plugin.GroupHand.Value = value != "Native"',
        'Plugin.InputAttention.Value = value', 'MenuLayout.DropdownY',
        'background.Set("grayed", options[i] != selected)')) {
        if (!$source.Contains($required)) { throw "Dropdown selection/lifecycle guard missing: $required" }
    }
    if ($source.Contains('HelpHint') -or $source.Contains('Cycle.') -or $source.Contains('ModText.NextMode')) {
        throw 'Obsolete cycle/help hint path remains'
    }
    foreach ($required in @('SetField("selectionMode", 3)', 'MenuLayout.InSettings(local.x, local.y)',
        'if (scrolling) { _pressed = IntPtr.Zero; hit = null; }', 'MenuLayout.ContentHeight(bottom)',
        'GameUi.Dispose(scrollTemplate)', 'MenuLayout.FooterY + 7',
        '_settingsView.SetField("scrollItemToViewOnClick", false)',
        'var scrollPosition = reopen ? _settingsScroll!.Get<float>("scrollingPosY") : 0;',
        '_settingsScroll!.Call("SetPosY", scrollPosition, false)')) {
        if (!$source.Contains($required)) { throw "Settings scrolling guard missing: $required" }
    }
    Write-Host 'PASS: native settings-scroll bindings, clipping/drag-click guards, content sizing, fixed footer. In-game rendering remains unverified.'
} finally { $assembly.Dispose() }
