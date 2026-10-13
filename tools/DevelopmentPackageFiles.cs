#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using BetterAstralParty.Updating;

namespace BetterAstralParty.Packaging
{
    // Credential-free development tooling. Reuses the reviewed NTFS handle boundary.
    // Captured bytes and leases stay private until hash, IL review, copy and ZIP finish.
    public sealed class DevelopmentPackageFiles : IDisposable
    {
        private sealed class Source
        {
            internal readonly byte[] Bytes;
            internal readonly WindowsFileFence.FileLease Lease;
            internal readonly string Hash;
            internal Source(byte[] bytes, WindowsFileFence.FileLease lease) { Bytes = bytes; Lease = lease; Hash = UpdateTrust.Hash(bytes); }
        }
        private readonly WindowsFileFence _fence;
        private readonly Dictionary<string, Source> _sources = new Dictionary<string, Source>(StringComparer.Ordinal);
        private readonly Dictionary<string, byte[]> _written = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        private readonly Dictionary<string, WindowsFileFence.FileLease> _outputs = new Dictionary<string, WindowsFileFence.FileLease>(StringComparer.Ordinal);
        private string? _output;
        private bool _disposed;
        public DevelopmentPackageFiles(string root) { _fence = new WindowsFileFence(root); }
        public string RootIdentity { get { return _fence.RootIdentity.Text; } }
        public void Capture(string relative)
        {
            if (_disposed || _sources.ContainsKey(relative)) throw new InvalidOperationException("Invalid capture state");
            var lease = _fence.OpenFile(relative);
            try
            {
                const int max = 64 * 1024 * 1024;
                var stream = lease.Stream;
                if (stream.Length <= 0 || stream.Length > max) throw new InvalidDataException("Input size bound");
                var bytes = new byte[checked((int)stream.Length)]; var position = 0;
                while (position < bytes.Length)
                {
                    var count = stream.Read(bytes, position, bytes.Length - position);
                    if (count == 0) throw new InvalidDataException("Incomplete capture"); position += count;
                }
                if (stream.ReadByte() != -1) throw new InvalidDataException("Input size changed");
                lease.Recheck(); _sources.Add(relative, new Source(bytes, lease));
            }
            catch { lease.Dispose(); throw; }
        }
        public string SourceHash(string relative) { return _sources[relative].Hash; }
        public string SourceIdentity(string relative) { return _sources[relative].Lease.Identity.Text; }
        // The caller cannot mutate the captured private bytes used by CopySource.
        public byte[] ReviewBytes(string relative) { return (byte[])_sources[relative].Bytes.Clone(); }
        public string CreateOutput(string relative)
        {
            if (_disposed || _output != null) throw new InvalidOperationException("Invalid output state");
            var identity = _fence.CreatePrivateDirectory(relative); _output = relative; return identity.Text;
        }
        private string Output(string relative)
        {
            if (_disposed || _output == null) throw new InvalidOperationException("No output boundary");
            return _output + "/" + relative;
        }
        public string CreateSubdirectory(string relative) { return _fence.CreatePrivateDirectory(Output(relative)).Text; }
        public void CopySource(string source, string relative) { Write(relative, _sources[source].Bytes); }
        public void Write(string relative, byte[] bytes)
        {
            var path = Output(relative);
            if (bytes == null || bytes.Length > 64 * 1024 * 1024 || _outputs.ContainsKey(relative)) throw new InvalidDataException("Invalid output bytes");
            var snapshot = (byte[])bytes.Clone();
            var lease = _fence.OpenFile(path, true, true);
            try
            {
                lease.Stream.Write(snapshot, 0, snapshot.Length); lease.Flush();
                if (lease.Hash() != UpdateTrust.Hash(snapshot)) throw new InvalidDataException("Copied snapshot mismatch");
                _outputs.Add(relative, lease); _written.Add(relative, snapshot);
            }
            catch { lease.Dispose(); throw; }
        }
        public string OutputHash(string relative) { return _outputs[relative].Hash(); }
        public string Archive(string relative, string payloadDirectory) { return Archive(relative, payloadDirectory, false); }
        public string Archive(string relative, string payloadDirectory, bool reproducible)
        {
            var path = Output(relative); var prefix = payloadDirectory + "/";
            if (_outputs.ContainsKey(relative)) throw new InvalidOperationException("Output already exists");
            var lease = _fence.OpenFile(path, true, true);
            try
            {
                var entries = new SortedDictionary<string, byte[]>(StringComparer.Ordinal);
                foreach (var file in _written) if (file.Key.StartsWith(prefix, StringComparison.Ordinal)) entries.Add(file.Key.Substring(prefix.Length), file.Value);
                if (entries.Count == 0) throw new InvalidDataException("Empty review archive");
                using (var archive = new ZipArchive(lease.Stream, ZipArchiveMode.Create, true))
                    foreach (var entry in entries)
                    {
                        var item = archive.CreateEntry(entry.Key, CompressionLevel.Optimal);
                        if (reproducible) item.LastWriteTime = new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
                        using (var target = item.Open()) target.Write(entry.Value, 0, entry.Value.Length);
                    }
                lease.Flush(); _outputs.Add(relative, lease); return lease.Hash();
            }
            catch { lease.Dispose(); throw; }
        }
        public void Recheck()
        {
            _fence.Recheck(); foreach (var source in _sources.Values) source.Lease.Recheck(); foreach (var output in _outputs.Values) output.Recheck();
        }
        public void Dispose()
        {
            if (_disposed) return; _disposed = true;
            foreach (var output in _outputs.Values) output.Dispose();
            foreach (var source in _sources.Values) source.Lease.Dispose();
            _fence.Dispose(); _written.Clear(); _sources.Clear(); _outputs.Clear();
        }
    }
}
