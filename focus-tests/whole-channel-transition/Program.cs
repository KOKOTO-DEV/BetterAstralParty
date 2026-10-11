using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using BetterAstralParty.Updating;

internal static class WholeChannelTransitionFixture
{
    private sealed class Interruption : Exception { }
    private static int _checks;
    private static void Check(bool value, string name)
    { if (!value) throw new Exception(name); _checks++; Console.WriteLine("PASS: " + name); }
    private static void Reject(Action action, string name)
    {
        try { action(); }
        catch (Exception error) when (error is ApplySafetyException or UpdateValidationException)
        { Check(true, name); return; }
        throw new Exception("Accepted: " + name);
    }
    private static byte[] Read(WindowsFileFence fence, string path, long limit = UpdateTrust.MaxFileBytes)
    { using var file = fence.OpenLaunchImage(path); return UpdateTicket.Read(file, limit); }
    private static void Write(WindowsFileFence fence, string path, byte[] bytes, bool fresh = true)
    {
        using var file = fence.OpenFile(path, true, fresh);
        file.Stream.Position = 0; file.Stream.SetLength(0); file.Stream.Write(bytes); file.Flush();
    }
    private static string Source(string name) => name == UpdateTrust.PluginPath ? "artifacts/BetterAstralParty.dll"
        : name is "BetterAstralParty-Launcher.exe" or "BetterAstralParty.compatibility.json" ? "artifacts/" + name : "tools/" + name;
    private sealed class Package : IDisposable
    {
        internal readonly WindowsFileFence Fence;
        internal readonly VerifiedUpdateDescriptor Descriptor;
        internal readonly HelperDescriptor Helper;
        internal readonly byte[] DescriptorBytes;
        internal readonly DetachedSignature Signature;
        internal Package(string path)
        {
            Fence = new WindowsFileFence(path);
            try {
                DescriptorBytes = Read(Fence, "update-proof/update.descriptor", UpdateTrust.MaxDescriptorBytes);
                var signatureBytes = Read(Fence, "update-proof/update.signature", 1024);
                Signature = DetachedSignature.Parse(signatureBytes);
                Descriptor = WholeInstallBridge.VerifyUpdateProof(DescriptorBytes, signatureBytes);
                Helper = HelperDescriptor.Verify(UpdateTrust.Production(), Read(Fence, "helper-bootstrap/helper.descriptor", UpdateTrust.MaxDescriptorBytes),
                    DetachedSignature.Parse(Read(Fence, "helper-bootstrap/helper.signature", 1024)), Read(Fence, "helper-bootstrap/" + HelperDescriptor.Image), Descriptor.Version);
            } catch { Fence.Dispose(); throw; }
        }
        public void Dispose() => Fence.Dispose();
    }
    private static void CopyOwned(WindowsFileFence target, Package package, byte[] receipt)
    {
        foreach (var file in package.Descriptor.Files) {
            var bytes = Read(package.Fence, Source(file.Path));
            Check(bytes.LongLength == file.Bytes && UpdateTrust.Hash(bytes) == file.Sha256, "scratch copy matches signed " + file.Path);
            Write(target, file.Path, bytes, !File.Exists(target.Full(file.Path)));
        }
        Write(target, InstallReceipt.Path, receipt, !File.Exists(target.Full(InstallReceipt.Path)));
    }
    private static byte[] Prepared(string root, Package package, string observation) =>
        Encoding.ASCII.GetBytes(WholeInstallBridge.PrepareReceipt(root, package.Fence.Root, package.Descriptor.Version, observation, "false"));
    private static void InstallFresh(string root, Package package)
    {
        var observation = WholeInstallBridge.Validate(root, package.Fence.Root, package.Descriptor.Version);
        var receipt = Prepared(root, package, observation);
        using (WholeInstallBridge.BeginInstall(root, package.Fence.Root, package.Descriptor.Version, observation, Encoding.ASCII.GetString(receipt)))
        using (var target = new WindowsFileFence(root)) CopyOwned(target, package, receipt);
        WholeInstallBridge.Install(root, package.Fence.Root, package.Descriptor.Version, observation, UpdateTrust.Hash(receipt));
    }
    private static Dictionary<string, string> SeedCompatibility(WindowsFileFence target, Package beta, string gameRoot, string cacheRoot)
    {
        using var game = new WindowsFileFence(gameRoot);
        using var cache = new WindowsFileFence(cacheRoot);
        using var document = JsonDocument.Parse(Read(beta.Fence, Source("BetterAstralParty.compatibility.json"), 65536));
        var copied = new Dictionary<string, string>(StringComparer.Ordinal);
        var publicGameFiles = new HashSet<string>(StringComparer.Ordinal) {
            "AstralParty_INT.exe", "GameAssembly.dll", "UnityPlayer.dll", "winhttp.dll", "baselib.dll",
            "AstralParty_INT_Data/il2cpp_data/Metadata/global-metadata.dat", "AstralParty_INT_Data/ScriptingAssemblies.json",
            "AstralParty_INT_Data/RuntimeInitializeOnLoads.json", "AstralParty_INT_Data/StreamingAssets/aa/settings.json",
            "AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle", "AstralParty_INT_Data/data.unity3d"
        };
        foreach (var entry in document.RootElement.GetProperty("files").EnumerateArray()) {
            var scope = entry.GetProperty("root").GetString();
            var path = entry.GetProperty("path").GetString() ?? throw new Exception("Missing public compatibility path");
            var hash = entry.GetProperty("sha256").GetString() ?? "";
            var publicLibrary = Regex.IsMatch(path, @"\A(?:BepInEx/core|AstralParty_INT_Data/Plugins)/(?:[^/\\:]+/)*[^/\\:]+\.dll\z", RegexOptions.IgnoreCase);
            if (scope != "game" && scope != "cache" || scope == "game" && !publicGameFiles.Contains(path) && !publicLibrary || UpdateTrust.OwnedPath(path) || !Regex.IsMatch(hash, @"\A[0-9A-Fa-f]{64}\z")
                || scope == "cache" && !Regex.IsMatch(path, @"\Acatalog[^/\\:]*\.(json|hash)\z", RegexOptions.IgnoreCase))
                throw new Exception("Only signed public compatibility entries may be copied");
            var destination = scope == "cache" ? "fixture-cache/" + path : path;
            using var source = (scope == "game" ? game : cache).OpenLaunchImage(path);
            if (source.Stream.Length > 512L * 1024 * 1024 || source.Hash() != hash.ToUpperInvariant())
                throw new Exception("Public compatibility input differs from signed baseline: " + scope + "/" + path);
            var parentEnd = destination.LastIndexOf('/');
            if (parentEnd >= 0) target.EnsureDirectory(destination.Substring(0, parentEnd));
            using var copy = target.OpenFile(destination, true, true);
            source.Stream.Position = 0; source.Stream.CopyTo(copy.Stream); copy.Flush(); source.Recheck();
            Check(copy.Hash() == hash.ToUpperInvariant(), "exact signed public compatibility scratch copy: " + scope + "/" + path);
            copied.Add(destination, hash.ToUpperInvariant());
        }
        return copied;
    }
    private static void AutomaticCase(string scratch, string name, Package stable, Package beta, byte[] zip, string gameRoot, string cacheRoot)
    {
        var root = Path.Combine(scratch, "automatic-" + name);
        if (Directory.Exists(root) || File.Exists(root)) throw new Exception("Fresh automatic case required");
        Directory.CreateDirectory(Path.Combine(root, "BepInEx/plugins/BetterAstralParty"));
        Directory.CreateDirectory(Path.Combine(root, "BepInEx/config"));
        using var target = new WindowsFileFence(root);
        var compatibility = SeedCompatibility(target, beta, gameRoot, cacheRoot);
        var preserved = new Dictionary<string, byte[]> {
            ["doorstop_config.ini"] = Encoding.UTF8.GetBytes("# keep shared bytes\r\n[General]\r\nenabled=true\r\ncustom=keep\r\n"),
            [ChannelTransitionIntent.SettingsPath] = Encoding.UTF8.GetBytes("[Updates]\nAutoDownload = false\nApplyAfterExit = false\nUpdateChannel = Beta\n사용자 설정\n"),
            ["BepInEx/plugins/OtherMod.dll"] = Encoding.ASCII.GetBytes("inert unrelated mod\n")
        };
        foreach (var item in preserved) Write(target, item.Key, item.Value);
        InstallFresh(root, stable);
        var oldReceipt = Read(target, InstallReceipt.Path, 16384);
        var old = InstallReceipt.Parse(oldReceipt);
        var oldChannels = old.Channels ?? throw new Exception("Stable channel history required");
        Check(oldChannels.ActiveChannel == "Stable" && oldChannels.BetaVersion == null && oldChannels.BetaDescriptor == "-",
            name + ": real Stable1.1.2 receipt has unvisited Beta history");
        var water = Encoding.ASCII.GetBytes("BetterAstralParty.HighWater/v1\nroot=" + target.RootIdentity.Text + "\nversion=" + stable.Descriptor.Version
            + "\ndescriptor=" + stable.Descriptor.DescriptorSha256 + "\n");
        Write(target, UpdateTransaction.HighWaterPath, water);
        var selection = new UpdateContext(beta.Descriptor.Repository, "Beta", stable.Descriptor.Version, beta.Descriptor.Version,
            beta.Descriptor.ReleaseId, beta.Descriptor.AssetId, beta.Descriptor.Platform, repositoryId: beta.Descriptor.RepositoryId);
        var invalidSignature = (byte[])beta.Signature.Signature.Clone(); invalidSignature[0] ^= 1;
        Reject(() => UpdateTransaction.Apply(target, beta.DescriptorBytes, beta.Signature.KeyId, invalidSignature, zip, UpdateTrust.Production(), selection),
            name + ": invalid signature is rejected before owned mutation");
        Check(Read(target, InstallReceipt.Path, 16384).SequenceEqual(oldReceipt) && Read(target, UpdateTransaction.HighWaterPath, 2048).SequenceEqual(water),
            name + ": rejection preserves receipt and high-water bytes");
        foreach (var item in stable.Descriptor.Files) Check(UpdateTrust.Hash(Read(target, item.Path)) == item.Sha256, name + ": rejection retains old owned " + item.Path);
        if (name == "commit") Check(UpdateTransaction.Apply(target, beta.DescriptorBytes, beta.Signature.KeyId, beta.Signature.Signature, zip, UpdateTrust.Production(), selection)
            == TransactionResult.Committed, name + ": signed automatic Apply commits with absent Beta evidence");
        else {
            var hit = false; var boundary = name == "rollback" ? "before:commit-intent" : "after:commit-intent";
            try { UpdateTransaction.Apply(target, beta.DescriptorBytes, beta.Signature.KeyId, beta.Signature.Signature, zip, UpdateTrust.Production(), selection,
                label => { if (label == boundary) { hit = true; throw new Interruption(); } }); } catch (Interruption) { }
            Check(hit, name + ": exact automatic boundary interrupted");
        }
        var work = Path.GetFileName(Directory.GetDirectories(root, "bap-txn-*").Single());
        var committed = name != "rollback";
        for (var attempt = 0; attempt < 2; attempt++) {
            Check(UpdateTransaction.Recover(target, work, UpdateTrust.Production(), selection) == (committed ? TransactionResult.Committed : TransactionResult.RolledBack),
                name + ": automatic recovery direction and repeated recovery " + attempt);
            var expected = committed ? beta : stable;
            var receipt = InstallReceipt.Parse(Read(target, InstallReceipt.Path, 16384));
            var channels = receipt.Channels ?? throw new Exception("Recovered channel history required");
            Check(receipt.LoaderBefore == old.LoaderBefore && channels.StableVersion == oldChannels.StableVersion
                && channels.StableDescriptor == oldChannels.StableDescriptor && channels.ActiveChannel == expected.Descriptor.Channel,
                name + ": recovery retains original loader baseline and Stable floor/evidence");
            Check(committed ? channels.BetaVersion == beta.Descriptor.Version && channels.BetaDescriptor == beta.Descriptor.DescriptorSha256
                : Read(target, InstallReceipt.Path, 16384).SequenceEqual(oldReceipt), name + ": target Beta evidence or exact original receipt restored");
            foreach (var item in expected.Descriptor.Files) Check(receipt.Files[item.Path] == item.Sha256 && UpdateTrust.Hash(Read(target, item.Path)) == item.Sha256,
                name + ": automatic resolved owned8 exact hash " + item.Path);
            Check(committed ? UpdateTransaction.ReadHighWater(target, out _) == beta.Descriptor.Version : Read(target, UpdateTransaction.HighWaterPath, 2048).SequenceEqual(water),
                name + ": automatic global high-water follows commit or exact rollback");
            foreach (var item in preserved) Check(Read(target, item.Key).SequenceEqual(item.Value), name + ": automatic shared/user bytes preserved " + item.Key);
            foreach (var item in compatibility) { using var file = target.OpenLaunchImage(item.Key); Check(file.Hash() == item.Value, name + ": public compatibility copy unchanged " + item.Key); }
        }
    }
    private static void Case(string scratch, string name, Package stable, Package beta)
    {
        var root = Path.Combine(scratch, name.Replace(':', '-'));
        if (Directory.Exists(root) || File.Exists(root)) throw new Exception("Fresh case required");
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(Path.Combine(root, "BepInEx/plugins/BetterAstralParty"));
        Directory.CreateDirectory(Path.Combine(root, "BepInEx/config"));
        var preserved = new Dictionary<string, byte[]> {
            ["AstralParty_INT.exe"] = Encoding.ASCII.GetBytes("inert fixture; never executed\n"),
            ["doorstop_config.ini"] = Encoding.UTF8.GetBytes("# keep all bytes\r\n[General]\r\nenabled=false\r\ncustom=keep\r\n"),
            ["BepInEx/config/kr.betterastralparty.mod.cfg"] = Encoding.UTF8.GetBytes("[Updates]\nAutoDownload = false\nApplyAfterExit = false\nUpdateChannel = Stable\n사용자 설정\n"),
            ["BepInEx/plugins/OtherMod.dll"] = Encoding.ASCII.GetBytes("inert unrelated mod\n")
        };
        using (var fence = new WindowsFileFence(root)) foreach (var item in preserved) Write(fence, item.Key, item.Value);
        InstallFresh(root, stable);
        using var target = new WindowsFileFence(root);
        var oldReceipt = Read(target, InstallReceipt.Path, 16384);
        var old = InstallReceipt.Parse(oldReceipt);
        Check(old.Channels?.ActiveChannel == "Stable" && old.Channels.ActiveVersion == stable.Descriptor.Version, name + ": initial Stable signed whole committed");
        // Constructed watermark tests preservation only; it is not a fabricated committed update transaction.
        var water = Encoding.ASCII.GetBytes("BetterAstralParty.HighWater/v1\nroot=" + target.RootIdentity.Text + "\nversion=" + stable.Descriptor.Version
            + "\ndescriptor=" + stable.Descriptor.DescriptorSha256 + "\n");
        Write(target, UpdateTransaction.HighWaterPath, water);
        string waterIdentity;
        using (var file = target.OpenFile(UpdateTransaction.HighWaterPath)) waterIdentity = file.Identity.Text;
        var observation = WholeInstallBridge.Validate(root, beta.Fence.Root, beta.Descriptor.Version);
        var nextReceipt = Prepared(root, beta, observation);
        using (WholeInstallBridge.BeginInstall(root, beta.Fence.Root, beta.Descriptor.Version, observation, Encoding.ASCII.GetString(nextReceipt))) {
            if (name != "cancel-before-owned") CopyOwned(target, beta, nextReceipt);
        }
        if (name == "cancel-before-owned") {
            WholeInstallBridge.Recover(root, beta.Fence.Root, beta.Descriptor.Version);
            Check(Read(target, InstallReceipt.Path, 16384).SequenceEqual(oldReceipt), name + ": original receipt restored without changing owned files");
            foreach (var item in stable.Descriptor.Files) Check(UpdateTrust.Hash(Read(target, item.Path)) == item.Sha256, name + ": original owned hash retained");
        } else {
            if (name == "normal") WholeInstallBridge.Install(root, beta.Fence.Root, beta.Descriptor.Version, observation, UpdateTrust.Hash(nextReceipt));
            else {
                var hit = false;
                try { WholeInstallBridge.Install(root, beta.Fence.Root, beta.Descriptor.Version, observation, UpdateTrust.Hash(nextReceipt), label => {
                    if (label == name) { hit = true; throw new Interruption(); }
                }); } catch (Interruption) { }
                Check(hit, name + ": exact native migration boundary interrupted");
                Reject(() => UpdateLaunchGate.Check(target), name + ": pending whole state blocks ordinary launch");
                WholeInstallBridge.Recover(root, beta.Fence.Root, beta.Descriptor.Version);
            }
            var receipt = InstallReceipt.Parse(Read(target, InstallReceipt.Path, 16384));
            Check(receipt.LoaderBefore == false && receipt.Channels?.ActiveChannel == "Beta" && receipt.Channels.ActiveVersion == beta.Descriptor.Version
                && receipt.Channels.BetaRepositoryId == ReleaseFeedPolicy.BetaRepositoryId && receipt.Channels.BetaDescriptor == beta.Descriptor.DescriptorSha256
                && receipt.Channels.StableRepositoryId == old.Channels!.StableRepositoryId && receipt.Channels.StableVersion == old.Channels.StableVersion
                && receipt.Channels.StableDescriptor == old.Channels.StableDescriptor, name + ": Beta active receipt preserves Stable history and loader baseline");
            foreach (var item in beta.Descriptor.Files) Check(receipt.Files[item.Path] == item.Sha256 && UpdateTrust.Hash(Read(target, item.Path)) == item.Sha256,
                name + ": exact active owned8 hash " + item.Path);
            Check(HelperDelivery.Fingerprint(target, UpdateTrust.Production(), 2) == beta.Helper.Sha256, name + ": public-verified helper is exactly current");
            var removal = HelperDelivery.RemovedEvidence(target, UpdateTrust.Production(), Read(target, HelperDescriptor.Image), Read(target, HelperDelivery.Receipt, 1024));
            Check(removal.StartsWith("BetterAstralParty.RemovedHelperEvidence/v1\n", StringComparison.Ordinal), name + ": copied removal helper proof uses signed original object history");
            Reject(() => WholeInstallBridge.Validate(root, stable.Fence.Root, stable.Descriptor.Version), name + ": reverse older whole install remains blocked");
            Reject(() => WholeInstallBridge.PrepareReceipt(root, beta.Fence.Root, beta.Descriptor.Version, observation, "false"), name + ": stale source observation cannot prepare again");
            WholeInstallBridge.Recover(root, beta.Fence.Root, beta.Descriptor.Version);
            File.WriteAllText(Path.Combine(scratch, name.Replace(':', '-') + "-proof.json"), JsonSerializer.Serialize(new {
                Root = target.RootIdentity.Text, PluginVersion = beta.Descriptor.Version,
                Channel = receipt.Channels!.Text().Split('\n'), Water = Encoding.ASCII.GetString(water).Split('\n'),
                Receipt = Encoding.ASCII.GetString(Read(target, InstallReceipt.Path, 16384)), Files = receipt.Files, HelperRemovalProof = removal
            }));
        }
        Check(Read(target, UpdateTransaction.HighWaterPath, 2048).SequenceEqual(water), name + ": original global high-water bytes retained");
        using (var file = target.OpenFile(UpdateTransaction.HighWaterPath)) Check(file.Identity.Text == waterIdentity, name + ": original global high-water object retained");
        foreach (var item in preserved) Check(Read(target, item.Key).SequenceEqual(item.Value), name + ": shared/user bytes preserved " + item.Key);
        UpdateLaunchGate.Check(target);
        Check(!WholeInstallBridge.Pending(target), name + ": no active whole migration after completion/recovery");
    }
    private static void Remove(WindowsFileFence target, string path)
    { using var file = target.OpenFile(path, true); file.RemoveOrdinaryRecoveryTarget(path); }
    private static Dictionary<string, string> Snapshot(WindowsFileFence target) => Directory.GetFiles(target.Root, "*", SearchOption.AllDirectories)
        .ToDictionary(path => path.Substring(target.Root.Length + 1).Replace('\\', '/'), path => {
            using var file = target.OpenLaunchImage(path.Substring(target.Root.Length + 1).Replace('\\', '/'));
            return file.Hash();
        }, StringComparer.Ordinal);
    private static void PartialRemovalEvidence(string scratch, WindowsFileFence target, Package beta, string[] missing, Dictionary<string, byte[]> preserved)
    {
        foreach (var path in missing) Remove(target, path);
        WholeInstallBridge.ValidatePartialRemoval(target.Root);
        Check(true, "partial removal: current production validator accepts only the known absent non-plugin set");
        var receipt = Read(target, InstallReceipt.Path, 16384);
        var helperImage = Read(target, HelperDescriptor.Image);
        var helperReceipt = Read(target, HelperDelivery.Receipt, 1024);
        var helperProof = HelperDelivery.RemovedEvidence(target, UpdateTrust.Production(), helperImage, helperReceipt);
        var water = Read(target, UpdateTransaction.HighWaterPath, 2048);
        string waterIdentity;
        using (var file = target.OpenFile(UpdateTransaction.HighWaterPath)) waterIdentity = file.Identity.Text;
        var backupRoot = Path.Combine(scratch, "partial-removal-backups");
        var backupId = Guid.NewGuid().ToString("N");
        var backupDir = Path.Combine(backupRoot, backupId);
        Directory.CreateDirectory(backupDir);
        using var backup = new WindowsFileFence(backupDir);
        var paths = InstallReceipt.Owned.Concat(new[] { InstallReceipt.Path, HelperDescriptor.Image, HelperDelivery.Receipt, ChannelTransitionIntent.SettingsPath }).OrderBy(path => path, StringComparer.Ordinal).ToArray();
        var entries = new List<object>();
        foreach (var path in paths) {
            var exists = File.Exists(target.Full(path));
            var leaf = entries.Count.ToString(System.Globalization.CultureInfo.InvariantCulture) + ".bin";
            string? hash = null;
            if (exists) {
                var bytes = Read(target, path); hash = UpdateTrust.Hash(bytes); Write(backup, leaf, bytes);
                Check(UpdateTrust.Hash(Read(backup, leaf)) == hash, "partial removal: exact retained backup " + path);
            } else Check(missing.Contains(path, StringComparer.Ordinal) && path != UpdateTrust.PluginPath, "partial removal: false row is only a known absent non-plugin file " + path);
            entries.Add(new { Target = target.Full(path), Existed = exists, Backup = backup.Full(leaf), Hash = hash });
        }
        var journal = JsonSerializer.SerializeToUtf8Bytes(new { GameRoot = target.Root, Entries = entries, BackupDir = backupDir });
        Write(backup, "completed.json", journal);
        foreach (var path in paths) if (File.Exists(target.Full(path))) Remove(target, path);
        foreach (var path in paths) Check(!File.Exists(target.Full(path)), "partial removal: owned target absent " + path);
        Check(HelperDelivery.RemovedEvidence(target, UpdateTrust.Production(), helperImage, helperReceipt) == helperProof,
            "partial removal: signed helper history still authenticates retained copies after removal");
        Check(Read(target, UpdateTransaction.HighWaterPath, 2048).SequenceEqual(water), "partial removal: original high-water bytes retained");
        using (var file = target.OpenFile(UpdateTransaction.HighWaterPath)) Check(file.Identity.Text == waterIdentity, "partial removal: original high-water identity retained");
        foreach (var item in preserved.Where(item => item.Key != ChannelTransitionIntent.SettingsPath))
            Check(Read(target, item.Key).SequenceEqual(item.Value), "partial removal: shared/unknown files preserved " + item.Key);
        var channels = InstallReceipt.Parse(receipt).Channels ?? throw new Exception("Retained removal channels required");
        File.WriteAllText(Path.Combine(scratch, "bounded-partial-removal.json"), JsonSerializer.Serialize(new {
            GameRoot = target.Root, Root = target.RootIdentity.Text, PluginVersion = beta.Descriptor.Version,
            Receipt = Encoding.ASCII.GetString(receipt), Channel = channels.Text().Split('\n'), Water = Encoding.ASCII.GetString(water).Split('\n'),
            WaterIdentity = waterIdentity, BackupRoot = backupRoot, BackupId = backupId, JournalSha256 = UpdateTrust.Hash(journal),
            Missing = missing, Preserved = preserved.Where(item => item.Key != ChannelTransitionIntent.SettingsPath).ToDictionary(item => item.Key, item => UpdateTrust.Hash(item.Value)),
            Scope = "Constructed scratch-only completed removal journal with native held-file backups/removal; actual PowerShell removal/reinstall predicates must be checked separately."
        }));
    }
    private static void PartialRepairCase(string scratch, string name, Package stable, Package beta, string[] missing, bool upgrade)
    {
        var root = Path.Combine(scratch, name);
        Directory.CreateDirectory(Path.Combine(root, "BepInEx/plugins/BetterAstralParty"));
        Directory.CreateDirectory(Path.Combine(root, "BepInEx/config"));
        using var target = new WindowsFileFence(root);
        var preserved = new Dictionary<string, byte[]> {
            ["AstralParty_INT.exe"] = Encoding.ASCII.GetBytes("inert fixture; never executed\n"),
            ["doorstop_config.ini"] = Encoding.ASCII.GetBytes("[General]\r\nenabled=false\r\nother=keep\r\n"),
            [ChannelTransitionIntent.SettingsPath] = Encoding.UTF8.GetBytes("[Updates]\nAutoDownload = false\nApplyAfterExit = false\nUpdateChannel = Beta\n"),
            ["BepInEx/plugins/OtherMod.dll"] = Encoding.ASCII.GetBytes("inert unrelated mod\n"),
            ["unknown-user-file.keep"] = Encoding.ASCII.GetBytes("keep unknown file\n")
        };
        foreach (var item in preserved) Write(target, item.Key, item.Value);
        var initial = upgrade ? stable : beta;
        InstallFresh(root, initial);
        var water = Encoding.ASCII.GetBytes("BetterAstralParty.HighWater/v1\nroot=" + target.RootIdentity.Text + "\nversion=" + initial.Descriptor.Version
            + "\ndescriptor=" + initial.Descriptor.DescriptorSha256 + "\n");
        Write(target, UpdateTransaction.HighWaterPath, water);
        var helperBefore = HelperDelivery.Fingerprint(target, UpdateTrust.Production(), 2);
        foreach (var path in missing) Remove(target, path);
        var removalBefore = Snapshot(target);
        WholeInstallBridge.ValidatePartialRemoval(root);
        var removalAfter = Snapshot(target);
        Check(removalBefore.Count == removalAfter.Count && removalBefore.All(pair => removalAfter.TryGetValue(pair.Key, out var hash) && hash == pair.Value),
            name + ": read-only removal validation accepts known missing owned files without writes");
        var observation = WholeInstallBridge.Validate(root, beta.Fence.Root, beta.Descriptor.Version);
        var receipt = Prepared(root, beta, observation);
        using (WholeInstallBridge.BeginInstall(root, beta.Fence.Root, beta.Descriptor.Version, observation, Encoding.ASCII.GetString(receipt))) CopyOwned(target, beta, receipt);
        WholeInstallBridge.Install(root, beta.Fence.Root, beta.Descriptor.Version, observation, UpdateTrust.Hash(receipt));
        var installed = InstallReceipt.Parse(Read(target, InstallReceipt.Path, 16384));
        foreach (var file in beta.Descriptor.Files) Check(installed.Files[file.Path] == file.Sha256 && UpdateTrust.Hash(Read(target, file.Path)) == file.Sha256,
            name + ": exact repaired signed owned file " + file.Path);
        Check(InstalledPluginMetadata.Read(Read(target, UpdateTrust.PluginPath)).Version == beta.Descriptor.Version, name + ": actual plugin version preserved/replaced as requested");
        Check(HelperDelivery.Fingerprint(target, UpdateTrust.Production(), 2) == beta.Helper.Sha256 && (upgrade || helperBefore == beta.Helper.Sha256),
            name + ": exact signed helper remains valid");
        Check(Read(target, UpdateTransaction.HighWaterPath, 2048).SequenceEqual(water), name + ": same-install high-water history is not retired");
        foreach (var item in preserved) Check(Read(target, item.Key).SequenceEqual(item.Value), name + ": shared/user/unknown bytes preserved " + item.Key);
        if (upgrade) {
            Check(installed.Channels?.StableVersion == stable.Descriptor.Version && installed.Channels.ActiveChannel == "Beta", name + ": prior Stable channel floor retained");
            PartialRemovalEvidence(scratch, target, beta, missing, preserved);
        }
    }
    private static void PartialRefusals(string scratch, Package beta)
    {
        var root = Path.Combine(scratch, "partial-refusals");
        Directory.CreateDirectory(Path.Combine(root, "BepInEx/plugins/BetterAstralParty"));
        using var target = new WindowsFileFence(root);
        Write(target, "AstralParty_INT.exe", Encoding.ASCII.GetBytes("inert fixture; never executed\n"));
        InstallFresh(root, beta);
        foreach (var kind in new[] { "changed-launcher", "missing-plugin", "missing-install-receipt", "missing-helper", "missing-helper-receipt", "missing-helper-pair", "changed-helper", "changed-helper-receipt", "forged-helper-receipt", "wrong-channel-root", "same-build-different-receipt-hash", "pending-reinstall", "pending-operation" }) {
            var paths = kind switch {
                "missing-plugin" => new[] { UpdateTrust.PluginPath },
                "missing-install-receipt" => new[] { InstallReceipt.Path },
                "missing-helper" or "changed-helper" => new[] { HelperDescriptor.Image },
                "missing-helper-receipt" or "changed-helper-receipt" or "forged-helper-receipt" => new[] { HelperDelivery.Receipt },
                "missing-helper-pair" => new[] { HelperDescriptor.Image, HelperDelivery.Receipt },
                "wrong-channel-root" => new[] { "BetterAstralParty-Launcher.exe", InstallReceipt.Path },
                "same-build-different-receipt-hash" => new[] { "BetterAstralParty-Launcher.exe", InstallReceipt.Path },
                "pending-reinstall" => new[] { "BetterAstralParty.reinstall.pending" },
                "pending-operation" => new[] { "BetterAstralParty.update.operation" },
                _ => new[] { "BetterAstralParty-Launcher.exe" }
            };
            var originals = paths.ToDictionary(path => path, path => File.Exists(target.Full(path)) ? Read(target, path) : null, StringComparer.Ordinal);
            var hidden = new Dictionary<string, string>(StringComparer.Ordinal);
            if (kind == "wrong-channel-root") {
                var channels = InstallReceipt.Parse(originals[InstallReceipt.Path]!).Channels!.Text();
                var forged = channels.Replace("root=" + target.RootIdentity.Text + "\n", "root=00000000:0000000000000000\n", StringComparison.Ordinal);
                var changed = Encoding.ASCII.GetBytes(Encoding.ASCII.GetString(originals[InstallReceipt.Path]!).Replace(Convert.ToBase64String(Encoding.ASCII.GetBytes(channels)), Convert.ToBase64String(Encoding.ASCII.GetBytes(forged)), StringComparison.Ordinal));
                Check(InstallReceipt.Parse(changed).Channels!.Root != target.RootIdentity.Text, kind + ": structurally valid wrong-root channel prepared");
                Remove(target, "BetterAstralParty-Launcher.exe"); Write(target, InstallReceipt.Path, changed, false);
            } else if (kind == "forged-helper-receipt") {
                var original = Encoding.ASCII.GetString(originals[HelperDelivery.Receipt]!);
                var changed = Encoding.ASCII.GetBytes(original.Replace("sha256=" + beta.Helper.Sha256 + "\n", "sha256=" + new string('0', 64) + "\n", StringComparison.Ordinal));
                Check(!changed.SequenceEqual(originals[HelperDelivery.Receipt]!), kind + ": structured receipt digest forged without changing its shape");
                Write(target, HelperDelivery.Receipt, changed, false);
            } else if (kind == "same-build-different-receipt-hash") {
                var oldHash = UpdateTrust.Hash(originals["BetterAstralParty-Launcher.exe"]!);
                Remove(target, "BetterAstralParty-Launcher.exe");
                var changed = Encoding.ASCII.GetBytes(Encoding.ASCII.GetString(originals[InstallReceipt.Path]!).Replace(oldHash, new string('0', 64), StringComparison.Ordinal));
                Check(InstallReceipt.Parse(changed).Files["BetterAstralParty-Launcher.exe"] == new string('0', 64), kind + ": exact different receipt payload prepared");
                Write(target, InstallReceipt.Path, changed, false);
            } else foreach (var path in paths) {
                if (kind.StartsWith("missing-", StringComparison.Ordinal)) {
                    var hiddenPath = "fixture-hidden-" + Guid.NewGuid().ToString("N");
                    using var file = target.OpenFile(path, true); file.RenameTo(target, hiddenPath); hidden.Add(path, hiddenPath);
                }
                else Write(target, path, Encoding.ASCII.GetBytes("inert changed/pending fixture\n"), originals[path] == null);
            }
            if (kind.Contains("helper", StringComparison.Ordinal)) Remove(target, "BetterAstralParty-Launcher.exe");
            var before = Snapshot(target);
            Reject(() => WholeInstallBridge.Validate(root, beta.Fence.Root, beta.Descriptor.Version), kind + ": bounded repair rejects missing core evidence/changed present files/pending work");
            if(kind is "missing-plugin" or "missing-install-receipt" or "changed-launcher" or "missing-helper-pair") {
                var expected=kind switch {
                    "missing-plugin" => "OwnedPluginMissing",
                    "missing-install-receipt" => "InstallReceiptMissing",
                    "changed-launcher" => "OwnedFileChanged",
                    _ => "HelperEvidenceMissing"
                };
                try { WholeInstallBridge.Validate(root, beta.Fence.Root, beta.Descriptor.Version); throw new Exception("Accepted missing/changed evidence"); }
                catch(ApplySafetyException error) { Check(error.Failure==ApplyFailure.RecoveryRequired && (string?)error.Data["BapRecoveryReason"]==expected, kind+": specific recovery blocker retained without changing refusal"); }
            }
            if (kind != "same-build-different-receipt-hash")
                Reject(() => WholeInstallBridge.ValidatePartialRemoval(root), kind + ": production partial-removal validator rejects unsafe evidence");
            var after = Snapshot(target);
            Check(before.Count == after.Count && before.All(pair => after.TryGetValue(pair.Key, out var hash) && hash == pair.Value), kind + ": rejection makes no owned/history mutation");
            foreach (var item in originals) {
                if (hidden.TryGetValue(item.Key, out var hiddenPath)) { using var file = target.OpenFile(hiddenPath, true); file.RenameTo(target, item.Key); }
                else if (item.Value == null) Remove(target, item.Key);
                else Write(target, item.Key, item.Value, !File.Exists(target.Full(item.Key)));
            }
            if (kind.Contains("helper", StringComparison.Ordinal)) Write(target, "BetterAstralParty-Launcher.exe", Read(beta.Fence, Source("BetterAstralParty-Launcher.exe")));
        }
        Remove(target, "BetterAstralParty-Launcher.exe");
        var observation = WholeInstallBridge.Validate(root, beta.Fence.Root, beta.Descriptor.Version);
        var receipt = Prepared(root, beta, observation);
        var unknown = Encoding.ASCII.GetBytes("unknown file appeared after observation; preserve\n");
        Write(target, "BetterAstralParty-Launcher.exe", unknown);
        Reject(() => { using var lease = WholeInstallBridge.BeginInstall(root, beta.Fence.Root, beta.Descriptor.Version, observation, Encoding.ASCII.GetString(receipt)); },
            "partial repair: late unknown present file is rejected before copying");
        Reject(() => WholeInstallBridge.ValidatePartialRemoval(root), "partial removal: late unknown present file is rejected");
        Check(Read(target, "BetterAstralParty-Launcher.exe").SequenceEqual(unknown), "partial repair: late unknown file remains intact");
    }
    private static void EmbeddedHelperCase(string scratch, Package stable, Package beta)
    {
        var root = Path.Combine(scratch, "embedded-helper");
        Directory.CreateDirectory(Path.Combine(root, "BepInEx/plugins/BetterAstralParty"));
        Directory.CreateDirectory(Path.Combine(root, "BepInEx/config"));
        using var target = new WindowsFileFence(root);
        var preserved = new Dictionary<string, byte[]> {
            ["AstralParty_INT.exe"] = Encoding.ASCII.GetBytes("inert fixture; never executed\n"),
            ["doorstop_config.ini"] = Encoding.ASCII.GetBytes("[General]\r\nenabled=false\r\nother=keep\r\n"),
            [ChannelTransitionIntent.SettingsPath] = Encoding.ASCII.GetBytes("[Updates]\nAutoDownload = false\nApplyAfterExit = false\nUpdateChannel = Beta\n"),
            ["BepInEx/plugins/OtherMod.dll"] = Encoding.ASCII.GetBytes("inert unrelated mod\n")
        };
        foreach (var item in preserved) Write(target, item.Key, item.Value);
        InstallFresh(root, stable);
        var water = Encoding.ASCII.GetBytes("BetterAstralParty.HighWater/v1\nroot=" + target.RootIdentity.Text + "\nversion=" + stable.Descriptor.Version
            + "\ndescriptor=" + stable.Descriptor.DescriptorSha256 + "\n");
        Write(target, UpdateTransaction.HighWaterPath, water);
        string Slot(string path) { using var file = target.OpenFile(path); return file.Identity.Text + "\t" + file.Hash(); }
        var oldImage = Slot(HelperDescriptor.Image); var oldHelperReceipt = Slot(HelperDelivery.Receipt); var oldWater = Slot(UpdateTransaction.HighWaterPath);
        var oldJournals = Snapshot(target).Where(pair => pair.Key.StartsWith("bap-helper-", StringComparison.Ordinal)).ToArray();
        Check(HelperDelivery.AuthenticatedAt(target, UpdateTrust.Production(), HelperDescriptor.Image, HelperDelivery.Receipt)?.Version == stable.Descriptor.Version,
            "embedded: actual authenticated Stable1.1.2 helper seed");
        var observation = WholeInstallBridge.Validate(root, beta.Fence.Root, beta.Descriptor.Version);
        var receipt = Prepared(root, beta, observation);
        Check(!WholeInstallBridge.Pending(target), "embedded: receipt preparation creates no whole intent");
        // Simulate a completed owned8 delivery only; do not invoke the whole helper migration.
        var archive = "fixture-owned8-" + Guid.NewGuid().ToString("N"); target.CreatePrivateDirectory(archive);
        var owned = beta.Descriptor.Files.Select(file => file.Path).Append(InstallReceipt.Path).ToArray();
        for (var i = 0; i < owned.Length; i++) {
            var path = owned[i]; var bytes = path == InstallReceipt.Path ? receipt : Read(beta.Fence, Source(path));
            if (path != InstallReceipt.Path) {
                var signed = beta.Descriptor.Files.Single(file => file.Path == path);
                Check(bytes.LongLength == signed.Bytes && UpdateTrust.Hash(bytes) == signed.Sha256, "embedded: signed delivery bytes " + path);
            }
            Write(target, archive + "/new-" + i, bytes);
            using (var old = target.OpenFile(path, true)) { old.RenameTo(target, archive + "/old-" + i); old.Flush(); }
            using (var next = target.OpenFile(archive + "/new-" + i, true)) { next.RenameTo(target, path); next.Flush(); }
        }
        Check(Slot(HelperDescriptor.Image) == oldImage && Slot(HelperDelivery.Receipt) == oldHelperReceipt
            && !WholeInstallBridge.Pending(target), "embedded: owned8 delivery retains authenticated old helper and creates no whole pending intent");
        var assembly = System.Reflection.Assembly.Load(Read(beta.Fence, Source("BetterAstralParty-Launcher.exe")));
        var names = new[] { "descriptor", "signature", "image" };
        Check(assembly.GetManifestResourceNames().Order().SequenceEqual(names.Select(name => AutomaticHelperUpgrade.ResourcePrefix + name).Order()),
            "embedded: actual launcher contains exactly three helper resources");
        byte[] Resource(string name, long limit) {
            using var stream = assembly.GetManifestResourceStream(AutomaticHelperUpgrade.ResourcePrefix + name) ?? throw new Exception("Missing actual helper resource");
            if (stream.Length < 1 || stream.Length > limit) throw new Exception("Helper resource size bound");
            var bytes = new byte[checked((int)stream.Length)]; stream.ReadExactly(bytes); return bytes;
        }
        var descriptor = Resource("descriptor", UpdateTrust.MaxDescriptorBytes); var signature = Resource("signature", 1024); var image = Resource("image", UpdateTrust.MaxFileBytes);
        var embedded = HelperDescriptor.Verify(UpdateTrust.Production(), descriptor, DetachedSignature.Parse(signature), image, "1.1.3-rc.3.local.3");
        Check(embedded.Protocol == 2 && embedded.Version != beta.Helper.Version && embedded.DescriptorHash != beta.Helper.DescriptorHash,
            "embedded: production-verified helper3 is distinct from final whole helper4");
        var context = new UpdateContext(stable.Descriptor.Repository, "Stable", stable.Descriptor.Version, stable.Descriptor.Version,
            stable.Descriptor.ReleaseId, stable.Descriptor.AssetId, stable.Descriptor.Platform, repositoryId: stable.Descriptor.RepositoryId);
        UpdateFaults.Fail(target, context, FaultPhase.Download, FaultReason.Network);
        var fault = Slot(UpdateFaults.FailurePath);
        var repairObservation = WholeInstallBridge.Validate(root, beta.Fence.Root, beta.Descriptor.Version);
        var repairReceipt = Prepared(root, beta, repairObservation);
        var before = owned.ToDictionary(path => path, Slot, StringComparer.Ordinal);
        var interrupted = false;
        try { using var lease = new UpdateLaunchGate.Lease(root, fence => AutomaticHelperUpgrade.Ensure(fence, descriptor, signature, image,
            UpdateTrust.Production(), label => { if (label == "intent") { interrupted = true; throw new Interruption(); } })); } catch (Interruption) { }
        Check(interrupted && AutomaticHelperUpgrade.Pending(target) && !HelperDelivery.PendingInstall(target),
            "embedded: interruption leaves only the durable automatic intent, before any child helper plan");
        var pending = Snapshot(target);
        void Deny(Action action, string name) {
            Reject(action, "embedded intent-only: " + name);
            var after = Snapshot(target);
            Check(pending.Count == after.Count && pending.All(pair => after.TryGetValue(pair.Key, out var hash) && hash == pair.Value),
                "embedded intent-only: " + name + " does not mutate files");
        }
        Deny(() => WholeInstallBridge.Validate(root, beta.Fence.Root, beta.Descriptor.Version), "whole Validate rejects");
        Deny(() => { using var lease = WholeInstallBridge.GuardRecovery(root, beta.Fence.Root, beta.Descriptor.Version); }, "GuardRecovery rejects");
        Deny(() => { using var lease = WholeInstallBridge.BeginInstall(root, beta.Fence.Root, beta.Descriptor.Version, repairObservation, Encoding.ASCII.GetString(repairReceipt)); }, "BeginInstall rejects");
        Deny(() => WholeInstallBridge.Recover(root, beta.Fence.Root, beta.Descriptor.Version), "whole Recover rejects");
        for (var attempt = 0; attempt < 2; attempt++) {
            var previous = Snapshot(target);
            using (var lease = new UpdateLaunchGate.Lease(root, fence => AutomaticHelperUpgrade.Ensure(fence, assembly))) { }
            Check(HelperDelivery.Fingerprint(target, UpdateTrust.Production(), 2) == embedded.Sha256
                && HelperDelivery.AuthenticatedAt(target, UpdateTrust.Production(), HelperDescriptor.Image, HelperDelivery.Receipt)?.DescriptorHash == embedded.DescriptorHash,
                "embedded: actual Assembly overload installs/resumes helper3 " + attempt);
            foreach (var item in before) Check(Slot(item.Key) == item.Value, "embedded: owned8/receipt object and hash unchanged " + item.Key);
            Check(Slot(UpdateTransaction.HighWaterPath) == oldWater && Read(target, UpdateTransaction.HighWaterPath, 2048).SequenceEqual(water)
                && Slot(UpdateFaults.FailurePath) == fault, "embedded: retained high-water and fault latch unchanged");
            foreach (var item in preserved) Check(Read(target, item.Key).SequenceEqual(item.Value), "embedded: unrelated/shared/user bytes unchanged " + item.Key);
            foreach (var item in oldJournals) Check(UpdateTrust.Hash(Read(target, item.Key)) == item.Value, "embedded: original helper journal retained " + item.Key);
            var work = Path.GetFileName(Directory.GetDirectories(root, "bap-helperauto-*").Single());
            Check(Slot(work + "/old-image") == oldImage && Slot(work + "/old-receipt") == oldHelperReceipt
                && HelperDelivery.ArchivedFingerprint(target, UpdateTrust.Production(), work + "/old-image", work + "/old-receipt") == stable.Helper.Sha256,
                "embedded: old signed helper image/receipt archive retain original file IDs");
            Check(!AutomaticHelperUpgrade.Pending(target) && !HelperDelivery.PendingInstall(target) && !WholeInstallBridge.Pending(target), "embedded: no active helper or whole work remains");
            if (attempt == 1) {
                var after = Snapshot(target);
                Check(previous.Count == after.Count && previous.All(pair => after.TryGetValue(pair.Key, out var hash) && hash == pair.Value), "embedded: second Ensure is a complete file no-op");
            }
        }
        File.WriteAllText(Path.Combine(scratch, "embedded-helper-result.json"), JsonSerializer.Serialize(new {
            Passed = true, Root = target.RootIdentity.Text, PluginVersion = beta.Descriptor.Version, EmbeddedHelperVersion = embedded.Version,
            EmbeddedHelperSha256 = embedded.Sha256, EmbeddedDescriptorSha256 = embedded.DescriptorHash,
            WholeHelperVersion = beta.Helper.Version, IntentOnlyWholeRefusals = 4, OldImage = oldImage, OldReceipt = oldHelperReceipt,
            Scope = "Actual public-signed launcher resources and production Assembly overload; scratch-only owned8 delivery simulation, not legacy-client automatic-update execution."
        }));
    }
    internal static void Main(string[] args)
    {
        if (args.Length != 4 && args.Length != 7) throw new ArgumentException("fresh-scratch artifact-root Stable-package Beta-package [signed-update-ZIP public-game-root public-cache-root]");
        var scratch = Path.GetFullPath(args[0]); var artifacts = Path.GetFullPath(args[1]).TrimEnd(Path.DirectorySeparatorChar);
        if (!Path.GetDirectoryName(scratch)!.Equals(artifacts, StringComparison.OrdinalIgnoreCase)
            || !Regex.IsMatch(Path.GetFileName(scratch), @"\Awct-[0-9a-f]{32}\z") || Directory.Exists(scratch) || File.Exists(scratch))
            throw new Exception("Only a new direct artifact scratch may be changed");
        using var stable = new Package(args[2]); using var beta = new Package(args[3]);
        Check(stable.Descriptor.Channel == "Stable" && stable.Descriptor.Version == "1.1.2" && stable.Descriptor.RepositoryId == ReleaseFeedPolicy.StableRepositoryId,
            "exact public Stable1.1.2 signed baseline");
        Check(beta.Descriptor.Channel == "Beta" && beta.Descriptor.RepositoryId == ReleaseFeedPolicy.BetaRepositoryId
            && UpdateVersion.Parse(beta.Descriptor.Version).CompareTo(UpdateVersion.Parse(stable.Descriptor.Version)) > 0,
            "verified target Beta strictly above Stable1.1.2");
        if (Encoding.ASCII.GetString(beta.DescriptorBytes).StartsWith("BetterAstralParty.LocalInstallDescriptor/v1\n", StringComparison.Ordinal)) {
            Check(beta.Descriptor.ReleaseId == 0 && beta.Descriptor.AssetId == 0 && UpdateVersion.Parse(beta.Descriptor.Version).IsLocalPrerelease, "local proof retains zero remote asset identities");
            var remote = new UpdateContext(beta.Descriptor.Repository, "Beta", "0.0.0", beta.Descriptor.Version, 1, 1, beta.Descriptor.Platform, repositoryId: beta.Descriptor.RepositoryId);
            Reject(() => UpdateTrust.Production().VerifyDescriptor(beta.DescriptorBytes, beta.Signature.KeyId, beta.Signature.Signature, remote), "local proof remains rejected by remote update verification");
        }
        byte[]? zip = null;
        if (args.Length == 7) {
            using var zipFile = File.Open(args[4], FileMode.Open, FileAccess.Read, FileShare.Read);
            if (zipFile.Length != beta.Descriptor.ZipBytes || zipFile.Length > UpdateTrust.MaxZipBytes) throw new Exception("Exact signed update ZIP required");
            zip = new byte[checked((int)zipFile.Length)]; zipFile.ReadExactly(zip);
            var context = new UpdateContext(beta.Descriptor.Repository, "Beta", "0.0.0", beta.Descriptor.Version, beta.Descriptor.ReleaseId,
                beta.Descriptor.AssetId, beta.Descriptor.Platform, repositoryId: beta.Descriptor.RepositoryId);
            var remote = UpdateTrust.Production().VerifyDescriptor(beta.DescriptorBytes, beta.Signature.KeyId, beta.Signature.Signature, context);
            UpdatePackage.VerifyPayload(zip, remote);
            Check(remote.DescriptorSha256 == beta.Descriptor.DescriptorSha256, "actual automatic update ZIP and remote release signature independently verified");
        }
        Directory.CreateDirectory(scratch);
        try {
            foreach (var name in new[] { "normal", "cancel-before-owned", "bridge-prepared", "after:old-image", "after:receipt", "after:bridge-committed" })
                Case(scratch, name, stable, beta);
            PartialRepairCase(scratch, "repair-launcher", stable, beta, new[] { "BetterAstralParty-Launcher.exe" }, false);
            PartialRepairCase(scratch, "repair-compatibility", stable, beta, new[] { "BetterAstralParty.compatibility.json" }, false);
            PartialRepairCase(scratch, "repair-launch-script", stable, beta, new[] { "BetterAstralParty-Mod.cmd", "check-compatibility.ps1" }, false);
            PartialRepairCase(scratch, "repair-all-nonplugin", stable, beta, InstallReceipt.Owned.Where(path => path != UpdateTrust.PluginPath).ToArray(), true);
            PartialRefusals(scratch, beta);
            var embeddedHelperCases = beta.Descriptor.Version == "1.1.3-rc.3.local.4" ? 1 : 0;
            if (embeddedHelperCases != 0) EmbeddedHelperCase(scratch, stable, beta);
            if (zip != null) foreach (var name in new[] { "commit", "rollback", "forward" }) AutomaticCase(scratch, name, stable, beta, zip, args[5], args[6]);
            File.WriteAllText(Path.Combine(scratch, "native-results.json"), JsonSerializer.Serialize(new {
                Passed = true, Checks = _checks, StableVersion = stable.Descriptor.Version, BetaVersion = beta.Descriptor.Version,
                StableDescriptor = stable.Descriptor.DescriptorSha256, BetaDescriptor = beta.Descriptor.DescriptorSha256,
                AutomaticCases = zip == null ? 0 : 3,
                PartialRepairCases = 4, PartialRefusalCases = 14,
                EmbeddedHelperCases = embeddedHelperCases,
                Scope = "Production public-signature/native whole bridge and optional signed automatic Apply/recovery in fresh scratch; signed public compatibility input copies only; no game/Steam execution, private key, real install/removal or network."
            }));
            Console.WriteLine("PASS: " + _checks + " signed whole/native scratch assertions; evidence retained at " + scratch);
        } catch (Exception error) { File.WriteAllText(Path.Combine(scratch, "failure.txt"), error.ToString()); throw; }
    }
}
