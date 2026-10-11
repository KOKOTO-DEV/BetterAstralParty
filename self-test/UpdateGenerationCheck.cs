using System.Text.Json;
using BetterAstralParty.Updating;

namespace BetterAstralParty;

internal static class UpdateGenerationCheck
{
    internal static byte[] Release(string version, string assets) => System.Text.Encoding.UTF8.GetBytes(
        "[{\"id\":123,\"draft\":false,\"prerelease\":false,\"tag_name\":\"" + version
        + "\",\"html_url\":\"https://github.com/" + ReleaseFeedPolicy.StableRepository + "/releases/tag/" + version
        + "\",\"assets\":" + assets + "}]");
    internal static string Assets(string version) => JsonSerializer.Serialize(new[] {
        new { id = 456, name = "BetterAstralParty-" + version + "-update.zip" },
        new { id = 457, name = ReleaseFeedPolicy.UpdateManifestAsset },
        new { id = 458, name = ReleaseFeedPolicy.UpdateSignatureAsset }
    });
    internal static int Run()
    {
        var checks = 0;
        void Check(bool value, string name) { if (!value) throw new Exception(name); checks++; }
        Check(ReleaseFeedPolicy.UpdateManifestAsset == "BetterAstralParty.update-v2.manifest"
            && ReleaseFeedPolicy.UpdateSignatureAsset == "BetterAstralParty.update-v2.signature", "exact second-generation discovery names");
        var manual = ReleaseUpdates.Select(ReleaseUpdates.Parse(Release("1.1.3", "[]"), ReleaseFeedPolicy.StableRepository), "1.1.2", ReleaseChannel.Stable);
        Check(manual?.Version == "1.1.3" && manual.DownloadRequest("1.1.2", ReleaseChannel.Stable) == null, "manual-only release stays available without a download");
        var good = Assets("1.1.4");
        using var tuple = JsonDocument.Parse(good);
        var malformed = new[] { "[]", good.Replace("458", "457"), good.Replace("458", "-1"), good.Replace("458", "0"),
            good.Replace("\"id\":458", "\"id\":\"458\""), good.Replace(ReleaseFeedPolicy.UpdateSignatureAsset, "wrong-name"),
            good[..^1] + "," + JsonSerializer.Serialize(new { id = 459, name = ReleaseFeedPolicy.UpdateManifestAsset }) + "]",
            good.Replace(ReleaseFeedPolicy.UpdateManifestAsset, "BetterAstralParty.update.manifest").Replace(ReleaseFeedPolicy.UpdateSignatureAsset, "BetterAstralParty.update.signature") }
            .Concat(Enumerable.Range(0, 3).Select(missing => JsonSerializer.Serialize(tuple.RootElement.EnumerateArray().Where((_, index) => index != missing))));
        foreach (var assets in new[] { good }.Concat(malformed)) {
            var available = ReleaseUpdates.Select(ReleaseUpdates.Parse(Release("1.1.4", assets), ReleaseFeedPolicy.StableRepository), "1.1.3", ReleaseChannel.Stable);
            Check(available?.Version == "1.1.4", "asset validation does not remove the update notice");
            Check((available!.DownloadRequest("1.1.3", ReleaseChannel.Stable) != null) == (assets == good), "new generation requires one complete exact asset tuple");
        }
        var future = ReleaseUpdates.Select(ReleaseUpdates.Parse(Release("1.1.5", Assets("1.1.5")), ReleaseFeedPolicy.StableRepository), "1.1.3", ReleaseChannel.Stable);
        Check(future?.DownloadRequest("1.1.3", ReleaseChannel.Stable)?.Context.ReleaseTag == "1.1.5", "manual upgrade enables later automatic targets without another bridge");
        Console.WriteLine($"Update generation: {checks} current-source discovery assertions passed.");
        return checks;
    }
}
