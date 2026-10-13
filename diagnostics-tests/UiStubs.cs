using System;
using System.Collections.Generic;
using UnityEngine;
namespace UnityEngine {
internal struct Vector2 { internal float x,y; internal Vector2(float a,float b){x=a;y=b;} }
internal static class Input {internal static bool Down,Up;internal static bool GetMouseButtonDown(int n)=>Down;internal static bool GetMouseButtonUp(int n)=>Up;}
internal static class Time {internal static float unscaledTime=>1;}
}
namespace BepInEx {internal static class Paths {internal static string GameRootPath=>throw new Exception("Real discovery forbidden in fixture");}}
namespace BetterAstralParty {
internal sealed class RuntimeObject {
internal IntPtr Pointer;internal string Title="";internal static RuntimeObject Stage=new();
private readonly Dictionary<string,object> fields=new();private Vector2 point;
internal RuntimeObject(int id=0){Pointer=new IntPtr(id);}
internal T Get<T>(string key){if(key=="touchPosition")return (T)(object)point;return fields.TryGetValue(key,out var value)?(T)value:default!;}
internal void Set(string key,object value)=>fields[key]=value;
internal void Touch(float x,float y)=>point=new Vector2(x,y);
internal RuntimeObject? Call(string method,params object[] values){if(method=="GlobalToLocal"){var r=new RuntimeObject();r.point=(Vector2)values[0];return r;}return this;}
internal T Value<T>()=>(T)(object)point;
internal static object FindClass(string a,string b)=>new object();
internal static RuntimeObject StaticCall(object type,string method)=>Stage;
}
internal static class GameUi {internal static RuntimeObject[] Path=Array.Empty<RuntimeObject>();internal static IEnumerable<RuntimeObject> PointerPath()=>Path;}
internal static class NativeUi {internal static void Play(RuntimeObject b,string s){}internal static void StyleTitle(RuntimeObject b,string text,int size)=>b.Title=text;}
internal static class Compatibility {internal static bool Allow=true;internal static bool Allowed(string action)=>Allow;}
internal static class UpdateNotificationUi {internal static bool CanConfirmTransition=>false;internal static void BeginTransition(){}}
internal sealed class Setting<T> {internal T Value;internal Setting(T v){Value=v;}}
internal sealed class Writer {internal bool IsRecording=>true;internal void Write(string s){}internal void Error(string f,Exception e){}internal void Flush(){}}
internal sealed class Session {internal void Connect(object input,bool ko){}internal void SignOut(){}}
internal sealed class Updates {internal Uri RepositoryPage=>new("https://github.com/TSM701/BetterAstralParty/releases");internal void Check(DateTimeOffset now){}internal bool TryDownloadPage(out Uri? page){page=null;return false;}internal void DownloadFailed(){}}
internal sealed class Automatic {internal bool CanReactivate=>false;internal bool CanRecheck=>false;internal void Reactivate(){}internal void Recheck(){}internal void Download(DateTimeOffset now){}internal void Cancel(){}}
internal static class Plugin {
internal const string Version="1.0.0-rc.2";
internal static void RecordSettings(){}
internal static BetterAstralParty.Observability.MinimalEventLog? MinimalDiagnostics {get;set;}
internal static Writer Diagnostics=new();internal static Session? UpdateSession=new();internal static Updates Updates=new();internal static Automatic Automatic=new();
internal static Setting<string> Language=new("한국어"),HandExpandMode=new("Hover"),InputAttention=new("Off"),UpdateChannel=new("Stable");
internal static Setting<bool> GroupHand=new(false),AutoDownload=new(false),ApplyAfterExit=new(false),Enabled=new(false),ShowDetails=new(false),KoMinimum=new(false),UseRealNames=new(false),CardPopups=new(false),BattleStatus=new(false),ShushuShield=new(false),FieldBuffs=new(false),DiagnosticLogging=new(false),MuteUnfocused=new(false);
internal static Setting<bool> FieldZoom=new(true),MatchFocus=new(true);
internal static Setting<float> UiScale=new(1f),Opacity=new(1f);
}
internal sealed class WindowsReleaseCredentialInput {}
internal static class HandLayoutUi {internal static void Clear(){}}
internal static class InputAttention {internal static void Stop(){}}
internal static class InputAttentionState {internal static string Label(string v)=>v;}
internal static class CardDiceUi {internal static void Clear(){}}
internal static class ShushuShieldUi {internal static void Clear(){}}
internal static class FieldZoomUi {internal static int Clears;internal static void Clear(){Clears++;}}
}
