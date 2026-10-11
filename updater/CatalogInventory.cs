#nullable enable
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace BetterAstralParty.Updating {
    internal static class CatalogInventory {
        private static Version? Number(string name) {
            var match=Regex.Match(name,@"\Acatalog_((?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8}))\.(?:json|hash)\z");
            Version? value;return match.Success && Version.TryParse(match.Groups[1].Value,out value)?value:null;
        }
        internal static bool Matches(string[] expected,string[] actual) {
            if(expected.Length>128 || actual.Length>512)return false;
            var required=new HashSet<string>(expected,StringComparer.Ordinal);
            var present=new HashSet<string>(actual,StringComparer.Ordinal);
            if(required.Count!=expected.Length || present.Count!=actual.Length || !required.IsSubsetOf(present))return false;
            var extra=present.Except(required).ToArray();if(extra.Length==0)return true;
            // Pinned Addressables settings select an exact cache pair, not every old file in its directory.
            if(expected.Length!=2)return false;
            var active=Number(expected[0]);if(active==null || Number(expected[1])!=active)return false;
            var stem="catalog_"+active;
            if(!required.Contains(stem+".json") || !required.Contains(stem+".hash"))return false;
            foreach(var name in extra){var version=Number(name);if(version==null || version.CompareTo(active)>=0)return false;}
            return true;
        }
    }
}
