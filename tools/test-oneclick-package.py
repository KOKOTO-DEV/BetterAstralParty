"""Synthetic offline tests; do not claim runtime/game verification."""
import importlib.util, pathlib, tempfile, json, hashlib, os, stat, zipfile, shutil
P=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('oneclick',P/'oneclick-package.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def sha(d):return hashlib.sha256(d).hexdigest().upper()
def write(base,name,blob):
    path=base/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(blob)
def fixture(t):
    b=t/'export';r=t/'release'; b.mkdir();r.mkdir()
    plugin=b'compiled test plugin'
    write(b,'plugin/BetterAstralParty.dll',plugin)
    write(b,'local-build-manifest.json',json.dumps({'schema':1,'containsInstaller':False,'artifacts':[{'path':'plugin/BetterAstralParty.dll','sha256':sha(plugin),'size':len(plugin)}]}).encode())
    names={'.deps/bepinex/winhttp.dll':b'w',
          '.deps/bepinex/doorstop_config.ini':b'd',
          '.deps/bepinex/BepInEx/core/BepInEx.Core.dll':b'c',
          '.deps/bepinex/BepInEx/core/BepInEx.Unity.IL2CPP.dll':b'i',
          'artifacts/BetterAstralParty.compatibility.json':b'{}'}
    for n,raw in names.items():write(r,n,raw)
    write(r,'package-manifest.json',json.dumps({'schema':1,'version':'1.2.1','files':[{'path':n,'sha256':sha(raw),'bytes':len(raw)} for n,raw in names.items()]}).encode())
    compiler=t/'fake-csc'
    compiler.write_text('#!/usr/bin/env python3\nimport sys,pathlib\nfor a in sys.argv:\n if a.startswith("/out:"):\n  pathlib.Path(a[5:]).write_bytes(b"synthetic exe, not executable")\n  break\n',encoding='utf-8')
    compiler.chmod(compiler.stat().st_mode|stat.S_IXUSR)
    return b,r,compiler

def test():
    with tempfile.TemporaryDirectory() as td:
        t=pathlib.Path(td);b,r,c=fixture(t)
        o=t/'valid.zip'
        m.prepare(b,r,o,c,None)
        assert o.exists()
        with zipfile.ZipFile(o) as z:
            names=set(z.namelist())
            assert {'Install.cmd','Uninstall.cmd','Force-Uninstall.cmd','BetterAstralParty.Setup.exe','PAYLOAD-MANIFEST.tsv','payload/BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll','payload/winhttp.dll','payload/BetterAstralParty.Setup.exe'} <=names
            assert b'compiled test plugin'==z.read('payload/BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll')
            assert z.read('BetterAstralParty.Setup.exe')==z.read('payload/BetterAstralParty.Setup.exe'), 'Installer/launcher engine must match'
            assert b'ExecutionPolicy Bypass' not in z.read('Install.cmd')
            assert b'force-uninstall' in z.read('Force-Uninstall.cmd')
            assert b'powershell.exe' not in z.read('Force-Uninstall.cmd').lower()
            assert b'UpdateHelper' not in z.read('PAYLOAD-MANIFEST.tsv')
        print('PASS: valid ZIP, SHA256 payloads, no PowerShell bootstrap/helper')
        # Regression: a real BepInEx payload can include more than 150 files.
        d=json.loads((r/'package-manifest.json').read_text())
        for i in range(160):
            path='.deps/bepinex/BepInEx/core/Extra%03d.dll' % i
            raw=('original-loader-fixture-%03d' % i).encode('ascii')
            write(r,path,raw)
            d['files'].append({'path':path,'sha256':sha(raw),'bytes':len(raw)})
        write(r,'package-manifest.json',json.dumps(d).encode())
        full=t/'over150.zip'
        m.prepare(b,r,full,c,None)
        with zipfile.ZipFile(full) as z:
            lines=[s for s in z.read('PAYLOAD-MANIFEST.tsv').decode('utf-8').splitlines() if s and not s.startswith('#')]
            assert len(lines)==168, 'Unexpected manifest entry count: %d' % len(lines)
            assert len(lines)<=m.MAX_PAYLOAD_FILES
        installer_source=(m.ROOT/'simple-installer/BetterAstralParty.Setup.cs').read_text(encoding='utf-8')
        # The installer is compiled with Windows .NET Framework CSC (C# 5).
        # No C# 7 throw-expression may be introduced in the launch path.
        assert 'using (var child = Process.Start(start))' in installer_source
        assert 'if (child == null) throw new Exception("Game did not start.");' in installer_source
        assert not __import__('re').search(r'\?\?\s*throw\b', installer_source)
        package_source=(m.ROOT/'tools/oneclick-package.py').read_text(encoding='utf-8')
        assert "'/langversion:5'" in package_source
        assert 'const int MaximumPayloadFiles = 2048' in installer_source
        assert 'rows.Count>150' not in installer_source
        assert 'Type INSTALL' not in installer_source
        assert 'VerifyCompatibleGame(game)' in installer_source
        assert 'BAP_COMPATIBILITY_CHECKED' in installer_source
        launcher=(m.ROOT/'simple-installer/Launch-BAP.cmd').read_text(encoding='utf-8')
        assert 'BetterAstralParty.Setup.exe' in launcher and ' launch ' in launcher
        assert '--doorstop-enabled true' not in launcher, 'Only vetted installer can set launch gate'
        assert 'ForceUninstall(game, keepUserData)' in installer_source
        # R6.5: a real Windows .lnk is created by the normal installer, rather
        # than copying the CMD to the desktop (which would break %~dp0).
        assert 'Environment.SpecialFolder.DesktopDirectory' in installer_source
        assert 'DesktopShortcutName = "BetterAstralParty_1.2.1.lnk"' in installer_source
        assert 'link.SetPath(Target(game, "Launch-BAP.cmd"))' in installer_source
        assert '((IPersistFile)link).Save(shortcutPath, true)' in installer_source
        assert 'DESKTOP_SHORTCUT_SHA256' in installer_source
        assert 'DesktopShortcutTargetsGame(link,game)' in installer_source
        assert 'WScript.Shell' not in installer_source
        print('PASS: 168 verified entries supported consistently by packager and installer source')
        for i in range(160):
            (r/('.deps/bepinex/BepInEx/core/Extra%03d.dll' % i)).unlink()
        d['files']=[x for x in d['files'] if not x['path'].startswith('.deps/bepinex/BepInEx/core/Extra')]
        write(r,'package-manifest.json',json.dumps(d).encode())
        # Tampered original release file
        write(r,'.deps/bepinex/winhttp.dll',b'e')
        try: m.prepare(b,r,t/'tamper.zip',c,None)
        except m.RepackError:print('PASS: reject modified original loader')
        else:raise AssertionError('Tampered loader unexpectedly accepted')
        write(r,'.deps/bepinex/winhttp.dll',b'w')
        # Tampered compiled DLL
        write(b,'plugin/BetterAstralParty.dll',b'altered')
        try: m.prepare(b,r,t/'badplugin.zip',c,None)
        except m.RepackError:print('PASS: reject modified compiled DLL')
        else:raise AssertionError('Tampered DLL unexpectedly accepted')
        write(b,'plugin/BetterAstralParty.dll',b'compiled test plugin')
        try: m.prepare(b,r,o,c,None)
        except m.RepackError:print('PASS: no overwrite of existing ZIP')
        else:raise AssertionError('Overwrote existing ZIP')
        # Remove manifest field
        d=json.loads((r/'package-manifest.json').read_text());d['files'].pop();write(r,'package-manifest.json',json.dumps(d).encode())
        try: m.prepare(b,r,t/'missing.zip',c,None)
        except m.RepackError:print('PASS: missing required loader rejected')
        else:raise AssertionError('Incomplete loader accepted')
        # Test orchestrated source build without installing/running .NET or a game.
        names={'.deps/bepinex/winhttp.dll':b'w',
               '.deps/bepinex/doorstop_config.ini':b'd',
               '.deps/bepinex/BepInEx/core/BepInEx.Core.dll':b'c',
               '.deps/bepinex/BepInEx/core/BepInEx.Unity.IL2CPP.dll':b'i',
               'artifacts/BetterAstralParty.compatibility.json':b'{}'}
        write(r,'package-manifest.json',json.dumps({'schema':1,'version':'1.2.1','files':[
            {'path':n,'sha256':sha(raw),'bytes':len(raw)} for n,raw in names.items()]}).encode())
        game=t/'8vJXnINT';write(game,'AstralParty_INT.exe',b'exe');write(game,'BepInEx/interop/Assembly-CSharp.dll',b'game-ref')
        dotnet=t/'fake-dotnet'
        dotnet.write_text('#!/usr/bin/env python3\nimport pathlib,sys\nif "build" in sys.argv:\n idx=sys.argv.index("-o")\n pathlib.Path(sys.argv[idx+1],"BetterAstralParty.dll").write_bytes(b"freshly built test plugin")\n',encoding='utf-8')
        dotnet.chmod(dotnet.stat().st_mode|stat.S_IXUSR)
        real=m.shutil.which
        m.shutil.which=lambda n: str(dotnet) if n in ('dotnet.exe','dotnet') else real(n)
        try:
            fresh=m.compile_plugin_from_source(r,game,t/'fresh-compiled')
        finally: m.shutil.which=real
        m.prepare(fresh,r,t/'fresh.zip',c,None)
        print('PASS: source build, manifest and standalone package orchestration')

if __name__=='__main__':test()
