$ErrorActionPreference = 'Stop'
$launchStage = 'SteamContext'
try {
    throw '이전 PowerShell 실행 경로는 지원하지 않습니다. 새 1.2.1 Install.cmd로 설치한 Mod 바로가기를 사용하세요. / PowerShell launch routing is unsupported; use the Mod shortcut installed by the new complete 1.2.1 package.'
} catch {
    # The windowless parent captures stderr, logs it and displays one error dialog.
    $failure = $_.Exception.GetBaseException()
    $failureType = $failure.GetType().FullName
    if ($failureType -notin @('System.IO.FileNotFoundException','System.IO.DirectoryNotFoundException','System.UnauthorizedAccessException','System.IO.IOException','System.ArgumentException','System.InvalidOperationException','System.NotSupportedException','System.ComponentModel.Win32Exception','System.Security.SecurityException')) { $failureType = 'Unknown' }
    [Console]::Error.WriteLine(('LaunchFailure: schema=1; phase={0}; errorType={1}; hresult=0x{2:X8}' -f $launchStage,$failureType,$failure.HResult))
    [Console]::Error.WriteLine(($_ | Out-String))
    exit 1
}
