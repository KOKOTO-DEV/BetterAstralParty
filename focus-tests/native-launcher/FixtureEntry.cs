using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using BetterAstralParty.Updating;

namespace BetterAstralParty
{
    internal static class Plugin
    {
        public const string Guid = "kr.betterastralparty.mod", Version = FixtureBoundary.Version, UpdateProtocol = "3", SettingsSchema = "1";
    }
}

internal static class FixtureEntry
{
    private static readonly string[] Names = { "SteamAppId", "SteamGameId", "SteamOverlayGameId", "BAP_COMPATIBILITY_CHECKED", "BAP_UPDATER_LAUNCHER_PID", "BAP_UPDATER_LAUNCHER_CREATION", "BAP_UPDATER_LAUNCHER_SESSION", "PSModulePath" };
    private static string Snapshot()
    {
        var text = new StringBuilder();
        foreach (var name in Names) text.Append(name).Append('=').Append(Environment.GetEnvironmentVariable(name) ?? "<absent>").Append('\n');
        return text.ToString();
    }
    private static void Setup(string root)
    {
        Directory.CreateDirectory(Path.Combine(root, "BepInEx", "config"));
        foreach (var path in InstallReceipt.Owned) {
            var full = Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            if (path == UpdateTrust.PluginPath) File.Copy(typeof(FixtureEntry).Assembly.Location, full, true);
            else if (!File.Exists(full)) File.WriteAllText(full, "inert fixture input; never execute\n");
        }
        var receipt = new StringBuilder("{\"schema\":1,\"baseline\":\"1.2.1\",\"owner\":\"" + InstalledPluginMetadata.Owner + "\",\"loaderBefore\":false,\"files\":[");
        foreach (var path in InstallReceipt.Owned) {
            if (receipt[receipt.Length - 1] != '[') receipt.Append(',');
            receipt.Append("{\"path\":\"").Append(path).Append("\",\"sha256\":\"")
                .Append(UpdateTrust.Hash(File.ReadAllBytes(Path.Combine(root, path.Replace('/', Path.DirectorySeparatorChar))))).Append("\"}");
        }
        var descriptor = File.ReadAllBytes(Path.Combine(root, "fixture-helper.descriptor"));
        var signature = File.ReadAllBytes(Path.Combine(root, "fixture-helper.signature"));
        var image = File.ReadAllBytes(Path.Combine(root, "fixture-helper.image"));
        var verified = HelperDescriptor.Verify(UpdateTrust.Production(), descriptor, DetachedSignature.Parse(signature), image);
        using (var fence = new WindowsFileFence(root)) {
            var channels = new ReceiptChannelState(fence.RootIdentity.Text, "Stable", Guid.NewGuid().ToString("N"),
                ReleaseFeedPolicy.StableRepositoryId, FixtureBoundary.Version, new string('A', 64), 0, null, "-");
            receipt.Append("],\"channelState\":\"").Append(channels.Encoded).Append("\"}");
            File.WriteAllText(Path.Combine(root, InstallReceipt.Path), receipt.ToString());
            InstallReceipt.Parse(Encoding.ASCII.GetBytes(receipt.ToString()));
            var work = "bap-v3-helper-" + Guid.NewGuid().ToString("N"); var workId = fence.CreatePrivateDirectory(work).Text;
            HelperDelivery.Write(fence, work + "/descriptor", descriptor); HelperDelivery.Write(fence, work + "/signature", signature);
            HelperDelivery.Write(fence, work + "/image", image);
            string imageId; using (var file = fence.OpenFile(work + "/image")) imageId = file.Identity.Text;
            HelperDelivery.Write(fence, work + "/receipt", HelperDelivery.WholeReceiptBytes(fence, verified, imageId));
            string receiptId; using (var file = fence.OpenFile(work + "/receipt")) receiptId = file.Identity.Text;
            var plan = "BetterAstralParty.HelperInstall/v1\nroot=" + fence.RootIdentity.Text + "\nwork=" + work + "\nwork-id=" + workId + "\ndescriptor=" + verified.DescriptorHash + "\nimage-id=" + imageId + "\nreceipt-id=" + receiptId + "\n";
            HelperDelivery.Write(fence, work + "/plan", Encoding.ASCII.GetBytes(plan));
            HelperDelivery.FinishWholeMigration(fence, work, UpdateTrust.Production(), null);
            if (HelperDelivery.Fingerprint(fence, UpdateTrust.Production(), 3) != verified.Sha256) throw new IOException("Fixture helper proof did not validate");
        }
    }
    [STAThread]
    private static int Main(string[] args)
    {
        var root = Path.GetFullPath(AppDomain.CurrentDomain.BaseDirectory).TrimEnd(Path.DirectorySeparatorChar);
        if (!root.StartsWith(FixtureBoundary.Root, StringComparison.OrdinalIgnoreCase)) return 90;
        try {
            if (args.Length == 1 && args[0] == "--setup") { Setup(root); return 0; }
            if (args.Length == 1 && args[0] == "--resources") {
                foreach (var name in typeof(SteamLauncher).Assembly.GetManifestResourceNames()) {
                    if (name.StartsWith("BetterAstralParty.HelperBootstrap.", StringComparison.Ordinal)) throw new IOException("Legacy helper resource remains");
                    using (var input = typeof(SteamLauncher).Assembly.GetManifestResourceStream(name)!) {
                        if (input.ReadByte() == 77 && input.ReadByte() == 90) throw new IOException("Embedded PE remains");
                    }
                }
                File.WriteAllText(Path.Combine(root, "resource-result"), "NoLegacyHelperOrEmbeddedPE"); return 0;
            }
            if (args.Length == 1 && args[0] == "--probe") {
                try { using (SteamLauncher.GuardMaintenance(root)) File.WriteAllText(Path.Combine(root, "probe-result"), "Available"); }
                catch (ApplySafetyException error) { File.WriteAllText(Path.Combine(root, "probe-result"), error.Failure.ToString()); }
                return 0;
            }
            if (args.Length != 0) return 91;
            var before = Snapshot();
            using (var self = Process.GetCurrentProcess()) File.WriteAllText(Path.Combine(root, "host-identity"), self.Id + "\n" + self.StartTime.ToFileTimeUtc() + "\n" + self.SessionId + "\n");
            string details; var code = SteamLauncher.Run(root, out details);
            File.WriteAllText(Path.Combine(root, "host-result"), code + "\n" + Convert.ToBase64String(Encoding.UTF8.GetBytes(details)) + "\n" + (before == Snapshot() ? "ParentUnchanged" : "ParentChanged") + "\n");
            return code;
        } catch (Exception error) { File.WriteAllText(Path.Combine(root, "fixture-error"), error.ToString()); return 92; }
    }
}

