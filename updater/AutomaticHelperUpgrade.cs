#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

namespace BetterAstralParty.Updating {
    // Signed bootstrap travels inside the existing owned8 launcher; never adopts an unknown helper.
    internal static class AutomaticHelperUpgrade {
        internal const string ResourcePrefix="BetterAstralParty.HelperBootstrap.";
        private static ApplySafetyException Bad(){return new ApplySafetyException(ApplyFailure.RecoveryRequired);}
        private static byte[] Text(string value){return Encoding.ASCII.GetBytes(value);}
        private static string Slot(WindowsFileFence.FileLease? file){return file==null?"-\t-":file.Identity.Text+"\t"+file.Hash();}
        private static bool IsSlot(string value){return Regex.IsMatch(value,@"\A[0-9A-F]{8}:[0-9A-F]{16}\t[0-9A-F]{64}\z");}
        private static WindowsFileFence.FileLease? Maybe(WindowsFileFence f,string path,bool mutable=false){
            try{return f.OpenFile(path,mutable);}catch(ApplySafetyException e)when(e.NativeError==2){return null;}
        }
        private static void Write(WindowsFileFence f,string path,byte[] bytes){HelperDelivery.Write(f,path,bytes);}
        private static byte[] Resource(Assembly assembly,string name,long limit){
            using(var stream=assembly.GetManifestResourceStream(ResourcePrefix+name)??throw Bad()){
                if(stream.Length<1 || stream.Length>limit)throw Bad();
                var bytes=new byte[(int)stream.Length];var offset=0;
                while(offset<bytes.Length){var read=stream.Read(bytes,offset,bytes.Length-offset);if(read==0)throw Bad();offset+=read;}
                return bytes;
            }
        }
        internal static void Ensure(WindowsFileFence fence,Assembly assembly){
            Ensure(fence,Resource(assembly,"descriptor",UpdateTrust.MaxDescriptorBytes),Resource(assembly,"signature",1024),
                Resource(assembly,"image",UpdateTrust.MaxFileBytes),UpdateTrust.Production());
        }
        private sealed class Intent {
            internal string Root="",Work="",WorkId="",HelperWork="",HelperId="",Descriptor="",Receipt="",Water="",OldImage="",OldReceipt="";
            internal string Value(){return "BetterAstralParty.AutomaticHelper/v1\nroot="+Root+"\nwork="+Work+"\nwork-id="+WorkId+"\nhelper-work="+HelperWork+"\nhelper-id="+HelperId+"\ndescriptor="+Descriptor+"\nreceipt="+Receipt+"\nwater="+Water+"\nold-image="+OldImage+"\nold-receipt="+OldReceipt+"\n";}
            internal static Intent Parse(byte[] bytes){
                foreach(var c in bytes)if(c>127 || c==13)throw Bad();
                var lines=Encoding.ASCII.GetString(bytes).Split('\n');
                var keys=new[]{"root=","work=","work-id=","helper-work=","helper-id=","descriptor=","receipt=","water=","old-image=","old-receipt="};
                if(lines.Length!=12 || lines[0]!="BetterAstralParty.AutomaticHelper/v1" || lines[11]!="")throw Bad();
                var v=new string[10];for(var i=0;i<keys.Length;i++){if(!lines[i+1].StartsWith(keys[i],StringComparison.Ordinal))throw Bad();v[i]=lines[i+1].Substring(keys[i].Length);}
                if(!Regex.IsMatch(v[0],@"\A[0-9A-F]{8}:[0-9A-F]{16}\z") || !Regex.IsMatch(v[1],@"\Abap-helperauto-[0-9a-f]{32}\z") || !Regex.IsMatch(v[2],@"\A[0-9A-F]{8}:[0-9A-F]{16}\z") || !Regex.IsMatch(v[3],@"\Abap-helper-[0-9a-f]{32}\z") || !Regex.IsMatch(v[4],@"\A[0-9A-F]{8}:[0-9A-F]{16}\z") || !Regex.IsMatch(v[5],@"\A[0-9A-F]{64}\z") || !IsSlot(v[6]) || v[7]!="-\t-" && !IsSlot(v[7]) || !IsSlot(v[8]) || !IsSlot(v[9]))throw Bad();
                var p=new Intent{Root=v[0],Work=v[1],WorkId=v[2],HelperWork=v[3],HelperId=v[4],Descriptor=v[5],Receipt=v[6],Water=v[7],OldImage=v[8],OldReceipt=v[9]};
                if(UpdateTrust.Hash(Text(p.Value()))!=UpdateTrust.Hash(bytes))throw Bad();return p;
            }
        }
        private static List<Intent> Scan(WindowsFileFence f){
            var result=new List<Intent>();var dirs=Directory.GetDirectories(f.Root,"bap-helperauto-*",SearchOption.TopDirectoryOnly);if(dirs.Length>64)throw Bad();
            foreach(var dir in dirs){var work=Path.GetFileName(dir);if(!Regex.IsMatch(work,@"\Abap-helperauto-[0-9a-f]{32}\z"))throw Bad();f.AssertPrivateDirectory(work);
                using(var file=Maybe(f,work+"/plan")){if(file==null)continue;var bytes=UpdateTicket.Read(file,4096);var p=Intent.Parse(bytes);
                    if(p.Work!=work || p.Root!=f.RootIdentity.Text || p.WorkId!=f.DirectoryIdentity(work).Text)throw Bad();
                    using(var marker=Maybe(f,work+"/committed")){if(marker==null)result.Add(p);else if(Encoding.ASCII.GetString(UpdateTicket.Read(marker,128))!=UpdateTrust.Hash(bytes)+"\n")throw Bad();}
                }
            }return result;
        }
        internal static bool Pending(WindowsFileFence f){return Scan(f).Count!=0;}
        private static void Keep(WindowsFileFence f,string path,byte[] expected,Action<string>? boundary){
            using(var file=Maybe(f,path)){if(file!=null){if(file.Hash()!=UpdateTrust.Hash(expected))throw Bad();return;}}
            Write(f,path,expected);boundary?.Invoke("prepared:"+Path.GetFileName(path));
        }
        private static void CheckItem(WindowsFileFence f,Intent p,string target,string old,string next,string staged,string archive){
            using(var live=Maybe(f,target))using(var saved=Maybe(f,p.Work+"/"+archive))using(var incoming=Maybe(f,p.HelperWork+"/"+staged)){
                var t=Slot(live);var b=Slot(saved);var n=Slot(incoming);
                if(b!="-\t-" && b!=old || t!=old && b!=old || t==old && saved!=null || t!=old && t!=next && live!=null || (t==next?incoming!=null:n!=next))throw Bad();
            }
        }
        private static void Archive(WindowsFileFence f,Intent p,string target,string old,string next,string name,Action<string>? boundary){
            using(var file=Maybe(f,target,true)){if(file==null || Slot(file)==next)return;if(Slot(file)!=old)throw Bad();
                boundary?.Invoke("before:"+name);file.RenameTo(f,p.Work+"/"+name);file.Flush();boundary?.Invoke("after:"+name);}
        }
        internal static void Ensure(WindowsFileFence f,byte[] descriptor,byte[] signature,byte[] image,UpdateTrust trust,Action<string>? boundary=null){
            var incoming=HelperDescriptor.Verify(trust,descriptor,DetachedSignature.Parse(signature),image);if(incoming.Protocol!=2)throw Bad();
            UpdateLaunchGate.AssertNoReinstall(f);UpdateFaults.Read(f);
            if(UpdateFaults.ReadFile(f,UpdateFaults.OperationPath)!=null || WholeInstallBridge.Pending(f))throw Bad();
            foreach(var entry in UpdateRecovery.Scan(f))if(entry.Pending)throw Bad();
            var pending=Scan(f);if(pending.Count>1)throw Bad();
            var helperDirs=Directory.GetDirectories(f.Root,"bap-helper-*",SearchOption.TopDirectoryOnly);if(helperDirs.Length>64)throw Bad();
            foreach(var dir in helperDirs){
                var work=Path.GetFileName(dir);if(!Regex.IsMatch(work,@"\Abap-helper-[0-9a-f]{32}\z"))throw Bad();f.AssertPrivateDirectory(work);
                using(var plan=Maybe(f,work+"/plan"))using(var committed=Maybe(f,work+"/committed"))
                    if(plan!=null && committed==null && (pending.Count!=1 || pending[0].HelperWork!=work))throw Bad();
            }
            using(var processes=WindowsProcessGuard.Acquire(f,new[]{"AstralParty_INT.exe"})){
                WindowsProcessGuard.AssertNoRunning(new[]{f.Full(HelperDescriptor.Image)});
                using(var receipt=f.OpenFile(InstallReceipt.Path)){
                    var installed=InstallReceipt.Parse(UpdateTicket.Read(receipt,16384));var leases=new List<WindowsFileFence.FileLease>();
                    try{
                        foreach(var path in InstallReceipt.Owned){var file=path=="BetterAstralParty-Launcher.exe"?f.OpenLaunchImage(path):f.OpenFile(path);leases.Add(file);if(file.Hash()!=installed.Files[path])throw Bad();}
                        UpdateTransaction.ReadHighWater(f);
                        if(installed.Channels!=null && installed.Channels.Root!=f.RootIdentity.Text)throw Bad();
                        using(var water=Maybe(f,UpdateTransaction.HighWaterPath)){
                            Intent p;
                            if(pending.Count==1){p=pending[0];if(p.Descriptor!=incoming.DescriptorHash || p.Receipt!=Slot(receipt) || p.Water!=Slot(water) || p.HelperId!=f.DirectoryIdentity(p.HelperWork).Text)throw Bad();}
                            else{
                                var current=HelperDelivery.AuthenticatedAt(f,trust,HelperDescriptor.Image,HelperDelivery.Receipt)??throw Bad();
                                if(current.Protocol>=2 && current.Sha256==incoming.Sha256 || UpdateVersion.Parse(current.Version).CompareTo(UpdateVersion.Parse(incoming.Version))>0)return;
                                if(UpdateVersion.Parse(current.Version).CompareTo(UpdateVersion.Parse(incoming.Version))==0)throw Bad();
                                p=new Intent{Root=f.RootIdentity.Text,Work="bap-helperauto-"+Guid.NewGuid().ToString("N"),HelperWork="bap-helper-"+Guid.NewGuid().ToString("N"),Descriptor=incoming.DescriptorHash,Receipt=Slot(receipt),Water=Slot(water)};
                                using(var old=Maybe(f,HelperDescriptor.Image))p.OldImage=Slot(old);
                                using(var old=Maybe(f,HelperDelivery.Receipt))p.OldReceipt=Slot(old);
                                p.WorkId=f.CreatePrivateDirectory(p.Work).Text;p.HelperId=f.CreatePrivateDirectory(p.HelperWork).Text;
                                Write(f,p.Work+"/plan",Text(p.Value()));boundary?.Invoke("intent");
                            }
                            f.AssertPrivateDirectory(p.HelperWork);
                            using(var plan=Maybe(f,p.HelperWork+"/plan"))if(plan==null){
                                using(var live=Maybe(f,HelperDescriptor.Image))using(var old=Maybe(f,HelperDelivery.Receipt))if(Slot(live)!=p.OldImage || Slot(old)!=p.OldReceipt)throw Bad();
                                Keep(f,p.HelperWork+"/descriptor",descriptor,boundary);Keep(f,p.HelperWork+"/signature",signature,boundary);Keep(f,p.HelperWork+"/image",image,boundary);
                                string id;using(var staged=f.OpenFile(p.HelperWork+"/image"))id=staged.Identity.Text;
                                Keep(f,p.HelperWork+"/receipt",HelperDelivery.WholeReceiptBytes(f,incoming,id),boundary);
                                string receiptId;using(var staged=f.OpenFile(p.HelperWork+"/receipt"))receiptId=staged.Identity.Text;
                                Keep(f,p.HelperWork+"/plan",Text("BetterAstralParty.HelperInstall/v1\nroot="+p.Root+"\nwork="+p.HelperWork+"\nwork-id="+p.HelperId+"\ndescriptor="+p.Descriptor+"\nimage-id="+id+"\nreceipt-id="+receiptId+"\n"),boundary);
                            }
                            string newImage,newReceipt;
                            using(var plan=f.OpenFile(p.HelperWork+"/plan")){
                                var l=Encoding.ASCII.GetString(UpdateTicket.Read(plan,2048)).Split('\n');
                                if(l.Length!=8 || l[0]!="BetterAstralParty.HelperInstall/v1" || l[1]!="root="+p.Root || l[2]!="work="+p.HelperWork || l[3]!="work-id="+p.HelperId || l[4]!="descriptor="+p.Descriptor || !Regex.IsMatch(l[5],@"\Aimage-id=[0-9A-F]{8}:[0-9A-F]{16}\z") || !Regex.IsMatch(l[6],@"\Areceipt-id=[0-9A-F]{8}:[0-9A-F]{16}\z") || l[7]!="")throw Bad();
                                newImage=l[5].Substring(9)+"\t"+incoming.Sha256;newReceipt=l[6].Substring(11)+"\t"+UpdateTrust.Hash(HelperDelivery.WholeReceiptBytes(f,incoming,l[5].Substring(9)));
                            }
                            CheckItem(f,p,HelperDescriptor.Image,p.OldImage,newImage,"image","old-image");CheckItem(f,p,HelperDelivery.Receipt,p.OldReceipt,newReceipt,"receipt","old-receipt");
                            string oldImage,oldReceipt;
                            using(var live=Maybe(f,HelperDescriptor.Image))oldImage=Slot(live)==p.OldImage?HelperDescriptor.Image:p.Work+"/old-image";
                            using(var live=Maybe(f,HelperDelivery.Receipt))oldReceipt=Slot(live)==p.OldReceipt?HelperDelivery.Receipt:p.Work+"/old-receipt";
                            var authenticated=HelperDelivery.AuthenticatedAt(f,trust,oldImage,oldReceipt)??throw Bad();
                            if(authenticated.Sha256!=p.OldImage.Split('\t')[1] || UpdateVersion.Parse(authenticated.Version).CompareTo(UpdateVersion.Parse(incoming.Version))>=0)throw Bad();
                            processes.Recheck();foreach(var file in leases)file.Recheck();receipt.Recheck();water?.Recheck();
                            Archive(f,p,HelperDescriptor.Image,p.OldImage,newImage,"old-image",boundary);Archive(f,p,HelperDelivery.Receipt,p.OldReceipt,newReceipt,"old-receipt",boundary);
                            HelperDelivery.FinishWholeMigration(f,p.HelperWork,trust,boundary);
                            CheckItem(f,p,HelperDescriptor.Image,p.OldImage,newImage,"image","old-image");CheckItem(f,p,HelperDelivery.Receipt,p.OldReceipt,newReceipt,"receipt","old-receipt");
                            if(HelperDelivery.Fingerprint(f,trust,2)!=incoming.Sha256)throw Bad();
                            processes.Recheck();foreach(var file in leases)file.Recheck();if(Slot(receipt)!=p.Receipt || Slot(water)!=p.Water)throw Bad();
                            boundary?.Invoke("before:auto-committed");Write(f,p.Work+"/committed",Text(UpdateTrust.Hash(Text(p.Value()))+"\n"));boundary?.Invoke("after:auto-committed");
                        }
                    }finally{foreach(var file in leases)file.Dispose();}
                }
            }
        }
    }
}
