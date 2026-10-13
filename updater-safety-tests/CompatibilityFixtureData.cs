#nullable enable
using System;
using System.IO;
using System.Collections.Generic;
using System.Text;
using BetterAstralParty.Updating;
internal static class CompatibilityFixtureData
{
    private static Dictionary<string,byte[]> Files(byte[] inert) {
        var files=new Dictionary<string,byte[]>(StringComparer.Ordinal);
        foreach(var path in new[]{"GameAssembly.dll","UnityPlayer.dll","winhttp.dll","BepInEx/core/BepInEx.Core.dll","AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle","fixture-cache/catalog_fixture.json","fixture-cache/catalog_fixture.hash"}) files.Add(path,Encoding.ASCII.GetBytes("compatibility fixture "+path));
        files.Add("AstralParty_INT.exe",inert);var resource=new byte[32];Encoding.ASCII.GetBytes("UnityFS\0").CopyTo(resource,0);files.Add("AstralParty_INT_Data/data.unity3d",resource);return files;
    }
    internal static byte[] Manifest(byte[] inert) {
        var text=new StringBuilder("{\"schema\":1,\"cacheCatalogs\":[\"catalog_fixture.hash\",\"catalog_fixture.json\"],\"files\":[");var first=true;
        foreach(var file in Files(inert)) {if(!first)text.Append(',');first=false;var cache=file.Key.StartsWith("fixture-cache/",StringComparison.Ordinal);text.Append("{\"root\":\"").Append(cache?"cache":"game").Append("\",\"path\":\"").Append(cache?file.Key.Substring(14):file.Key).Append("\",\"kind\":\"fixture\",\"sha256\":\"").Append(UpdateTrust.Hash(file.Value)).Append("\"}");}
        return Encoding.ASCII.GetBytes(text.Append("]}").ToString());
    }
    internal static void Seed(string root,byte[] inert) {foreach(var file in Files(inert)) {var path=Path.Combine(root,file.Key);Directory.CreateDirectory(Path.GetDirectoryName(path)!);File.WriteAllBytes(path,file.Value);}}
}
