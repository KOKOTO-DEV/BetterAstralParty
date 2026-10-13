using BetterAstralParty.Updating;
using System.Collections;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Globalization;
using System.Diagnostics;

// Inventory tests do not execute installers, helpers, games or Steam. Transactions/
// intents are structural fixtures, not proof that a signed update was applied.
// Helper provenance is separately verified with an ephemeral fixture RSA key.
internal static class HistoryInventoryFixture
{
    private enum Kind { Transaction, Helper, AutomaticHelper, WholeBridge, WholeIntent }
    private sealed record Case(string Name, bool Passed, string? Failure = null, long ElapsedMilliseconds = 0);
    private sealed record HelperRecord(string Work, string WorkId, string ImageId, string ReceiptId, byte[] Receipt);
    private sealed record HandoffRecord(UpdateTicket Ticket, byte[] Bytes, string? AttemptWork);
    private const BindingFlags Hidden = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;
    private static readonly string Digest = new('A', 64);
    private static readonly List<Case> Cases = new();
    private static string FixtureRoot = "";
    private static int Sequence, Assertions;
    private static RSA Key = null!;
    private static UpdateTrust Trust = null!;
    private static byte[] Image = null!, Descriptor = null!, Signature = null!;
    private static byte[] PublicDescriptor = null!, PublicSignature = null!;
    private static DetachedSignature PublicEnvelope = null!;
    private static UpdateContext PublicContext = null!;
    private static string PublicProofRoot = "", PublicDescriptorHash = "";

    public static int Main(string[] args)
    {
        try
        {
            if (args.Length != 3 || !OperatingSystem.IsWindows()) throw new InvalidOperationException("Windows fixture root, artifact root and readonly public remote proof root required.");
            FixtureRoot = Path.GetFullPath(args[0]).TrimEnd(Path.DirectorySeparatorChar);
            var artifacts = Path.GetFullPath(args[1]).TrimEnd(Path.DirectorySeparatorChar);
            if (!FixtureRoot.StartsWith(artifacts + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                || Directory.Exists(FixtureRoot) || FixtureRoot.Length > 135)
                throw new InvalidOperationException("Fresh, short, isolated artifact descendant required.");
            Directory.CreateDirectory(FixtureRoot);
            PublicProofRoot = Path.GetFullPath(args[2]).TrimEnd(Path.DirectorySeparatorChar);
            if (!PublicProofRoot.StartsWith(Path.GetDirectoryName(artifacts)! + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                || PublicProofRoot.StartsWith(FixtureRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Public proof must be a readonly selected-project path outside the fresh fixture.");
            PublicDescriptor = File.ReadAllBytes(Path.Combine(PublicProofRoot, "update.descriptor"));
            PublicSignature = File.ReadAllBytes(Path.Combine(PublicProofRoot, "update.signature"));
            if (PublicDescriptor.Length > UpdateTrust.MaxDescriptorBytes || PublicSignature.Length > 1024) throw new InvalidOperationException("Public proof bounds exceeded.");
            var publicLines = Encoding.ASCII.GetString(PublicDescriptor).Split('\n');
            if (publicLines.Length < 15 || publicLines[0] != "BetterAstralParty.UpdateDescriptor/v3") throw new InvalidOperationException("A signed baseline RemoteUpdate proof, not a LocalInstall or legacy proof, is required.");
            PublicEnvelope = DetachedSignature.Parse(PublicSignature);
            PublicContext = new UpdateContext(publicLines[1][11..], publicLines[3][8..], "1.2.1-0", publicLines[2][8..],
                long.Parse(publicLines[5][11..], CultureInfo.InvariantCulture), long.Parse(publicLines[6][9..], CultureInfo.InvariantCulture), UpdateTrust.PlatformId,
                repositoryId: long.Parse(publicLines[12][14..], CultureInfo.InvariantCulture));
            var publicVerified = UpdateTrust.Production().VerifyDescriptor(PublicDescriptor, PublicEnvelope.KeyId, PublicEnvelope.Signature, PublicContext);
            PublicDescriptorHash = publicVerified.DescriptorSha256;
            using var key = RSA.Create(3072); Key = key;
            Trust = new UpdateTrust(new[] { new TrustedUpdateKey("maintenance-history-fixture", Key.ExportParameters(false)) });
            Image = new byte[512]; Image[0] = 77; Image[1] = 90;
            BitConverter.GetBytes(128).CopyTo(Image, 60); Image[128] = 80; Image[129] = 69;
            BitConverter.GetBytes((ushort)0x8664).CopyTo(Image, 132);
            Descriptor = HelperDescriptor.Prepare("1.2.1", Image, 3);
            Signature = new DetachedSignature("maintenance-history-fixture", Key.SignData(Descriptor, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)).Bytes();
            // Fail fast if the fixture's ephemeral signature ever diverges from the
            // product verifier, instead of misreporting that setup error as a regression.
            HelperDescriptor.Verify(Trust, Descriptor, DetachedSignature.Parse(Signature), Image);
            foreach (var kind in Enum.GetValues<Kind>())
            {
                CheckCase(kind + ":retained-completed-over-old-limit", () => CompletedInventory(kind));
                CheckCase(kind + ":terminal-marker-tamper-rejected", () => MarkerTamper(kind));
                CheckCase(kind + ":completed-native-root-mismatch-rejected", () => WrongRoot(kind));
            }
            CheckCase("Transaction:mixed-completed-and-pending", MixedTransaction);
            CheckCase("Helper:mixed-completed-and-pending", MixedHelper);
            CheckCase("Transaction:257-completed-payload-stages-and-exact-active-handoff", RetainedStageDiscovery);
            foreach (var kind in new[] { Kind.Transaction, Kind.Helper, Kind.AutomaticHelper })
                CheckCase(kind + ":pre-journal-empty-active-over-limit-rejected", () => EmptyActive(kind));
            CheckCase("Transaction:committed-and-rolled-back-conflict-rejected", TransactionConflict);
            CheckCase("WholeIntent:committed-and-cancelled-conflict-rejected", WholeConflict);
            CheckCase("Helper:retained-65-live-and-removed-signed-provenance", HelperProvenance);
            foreach (var terminal in new[] { "Committed", "Recovered", "Cancelled", "FaultDisabled", "FaultDisabledNoChanges" })
                CheckCase("SignedTerminal:" + terminal + ":exact-proof-retired", () => SignedTerminalPositive(terminal));
            foreach (var fault in new[] { "result-hash", "attempt-binding", "signature", "descriptor-binding", "unfinished-attempt", "resolution", "missing-resolution" })
                CheckCase("SignedTerminal:" + fault + ":not-retired", () => SignedTerminalNegative(fault));
            CheckCase("SignedTerminal:257-retained-mixed-terminal-handoffs-and-one-active", SignedTerminalDiscovery);
            var passed = Cases.All(test => test.Passed);
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                Passed = passed, Assertions, Cases, Runtime = Environment.Version.ToString(), FixtureRoot,
                NoGameOrSteamExecution = true, NoNetworkRequests = true, EphemeralFixtureKeyOnly = true,
                StructuralInventoryNotSignedUpdateExecution = true,
                ExistingEvidencePathsPreserved = true,
                PublicRemoteProof = new { Path = PublicProofRoot, DescriptorSha256 = PublicDescriptorHash, SignatureSha256 = UpdateTrust.Hash(PublicSignature), PublicContext.Repository, PublicContext.RepositoryId, PublicContext.ReleaseTag, PublicContext.ReleaseId, PublicContext.AssetId, KeyId = PublicEnvelope.KeyId },
                Scope = "Canonical inventory/native ID/terminal marker tests; separately ephemeral-signed helper provenance and protocol3 RemoteUpdate terminal classification. Default remote proof uses a compiled fixture-only public pin; an explicit public proof uses unchanged product pins. Terminal journals/tickets are structural simulations, not successful signed update executions. No helper/installer process execution, live game root, operating signing key or network."
            }));
            return passed ? 0 : 1;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 2; }
    }

    private static void Check(bool value, string message)
    { Assertions++; if (!value) throw new InvalidOperationException(message); }
    private static void CheckCase(string name, Action body)
    {
        var timer = Stopwatch.StartNew();
        try { body(); Cases.Add(new Case(name, true, ElapsedMilliseconds: timer.ElapsedMilliseconds)); }
        catch (Exception error) { Cases.Add(new Case(name, false, error.GetType().Name + ": " + error.Message, timer.ElapsedMilliseconds)); }
        Console.WriteLine((Cases[^1].Passed ? "PASS " : "FAIL ") + Cases.Count + ": " + name + " (" + timer.ElapsedMilliseconds + " ms)");
    }
    private static WindowsFileFence Fresh()
    {
        var root = Path.Combine(FixtureRoot, (++Sequence).ToString("D2")); Directory.CreateDirectory(root);
        return new WindowsFileFence(root);
    }
    private static byte[] Bytes(string text) => Encoding.ASCII.GetBytes(text);
    private static void Write(WindowsFileFence fence, string path, byte[] bytes)
    { using var file = fence.OpenFile(path, true, true); file.Stream.Write(bytes); file.Flush(); }
    private static void Replace(WindowsFileFence fence, string path, byte[] bytes)
    { using var file = fence.OpenFile(path, true); file.Stream.SetLength(0); file.Stream.Write(bytes); file.Flush(); }
    private static string Id(WindowsFileFence fence, string path)
    { using var file = fence.OpenFile(path); return file.Identity.Text; }
    private static byte[] Read(WindowsFileFence fence, string path)
    { using var file = fence.OpenFile(path); return UpdateTicket.Read(file, 16384); }
    private static string Private(WindowsFileFence fence, string prefix)
    { var path = prefix + Guid.NewGuid().ToString("N"); fence.CreatePrivateDirectory(path); return path; }
    private static void Terminal(WindowsFileFence fence, string work, byte[] plan, string marker)
    { Write(fence, work + "/" + marker, Bytes(UpdateTrust.Hash(plan) + "\n")); }
    private static object? Invoke(Type type, string method, WindowsFileFence fence)
    {
        try { return type.GetMethod(method, Hidden)!.Invoke(null, new object[] { fence }); }
        catch (TargetInvocationException error) when (error.InnerException != null)
        { ExceptionDispatchInfo.Capture(error.InnerException).Throw(); throw; }
    }
    private static int Pending(Kind kind, WindowsFileFence fence)
        => kind switch
        {
            Kind.Transaction => UpdateRecovery.Scan(fence).Count(entry => entry.Pending),
            Kind.Helper => HelperDelivery.PendingInstall(fence) ? 1 : 0,
            Kind.AutomaticHelper => ((ICollection)Invoke(typeof(AutomaticHelperUpgrade), "Scan", fence)!).Count,
            Kind.WholeBridge => ((ICollection)Invoke(typeof(WholeInstallBridge), "Scan", fence)!).Count,
            _ => ((ICollection)Invoke(typeof(WholeInstallBridge), "ScanIntents", fence)!).Count
        };
    private static void Recovery(Action body)
    {
        Assertions++;
        try { body(); }
        catch (ApplySafetyException error) when (error.Failure == ApplyFailure.RecoveryRequired) { return; }
        throw new InvalidOperationException("Expected RecoveryRequired, but the unsafe evidence was accepted.");
    }
    private static HelperRecord AddHelper(WindowsFileFence f, bool completed = true, bool wrongRoot = false)
    {
        var work = Private(f, "bap-v3-helper-"); var workId = f.DirectoryIdentity(work).Text;
        Write(f, work + "/image", Image); var imageId = Id(f, work + "/image");
        var receipt = Bytes("BetterAstralParty.HelperReceipt/v1\nroot=" + f.RootIdentity.Text + "\nimage-id=" + imageId
            + "\nversion=1.2.1\nsha256=" + UpdateTrust.Hash(Image) + "\ndescriptor=" + UpdateTrust.Hash(Descriptor) + "\nkey-id=maintenance-history-fixture\n");
        Write(f, work + "/receipt", receipt); var receiptId = Id(f, work + "/receipt");
        Write(f, work + "/descriptor", Descriptor); Write(f, work + "/signature", Signature);
        var plan = Bytes("BetterAstralParty.HelperInstall/v1\nroot=" + (wrongRoot ? "00000000:0000000000000000" : f.RootIdentity.Text)
            + "\nwork=" + work + "\nwork-id=" + workId + "\ndescriptor=" + UpdateTrust.Hash(Descriptor)
            + "\nimage-id=" + imageId + "\nreceipt-id=" + receiptId + "\n");
        Write(f, work + "/plan", plan); if (completed) Terminal(f, work, plan, "committed");
        return new HelperRecord(work, workId, imageId, receiptId, receipt);
    }
    private static string AddRecord(WindowsFileFence f, Kind kind, bool completed = true, bool wrongRoot = false, bool cancelled = false, string? descriptorHash = null)
    {
        if (kind == Kind.Helper) return AddHelper(f, completed, wrongRoot).Work;
        var prefix = kind switch { Kind.Transaction => "bap-v3-txn-", Kind.AutomaticHelper => "bap-v3-helperauto-", Kind.WholeBridge => "bap-v3-helperbridge-", _ => "bap-v3-wholeintent-" };
        var work = Private(f, prefix); var workId = f.DirectoryIdentity(work).Text;
        var root = wrongRoot ? "00000000:0000000000000000" : f.RootIdentity.Text;
        string plan;
        if (kind == Kind.Transaction)
        {
            var stage = Private(f, "bap-v3-stage-");
            var text = new StringBuilder("BetterAstralParty.Transaction/v3\nroot=" + root + "\nwork=" + work + "\nwork-id=" + workId
                + "\nstage=" + stage + "\nstage-id=" + f.DirectoryIdentity(stage).Text + "\ndescriptor=" + (descriptorHash ?? Digest)
                + "\noriginal=" + (descriptorHash == null ? "1.2.1" : PublicContext.CurrentVersion) + "\ncount=10\n");
            foreach (var path in InstallReceipt.Owned.Concat(new[] { InstallReceipt.Path, UpdateTransaction.HighWaterPath }))
                text.Append("file=").Append(path).Append("\t-\t-\t").Append(f.RootIdentity.Text).Append('\t').Append(Digest).Append('\n');
            plan = text.Append("settings=-\t-\n").ToString();
        }
        else if (kind == Kind.WholeIntent)
        {
            var observation = "BetterAstralParty.WholeObservation/v1\nroot=" + root + "\nplugin=-\nreceipt=-\nimage=-\t-\nhelper-receipt=-\t-\nwater=-\t-\nupdate="
                + Digest + "\nhelper=" + Digest + "\nmode=Fresh\nnonce=00000000000000000000000000000000\n";
            plan = "BetterAstralParty.WholeInstallIntent/v1\nroot=" + root + "\nwork=" + work + "\nwork-id=" + workId
                + "\nobservation=" + Convert.ToBase64String(Bytes(observation)) + "\ntarget-receipt=" + Digest + "\nold-plugin=-\t-\nold-receipt=-\t-\n";
        }
        else
        {
            var helper = AddHelper(f); var slot = f.RootIdentity.Text + "\t" + Digest;
            if (kind == Kind.AutomaticHelper)
                plan = "BetterAstralParty.AutomaticHelper/v1\nroot=" + root + "\nwork=" + work + "\nwork-id=" + workId
                    + "\nhelper-work=" + helper.Work + "\nhelper-id=" + helper.WorkId + "\ndescriptor=" + UpdateTrust.Hash(Descriptor)
                    + "\nreceipt=" + slot + "\nwater=-\t-\nold-image=" + slot + "\nold-receipt=" + slot + "\n";
            else
                plan = "BetterAstralParty.WholeHelperMigration/v1\nroot=" + root + "\nwork=" + work + "\nwork-id=" + workId
                    + "\nhelper-work=" + helper.Work + "\nhelper-work-id=" + helper.WorkId + "\nupdate=" + Digest + "\nhelper=" + UpdateTrust.Hash(Descriptor)
                    + "\nreceipt=" + Digest + "\nwater=-\t-\nold-image=-\t-\nold-receipt=-\t-\nnew-image=" + helper.ImageId + "\t" + UpdateTrust.Hash(Image)
                    + "\nnew-receipt=" + helper.ReceiptId + "\t" + UpdateTrust.Hash(helper.Receipt) + "\n";
        }
        var bytes = Bytes(plan); Write(f, work + "/plan", bytes);
        if (completed)
        {
            if (kind == Kind.Transaction) Terminal(f, work, bytes, "commit-intent");
            Terminal(f, work, bytes, cancelled ? "cancelled" : "committed");
        }
        return work;
    }
    private static void CompletedInventory(Kind kind)
    {
        using var f = Fresh(); var count = kind == Kind.Transaction ? 129 : 65;
        for (var i = 0; i < count; i++) AddRecord(f, kind, cancelled: kind == Kind.WholeIntent && i % 2 == 0);
        Check(Pending(kind, f) == 0, "Completed histories must not consume active recovery quota.");
        if (kind == Kind.Transaction) Check(UpdateRecovery.Scan(f).Count == count, "All completed transaction evidence remains discoverable.");
        UpdateLaunchGate.Check(f); Assertions++;
    }
    private static void MarkerTamper(Kind kind)
    {
        using var f = Fresh(); var work = AddRecord(f, kind);
        Replace(f, work + "/committed", Bytes(new string('B', 64) + "\n"));
        Recovery(() => Pending(kind, f)); Recovery(() => UpdateLaunchGate.Check(f));
    }
    private static void WrongRoot(Kind kind)
    {
        using var f = Fresh(); AddRecord(f, kind, wrongRoot: true);
        Recovery(() => Pending(kind, f));
    }
    private static void MixedTransaction()
    {
        using var f = Fresh(); for (var i = 0; i < 129; i++) AddRecord(f, Kind.Transaction);
        AddRecord(f, Kind.Transaction, completed: false);
        Check(Pending(Kind.Transaction, f) == 1, "Only unfinished transaction consumes active quota.");
        Recovery(() => UpdateLaunchGate.Check(f));
    }
    private static void EmptyActive(Kind kind)
    {
        using var f = Fresh(); var prefix = kind switch { Kind.Transaction => "bap-v3-txn-", Kind.Helper => "bap-v3-helper-", _ => "bap-v3-helperauto-" };
        for (var i = 0; i < (kind == Kind.Transaction ? 129 : 65); i++) Private(f, prefix);
        Recovery(() => Pending(kind, f));
    }
    private static void MixedHelper()
    {
        using var f = Fresh(); for (var i = 0; i < 65; i++) AddHelper(f);
        AddHelper(f, completed: false);
        Check(HelperDelivery.PendingInstall(f), "Completed helper history must not prevent discovering one exact pending helper plan.");
        Recovery(() => UpdateLaunchGate.Check(f));
    }
    private static void RetainedStageDiscovery()
    {
        using var f = Fresh(); for (var i = 0; i < 257; i++) AddRecord(f, Kind.Transaction);
        var pendingWork = AddRecord(f, Kind.Transaction, completed: false);
        var stage = Private(f, "bap-v3-stage-"); var feed = ReleaseFeedPolicy.For("Stable");
        var ticket = new UpdateTicket
        {
            RootId = f.RootIdentity.Text, Stage = stage, StageId = f.DirectoryIdentity(stage).Text, DescriptorHash = Digest,
            Context = new UpdateContext(feed.Repository, "Stable", "1.1.3", "1.1.4", 1, 2, UpdateTrust.PlatformId, repositoryId: feed.RepositoryId),
            GamePid = 1, GameCreation = 1
        };
        var bytes = ticket.Bytes(); Write(f, stage + "/handoff.ticket", bytes);
        Write(f, stage + "/helper.attempt", HelperRecoveryBinding.Attempt(UpdateTrust.Hash(bytes), pendingWork));
        Check(UpdateRecovery.PendingTicket(f) == stage, "257 retained completed payload stages must not consume active handoff discovery quota.");
        Recovery(() => UpdateLaunchGate.Check(f));
    }
    private static void TransactionConflict()
    {
        using var f = Fresh(); var work = AddRecord(f, Kind.Transaction);
        Terminal(f, work, Read(f, work + "/plan"), "rolled-back"); Recovery(() => UpdateRecovery.Scan(f));
    }
    private static void WholeConflict()
    {
        using var f = Fresh(); var work = AddRecord(f, Kind.WholeIntent);
        Terminal(f, work, Read(f, work + "/plan"), "cancelled"); Recovery(() => Pending(Kind.WholeIntent, f));
    }
    private static void HelperProvenance()
    {
        using var f = Fresh(); var history = new List<HelperRecord>();
        for (var i = 0; i < 65; i++) history.Add(AddHelper(f));
        var latest = history[^1];
        using (var file = f.OpenFile(latest.Work + "/image", true)) { file.RenameTo(f, HelperDescriptor.Image); file.Flush(); }
        using (var file = f.OpenFile(latest.Work + "/receipt", true)) { file.RenameTo(f, HelperDelivery.Receipt); file.Flush(); }
        Check(HelperDelivery.Fingerprint(f, Trust, 3) == UpdateTrust.Hash(Image), "Live helper authenticates its exact retained journal beyond old cap.");
        var removed = HelperDelivery.RemovedEvidence(f, Trust, Image, history[0].Receipt);
        Check(removed.Contains(history[0].Work + "/plan=", StringComparison.Ordinal), "Removed helper copy authenticates exactly its original retained signed evidence.");
        UpdateLaunchGate.Check(f); Assertions++;
        Replace(f, latest.Work + "/signature", Bytes("invalid signature envelope\n"));
        Assertions++;
        try { HelperDelivery.Fingerprint(f, Trust, 3); }
        catch (UpdateValidationException error) when (error.Failure == UpdateFailure.InvalidSignature) { return; }
        throw new InvalidOperationException("Malformed signature must still reject the exact live helper provenance.");
    }
    private static HandoffRecord SignedHandoff(WindowsFileFence f, string terminal, bool pendingAttempt = false, bool wrongDescriptor = false, string? retainedWork = null)
    {
        var digest = wrongDescriptor ? Digest : PublicDescriptorHash;
        var noAttempt = terminal is "Cancelled" or "FaultDisabledNoChanges";
        var work = noAttempt ? null : retainedWork ?? AddRecord(f, Kind.Transaction, completed: terminal != "FaultDisabled" && !pendingAttempt, descriptorHash: digest);
        if (work != null && terminal == "FaultDisabled" && retainedWork == null)
            Terminal(f, work, Read(f, work + "/plan"), "rolled-back");
        var stage = Private(f, "bap-v3-stage-");
        var ticket = new UpdateTicket { RootId = f.RootIdentity.Text, Stage = stage, StageId = f.DirectoryIdentity(stage).Text, DescriptorHash = digest,
            Context = PublicContext, GamePid = 1, GameCreation = 1 };
        var bytes = ticket.Bytes(); var hash = UpdateTrust.Hash(bytes);
        Write(f, stage + "/handoff.ticket", bytes);
        if (work != null) Write(f, stage + "/helper.attempt", HelperRecoveryBinding.Attempt(hash, work));
        Write(f, stage + "/helper.result", Bytes(hash + "\n" + (terminal == "FaultDisabledNoChanges" ? "FaultDisabled" : terminal) + "\n"));
        if (terminal is "FaultDisabled" or "FaultDisabledNoChanges") Write(f, stage + "/helper.recovery", HelperRecoveryBinding.Resolution(hash, work,
            work == null ? RecoveryOutcome.NoChanges : RecoveryOutcome.OriginalRestored));
        Write(f, stage + "/descriptor.bin", PublicDescriptor); Write(f, stage + "/signature.bin", PublicEnvelope.Signature);
        Write(f, stage + "/key-id.bin", Bytes(PublicEnvelope.KeyId));
        return new HandoffRecord(ticket, bytes, work);
    }
    private static bool Retired(WindowsFileFence f, HandoffRecord handoff)
    {
        var entries = UpdateRecovery.Scan(f); handoff.Ticket.Recheck(f);
        var method = typeof(UpdateRecovery).GetMethod("RetiredTicket", Hidden)
            ?? throw new InvalidOperationException("The production read-only terminal classification kernel is not yet present.");
        try { return (bool)method.Invoke(null, new object[] { f, handoff.Ticket, handoff.Bytes, entries })!; }
        catch (TargetInvocationException error) when (error.InnerException != null)
        { ExceptionDispatchInfo.Capture(error.InnerException).Throw(); throw; }
    }
    private static void SignedTerminalPositive(string terminal)
    {
        using var f = Fresh(); var handoff = SignedHandoff(f, terminal);
        Check(Retired(f, handoff), "Exact public-signed terminal proof must retire only the finished/no-change handoff inventory.");
    }
    private static void SignedTerminalNegative(string fault)
    {
        using var f = Fresh(); var handoff = SignedHandoff(f, fault is "resolution" or "missing-resolution" ? "FaultDisabled" : "Committed",
            pendingAttempt: fault == "unfinished-attempt", wrongDescriptor: fault == "descriptor-binding");
        var stage = handoff.Ticket.Stage;
        switch (fault)
        {
            case "result-hash": Replace(f, stage + "/helper.result", Bytes(Digest + "\nCommitted\n")); break;
            case "attempt-binding": Replace(f, stage + "/helper.attempt", HelperRecoveryBinding.Attempt(UpdateTrust.Hash(handoff.Bytes), "bap-v3-txn-" + Guid.NewGuid().ToString("N"))); break;
            case "signature": var corrupted = (byte[])PublicEnvelope.Signature.Clone(); corrupted[0] ^= 1; Replace(f, stage + "/signature.bin", corrupted); break;
            case "resolution": Replace(f, stage + "/helper.recovery", HelperRecoveryBinding.Resolution(UpdateTrust.Hash(handoff.Bytes), handoff.AttemptWork, RecoveryOutcome.TargetCompleted)); break;
            case "missing-resolution":
                // Rename only this fresh fixture-owned evidence file by a native handle;
                // no real installation, retained user file or directory is touched.
                using (var file = f.OpenFile(stage + "/helper.recovery", true)) { file.RenameTo(f, stage + "/fixture-resolution-withheld"); file.Flush(); } break;
        }
        try { Check(!Retired(f, handoff), "Unverified/unresolved handoff evidence must remain an active candidate."); }
        catch (ApplySafetyException error) when (fault == "missing-resolution" && error.NativeError == 2)
        { Assertions++; } // PendingTicket must classify this unretired candidate, not infer completion.
    }
    private static void SignedTerminalDiscovery()
    {
        using var f = Fresh(); string? committed = null, rolled = null;
        var terminals = new[] { "Committed", "Recovered", "Cancelled", "FaultDisabled", "FaultDisabledNoChanges" };
        for (var i = 0; i < 257; i++)
        {
            var terminal = terminals[i % terminals.Length];
            var handoff = SignedHandoff(f, terminal, retainedWork: terminal == "FaultDisabled" ? rolled : terminal is "Committed" or "Recovered" ? committed : null);
            if (terminal == "FaultDisabled") rolled ??= handoff.AttemptWork;
            else if (terminal is "Committed" or "Recovered") committed ??= handoff.AttemptWork;
        }
        var pending = AddRecord(f, Kind.Transaction, completed: false, descriptorHash: PublicDescriptorHash);
        var stage = Private(f, "bap-v3-stage-");
        var ticket = new UpdateTicket { RootId = f.RootIdentity.Text, Stage = stage, StageId = f.DirectoryIdentity(stage).Text,
            DescriptorHash = PublicDescriptorHash, Context = PublicContext, GamePid = 1, GameCreation = 1 };
        var bytes = ticket.Bytes(); Write(f, stage + "/handoff.ticket", bytes);
        Write(f, stage + "/helper.attempt", HelperRecoveryBinding.Attempt(UpdateTrust.Hash(bytes), pending));
        Check(UpdateRecovery.PendingTicket(f) == stage, "257 signed terminal handoff histories must not consume the active discovery quota.");
        Recovery(() => UpdateLaunchGate.Check(f));
    }
}
