#!/usr/bin/env python3
"""One-click standalone *local* installation ZIP, no updater/signature bypass.

Inputs: compiled local-export plus genuine fully inventoried 1.2.1 official release.
Output: an offline, simplified install/uninstall package; no privileged operations.
"""
from __future__ import annotations
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile, zipfile, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIMIT = 250_000_000
MAX_PAYLOAD_FILES = 2048  # Must match simple-installer/BetterAstralParty.Setup.cs

class RepackError(Exception): pass

def require(ok, msg):
    if not ok: raise RepackError(msg)

def sha(data: bytes): return hashlib.sha256(data).hexdigest().upper()

def data(path: Path, limit=LIMIT):
    require(path.is_file() and not path.is_symlink(), 'Missing/linked input: '+str(path))
    require(path.stat().st_size <= limit, 'Input too large: '+str(path))
    return path.read_bytes()

def jread(path): return json.loads(data(path).decode('utf-8-sig'))

def relative(path):
    require(isinstance(path,str) and path and not '\\' in path and not ':' in path and not path.startswith('/'), 'Unsafe name: '+repr(path))
    require(all(s not in ('','.','..') and not s.endswith(('.', ' ')) and not re.match(r'(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',s) for s in path.split('/')), 'Unsafe segment: '+repr(path))
    return path

def release_lookup(release):
    doc = jread(release/'package-manifest.json')
    require(doc.get('schema')==1 and doc.get('version')=='1.2.1' and isinstance(doc.get('files'),list), 'Complete ORIGINAL 1.2.1 installer directory required (--release), not source ZIP')
    out={}
    for x in doc['files']:
        path=relative(x['path'])
        require(path.casefold() not in out, 'Duplicate source path: '+path)
        out[path.casefold()] = (path,x)
    return doc,out

def compiler_lookup(build):
    doc=jread(build/'local-build-manifest.json')
    require(doc.get('schema')==1 and doc.get('containsInstaller') is False and isinstance(doc.get('artifacts'),list), 'Compiled Build-Local export required (--build).')
    got={}
    for x in doc['artifacts']:
        path=relative(x['path'])
        got[path]=x
    key='plugin/BetterAstralParty.dll'
    require(key in got, 'Compiled BetterAstralParty.dll missing from build manifest')
    blob=data(build/key)
    require(len(blob)==got[key]['size'] and sha(blob)==got[key]['sha256'].upper(),'Modified DLL does not match compiled manifest')
    return blob

def candidates(kind):
    if kind=='release':
        return [x for x in ROOT.parent.iterdir() if x.is_dir() and (x/'package-manifest.json').is_file()]
    result=[]
    for folder in [ROOT, *[x for x in ROOT.parent.iterdir() if x.is_dir() and x.name.lower().startswith('betterastralparty')]]:
        for child in (folder/'export', folder/'local-build', folder):
            if (child/'local-build-manifest.json').is_file(): result.append(child)
    return sorted(set(result),key=lambda x:str(x).lower())

def select(kind, supplied):
    if supplied:
        path=Path(supplied).resolve()
        require(path.is_dir(), 'No '+kind+' directory: '+str(path))
        return path
    options=candidates(kind)
    if len(options)==1:
        print('Auto-detected '+kind+': '+str(options[0])); return options[0]
    print('\nSelect '+kind+' folder:')
    for index,item in enumerate(options,1): print('%d. %s' % (index,item))
    choice=input('Enter number or folder path: ').strip().strip('"')
    if choice.isdigit() and 1<=int(choice)<=len(options): return options[int(choice)-1]
    path=Path(choice).resolve()
    require(choice and path.is_dir(), 'No '+kind+' folder selected.')
    return path

def find_game(override):
    if override:
        root=Path(override).resolve()
        require(root.name.lower()=='8vjxnint' and (root/'AstralParty_INT.exe').is_file(),'Not a valid INT game folder: '+str(root))
        return root
    libraries=[]
    if os.name=='nt':
        try:
            import winreg
            for hive in (winreg.HKEY_CURRENT_USER,winreg.HKEY_LOCAL_MACHINE):
                for flag in (winreg.KEY_WOW64_64KEY,winreg.KEY_WOW64_32KEY):
                    try:
                        with winreg.OpenKey(hive,r'Software\Valve\Steam',0,winreg.KEY_READ|flag) as key:
                            for name in ('SteamPath','InstallPath'):
                                try: libraries.append(Path(winreg.QueryValueEx(key,name)[0]))
                                except OSError: pass
                    except OSError: pass
        except ImportError: pass
    for e in ('PROGRAMFILES(X86)','PROGRAMFILES'):
        if os.environ.get(e): libraries.append(Path(os.environ[e])/'Steam')
    roots=set()
    for root in libraries:
        if not root.is_dir():continue
        roots.add(root.resolve())
        vdf=root/'steamapps/libraryfolders.vdf'
        if vdf.is_file():
            for raw in re.findall(r'"path"\s*"([^"]+)"',vdf.read_text(encoding='utf-8-sig',errors='replace'),re.I):
                path=Path(raw.replace('\\\\','\\'))
                if path.is_dir():roots.add(path.resolve())
    results=sorted(set(p/'steamapps/common/Astral Party/8vJXnINT' for p in roots if (p/'steamapps/common/Astral Party/8vJXnINT/AstralParty_INT.exe').is_file()))
    if len(results)==1:
        print('Detected INT game:',results[0]);return results[0]
    print('\nGame installations:')
    for i,p in enumerate(results,1): print(str(i)+'. '+str(p))
    typed=input('Game selection number or full 8vJXnINT folder: ').strip().strip('"')
    if typed.isdigit() and 1<=int(typed)<=len(results):return results[int(typed)-1]
    game=Path(typed).resolve()
    require(typed and game.name.lower()=='8vjxnint' and (game/'AstralParty_INT.exe').is_file(),'Valid INT game directory not selected.')
    return game

def compile_plugin_from_source(release,game,build):
    require(not build.exists(),'Local build output exists, choose a fresh path: '+str(build))
    require((game/'BepInEx/interop/Assembly-CSharp.dll').is_file(), 'Game interop reference missing. Launch game once with a working BepInEx setup first.')
    _,rows=release_lookup(release)
    dotnet=shutil.which('dotnet.exe') or shutil.which('dotnet')
    require(dotnet is not None,'dotnet executable not on PATH. Install .NET SDK 8.0.425 or a newer 8.0.4xx patch and the .NET 6 targeting pack.')
    build.mkdir(parents=True)
    loader=build/'clean-loader'
    for key,(name,record) in rows.items():
        if not key.startswith('.deps/bepinex/'):continue
        rel=name[len('.deps/bepinex/'):]
        raw=data(release/name)
        require(len(raw)==record['bytes'] and sha(raw)==record['sha256'].upper(),'Loader hash mismatch: '+name)
        write=loader/rel
        write.parent.mkdir(parents=True,exist_ok=True);write.write_bytes(raw)
    project=ROOT/'src/BetterAstralParty.csproj'
    obj=(build/'obj').resolve()
    props=['-p:GameRoot='+str(game),'-p:BepInExRoot='+str(loader),
           '-p:BaseIntermediateOutputPath='+str(obj)+os.sep,
           '-p:MSBuildProjectExtensionsPath='+str(obj)+os.sep,
           '-p:NuGetAudit=false','-p:UseSharedCompilation=false']
    env=os.environ.copy();env['DOTNET_CLI_TELEMETRY_OPTOUT']='1';env['DOTNET_CLI_HOME']=str(build/'dotnet-home')
    restore=[dotnet,'restore',str(project),'--configfile',str(ROOT/'offline-nuget.config'),*props]
    print('Building BetterAstralParty plugin from source (offline restore)...')
    subprocess.run(restore,check=True,env=env,cwd=str(ROOT))
    output=build/'plugin';output.mkdir()
    subprocess.run([dotnet,'build',str(project),'-c','Release','--no-restore','-o',str(output),*props],check=True,env=env,cwd=str(ROOT))
    blob=data(output/'BetterAstralParty.dll')
    manifest={'schema':1,'version':'1.2.1-local-source-modified','containsInstaller':False,'installerApproved':False,
              'artifacts':[{'path':'plugin/BetterAstralParty.dll','sha256':sha(blob),'size':len(blob)}]}
    (build/'local-build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    print('Plugin compiled:',output/'BetterAstralParty.dll')
    return build

def csc_path(explicit):
    if explicit: return Path(explicit)
    system=Path(os.environ.get('WINDIR',r'C:\Windows'))
    return system/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'

def compile_installer(executable:Path, csc:Path):
    require(csc.is_file(),'Windows x64 .NET Framework compiler not found: '+str(csc))
    source=ROOT/'simple-installer/BetterAstralParty.Setup.cs'
    cmd=[str(csc), '/nologo','/target:exe','/platform:x64','/optimize+','/langversion:5','/out:'+str(executable),str(source),'/reference:System.Core.dll','/reference:System.Web.Extensions.dll']
    result=subprocess.run(cmd,capture_output=True,text=True,errors='replace')
    if result.returncode:
        raise RepackError('Installer compile failed:\n'+result.stdout+'\n'+result.stderr)
    require(executable.is_file(),'Installer EXE not produced')

def code_sign(exe:Path, thumbprint):
    if not thumbprint: return
    require(re.fullmatch('[a-fA-F0-9]{40}',thumbprint)!=None,'Expected 40 hex-character SHA1 certificate thumbprint')
    signtool=shutil.which('signtool.exe')
    require(signtool is not None, 'signtool.exe missing from PATH; Windows SDK needed for certificate signing')
    command=[signtool,'sign','/sha1',thumbprint,'/fd','SHA256','/tr','http://timestamp.digicert.com','/td','SHA256',str(exe)]
    subprocess.run(command,check=True)
    subprocess.run([signtool,'verify','/pa',str(exe)],check=True)

def reviewed_compatibility(path):
    raw=data(path,8_000_000)
    doc=json.loads(raw.decode('utf-8-sig'))
    require(doc.get('schema')==1 and isinstance(doc.get('files'),list) and 5<=len(doc['files'])<=512,
            'Invalid reviewed compatibility manifest')
    require(isinstance(doc.get('reviewNote'),str) and doc['reviewNote'].strip(), 'Compatibility review note required')
    seen=set()
    for row in doc['files']:
        require(isinstance(row,dict) and row.get('root') in ('game','cache'), 'Invalid compatibility root')
        name=relative(row.get('path'))
        require(re.fullmatch('[A-Fa-f0-9]{64}',row.get('sha256','')) is not None,'Invalid compatibility SHA256')
        key=row['root']+'/'+name
        require(key.casefold() not in seen,'Duplicate compatibility path')
        seen.add(key.casefold())
        if row['root']=='cache': require('/' not in name,'Catalog guard requires flat cache catalog paths')
    required=['AstralParty_INT.exe','GameAssembly.dll','UnityPlayer.dll','winhttp.dll',
              'AstralParty_INT_Data/StreamingAssets/aa/settings.json',
              'AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle','AstralParty_INT_Data/data.unity3d',
              'AstralParty_INT_Data/il2cpp_data/Metadata/global-metadata.dat']
    require(all(('game/'+n).casefold() in seen for n in required),'Incomplete reviewed game baseline')
    catalogs=doc.get('cacheCatalogs')
    require(isinstance(catalogs,list) and len(catalogs)==2 and len(set(catalogs))==2,'One active catalog pair required')
    versions=[]
    for n in catalogs:
        require(isinstance(n,str),'Invalid catalog name')
        match=re.fullmatch(r'catalog_([0-9]+\.[0-9]+\.[0-9]+)\.(json|hash)',n)
        require(match is not None and ('cache/'+n).casefold() in seen,'Unpinned active catalog')
        versions.append((match.group(1),match.group(2)))
    require(versions[0][0]==versions[1][0] and {v[1] for v in versions}=={'json','hash'},'Mismatching catalog pair')
    require({r['path'] for r in doc['files'] if r['root']=='cache'}==set(catalogs),'Unexpected cache baseline')
    return raw

def prepare(build,release,out,csc,thumbprint,compatibility_review=None):
    require(not out.exists(), 'Output already exists (do not overwrite): '+str(out))
    require(out.suffix.lower()=='.zip','Output must have ZIP extension')
    _,source=release_lookup(release)
    plugin=compiler_lookup(build)
    # Compile once: use the SAME installer engine both in the install ZIP and
    # in the game folder for compatibility-reviewed mod launches.
    with tempfile.TemporaryDirectory(prefix='bap-setup-') as launch_temp:
        local_setup=Path(launch_temp)/'BetterAstralParty.Setup.exe'
        compile_installer(local_setup,csc)
        code_sign(local_setup,thumbprint)
        installer_bytes=data(local_setup)
    required=[
        'artifacts/BetterAstralParty.compatibility.json',
        '.deps/bepinex/winhttp.dll', '.deps/bepinex/doorstop_config.ini',
        '.deps/bepinex/BepInEx/core/BepInEx.Core.dll',
        '.deps/bepinex/BepInEx/core/BepInEx.Unity.IL2CPP.dll']
    for key in required: require(key.casefold() in source,'Original release missing: '+key)
    loader_allow=re.compile(r'(?i)^(winhttp\.dll|doorstop_config\.ini|\.doorstop_version|changelog\.txt|BepInEx/core/[^/]+\.(?:dll|config)|dotnet/[^/]+\.(?:dll|json)|dotnet/\.version)$')
    content={} ; mappings=[]
    def put(output_path,buf):
        relative(output_path);require(output_path not in content,'Duplicate output '+output_path)
        content[output_path]=buf
    def payload(dest,buf):
        relative(dest)
        output_path='payload/'+dest
        put(output_path,buf)
        mappings.append((output_path,dest,sha(buf),len(buf)))
    for key,(name,record) in sorted(source.items()):
        if not key.startswith('.deps/bepinex/'): continue
        rel=name[len('.deps/bepinex/'):]
        require(loader_allow.fullmatch(rel)!=None,'Non-standard loader file refused: '+name)
        raw=data(release/name)
        require(sha(raw)==record['sha256'].upper() and len(raw)==record['bytes'],'Release file hash/size mismatch: '+name)
        payload(rel,raw)
    name,record=source['artifacts/betterastralparty.compatibility.json']
    raw=data(release/name)
    require(sha(raw)==record['sha256'].upper() and len(raw)==record['bytes'],'Release compatibility file hash/size mismatch')
    if compatibility_review is not None:
        raw=reviewed_compatibility(compatibility_review)
        print('Using explicitly reviewed local compatibility baseline:',compatibility_review)
    payload('BetterAstralParty.compatibility.json',raw)
    payload('BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll',plugin)
    payload('Launch-BAP.cmd',data(ROOT/'simple-installer/Launch-BAP.cmd'))
    payload('BetterAstralParty.Setup.exe',installer_bytes)
    require(len(mappings) >= 5, 'Incomplete BepInEx payload')
    targets = [dest for _, dest, _, _ in mappings]
    require(len(targets) == len(set(t.casefold() for t in targets)), 'Duplicate case-insensitive payload destination')
    require('BepInEx/plugins/BetterAstralParty/BetterAstralParty.dll' in targets and 'winhttp.dll' in targets,
            'Required plugin or winhttp.dll missing from payload')
    require(len(mappings) <= MAX_PAYLOAD_FILES,
            'Payload has %d files (maximum %d); installer would refuse this ZIP' % (len(mappings), MAX_PAYLOAD_FILES))
    print('Verified payload entries for installer:', len(mappings), '/', MAX_PAYLOAD_FILES)
    lines=['# source\\tdestination\\tSHA256\\tbytes']
    lines.extend('\t'.join(map(str,values)) for values in sorted(mappings,key=lambda x:x[1]))
    put('PAYLOAD-MANIFEST.tsv',('\n'.join(lines)+'\n').encode('utf-8'))
    for file in ('Install.cmd','Uninstall.cmd','Force-Uninstall.cmd'):
        put(file,data(ROOT/'simple-installer'/file))
    for file in ('LICENSE','THIRD-PARTY-NOTICES/SOURCES.md','THIRD-PARTY-NOTICES/component-matrix.json'):
        put(file,data(ROOT/file))
    for prefix in ('THIRD-PARTY-NOTICES','THIRD-PARTY-SOURCE'):
        for entry in sorted((ROOT/prefix).iterdir()):
            if entry.is_file():
                name=prefix+'/'+entry.name
                if name not in content: put(name,data(entry,50_000_000))
    put('README-SIMPLE-INSTALL.txt',data(ROOT/'docs/SIMPLE-ONECLICK.md'))
    put('SOURCE-Setup.cs',data(ROOT/'simple-installer/BetterAstralParty.Setup.cs'))
    put('BetterAstralParty.Setup.exe',installer_bytes)
    package_info={'schema':1,'kind':'LOCAL_SIMPLE_OFFLINE','officialBuild':False,
                  'automaticUpdate':False,'steamRegistryModification':False,
                  'compiledPluginSHA256':sha(plugin),'installerSha256':sha(installer_bytes),
                  'installerAuthenticodeRequested':bool(thumbprint),'files':[
                     {'path':name,'sha256':sha(blob),'bytes':len(blob)} for name,blob in sorted(content.items())]}
    put('PACKAGE-FILES.json',(json.dumps(package_info,ensure_ascii=False,indent=2)+'\n').encode('utf-8'))
    out.parent.mkdir(parents=True,exist_ok=True)
    tmp=out.with_name(out.name+'.partial')
    try:
        with zipfile.ZipFile(tmp,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
            for name,blob in sorted(content.items()): z.writestr(name,blob)
        with zipfile.ZipFile(tmp,'r') as z:
            require(set(z.namelist())==set(content),'ZIP index mismatch')
            for name,blob in content.items(): require(z.read(name)==blob,'ZIP file mismatch: '+name)
        os.replace(tmp,out)
    finally:
        if tmp.exists():tmp.unlink()
    print('\nSIMPLE OFFLINE INSTALL ZIP CREATED:',out)
    print('ZIP SHA256:',sha(data(out,1_000_000_000)))
    print('Files:',len(content),'| plugin:',sha(plugin))
    print('EXTRACT and double-click Install.cmd; Force-Uninstall.cmd is included for verified mod-only cleanup.')
    print('Unsigned binaries MAY STILL BE flagged by Defender or SmartScreen; do not disable protections.')

def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build',help='Existing compiled export with local-build-manifest.json')
    p.add_argument('--release',help='Original complete 1.2.1 installer containing package-manifest.json')
    p.add_argument('--output',help='Output ZIP filename')
    p.add_argument('--csc',help='Windows Framework64 csc.exe path')
    p.add_argument('--sign-thumbprint',help='Optional real trusted code-signing certificate thumbprint; requires signtool')
    p.add_argument('--compatibility-review',help='Explicit reviewed local game/catalog SHA256 manifest; launch checks remain mandatory')
    p.add_argument('--compile',action='store_true',help='Compile modified plugin directly from source, then package (no previous export needed)')
    p.add_argument('--game',help='INT game root with BepInEx interop references for --compile')
    a=p.parse_args(argv)
    release=select('release',a.release)
    if a.compile:
        game=find_game(a.game)
        timestamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d-%H%M%S')
        build=compile_plugin_from_source(release,game,ROOT/'artifacts'/('simple-build-'+timestamp))
    else: build=select('build',a.build)
    output=Path(a.output).resolve() if a.output else (ROOT.parent/'BetterAstralParty-1.2.1-SimpleInstall.zip')
    prepare(build,release,output,csc_path(a.csc),a.sign_thumbprint,
            Path(a.compatibility_review).resolve() if a.compatibility_review else None)

if __name__=='__main__':
    try: main()
    except (RepackError,KeyError,ValueError,TypeError,OSError,subprocess.CalledProcessError,zipfile.BadZipFile) as err:
        print('PACKAGING FAILED:',str(err),file=sys.stderr);sys.exit(1)
