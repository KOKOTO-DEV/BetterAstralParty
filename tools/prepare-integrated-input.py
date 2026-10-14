#!/usr/bin/env python3
"""Prepare audited inputs for BetterAstralParty's ORIGINAL package-ga.ps1.

This tool does not authorize, sign or install a release. It creates a pinned,
private staging inventory consumed by the unchanged GA release builder.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import zipfile
from pathlib import Path

EXPECTED_CECIL = '769A59793D4B8885BBBFBC5AEE8F57A0D4E34D275C56C60C03994309B87F67E9'
EXPECTED_LOADER = 'F4CC496BD098A0DF4164B81E3737297707F13A47C2478DBA2F60EEFAB784817A'
ROOT = Path(__file__).resolve().parent.parent
EXTRA = ['Force-Uninstall.cmd', 'tools/force-uninstall.ps1']
REPLACE_SOURCE = {
    'Install.cmd', 'Uninstall.cmd', 'README.md',
    'tools/install-policy.ps1', 'tools/install.ps1', 'tools/install-bootstrap.ps1',
    'tools/install-helper.ps1', 'tools/install-reinstall.ps1',
    'tools/install-backup.ps1', 'tools/install-log.ps1', 'tools/uninstall.ps1',
    'tools/find-game.ps1', 'tools/steam-session.ps1', 'tools/steam-shortcut.ps1',
    'tools/set-loader-mode.ps1', 'tools/BetterAstralParty-Mod.cmd',
    'tools/AstralParty-Vanilla.cmd', 'tools/check-compatibility.ps1',
    'tools/BetterAstralParty-Steam.ps1', 'tools/diagnostics.ps1',
    'diagnostics/DiagnosticBundle.cs', 'diagnostics/MinimalDiagnosticProjection.cs'
}
REPLACEMENTS = {
    'artifacts/BetterAstralParty.dll': 'plugin/BetterAstralParty.dll',
    'artifacts/BetterAstralParty-Launcher.exe': 'launcher/BetterAstralParty-Launcher.exe',
    'helper-bootstrap/BetterAstralParty-UpdateHelper.exe': 'helper/BetterAstralParty-UpdateHelper.exe',
}
DERIVED = {'package-manifest.json', 'helper-bootstrap/helper.descriptor',
           'helper-bootstrap/helper.signature', 'update-proof/update.descriptor',
           'update-proof/update.signature'}


def fail(msg):
    raise ValueError(msg)


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def doc(data, name):
    try:
        return json.loads(data.decode('utf-8-sig'))
    except (UnicodeError, json.JSONDecodeError) as e:
        fail(f'Invalid JSON ({name}): {e}')


def safe_rel(name):
    if not isinstance(name, str) or not name or '\\' in name or name.startswith('/') or name.count('//') or ':' in name or any(x in name for x in '<>"|?*') or any(ord(c) < 32 for c in name):
        fail(f'Unsafe package path: {name!r}')
    if any(p in ('', '.', '..') or p.strip() != p or p.endswith('.') for p in name.split('/')):
        fail(f'Unsafe path components: {name!r}')
    return name


def read_file(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024 * 1024:
        fail(f'Invalid or missing file: {path}')
    return path.read_bytes()


def version_parts(text):
    m=re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?', text)
    if not m: fail(f'Invalid version: {text}')
    return tuple(map(int,m.group(1,2,3)))


def check_original_release(release):
    manifest=doc(read_file(release/'package-manifest.json'),'base manifest')
    if manifest.get('schema') != 1 or not isinstance(manifest.get('files'),list) or not manifest['files']:
        fail('Original release manifest is missing or invalid')
    if version_parts(manifest.get('version', '')) < (1,2,1):
        fail('Baseline must be a complete 1.2.1+ release, not legacy package')
    recorded,folded={},set()
    for row in manifest['files']:
        if not isinstance(row,dict): fail('Invalid release inventory row')
        name=safe_rel(row.get('path'))
        case=name.casefold()
        if case in folded: fail(f'Case-colliding release path: {name}')
        folded.add(case)
        buf=read_file(release/name)
        if row.get('sha256')!=digest(buf) or row.get('bytes') !=len(buf):
            fail(f'Original release hash/size mismatch: {name}')
        recorded[name]=buf
    if 'tools/approved-install-bundles.json' not in recorded:
        fail('Original release lacks approval catalog')
    catalog=doc(recorded['tools/approved-install-bundles.json'],'base approval')
    if catalog.get('schema')!=1 or not isinstance(catalog.get('bundles'), list):
        fail('Invalid original approval catalog')
    # Recalculate exact original content identity (catalog intentionally excluded).
    plugin_proto=1
    fields=['BetterAstralParty.InstallBundle/v1', 'version='+manifest['version'],
            'kind='+manifest['kind'], 'protocol='+str(plugin_proto)]
    fields += [name+'='+digest(recorded[name]) for name in sorted(recorded) if name!='tools/approved-install-bundles.json']
    identity=digest(('\n'.join(fields)+'\n').encode('utf-8'))
    if manifest.get('buildIdentity')!=identity or not any(isinstance(x,dict) and x.get('buildIdentity')==identity and x.get('version')==manifest['version'] and x.get('kind')==manifest['kind'] and x.get('protocol')==plugin_proto for x in catalog['bundles']):
        fail('Original release identity/catalog mismatch; use complete authentic release')
    required=('Install.cmd','Uninstall.cmd','tools/find-game.ps1','tools/steam-shortcut.ps1',
              'tools/install.ps1','tools/approved-install-bundles.json',
              'artifacts/BetterAstralParty.dll','artifacts/BetterAstralParty-Launcher.exe',
              'helper-bootstrap/BetterAstralParty-UpdateHelper.exe',
              '.deps/bepinex/BepInEx/core/Mono.Cecil.dll',
              'update-proof/update.descriptor','update-proof/update.signature')
    for k in required:
        if k not in recorded: fail('Original release missing '+k)
    if digest(recorded['.deps/bepinex/BepInEx/core/Mono.Cecil.dll'])!=EXPECTED_CECIL:
        fail('Original release does not include pinned Mono.Cecil')
    return manifest,recorded,identity


def check_build(build):
    m=doc(read_file(build/'local-build-manifest.json'),'build manifest')
    if m.get('schema')!=1 or m.get('containsInstaller') is not False or m.get('installerApproved') is not False:
        fail('Expected source compiler manifest; release artifacts must be independently signed')
    observed={}
    for row in m.get('artifacts', []):
        if not isinstance(row,dict):fail('Invalid compiler output row')
        name=safe_rel(row.get('path'))
        if name in observed:fail('Duplicate build component')
        buf=read_file(build/name)
        if len(buf)!=row.get('size') or digest(buf)!=row.get('sha256'):
            fail(f'Compiled artifact hash mismatch: {name}')
        observed[name]=buf
    if set(observed)!=set(REPLACEMENTS.values()):
        fail('Build directory must contain exactly plugin, launcher, helper outputs')
    return observed


def loader_config(upstream):
    data=read_file(upstream)
    if digest(data)!=EXPECTED_LOADER:
        fail(f'BepInEx build 788 upstream archive SHA-256 mismatch: {digest(data)}')
    with zipfile.ZipFile(upstream) as z:
        configs=[n for n in z.namelist() if n == 'doorstop_config.ini']
        if len(configs)!=1:fail('Expected unique doorstop_config.ini in upstream loader')
        config=z.read(configs[0])
        if not config or len(config)>65536:fail('Invalid loader config size')
    return data,config


def prepare(base,build,upstream,stage):
    release_manifest, original, orig_identity=check_original_release(base)
    compiler=check_build(build)
    upstream_bytes, config=loader_config(upstream)
    destination=ROOT/'artifacts'/'automatic-update-development'/stage/'inputs'
    if destination.exists():
        fail('Input stage already exists; choose a fresh --stage name')
    packaging_reader=ROOT/'.deps/bepinex/BepInEx/core/Mono.Cecil.dll'
    if packaging_reader.exists():
        if digest(read_file(packaging_reader))!=EXPECTED_CECIL:
            fail('Existing source packaging reader conflicts with pinned reader')
    source=dict(original)
    for name in DERIVED:
        source.pop(name, None)
    # Approval entries are NOT copied/forged from the prior build.
    source['tools/approved-install-bundles.json']=b'{"schema":1,"bundles":[]}'
    for name in REPLACE_SOURCE:
        if name in source and (ROOT/name).is_file():
            source[name]=read_file(ROOT/name)
    for name,artifact in REPLACEMENTS.items():
        if name not in source:fail(f'Original release is missing expected artifact: {name}')
        source[name]=compiler[artifact]
    source['.deps/bepinex/doorstop_config.ini']=config
    # The original signed update proof becomes a historical proof for recovery
    # and is verified by the GA package compiler against pinned public keys.
    desc=original['update-proof/update.descriptor']
    sig=original['update-proof/update.signature']
    if not desc or not sig:fail('Original signed proof missing')
    key=digest(desc)
    for suffix,data in (('descriptor',desc),('signature',sig)):
        keypath=f'update-proof/prior/{key}.{suffix}'
        if keypath in source and source[keypath]!=data:
            fail('Historical proof hash collision')
        source[keypath]=data
    for name in EXTRA:
        source[name]=read_file(ROOT/name)
    # No signing outputs are generated by this preparation tool.
    for name in ('update-proof/update.descriptor','update-proof/update.signature','helper-bootstrap/helper.signature'):
        if name in source:fail('Current version signature must be produced by authorized signer')
    if len(source)>1024 or len(source)<25:fail('Invalid GA input file count')
    total=0
    for name,data in source.items():
        safe_rel(name)
        if not data or len(data)>64*1024*1024:fail('Invalid input component size: '+name)
        total+=len(data)
    if total>256*1024*1024:fail('GA input exceeds 256 MB limit')
    try:
        files=destination/'files'
        files.mkdir(parents=True,exist_ok=False)
        rows=[]
        for name in sorted(source):
            f=files/name
            f.parent.mkdir(parents=True,exist_ok=True)
            f.write_bytes(source[name])
            rows.append({'path':name,'sha256':digest(source[name]),'bytes':len(source[name])})
        (destination/'upstream-loader.zip').write_bytes(upstream_bytes)
        # Package-ga extracts actual plugin version from IL; metadata from the
        # previous release is not reused as a claim about the new compiled DLL.
        plugin_source=(ROOT/'src/Plugin.cs').read_text(encoding='utf-8-sig')
        match=re.search(r'(?m)^\s*public const string Version = \"([^\"]+)\";',plugin_source)
        if not match:fail('Cannot read canonical plugin version from source')
        proposed_version=match.group(1)
        version_parts(proposed_version)
        spec={'schema':1,'version':proposed_version,'upstreamArchiveSha256':EXPECTED_LOADER,'files':rows}
        # A same-version build is allowed as a *review candidate* but never
        # approved for in-place replacement without a signed recovery plan.
        blob=json.dumps(spec,ensure_ascii=False,indent=2).encode('utf-8')
        (destination/'input-manifest.json').write_bytes(blob)
        report={'inputDirectory':str(destination),'inputManifestSha256':digest(blob),
                'originalVersion':release_manifest['version'],'proposedVersion':proposed_version,'originalBuildIdentity':orig_identity,
                'sourceManifestReview':'updated source only, not owner signed',
                'installable':False,'approved':False,'componentCount':len(rows),
                'signingRequired':True}
        (destination.parent/'prepared-review.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
        packaging_reader.parent.mkdir(parents=True,exist_ok=True)
        if not packaging_reader.exists():packaging_reader.write_bytes(original['.deps/bepinex/BepInEx/core/Mono.Cecil.dll'])
        return report
    except Exception:
        shutil.rmtree(destination.parent,ignore_errors=True)
        raise


def main():
    parser=argparse.ArgumentParser(description='Stage original 1.2.1 signed-release format without creating trust/approval')
    parser.add_argument('--release',required=True,help='Complete approved original INSTALLER extracted folder')
    parser.add_argument('--build',required=True,help='Existing Build-Local compiled export directory')
    parser.add_argument('--upstream',required=True,help='Unmodified upstream BepInEx IL2CPP Windows x64 build 788 ZIP')
    parser.add_argument('--stage',required=True,help='New private stage label, e.g. review01')
    a=parser.parse_args()
    if not re.fullmatch('[A-Za-z0-9_-]{1,50}',a.stage):fail('Unsafe stage label')
    report=prepare(Path(a.release).resolve(),Path(a.build).resolve(),Path(a.upstream).resolve(),a.stage)
    print(json.dumps(report,ensure_ascii=False,indent=2))


if __name__=='__main__':
    try:main()
    except (ValueError,OSError,zipfile.BadZipFile) as e:
        print('INTEGRATED INPUT FAILED:',str(e),file=sys.stderr)
        sys.exit(1)
