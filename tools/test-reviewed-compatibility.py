"""Synthetic packaging tests; these do not launch a game or execute stub binaries."""
import copy, hashlib, importlib.util, json, pathlib, tempfile, unittest, zipfile
from unittest.mock import patch

folder=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('review_packager',folder/'oneclick-package.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=pathlib.Path(self.tmp.name);self.path=self.root/'review.json'
        names=['AstralParty_INT.exe','GameAssembly.dll','UnityPlayer.dll','winhttp.dll',
               'AstralParty_INT_Data/StreamingAssets/aa/settings.json',
               'AstralParty_INT_Data/StreamingAssets/aa/catalog.bundle','AstralParty_INT_Data/data.unity3d',
               'AstralParty_INT_Data/il2cpp_data/Metadata/global-metadata.dat']
        self.doc={'schema':1,'reviewNote':'Synthetic reviewed baseline','files':[
            {'root':'game','path':n,'sha256':'A'*64} for n in names],
            'cacheCatalogs':['catalog_3.3.0.hash','catalog_3.3.0.json']}
        self.doc['files'] += [{'root':'cache','path':n,'sha256':'B'*64} for n in self.doc['cacheCatalogs']]

    def save(self,doc):
        self.path.write_text(json.dumps(doc),encoding='utf-8');return self.path

    def test_valid_pair(self):
        self.assertEqual(m.reviewed_compatibility(self.save(self.doc)),self.path.read_bytes())

    def test_invalid_reviews(self):
        cases=[]
        d=copy.deepcopy(self.doc);d['files'][0]['path']='../escape';cases.append(d)
        d=copy.deepcopy(self.doc);d['files'][0]['sha256']='short';cases.append(d)
        d=copy.deepcopy(self.doc);d['files'].append(d['files'][0]);cases.append(d)
        d=copy.deepcopy(self.doc);d['files'].pop(1);cases.append(d)
        d=copy.deepcopy(self.doc);d['cacheCatalogs'][0]='catalog_3.2.0.hash';cases.append(d)
        d=copy.deepcopy(self.doc);d['reviewNote']='';cases.append(d)
        for d in cases:
            with self.subTest(doc=d),self.assertRaises(m.RepackError):m.reviewed_compatibility(self.save(d))

    def test_explicit_override_and_original_default(self):
        build=self.root/'build';release=self.root/'release';build.mkdir();release.mkdir()
        def write(base,name,data):
            p=base/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data)
        plugin=b'fixture plugin, not an executable assembly'
        write(build,'plugin/BetterAstralParty.dll',plugin)
        write(build,'local-build-manifest.json',json.dumps({'schema':1,'containsInstaller':False,'artifacts':[
            {'path':'plugin/BetterAstralParty.dll','sha256':m.sha(plugin),'size':len(plugin)}]}).encode())
        files={'.deps/bepinex/winhttp.dll':b'w','.deps/bepinex/doorstop_config.ini':b'd',
               '.deps/bepinex/BepInEx/core/BepInEx.Core.dll':b'c',
               '.deps/bepinex/BepInEx/core/BepInEx.Unity.IL2CPP.dll':b'i',
               'artifacts/BetterAstralParty.compatibility.json':b'{"original":true}'}
        for n,b in files.items():write(release,n,b)
        write(release,'package-manifest.json',json.dumps({'schema':1,'version':'1.2.1','files':[
            {'path':n,'sha256':m.sha(b),'bytes':len(b)} for n,b in files.items()]}).encode())
        self.save(self.doc)
        with patch.object(m,'compile_installer',lambda exe,csc:exe.write_bytes(b'non-executable fixture')):
            m.prepare(build,release,self.root/'original.zip',None,None)
            m.prepare(build,release,self.root/'reviewed.zip',None,None,self.path)
        for name,expected in [('original.zip',files['artifacts/BetterAstralParty.compatibility.json']),('reviewed.zip',self.path.read_bytes())]:
            with zipfile.ZipFile(self.root/name) as z:
                data=z.read('payload/BetterAstralParty.compatibility.json');self.assertEqual(data,expected)
                rows=[s.split('\t') for s in z.read('PAYLOAD-MANIFEST.tsv').decode().splitlines() if not s.startswith('#')]
                row=next(r for r in rows if r[1]=='BetterAstralParty.compatibility.json')
                self.assertEqual(row[2],m.sha(expected));self.assertEqual(int(row[3]),len(expected))

if __name__=='__main__':unittest.main()
