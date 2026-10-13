using System.Text;
using System.Text.Json;
using System.IO.Compression;
using BetterAstralParty;
using BetterAstralParty.Diagnostics;
using UnityEngine;

// Actual managed input/routing methods are extracted unchanged; native objects and configuration are inert.
var root=Path.Combine(Path.GetTempPath(),"bap-diag-b2-ui-"+Guid.NewGuid().ToString("N")[..8]);
var game=Path.Combine(root,"g");Directory.CreateDirectory(Path.Combine(game,"AstralParty_INT_Data"));
File.WriteAllText(Path.Combine(game,"AstralParty_INT.exe"),"inert fixture, never run");
var log=Path.Combine(game,"BepInEx","BetterAstralParty-Diagnostics","current.log");Directory.CreateDirectory(Path.GetDirectoryName(log)!);
File.WriteAllText(log,"phase=7\n");
var minimal=Path.Combine(game,"BepInEx","BetterAstralParty-Diagnostics","minimal-v1","events-current.jsonl");
Directory.CreateDirectory(Path.GetDirectoryName(minimal)!);
string Event(string kind,int sequence)=>JsonSerializer.Serialize(new{schema="bap.minimal-diagnostic/v1",process_session=new string('a',32),sequence,utc="2026-10-04T10:00:00.0000000+00:00",elapsed_ms=25,mod_version="1.0.0-rc.2",build_id=new string('A',32),runtime_version="6.0.36",kind,feature="Settings",phase="UiAction",outcome=kind=="Failure"?"Failed":"Begin",code=kind=="Failure"?"Unknown":"None",ui_action="General",error_site=kind=="Failure"?"ModUiApply":"None",error_type=kind=="Failure"?"Unknown":"None",operation=new string('b',32),related_operation="-",target_version="unknown",update_state="Unknown",count=1,secondary_count=0,native_code=0,validation_code=0,apply_code=0},new JsonSerializerOptions{Encoder=System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping});
File.WriteAllText(minimal,Event("Stage",1)+"\n"+Event("Failure",2)+"\n");
var minimalHash=System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(minimal));
var checks=new List<string>();void Check(bool ok,string name){if(!ok)throw new Exception(name);checks.Add(name);}
BundleResult Collect()=>DiagnosticBundle.Collect(game,"","","",Path.Combine(root,"hub"),Path.Combine(root,"hub2"),"6.0");
var open=new RuntimeObject(1);var collect=new RuntimeObject(2);
ModUi.Controls.Add(open.Pointer,(open,"DiagnosticsOpen"));ModUi.Controls.Add(collect.Pointer,(collect,"DiagnosticsCollect"));
ModUi.ToggleBackgrounds.Add("DiagnosticsOpen",new());ModUi.ToggleBackgrounds.Add("DiagnosticsCollect",new());
RuntimeObject.Stage.Touch(100,100);ModUi.Reset();ModText.Select("한국어");
void Frame(RuntimeObject? hit,bool down,bool up){GameUi.Path=hit==null?Array.Empty<RuntimeObject>():new[]{hit};Input.Down=down;Input.Up=up;ModUi.Poll();}
void Click(RuntimeObject hit){Frame(hit,true,false);Frame(hit,false,true);}
int opens=0,prepares=0,collections=0;bool held=false;BundleResult? result=null;
using var gate=new ManualResetEventSlim();using var started=new ManualResetEventSlim();
var controller=new DiagnosticActionController(()=>{prepares++;return ()=>{Interlocked.Increment(ref collections);started.Set();if(!gate.Wait(TimeSpan.FromSeconds(10)))throw new Exception("fixture gate timeout");return result=Collect();};},
    ()=>{using var lease=DiagnosticBundle.AcquireHub(Path.Combine(root,"open"),Path.Combine(root,"open2"));lease.Open(path=>opens++);},
    bundle=>bundle.OpenFolder(path=>{opens++;try{Directory.Move(path,path+"-unexpected");}catch(IOException){held=true;}}));
DiagnosticActions.UseFixture(controller);ModUi.Redraw();Click(open);
Check(opens==1,"Open button down/up invokes real ApplyCore and fenced adapter");
Check(MenuLayout.GeneralControl("DiagnosticsOpen")&&MenuLayout.GeneralControl("DiagnosticsCollect")&&MenuLayout.Options("DiagnosticsCollect").Length==0,"diagnostic actions remain normal general controls");
Frame(open,false,true);Check(opens==1,"release without press cannot trigger action");
Click(collect);Check(started.Wait(TimeSpan.FromSeconds(5)),"collect worker started from real button click");
Check(controller.Busy&&controller.StatusCode==1&&prepares==1,"click reaches real busy status before worker completes");
ModUi.Redraw();Check(collect.Get<bool>("grayed")&&ModUi.ToggleBackgrounds["DiagnosticsCollect"].Get<bool>("grayed")&&!open.Get<bool>("grayed"),"actual refresh branch disables collect while busy");
Check(collect.Title.Contains("진단 ZIP 만드는 중")&&ModUi.Help.Contains("직접 첨부"),"Korean busy title and sharing help use actual catalog");
Click(open);Check(opens==2&&controller.StatusCode==1,"opening hub during collection preserves Creating status");
Click(collect);DiagnosticActions.CreateBundle();Check(prepares==1&&collections==1,"disabled click and adapter CAS both prevent duplicate worker");
ModText.Select("English");ModUi.Redraw();Check(collect.Title.Contains("Creating ZIP")&&!collect.Title.Contains("진단"),"English busy title uses actual catalog after language switch");
gate.Set();controller.Pending.GetAwaiter().GetResult();ModUi.Redraw();
Check(!controller.Busy&&controller.StatusCode==2&&opens==3&&held&&File.Exists(result!.ArchivePath),"successful real bundle creation opens committed folder while pinned");
using(var archive=ZipFile.OpenRead(result!.ArchivePath))
{
    using var reader=new StreamReader(archive.GetEntry("logs/game-minimal-current.log")!.Open());
    var raw=reader.ReadToEnd();var lines=raw.Split('\n',StringSplitOptions.RemoveEmptyEntries).Select(line=>JsonDocument.Parse(line)).ToArray();
    Check(lines.Length==2&&lines[1].RootElement.GetProperty("error_type").GetString()=="Unknown"&&lines[1].RootElement.GetProperty("error_site").GetString()=="ModUiApply","net6 in-game route retains structured stage and Unknown failure/site in ZIP");
    Check(!raw.Contains(new string('a',32))&&!raw.Contains(new string('b',32))&&lines[0].RootElement.GetProperty("operation").GetString()==lines[1].RootElement.GetProperty("operation").GetString(),"net6 projection aliases identities while preserving operation relations");
    foreach(var line in lines)line.Dispose();
}
Check(!collect.Get<bool>("grayed")&&collect.Title.Contains("ZIP Created"),"success refresh reenables collection and displays English success");
ModText.Select("한국어");ModUi.Redraw();Check(collect.Title.Contains("진단 ZIP 생성됨"),"success status switches back to Korean");
var failed=new DiagnosticActionController(()=>()=>throw new IOException("FAKE_PRIVATE_ERROR"),()=>{},_=>{});DiagnosticActions.UseFixture(failed);Click(collect);failed.Pending.GetAwaiter().GetResult();ModUi.Redraw();
Check(!failed.Busy&&failed.StatusCode==3&&collect.Title.Contains("진단 ZIP 생성 실패"),"collection failure displays Korean failure and releases busy");
ModText.Select("English");ModUi.Redraw();Check(collect.Title.Contains("ZIP Failed"),"collection failure has English translation");
Check(ModText.Text(MenuLayout.Help("DiagnosticsCollect").Body).Contains("attach")&&!ModText.Text(MenuLayout.Help("DiagnosticsCollect").Body).Contains("개인정보"),"sharing help has English translation from actual catalog");
var prepareFailed=new DiagnosticActionController(()=>throw new IOException("FAKE_FLUSH_FAILURE"),()=>{},_=>{});DiagnosticActions.UseFixture(prepareFailed);Click(collect);ModUi.Redraw();
Check(!prepareFailed.Busy&&prepareFailed.StatusCode==3&&!collect.Get<bool>("grayed"),"synchronous prepare/flush failure cannot leave busy stuck");
BundleResult? saved=null;var openFailed=new DiagnosticActionController(()=>()=>saved=Collect(),()=>throw new IOException("fake opener"),_=>throw new IOException("fake opener"));
DiagnosticActions.UseFixture(openFailed);Click(collect);openFailed.Pending.GetAwaiter().GetResult();ModUi.Redraw();
Check(!openFailed.Busy&&openFailed.StatusCode==4&&File.Exists(saved!.ArchivePath)&&collect.Title.Contains("Could Not Open Folder"),"shell dispatch failure preserves created ZIP and has distinct English status");
ModText.Select("한국어");ModUi.Redraw();Check(collect.Title.Contains("진단 폴더 열기 실패"),"folder failure has Korean translation");
int calls=0;var routing=new DiagnosticActionController(()=>()=>Collect(),()=>calls++,_=>{});DiagnosticActions.UseFixture(routing);ModUi.Redraw();
Frame(open,true,false);ModUi.Drag(true);Frame(open,false,true);ModUi.Drag(false);Check(calls==0,"drag between press/release cancels action through real HandleInput");
RuntimeObject.Stage.Touch(-1,100);Click(open);Check(calls==0,"outside settings viewport prevents diagnostic button action");
RuntimeObject.Stage.Touch(100,100);Compatibility.Allow=false;Click(open);Compatibility.Allow=true;Check(calls==0,"compatibility rejection respected by actual ApplyCore");
Click(open);Check(calls==1&&routing.StatusCode==0,"valid later click opens folder and clears stale status");
// New preferences exercise the extracted production ApplyCore, with only camera cleanup inert.
var focus=new RuntimeObject(3);var zoom=new RuntimeObject(4);var features=new RuntimeObject(5);var general=new RuntimeObject(6);
ModUi.Controls.Add(focus.Pointer,(focus,"MatchFocus"));ModUi.Controls.Add(zoom.Pointer,(zoom,"FieldZoom"));
ModUi.Controls.Add(features.Pointer,(features,"Features"));ModUi.Controls.Add(general.Pointer,(general,"General"));
Check(Plugin.MatchFocus.Value&&Plugin.FieldZoom.Value,"new fixture preferences begin ON");
ModUi.Redraw();Check(focus.Get<bool>("visible")&&!zoom.Get<bool>("visible"),"production tab visibility puts focus in General only");
Click(focus);Check(!Plugin.MatchFocus.Value&&Plugin.FieldZoom.Value,"production focus toggle does not change wheel zoom");
Click(focus);Check(Plugin.MatchFocus.Value,"focus OFF control remains clickable to enable");
Click(features);Check(!focus.Get<bool>("visible")&&zoom.Get<bool>("visible"),"production tab visibility puts wheel zoom in Features only");
Click(zoom);Check(!Plugin.FieldZoom.Value&&FieldZoomUi.Clears==1&&Plugin.MatchFocus.Value,"wheel zoom OFF immediately clears owned presentation only");
Click(zoom);Check(Plugin.FieldZoom.Value&&FieldZoomUi.Clears==1,"wheel zoom ON does not perform extra cleanup");
Compatibility.Allow=false;Click(zoom);Compatibility.Allow=true;
Check(Plugin.FieldZoom.Value&&FieldZoomUi.Clears==1,"compatibility rejection prevents wheel zoom setting mutation");
Click(general);Check(focus.Get<bool>("visible")&&!zoom.Get<bool>("visible"),"returning to General restores correct distinct tabs");
Check(File.ReadAllText(log)=="phase=7\n","UI collection preserves synthetic source bytes");
Check(minimalHash.SequenceEqual(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(minimal))),"UI collection preserves structured source bytes");
// Actual production Apply emits typed events; collection flushes on its worker.
var live=Path.Combine(root,"live");Directory.CreateDirectory(Path.Combine(live,"AstralParty_INT_Data"));File.WriteAllText(Path.Combine(live,"AstralParty_INT.exe"),"inert never run");
string CurrentSession(string dir){using var file=new FileStream(Path.Combine(dir,"events-current.jsonl"),FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete);using var reader=new StreamReader(file);using var json=JsonDocument.Parse(reader.ReadLine()!);return json.RootElement.GetProperty("process_session").GetString()!;}
var liveDir=Path.Combine(live,"BepInEx","BetterAstralParty-Diagnostics","minimal-v1");
using(var producer=BetterAstralParty.Observability.MinimalEventLog.Start(liveDir,"1.0.0-rc.2",new string('A',32))){
 var deadline=DateTime.UtcNow.AddSeconds(5);while(!producer.Recording && !producer.StorageFailed && DateTime.UtcNow<deadline)Thread.Sleep(10);
 Check(producer.Recording,"actual typed producer ready in synthetic UI route");
 Check(BetterAstralParty.Observability.DiagnosticHub.Bind(producer),"actual UI producer bound");Plugin.MinimalDiagnostics=producer;BundleResult? liveResult=null;
 var liveController=new DiagnosticActionController(()=>()=>{producer.FlushBoundary(50);return liveResult=DiagnosticBundle.Collect(live,"","","",Path.Combine(root,"live-hub"),Path.Combine(root,"live-fallback"),"synthetic",Plugin.Version);},()=>{},_=>{});
 DiagnosticActions.UseFixture(liveController);ModUi.Redraw();Click(collect);liveController.Pending.GetAwaiter().GetResult();Check(liveController.StatusCode==2 && liveResult!=null,"actual Apply DiagnosticsCollect emits and creates ZIP");
 using(var zip=ZipFile.OpenRead(liveResult!.ArchivePath)){using var reader=new StreamReader(zip.GetEntry("logs/game-minimal-current.log")!.Open());var raw=reader.ReadToEnd();Check(raw.Contains("\"ui_action\":\"DiagnosticsCollect\"") && raw.Contains("\"outcome\":\"Begin\""),"real UI producer event reaches actual ZIP");Check(!raw.Contains(CurrentSession(liveDir)),"UI producer session replaced by bundle-local alias");}
 BetterAstralParty.Observability.DiagnosticHub.Unbind(producer);Plugin.MinimalDiagnostics=null;producer.Stop(BetterAstralParty.Observability.DiagnosticEndReason.OwnerDisposed);
}
var report=JsonSerializer.Serialize(new{runtime=Environment.Version.ToString(),passed=checks.Count,cases=checks,scratch=root,actualManagedMethods=new[]{"HandleInput","Apply","ApplyCore"},refreshScope="diagnostic branch",nativeUiRendered=false,shellDispatched=false,realLogsRead=false,realGameRun=false,upload=false},new JsonSerializerOptions{WriteIndented=true});
File.WriteAllText(Path.Combine(root,"test-results.json"),report,new UTF8Encoding(false));Console.WriteLine(report);
