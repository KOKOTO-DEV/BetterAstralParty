using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class SteamLauncher
{
    [STAThread]
    private static int Main()
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        int exitCode = 1;
        try
        {
            string details;
            exitCode = Run(root, out details);
            if (exitCode != 0) throw new Exception("Launch exit code: " + exitCode + "\r\n" + details);
            return exitCode;
        }
        catch (Exception error)
        {
            string? path = SaveFailure(CaptureLaunchContext(root) + error.ToString());
            MessageBox.Show("모드 실행에 실패했습니다. / Mod launch failed.\r\n" +
                (path == null ? error.Message : "로그 / Debug log: " + path), "BetterAstralParty");
            return exitCode == 0 ? 1 : exitCode;
        }
    }

    public const int InstallBundleProtocol = 1;
    public static IDisposable GuardModLaunchVerified(string root,string? snapshotHash) {
        return new BetterAstralParty.Updating.UpdateLaunchGate.Lease(root, fence => {
            var assembly=typeof(SteamLauncher).Assembly;
            if(assembly.Location.Length!=0 && !String.Equals(Path.GetFullPath(assembly.Location),fence.Full("BetterAstralParty-Launcher.exe"),StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Installed launcher required.");
            if(snapshotHash!=null){
                if(!System.Text.RegularExpressions.Regex.IsMatch(snapshotHash,@"\A[0-9A-F]{64}\z"))throw new InvalidOperationException("Invalid launcher snapshot hash.");
                using(var launcher=fence.OpenLaunchImage("BetterAstralParty-Launcher.exe"))
                    if(launcher.Hash()!=snapshotHash)throw new InvalidOperationException("Launcher changed after snapshot capture.");
            }
            BetterAstralParty.Updating.InstallReceipt installed;
            using(var receipt=fence.OpenFile(BetterAstralParty.Updating.InstallReceipt.Path))
                installed=BetterAstralParty.Updating.InstallReceipt.Parse(BetterAstralParty.Updating.UpdateTicket.Read(receipt,16384));
            if(installed.Channels==null || installed.Channels.Root!=fence.RootIdentity.Text)
                throw new InvalidOperationException("Installed receipt belongs to another game root.");
            foreach(var path in BetterAstralParty.Updating.InstallReceipt.Owned) {
                using(var file=path=="BetterAstralParty-Launcher.exe" ? fence.OpenLaunchImage(path) : fence.OpenFile(path)) {
                    if(file.Hash()!=installed.Files[path])throw new InvalidOperationException("Installed file changed: "+path);
                    if(path==BetterAstralParty.Updating.UpdateTrust.PluginPath) {
                        var metadata=BetterAstralParty.Updating.InstalledPluginMetadata.Read(BetterAstralParty.Updating.UpdateTicket.Read(file,(int)BetterAstralParty.Updating.UpdateTrust.MaxFileBytes));
                        if(metadata.Version!=installed.Channels.ActiveVersion || metadata.UpdateProtocol!=3 || metadata.SettingsSchema!=1)
                            throw new InvalidOperationException("Installed plugin does not match the supported receipt.");
                    }
                }
            }
            if(BetterAstralParty.Updating.HelperDelivery.Fingerprint(fence,BetterAstralParty.Updating.UpdateTrust.Production(),3)==null)
                throw new InvalidOperationException("새 1.2.1 전체 패키지로 설치하세요. / Install the new complete 1.2.1 package.");
        });
    }
    public static IDisposable GuardMaintenance(string root) { return new BetterAstralParty.Updating.UpdateLaunchGate.Lease(root); }
    public static object[] ReadMaintenanceProcess(int pid) {
        if(pid<=0)throw new ArgumentOutOfRangeException(nameof(pid));
        using(var process=BetterAstralParty.Updating.WindowsProcessGuard.Observe((uint)pid, allowExited: true))
            return new object[]{process.Exited,process.Image,process.Creation,process.Session};
    }
    public static void EnableSharedLoader(string root, IDisposable guardedLaunch) {
        if(guardedLaunch is not BetterAstralParty.Updating.UpdateLaunchGate.Lease operation)
            throw new InvalidOperationException("A retained launch lease is required");
        BetterAstralParty.Updating.SharedLoaderConfiguration.Enable(root,operation);
    }
    public static string ReadInstallerState(string root)
    {
        using (var fence = new BetterAstralParty.Updating.WindowsFileFence(root)) {
            var water = BetterAstralParty.Updating.UpdateTransaction.ReadHighWater(fence, out var hash);
            var version = water == null ? "" : BetterAstralParty.Updating.UpdateVersion.Parse(water).Tag;
            return "BetterAstralParty.InstallerState/v1\nroot=" + fence.RootIdentity.Text + "\nversion=" + version + "\nwater-sha=" + (hash ?? "") + "\n";
        }
    }
    public static void ValidateMaintenancePaths(string root,string journalRoot) {BetterAstralParty.Updating.WholeInstallBridge.ValidateMaintenancePaths(root,journalRoot);}
    public static void ValidateInstalledHistory(string root) {
        using(var fence=new BetterAstralParty.Updating.WindowsFileFence(root))using(var file=fence.OpenFile(BetterAstralParty.Updating.InstallReceipt.Path,false))
        using(var history=BetterAstralParty.Updating.UpdateTransaction.ValidateHistory(fence,BetterAstralParty.Updating.InstallReceipt.Parse(BetterAstralParty.Updating.UpdateTicket.Read(file,16384)))) { }
    }
    public static string? CheckOwnedHelper(string root)
    {
        using (var fence = new BetterAstralParty.Updating.WindowsFileFence(root)) {
            BetterAstralParty.Updating.UpdateLaunchGate.Check(fence);
            string? image;
            try { image = BetterAstralParty.Updating.HelperDelivery.Fingerprint(fence, BetterAstralParty.Updating.UpdateTrust.Production()); }
            catch (BetterAstralParty.Updating.UpdateValidationException) {
                BetterAstralParty.Updating.UpdateLaunchGate.Check(fence);
                return null;
            }
            catch (BetterAstralParty.Updating.ApplySafetyException error) {
                if (error.Failure != BetterAstralParty.Updating.ApplyFailure.RecoveryRequired &&
                    error.Failure != BetterAstralParty.Updating.ApplyFailure.InvalidState) throw;
                BetterAstralParty.Updating.UpdateLaunchGate.Check(fence);
                return null;
            }
            if (image == null) return null;
            using (var receipt = fence.OpenFile(BetterAstralParty.Updating.HelperDelivery.Receipt))
                return image + ":" + receipt.Hash();
        }
    }
    public static void CheckUpdateState(string root) {using(var fence=new BetterAstralParty.Updating.WindowsFileFence(root)) BetterAstralParty.Updating.UpdateLaunchGate.Check(fence);}

    public static string ValidateRemovedHelperEvidence(string root,byte[] image,byte[] receipt)
    {
        using(var fence=new BetterAstralParty.Updating.WindowsFileFence(root)) {
            BetterAstralParty.Updating.UpdateLaunchGate.Check(fence);
            return BetterAstralParty.Updating.HelperDelivery.RemovedEvidence(fence,BetterAstralParty.Updating.UpdateTrust.Production(),image,receipt);
        }
    }

    public static string ValidateHelperBootstrap(string bundleRoot, string version, string expectedHash)
    {
        return BetterAstralParty.Installation.InstallHelperBootstrap.Validate(bundleRoot, version, expectedHash);
    }
    public static int InstallHelperBootstrap(string root, string bundleRoot, string version, string expectedHash)
    {
        return BetterAstralParty.Installation.InstallHelperBootstrap.Install(root, bundleRoot, version, expectedHash);
    }

    private sealed class InstallerDiagnosticLease : IDisposable {
        private readonly BetterAstralParty.Observability.MinimalEventLog _sink;
        internal InstallerDiagnosticLease(string root,string version) {
            _sink=BetterAstralParty.Observability.DiagnosticOwner.StartInstaller(root,version,typeof(SteamLauncher).Module.ModuleVersionId.ToString("N"));
            if(!BetterAstralParty.Observability.DiagnosticHub.Bind(_sink)) {_sink.Dispose();throw new InvalidOperationException("Diagnostic owner already bound.");}
        }
        public void Dispose() {_sink.Stop(BetterAstralParty.Observability.DiagnosticEndReason.OwnerDisposed);BetterAstralParty.Observability.DiagnosticHub.Unbind(_sink);}
    }
    public static IDisposable BeginInstallerDiagnostics(string root,string version) {return new InstallerDiagnosticLease(root,version);}
    public static void RecordInstallerStage(string phase,string outcome) {
        BetterAstralParty.Observability.DiagnosticPhase p;BetterAstralParty.Observability.DiagnosticOutcome o;
        if(!Enum.TryParse(phase,out p) || !Enum.IsDefined(typeof(BetterAstralParty.Observability.DiagnosticPhase),p) || !Enum.TryParse(outcome,out o) || !Enum.IsDefined(typeof(BetterAstralParty.Observability.DiagnosticOutcome),o))return;
        BetterAstralParty.Observability.DiagnosticHub.Stage(BetterAstralParty.Observability.DiagnosticFeature.Installer,p,o);
    }
    public static void RecordInstallerFailure(string phase,Exception error) {
        BetterAstralParty.Observability.DiagnosticPhase p;
        if(!Enum.TryParse(phase,out p) || !Enum.IsDefined(typeof(BetterAstralParty.Observability.DiagnosticPhase),p))return;
        var cause=error;var code=BetterAstralParty.Observability.DiagnosticCode.Unknown;var native=0;var apply=0;var validation=0;
        for(var depth=0;depth<8;depth++) {
            if(cause is BetterAstralParty.Updating.ApplySafetyException safety) {
                native=safety.NativeError;apply=(int)safety.Failure;
                var reason=safety.Data["BapRecoveryReason"] as string;
                code=reason=="MaintenancePathTooLong"?BetterAstralParty.Observability.DiagnosticCode.LimitExceeded
                    : reason=="HighWaterRootMismatch" || reason=="HighWaterRepositoryMismatch"?BetterAstralParty.Observability.DiagnosticCode.WrongTarget
                    : reason=="HighWaterProofMissing"?BetterAstralParty.Observability.DiagnosticCode.Prerequisite
                    : reason!=null && reason.StartsWith("HighWater",StringComparison.Ordinal)?BetterAstralParty.Observability.DiagnosticCode.Integrity
                    : BetterAstralParty.Observability.DiagnosticHub.CodeForStatus(safety.Failure.ToString());break;
            }
            if(cause is BetterAstralParty.Updating.UpdateValidationException invalid) {validation=(int)invalid.Failure;code=BetterAstralParty.Observability.DiagnosticHub.CodeForStatus(invalid.Failure.ToString());break;}
            if(cause.InnerException==null)break;cause=cause.InnerException;
        }
        BetterAstralParty.Observability.DiagnosticHub.Failure(BetterAstralParty.Observability.DiagnosticFeature.Installer,p,code,cause,native,validation,applyCode:apply);
    }

    public static void ValidateInstalledReceipt(byte[] bytes) {BetterAstralParty.Updating.InstallReceipt.Parse(bytes);}
    public static void ValidatePartialRemoval(string root) {BetterAstralParty.Updating.WholeInstallBridge.ValidatePartialRemoval(root);}
    public static void ValidatePartialRemovalWithPackage(string root,string package,string version) {BetterAstralParty.Updating.WholeInstallBridge.ValidatePartialRemovalWithPackage(root,package,version);}
    public static string ValidateRemovedInstallEvidence(string root,string package,string version,byte[] receipt) {return BetterAstralParty.Updating.WholeInstallBridge.RemovedInstallEvidence(root,package,version,receipt);}
    public static void ValidateWholeInputs(string root,string package,string version) {BetterAstralParty.Updating.WholeInstallBridge.ValidateInputs(root,package,version);}
    public static string ValidateWholeBridge(string root,string package,string version) {return BetterAstralParty.Updating.WholeInstallBridge.Validate(root,package,version);}
    public static string ValidateReviewedWholeBridge(string root,string package,string version,string review) {return BetterAstralParty.Updating.WholeInstallBridge.ValidateReviewed(root,package,version,review);}
    public static string ReadVerifiedInstalledState(string root,string package,string version) {return BetterAstralParty.Updating.WholeInstallBridge.VerifiedInstalledState(root,package,version);}
    public static string PrepareWholeReceipt(string root,string package,string version,string observation,string loaderBefore) {return BetterAstralParty.Updating.WholeInstallBridge.PrepareReceipt(root,package,version,observation,loaderBefore);}
    public static IDisposable GuardWholeRecovery(string root,string package,string version) {return BetterAstralParty.Updating.WholeInstallBridge.GuardRecovery(root,package,version);}
    public static IDisposable BeginWholeInstall(string root,string package,string version,string observation,string receipt) {return BetterAstralParty.Updating.WholeInstallBridge.BeginInstall(root,package,version,observation,receipt);}
    public static void RecoverWholeHelper(string root,string package,string version) {BetterAstralParty.Updating.WholeInstallBridge.Recover(root,package,version);}
    public static void InstallWholeHelper(string root,string package,string version,string observation,string receiptHash) {BetterAstralParty.Updating.WholeInstallBridge.Install(root,package,version,observation,receiptHash);}
    public static void RestoreOrdinaryInstall(string root,string journalRoot,string journalHash,string[] allowedTargets,string expectedCurrent,bool completeOnly,string rootIdentity) {BetterAstralParty.Updating.OrdinaryInstallRecovery.Run(root,journalRoot,journalHash,allowedTargets,expectedCurrent,completeOnly,rootIdentity);}
    public static IDisposable BeginOwnedRemoval(string root,string journalRoot,string journalHash,string[] allowedTargets,string rootIdentity,bool allowLoader) {
        return new BetterAstralParty.Updating.OrdinaryInstallRecovery.OwnedRemovalLease(root,journalRoot,journalHash,allowedTargets,rootIdentity,allowLoader);
    }

    internal static int Run(string root, out string details)
    {
        details = "";
        string phase = "SteamContext";
        try {
            if (String.IsNullOrEmpty(Environment.GetEnvironmentVariable("SteamGameId")))
                throw new InvalidOperationException("Open Astral Party - Mod from your Steam library.");
            foreach (var name in new[] { "AstralParty_INT", "AstralParty_CN" }) {
                var running = Process.GetProcessesByName(name);
                try { if (running.Length != 0) throw new InvalidOperationException("Close Astral Party before launching the mod."); }
                finally { foreach (var process in running) process.Dispose(); }
            }
            phase = "UpdateGate";
            // The already running native host owns the lease; PowerShell never reloads this executable.
            using (var guardedLaunch = GuardModLaunchVerified(root, null)) {
                phase = "Compatibility";
                var checkStart = new ProcessStartInfo {
                    FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe"),
                    Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + Path.Combine(root, "check-compatibility.ps1") + "\" -GameRoot \"" + root.TrimEnd(Path.DirectorySeparatorChar) + "\"",
                    WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true
                };
                checkStart.EnvironmentVariables["PSModulePath"] = Path.Combine(Path.GetDirectoryName(checkStart.FileName)!, "Modules");
                using (var check = Process.Start(checkStart) ?? throw new InvalidOperationException("Compatibility checker could not start")) {
                    var stdout = check.StandardOutput.ReadToEndAsync();
                    var stderr = check.StandardError.ReadToEndAsync();
                    check.WaitForExit();
                    var output = stdout.Result;
                    var errorOutput = stderr.Result;
                    if (check.ExitCode != 0) {
                        details = LaunchFailure(phase, new InvalidOperationException("Compatibility check failed (exit " + check.ExitCode + "). " + errorOutput + " " + output));
                        return check.ExitCode;
                    }
                }
                phase = "SharedLoader";
                EnableSharedLoader(root, guardedLaunch);
                var start = new ProcessStartInfo {
                    FileName = Path.Combine(root, "AstralParty_INT.exe"),
                    Arguments = "--doorstop-enabled true --bap-compatibility-checked",
                    WorkingDirectory = root, UseShellExecute = false
                };
                foreach (var name in new[] { "SteamAppId", "SteamGameId", "SteamOverlayGameId" }) start.EnvironmentVariables[name] = "2622000";
                start.EnvironmentVariables["BAP_COMPATIBILITY_CHECKED"] = "1";
                using (var launcher = Process.GetCurrentProcess()) {
                    start.EnvironmentVariables["BAP_UPDATER_LAUNCHER_PID"] = launcher.Id.ToString(System.Globalization.CultureInfo.InvariantCulture);
                    start.EnvironmentVariables["BAP_UPDATER_LAUNCHER_CREATION"] = launcher.StartTime.ToFileTimeUtc().ToString(System.Globalization.CultureInfo.InvariantCulture);
                    start.EnvironmentVariables["BAP_UPDATER_LAUNCHER_SESSION"] = launcher.SessionId.ToString(System.Globalization.CultureInfo.InvariantCulture);
                }
                phase = "GameStart";
                using (var game = Process.Start(start) ?? throw new InvalidOperationException("Game could not start")) {
                    phase = "GameExit";
                    game.WaitForExit();
                    if (game.ExitCode != 0) details = LaunchFailure(phase, new InvalidOperationException("Game exited with code " + game.ExitCode + ". Include BepInEx/LogOutput.log and Player.log when reporting a crash."));
                    return game.ExitCode;
                }
            }
        } catch (Exception error) { details = LaunchFailure(phase, error); return 1; }
    }

    internal static string LaunchFailure(string phase, Exception error)
    {
        var failure = error.GetBaseException();
        var type = failure.GetType().FullName ?? "Unknown";
        var allowed = new[] { "System.IO.FileNotFoundException", "System.IO.DirectoryNotFoundException", "System.UnauthorizedAccessException", "System.IO.IOException", "System.ArgumentException", "System.InvalidOperationException", "System.NotSupportedException", "System.ComponentModel.Win32Exception", "System.Security.SecurityException" };
        if (Array.IndexOf(allowed, type) < 0) type = "Unknown";
        return "LaunchFailure: schema=1; phase=" + phase + "; errorType=" + type + "; hresult=0x" + failure.HResult.ToString("X8") + "\r\n" + error;
    }

    // Failure-time observations only. No diagnosis, execution or authorization is inferred from these paths.
    internal static string CaptureLaunchContext(string root)
    {
        string full;
        try { full = Path.GetFullPath(root); if (full.Length > 512) throw new ArgumentException(); }
        catch (Exception error) {
            return "LaunchRoot: source=LauncherDirectory; state=Invalid; hresult=0x" + error.HResult.ToString("X8") + "\r\n";
        }
        var text = new System.Text.StringBuilder("Game: ").Append(full).Append("\r\nLaunchRoot: source=LauncherDirectory; ")
            .Append(LaunchEntryState(full)).Append("\r\n");
        string[] names = { "AstralParty_INT.exe", "BetterAstralParty-Steam.ps1", "check-compatibility.ps1", "BetterAstralParty-Launcher.exe" };
        string[] kinds = { "GameExecutable", "EntryScript", "CompatibilityScript", "Launcher" };
        for (int i = 0; i < names.Length; i++)
            text.Append("LaunchFile: kind=").Append(kinds[i]).Append("; ").Append(LaunchEntryState(Path.Combine(full, names[i]))).Append("\r\n");
        return text.ToString();
    }
    private static string LaunchEntryState(string path)
    {
        string state; int hresult = 0;
        try {
            var attributes = File.GetAttributes(path);
            state = (attributes & FileAttributes.ReparsePoint) != 0 ? "Linked"
                : (attributes & FileAttributes.Directory) != 0 ? "Directory" : "File";
        }
        catch (FileNotFoundException error) { state = "Missing"; hresult = error.HResult; }
        catch (DirectoryNotFoundException error) { state = "Missing"; hresult = error.HResult; }
        catch (UnauthorizedAccessException error) { state = "Denied"; hresult = error.HResult; }
        catch (ArgumentException error) { state = "Invalid"; hresult = error.HResult; }
        catch (Exception error) { state = "Unavailable"; hresult = error.HResult; }
        return "state=" + state + "; hresult=0x" + hresult.ToString("X8");
    }

    internal static string? SaveFailure(string details)
    {
        string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!String.IsNullOrEmpty(profile)) details = System.Text.RegularExpressions.Regex.Replace(details,
            System.Text.RegularExpressions.Regex.Escape(profile), "%USERPROFILE%", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        foreach (string directory in new[] {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"BetterAstralParty\Logs"),
            Path.Combine(Path.GetTempPath(), "BetterAstralParty") })
        {
            try {
                Directory.CreateDirectory(directory);
                string path = Path.Combine(directory, "Launch-" + Guid.NewGuid().ToString("N") + ".log");
                File.WriteAllText(path, "BAP-LAUNCH-FAILED\r\nTime: " + DateTimeOffset.Now.ToString("o") + "\r\n" + details);
                return path;
            } catch { /* A failed log write must not prevent the error dialog. */ }
        }
        return null;
    }
}
