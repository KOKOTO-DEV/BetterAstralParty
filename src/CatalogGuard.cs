using System.Security.Cryptography;
using System.Text.Json;

namespace BetterAstralParty;

// Downloaded catalogs can change after the launcher check, during login.
internal sealed class CatalogGuard
{
    private readonly string _root;
    private readonly Dictionary<string, string> _expected = new(StringComparer.OrdinalIgnoreCase);
    private readonly bool _pinnedSettings;
    private DateTime _nextCheck;
    private Task? _pending;

    internal CatalogGuard(string manifest, string root)
    {
        _root = root;
        using var json = JsonDocument.Parse(File.ReadAllText(manifest));
        foreach (var entry in json.RootElement.GetProperty("files").EnumerateArray())
        {
            if (entry.GetProperty("root").GetString() == "game" && entry.GetProperty("path").GetString() == "AstralParty_INT_Data/StreamingAssets/aa/settings.json") _pinnedSettings = true;
            if (entry.GetProperty("root").GetString() != "cache") continue;
            var name = entry.GetProperty("path").GetString()!;
            if (Path.GetFileName(name) != name || name.Contains('\\') || name.Contains(':'))
                throw new InvalidDataException("Invalid catalog path");
            _expected.Add(name, entry.GetProperty("sha256").GetString()!);
        }
        if (_expected.Count == 0) throw new InvalidDataException("Catalog baseline missing");
    }

    internal void Verify(DateTime now)
    {
        if (now < _nextCheck) return;
        var files = Directory.EnumerateFiles(_root, "catalog*")
            .Where(path => string.Equals(Path.GetExtension(path), ".json", StringComparison.OrdinalIgnoreCase) || string.Equals(Path.GetExtension(path), ".hash", StringComparison.OrdinalIgnoreCase)).Take(513).ToArray();
        if ((!_pinnedSettings && files.Length != _expected.Count) || !Updating.CatalogInventory.Matches(_expected.Keys.ToArray(), files.Select(path => Path.GetFileName(path)!).ToArray()))
            throw new InvalidDataException("Downloaded catalog inventory changed");
        foreach (var entry in _expected)
        {
            using var stream = File.OpenRead(Path.Combine(_root, entry.Key));
            using var sha = SHA256.Create();
            if (!string.Equals(Convert.ToHexString(sha.ComputeHash(stream)), entry.Value, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Downloaded catalog changed; review required");
        }
        // No AssetBundles scan or automatic baseline updates.
        _nextCheck = now.AddSeconds(10);
    }

    // Startup still uses synchronous Verify. Later full hashes use one worker;
    // observe failures on the UI thread so the existing circuit breaker owns cleanup.
    internal void Poll(DateTime now)
    {
        if (_pending != null)
        {
            if (!_pending.IsCompleted) return;
            _pending.GetAwaiter().GetResult();
            _pending = null;
        }
        if (now < _nextCheck) return;
        _pending = Task.Run(() => Verify(now));
    }
}
