using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Text.Json;
using BetterAstralParty;
using BetterAstralParty.Diagnostics;
using BetterAstralParty.Observability;
using BetterAstralParty.Updating;

internal static class ChannelDiagnosticsFixture
{
    internal static void Run(Action<ReleaseUpdateResult> inject, Action<Action?> frame, Action reviewSwitch, Action<string, bool> click)
    {
        var root = Path.Combine(AppContext.BaseDirectory, "cd-" + Guid.NewGuid().ToString("N").Substring(0, 8));
        var checks = new List<string>();
        void Check(bool value, string name) { if (!value) throw new InvalidOperationException(name); checks.Add(name); }
        Directory.CreateDirectory(root);
        using var owner = DiagnosticOwner.Start(root, false, Plugin.Version, new string('B', 32));
        Check(DiagnosticHub.Bind(owner), "actual channel producer has real typed diagnostic owner");
        try
        {
            reviewSwitch(); var before = Plugin.Automatic.ConfirmCalls;
            click("Button_ConfirmRounded", true); click("Button_ConfirmRounded", false);
            Check(Plugin.Automatic.ConfirmCalls == before + 1, "actual native confirmation emits one completed operation");
            reviewSwitch(); UpdateNotificationUi.Clear();
            Plugin.Automatic.CanReviewTransition = false; UpdateNotificationUi.BeginTransition();
            var pending = typeof(UpdateNotificationUi).GetField("_pendingTransition", BindingFlags.Static | BindingFlags.NonPublic)!;
            void Fail(Exception error)
            {
                UpdateNotificationUi.Clear(); Plugin.Automatic.CanReviewTransition = Plugin.Automatic.ProposalCurrent = true;
                error.Data["token"] = "FAKE_UI_PRIVATE_DATA";
                var worker = new TaskCompletionSource<ChannelTransitionProposal>(TaskCreationOptions.RunContinuationsAsynchronously);
                Plugin.Automatic.ProposalWorker = worker;
                UpdateNotificationUi.BeginTransition(); worker.SetException(error);
                for (var i = 0; i < 200 && pending.GetValue(null) != null; i++) { frame(null); Thread.Sleep(2); }
                Check(pending.GetValue(null) == null, "actual proposal worker reaches typed failure: " + error.GetType().Name);
                UpdateNotificationUi.Clear(); Plugin.Automatic.ProposalWorker = null;
            }
            Fail(new UpdateValidationException(UpdateFailure.InvalidSignature));
            Fail(new UpdateValidationException(UpdateFailure.WrongTarget));
            Fail(new UpdateValidationException(UpdateFailure.InvalidDescriptor));
            Fail(new ApplySafetyException(7, 32));
            Fail(new InvalidOperationException("FAKE_UI_PRIVATE_MESSAGE\ntoken=FAKE_UI_PRIVATE_DATA"));
            var changed = new TaskCompletionSource<ChannelTransitionProposal>(TaskCreationOptions.RunContinuationsAsynchronously);
            Plugin.Automatic.ProposalWorker = changed;
            UpdateNotificationUi.BeginTransition();
            inject(Plugin.Updates.Result with { Release = Plugin.Updates.Result.Release! with { SignatureAssetId = 999 } });
            frame(null); Check(pending.GetValue(null) == null, "actual stale target emits refusal before approving");
            changed.SetResult(new(new("fixture", "Stable", "2.0.0", new string('A', 64))));
            UpdateNotificationUi.Clear(); Plugin.Automatic.ProposalWorker = null;
            Check(owner.Stop(DiagnosticEndReason.OwnerDisposed, 2000), "actual channel typed writer drained");
            var bundle = DiagnosticBundle.Collect(root, "", "", "", Path.Combine(root, "hub"), Path.Combine(root, "fallback"), "8.0");
            var all = new StringBuilder(); var events = new List<JsonElement>();
            using (var zip = ZipFile.OpenRead(bundle.ArchivePath))
                foreach (var entry in zip.Entries)
                {
                    using var reader = new StreamReader(entry.Open()); var text = reader.ReadToEnd(); all.Append(text);
                    if (!entry.FullName.StartsWith("logs/game-minimal-", StringComparison.Ordinal)) continue;
                    foreach (var line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
                    { using var document = JsonDocument.Parse(line); events.Add(document.RootElement.Clone()); }
                }
            string Field(JsonElement e, string name) => e.GetProperty(name).GetString()!;
            var ui = events.Where(e => Field(e, "feature") == "Settings" && Field(e, "phase") == "UiAction").ToArray();
            Check(ui.Length > 0, "actual channel producer to actual ZIP includes Settings/UiAction events");
            foreach (var outcome in new[] { "Begin", "Completed", "Cancelled", "Unavailable" })
                Check(ui.Any(e => Field(e, "outcome") == outcome), "actual channel outcome survives ZIP: " + outcome);
            foreach (var code in new[] { "InvalidSignature", "WrongTarget", "Integrity", "Prerequisite" })
                Check(ui.Any(e => Field(e, "kind") == "Failure" && Field(e, "code") == code), "actual channel failure survives ZIP: " + code);
            foreach (var pair in new[] { ("InvalidSignature", 1), ("WrongTarget", 3), ("Integrity", 2) })
                Check(ui.Any(e => Field(e, "code") == pair.Item1 && e.GetProperty("validation_code").GetInt32() == pair.Item2), "validation distinctions retained: " + pair.Item1);
            Check(ui.Any(e => Field(e, "code") == "Prerequisite" && e.GetProperty("apply_code").GetInt32() == 7 && e.GetProperty("native_code").GetInt32() == 32), "channel safety apply/native codes retained");
            foreach (var end in new[] { "Completed", "Cancelled" })
            {
                var terminal = ui.First(e => Field(e, "outcome") == end);
                Check(ui.Any(e => Field(e, "outcome") == "Begin" && Field(e, "operation") == Field(terminal, "operation") && Field(e, "target_version") == Field(terminal, "target_version")), "same aliased operation and target retained: " + end);
            }
            Check(ui.All(e => Field(e, "operation") != "-" && Field(e, "target_version") == "2.0.0"), "new channel producer paths retain bounded target and operation");
            Check(!all.ToString().Contains("FAKE_UI_PRIVATE") && !all.ToString().Contains(owner.ProcessSession) && !all.ToString().Contains(root), "UI exception messages, Data, raw sessions and source paths absent in ZIP");
            var report = new { passed = true, checks = checks.Count, cases = checks, archive = bundle.ArchivePath, sourceLinkedUiAndWriterAndCollector = true, nativePolicyStubbed = true, actualGameSteamOrProductionKeysUsed = false };
            File.WriteAllText(Path.Combine(root, "test-results.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine("CHANNEL-DIAGNOSTICS " + JsonSerializer.Serialize(report));
        }
        finally { UpdateNotificationUi.Clear(); Plugin.Automatic.ProposalWorker = null; Plugin.Automatic.CanReviewTransition = false; owner.Stop(DiagnosticEndReason.OwnerDisposed, 2000); DiagnosticHub.Unbind(owner); }
    }
}
