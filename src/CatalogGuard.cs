using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace BetterAstralParty;

// PC 3.3.0+: a verified native/runtime baseline is enforced by the launcher.
// Addressables data can be refreshed without changing GameAssembly or IL2CPP
// metadata. This guard validates its shape and flags drift; it never changes
// the signed updater's independent safety decisions.
internal sealed class CatalogGuard
{
    private readonly string _root;
    private readonly Dictionary<string, string> _expected = new(StringComparer.Ordinal);
    private readonly HashSet<string> _warned = new(StringComparer.Ordinal);
    internal event Action<string>? Warning;
    private readonly Version _baseline;
    private DateTime _nextCheck;
    private Task? _pending;

    private static readonly Regex CatalogName = new(
        @"\Acatalog_((?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8}))\.(json|hash)\z",
        RegexOptions.CultureInvariant);

    internal CatalogGuard(string manifest, string root)
    {
        _root = root;
        using var json = JsonDocument.Parse(File.ReadAllText(manifest));
        foreach (var entry in json.RootElement.GetProperty("files").EnumerateArray())
        {
            if (entry.GetProperty("root").GetString() != "cache") continue;
            var name = entry.GetProperty("path").GetString() ?? "";
            if (!ValidVersion(name, out _)) throw new InvalidDataException("Invalid catalog baseline name");
            var hash = entry.GetProperty("sha256").GetString() ?? "";
            if (!Regex.IsMatch(hash, @"\A[A-Fa-f0-9]{64}\z"))
                throw new InvalidDataException("Invalid catalog baseline digest");
            _expected.Add(name, hash);
        }
        if (_expected.Count != 2) throw new InvalidDataException("One catalog baseline pair required");
        var first = _expected.Keys.First();
        if (!ValidVersion(first, out var baseline) ||
            !_expected.ContainsKey("catalog_" + baseline + ".json") ||
            !_expected.ContainsKey("catalog_" + baseline + ".hash"))
            throw new InvalidDataException("Invalid catalog baseline pair");
        _baseline = baseline;
    }

    private static bool ValidVersion(string name, out Version version)
    {
        var match = CatalogName.Match(name);
        var ok = Version.TryParse(match.Success ? match.Groups[1].Value : null, out var parsed);
        version = parsed ?? new Version(0, 0, 0);
        return ok;
    }

    private void WarnOnce(string key, string detail)
    {
        if (_warned.Add(key))
        {
            Warning?.Invoke(detail);
        }
    }

    private static void VerifyJson(string path)
    {
        var length = new FileInfo(path).Length;
        if (length <= 0 || length > 64L * 1024 * 1024)
            throw new InvalidDataException("Invalid catalog JSON size: " + Path.GetFileName(path));
        using var file = File.OpenRead(path);
        using var document = JsonDocument.Parse(file);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new InvalidDataException("Invalid catalog JSON object: " + Path.GetFileName(path));
    }

    private static void VerifyHash(string path)
    {
        var length = new FileInfo(path).Length;
        if (length <= 0 || length > 4096)
            throw new InvalidDataException("Invalid catalog hash size: " + Path.GetFileName(path));
        var value = File.ReadAllText(path).Trim();
        if (value.Length == 0 || value.Any(char.IsControl))
            throw new InvalidDataException("Invalid catalog hash content: " + Path.GetFileName(path));
    }

    internal void Verify(DateTime now)
    {
        if (now < _nextCheck) return;
        if (!Directory.Exists(_root)) throw new InvalidDataException("Addressables catalog directory missing");
        var files = Directory.EnumerateFiles(_root, "catalog*")
            .Where(path => string.Equals(Path.GetExtension(path), ".json", StringComparison.OrdinalIgnoreCase) ||
                           string.Equals(Path.GetExtension(path), ".hash", StringComparison.OrdinalIgnoreCase))
            .Take(513).ToArray();
        if (files.Length > 512) throw new InvalidDataException("Too many Addressables catalog files");
        var names = files.Select(path => Path.GetFileName(path)!).ToArray();
        if (names.Distinct(StringComparer.Ordinal).Count() != names.Length ||
            names.Any(name => !ValidVersion(name!, out _)))
            throw new InvalidDataException("Malformed Addressables catalog name");
        var versions = names.Select(name => { ValidVersion(name!, out var version); return version; })
            .Distinct().OrderByDescending(version => version).ToArray();
        var active = versions.FirstOrDefault(version =>
            names.Contains("catalog_" + version + ".json", StringComparer.Ordinal) &&
            names.Contains("catalog_" + version + ".hash", StringComparer.Ordinal));
        if (active == null || active.CompareTo(_baseline) < 0)
            throw new InvalidDataException("Missing complete current Addressables catalog pair");
        var jsonPath = Path.Combine(_root, "catalog_" + active + ".json");
        var hashPath = Path.Combine(_root, "catalog_" + active + ".hash");
        VerifyJson(jsonPath);
        VerifyHash(hashPath);
        if (active.CompareTo(_baseline) > 0)
            WarnOnce("version:" + active, "Newer catalog " + active + " loaded with runtime/UI guards; native runtime baseline still required");
        foreach (var entry in _expected)
        {
            var path = Path.Combine(_root, entry.Key);
            if (!File.Exists(path))
            {
                if (active.CompareTo(_baseline) == 0)
                    throw new InvalidDataException("Missing reviewed Addressables catalog: " + entry.Key);
                WarnOnce("removed:" + entry.Key, "Superseded catalog missing: " + entry.Key);
                continue;
            }
            using var stream = File.OpenRead(path);
            using var sha = SHA256.Create();
            if (!string.Equals(Convert.ToHexString(sha.ComputeHash(stream)), entry.Value, StringComparison.OrdinalIgnoreCase))
                WarnOnce("drift:" + entry.Key, "Catalog content hash changed: " + entry.Key);
        }
        foreach (var version in versions.Where(version => version.CompareTo(active) > 0))
            WarnOnce("incomplete:" + version, "Incomplete next catalog pair detected: " + version);
        _nextCheck = now.AddSeconds(10);
    }

    // Later checks run in one worker and errors are still observed on the UI
    // thread, so existing per-feature compatibility cleanups remain active.
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
