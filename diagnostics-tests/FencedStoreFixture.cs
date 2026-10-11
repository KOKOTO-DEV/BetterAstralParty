#nullable enable
using System;using System.IO;using System.Linq;using System.Collections.Generic;using System.Text;using System.Text.Json;using System.Diagnostics;using System.Runtime.InteropServices;
using BetterAstralParty.Observability;using BetterAstralParty.Diagnostics;using BetterAstralParty.Updating;
internal static class FencedStoreFixture {
 static readonly List<string> Cases=new();static string Base="";
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateHardLinkW(string next,string prior,IntPtr reserved);
 static void Check(bool v,string n){if(!v)throw new Exception("FAIL:"+n);Cases.Add(n);}
 static void Reject(Action a,string n){bool rejected=false;try{a();}catch{rejected=true;}Check(rejected,n);}
 static string Root(string n){var p=Path.Combine(Base,n);Directory.CreateDirectory(p);return p;}
 static string Event(){return SafeDiagnosticJson.Encode(new SafeDiagnosticEvent{Kind=DiagnosticKind.Stage,Feature=DiagnosticFeature.Helper,Phase=DiagnosticPhase.Apply,Outcome=DiagnosticOutcome.Begin,Utc=DateTimeOffset.UtcNow,EnqueuedStamp=Stopwatch.GetTimestamp()},new DiagnosticIdentity("1.0.0-rc.2",new string('A',32),"8.0.31"),1,Stopwatch.GetTimestamp());}
 static string Dir(string r)=>Path.Combine(r,"BepInEx/BetterAstralParty-Diagnostics/minimal-v1");
 static void Seed(string r){using(var f=new WindowsFileFence(r)){f.EnsureDirectory("BepInEx/BetterAstralParty-Diagnostics");f.CreatePrivateDirectory("BepInEx/BetterAstralParty-Diagnostics/minimal-v1");}}
 static string ReadLive(string p){using(var f=new FileStream(p,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))using(var t=new StreamReader(f))return t.ReadToEnd();}
 public static int Main(string[] args){
  Base=args[0];Directory.CreateDirectory(Base);var line=Event();Check(MinimalDiagnosticProjection.TryProject(line,out _),"producer fixed event accepted");
  var root=Root("normal");var path=Path.Combine(Dir(root),"events-current.jsonl");
  using(var store=new FencedDiagnosticEventStore(root)){
   Check(store.Previous().Outcome==DiagnosticOutcome.NotObserved,"new store no false previous success");store.Open();store.Append(line);store.Flush();
   Check(ReadLive(path).Trim()==line,"collector-compatible read while native writer alive");
   Reject(()=>{using var foreign=new FileStream(path,FileMode.Open,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete);},"foreign writer refused");
   Reject(()=>File.Delete(path),"foreign delete refused");Reject(()=>Directory.Move(root,root+"-renamed"),"root identity pinned");
   using(var other=new FencedDiagnosticEventStore(root))Reject(()=>other.Previous(),"second writer ownership refused");
   var id=new DiagnosticIdentity("1.0.0-rc.2",new string('A',32),"8.0.31");store.Mark(id,false,DiagnosticEndReason.Unknown);
   Reject(()=>File.WriteAllText(Path.Combine(Dir(root),"session.state"),"UNKNOWN"),"live marker protected");
   store.Rotate();Check(File.Exists(Path.Combine(Dir(root),"events-previous.jsonl")),"rotation archives own current");Check(ReadLive(path)=="","new current empty after rotation");
   store.Append(line);store.Flush();store.Mark(id,true,DiagnosticEndReason.OwnerDisposed);
  }
  using(var next=new FencedDiagnosticEventStore(root)){Check(next.Previous().Outcome==DiagnosticOutcome.Completed,"verified ended marker recognized");next.Open();next.Append(line);next.Flush();}
  var active=Root("active");using(var store=new FencedDiagnosticEventStore(active)){store.Previous();store.Open();store.Mark(new DiagnosticIdentity("1.0.0-rc.2",new string('A',32),"8.0.31"),false,DiagnosticEndReason.Unknown);}
  using(var next=new FencedDiagnosticEventStore(active))Check(next.Previous().Outcome==DiagnosticOutcome.IncompleteUnknown,"active marker means interruption unknown");
  var unknown=Root("unknown");Seed(unknown);var custom=Path.Combine(Dir(unknown),"events-current.jsonl");File.WriteAllText(custom,"FAKE_USER_SENTINEL");
  using(var store=new FencedDiagnosticEventStore(unknown)){store.Previous();Reject(()=>store.Open(),"unknown current blocks append");}Check(File.ReadAllText(custom)=="FAKE_USER_SENTINEL","unknown current bytes retained");
  var previous=Root("previous");Seed(previous);var prior=Path.Combine(Dir(previous),"events-previous.jsonl");File.WriteAllText(prior,"FAKE_OLD_SENTINEL");File.WriteAllText(Path.Combine(Dir(previous),"events-current.jsonl"),line+"\n");
  using(var store=new FencedDiagnosticEventStore(previous)){store.Previous();Reject(()=>store.Open(),"unknown previous blocks rotation");}Check(File.ReadAllText(prior)=="FAKE_OLD_SENTINEL" && File.ReadAllText(Path.Combine(Dir(previous),"events-current.jsonl"))==line+"\n","both unknown and current evidence retained");
  var marker=Root("marker");Seed(marker);var mp=Path.Combine(Dir(marker),"session.state");File.WriteAllText(mp,"FAKE_STATE_SENTINEL");
  using(var store=new FencedDiagnosticEventStore(marker)){Check(store.Previous().Outcome==DiagnosticOutcome.Unknown,"malformed marker reported unknown");store.Open();store.Mark(new DiagnosticIdentity("1.0.0-rc.2",new string('A',32),"8.0.31"),true,DiagnosticEndReason.OwnerDisposed);}
  Check(File.ReadAllText(mp)=="FAKE_STATE_SENTINEL","malformed marker not adopted");
  var locked=Root("unknown-lock");Seed(locked);File.WriteAllText(Path.Combine(Dir(locked),"writer.lock"),"FAKE_UNOWNED_LOCK");File.WriteAllText(Path.Combine(Dir(locked),"events-current.jsonl"),"FAKE_CURRENT");File.WriteAllText(Path.Combine(Dir(locked),"events-previous.jsonl"),"FAKE_PREVIOUS");
  using(var store=new FencedDiagnosticEventStore(locked)){Reject(()=>store.Previous(),"nonempty lock rejected");Reject(()=>store.Open(),"reentry cannot bypass failed ownership");}
  Check(File.ReadAllText(Path.Combine(Dir(locked),"events-current.jsonl"))=="FAKE_CURRENT" && File.ReadAllText(Path.Combine(Dir(locked),"events-previous.jsonl"))=="FAKE_PREVIOUS","unknown lock cannot change either event file");
  var damaged=Root("damaged-history");Seed(damaged);File.WriteAllText(Path.Combine(Dir(damaged),"session.state"),"FAKE_MARKER");File.WriteAllText(Path.Combine(Dir(damaged),"events-current.jsonl"),"FAKE_CURRENT");File.WriteAllText(Path.Combine(Dir(damaged),"events-previous.jsonl"),"FAKE_PREVIOUS");
  using(var store=new FencedDiagnosticEventStore(damaged)){Check(store.Previous().Outcome==DiagnosticOutcome.Unknown,"combined malformed history remains unknown");Reject(()=>store.Open(),"combined foreign current/previous refused");}
  Check(File.ReadAllText(Path.Combine(Dir(damaged),"session.state"))=="FAKE_MARKER" && File.ReadAllText(Path.Combine(Dir(damaged),"events-current.jsonl"))=="FAKE_CURRENT" && File.ReadAllText(Path.Combine(Dir(damaged),"events-previous.jsonl"))=="FAKE_PREVIOUS","combined marker and both unknown event files preserved");
  var hard=Root("hard");Seed(hard);var outside=Path.Combine(Base,"foreign.log");File.WriteAllText(outside,line+"\n");var hp=Path.Combine(Dir(hard),"events-current.jsonl");
  Check(CreateHardLinkW(hp,outside,IntPtr.Zero),"synthetic hardlink created");using(var store=new FencedDiagnosticEventStore(hard)){store.Previous();Reject(()=>store.Open(),"hardlinked current refused");}Check(File.ReadAllText(outside)==line+"\n","hardlink target unchanged");
  var linked=Root("linked");var foreign=Root("foreign-directory");var link=Path.Combine(linked,"BepInEx");var start=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"cmd.exe"),"/c mklink /J \""+link+"\" \""+foreign+"\""){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};using(var process=Process.Start(start)!){process.StandardOutput.ReadToEnd();process.StandardError.ReadToEnd();process.WaitForExit();Check(process.ExitCode==0,"synthetic junction created");}
  using(var store=new FencedDiagnosticEventStore(linked))Reject(()=>store.Previous(),"junction ancestor refused");Check(!Directory.EnumerateFileSystemEntries(foreign).Any(),"junction target untouched");
  var install=Root("installer");File.WriteAllText(Path.Combine(install,"AstralParty_INT.exe"),"INERT_NEVER_EXECUTED");Directory.CreateDirectory(Path.Combine(install,"AstralParty_INT_Data"));using(var store=new FencedDiagnosticEventStore(install,installer:true)){store.Previous();store.Open();store.Append(line);store.Flush();Check(File.Exists(Path.Combine(Dir(install),"installer/events-current.jsonl")),"installer fixed sink separated");
   var liveBundle=DiagnosticBundle.Collect(install,"","","",Path.Combine(Base,"live-hub"),Path.Combine(Base,"live-fallback"),"synthetic","1.0.0-rc.2");
   using(var zip=System.IO.Compression.ZipFile.OpenRead(liveBundle.ArchivePath)){Check(zip.GetEntry("logs/game-minimal-installer-current.log")!=null,"actual collector reads native live writer");}
   store.Append(line);store.Flush();Check(ReadLive(Path.Combine(Dir(install),"installer/events-current.jsonl")).Split('\n',StringSplitOptions.RemoveEmptyEntries).Length==2,"native writer remains writable after collection");
  }
  var bundle=DiagnosticBundle.Collect(install,"","","",Path.Combine(Base,"hub"),Path.Combine(Base,"fallback"),"synthetic","1.0.0-rc.2");
  using(var zip=System.IO.Compression.ZipFile.OpenRead(bundle.ArchivePath)){var entry=zip.Entries.Single(e=>e.FullName=="logs/game-minimal-installer-current.log");using var reader=new StreamReader(entry.Open());var collected=reader.ReadToEnd();Check(collected.Contains("\"phase\":\"Apply\"") && JsonDocument.Parse(collected.Split('\n',StringSplitOptions.RemoveEmptyEntries)[0]).RootElement.GetProperty("process_session").GetString()!=JsonDocument.Parse(line).RootElement.GetProperty("process_session").GetString(),"installer event collected with per-bundle alias");}
  File.WriteAllText(Path.Combine(Base,"results.json"),JsonSerializer.Serialize(new {passed=Cases.Count,cases=Cases,syntheticOnly=true,realLogsRead=false,gameSteamExecuted=false},new JsonSerializerOptions{WriteIndented=true}));Console.WriteLine("Fenced store checks passed:"+Cases.Count);return 0;
 }
}
