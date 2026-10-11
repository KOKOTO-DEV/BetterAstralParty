using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using BetterAstralParty.Updating;

// Metadata-only plugin fixture; its installed copy and all PE images are never executed.
namespace BetterAstralParty {
    internal static class Plugin {
        public const string Guid = "kr.betterastralparty.mod", Version = "1.0.0", UpdateProtocol = "2", SettingsSchema = "1";
    }
}

internal static class Program {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLinkW(string link, string existing, IntPtr security);
    private sealed class Interrupted : Exception { internal Interrupted(string point) : base(point) { } }
    private sealed class Payload : IDisposable {
        private readonly RSA _key = RSA.Create(3072);
        private readonly Dictionary<string, byte[]> _signatures = new(StringComparer.Ordinal);
        internal readonly UpdateTrust Trust;
        internal Payload() { Trust = new UpdateTrust(new[] { new TrustedUpdateKey("automatic-helper-fixture", _key.ExportParameters(false)) }); }
        internal byte[] Signature(byte[] descriptor) {
            var hash = UpdateTrust.Hash(descriptor);
            if (!_signatures.TryGetValue(hash, out var bytes)) {
                bytes = new DetachedSignature("automatic-helper-fixture", _key.SignData(descriptor, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)).Bytes();
                _signatures.Add(hash, bytes);
            }
            return (byte[])bytes.Clone();
        }
        public void Dispose() => _key.Dispose();
    }
    private sealed record Snapshot(Dictionary<string, string> Hashes, Dictionary<string, string> Identities);
    private sealed record CaseResult(string Name, string Root, int Assertions, string[] Boundaries);
    private static readonly List<CaseResult> Results = new();
    private static string _root = "";
    private static int _assertions, _roots;
    private static byte[] Bytes(string text) => Encoding.ASCII.GetBytes(text);
    private static void Check(bool value, string name) { if (!value) throw new Exception(name); _assertions++; }
    private static string Full(string root, string relative) => Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
    private static byte[] Image(byte marker) {
        var image = new byte[512]; image[0] = 77; image[1] = 90;
        BitConverter.GetBytes(128).CopyTo(image, 60); image[128] = 80; image[129] = 69;
        BitConverter.GetBytes((ushort)0x8664).CopyTo(image, 132); image[511] = marker;
        HelperDescriptor.Executable(image); return image;
    }
    private static string Seed(Payload payload, string version = "1.0.0", int protocol = 1, byte marker = 1,
        bool channels = true, bool water = true, Action<string>? installBoundary = null) {
        var root = Path.Combine(_root, "c" + (++_roots));
        if (Directory.Exists(root)) throw new IOException("Fresh scratch root required");
        Directory.CreateDirectory(Full(root, "BepInEx/plugins/BetterAstralParty"));
        Directory.CreateDirectory(Full(root, "BepInEx/plugins/OtherMod"));
        Directory.CreateDirectory(Full(root, "BepInEx/config"));
        var plugin = File.ReadAllBytes(Assembly.GetExecutingAssembly().Location);
        Check(InstalledPluginMetadata.Read(plugin).Version == "1.0.0", "fixture plugin metadata is authentic");
        var owned = InstallReceipt.Owned.ToDictionary(path => path, path => path == UpdateTrust.PluginPath ? plugin : path == "BetterAstralParty-Launcher.exe" ? Image(9) : Bytes("owned fixture: " + path));
        foreach (var file in owned) File.WriteAllBytes(Full(root, file.Key), file.Value);
        File.WriteAllBytes(Full(root, "AstralParty_INT.exe"), Image(10));
        File.WriteAllBytes(Full(root, "doorstop_config.ini"), Bytes("[General]\r\nenabled=false\r\ncustom=untouched\r\n"));
        File.WriteAllBytes(Full(root, "BepInEx/config/kr.betterastralparty.mod.cfg"), Bytes("user preferences remain byte-exact"));
        File.WriteAllBytes(Full(root, "BepInEx/plugins/OtherMod/OtherMod.dll"), Bytes("other plugin remains byte-exact"));
        File.WriteAllBytes(Full(root, "BepInEx/config/OtherMod.cfg"), Bytes("other configuration remains byte-exact"));
        File.WriteAllBytes(Full(root, "retained-install-backup.keep"), Bytes("retained backup remains byte-exact"));
        using (var fence = new WindowsFileFence(root)) {
            var history = new ReceiptChannelState(fence.RootIdentity.Text, "Stable", Guid.NewGuid().ToString("N"), ReleaseFeedPolicy.StableRepositoryId, "1.0.0", new string('A', 64), ReleaseFeedPolicy.BetaRepositoryId, "1.0.0-rc.6", new string('B', 64));
            var receipt = "{\"schema\":1,\"owner\":\"kr.betterastralparty.mod\",\"loaderBefore\":false,\"files\":[" + string.Join(",", owned.Select(file => "{\"path\":\"" + file.Key + "\",\"sha256\":\"" + UpdateTrust.Hash(file.Value) + "\"}")) + "]" + (channels ? ",\"channelState\":\"" + history.Encoded + "\"" : "") + "}";
            File.WriteAllBytes(Full(root, InstallReceipt.Path), Bytes(receipt));
            if (water) File.WriteAllBytes(Full(root, UpdateTransaction.HighWaterPath), Bytes("BetterAstralParty.HighWater/v1\nroot=" + fence.RootIdentity.Text + "\nversion=1.0.0\ndescriptor=" + new string('C', 64) + "\n"));
            var image = Image(marker); var descriptor = HelperDescriptor.Prepare(version, image, protocol);
            Check(HelperDelivery.Install(fence, descriptor, payload.Signature(descriptor), image, payload.Trust, installBoundary) == HelperInstallResult.Installed, "authentic old helper delivery committed");
            Check(HelperDelivery.Fingerprint(fence, payload.Trust) == UpdateTrust.Hash(image), "old signed fingerprint verified");
        }
        return root;
    }
    private static Snapshot Capture(string root) {
        var hashes = new Dictionary<string, string>(StringComparer.Ordinal);
        var identities = new Dictionary<string, string>(StringComparer.Ordinal);
        using var fence = new WindowsFileFence(root);
        foreach (var full in Directory.GetFiles(root, "*", SearchOption.AllDirectories)) {
            var path = Path.GetRelativePath(root, full).Replace('\\', '/');
            using var file = fence.OpenFile(path); hashes.Add(path, file.Hash()); identities.Add(path, file.Identity.Text);
        }
        return new Snapshot(hashes, identities);
    }
    private static void Preserved(string root, Snapshot before, bool helperMayMove = true) {
        using var fence = new WindowsFileFence(root);
        foreach (var item in before.Hashes) {
            if (helperMayMove && (item.Key == HelperDescriptor.Image || item.Key == HelperDelivery.Receipt)) continue;
            using var file = fence.OpenFile(item.Key);
            Check(file.Hash() == item.Value, "retained bytes preserved " + item.Key);
            Check(file.Identity.Text == before.Identities[item.Key], "retained object identity preserved " + item.Key);
        }
    }
    private static void Run(string root, Payload payload, byte[]? image = null, string version = "1.1.0", int protocol = 2,
        Action<string>? boundary = null, Action<string>? native = null, byte[]? signature = null) {
        image ??= Image(2); var descriptor = HelperDescriptor.Prepare(version, image, protocol);
        using var lease = new UpdateLaunchGate.Lease(root, fence => {
            if (native == null) AutomaticHelperUpgrade.Ensure(fence, descriptor, signature ?? payload.Signature(descriptor), image, payload.Trust, boundary);
            else using (var faultFence = new WindowsFileFence(root, native)) AutomaticHelperUpgrade.Ensure(faultFence, descriptor, signature ?? payload.Signature(descriptor), image, payload.Trust, boundary);
        });
        using var secondFence = new WindowsFileFence(root);
        lease.Recheck(secondFence);
        try { using var conflicting = new UpdateLaunchGate.Lease(root); throw new Exception("operation lease was released too soon"); }
        catch (ApplySafetyException error) { Check(error.Failure == ApplyFailure.FileBusy, "retained native operation lease remains exclusive"); }
    }
    private static void VerifyUpgraded(string root, Payload payload, Snapshot before) {
        Preserved(root, before);
        using (var fence = new WindowsFileFence(root)) {
            Check(HelperDelivery.Fingerprint(fence, payload.Trust, 2) == UpdateTrust.Hash(Image(2)), "new signed protocol2 helper authenticated");
            Check(!AutomaticHelperUpgrade.Pending(fence) && !HelperDelivery.PendingInstall(fence), "both durable journals committed");
            UpdateLaunchGate.Check(fence); Check(true, "ordinary launch check accepts recovered state");
            var archive = Directory.GetDirectories(root, "bap-helperauto-*").Single(path => File.Exists(Path.Combine(path, "committed")));
            foreach (var pair in new[] { (HelperDescriptor.Image, "old-image"), (HelperDelivery.Receipt, "old-receipt") }) {
                using var old = fence.OpenFile(Path.GetFileName(archive) + "/" + pair.Item2);
                Check(old.Hash() == before.Hashes[pair.Item1], "exact old helper archive retained " + pair.Item2);
                Check(old.Identity.Text == before.Identities[pair.Item1], "old helper archive original identity retained " + pair.Item2);
            }
        }
        var committed = Capture(root); Run(root, payload); Preserved(root, committed, false);
        var repeated = Capture(root);
        Check(repeated.Hashes.Count == committed.Hashes.Count && repeated.Hashes.All(item => committed.Hashes[item.Key] == item.Value), "idempotence creates no files and changes no bytes");
    }
    private static void Case(string name, Action<List<string>> action) {
        var start = _assertions; var roots = _roots; var boundaries = new List<string>();
        action(boundaries);
        Results.Add(new CaseResult(name, Path.Combine(_root, "c" + (roots + 1)), _assertions - start, boundaries.ToArray()));
        Console.WriteLine("PASS " + name + ": " + (_assertions - start) + " assertions");
    }
    private static void Reject(Action action, string label) {
        try { action(); } catch (ApplySafetyException) { Check(true, label); return; } catch (UpdateValidationException) { Check(true, label); return; }
        throw new Exception("Unsafe operation accepted: " + label);
    }
    private static void InterruptedAt(Action action, string point) {
        try { action(); } catch (Interrupted error) { Check(error.Message == point, "exact interruption hit " + point); return; }
        throw new Exception("Interruption not reached: " + point);
    }
    private static void Recoveries(Payload payload) {
        var points = new[] { "intent", "prepared:descriptor", "prepared:signature", "prepared:image", "prepared:receipt", "prepared:plan", "before:old-image", "after:old-image", "before:old-receipt", "after:old-receipt", "before:image", "after:image", "before:receipt", "after:receipt", "before:committed", "after:committed", "before:auto-committed", "after:auto-committed" };
        foreach (var point in points) Case("boundary " + point, observed => {
            var root = Seed(payload); var before = Capture(root);
            InterruptedAt(() => Run(root, payload, boundary: hit => { observed.Add(hit); if (hit == point) throw new Interrupted(point); }), point);
            Preserved(root, before);
            if (point != "after:auto-committed") Reject(() => { using var rejected = new UpdateLaunchGate.Lease(root); }, "unfinished migration blocks ordinary gate");
            Run(root, payload, boundary: observed.Add); VerifyUpgraded(root, payload, before);
        });
        // The atomic publisher and archive moves make twelve native rename operations.
        // Inject before each actual kernel rename, not merely around managed callbacks.
        for (var nth = 1; nth <= 12; nth++) {
            var index = nth;
            Case("native rename " + index, observed => {
                var root = Seed(payload); var before = Capture(root); var renames = 0;
                InterruptedAt(() => Run(root, payload, boundary: observed.Add, native: op => { if (op == "rename" && ++renames == index) throw new Interrupted("rename " + index); }), "rename " + index);
                Check(renames == index, "exact native rename count"); Preserved(root, before);
                var pending = Directory.GetFiles(root, "*-pending-*", SearchOption.AllDirectories).ToDictionary(path => path, path => UpdateTrust.Hash(File.ReadAllBytes(path)));
                if (index <= 6 || index >= 11) Check(pending.Count == 1, "interrupted atomic publication retains one whole temporary file");
                var managedCallbacks = new List<string>(); Run(root, payload, boundary: managedCallbacks.Add); observed.AddRange(managedCallbacks);
                foreach (var item in pending) Check(File.Exists(item.Key) && UpdateTrust.Hash(File.ReadAllBytes(item.Key)) == item.Value, "temporary interrupted evidence preserved");
                VerifyUpgraded(root, payload, before);
            });
        }
    }
    private static void Refusals(Payload payload) {
        var cases = new[] { "same-version-different-image", "signature-tamper", "image-tamper", "protocol-one", "unknown-helper", "unreceipted-helper", "owned8-tamper", "channel-root-mismatch", "highwater-tamper", "pending-reinstall", "pending-operation", "pending-helper", "pending-whole", "pending-transaction", "malformed-helper-directory", "excessive-helper-directories", "linked-helper", "linked-owned-plugin", "busy-helper", "busy-operation-lock" };
        foreach (var name in cases) Case(name, _ => {
            var root = Seed(payload, version: name == "same-version-different-image" ? "1.1.0" : "1.0.0");
            var image = Image(2); byte[]? signature = null; var protocol = name == "protocol-one" ? 1 : 2;
            FileStream? busy = null;
            switch (name) {
                case "signature-tamper": signature = payload.Signature(HelperDescriptor.Prepare("1.1.0", image, 2)); var envelope = DetachedSignature.Parse(signature); envelope.Signature[0] ^= 1; signature = new DetachedSignature(envelope.KeyId, envelope.Signature).Bytes(); break;
                case "image-tamper": signature = payload.Signature(HelperDescriptor.Prepare("1.1.0", Image(3), 2)); break;
                case "unknown-helper": File.WriteAllBytes(Full(root, HelperDescriptor.Image), Image(99)); break;
                case "unreceipted-helper": File.Move(Full(root, HelperDelivery.Receipt), Full(root, "unreceipted-backup.keep")); break;
                case "owned8-tamper": File.AppendAllText(Full(root, "AstralParty-Vanilla.cmd"), "tamper"); break;
                case "channel-root-mismatch": {
                    using var fence = new WindowsFileFence(root); var text = File.ReadAllText(Full(root, InstallReceipt.Path)); var receipt = InstallReceipt.Parse(Bytes(text));
                    var wrong = new ReceiptChannelState("00000000:0000000000000000", "Stable", receipt.Channels!.Operation, ReleaseFeedPolicy.StableRepositoryId, "1.0.0", new string('A', 64), 0, null, "-");
                    File.WriteAllBytes(Full(root, InstallReceipt.Path), Bytes(text.Replace(receipt.Channels.Encoded, wrong.Encoded))); break;
                }
                case "highwater-tamper": File.WriteAllText(Full(root, UpdateTransaction.HighWaterPath), "invalid water"); break;
                case "pending-reinstall": File.WriteAllText(Full(root, "BetterAstralParty.reinstall.pending"), "retained pending reinstall"); break;
                case "pending-operation": {
                    using var fence = new WindowsFileFence(root);
                    var fault = new UpdateFault { Root = fence.RootIdentity.Text, Operation = Guid.NewGuid().ToString("N"), Phase = FaultPhase.Preparation, Reason = FaultReason.Interrupted, Context = new UpdateContext(ReleaseFeedPolicy.StableRepository, "Stable", "1.0.0", "1.1.0", 1, 2, UpdateTrust.PlatformId) };
                    File.WriteAllBytes(Full(root, UpdateFaults.OperationPath), fault.Bytes()); break;
                }
                case "pending-helper": {
                    using var fence = new WindowsFileFence(root); var work = "bap-helper-" + Guid.NewGuid().ToString("N"); fence.CreatePrivateDirectory(work);
                    HelperDelivery.Write(fence, work + "/plan", Bytes("pending helper evidence - must not adopt")); break;
                }
                case "malformed-helper-directory": {
                    using var fence = new WindowsFileFence(root); fence.CreatePrivateDirectory("bap-helper-malformed"); break;
                }
                case "excessive-helper-directories": {
                    using var fence = new WindowsFileFence(root);
                    for (var i = 0; i < 64; i++) fence.CreatePrivateDirectory("bap-helper-" + Guid.NewGuid().ToString("N"));
                    Check(Directory.GetDirectories(root, "bap-helper-*").Length == 65, "fixture exceeds the bounded helper-journal inventory"); break;
                }
                case "pending-whole": {
                    using var fence = new WindowsFileFence(root); var work = "bap-helperbridge-" + Guid.NewGuid().ToString("N"); fence.CreatePrivateDirectory(work);
                    using var file = fence.OpenFile(work + "/plan", true, true); var bytes = Bytes("unresolved whole migration evidence"); file.Stream.Write(bytes); file.Flush(); break;
                }
                case "pending-transaction": {
                    using var fence = new WindowsFileFence(root); var work = "bap-txn-" + Guid.NewGuid().ToString("N"); var stage = "bap-stage-" + Guid.NewGuid().ToString("N");
                    var workId = fence.CreatePrivateDirectory(work).Text; var stageId = fence.CreatePrivateDirectory(stage).Text;
                    var lines = new List<string> { "BetterAstralParty.Transaction/v1", "root=" + fence.RootIdentity.Text, "work=" + work, "work-id=" + workId, "stage=" + stage, "stage-id=" + stageId, "descriptor=" + new string('A', 64), "receipt=fixture", "count=10" };
                    lines.AddRange(Enumerable.Repeat("retained entry", 10)); lines.Add("");
                    using var file = fence.OpenFile(work + "/plan", true, true); file.Stream.Write(Bytes(string.Join("\n", lines))); file.Flush(); break;
                }
                case "linked-helper": Check(CreateHardLinkW(Full(root, "helper-linked.keep"), Full(root, HelperDescriptor.Image), IntPtr.Zero), "scratch helper hardlink created"); break;
                case "linked-owned-plugin": Check(CreateHardLinkW(Full(root, "plugin-linked.keep"), Full(root, UpdateTrust.PluginPath), IntPtr.Zero), "scratch plugin hardlink created"); break;
            }
            // Hardlinks are deliberately rejected by the fence; use a byte-only snapshot here.
            var before = Directory.GetFiles(root, "*", SearchOption.AllDirectories).ToDictionary(path => path, path => UpdateTrust.Hash(File.ReadAllBytes(path)));
            var directories = Directory.GetDirectories(root, "*", SearchOption.AllDirectories).ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (name == "busy-helper") busy = new FileStream(Full(root, HelperDescriptor.Image), FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            if (name == "busy-operation-lock") busy = new FileStream(Full(root, "BetterAstralParty.update.lock"), FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            try { Reject(() => Run(root, payload, image, protocol: protocol, signature: signature), name + " blocked"); }
            finally { busy?.Dispose(); }
            var after = Directory.GetFiles(root, "*", SearchOption.AllDirectories);
            Check(after.Length == before.Count, "rejected candidate creates no files");
            Check(directories.SetEquals(Directory.GetDirectories(root, "*", SearchOption.AllDirectories)), "rejected candidate preserves every directory");
            foreach (var item in before) Check(UpdateTrust.Hash(File.ReadAllBytes(item.Key)) == item.Value, "rejected candidate preserves evidence " + Path.GetFileName(item.Key));
        });
    }
    private static int Main(string[] args) {
        try {
            if (!OperatingSystem.IsWindows() || args.Length != 2) throw new ArgumentException("Windows scratch and artifact roots required");
            var allowed = Path.GetFullPath(args[1]).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            _root = Path.GetFullPath(args[0]);
            if (!_root.StartsWith(allowed, StringComparison.OrdinalIgnoreCase) || _root.Length > 130 || Directory.Exists(_root)) throw new ArgumentException("Fresh short artifact scratch root required");
            Directory.CreateDirectory(_root);
            using var payload = new Payload();
            foreach (var setup in new[] { "protocol1", "protocol2", "legacy-receipt-no-water" }) Case("normal " + setup, observed => {
                var legacy = setup == "legacy-receipt-no-water"; var root = Seed(payload, protocol: setup == "protocol2" ? 2 : 1, channels: !legacy, water: !legacy);
                var before = Capture(root); Run(root, payload, boundary: observed.Add); VerifyUpgraded(root, payload, before);
            });
            foreach (var setup in new[] { "already-current", "newer-helper" }) Case(setup, _ => {
                var root = Seed(payload, version: setup == "newer-helper" ? "1.2.0" : "1.1.0", protocol: 2, marker: setup == "newer-helper" ? (byte)3 : (byte)2);
                var before = Capture(root); Run(root, payload); Preserved(root, before, false); Check(Capture(root).Hashes.Count == before.Hashes.Count, "no-op creates no journal");
            });
            Recoveries(payload); Refusals(payload);
            Console.WriteLine(JsonSerializer.Serialize(new { Passed = true, Assertions = _assertions, Roots = _roots, Cases = Results, Runtime = RuntimeInformation.FrameworkDescription, ScratchRoot = _root, NoGameOrSteamExecution = true, EphemeralFixtureKeyOnly = true }));
            return 0;
        } catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
