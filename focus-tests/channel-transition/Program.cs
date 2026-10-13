using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using BetterAstralParty;
using BetterAstralParty.Updating;

internal static class ChannelTransitionTests
{
    private static int _checks;
    private const string Root="ABCD1234:0000000000000100";
    private static void Check(bool value,string reason){if(!value)throw new InvalidOperationException(reason);_checks++;}
    private static void Refuse(Action action,string reason){try{action();}catch(Exception error)when(error is UpdateValidationException or ApplySafetyException or ArgumentException){Check(true,reason);return;}throw new InvalidOperationException(reason);}
    private static UpdateContext Context(ReleaseFeed feed,string current,string target,string? floor=null,ChannelTransitionIntent? intent=null,string? hash=null)
        =>new(feed.Repository,feed.Channel,current,target,123,456,UpdateTrust.PlatformId,floor,feed.RepositoryId,intent,hash);
    private static byte[] Descriptor(UpdateContext context,string schema="1",string protocol="3"){
        var text=$"BetterAstralParty.UpdateDescriptor/v{protocol}\nrepository={context.Repository}\nversion={context.ReleaseTag}\nchannel={context.Channel}\nplatform={UpdateTrust.PlatformId}\nrelease-id=123\nasset-id=456\nasset-name=BetterAstralParty-{context.ReleaseTag}-update.zip\nzip-bytes=1\nzip-sha256={new string('A',64)}\nfile-count=8\npurpose=release/{context.Channel}\nrepository-id={context.RepositoryId}\nsettings-schema={schema}\n";
        foreach(var path in InstallReceipt.Owned.OrderBy(value=>value,StringComparer.Ordinal))text+=$"file={path}\t1\t{new string('B',64)}\n";
        return Encoding.ASCII.GetBytes(text);
    }
    private static ReceiptChannelState Source(ReleaseFeed feed,string version,ReleaseFeed target,string? floor,string floorHash)
        =>new(Root,feed.Channel,new string('a',32),feed.Channel=="Stable"?feed.RepositoryId:floor==null?0:target.RepositoryId,
            feed.Channel=="Stable"?version:floor,feed.Channel=="Stable"?new string('C',64):floorHash,
            feed.Channel=="Beta"?feed.RepositoryId:floor==null?0:target.RepositoryId,
            feed.Channel=="Beta"?version:floor,feed.Channel=="Beta"?new string('D',64):floorHash);
    private static byte[] Sign(RSA key,byte[] bytes)=>key.SignData(bytes,HashAlgorithmName.SHA256,RSASignaturePadding.Pss);
    private static void Policy(RSA key,UpdateTrust trust){
        foreach(var source in new[]{ReleaseFeedPolicy.Stable,ReleaseFeedPolicy.Beta})foreach(var version in new[]{"1.2.2","1.2.3","1.2.4"}){
            var target=ReleaseFeedPolicy.For(source.Channel=="Stable"?"Beta":"Stable");
            var proposalContext=Context(target,"0.0.0",version);var bytes=Descriptor(proposalContext);var signature=Sign(key,bytes);
            var descriptor=trust.VerifyProposal(bytes,"ephemeral-transition-fixture",signature,proposalContext);
            var state=Source(source,"1.2.3",target,null,"-");
            var review=new ChannelTransitionReview(Root,new string('E',64),new string('F',64),new string('A',64),"1.2.3",state,descriptor);
            var intent=ChannelTransitionIntent.Parse(ChannelTransitionIntent.Approve(review).Bytes());var approved=Context(target,"1.2.3",version,intent:intent);
            Check(intent.MatchesTarget(approved),"symmetric exact intent roundtrip "+source.Channel+" -> "+target.Channel+" "+version);
            Check(trust.VerifyDescriptor(bytes,"ephemeral-transition-fixture",signature,approved).Version==version,"explicit lower/equal/higher installed version accepted");
            var replay=Context(target,"1.2.3",version,version,intent,descriptor.DescriptorSha256);
            Check(trust.VerifyDescriptor(bytes,"ephemeral-transition-fixture",signature,replay).Version==version,"destination exact floor replay accepted");
            Check(state.Applied(Root,descriptor,intent.Operation,intent).ActiveChannel==target.Channel,"receipt keeps explicit target channel");
            var retained=Source(source,"1.2.3",target,version,descriptor.DescriptorSha256);
            Check(retained.Applied(Root,descriptor,intent.Operation,intent).ActiveChannel==target.Channel,"receipt permits only exact destination-floor replay");
            Refuse(()=>trust.VerifyDescriptor(bytes,"ephemeral-transition-fixture",signature,Context(target,"1.2.3",version,"9.0.0",intent,descriptor.DescriptorSha256)),"destination floor cannot be lowered");
            Refuse(()=>trust.VerifyDescriptor(bytes,"ephemeral-transition-fixture",signature,Context(target,"1.2.3",version,version,intent,new string('F',64))),"equal destination floor requires exact descriptor");
            Refuse(()=>Context(target,"1.2.5",version,intent:intent),"changed installed source cannot reuse approval");
            var changed=Encoding.ASCII.GetBytes(Encoding.ASCII.GetString(bytes).Replace("zip-bytes=1","zip-bytes=2"));
            Refuse(()=>trust.VerifyDescriptor(changed,"ephemeral-transition-fixture",Sign(key,changed),approved),"signed changed target cannot reuse approval");
        }
        foreach(var feed in new[]{ReleaseFeedPolicy.Stable,ReleaseFeedPolicy.Beta})foreach(var version in new[]{"1.2.2","1.2.3"}){
            var context=Context(feed,"1.2.3",version);var bytes=Descriptor(context);
            Refuse(()=>trust.VerifyDescriptor(bytes,"ephemeral-transition-fixture",Sign(key,bytes),context),"ordinary same-channel lower/equal refused");
        }
        var stable=Context(ReleaseFeedPolicy.Stable,"0.0.0","1.2.2");
        foreach(var bad in new[]{Descriptor(stable,"2"),Descriptor(stable,protocol:"2"),Descriptor(Context(ReleaseFeedPolicy.Stable,"0.0.0","1.2.0"))})
            Refuse(()=>trust.VerifyDescriptor(bad,"ephemeral-transition-fixture",Sign(key,bad),stable),"unsupported schema/protocol/baseline refused");
        var valid=Descriptor(stable);var broken=Sign(key,valid);broken[0]^=1;
        Refuse(()=>trust.VerifyDescriptor(valid,"ephemeral-transition-fixture",broken,stable),"invalid signature refused");
        Refuse(()=>trust.VerifyDescriptor(valid,"unknown-fixture-key",Sign(key,valid),stable),"unknown key refused");
    }
    private sealed class NoNetwork : HttpMessageHandler { internal int Requests; protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token){Requests++;throw new InvalidOperationException("No network allowed in policy fixture");} }
    private sealed class Authentication : IReleaseAuthentication { internal string IdentityValue="inert-fixture";public string CacheIdentity=>IdentityValue;public bool TryAuthorize(HttpRequestMessage request){request.Headers.Authorization=new("Bearer","inert-fixture-not-a-credential");return true;} }
    private sealed class DiscoveryHandler(ReleaseFeed feed,string target,bool missingLatest=false) : HttpMessageHandler {
        internal int Requests;
        private object Release(string version,long id,bool complete){
            var assets=new List<object>{new{id=id+1,name="BetterAstralParty-"+version+"-update.zip"},new{id=id+2,name=ReleaseFeedPolicy.UpdateManifestAsset}};
            if(complete)assets.Add(new{id=id+3,name=ReleaseFeedPolicy.UpdateSignatureAsset});
            return new{tag_name=version,name="fixture",body="fixture",html_url="https://github.com/"+feed.Repository+"/releases/tag/"+version,draft=false,prerelease=false,id,assets};
        }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token){
            Requests++;Check(request.RequestUri!.Host=="api.github.com"&&request.RequestUri.AbsolutePath.StartsWith("/repos/"+feed.Repository,StringComparison.Ordinal),"discovery uses only the selected repository");
            var identity=request.RequestUri.AbsolutePath=="/repos/"+feed.Repository;
            var json=identity?JsonSerializer.Serialize(new{id=feed.RepositoryId,full_name=feed.Repository,@private=feed.RequiresAuthentication})
                :JsonSerializer.Serialize(new[]{Release(target,900, !missingLatest),Release("1.2.2",800,true)});
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){RequestMessage=request,Content=new StringContent(json,Encoding.UTF8,"application/json")});
        }
    }
    private static async Task Finish(ReleaseUpdates discovery){
        for(var i=0;i<300&&discovery.Result.Status==ReleaseUpdateStatus.Checking;i++){discovery.Poll();await Task.Delay(2);}discovery.Poll();
        Check(discovery.Result.Status!=ReleaseUpdateStatus.Checking,"bounded mocked discovery completes");
    }
    private static async Task Discovery(UpdateTrust trust){
        foreach(var source in new[]{ReleaseFeedPolicy.Stable,ReleaseFeedPolicy.Beta})foreach(var target in new[]{"1.3.0","1.4.0","1.5.0"}){
            var selected=ReleaseFeedPolicy.For(source.Channel=="Stable"?"Beta":"Stable");var auth=new Authentication();
            using var handler=new DiscoveryHandler(selected,target);using var client=new HttpClient(handler);using var discovery=new ReleaseUpdates("1.4.0",selected,client,auth);
            using var noNetwork=new NoNetwork();using var downloads=new UpdateDownloads(trust,auth,noNetwork,feed:selected);
            using var automatic=new AutomaticUpdates(downloads,new Handoff(),new Safety(Source(source,"1.4.0",selected,null,"-")));automatic.Configure(auth);
            for(var i=0;i<100&&automatic.Status==AutomaticUpdateStatus.CheckingInstallation;i++){automatic.Tick(DateTimeOffset.UtcNow);await Task.Delay(2);}
            UpdateDiscoveryBridge.Apply(discovery,automatic,"1.4.0");
            var now=DateTimeOffset.UtcNow;discovery.Check(now);await Finish(discovery);
            Check(discovery.Result.Status==ReleaseUpdateStatus.Available&&discovery.Result.Release?.Version==target,$"fresh config picks selected repository latest: {source.Channel}/{selected.Channel}/{target}, {discovery.Result.Status}/{discovery.Result.Release?.Version}, requests={handler.Requests}");
            Check(discovery.Result.Release!.TransitionCandidate==(UpdateVersion.Parse(target).CompareTo(UpdateVersion.Parse("1.4.0"))<=0),"lower/equal discovery remains explicit-only");
            UpdateDiscoveryBridge.Apply(discovery,automatic,"1.4.0");Check(automatic.CanReviewTransition&&!automatic.CanDownload&&automatic.Status==AutomaticUpdateStatus.TransitionRequired,"real bridge keeps explicit approval even for a lower candidate without an ordinary download request");
            auth.IdentityValue="inert-fixture-refreshed";discovery.Configure(client,auth);discovery.Check(now.AddMinutes(2));await Finish(discovery);
            Check(discovery.Result.Release?.Version==target,"auth configure/clear retains installed-channel latest mode");
            auth.IdentityValue="inert-fixture-second-session";discovery.Poll();discovery.Check(now.AddMinutes(4));await Finish(discovery);
            Check(discovery.Result.Release?.Version==target,"identity refresh cannot drop lower/equal latest mode");
        }
        foreach(var selected in new[]{ReleaseFeedPolicy.Stable,ReleaseFeedPolicy.Beta}){
            using var handler=new DiscoveryHandler(selected,"1.3.0");using var client=new HttpClient(handler);using var discovery=new ReleaseUpdates("1.4.0",selected,client,new Authentication());
            discovery.InstalledChannel(selected.Channel);discovery.Check(DateTimeOffset.UtcNow);await Finish(discovery);
            Check(discovery.Result.Status==ReleaseUpdateStatus.UpToDate&&discovery.Result.Release==null,"ordinary same-channel discovery keeps strict newer filter");
        }
        using var missingHandler=new DiscoveryHandler(ReleaseFeedPolicy.Stable,"1.5.0",true);using var missingClient=new HttpClient(missingHandler);
        using var missing=new ReleaseUpdates("1.4.0",ReleaseFeedPolicy.Stable,missingClient);missing.InstalledChannel("Beta");missing.Check(DateTimeOffset.UtcNow);await Finish(missing);
        Check(missing.Result.Release?.Version=="1.5.0"&&missing.Result.Release.ProposalRequest("1.4.0")==null,"missing latest asset never falls back silently to an older complete release");
    }
    private sealed class Handoff : IUpdateHandoff {
        public bool Configured=>true;public Task<string?> Inspect()=>Task.FromResult<string?>(null);
        public Task<object> Prepare(DownloadedUpdate update,UpdateContext context,CancellationToken token)=>throw new InvalidOperationException("No staging allowed");
        public Task<object> Queue(object prepared,CancellationToken token)=>throw new InvalidOperationException("No process allowed");
        public void SignalCancel(object prepared){}public Task Cancel(object prepared)=>Task.CompletedTask;
    }
    private sealed class Safety(ReceiptChannelState state) : IUpdateSafety {
        public Task<UpdateSafetySnapshot> Probe()=>Task.FromResult(new UpdateSafetySnapshot(Channels:state,InstalledVersion:state.ActiveVersion));
        public Task<UpdateFault> Begin(UpdateContext context)=>throw new InvalidOperationException("No mutation allowed");
        public Task Complete(UpdateFault? operation)=>Task.CompletedTask;
        public Task<UpdateFault> Fail(UpdateContext context,FaultPhase phase,FaultReason reason,string? stage)=>throw new InvalidOperationException("No fault persistence allowed");
        public Task SavePreferences(bool download,bool apply)=>throw new InvalidOperationException("Preferences must not change");
        public Task SaveFailed(UpdateFault fault)=>Task.CompletedTask;public Task Acknowledge()=>Task.CompletedTask;
    }
    private static async Task Coordinator(UpdateTrust trust){
        foreach(var source in new[]{ReleaseFeedPolicy.Stable,ReleaseFeedPolicy.Beta})foreach(var version in new[]{"1.2.2","1.2.3","1.2.4"}){
            var target=ReleaseFeedPolicy.For(source.Channel=="Stable"?"Beta":"Stable");var state=Source(source,"1.2.3",target,null,"-");
            using var handler=new NoNetwork();var auth=new Authentication();using var downloads=new UpdateDownloads(trust,auth,handler,feed:target);
            using var automatic=new AutomaticUpdates(downloads,new Handoff(),new Safety(state));automatic.Configure(auth);
            automatic.Context(new(Context(target,"1.2.3",version),457,458),12);
            for(var i=0;i<100&&automatic.Status==AutomaticUpdateStatus.CheckingInstallation;i++){automatic.Tick(DateTimeOffset.UtcNow);await Task.Delay(2);}
            for(var i=0;i<5;i++)automatic.Tick(DateTimeOffset.UtcNow);
            Check(automatic.Status==AutomaticUpdateStatus.TransitionRequired&&!automatic.CanDownload&&automatic.CanReviewTransition,"all cross-channel directions/sizes require approval");
            Check(handler.Requests==0&&automatic.AutoDownload&&automatic.ApplyAfterExit,"channel selection cannot download or change saved choices");
        }
        using var noNetwork=new NoNetwork();using var client=new HttpClient(noNetwork);using var discovery=new ReleaseUpdates("1.2.3",ReleaseFeedPolicy.Stable,client);
        var latest=new ReleaseUpdate("1.2.4","fixture","",new Uri("https://github.com/"+ReleaseFeedPolicy.StableRepository+"/releases/tag/1.2.4")){
            Repository=ReleaseFeedPolicy.StableRepository,RepositoryId=ReleaseFeedPolicy.StableRepositoryId,FeedChannel="Stable",Generation=discovery.Generation,ReleaseId=123,ZipAssetId=456,DescriptorAssetId=457,SignatureAssetId=458};
        var result=typeof(ReleaseUpdates).GetProperty("Result",BindingFlags.Instance|BindingFlags.NonPublic)!;result.SetValue(discovery,new ReleaseUpdateResult(ReleaseUpdateStatus.Available,latest));
        Check(discovery.CurrentRelease(latest),"fresh exact current repository latest target accepted");
        foreach(var changed in new[]{latest with{ZipAssetId=459},latest with{DescriptorAssetId=459},latest with{SignatureAssetId=459},latest with{Generation=latest.Generation+1},latest with{Repository=ReleaseFeedPolicy.BetaRepository},latest with{RepositoryId=ReleaseFeedPolicy.BetaRepositoryId},latest with{FeedChannel="Beta"},latest with{ReleaseId=124}})
            Check(!discovery.CurrentRelease(changed),"changed latest identity cannot be approved");
        foreach(var status in new[]{ReleaseUpdateStatus.Stale,ReleaseUpdateStatus.Incomplete,ReleaseUpdateStatus.Checking}){result.SetValue(discovery,new ReleaseUpdateResult(status,latest));Check(!discovery.CurrentRelease(latest),"nonfresh discovery cannot approve old release");}
    }
    internal static async Task Main(string[] args){
        using var key=RSA.Create(3072);var trust=new UpdateTrust(new[]{new TrustedUpdateKey("ephemeral-transition-fixture",key.ExportParameters(false))});
        typeof(UpdateTrust).GetField("_production",BindingFlags.Instance|BindingFlags.NonPublic)!.SetValue(trust,true);
        Policy(key,trust);await Coordinator(trust);await Discovery(trust);
        var report=new{checks=_checks,scope="Actual policy/coordinator sources, stricter production floor with an ephemeral fixture key only. No operational key, live network, native UI, game, Steam, helper process, staging or installation.",pass=true};
        File.WriteAllText(Path.Combine(args[0],"results.json"),JsonSerializer.Serialize(report,new JsonSerializerOptions{WriteIndented=true}));
        Console.WriteLine("PASS "+_checks+" channel-policy/coordinator checks.");
    }
}
