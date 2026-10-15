// BetterAstralParty simple, offline, transparent installer for a local source build.
// Target: .NET Framework 4.8 (Windows-installed CSC). No elevation, network,
// services, PowerShell, dynamic code or background tasks.
using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Collections.Generic;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using Microsoft.Win32;
using System.Web.Script.Serialization;

internal static class BetterAstralPartySetup
{
    const string Marker = "BetterAstralParty.simple-install.txt";
    const string PluginPath = "BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll";
    const string ConfigPath = "BepInEx/config/kr.betterastralparty.mod.cfg";
    const string DesktopShortcutName = "BetterAstralParty_1.2.1.lnk";
    const int MaximumPayloadFiles = 2048; // BepInEx contains more than 150 verified dependency files.
    static readonly StringComparer PathCompare = StringComparer.OrdinalIgnoreCase;
    sealed class FileRow { public string Source, Target, Hash; public long Size; }
    public sealed class CompatibilityDocument {
        public int schema { get; set; }
        public List<CompatibilityFile> files { get; set; }
        public List<string> cacheCatalogs { get; set; }
    }
    public sealed class CompatibilityFile {
        public string root { get; set; }
        public string path { get; set; }
        public string sha256 { get; set; }
        public string kind { get; set; }
    }
    static string Root { get { return AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\'); } }

    // Windows Shell Link COM API. No PowerShell, WScript, administrator rights or
    // additional launcher processes are needed to create a real .lnk shortcut.
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class ShellLinkObject { }
    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int max, IntPtr findData, int flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder description, int max);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string description);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int max);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int max);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCommand);
        void SetShowCmd(int showCommand);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder iconPath, int max, out int iconIndex);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string iconPath, int iconIndex);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string relativePath, int reserved);
        void Resolve(IntPtr window, int flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }
    static string DesktopShortcutPath() {
        string desktop = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        if (string.IsNullOrEmpty(desktop) || !Directory.Exists(desktop))
            throw new Exception("Windows desktop directory was not found.");
        // DesktopDirectory is resolved by Windows and may legitimately be
        // redirected through OneDrive or a shell-folder junction.
        return Path.Combine(desktop, DesktopShortcutName);
    }
    static void CreateDesktopShortcut(string game, string shortcutPath) {
        if (File.Exists(shortcutPath) || Directory.Exists(shortcutPath))
            throw new Exception("Desktop shortcut path is already occupied.");
        IShellLinkW link = null;
        try {
            link = (IShellLinkW)new ShellLinkObject();
            link.SetPath(Target(game, "Launch-BAP.cmd"));
            link.SetWorkingDirectory(game);
            link.SetDescription("Launch Astral Party INT with BetterAstralParty");
            link.SetIconLocation(Target(game, "AstralParty_INT.exe"), 0);
            ((IPersistFile)link).Save(shortcutPath, true);
        } finally {
            if (link != null) Marshal.FinalReleaseComObject(link);
        }
        if (!File.Exists(shortcutPath)) throw new Exception("Desktop shortcut was not created.");
    }
    static bool DesktopShortcutTargetsGame(string shortcutPath, string game) {
        if (!File.Exists(shortcutPath)) return false;
        IShellLinkW link = null;
        try {
            link = (IShellLinkW)new ShellLinkObject();
            ((IPersistFile)link).Load(shortcutPath, 0);
            var path = new StringBuilder(32768);
            link.GetPath(path, path.Capacity, IntPtr.Zero, 0);
            return !string.IsNullOrWhiteSpace(path.ToString()) &&
                string.Equals(Full(path.ToString()), Full(Target(game, "Launch-BAP.cmd")), StringComparison.OrdinalIgnoreCase);
        } catch (Exception) { return false; }
        finally { if (link != null) Marshal.FinalReleaseComObject(link); }
    }

    static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;
        try {
            if (args.Length == 0 || (args[0] != "install" && args[0] != "uninstall" && args[0] != "force-uninstall" && args[0] != "launch"))
                throw new Exception("Usage: BetterAstralParty.Setup.exe install|uninstall|force-uninstall|launch [game-folder] [--keep-user-data]");
            string suppliedGame = null; bool keepUserData = false;
            for (int i = 1; i < args.Length; i++) {
                if (args[i] == "--keep-user-data" && args[0] == "force-uninstall") keepUserData = true;
                else if (suppliedGame == null && !args[i].StartsWith("--")) suppliedGame = args[i];
                else throw new Exception("Unexpected argument: " + args[i]);
            }
            string game = FindGame(suppliedGame);
            ValidateGame(game);
            if (args[0] == "install") Install(game);
            else if (args[0] == "uninstall") Uninstall(game);
            else if (args[0] == "launch") Launch(game);
            else ForceUninstall(game, keepUserData);
            return 0;
        } catch (Exception ex) {
            Console.Error.WriteLine("FAILED: " + ex.Message);
            return 1;
        }
    }

    static string Full(string path) { return Path.GetFullPath(path).TrimEnd('\\'); }
    static string Join(string baseDir, string relative) { return Path.Combine(baseDir, relative.Replace('/', Path.DirectorySeparatorChar)); }
    static bool IsLink(string path) {
        if (!File.Exists(path) && !Directory.Exists(path)) return false;
        return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
    }
    static void NoLinks(string path) {
        string current = Full(path);
        while (current != null) {
            if (IsLink(current)) throw new Exception("Junction/symlink not supported: " + current);
            string parent = Path.GetDirectoryName(current);
            if (string.IsNullOrEmpty(parent) || parent == current) break;
            current = parent;
        }
    }
    static bool SafeRelative(string path) {
        if (string.IsNullOrWhiteSpace(path) || path.IndexOfAny(new[] {'\\', ':', '\t', '\r', '\n', '\0'}) >= 0 || path[0] == '/') return false;
        string[] parts = path.Split('/');
        foreach (string part in parts) {
            if (part.Length == 0 || part == "." || part == ".." || part.EndsWith(".") || part.EndsWith(" ")) return false;
            if (Regex.IsMatch(part, @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)", RegexOptions.IgnoreCase)) return false;
        }
        return true;
    }
    static string Target(string root, string relative) {
        if (!SafeRelative(relative)) throw new Exception("Unsafe relative path: " + relative);
        string result = Full(Join(root, relative));
        if (!result.StartsWith(Full(root) + "\\", StringComparison.OrdinalIgnoreCase)) throw new Exception("Path outside game: " + relative);
        NoLinks(result);
        return result;
    }
    static string Hash(string path) {
        using (var sha = SHA256.Create()) using (var stream = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
    }
    static bool SameHash(string path, string expected) { return File.Exists(path) && string.Equals(Hash(path), expected, StringComparison.OrdinalIgnoreCase); }
    static void ValidateGame(string path) {
        if (!string.Equals(Path.GetFileName(path), "8vJXnINT", StringComparison.OrdinalIgnoreCase) || !File.Exists(Path.Combine(path, "AstralParty_INT.exe")))
            throw new Exception("Expected Astral Party INT folder (8vJXnINT): " + path);
        NoLinks(path);
        foreach (var process in Process.GetProcesses()) {
            try { if (process.ProcessName.Equals("AstralParty_INT", StringComparison.OrdinalIgnoreCase) ||
                      process.ProcessName.Equals("BetterAstralParty-Launcher", StringComparison.OrdinalIgnoreCase) ||
                      process.ProcessName.Equals("BetterAstralParty-UpdateHelper", StringComparison.OrdinalIgnoreCase))
                        throw new Exception("Close game, launcher and helper before modifying files."); }
            finally { process.Dispose(); }
        }
    }
    static IEnumerable<string> SteamInstallRoots() {
        var seen = new HashSet<string>(PathCompare);
        var found = new List<string>();
        foreach (RegistryHive hive in new[]{RegistryHive.CurrentUser, RegistryHive.LocalMachine}) {
            foreach (RegistryView view in new[]{RegistryView.Registry64, RegistryView.Registry32}) {
                try {
                    using(var baseKey = RegistryKey.OpenBaseKey(hive, view))
                    using(var key = baseKey.OpenSubKey(@"Software\Valve\Steam")) {
                        if (key != null) foreach (string name in new[]{"SteamPath", "InstallPath"}) {
                            string root = key.GetValue(name) as string;
                            if (!string.IsNullOrEmpty(root) && Directory.Exists(root) && seen.Add(Full(root))) found.Add(Full(root));
                        }
                    }
                } catch (System.Security.SecurityException) { } catch (UnauthorizedAccessException) { }
            }
        }
        foreach (string p in new[]{Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles)}) {
            if (string.IsNullOrEmpty(p)) continue;
            string root = Path.Combine(p, "Steam");
            if (Directory.Exists(root) && seen.Add(Full(root))) found.Add(Full(root));
        }
        return found;
    }
    static IEnumerable<string> SteamLibraries(string steam) {
        var found = new List<string>{steam};
        string vdf = Path.Combine(steam, @"steamapps\libraryfolders.vdf");
        if (!File.Exists(vdf)) return found;
        string content;
        try { content = File.ReadAllText(vdf); } catch (IOException) { return found; }
        foreach (Match m in Regex.Matches(content, "\"path\"\\s*\"([^\"]+)\"", RegexOptions.IgnoreCase)) {
            string lib = m.Groups[1].Value.Replace("\\\\", "\\");
            if (Directory.Exists(lib)) found.Add(Full(lib));
        }
        return found;
    }
    static string FindGame(string explicitPath) {
        if (!string.IsNullOrWhiteSpace(explicitPath)) return Full(explicitPath.Trim('"'));
        var found = new HashSet<string>(PathCompare);
        foreach (string steam in SteamInstallRoots()) foreach (string lib in SteamLibraries(steam)) {
            string candidate = Path.Combine(lib, @"steamapps\common\Astral Party\8vJXnINT");
            if (File.Exists(Path.Combine(candidate, "AstralParty_INT.exe"))) found.Add(Full(candidate));
        }
        if (found.Count == 1) { string only = found.First(); Console.WriteLine("Detected game: " + only); return only; }
        if (found.Count > 1) {
            string[] options = found.OrderBy(s=>s).ToArray();
            for (int i=0; i<options.Length; i++) Console.WriteLine((i+1).ToString() + ") " + options[i]);
            Console.Write("Select number, or enter full game folder: ");
            string typed = Console.ReadLine(); int selected;
            if (int.TryParse(typed, out selected) && selected > 0 && selected <= options.Length) return options[selected-1];
            if (!string.IsNullOrWhiteSpace(typed)) return Full(typed.Trim('"'));
            throw new Exception("Game selection cancelled.");
        }
        Console.Write("Game folder (8vJXnINT): ");
        string manual = Console.ReadLine();
        if (string.IsNullOrWhiteSpace(manual)) throw new Exception("No game folder provided.");
        return Full(manual.Trim('"'));
    }
    // The stock launcher completes a compatibility review and passes the
    // BAP_COMPATIBILITY_CHECKED gate. The simplified installer must do the
    // SAME review rather than blindly passing the flag (which disables the mod).
    // Reuse this already-built setup executable; ship no additional binary,
    // PowerShell bootstrap, elevation or code injection.
    static void VerifySimpleReceipt(string game) {
        var receipt = Target(game, Marker);
        if (!File.Exists(receipt)) throw new Exception("Local installation receipt missing. Reinstall the local package.");
        var lines = File.ReadAllLines(receipt, Encoding.UTF8);
        if (lines.Length < 5 || lines[0] != "BAP-SIMPLE-INSTALL/1") throw new Exception("Invalid local installation receipt.");
        var required = new[]{PluginPath, "BetterAstralParty.compatibility.json", "BetterAstralParty.Setup.exe"};
        foreach (string name in required) {
            var matches = lines.Where(l => l.StartsWith("OWNED\t" + name + "\t", StringComparison.OrdinalIgnoreCase)).ToArray();
            if (matches.Length != 1) throw new Exception("Local receipt does not own " + name);
            var cols = matches[0].Split('\t');
            if (cols.Length != 3 || !Regex.IsMatch(cols[2], @"^[A-Fa-f0-9]{64}$") || !SameHash(Target(game, name),cols[2]))
                throw new Exception("Installed component changed: " + name);
        }
        if (IsOfficialPresent(game)) throw new Exception("Conflicting original installation detected. Refusing local launch.");
    }
    // Content-only updates must not silently downgrade code or loader checks.
    // These are the ONLY paths permitted to drift from a reviewed SHA-256.
    static bool IsMutableContent(string key) {
        return key == "game/AstralParty_INT_Data/data.unity3d" ||
            key == "game/AstralParty_INT_Data/StreamingAssets/aa/settings.json" ||
            key == "game/AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle" ||
            key.StartsWith("cache/catalog_", StringComparison.Ordinal);
    }
    static Version CatalogVersion(string name) {
        var match = Regex.Match(name, @"^catalog_((?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8}))\.(?:json|hash)$");
        Version result;
        return match.Success && Version.TryParse(match.Groups[1].Value, out result) ? result : null;
    }
    static void CheckJson(string file, string key) {
        var info = new FileInfo(file);
        if (info.Length == 0 || info.Length > 64L * 1024 * 1024)
            throw new Exception("Invalid JSON content size: " + key);
        try {
            var value = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024, RecursionLimit = 256 }
                .DeserializeObject(File.ReadAllText(file, Encoding.UTF8));
            if (!(value is System.Collections.IDictionary)) throw new Exception("Not an object");
        } catch (Exception ex) { throw new Exception("Invalid JSON content: " + key, ex); }
    }
    static void CheckUnityFS(string source, string key) {
        using (var stream = File.OpenRead(source)) {
            byte[] header = new byte[8];
            if (stream.Length < 32 || stream.Read(header, 0, 8) != 8 ||
                Encoding.ASCII.GetString(header) != "UnityFS\0")
                throw new Exception("Invalid UnityFS bundle: " + key);
        }
    }
    static void CheckCatalogHash(string source, string key) {
        var info = new FileInfo(source);
        if (info.Length == 0 || info.Length > 4096)
            throw new Exception("Invalid catalog hash size: " + key);
        string value = File.ReadAllText(source, Encoding.UTF8).Trim();
        if (value.Length == 0 || value.Any(c => char.IsControl(c)))
            throw new Exception("Invalid catalog hash value: " + key);
    }
    static void CheckMutableContent(string source, string key) {
        if (key == "game/AstralParty_INT_Data/data.unity3d" ||
            key == "game/AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle") CheckUnityFS(source, key);
        else if (key == "game/AstralParty_INT_Data/StreamingAssets/aa/settings.json" ||
                 key.EndsWith(".json", StringComparison.Ordinal)) CheckJson(source, key);
        else if (key.EndsWith(".hash", StringComparison.Ordinal)) CheckCatalogHash(source, key);
        else throw new Exception("Unknown mutable content: " + key);
    }
    static void VerifyCatalogInventory(string cache, CompatibilityDocument manifest) {
        if (manifest.cacheCatalogs.Count != 2 || manifest.cacheCatalogs.Distinct(StringComparer.Ordinal).Count() != 2)
            throw new Exception("Expected one reviewed Addressables catalog pair.");
        var baseline = CatalogVersion(manifest.cacheCatalogs[0]);
        if (baseline == null || manifest.cacheCatalogs.Any(name => CatalogVersion(name) == null || CatalogVersion(name).CompareTo(baseline) != 0) ||
            !manifest.cacheCatalogs.Contains("catalog_" + baseline + ".json") ||
            !manifest.cacheCatalogs.Contains("catalog_" + baseline + ".hash"))
            throw new Exception("Invalid reviewed catalog names.");
        if (!Directory.Exists(cache)) throw new Exception("Addressables cache unavailable: " + cache);
        var actual = Directory.GetFiles(cache).Select(Path.GetFileName)
            .Where(name => Regex.IsMatch(name, @"^catalog.*\.(json|hash)$", RegexOptions.IgnoreCase))
            .ToArray();
        if (actual.Length > 512 || actual.Distinct(StringComparer.Ordinal).Count() != actual.Length ||
            actual.Any(name => CatalogVersion(name) == null))
            throw new Exception("Malformed Addressables catalog inventory.");
        var completed = actual.Select(CatalogVersion).Distinct().Where(version =>
            actual.Contains("catalog_" + version + ".json") &&
            actual.Contains("catalog_" + version + ".hash")).OrderByDescending(version => version).ToArray();
        if (completed.Length == 0 || completed[0].CompareTo(baseline) < 0)
            throw new Exception("No complete current Addressables catalog pair.");
        var active = completed[0];
        foreach (var ext in new[] { ".json", ".hash" }) {
            var name = "catalog_" + active + ext;
            CheckMutableContent(Target(cache, name), "cache/" + name);
        }
        if (active.CompareTo(baseline) > 0)
            Console.WriteLine("Warning: newer Addressables catalog " + active + "; runtime feature guards remain enabled.");
        foreach (var name in actual) {
            var version = CatalogVersion(name);
            if (version.CompareTo(active) > 0)
                Console.WriteLine("Warning: incomplete newer catalog is downloading: " + name);
        }
    }
    static void VerifyCompatibleGame(string game) {
        string path = Target(game,"BetterAstralParty.compatibility.json");
        var manifest = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 }
            .Deserialize<CompatibilityDocument>(File.ReadAllText(path, Encoding.UTF8));
        if (manifest == null || manifest.schema != 1 || manifest.files == null || manifest.files.Count < 5 ||
            manifest.files.Count > 512 || manifest.cacheCatalogs == null || manifest.cacheCatalogs.Count > 128)
            throw new Exception("Invalid original compatibility manifest.");
        string cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            @"AppData\LocalLow\feimo\AstralParty_INT\com.unity.addressables");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var file in manifest.files) {
            if (file == null || (file.root != "game" && file.root != "cache") ||
                !SafeRelative(file.path) || file.sha256 == null || !Regex.IsMatch(file.sha256,@"^[A-Fa-f0-9]{64}$"))
                throw new Exception("Unsafe compatibility entry.");
            string key = file.root + "/" + file.path;
            if (!seen.Add(key)) throw new Exception("Duplicate compatibility entry: " + key);
            if (file.root == "cache" && CatalogVersion(file.path) == null)
                throw new Exception("Unexpected catalog baseline name: " + key);
            string source = Target(file.root == "game" ? game : cache, file.path);
            if (!File.Exists(source)) {
                // A newer COMPLETE pair may supersede an old downloaded pair.
                // Mandatory local game and loader files are NEVER optional.
                if (file.root == "cache") continue;
                throw new Exception("Missing game/runtime file: " + key);
            }
            bool same = SameHash(source, file.sha256);
            // Reviewed exact files need no re-parsing; validate resource structure
            // whenever an advisory content update arrives.
            if (key == "game/AstralParty_INT_Data/data.unity3d" ||
                (IsMutableContent(key) && !same)) CheckMutableContent(source, key);
            if (!same) {
                if (IsMutableContent(key))
                    Console.WriteLine("Warning: content hash changed (not executable): " + key);
                else throw new Exception("Game executable / loader / metadata changed; review required: " + key);
            }
        }
        foreach (string required in new[]{"game/AstralParty_INT.exe","game/GameAssembly.dll","game/UnityPlayer.dll",
            "game/winhttp.dll","game/AstralParty_INT_Data/il2cpp_data/Metadata/global-metadata.dat",
            "game/AstralParty_INT_Data/StreamingAssets/aa/settings.json",
            "game/AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle",
            "game/AstralParty_INT_Data/data.unity3d"})
            if (!seen.Contains(required)) throw new Exception("Incomplete compatibility manifest: " + required);
        foreach (var name in manifest.cacheCatalogs)
            if (!seen.Contains("cache/" + name)) throw new Exception("Missing reviewed cache manifest entry: " + name);
        VerifyCatalogInventory(cache, manifest);
    }
    static void Launch(string game) {
        if (!string.Equals(Full(game),Full(Root),StringComparison.OrdinalIgnoreCase))
            throw new Exception("The local launcher must run from the installed game folder.");
        VerifySimpleReceipt(game);
        VerifyCompatibleGame(game);
        Console.WriteLine("Compatibility review PASS. Starting BetterAstralParty...");
        var start = new ProcessStartInfo {
            FileName = Path.Combine(game,"AstralParty_INT.exe"),
            Arguments = "--doorstop-enabled true --bap-compatibility-checked",
            WorkingDirectory = game,
            UseShellExecute = false
        };
        foreach (var name in new[]{"SteamAppId","SteamGameId","SteamOverlayGameId"})
            start.EnvironmentVariables[name] = "2622000";
        start.EnvironmentVariables["BAP_COMPATIBILITY_CHECKED"] = "1";
        // The Windows .NET Framework CSC used for the offline installer is C# 5.
        // Use an ordinary null check; the old compiler does not support throw expressions.
        using (var child = Process.Start(start)) {
            if (child == null) throw new Exception("Game did not start.");
            child.WaitForExit();
            if (child.ExitCode != 0) throw new Exception("Game process exited with code "+child.ExitCode);
        }
    }
    static bool AllowedTarget(string relative) {
        return relative==PluginPath || relative=="Launch-BAP.cmd" || relative=="BetterAstralParty.Setup.exe" ||
               relative=="BetterAstralParty.compatibility.json" ||
               relative=="winhttp.dll" || relative=="doorstop_config.ini" ||
               relative==".doorstop_version" || relative=="changelog.txt" ||
               Regex.IsMatch(relative,@"^BepInEx/core/[^/]+\.(dll|config)$",RegexOptions.IgnoreCase) ||
               Regex.IsMatch(relative,@"^dotnet/[^/]+\.(dll|json)$",RegexOptions.IgnoreCase) ||
               relative=="dotnet/.version";
    }
    static List<FileRow> ReadPayload() {
        string path = Path.Combine(Root, "PAYLOAD-MANIFEST.tsv");
        if (!File.Exists(path)) throw new Exception("Package manifest missing.");
        var rows = new List<FileRow>(); var seen = new HashSet<string>(PathCompare);
        foreach(string text in File.ReadAllLines(path, new UTF8Encoding(false))) {
            if (text.Length==0 || text.StartsWith("#")) continue;
            string[] parts = text.Split('\t');
            long size;
            if (parts.Length!=4 || !SafeRelative(parts[0]) || !SafeRelative(parts[1]) ||
                !Regex.IsMatch(parts[2], "^[A-Fa-f0-9]{64}$") || !long.TryParse(parts[3],out size) || size < 0 || size > 250000000)
                throw new Exception("Malformed payload manifest.");
            if (!AllowedTarget(parts[1])) throw new Exception("Not a BetterAstralParty installer target: " + parts[1]);
            if (!seen.Add(parts[1])) throw new Exception("Duplicate target: " + parts[1]);
            string source = Target(Root, parts[0]);
            if (!File.Exists(source) || new FileInfo(source).Length != size || !SameHash(source,parts[2]))
                throw new Exception("Payload SHA-256 mismatch: " + parts[0]);
            rows.Add(new FileRow{Source=source,Target=parts[1],Hash=parts[2].ToUpperInvariant(),Size=size});
        }
        if (rows.Count < 5 || !rows.Any(r => r.Target == PluginPath) || !rows.Any(r => r.Target == "winhttp.dll"))
            throw new Exception("Incomplete payload manifest: " + rows.Count + " entries; required plugin or winhttp.dll missing.");
        if (rows.Count > MaximumPayloadFiles)
            throw new Exception("Payload manifest entry limit exceeded: " + rows.Count + " (maximum " + MaximumPayloadFiles + ").");
        Console.WriteLine("Verified payload manifest: " + rows.Count + " files (SHA-256 checked).");
        return rows;
    }
    static bool IsOfficialPresent(string game) {
        return new[]{"BetterAstralParty.install.json", "BetterAstralParty-Launcher.exe", "BetterAstralParty.helper.receipt", "BetterAstralParty-UpdateHelper.exe", "BetterAstralParty.reinstall-v3.pending"}.Any(p=>File.Exists(Target(game,p)));
    }
    static byte[] ConfigWithoutAutoUpdates(byte[] original) {
        string content = original==null ? "" : Encoding.UTF8.GetString(original).TrimStart('\uFEFF');
        var lines = content.Split(new[]{"\r\n","\n"},StringSplitOptions.None).ToList();
        int sectionStart=-1, sectionEnd=lines.Count;
        for(int i=0;i<lines.Count;i++) {
            var m=Regex.Match(lines[i],@"^\s*\[(.+?)\]\s*$");
            if (!m.Success) continue;
            if (sectionStart>=0) { sectionEnd=i; break; }
            if (m.Groups[1].Value=="업데이트") sectionStart=i;
        }
        if (sectionStart<0) { if(lines.Count>0 && lines[lines.Count-1]!="") lines.Add(""); lines.Add("[업데이트]"); sectionStart=lines.Count-1; sectionEnd=lines.Count; }
        bool dl=false, apply=false;
        for(int i=sectionStart+1;i<sectionEnd;i++) {
            if (Regex.IsMatch(lines[i],@"^\s*자동 다운로드\s*=")) { if(dl) throw new Exception("Duplicate auto-download setting."); dl=true;lines[i]="자동 다운로드 = false"; }
            if (Regex.IsMatch(lines[i],@"^\s*종료 후 적용\s*=")) { if(apply) throw new Exception("Duplicate apply-after-exit setting."); apply=true;lines[i]="종료 후 적용 = false"; }
        }
        if(!dl) lines.Insert(sectionEnd++,"자동 다운로드 = false");
        if(!apply) lines.Insert(sectionEnd++,"종료 후 적용 = false");
        return new UTF8Encoding(false).GetBytes(string.Join("\r\n",lines));
    }
    static void Install(string game) {
        if (IsOfficialPresent(game)) throw new Exception("Official installation/recovery markers detected. First run the original uninstaller. No changes made.");
        if (File.Exists(Target(game,Marker)) || File.Exists(Target(game,PluginPath))) throw new Exception("BetterAstralParty already present; uninstall first. No changes made.");
        var rows=ReadPayload();
        var create = new List<FileRow>();
        foreach(var row in rows) {
            string destination=Target(game,row.Target);
            if (File.Exists(destination)) {
                // A shared loader file is left untouched only if it is exactly the pinned expected content.
                if (row.Target==PluginPath || !SameHash(destination,row.Hash))
                    throw new Exception("Existing file conflict (no overwrite): " + destination);
            } else create.Add(row);
        }
        string config=Target(game,ConfigPath);
        if(File.Exists(config) && new FileInfo(config).Length>131072) throw new Exception("Existing config too large; no changes made.");
        byte[] oldCfg=File.Exists(config)?File.ReadAllBytes(config):null;
        byte[] newCfg=ConfigWithoutAutoUpdates(oldCfg);
        Console.WriteLine("\nBetterAstralParty local simple installation (not official GA)");
        Console.WriteLine("Game: " + game);
        Console.WriteLine("Create " + create.Count + " files; leave matching shared loader files unchanged.");
        Console.WriteLine("Auto update OFF; no admin elevation, Steam/registry changes, downloads, or background service.");
        // Install.cmd is an explicit user action.  Preflight checks and SHA-256
        // verification have already completed, so no typed token is needed.
        var copied=new List<string>(); bool cfgTouched=false;
        string createdShortcutPath = null, createdShortcutHash = null;
        try {
            foreach(var row in create) {
                string dest=Target(game,row.Target);
                Directory.CreateDirectory(Path.GetDirectoryName(dest));NoLinks(Path.GetDirectoryName(dest));
                using(var src=File.OpenRead(row.Source)) using(var dst=File.Open(dest,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                    copied.Add(dest);
                    src.CopyTo(dst);
                }
                if(!SameHash(dest,row.Hash)) throw new Exception("Copy verification failed: " + row.Target);
            }
            Directory.CreateDirectory(Path.GetDirectoryName(config));
            cfgTouched=true;File.WriteAllBytes(config,newCfg);
            var receipt = new List<string>{"BAP-SIMPLE-INSTALL/1", "CONFIG_BEFORE\t" + (oldCfg==null?"-":Convert.ToBase64String(oldCfg)), "CONFIG_AFTER\t" + Hash(config)};
            foreach(var row in create) receipt.Add("OWNED\t" + row.Target + "\t" + row.Hash);
            // Desktop shortcut is optional: a locked/redirected desktop must not
            // prevent a verified game installation from succeeding.
            try {
                string desktopLink = DesktopShortcutPath();
                if (File.Exists(desktopLink) || Directory.Exists(desktopLink)) {
                    Console.WriteLine("Desktop shortcut already exists; leaving it unchanged: " + desktopLink);
                } else {
                    CreateDesktopShortcut(game, desktopLink);
                    createdShortcutPath = desktopLink;
                    createdShortcutHash = Hash(desktopLink);
                    receipt.Add("DESKTOP_SHORTCUT_SHA256\t" + createdShortcutHash);
                    Console.WriteLine("Desktop shortcut created: " + desktopLink);
                }
            } catch (Exception ex) {
                // A shortcut is not essential to the installed mod. If a link
                // was partially created, remove it only if it targets our CMD.
                try {
                    string partial = DesktopShortcutPath();
                    if (createdShortcutPath == null && DesktopShortcutTargetsGame(partial, game)) File.Delete(partial);
                } catch (Exception) { }
                Console.WriteLine("WARNING: Desktop shortcut could not be created: " + ex.Message);
            }
            File.WriteAllLines(Target(game,Marker),receipt.ToArray(),new UTF8Encoding(false));
            Console.WriteLine("INSTALLED. Launch via the desktop shortcut or Launch-BAP.cmd in the game folder.");
        } catch {
            if (createdShortcutPath != null && SameHash(createdShortcutPath, createdShortcutHash))
                try { File.Delete(createdShortcutPath); } catch (Exception) { }
            foreach(string dest in copied.AsEnumerable().Reverse()) try {File.Delete(dest);}catch{}
            if (cfgTouched) { if(oldCfg==null) try{File.Delete(config);}catch{} else File.WriteAllBytes(config,oldCfg); }
            throw;
        }
    }
    static void Uninstall(string game) {
        string receiptFile=Target(game,Marker);
        if(!File.Exists(receiptFile)) throw new Exception("Local simple install receipt absent; nothing removed.");
        var lines=File.ReadAllLines(receiptFile,Encoding.UTF8);
        if(lines.Length<4 || lines[0]!="BAP-SIMPLE-INSTALL/1") throw new Exception("Invalid local receipt.");
        var owned=new List<FileRow>(); var seen=new HashSet<string>(PathCompare);
        string configBefore=null, configAfter=null, shortcutHash=null;
        foreach(string line in lines.Skip(1)) {
            string[] p=line.Split('\t');
            if (p.Length==2 && p[0]=="CONFIG_BEFORE") configBefore=p[1];
            else if(p.Length==2 && p[0]=="CONFIG_AFTER") configAfter=p[1];
            else if(p.Length==2 && p[0]=="DESKTOP_SHORTCUT_SHA256" && shortcutHash==null &&
                    Regex.IsMatch(p[1], "^[A-Fa-f0-9]{64}$")) shortcutHash=p[1];
            else if(p.Length==3 && p[0]=="OWNED" && SafeRelative(p[1]) && Regex.IsMatch(p[2],"^[A-Fa-f0-9]{64}$") && seen.Add(p[1])) {
                if (!AllowedTarget(p[1]))
                    throw new Exception("Unrecognized receipt file: " + p[1]);
                owned.Add(new FileRow{Target=p[1],Hash=p[2]});
            } else throw new Exception("Malformed receipt record; nothing removed.");
        }
        if(configBefore==null || !Regex.IsMatch(configAfter??"","^[A-Fa-f0-9]{64}$") || owned.Count<3) throw new Exception("Incomplete receipt.");
        var changed=new List<string>();
        foreach(var row in owned) if(!SameHash(Target(game,row.Target),row.Hash)) changed.Add(row.Target);
        if(changed.Count>0) throw new Exception("Changed or missing owned files; abort without deleting: " + string.Join(", ",changed));
        string config=Target(game,ConfigPath);
        bool restoreCfg=SameHash(config,configAfter);
        Console.WriteLine("Remove " + owned.Count + " unchanged local-owned files. Game, other mods, shared pre-existing loader and modified config are preserved.");
        Console.Write("Continue standard removal? [y/N]: ");
        string answer = Console.ReadLine();
        if (!string.Equals(answer, "y", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(answer, "yes", StringComparison.OrdinalIgnoreCase)) {
            Console.WriteLine("Cancelled; no files removed."); return;
        }
        // Receipt-bound shortcuts are removed only when still unchanged and
        // still pointing at this exact game installation.
        if (shortcutHash != null) {
            try {
                string link=DesktopShortcutPath();
                if (SameHash(link,shortcutHash) && DesktopShortcutTargetsGame(link,game)) {
                    File.Delete(link); Console.WriteLine("Removed desktop shortcut: " + link);
                } else if (File.Exists(link)) Console.WriteLine("Desktop shortcut changed; preserved: " + link);
            } catch (Exception ex) { Console.WriteLine("Desktop shortcut preserved: " + ex.Message); }
        }
        foreach(var row in owned) File.Delete(Target(game,row.Target));
        if(restoreCfg) { if(configBefore=="-") File.Delete(config); else File.WriteAllBytes(config,Convert.FromBase64String(configBefore)); }
        File.Delete(receiptFile);
        Console.WriteLine("REMOVED. Empty folders and user-modified config preserved.");
    }
    // Fixed, mod-specific allowlist: never read deletion targets from a possibly
    // corrupted receipt or from the install ZIP.  Shared BepInEx/doorstop files
    // are deliberately preserved because other mods may depend on them.
    static readonly string[] ForceFiles = new[] {
        Marker, "Launch-BAP.cmd", "BetterAstralParty.Setup.exe", "BetterAstralParty.install.json",
        "BetterAstralParty-Launcher.exe", "BetterAstralParty-UpdateHelper.exe",
        "BetterAstralParty.helper.receipt", "BetterAstralParty.compatibility.json",
        "BetterAstralParty-Mod.cmd", "AstralParty-Vanilla.cmd",
        "BetterAstralParty-Steam.ps1", "check-compatibility.ps1",
        "steam-shortcut.ps1", "BetterAstralParty.update-v3.version",
        "BetterAstralParty.update.lock", "BetterAstralParty.reinstall-v3.pending",
        "BetterAstralParty-Compatibility.log", "BetterAstralParty-LaunchError.log",
        ConfigPath
    };
    static readonly string[] ForceDirectories = new[] {
        "BepInEx/plugins/BetterAstralParty", "BepInEx/BetterAstralParty-Diagnostics"
    };
    static void CheckOwnedTree(string directory) {
        NoLinks(directory);
        if (!Directory.Exists(directory)) return;
        foreach (string entry in Directory.GetFileSystemEntries(directory)) {
            NoLinks(entry);
            if (Directory.Exists(entry)) CheckOwnedTree(entry);
        }
    }
    static void DeleteOwnedTree(string directory) {
        NoLinks(directory);
        if (!Directory.Exists(directory)) return;
        // Do not pass recursive deletion through an unchecked junction.
        foreach (string entry in Directory.GetFileSystemEntries(directory)) {
            NoLinks(entry);
            if (Directory.Exists(entry)) DeleteOwnedTree(entry);
            else File.Delete(entry);
        }
        Directory.Delete(directory, false);
    }
    static void ForceUninstall(string game, bool keepUserData) {
        var files = new List<string>(); var directories = new List<string>();
        foreach (string relative in ForceFiles) {
            string path = Target(game, relative);
            if (File.Exists(path)) files.Add(path);
        }
        foreach (string relative in ForceDirectories) {
            string path = Target(game, relative);
            if (Directory.Exists(path)) { CheckOwnedTree(path); directories.Add(path); }
        }
        foreach (string path in Directory.GetFiles(game)) {
            string name = Path.GetFileName(path);
            if (Regex.IsMatch(name,
                @"^BetterAstralParty\.(?:reinstall-v3\.completed-|update-v3\.version\.uninstalled-)[A-Za-z0-9_-]{1,100}$",
                RegexOptions.IgnoreCase)) {
                Target(game, name);
                files.Add(path);
            }
        }
        // Force removal may not have a receipt; inspect the link's actual target
        // rather than trusting the filename or deleting unrelated desktop links.
        try {
            string link=DesktopShortcutPath();
            if (DesktopShortcutTargetsGame(link,game)) files.Add(link);
            else if (File.Exists(link)) Console.WriteLine("Unrelated/modified desktop shortcut preserved: " + link);
        } catch (Exception ex) { Console.WriteLine("Desktop shortcut not inspected: " + ex.Message); }
        string localData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "BetterAstralParty");
        // A nonstandard path, root, or reparse point must never be removed.
        if (!keepUserData && Directory.Exists(localData)) {
            if (Path.GetFileName(Full(localData)) != "BetterAstralParty")
                throw new Exception("Unexpected user data directory; nothing removed.");
            CheckOwnedTree(localData);
            directories.Add(localData);
        }
        if (files.Count == 0 && directories.Count == 0) {
            Console.WriteLine("No BetterAstralParty-specific files found. Shared BepInEx files were preserved."); return;
        }
        Console.WriteLine("\nBETTERASTRALPARTY FORCE UNINSTALL - PERMANENT DELETION");
        Console.WriteLine("Game: " + game);
        foreach (string path in files) Console.WriteLine("DELETE FILE: " + path);
        foreach (string path in directories) Console.WriteLine("DELETE TREE: " + path);
        Console.WriteLine("PRESERVED: game assets, unrelated plugins, shared BepInEx/doorstop loader, unrelated Steam/desktop shortcuts.");
        if (keepUserData) Console.WriteLine("PRESERVED: LocalAppData BetterAstralParty logs, settings and recovery backups.");
        else Console.WriteLine("WARNING: listed LocalAppData includes logs, settings and recovery BACKUPS.");
        Console.Write("Delete all listed BetterAstralParty data? [y/N]: ");
        string confirmation = Console.ReadLine();
        if (!string.Equals(confirmation,"y",StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(confirmation,"yes",StringComparison.OrdinalIgnoreCase)) {
            Console.WriteLine("Cancelled; no files removed."); return;
        }
        ValidateGame(game); // recheck active processes immediately before changing files
        foreach (string path in files) NoLinks(path);
        foreach (string path in directories) CheckOwnedTree(path);
        var errors = new List<string>();
        foreach (string path in files) {
            try { if (File.Exists(path)) { File.Delete(path); Console.WriteLine("DELETED: " + path); } }
            catch (Exception ex) { errors.Add(path + " : " + ex.Message); }
        }
        foreach (string path in directories) {
            try { if (Directory.Exists(path)) { DeleteOwnedTree(path); Console.WriteLine("DELETED: " + path); } }
            catch (Exception ex) { errors.Add(path + " : " + ex.Message); }
        }
        if (errors.Count > 0) throw new Exception("Partial removal (no ACL/AV bypass):\n" + string.Join("\n", errors));
        Console.WriteLine("FORCE REMOVAL COMPLETE. Game and shared loader remain untouched.");
    }

}
