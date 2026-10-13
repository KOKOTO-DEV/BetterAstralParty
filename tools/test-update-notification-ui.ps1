param([Parameter(Mandatory)][string]$PluginPath,
    [string]$ReferenceRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($ReferenceRoot)
Add-Type -Path (Join-Path $root '.deps/bepinex/BepInEx/core/Mono.Cecil.dll')
$native = [Mono.Cecil.AssemblyDefinition]::ReadAssembly((Join-Path $root '.research/extracted/AstralParty.Runtime.dll.dll'))
$plugin = [Mono.Cecil.AssemblyDefinition]::ReadAssembly([IO.Path]::GetFullPath($PluginPath))
try {
    $field = $native.MainModule.GetType('FairyGUI.GTextField')
    $setter = @($field.Methods | Where-Object Name -eq 'set_UBBEnabled')
    if ($setter.Count -ne 1 -or $setter[0].Parameters[0].ParameterType.FullName -ne 'System.Boolean') {
        throw 'Native plain-text switch missing or incompatible'
    }
    $layout = ($field.Methods | Where-Object Name -eq 'SetTextFieldText').Body.Instructions
    $guard = @($layout | Where-Object { $_.Operand -is [Mono.Cecil.FieldReference] -and $_.Operand.Name -eq '_ubbEnabled' })
    if ($guard.Count -ne 1 -or $guard[0].Next.OpCode.Code -notin @('Brfalse','Brfalse_S')) { throw 'Native markup guard changed' }
    $plainStart = $guard[0].Next.Operand.Offset
    $plain = @($layout | Where-Object { $_.Offset -ge $plainStart -and $_.Operand -is [Mono.Cecil.MethodReference] })
    if ($plain.Count -ne 1 -or $plain[0].Operand.FullName -ne 'System.Void FairyGUI.TextField::set_text(System.String)') {
        throw 'Disabled UBB no longer reaches only literal native text'
    }
    foreach ($contract in @(
        @('FairyGUI.GObject','get_relations','FairyGUI.Relations',@()),
        @('FairyGUI.Relations','ClearAll','System.Void',@()),
        @('FairyGUI.GComponent','get_scrollPane','FairyGUI.ScrollPane',@()),
        @('FairyGUI.GComponent','RemoveChildren','System.Void',@('System.Int32','System.Int32','System.Boolean')),
        @('FairyGUI.GComponent','EnsureBoundsCorrect','System.Void',@()),
        @('FairyGUI.GObject','SetSize','System.Void',@('System.Single','System.Single')),
        @('FairyGUI.GTextField','get_textHeight','System.Single',@()),
        @('FairyGUI.GTextField','set_autoSize','System.Void',@('FairyGUI.AutoSizeType')),
        @('FairyGUI.GList','set_autoResizeItem','System.Void',@('System.Boolean')),
        @('FairyGUI.GList','set_layout','System.Void',@('FairyGUI.ListLayoutType')),
        @('FairyGUI.ScrollPane','get_viewWidth','System.Single',@()),
        @('FairyGUI.ScrollPane','get_viewHeight','System.Single',@()),
        @('FairyGUI.ScrollPane','get_contentHeight','System.Single',@()),
        @('FairyGUI.ScrollPane','get_scrollingPosY','System.Single',@()),
        @('FairyGUI.ScrollPane','ScrollTop','System.Void',@('System.Boolean')),
        @('FairyGUI.ScrollPane','set_mouseWheelEnabled','System.Void',@('System.Boolean')),
        @('FairyGUI.ScrollPane','set_bouncebackEffect','System.Void',@('System.Boolean')),
        @('FairyGUI.ScrollPane','set_scrollStep','System.Void',@('System.Single')))) {
        $methods = @($native.MainModule.GetType($contract[0]).Methods | Where-Object {
            $_.Name -ceq $contract[1] -and $_.IsPublic -and !$_.IsStatic -and $_.ReturnType.FullName -ceq $contract[2] -and
            $_.Parameters.Count -eq $contract[3].Count -and
            [string]::Join('|',@($_.Parameters | ForEach-Object {$_.ParameterType.FullName})) -ceq [string]::Join('|',$contract[3])
        })
        if ($methods.Count -ne 1) { throw ('Native scroll/text signature changed: '+$contract[0]+'::'+$contract[1]) }
    }
    foreach ($contract in @(@('selectionMode','FairyGUI.ListSelectionMode'),@('scrollItemToViewOnClick','System.Boolean'))) {
        $fields = @($native.MainModule.GetType('FairyGUI.GList').Fields | Where-Object {
            $_.Name -ceq $contract[0] -and $_.IsPublic -and !$_.IsStatic -and $_.FieldType.FullName -ceq $contract[1]
        })
        if ($fields.Count -ne 1) { throw ('Native scroll field changed: '+$contract[0]) }
    }
    foreach ($contract in @(@('FairyGUI.AutoSizeType','Height',2),@('FairyGUI.ListLayoutType','SingleColumn',0),@('FairyGUI.ListSelectionMode','None',3))) {
        $enum = $native.MainModule.GetType($contract[0])
        if (!$enum.IsEnum -or @($enum.Fields | Where-Object { $_.Name -ceq 'value__' -and $_.FieldType.FullName -ceq 'System.Int32' }).Count -ne 1 -or
            @($enum.Fields | Where-Object { $_.Name -ceq $contract[1] -and $_.Constant -eq $contract[2] }).Count -ne 1) {
            throw ('Native scroll/text enum changed: '+$contract[0])
        }
    }
    $ui = $plugin.MainModule.GetType('BetterAstralParty.ModUi')
    $builder = ($ui.Methods | Where-Object Name -eq 'Create').Body.Instructions
    $switch = @($builder | Where-Object { $_.OpCode.Code -eq 'Ldstr' -and $_.Operand -eq 'UBBEnabled' })
    if ($switch.Count -ne 1 -or $switch[0].Next.OpCode.Code -ne 'Ldc_I4_0') { throw 'Production help text must disable native UBB' }
    $help = ($ui.Methods | Where-Object Name -eq 'SetHelp').Body.Instructions
    if (!($help | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.FullName.Contains('ModText::UpdateDetails') })) {
        throw 'Update text presenter is not wired to production help'
    }
    # Production authentication is owned by the security implementation, not by this presenter.
    foreach ($name in @('Check','Poll','Tick')) {
        $calls = ($plugin.MainModule.GetType('BetterAstralParty.ReleaseUpdates').Methods | Where-Object Name -eq $name).Body.Instructions
        if ($calls | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and ($_.Operand.Name -eq 'Wait' -or $_.Operand.Name -eq 'SendAsync') }) {
            throw 'Direct blocking/network work entered the UI-thread entry point'
        }
    }
    $tick = ($ui.Methods | Where-Object Name -eq 'Tick').Body
    $autoCall = @($tick.Instructions | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.DeclaringType.FullName -eq 'BetterAstralParty.ReleaseUpdates' -and $_.Operand.Name -eq 'Tick' })
    if ($autoCall.Count -ne 1 -or !($tick.ExceptionHandlers | Where-Object { $_.HandlerType -eq 'Catch' -and $_.TryStart.Offset -le $autoCall[0].Offset -and $_.TryEnd.Offset -gt $autoCall[0].Offset })) {
        throw 'Automatic update entry point lacks the final UI-frame exception boundary'
    }
    if (!($tick.Instructions | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.FullName.Contains('GameUi::RefreshReleaseNotification') })) {
        throw 'Automatic availability presenter is not connected'
    }
    $notice = ($plugin.MainModule.GetType('BetterAstralParty.GameUi').Methods | Where-Object Name -eq 'RefreshReleaseNotification').Body.Instructions
    if (!($notice | Where-Object { $_.Operand -is [Mono.Cecil.FieldReference] -and $_.Operand.Name -eq '_menu' }) -or !($notice | Where-Object { $_.OpCode.Code -eq 'Ldstr' -and $_.Operand -eq 'n8' })) {
        throw 'Home notification no longer targets the private menu clone known native title'
    }
    if ($notice | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'TogglePanel' }) { throw 'Notification must not open repeated popups' }
    $open = ($ui.Methods | Where-Object Name -eq 'TogglePanel').Body.Instructions
    if (!($open | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'AcknowledgeNotification' })) { throw 'Reading update notice must acknowledge it' }
    $popup = $plugin.MainModule.GetType('BetterAstralParty.UpdateNotificationUi')
    $state = $plugin.MainModule.GetType('BetterAstralParty.UpdateNotificationState')
    if (!$popup -or !$state) { throw 'Update notification UI/state missing from production build' }
    $popupCall = @($tick.Instructions | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.DeclaringType.FullName -eq $popup.FullName -and $_.Operand.Name -eq 'Tick' })
    $gameCall = @($tick.Instructions | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.FullName.Contains('GameUi::Tick') })
    if ($popupCall.Count -ne 1 -or $gameCall.Count -ne 1 -or $popupCall[0].Offset -le $gameCall[0].Offset) { throw 'Popup must poll after current game UI discovery' }
    $core = ($popup.Methods | Where-Object Name -eq 'TickCore').Body.Instructions
    if (!($core | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'NotificationHome' })) { throw 'Popup lacks current home eligibility gate' }
    $popupTick = ($popup.Methods | Where-Object Name -eq 'Tick').Body
    if (@($popupTick.ExceptionHandlers | Where-Object HandlerType -eq 'Catch').Count -ne 1) { throw 'Popup failure must be locally contained' }
    $forbidden = @('Download','Cancel','Preferences','Configure','Context','Reactivate','Recheck','Connect','SignOut','FrameFailed','SetSettingsModal','RegisterDelegateConvertor')
    foreach ($type in @($popup,$state)) {
        foreach ($method in $type.Methods | Where-Object HasBody) {
            foreach ($instruction in $method.Body.Instructions) {
                $call = $instruction.Operand
                if ($call -isnot [Mono.Cecil.MethodReference]) { continue }
                $reviewCleanup = $call.DeclaringType.FullName -ceq 'System.Threading.CancellationTokenSource' -and $call.Name -ceq 'Cancel'
                $rootPath = $call.DeclaringType.FullName -ceq 'System.IO.Path' -and $call.Name -ceq 'GetDirectoryName'
                if (!$reviewCleanup -and !$rootPath -and ($call.Name -in $forbidden -or $call.DeclaringType.FullName -match 'System\.IO\.|System\.Net\.|System\.Diagnostics\.Process|Harmony|DelegateSupport')) {
                    throw ('Notification must be presentation-only: ' + $call.FullName)
                }
            }
        }
    }
    $settingsActions = ($ui.Methods | Where-Object Name -eq 'ApplyCore').Body.Instructions
    if (!($settingsActions | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.DeclaringType.FullName -ceq $popup.FullName -and $_.Operand.Name -ceq 'BeginTransition' })) { throw 'Native settings command must reach the explicit transition review' }
    foreach ($contract in @(@('BeginTransition','BetterAstralParty.AutomaticUpdates','ProposeTransition'),@('HandleInput','BetterAstralParty.Updating.ChannelTransitionIntent','Approve'),@('HandleInput','BetterAstralParty.AutomaticUpdates','ConfirmTransition'))) {
        $calls = ($popup.Methods | Where-Object Name -ceq $contract[0]).Body.Instructions
        if (@($calls | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.DeclaringType.FullName -ceq $contract[1] -and $_.Operand.Name -ceq $contract[2] }).Count -ne 1) { throw ('Exact explicit transition call missing: '+[string]::Join('::',$contract)) }
    }
    foreach ($method in $popup.Methods | Where-Object HasBody) {
        foreach ($instruction in $method.Body.Instructions) {
            $call = $instruction.Operand
            if ($call -is [Mono.Cecil.MethodReference] -and $call.Name -in @('Approve','ConfirmTransition') -and $method.Name -cne 'HandleInput') { throw 'Only an explicit native button dispatch may approve a transition.' }
            if ($call -is [Mono.Cecil.MethodReference] -and $call.DeclaringType.FullName -ceq 'BetterAstralParty.Updating.WindowsFileFence') { throw 'Transition filesystem review must remain on its worker, not a native UI method.' }
        }
    }
    $homeGate = ($plugin.MainModule.GetType('BetterAstralParty.GameUi').Methods | Where-Object Name -eq 'NotificationHome').Body.Instructions
    foreach ($name in @('currentPanel','TeamId','roomStateType','connectRoomId','GetTopWindow','hasModalWindow','modalWaiting','hasAnyPopup','Cut_in','playing')) {
        if (!($homeGate | Where-Object { $_.OpCode.Code -eq 'Ldstr' -and $_.Operand -eq $name })) { throw ('Home gate missing: '+$name) }
    }
    $manager = $native.MainModule.GetType('UI.UIManager')
    $current = @($manager.Methods | Where-Object Name -eq 'get_currentPanel')
    if ($current.Count -ne 1 -or $current[0].ReturnType.FullName -ne 'UI.IBasePanel' -or $current[0].Parameters.Count -ne 0) { throw 'Current panel native contract changed' }
    $base = $native.MainModule.GetType('UI.BasePanel`1')
    if (@($base.Methods | Where-Object { $_.Name -eq 'get_ui' -and $_.Parameters.Count -eq 0 }).Count -ne 1) { throw 'Home ui getter contract changed' }
    $rootType = $native.MainModule.GetType('FairyGUI.GRoot')
    if (@($native.MainModule.GetType('FairyGUI.Transition').Methods | Where-Object { $_.Name -eq 'get_playing' -and $_.ReturnType.FullName -eq 'System.Boolean' -and $_.Parameters.Count -eq 0 }).Count -ne 1) { throw 'Native home transition playing contract changed' }
    foreach ($name in @('get_hasModalWindow','get_modalWaiting','get_hasAnyPopup')) {
        if (@($rootType.Methods | Where-Object { $_.Name -eq $name -and $_.ReturnType.FullName -eq 'System.Boolean' -and $_.Parameters.Count -eq 0 }).Count -ne 1) { throw ('Native root blocker changed: '+$name) }
    }
    if (@($native.MainModule.GetType('GameLogic.RoomStateType').Fields | Where-Object { $_.Name -eq 'NONE' -and $_.Constant -eq 0 }).Count -ne 1) { throw 'Native idle room enum changed' }
    foreach ($pair in @(@('GameLogic.MatchData','get_TeamId'),@('GameLogic.GameLogicManager','get_connectRoomId'))) {
        if (@($native.MainModule.GetType($pair[0]).Methods | Where-Object { $_.Name -eq $pair[1] -and $_.ReturnType.FullName -eq 'System.Int64' -and $_.Parameters.Count -eq 0 }).Count -ne 1) { throw ('Native home long getter changed: '+$pair[1]) }
    }
    $presenter = ($popup.Methods | Where-Object Name -eq 'Refresh').Body.Instructions
    if (!($presenter | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.FullName.Contains('ModText::UpdateNotificationDetails') })) { throw 'Popup lacks bilingual status presentation' }
    $createPopup = ($popup.Methods | Where-Object Name -eq 'Create').Body.Instructions
    foreach ($name in @('Com_BuffInfo','list_Buff','relations','ClearAll','RemoveChildren','autoResizeItem','layout','selectionMode',
        'scrollItemToViewOnClick','scrollPane','mouseWheelEnabled','bouncebackEffect','scrollStep','viewWidth','UBBEnabled','singleLine')) {
        if (!($createPopup | Where-Object { $_.OpCode.Code -eq 'Ldstr' -and $_.Operand -ceq $name })) { throw ('Popup native scroll setup missing: '+$name) }
    }
    $literalSwitch = @($createPopup | Where-Object { $_.OpCode.Code -eq 'Ldstr' -and $_.Operand -ceq 'UBBEnabled' })
    $wrappedHeight = @($createPopup | Where-Object { $_.OpCode.Code -eq 'Ldstr' -and $_.Operand -ceq 'autoSize' })
    if ($literalSwitch.Count -ne 1 -or $literalSwitch[0].Next.OpCode.Code -ne 'Ldc_I4_0' -or
        $wrappedHeight.Count -ne 1 -or $wrappedHeight[0].Next.OpCode.Code -ne 'Ldc_I4_2') { throw 'Popup must be literal wrapped auto-height text, not shrink-to-fit' }
    if (@($createPopup | Where-Object { $_.OpCode.Code -eq 'Ldstr' -and $_.Operand -ceq 'ScrollTop' }).Count -ne 1 -or
        ($presenter | Where-Object { $_.OpCode.Code -eq 'Ldstr' -and $_.Operand -ceq 'ScrollTop' })) { throw 'Only popup creation may reset native reading position' }
    foreach ($name in @('textHeight','width','SetSize','EnsureBoundsCorrect')) {
        if (!($presenter | Where-Object { $_.OpCode.Code -eq 'Ldstr' -and $_.Operand -ceq $name })) { throw ('Popup text-height/bounds refresh missing: '+$name) }
    }
    $fontPoll = @($core | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.DeclaringType.FullName -ceq 'BetterAstralParty.ModFont' -and $_.Operand.Name -ceq 'get_Revision' })
    $fontCapture = @($presenter | Where-Object { $_.OpCode.Code -eq 'Stsfld' -and $_.Operand -is [Mono.Cecil.FieldReference] -and $_.Operand.Name -ceq '_fontRevision' })
    $titleStyles = @($presenter | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.DeclaringType.FullName -ceq 'BetterAstralParty.NativeUi' -and $_.Operand.Name -ceq 'StyleTitle' })
    if ($fontPoll.Count -ne 1 -or $fontCapture.Count -ne 1 -or $titleStyles.Count -ne 1 -or
        $fontCapture[0].Offset -le $titleStyles[0].Offset -or $fontCapture[0].Previous.Operand -isnot [Mono.Cecil.MethodReference] -or
        $fontCapture[0].Previous.Operand.FullName -cne 'System.Int32 BetterAstralParty.ModFont::get_Revision()') {
        throw 'Popup must remeasure delayed font fallback and capture its revision after all font writes'
    }
    $textType = $plugin.MainModule.GetType('BetterAstralParty.ModText')
    $marker = ($popup.Methods | Where-Object Name -eq 'UpdateScrollMarker').Body.Instructions
    foreach ($name in @('scrollPane','viewHeight','contentHeight','scrollingPosY','visible','SetSize','SetXY')) {
        if (!($marker | Where-Object { $_.OpCode.Code -eq 'Ldstr' -and $_.Operand -ceq $name })) { throw ('Popup position marker native contract missing: '+$name) }
    }
    if (!($core | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.DeclaringType.FullName -ceq $popup.FullName -and $_.Operand.Name -ceq 'UpdateScrollMarker' }) -or
        !($marker | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.DeclaringType.FullName -ceq 'BetterAstralParty.MenuLayout' -and $_.Operand.Name -ceq 'ScrollMarker' }) -or
        @($createPopup | Where-Object { $_.OpCode.Code -eq 'Newobj' -and $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.DeclaringType.FullName -ceq 'BetterAstralParty.NativeUi/Surface' }).Count -ne 2) {
        throw 'Popup must reuse the existing settings position-only scroll marker'
    }
    $hoverText = ($textType.Methods | Where-Object Name -eq 'UpdateDetails').Body.Instructions
    if ($hoverText | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -in @('get_Notes','PlainText') }) { throw 'Release notes must not return to UpdateCheck hover' }
    $popupText = ($textType.Methods | Where-Object Name -eq 'UpdateNotificationDetails').Body.Instructions
    if (!($popupText | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'get_Notes' }) -or
        !($popupText | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.DeclaringType.FullName -eq 'BetterAstralParty.ReleaseUpdates' -and $_.Operand.Name -eq 'PlainText' }) -or
        !($popupText | Where-Object { $_.OpCode.Code -eq 'Ldc_I4' -and $_.Operand -eq 4096 })) { throw 'Popup lacks full bounded literal release notes' }
    $noticeInput = ($popup.Methods | Where-Object Name -eq 'HandleInput').Body.Instructions
    if (!($noticeInput | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.FullName.Contains('UpdateNotificationInput::Step') })) { throw 'Popup input state not linked' }
    Write-Host 'PASS: compiled ordinary notice/status/notes presentation boundary and explicit signed transition native settings/button call path; strict native scroll/getter/setter/field/int32-enum contracts; literal wrapped auto-height text and bounded notes; create-only scroll reset, content-height refresh and delayed font revision capture; current home/input gates and bilingual presenter. Metadata only; actual native marshaling, wheel behavior and in-game rendering unexecuted.'
} finally { $plugin.Dispose(); $native.Dispose() }
