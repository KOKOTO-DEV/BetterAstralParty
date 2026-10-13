#nullable enable
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
namespace BetterAstralParty.Updating
{
    internal sealed class RecoveryEntry
    {
        internal string Work = "", Descriptor = "", Stage = "";
        internal bool Pending, Committed;
    }
    // Read-only bounded discovery. The transaction re-verifies every field before any recovery mutation.
    internal static class UpdateRecovery
    {
        private static bool Marker(WindowsFileFence fence, string path, string hash) {
            try { using (var file = fence.OpenFile(path)) {
                if (Encoding.ASCII.GetString(UpdateTicket.Read(file, 128)) != hash + "\n") throw Bad(); return true;
            } } catch (ApplySafetyException error) when (error.NativeError == 2) { return false; }
        }
        private static ApplySafetyException Bad() { return new ApplySafetyException(ApplyFailure.RecoveryRequired); }
        internal static List<RecoveryEntry> Scan(WindowsFileFence fence) {
            // Retained terminal evidence keeps its original path/object identities. Only
            // unfinished preparation/recovery consumes the bounded active inventory.
            var result = new List<RecoveryEntry>(); var active = 0;
            var dirs = Directory.EnumerateDirectories(fence.Root, "bap-v3-txn-*", SearchOption.TopDirectoryOnly);
            foreach (var dir in dirs) {
                var work = Path.GetFileName(dir); if (!Regex.IsMatch(work, @"\Abap-v3-txn-[0-9a-f]{32}\z")) throw Bad(); fence.AssertPrivateDirectory(work);
                byte[] bytes;
                try { using (var file = fence.OpenFile(work + "/plan")) bytes = UpdateTicket.Read(file, 16384); }
                catch (ApplySafetyException error) when (error.NativeError == 2) { if (++active > 128) throw Bad(); continue; }
                var lines = Encoding.ASCII.GetString(bytes).Split('\n');
                var v2 = lines.Length == 21 && lines[0] == "BetterAstralParty.Transaction/v3";
                if (!v2 || lines[1] != "root=" + fence.RootIdentity.Text
                    || lines[2] != "work=" + work || lines[3] != "work-id=" + fence.DirectoryIdentity(work).Text || lines[8] != "count=10" || lines[lines.Length - 1] != "") throw Bad();
                if (v2 && !Regex.IsMatch(lines[19], @"\Asettings=(?:-\t-|[0-9A-F]{8}:[0-9A-F]{16}\t[0-9A-F]{64})\z")) throw Bad();
                if (!Regex.IsMatch(lines[4], @"\Astage=bap-v3-stage-[0-9a-f]{32}\z") || !Regex.IsMatch(lines[6], @"\Adescriptor=[0-9A-F]{64}\z")) throw Bad();
                var stage = lines[4].Substring(6); fence.AssertPrivateDirectory(stage); if (lines[5] != "stage-id=" + fence.DirectoryIdentity(stage).Text) throw Bad();
                var hash = UpdateTrust.Hash(bytes); var committed = Marker(fence, work + "/committed", hash); var rolled = Marker(fence, work + "/rolled-back", hash); var intent = Marker(fence, work + "/commit-intent", hash);
                if (committed && (!intent || rolled) || rolled && intent) throw Bad();
                if (!committed && !rolled && ++active > 128) throw Bad();
                result.Add(new RecoveryEntry { Work = work, Stage = stage, Descriptor = lines[6].Substring(11), Pending = !committed && !rolled, Committed=committed });
            }
            return result;
        }
        // This is read-only historical classification, never apply/recovery permission.
        // A terminal result alone cannot retire a stage with unfinished/untracked work.
        private static bool RetiredTicket(WindowsFileFence fence, UpdateTicket ticket, byte[] ticketBytes, List<RecoveryEntry> entries) {
            byte[] result;
            try { using (var file = fence.OpenFile(ticket.Stage + "/helper.result")) result = UpdateTicket.Read(file, 128); }
            catch (ApplySafetyException error) when (error.NativeError == 2) { return false; }
            var lines = Encoding.ASCII.GetString(result).Split('\n');
            if (lines.Length != 3 || lines[0] != UpdateTrust.Hash(ticketBytes) || lines[2] != "") return false;
            var work = HelperRecoveryBinding.ReadAttempt(fence, ticket, UpdateTrust.Hash(ticketBytes));
            if (lines[1] == "FaultDisabled" && work == null && ticket.Context.RepositoryId > 0) {
                using (var resolution = fence.OpenFile(ticket.Stage + "/helper.recovery"))
                    if (HelperRecoveryBinding.ParseResolution(UpdateTicket.Read(resolution, 320), UpdateTrust.Hash(ticketBytes), null) != RecoveryOutcome.NoChanges) return false;
            } else if (lines[1] == "Committed" || lines[1] == "Recovered" || lines[1] == "FaultDisabled") {
                RecoveryEntry? completed = null;
                foreach (var entry in entries) if (entry.Work == work && entry.Descriptor == ticket.DescriptorHash && !entry.Pending) {
                    if (completed != null) throw Bad(); completed = entry;
                }
                if (completed == null || lines[1] == "Committed" && !completed.Committed) return false;
                if (lines[1] == "FaultDisabled") using (var resolution = fence.OpenFile(ticket.Stage + "/helper.recovery")) {
                    var outcome = HelperRecoveryBinding.ParseResolution(UpdateTicket.Read(resolution, 320), UpdateTrust.Hash(ticketBytes), work);
                    if (completed.Committed ? outcome != RecoveryOutcome.TargetCompleted : outcome != RecoveryOutcome.OriginalRestored) return false;
                }
            } else {
                // v2 helpers record an attempt before transaction mutation. Old/untracked
                // contracts remain active candidates rather than being inferred terminal.
                if (ticket.Context.RepositoryId <= 0 || work != null || lines[1] != "Cancelled" && lines[1] != "FilesBusy"
                    && lines[1] != "ManualUpgradeRequired" && lines[1] != "AlreadyClaimed" && lines[1] != "Abandoned") return false;
            }
            byte[] descriptor, signature, key;
            try {
                using (var file = fence.OpenFile(ticket.Stage + "/descriptor.bin")) descriptor = UpdateTicket.Read(file, UpdateTrust.MaxDescriptorBytes);
                using (var file = fence.OpenFile(ticket.Stage + "/signature.bin")) signature = UpdateTicket.Read(file, UpdateTrust.MaxSignatureBytes);
                using (var file = fence.OpenFile(ticket.Stage + "/key-id.bin")) key = UpdateTicket.Read(file, 40);
                // Same signed-purpose/context verification as retention; no new trust pin.
                var verified = UpdateTrust.Production().VerifyDescriptor(descriptor, Encoding.ASCII.GetString(key), signature, ticket.Context);
                return verified.DescriptorSha256 == ticket.DescriptorHash;
            } catch (ApplySafetyException error) when (error.NativeError == 2) { return false; }
            catch (UpdateValidationException) { return false; }
        }
        internal static string? PendingTicket(WindowsFileFence fence, UpdateFault? operation = null, UpdateFault? failure = null) {
            RecoveryEntry? selected = null;
            var entries = Scan(fence);
            foreach (var entry in entries) if (entry.Pending) { if (selected != null) throw Bad(); selected = entry; }
            if (selected == null) return null;
            // Apply creates a separate payload stage. Link the HANDOFF to its exact current
            // transaction WORK via helper.attempt, rather than treating plan.Stage as a ticket.
            string? current = null;
            var terminalStages = new HashSet<string>(StringComparer.Ordinal);
            foreach (var entry in entries) if (!entry.Pending) terminalStages.Add(entry.Stage);
            var active = 0; var dirs = Directory.EnumerateDirectories(fence.Root, "bap-v3-stage-*", SearchOption.TopDirectoryOnly);
            foreach (var dir in dirs) {
                var stage = Path.GetFileName(dir); if (!Regex.IsMatch(stage, @"\Abap-v3-stage-[0-9a-f]{32}\z")) throw Bad();
                // Completed transaction payload stages have already passed Scan's exact
                // private directory/root/stage object-ID checks; retain them in place.
                if (terminalStages.Contains(stage)) continue;
                var counted = false;
                try { using (var file = fence.OpenFile(stage + "/handoff.ticket")) {
                    var bytes = UpdateTicket.Read(file, UpdateTicket.MaxBytes); var ticket = UpdateTicket.Parse(bytes); ticket.Recheck(fence);
                    if (ticket.Stage != stage) throw Bad();
                    if (RetiredTicket(fence, ticket, bytes, entries)) continue;
                    if (++active > 256) throw Bad();
                    counted = true;
                    if (ticket.DescriptorHash != selected.Descriptor) continue;
                    var work = HelperRecoveryBinding.ReadAttempt(fence, ticket, UpdateTrust.Hash(bytes));
                    if (work != null ? work != selected.Work : ticket.Context.RepositoryId > 0 || operation?.Stage != stage && failure?.Stage != stage) continue;
                    if (operation != null) HelperRecoveryBinding.RequireOwner(fence, ticket, operation);
                    if (failure != null) HelperRecoveryBinding.RequireLatch(fence, ticket, failure);
                    if (current != null) throw Bad(); current = stage;
                } } catch (ApplySafetyException error) when (error.NativeError == 2) { if (!counted && ++active > 256) throw Bad(); }
            }
            return current ?? throw Bad();
        }
    }
}
