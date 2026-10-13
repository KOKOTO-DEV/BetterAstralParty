using System.Collections.Concurrent;
using BetterAstralParty;
using BetterAstralParty.Updating;

internal static class UpdateSafetyCheck
{
    private sealed class Handoff : IUpdateHandoff
    {
        public bool Configured => true;
        public Task<object> Prepare(DownloadedUpdate update, UpdateContext context, CancellationToken token) => throw new Exception("No fixture download is allowed");
        public Task<object> Queue(object prepared, CancellationToken token) => throw new Exception("No fixture launch is allowed");
        public void SignalCancel(object prepared) => throw new Exception("No fixture handoff exists");
        public Task Cancel(object prepared) => throw new Exception("No fixture handoff exists");
        public Task<string?> Inspect() => Task.FromResult<string?>(null);
    }
    private static int _checks;
    private static void Check(bool condition, string name)
    { if (!condition) throw new Exception("Update safety: " + name); _checks++; }
    private static async Task Settle(AutomaticUpdates updates, DateTimeOffset now)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (updates.Status == AutomaticUpdateStatus.CheckingInstallation && DateTime.UtcNow < deadline) {
            updates.Tick(now); await Task.Delay(1);
        }
        updates.Tick(now);
        Check(updates.Status != AutomaticUpdateStatus.CheckingInstallation, "bounded fixture worker completed");
    }
    private static async Task Cases()
    {
        if (!OperatingSystem.IsWindows()) throw new Exception("Native NTFS safety checks require Windows");
        var parent = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar);
        var root = Path.Combine(parent, "bap-probe-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try {
            foreach (var native in new[] { 32, 33 }) {
                var saves = new ConcurrentQueue<(bool, bool)>(); var calls = 0;
                var safety = new FileUpdateSafety(root, (download, apply) => { saves.Enqueue((download, apply)); return Task.CompletedTask; },
                    readiness: () => Interlocked.Increment(ref calls) == 1
                        ? Task.FromException(new ApplySafetyException(ApplyFailure.FileBusy, native)) : Task.CompletedTask);
                using var updates = new AutomaticUpdates(UpdateDownloads.Production(), new Handoff(), safety);
                var now = DateTimeOffset.UtcNow;
                updates.Configure(null); await Settle(updates, now);
                Check(updates.Status == AutomaticUpdateStatus.FilesBusy && updates.AutoDownload && updates.ApplyAfterExit && saves.IsEmpty,
                    "transient " + native + " preserves preferences");
                updates.Tick(now.AddSeconds(1));
                Check(calls == 1, "busy probe does not repeat every frame");
                updates.Tick(now.AddSeconds(3)); await Settle(updates, now.AddSeconds(3));
                Check(calls == 2 && updates.Status is not (AutomaticUpdateStatus.FilesBusy or AutomaticUpdateStatus.RecoveryRequired)
                    && updates.AutoDownload && updates.ApplyAfterExit && saves.IsEmpty, "lock release is rechecked without user reactivation");
            }
            foreach (var native in new[] { 5, 2, 0 }) {
                var safety = new FileUpdateSafety(root, (_, _) => Task.CompletedTask,
                    readiness: () => Task.FromException(new ApplySafetyException(ApplyFailure.RecoveryRequired, native)));
                try { await safety.Probe(); throw new Exception("Unexpected accepted permanent fault"); }
                catch (ApplySafetyException error) { Check(error.Failure == ApplyFailure.RecoveryRequired && error.NativeError == native,
                    "non-sharing failure is not Busy: " + native); }
            }
            var normal = await new FileUpdateSafety(root, (_, _) => Task.CompletedTask, readiness: () => Task.CompletedTask).Probe();
            Check(!normal.Busy && !normal.RecoveryRequired && normal.Fault == null, "normal read-only probe remains normal");
        } finally {
            if (Path.GetDirectoryName(root) != parent || !Path.GetFileName(root).StartsWith("bap-probe-", StringComparison.Ordinal))
                throw new Exception("Unsafe fixture cleanup");
            Directory.Delete(root, true);
        }
    }
    internal static void Run()
    {
        Cases().GetAwaiter().GetResult();
        Console.WriteLine($"Update readiness: {_checks} checks PASS; temporary locks rechecked; no game, Steam, network or settings file.");
    }
}
