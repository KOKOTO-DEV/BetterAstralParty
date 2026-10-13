"""Extract the actual managed click path, with inert native/config boundaries. Never read logs."""
from pathlib import Path
import hashlib,json,re
root=Path(__file__).resolve().parents[1]
target=Path(__file__).parent/'ui-generated'
target.mkdir(exist_ok=True)
ui=(root/'src/ModUi.cs').read_text(encoding='utf-8-sig')
text=(root/'src/ModText.cs').read_text(encoding='utf-8-sig')
def method(signature):
    start=ui.index(signature);opening=ui.index('{',start);depth=0
    tokens=re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|@"(?:""|[^"])*"|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]')
    for m in tokens.finditer(ui,opening):
        if m.group()=='{':depth+=1
        elif m.group()=='}':
            depth-=1
            if depth==0:return ui[start:m.end()]
    raise ValueError(signature)
methods=[method('    private static void '+name) for name in ('HandleInput()', 'Apply(string action)', 'ApplyCore(string action)')]
refresh=ui[ui.index('        foreach (var (button, action) in Controls.Values)',ui.index('    private static void Refresh()')):ui.index('            if (action is "UpdateAuth"',ui.index('    private static void Refresh()'))]
prefix='''using BetterAstralParty.Observability; using System; using System.Linq; using System.Collections.Generic; using UnityEngine;
namespace BetterAstralParty;
internal static class ModUi {
internal static readonly Dictionary<IntPtr,(RuntimeObject Button,string Action)> Controls=new();
internal static readonly Dictionary<string,RuntimeObject> ToggleBackgrounds=new();
private static RuntimeObject? _dropdown;
private static RuntimeObject? _settingsView=new(),_settingsScroll=new();
private static float _scrollPosition,_changedAt;
private static IntPtr _pressed,_hovered;
private static bool _general=true;
private static string? _helpAction;
internal static string Help="";
internal static void Poll()=>HandleInput();
internal static void Redraw()=>Refresh();
internal static void Reset(){_pressed=_hovered=IntPtr.Zero;_scrollPosition=0;_settingsScroll!.Set("scrollingPosY",0f);_settingsScroll.Set("isDragged",false);}
internal static void Drag(bool v)=>_settingsScroll!.Set("isDragged",v);
private static void SetHelp(string action){Help=ModText.Text(MenuLayout.Help(action).Body);}
private static void TraceInput(string phase,IntPtr pointer){}
private static void ClosePanel(bool immediately=false){}
private static void HandleDropdown()=>throw new Exception("Unexpected dropdown");
private static void OpenDropdown(string action)=>throw new Exception("Unexpected dropdown");
'''
(target/'ManagedUi.cs').write_text(prefix+'\n'.join(methods)+'\nprivate static void Refresh(){\n'+refresh+'        }\n    }\n}\n',encoding='utf-8')
begin=text.index('    internal static bool Korean');end=text.index('    internal static string AutomaticStatus')
(target/'Catalog.cs').write_text('using System; using System.Linq; using System.Collections.Generic; using System.Text.RegularExpressions;\nnamespace BetterAstralParty;\ninternal static class ModText {\n'+text[begin:end]+'}\n',encoding='utf-8')
manifest={str(f.relative_to(root)).replace('\\','/'):hashlib.sha256(f.read_bytes()).hexdigest().upper() for f in [root/'src/ModUi.cs',root/'src/ModText.cs',root/'src/MenuLayout.cs',root/'src/DiagnosticActions.cs',root/'diagnostics/DiagnosticBundle.cs',root/'diagnostics/MinimalDiagnosticProjection.cs']}
(target/'inputs.json').write_text(json.dumps({'sourceHashes':manifest,'methodsUnchanged':['HandleInput','Apply','ApplyCore'],'refreshScope':'actual diagnostic branch only','nativeRenderTested':False,'shellDispatched':False},indent=2),encoding='utf-8')
print(json.dumps({'generated':str(target),'sources':len(manifest)}))
