// XenServer .NET (C#) SDK - real-world workflow examples.
//
// Each example mirrors a task you would perform in XenCenter, driven through the XenServer
// Management API (XenAPI). The .NET binding speaks JSON-RPC.
//
// Every example is self-contained: it takes the connection details (and any object it acts on,
// looked up by name) as parameters, opens its own session and logs out when done - so you can copy
// one out and run it on its own; see the "Run it:" line under each. The dispatcher at the bottom is
// only what lets this one file run any of them from the command line.
//
// Usage:
//   dotnet run -- <workflow> <url> <username> <password>
//
//   <workflow>  any workflow id from the dispatcher (see also README.md)

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Xml.Linq;
using XenAPI;
using Console = System.Console; // XenAPI also defines a Console class

internal static class Program
{
    // --- connect ---
    private static Session Connect(string url, string user, string password)
    {
        try
        {
            return Login(url, user, password);
        }
        catch (Failure f) when (f.ErrorDescription[0] == "HOST_IS_SLAVE")
        {
            // A pool member names the coordinator's address; reconnect there (assuming the coordinator
            // is up), exactly as XenCenter does when you add a member server.
            return Login($"https://{f.ErrorDescription[1]}", user, password);
        }
    }

    private static Session Login(string url, string user, string password)
    {
        var session = new Session(url);
        // Accept the host's self-signed certificate.
        session.JsonRpcClient.ServerCertificateValidationCallback = (req, cert, chain, errors) => true;
        session.login_with_password(user, password, "1.0", "sdk-examples");
        return session;
    }

    // Look up a template VM by its exact name (rather than picking an arbitrary one).
    private static string TemplateByName(Session session, string name) =>
        VM.get_all_records(session).First(kv => kv.Value.is_a_template && kv.Value.name_label == name)
            .Key.opaque_ref;

    // Look up a guest VM (not a template, control domain or snapshot) by its exact name.
    private static string VmByName(Session session, string name) =>
        VM.get_all_records(session).First(kv => !kv.Value.is_a_template && !kv.Value.is_control_domain
            && !kv.Value.is_a_snapshot && kv.Value.name_label == name).Key.opaque_ref;

    // Look up an SR by its exact name (optionally requiring it to be shared).
    private static string SrByName(Session session, string name, bool shared = false) =>
        SR.get_all_records(session).First(kv => kv.Value.name_label == name && (!shared || kv.Value.shared))
            .Key.opaque_ref;

    /// <summary>
    /// Detach an SR from every host, then forget it: XenCenter's Detach followed by Forget. SR.forget
    /// refuses an SR that is still attached (SR_HAS_PBD), so unplug its PBDs first. Forgetting drops the
    /// pool's record of the SR but leaves the data on the storage itself.
    /// </summary>
    private static void DetachAndForgetSr(Session session, string sr)
    {
        foreach (var pbd in SR.get_PBDs(session, sr))
            if (PBD.get_currently_attached(session, pbd.opaque_ref))
                PBD.unplug(session, pbd.opaque_ref);
        SR.forget(session, sr);
    }

    /// <summary>
    /// VM.provision, after filling in the SR for every disk the template describes. A template's
    /// other_config["disks"] carries each disk's SR as sr="" (empty); a real host takes that literally and
    /// VM.provision fails with UUID_INVALID, so the caller has to rewrite it to the pool's default SR
    /// first — exactly what `xe vm-install` does before calling VM.provision itself.
    /// </summary>
    private static void Provision(Session session, string vm)
    {
        if (VM.get_other_config(session, vm).TryGetValue("disks", out var disksXml))
        {
            var defaultSr = Pool.get_default_SR(session, Pool.get_all(session).First().opaque_ref).opaque_ref;
            var doc = XDocument.Parse(disksXml);
            foreach (var disk in doc.Root!.Elements("disk"))
                disk.SetAttributeValue("sr", SR.get_uuid(session, defaultSr));

            VM.remove_from_other_config(session, vm, "disks");
            VM.add_to_other_config(session, vm, "disks", doc.ToString(SaveOptions.DisableFormatting));
        }
        VM.provision(session, vm);
    }

    /// <summary>The first (from the end) Failure detail that looks like an XML fragment, or null.</summary>
    private static string XmlFromFailure(Failure f) =>
        f.ErrorDescription.AsEnumerable().Reverse()
            .FirstOrDefault(d => !string.IsNullOrEmpty(d) && d.TrimStart().StartsWith("<"));

    /// <summary>
    /// Return the XML a backend sends back on its deliberately-failing discovery probe. The New SR
    /// wizard (and XenRT) discover iSCSI/HBA LUNs by asking with an incomplete device-config on purpose:
    /// the backend can't create anything from it yet, so it fails with an SR_BACKEND_FAILURE_&lt;n&gt;
    /// error whose params carry an XML fragment describing what it found. Never probe by attempting
    /// SR.create instead: on real storage a create that unexpectedly succeeds formats the LUN.
    /// </summary>
    private static string ProbeForFailure(Session session, string host,
        Dictionary<string, string> deviceConfig, string smType)
    {
        try
        {
            SR.probe(session, host, deviceConfig, smType, new Dictionary<string, string>());
        }
        catch (Failure f)
        {
            var xml = XmlFromFailure(f);
            if (xml != null) return xml;
            throw;
        }
        throw new Exception($"SR.probe for {smType} succeeded without asking for more information; " +
                            "check the target address");
    }

    // Pick the IQN from an iSCSI discovery probe: the caller's, if named (it must be one the target
    // offers), else the first. An array usually offers many targets - one per LUN, often belonging to
    // different users - so on shared storage always name yours: SR.create formats the LUN behind it.
    private static string ChooseTargetIqn(XDocument iqnXml, string target, string targetIqn)
    {
        var offered = iqnXml.Descendants("TargetIQN").Select(e => e.Value).ToList();
        if (!string.IsNullOrEmpty(targetIqn) && !offered.Contains(targetIqn))
            throw new Exception($"target {target} does not offer IQN {targetIqn}");
        return string.IsNullOrEmpty(targetIqn) ? offered.First() : targetIqn;
    }

    /// <summary>
    /// A throwaway self-signed certificate and private key (PEM), the way XenRT provisions one for its
    /// own certificate tests. .NET's own X509 API builds one directly - no external tool needed.
    /// </summary>
    private static (string CertPem, string KeyPem) SelfSignedCertPem()
    {
        using var rsa = RSA.Create(2048);
        var request = new System.Security.Cryptography.X509Certificates.CertificateRequest(
            "CN=sdk-example", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var cert = request.CreateSelfSigned(
            DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(365));
        return (cert.ExportCertificatePem(), rsa.ExportRSAPrivateKeyPem());
    }

    /// <summary>
    /// Wait out a pool-wide xapi restart (Pool.designate_new_master) and reconnect. XenRT's own helper
    /// for this call treats the connection dropping as the expected, successful outcome and then waits
    /// several minutes before trusting the pool again, rather than retrying immediately - do the same.
    /// </summary>
    private static Session ReconnectAfterMasterChange(string url, string user, string password,
        int timeoutSeconds = 600, int intervalSeconds = 5)
    {
        var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        Exception lastError = null;
        while (DateTime.UtcNow < deadline)
        {
            try { return Connect(url, user, password); }
            catch (Exception e)
            {
                lastError = e;
                System.Threading.Thread.Sleep(intervalSeconds * 1000);
            }
        }
        throw new Exception($"the pool did not come back after the master change: {lastError}");
    }

    /// <summary>
    /// Poll host_metrics.live until it matches, rather than issuing the next power command immediately -
    /// real out-of-band power control has no retry of its own, so a tool that doesn't wait can issue a
    /// second command while the first is still in flight.
    /// </summary>
    private static void WaitForHostLive(Session session, string host, bool want,
        int timeoutSeconds = 60, int intervalSeconds = 2)
    {
        var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (HostLive(session, host) != want)
        {
            if (DateTime.UtcNow > deadline) throw new Exception($"host did not reach live={want} in time");
            System.Threading.Thread.Sleep(intervalSeconds * 1000);
        }
    }

    /// <summary>
    /// Build the URL for a given host's own address, keeping the scheme and port the caller originally
    /// connected with (a host's management address carries no port of its own).
    /// </summary>
    private static string HostUrl(string url, string address)
    {
        var uri = new Uri(url);
        var port = uri.IsDefaultPort ? "" : $":{uri.Port}";
        return $"{uri.Scheme}://{address}{port}";
    }

    /// <summary>
    /// Relocate every one of a (not-yet-started) VM's disks onto the given SR, the same VDI.pool_migrate
    /// storage-migrate already demonstrates.
    /// </summary>
    private static void MoveDisksToSr(Session session, string vm, string srRef)
    {
        foreach (var vdi in DiskVdis(session, vm))
            if (VDI.get_SR(session, vdi).opaque_ref != srRef)
                AwaitTask(session, VDI.async_pool_migrate(session, vdi, srRef, new Dictionary<string, string>()));
    }

    /// <summary>
    /// Wait for an async_* task to finish, return its result and destroy it. A call that copies a disk
    /// runs for many minutes, and an HTTP request held open that long tends to be dropped by the network
    /// (SocketException 10060) however long the client is willing to wait, so long operations start the
    /// async_ twin, which returns a Task at once, and poll that instead.
    /// </summary>
    private static string AwaitTask(Session session, XenRef<Task> task)
    {
        try
        {
            while (Task.get_status(session, task) == task_status_type.pending)
                System.Threading.Thread.Sleep(1000);
            if (Task.get_status(session, task) != task_status_type.success)
                throw new Failure(Task.get_error_info(session, task));
            return Task.get_result(session, task).Replace("<value>", "").Replace("</value>", "").Trim();
        }
        finally
        {
            Task.destroy(session, task);
        }
    }

    /// <summary>
    /// A throwaway VM with a working guest OS: a copy of an existing VM that has one. Suspend,
    /// checkpoint, live migration and clean shutdown all need the guest's cooperation: on a running VM
    /// with no PV drivers xapi refuses them up front with VM_LACKS_FEATURE (a VM freshly cloned from a
    /// template has no OS at all). So copy a VM that does have an OS and PV drivers, without disturbing
    /// it: snapshot it (fine while it runs), clone the snapshot - a clone of a snapshot is a template -
    /// and provision that into an ordinary VM. The snapshot is only needed for the clone, so it goes
    /// again straight away.
    /// </summary>
    private static string CopyOfGuest(Session session, string sourceVmName, string newVmName)
    {
        var source = VmByName(session, sourceVmName);
        var snapshot = VM.snapshot(session, source, newVmName + "-source").opaque_ref;
        var vm = VM.clone(session, snapshot, newVmName).opaque_ref;
        Provision(session, vm);
        DestroyVmAndDisks(session, snapshot);
        return vm;
    }

    /// <summary>
    /// Wait, after VM.start, until the guest's PV drivers have reported in. xapi only offers the
    /// guest-dependent operations once the guest says it can do them, and allowed_operations is where
    /// it says so: wait for clean_shutdown to appear there (the same check that refuses it with
    /// VM_LACKS_FEATURE beforehand). A booting OS takes a while.
    /// </summary>
    private static void WaitForGuestAgent(Session session, string vm, int timeoutSeconds = 300,
        int intervalSeconds = 2)
    {
        var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (!VM.get_allowed_operations(session, vm).Contains(vm_operations.clean_shutdown))
        {
            if (DateTime.UtcNow > deadline)
                throw new Exception($"the guest's PV drivers did not report in within {timeoutSeconds}s; " +
                    "does the source VM have a guest OS with PV drivers (XenServer VM Tools)?");
            System.Threading.Thread.Sleep(intervalSeconds * 1000);
        }
    }

    /// <summary>Merge CLI-supplied overrides onto a workflow's dispatcher defaults.</summary>
    private static Dictionary<string, string> Merge(Dictionary<string, string> defaults,
        Dictionary<string, string> overrides)
    {
        var result = new Dictionary<string, string>(defaults);
        foreach (var kv in overrides) result[kv.Key] = kv.Value;
        return result;
    }

    // --- 1. Connect & inventory ---------------------------------------------------------
    private static void ConnectInventory(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var pool = Pool.get_all_records(session).Values.First();
        Console.WriteLine($"Connected to pool: {pool.name_label}");

        var hosts = Host.get_all_records(session);
        Console.WriteLine($"Hosts ({hosts.Count}):");
        foreach (var host in hosts.Values)
            Console.WriteLine($"  - {host.name_label} ({host.address})");

        var vms = VM.get_all_records(session).Values
            .Where(v => !v.is_a_template && !v.is_control_domain).ToList();
        Console.WriteLine($"VMs ({vms.Count}):");
        foreach (var vm in vms)
            Console.WriteLine($"  - {vm.name_label} [{vm.power_state}]");

        Console.WriteLine("OK: connect-inventory");
        session.logout();
    }
    // Run it:
    //   ConnectInventory("https://xenserver", "root", password);

    // --- 2. Create a VM from a template -------------------------------------------------
    private static void CreateVm(string url, string user, string password,
        string templateName, string newVmName = "sdk-example-vm")
    {
        var session = Connect(url, user, password);
        var templateRef = TemplateByName(session, templateName);
        Console.WriteLine($"Using template: {VM.get_name_label(session, templateRef)}");

        var vmRef = VM.clone(session, templateRef, newVmName);
        Console.WriteLine($"Cloned new VM: {VM.get_uuid(session, vmRef.opaque_ref)}");

        Provision(session, vmRef.opaque_ref);
        Console.WriteLine($"Provisioned. is_a_template = {VM.get_is_a_template(session, vmRef.opaque_ref)}");

        DestroyVmAndDisks(session, vmRef.opaque_ref);
        Console.WriteLine("Cleaned up the example VM.");

        Console.WriteLine("OK: create-vm");
        session.logout();
    }
    // Run it:
    //   CreateVm("https://xenserver", "root", password, "Rocky Linux 8");

    // --- 3. VM power lifecycle ----------------------------------------------------------
    private static void VmLifecycle(string url, string user, string password,
        string sourceVm, string newVmName = "sdk-example-lifecycle")
    {
        var session = Connect(url, user, password);
        // Suspend and clean shutdown need the guest's cooperation (VM_LACKS_FEATURE without PV
        // drivers), so the copy is made from sourceVm, a VM with a guest OS and PV drivers, and the
        // example waits for the guest to report in after starting. Suspend also needs a suspend-image
        // SR (the VM's own, else the pool's, else the host's); check one is actually configured before
        // trying.
        var vmRef = CopyOfGuest(session, sourceVm, newVmName);

        string State() => VM.get_power_state(session, vmRef).ToString();

        Console.WriteLine($"Initial power state: {State()}");
        VM.start(session, vmRef, false, true);
        WaitForGuestAgent(session, vmRef);
        Console.WriteLine($"After start:    {State()}");

        // The emulated hardware (the device model) can be restarted under a running guest without
        // rebooting it — what you reach for when the VM's virtual devices misbehave.
        VM.restart_device_models(session, vmRef);
        Console.WriteLine($"Device models restarted; still {State()}");

        if (HasSuspendSr(session, vmRef))
        {
            VM.suspend(session, vmRef);
            Console.WriteLine($"After suspend:  {State()}");
            VM.resume(session, vmRef, false, true);
            WaitForGuestAgent(session, vmRef); // the PV drivers reconnect after a resume
            Console.WriteLine($"After resume:   {State()}");
        }
        else
        {
            Console.WriteLine("Skipping suspend/resume: no suspend-image SR is configured for this VM/pool/host");
        }

        // A clean shutdown asks the guest OS to shut itself down, as pressing the power button would.
        VM.clean_shutdown(session, vmRef);
        Console.WriteLine($"After shutdown: {State()}");

        DestroyVmAndDisks(session, vmRef);
        Console.WriteLine("OK: vm-lifecycle");
        session.logout();
    }
    // Run it:
    //   VmLifecycle("https://xenserver", "root", password, "web-01");

    /// <summary>
    /// Whether VM.suspend has a suspend-image SR to use: the VM's own, else the pool's, else the
    /// resident host's - the same fallback order xapi's choose_suspend_sr uses.
    /// </summary>
    private static bool HasSuspendSr(Session session, string vm)
    {
        if (VM.get_suspend_SR(session, vm).opaque_ref != "OpaqueRef:NULL") return true;
        var pool = Pool.get_all(session)[0].opaque_ref;
        if (Pool.get_suspend_image_SR(session, pool).opaque_ref != "OpaqueRef:NULL") return true;
        var host = Pool.get_master(session, pool).opaque_ref;
        return Host.get_suspend_image_sr(session, host).opaque_ref != "OpaqueRef:NULL";
    }

    // --- Manage VM disks: Deactivate / Resize / Activate ----------------------------------
    private static void ManageVmDisks(string url, string user, string password,
        string templateName, string srName, string newVmName = "sdk-example-vm-disks")
    {
        const long GiB = 1024L * 1024 * 1024;
        var session = Connect(url, user, password);
        // Not the VM's root/boot disk: a real VM's system disk is unpluggable=false (only a template's
        // non-system disks default to unpluggable), so VBD.unplug on it fails on a real host with
        // VBD_NOT_UNPLUGGABLE - and the VM has to be running in the first place, or unplug fails with
        // VM_BAD_POWER_STATE. Work on a data disk this example adds to its own throwaway VM instead,
        // matching XenCenter's own "deactivate" action, which only ever targets additional disks.
        var vmRef = VM.clone(session, TemplateByName(session, templateName), newVmName).opaque_ref;
        Provision(session, vmRef);
        VM.start(session, vmRef, false, true);

        var srRef = SrByName(session, srName);
        var vdiRef = VDI.create(session, new VDI
        {
            name_label = "sdk-example-data-disk",
            SR = new XenRef<SR>(srRef),
            virtual_size = 4 * GiB,
            type = vdi_type.user,
            sharable = false,
            read_only = false,
            other_config = new Dictionary<string, string>(),
        }).opaque_ref;
        var vbdRef = VBD.create(session, new VBD
        {
            VM = new XenRef<VM>(vmRef),
            VDI = new XenRef<VDI>(vdiRef),
            userdevice = VM.get_allowed_VBD_devices(session, vmRef)[0],
            mode = vbd_mode.RW,
            type = vbd_type.Disk,
            empty = false,
            other_config = new Dictionary<string, string>(),
            qos_algorithm_type = "",
            qos_algorithm_params = new Dictionary<string, string>(),
        }).opaque_ref;
        VBD.plug(session, vbdRef);
        Console.WriteLine($"Disk attached:  {VBD.get_currently_attached(session, vbdRef)}");

        // Deactivate = VBD.unplug. The disk stays with the VM; it is just no longer live.
        VBD.unplug(session, vbdRef);
        Console.WriteLine($"After unplug:   {VBD.get_currently_attached(session, vbdRef)}");

        var size = VDI.get_virtual_size(session, vdiRef);
        VDI.resize(session, vdiRef, size * 2);
        Console.WriteLine($"Resized:        {size} -> {VDI.get_virtual_size(session, vdiRef)} bytes");

        VBD.plug(session, vbdRef);
        Console.WriteLine($"After plug:     {VBD.get_currently_attached(session, vbdRef)}");

        // Growing a disk that is attached and live is a DIFFERENT call, not a flag on the same one:
        // resize_online tells the storage layer the guest is using the disk while it grows.
        var grown = VDI.get_virtual_size(session, vdiRef) + 1024L * 1024 * 1024;
        VDI.resize_online(session, vdiRef, grown);
        Console.WriteLine($"Grown online:   {VDI.get_virtual_size(session, vdiRef)} bytes");

        VM.hard_shutdown(session, vmRef);
        DestroyVmAndDisks(session, vmRef);
        Console.WriteLine("OK: manage-vm-disks");
        session.logout();
    }

    // --- Raise and dismiss alerts ---------------------------------------------------------
    private static void DismissAlerts(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var messages = Message.get_all_records(session);
        Console.WriteLine($"Alerts:         {messages.Count}");

        var first = messages.FirstOrDefault();
        if (first.Key == null)
        {
            Console.WriteLine("No alerts to dismiss.");
        }
        else
        {
            Console.WriteLine($"Dismissing:     {first.Value.name} (priority {first.Value.priority})");
            // Dismiss in XenCenter's Notifications view is exactly this call.
            Message.destroy(session, first.Key);
            Console.WriteLine($"Alerts left:    {Message.get_all_records(session).Count}");
        }
        Console.WriteLine("OK: dismiss-alerts");
        session.logout();
    }

    // --- Configure host power on ------------------------------------------------------------
    private static void HostPowerOn(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var hostRef = Host.get_all(session).First().opaque_ref;

        // Mode and config travel together: the config carries the credentials the mode needs.
        // "wake-on-lan" is a real, still-supported mode and needs no credentials; the legacy "iLO"/"DRAC"
        // modes were removed from the real power-on plugin (REQ-811) and fail the moment host.power_on
        // is actually called ("{mode} script has been removed").
        Host.set_power_on_mode(session, hostRef, "wake-on-lan", new Dictionary<string, string>());
        Console.WriteLine($"Power-on mode:  {Host.get_power_on_mode(session, hostRef)}");
        foreach (var kv in Host.get_power_on_config(session, hostRef))
            Console.WriteLine($"  {kv.Key} = {kv.Value}");

        Host.set_power_on_mode(session, hostRef, "", new Dictionary<string, string>());
        Console.WriteLine("OK: host-power-on");
        session.logout();
    }

    // --- Rotate the pool secret -------------------------------------------------------------
    private static void RotatePoolSecret(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var poolRef = Pool.get_all_records(session).Keys.First().opaque_ref;
        Console.WriteLine($"Pool:           {Pool.get_name_label(session, poolRef)}");

        // xapi checks its own preconditions before rotating - HA must be disabled, every host must be
        // live, no rolling pool upgrade may be in progress, and the pool must be licensed for it - and
        // raises a clear error naming which one failed rather than silently refusing. Report that
        // explanation instead of letting an unhandled Failure speak for itself.
        var explanations = new Dictionary<string, string>
        {
            ["HA_IS_ENABLED"] = "HA is enabled on this pool; disable it first.",
            ["CANNOT_CONTACT_HOST"] = "a host in the pool is not reachable.",
            ["NOT_SUPPORTED_DURING_UPGRADE"] = "a rolling pool upgrade is in progress.",
            ["LICENCE_RESTRICTION"] = "this edition is not licensed for pool secret rotation.",
        };
        try
        {
            // A pool-wide operation; existing sessions survive it.
            Pool.rotate_secret(session);
            Console.WriteLine($"Rotated. Still connected: {Pool.get_all(session).Count == 1}");
        }
        catch (Failure f)
        {
            var explanation = explanations.TryGetValue(f.ErrorDescription[0], out var e) ? e : "see the error for detail";
            Console.WriteLine($"Could not rotate the pool secret: {f.ErrorDescription[0]} ({explanation})");
        }
        Console.WriteLine("OK: rotate-pool-secret");
        session.logout();
    }

    // --- Change the root password ------------------------------------------------------------
    private static void ChangeRootPassword(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        const string temporary = "sdk-example-temp-password";

        // session.change_password takes the OLD password as well as the new one, even though you are
        // already authenticated.
        Session.change_password(session, password, temporary);
        Console.WriteLine("Password changed.");

        // The existing session stays valid afterwards — only NEW connections need the new password, so a
        // script can carry on without reconnecting.
        Console.WriteLine($"Session still usable: {Pool.get_all(session).Count == 1}");

        // session.change_password on a ROOT session ignores the old password entirely (CA-13567): the
        // call succeeds regardless of what old_pwd is, so "supplying the wrong old password" is not a
        // real failure to demonstrate here. The real gate is who may call this at all.
        Console.WriteLine($"Is local superuser (may call change_password): {session.IsLocalSuperuser}");

        Session.change_password(session, temporary, password);
        Console.WriteLine("Password restored.");
        Console.WriteLine("OK: change-root-password");
        session.logout();
    }
    // Run it:
    //   ChangeRootPassword("https://xenserver", "root", password);

    // --- Manage TLS certificates ------------------------------------------------------------
    private static void ManageCertificates(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var hostRef = Host.get_all(session).First().opaque_ref;
        var poolRef = Pool.get_all(session).First().opaque_ref;
        var (certPem, keyPem) = SelfSignedCertPem();

        Console.WriteLine($"Certificates:   {Certificate.get_all(session).Count}");

        // ca=true: trusted as a root to verify a chain, not pinned as one specific leaf certificate.
        // purpose=[]: general pool trust, not the licensing/ldaps-specific uses that enum also covers.
        // install_trusted_certificate returns nothing, so find the new record by diffing the set - the
        // current API; install_ca_certificate/uninstall_ca_certificate are its deprecated predecessors.
        var before = Certificate.get_all(session).ToHashSet();
        Pool.install_trusted_certificate(session, poolRef, true, certPem, new List<certificate_purpose>());
        var certRef = Certificate.get_all(session).Except(before).First().opaque_ref;
        Console.WriteLine($"After CA add:   {Certificate.get_all(session).Count}");

        // Actually replace the host's own TLS identity with a real certificate (what this workflow's
        // name promises, beyond CA trust), then reset it back to a fresh self-signed one.
        Host.install_server_certificate(session, hostRef, certPem, keyPem, "");
        Console.WriteLine("Host certificate replaced with a real, generated certificate.");
        Host.reset_server_certificate(session, hostRef);
        Console.WriteLine("Host certificate reset (a fresh self-signed identity).");

        Pool.uninstall_trusted_certificate(session, poolRef, certRef);
        Console.WriteLine($"After CA remove:{Certificate.get_all(session).Count}");

        // Separately from which certificates exist: whether the pool actually CHECKS the ones its members
        // present to each other. Turning it on is a one-way door from here — there is no matching disable,
        // because a pool that could be talked out of verifying would not be verifying — so the call is
        // idempotent and safe to repeat.
        var pool = Pool.get_all(session).First().opaque_ref;
        Console.WriteLine($"TLS verification: {Pool.get_tls_verification_enabled(session, pool)}");
        Pool.enable_tls_verification(session);
        Console.WriteLine($"  after enabling: {Pool.get_tls_verification_enabled(session, pool)}");
        Console.WriteLine("OK: manage-certificates");
        session.logout();
    }

    // --- Snapshot schedule --------------------------------------------------------------
    private static void SnapshotSchedule(string url, string user, string password,
        string vmName, string scheduleName = "sdk-example-schedule")
    {
        var session = Connect(url, user, password);
        var vmRef = VmByName(session, vmName);

        // retained_snapshots is the interesting field: the schedule prunes to it every time it runs.
        var vmssRef = VMSS.create(session, new VMSS
        {
            name_label = scheduleName,
            name_description = "Scheduled snapshots created by the SDK example",
            enabled = true,
            type = vmss_type.snapshot,
            frequency = vmss_frequency.daily,
            retained_snapshots = 2,
            schedule = new Dictionary<string, string> { ["hour"] = "2", ["min"] = "0" },
        }).opaque_ref;
        Console.WriteLine($"Created schedule: {VMSS.get_uuid(session, vmssRef)}");

        VM.set_snapshot_schedule(session, vmRef, new XenRef<VMSS>(vmssRef));
        Console.WriteLine($"Members:          {VMSS.get_VMs(session, vmssRef).Count}");

        // Run it three times against a retention of two: the oldest is pruned away. Compare against the
        // snapshots the VM already had, so only the schedule's own are counted (and tidied up below).
        var before = VM.get_snapshots(session, vmRef).Select(s => s.opaque_ref).ToHashSet();
        for (var i = 0; i < 3; i++) VMSS.snapshot_now(session, vmssRef);
        var kept = VM.get_snapshots(session, vmRef).Select(s => s.opaque_ref).Where(s => !before.Contains(s)).ToList();
        Console.WriteLine($"Snapshots kept:   {kept.Count} (retention 2)");

        // Tidy up: a schedule with VMs still on it cannot be destroyed (VMSS_HAS_VM), so take the VM off it
        // first. Destroying the schedule leaves the snapshots it took, so destroy those too, with their disks.
        VM.set_snapshot_schedule(session, vmRef, new XenRef<VMSS>("OpaqueRef:NULL"));
        VMSS.destroy(session, vmssRef);
        foreach (var snapshot in kept) DestroyVmAndDisks(session, snapshot);
        Console.WriteLine("OK: snapshot-schedule");
        session.logout();
    }
    // Run it:
    //   SnapshotSchedule("https://xenserver", "root", password, "web-01");

    // --- Manage VM groups ---------------------------------------------------------------
    private static void ManageVmGroups(string url, string user, string password,
        string vmName, string groupName = "sdk-example-group")
    {
        var session = Connect(url, user, password);
        var vmRef = VmByName(session, vmName);

        // anti_affinity asks the pool to keep the group's members on different hosts.
        var groupRef = VM_group.create(session, new VM_group
        {
            name_label = groupName,
            name_description = "Anti-affinity group created by the SDK example",
            placement = placement_policy.anti_affinity,
        }).opaque_ref;
        Console.WriteLine($"Created group:  {VM_group.get_uuid(session, groupRef)}");

        // Membership is written from the VM side...
        VM.set_groups(session, vmRef, new List<XenRef<VM_group>> { new(groupRef) });

        // ...and read back from the group side, which is the half that is easy to get wrong.
        var members = VM_group.get_VMs(session, groupRef);
        Console.WriteLine($"Group members:  {members.Count}");
        foreach (var m in members)
            Console.WriteLine($"  {VM.get_name_label(session, m.opaque_ref)}");

        // VM_group.destroy already clears the group from every member VM's groups field - no need to
        // remove membership ourselves first.
        VM_group.destroy(session, groupRef);
        Console.WriteLine("OK: manage-vm-groups");
        session.logout();
    }
    // Run it:
    //   ManageVmGroups("https://xenserver", "root", password, "web-01");

    // --- Snapshot & revert -----------------------------------------------------------
    private static void SnapshotRevert(string url, string user, string password,
        string vmName, string snapshotName = "sdk-example-snapshot")
    {
        var session = Connect(url, user, password);
        var vmRef = VmByName(session, vmName);
        Console.WriteLine($"Snapshotting VM: {VM.get_name_label(session, vmRef)}");
        var wasRunning = VM.get_power_state(session, vmRef) == vm_power_state.Running;

        var snapRef = VM.snapshot(session, vmRef, snapshotName).opaque_ref;
        Console.WriteLine($"Created snapshot: {VM.get_uuid(session, snapRef)}");

        // A client shows a thumbnail of what was on screen when the snapshot was taken, captured from the
        // VM's console at that moment. It is an HTTP transfer alongside the API, not an API call, so the
        // session id travels in the query string. Only a running VM has a console to capture: the server
        // answers HTTP 500 for a halted VM, and for the snapshot record itself.
        if (VM.get_power_state(session, vmRef) == vm_power_state.Running)
        {
            using var client = InsecureHttpClient();
            var bytes = client.GetByteArrayAsync(
                $"{url}/vncsnapshot?session_id={session.opaque_ref}&ref={vmRef}").Result;
            Console.WriteLine($"Thumbnail:      {bytes.Length} bytes of PNG");
        }
        else
        {
            Console.WriteLine("Thumbnail:      none (the VM is not running, so it has no console)");
        }

        // Reverting to a plain snapshot always leaves the VM Halted (xapi hard-shuts-down a running VM
        // before reverting it), even if it was Running a moment ago - restart it afterwards if that's
        // how we found it, so the workflow actually restores what it changed.
        VM.revert(session, snapRef);
        Console.WriteLine("Reverted VM to the snapshot.");

        if (wasRunning)
        {
            VM.start(session, vmRef, false, true);
            Console.WriteLine("Restarted the VM (it was running before the revert).");
        }

        DestroyVmAndDisks(session, snapRef);
        Console.WriteLine("OK: snapshot-revert");
        session.logout();
    }
    // Run it:
    //   SnapshotRevert("https://xenserver", "root", password, "web-01");

    // --- 5. Create an NFS storage repository --------------------------------------------
    private static void CreateNfsSr(string url, string user, string password,
        string nfsServer, string nfsPath, string srName = "sdk-example-nfs")
    {
        var session = Connect(url, user, password);
        var hostRef = Host.get_all_records(session).Keys.First().opaque_ref;
        var deviceConfig = new Dictionary<string, string>
        {
            ["server"] = nfsServer,
            ["serverpath"] = nfsPath,
            ["nfsversion"] = "3",
        };

        var srRef = SR.create(session, hostRef, deviceConfig, 0,
            srName, "NFS SR created by the SDK example",
            "nfs", "user", true, new Dictionary<string, string>());
        Console.WriteLine($"Created SR: {SR.get_uuid(session, srRef.opaque_ref)}");

        DetachAndForgetSr(session, srRef.opaque_ref);
        Console.WriteLine("OK: create-nfs-sr");
        session.logout();
    }
    // Run it:
    //   CreateNfsSr("https://xenserver", "root", password, "192.0.2.10", "/export/sdk");

    // --- 6. Create a network ------------------------------------------------------------
    private static void CreateNetwork(string url, string user, string password,
        string networkName = "sdk-example-net")
    {
        var session = Connect(url, user, password);
        var record = new Network
        {
            name_label = networkName,
            name_description = "Internal network created by the SDK example",
            MTU = 1500,
            other_config = new Dictionary<string, string>(),
        };
        var netRef = Network.create(session, record);
        Console.WriteLine($"Created network: {Network.get_uuid(session, netRef.opaque_ref)}");

        // Raise the MTU to use jumbo frames. Every NIC and switch along the path has to agree, so this is
        // a property of the network rather than of any one interface on it.
        Network.set_MTU(session, netRef.opaque_ref, 9000);
        Console.WriteLine($"MTU now:         {Network.get_MTU(session, netRef.opaque_ref)}");

        Network.destroy(session, netRef.opaque_ref);
        Console.WriteLine("OK: create-network");
        session.logout();
    }
    // Run it:
    //   CreateNetwork("https://xenserver", "root", password, "sdk-example-net");

    // --- 7. Edit VM properties ----------------------------------------------------------
    private static void EditVmProperties(string url, string user, string password, string vmName)
    {
        var session = Connect(url, user, password);
        var vmRef = VmByName(session, vmName);

        var originalDesc = VM.get_name_description(session, vmRef);
        VM.set_name_description(session, vmRef, "Edited by the SDK example");
        VM.add_to_other_config(session, vmRef, "sdk_example", "true");
        Console.WriteLine($"New description: {VM.get_name_description(session, vmRef)}");
        Console.WriteLine($"other_config[sdk_example] = {VM.get_other_config(session, vmRef)["sdk_example"]}");

        VM.set_name_description(session, vmRef, originalDesc);
        VM.remove_from_other_config(session, vmRef, "sdk_example");
        Console.WriteLine("OK: edit-vm-properties");
        session.logout();
    }
    // Run it:
    //   EditVmProperties("https://xenserver", "root", password, "web-01");

    // --- 8. Event monitoring ------------------------------------------------------------
    private static void Events(string url, string user, string password, string vmName)
    {
        var session = Connect(url, user, password);
        var classes = new[] { "VM" };
        var batch = (EventBatch)Event.from(session, classes, "", 1.0);
        var token = batch.token;
        Console.WriteLine("Established event token after initial snapshot.");

        var vmRef = VmByName(session, vmName);
        var original = VM.get_name_description(session, vmRef);
        VM.set_name_description(session, vmRef, "changed-to-trigger-event");

        batch = (EventBatch)Event.from(session, classes, token, 5.0);
        Console.WriteLine($"Received {batch.events.Length} event(s) after the change.");
        foreach (var ev in batch.events.Take(3))
            Console.WriteLine($"  - {ev.operation} {ev.class_}");

        VM.set_name_description(session, vmRef, original); // put it back
        Console.WriteLine("OK: events");
        session.logout();
    }
    // Run it:
    //   Events("https://xenserver", "root", password, "web-01");

    // --- 9. New VM wizard (full) --------------------------------------------------------
    private static void NewVmWizard(string url, string user, string password,
        string templateName, string newVmName = "wizard-vm")
    {
        const long GiB = 1024L * 1024 * 1024, MiB = 1024L * 1024;

        var session = Connect(url, user, password);
        // Page 1 - Template.
        var templateRef = TemplateByName(session, templateName);
        Console.WriteLine($"Template:      {VM.get_name_label(session, templateRef)}");

        // Page 2 - Name and description.
        var vm = VM.clone(session, templateRef, newVmName).opaque_ref;
        VM.set_name_description(session, vm, "Created by the full New VM wizard example");
        VM.set_is_a_template(session, vm, false);
        Console.WriteLine($"Created VM:    {VM.get_uuid(session, vm)}");

        // Page 3 - Installation media (a network install repository).
        VM.add_to_other_config(session, vm, "install-repository", "http://mirror.example.com/rocky/9/os/x86_64");
        Console.WriteLine("Install media: network repository");

        // Page 4 - Home server (affinity).
        var (hostRef, host) = Host.get_all_records(session).First();
        VM.set_affinity(session, vm, hostRef.opaque_ref);
        Console.WriteLine($"Home server:   {host.name_label}");

        // Page 5 - CPU & Memory.
        VM.set_VCPUs_max(session, vm, 2);
        VM.set_VCPUs_at_startup(session, vm, 2);
        VM.set_memory_limits(session, vm, 512 * MiB, 2 * GiB, 2 * GiB, 2 * GiB);
        Console.WriteLine("CPU/memory:    2 vCPUs, 2 GiB");

        // Page 6 - Storage: add a disk on a (non-ISO) SR.
        var (srRef, sr) = SR.get_all_records(session)
            .First(kv => kv.Value.content_type != "iso" && kv.Value.type != "iso" && kv.Value.type != "udev");
        var vbdDevice = VM.get_allowed_VBD_devices(session, vm)[0];
        var vdi = VDI.create(session, new VDI
        {
            name_label = $"{newVmName} disk 0",
            name_description = "System disk created by the wizard example",
            SR = srRef,
            virtual_size = 24 * GiB,
            type = vdi_type.system,
            sharable = false,
            read_only = false,
            other_config = new Dictionary<string, string>(),
        }).opaque_ref;
        VBD.create(session, new VBD
        {
            VM = new XenRef<VM>(vm),
            VDI = new XenRef<VDI>(vdi),
            userdevice = vbdDevice,
            bootable = true,
            mode = vbd_mode.RW,
            type = vbd_type.Disk,
            empty = false,
            other_config = new Dictionary<string, string>(),
            qos_algorithm_type = "",
            qos_algorithm_params = new Dictionary<string, string>(),
        });
        Console.WriteLine($"Storage:       24 GiB disk on {sr.name_label}");

        // Page 7 - Networking: attach a VIF to a network.
        var (netRef, net) = Network.get_all_records(session).First();
        var vifDevice = VM.get_allowed_VIF_devices(session, vm)[0];
        VIF.create(session, new VIF
        {
            VM = new XenRef<VM>(vm),
            network = netRef,
            device = vifDevice,
            MAC = "",
            MTU = 1500,
            other_config = new Dictionary<string, string>(),
            qos_algorithm_type = "",
            qos_algorithm_params = new Dictionary<string, string>(),
        });
        Console.WriteLine($"Networking:    NIC on {net.name_label}");

        // Page 8 - Finish: start the VM.
        VM.start(session, vm, false, true);

        Console.WriteLine("--- Result ---");
        Console.WriteLine($"power state:   {VM.get_power_state(session, vm)}");
        Console.WriteLine($"vCPUs:         {VM.get_VCPUs_max(session, vm)}");
        Console.WriteLine($"disks:         {VM.get_VBDs(session, vm).Count}, NICs: {VM.get_VIFs(session, vm).Count}");

        // Tidy up so the example is repeatable.
        VM.hard_shutdown(session, vm);
        VM.destroy(session, vm);
        VDI.destroy(session, vdi);
        Console.WriteLine("Cleaned up the example VM.");

        Console.WriteLine("OK: new-vm-wizard");
        session.logout();
    }
    // Run it:
    //   NewVmWizard("https://xenserver", "root", password, "Rocky Linux 8");

    // --- 10. Live migrate a VM ----------------------------------------------------------
    private static void LiveMigrate(string url, string user, string password,
        string sourceVm, string srName, string newVmName = "sdk-example-migrate")
    {
        var session = Connect(url, user, password);
        // Moves a throwaway copy of sourceVm, a VM with a guest OS and PV drivers: live migration
        // needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers). Only the VM's memory
        // moves, so the destination host has to see its disks already: a disk on local storage
        // refuses with VM_REQUIRES_SR. Put the copy's disks on the shared SR srName first.
        var vm = CopyOfGuest(session, sourceVm, newVmName);
        MoveDisksToSr(session, vm, SrByName(session, srName, shared: true));
        VM.start(session, vm, false, true);
        WaitForGuestAgent(session, vm);

        var sourceHost = VM.get_resident_on(session, vm).opaque_ref;
        Console.WriteLine($"VM is running on: {Host.get_name_label(session, sourceHost)}");

        // Pick a different host in the pool to receive the VM.
        var destHost = Host.get_all_records(session).Keys.First(h => h.opaque_ref != sourceHost).opaque_ref;

        // Check the destination can boot it, then live-migrate (empty options = default live migration).
        VM.assert_can_boot_here(session, vm, destHost);
        VM.pool_migrate(session, vm, destHost, new Dictionary<string, string>());

        Console.WriteLine($"Migrated to:      {Host.get_name_label(session, VM.get_resident_on(session, vm).opaque_ref)}");
        Console.WriteLine($"Still running:    {VM.get_power_state(session, vm)}");

        // Tidy up so the example is repeatable.
        VM.hard_shutdown(session, vm);
        DestroyVmAndDisks(session, vm);
        Console.WriteLine("OK: live-migrate");
        session.logout();
    }
    // Run it:
    //   LiveMigrate("https://xenserver", "root", password, "web-01", "Shared NFS");

    // --- 11. Enter & exit maintenance mode ----------------------------------------------
    private static void HostMaintenance(string url, string user, string password,
        string sourceVm, string srName, string newVmName = "sdk-example-maint")
    {
        var session = Connect(url, user, password);
        // Choose a host that is not the pool coordinator, so the coordinator can receive its guests.
        var master = Pool.get_all_records(session).Values.First().master.opaque_ref;
        var hostRef = Host.get_all_records(session).Keys.First(h => h.opaque_ref != master).opaque_ref;
        Console.WriteLine($"Maintenance host: {Host.get_name_label(session, hostRef)}");

        // Pin a throwaway copy of sourceVm to that host so evacuation has something to move.
        // Evacuation live-migrates the guest, which needs its cooperation (VM_LACKS_FEATURE without PV
        // drivers), so sourceVm must have a guest OS with PV drivers. Evacuation also needs somewhere
        // else in the pool that can actually see the VM's disk - a VM whose only disk is on local
        // (non-shared) storage can't be evacuated at all (VM_REQUIRES_SR), and a pool's installation-time
        // default SR is commonly local storage, so put the pinned VM's disk on a shared SR explicitly.
        var vm = CopyOfGuest(session, sourceVm, newVmName);
        MoveDisksToSr(session, vm, SrByName(session, srName, shared: true));
        VM.set_affinity(session, vm, hostRef);
        VM.start(session, vm, false, true);
        WaitForGuestAgent(session, vm);
        Console.WriteLine($"Guest resident on:{Host.get_name_label(session, VM.get_resident_on(session, vm).opaque_ref)}");

        // Enter maintenance mode: disable the host, then evacuate its guests.
        Host.disable(session, hostRef);
        Console.WriteLine($"After disable:    host.enabled = {Host.get_enabled(session, hostRef)}");
        Host.evacuate(session, hostRef);
        Console.WriteLine($"After evacuate:   guest now on {Host.get_name_label(session, VM.get_resident_on(session, vm).opaque_ref)}");

        // Exit maintenance mode.
        Host.enable(session, hostRef);
        Console.WriteLine($"After enable:     host.enabled = {Host.get_enabled(session, hostRef)}");

        // Tidy up so the example is repeatable.
        VM.hard_shutdown(session, vm);
        DestroyVmAndDisks(session, vm);
        Console.WriteLine("OK: host-maintenance");
        session.logout();
    }
    // Run it:
    //   HostMaintenance("https://xenserver", "root", password, "web-01", "Shared NFS");

    // --- 12. Configure high availability ------------------------------------------------
    private static void ConfigureHa(string url, string user, string password, string heartbeatSrName)
    {
        var session = Connect(url, user, password);
        var poolRef = Pool.get_all_records(session).Keys.First().opaque_ref;

        // The HA heartbeat statefile needs a shared SR; confirm the chosen one can host it.
        var srRef = SrByName(session, heartbeatSrName, shared: true);
        Console.WriteLine($"Heartbeat SR:  {SR.get_name_label(session, srRef)}");
        SR.assert_can_host_ha_statefile(session, srRef);

        // How many host failures can the pool tolerate? Set that as the target and enable HA.
        var ntol = Pool.ha_compute_hypothetical_max_host_failures_to_tolerate(
            session, new Dictionary<XenRef<VM>, string>());
        Console.WriteLine($"Max failures:  {ntol}");
        Pool.set_ha_host_failures_to_tolerate(session, poolRef, ntol);
        Pool.enable_ha(session, new List<XenRef<SR>> { new(srRef) }, new Dictionary<string, string>());
        Console.WriteLine($"HA enabled:    {Pool.get_ha_enabled(session, poolRef)}");

        // What HA does per VM. The restart priority decides which guests come back first after a host
        // failure, and whether a VM is protected at all; "restart" is protected, an empty string is not.
        var guest = VM.get_all_records(session).First(kv =>
            !kv.Value.is_a_template && !kv.Value.is_control_domain && !kv.Value.is_a_snapshot).Key.opaque_ref;
        var wasPriority = VM.get_ha_restart_priority(session, guest);
        VM.set_ha_restart_priority(session, guest, "restart");
        Console.WriteLine($"{VM.get_name_label(session, guest)} priority: '{wasPriority}' -> " +
            $"'{VM.get_ha_restart_priority(session, guest)}'");
        VM.set_ha_restart_priority(session, guest, wasPriority);

        // And a pool-wide judgement call: if a guest shuts itself down from the inside, is that a
        // failure HA should undo, or an administrator's intent it should respect?
        var restartOnInternalShutdown = Pool.get_ha_reboot_vm_on_internal_shutdown(session, poolRef);
        Console.WriteLine($"Restart on internal shutdown: {restartOnInternalShutdown}");

        // Turn HA back off so the example is repeatable.
        Pool.disable_ha(session);
        Console.WriteLine($"HA enabled:    {Pool.get_ha_enabled(session, poolRef)}");
        Console.WriteLine("OK: configure-ha");
        session.logout();
    }
    // Run it:
    //   ConfigureHa("https://xenserver", "root", password, "Shared NFS");

    // --- 13. Copy a VM ------------------------------------------------------------------
    private static void CopyVm(string url, string user, string password,
        string vmName, string srName, string copyName = "sdk-example-copy")
    {
        var session = Connect(url, user, password);
        // A full copy needs a halted source; it places an independent set of disks on the chosen SR.
        // VM.copy (like VM.clone) raises VM_BAD_POWER_STATE on a running source, so shut it down first
        // if it's running, and start it back up again after the copy.
        var source = VmByName(session, vmName);
        var (srRef, sr) = SR.get_all_records(session).First(kv => kv.Value.name_label == srName);
        Console.WriteLine($"Copying '{VM.get_name_label(session, source)}' to SR: {sr.name_label}");

        var wasRunning = VM.get_power_state(session, source) == vm_power_state.Running;
        if (wasRunning) VM.clean_shutdown(session, source);

        var copy = VM.copy(session, source, copyName, srRef).opaque_ref;
        Console.WriteLine($"Copied VM:     {VM.get_uuid(session, copy)}");
        Console.WriteLine($"Copy has {VM.get_VBDs(session, copy).Count} VBD(s), is_a_template = {VM.get_is_a_template(session, copy)}");

        if (wasRunning) VM.start(session, source, false, true);

        // Tidy up: destroy the copy and its disks, leaving the source VM intact.
        DestroyVmAndDisks(session, copy);
        Console.WriteLine("Cleaned up the copied VM (left the source intact).");
        Console.WriteLine("OK: copy-vm");
        session.logout();
    }
    // Run it:
    //   CopyVm("https://xenserver", "root", password, "db-01", "Shared NFS");

    /// <summary>The VDIs backing a VM's disk VBDs (used to clean up a full copy's independent disks).</summary>
    private static List<string> DiskVdis(Session session, string vmRef)
    {
        var vdis = new List<string>();
        foreach (var vbdRef in VM.get_VBDs(session, vmRef))
        {
            if (VBD.get_type(session, vbdRef.opaque_ref) != vbd_type.Disk) continue;
            var vdi = VBD.get_VDI(session, vbdRef.opaque_ref).opaque_ref;
            if (vdi != "OpaqueRef:NULL") vdis.Add(vdi);
        }
        return vdis;
    }

    /// <summary>
    /// VM.destroy leaves a VM's (or snapshot's/template's) disks behind; this collects them first and
    /// destroys them afterwards, the way delete-vm does for a VM it created.
    /// </summary>
    private static void DestroyVmAndDisks(Session session, string vm)
    {
        var vdis = DiskVdis(session, vm);
        // A checkpoint (or a suspended VM) also owns a suspend image holding its memory, which no VBD
        // points at: destroy that as well.
        var suspendVdi = VM.get_suspend_VDI(session, vm).opaque_ref;
        if (suspendVdi != "OpaqueRef:NULL") vdis.Add(suspendVdi);
        VM.destroy(session, vm);
        foreach (var vdi in vdis) VDI.destroy(session, vdi);
    }

    // --- 14. Create a VM with a vGPU ----------------------------------------------------
    private static void CreateVmWithVgpu(string url, string user, string password,
        string templateName, string newVmName = "sdk-example-vgpu-vm")
    {
        var session = Connect(url, user, password);
        // Find a GPU group that offers a real (non-passthrough) vGPU type, plus that type.
        var (groupRef, typeRef) = GpuGroupWithVgpuType(session);
        var typeRec = VGPU_type.get_record(session, typeRef);
        Console.WriteLine($"Using vGPU type: {typeRec.model_name} ({typeRec.framebuffer_size / (1024 * 1024)} MB framebuffer)");

        // Provision a fresh VM from the template to attach the vGPU to.
        var templateRef = TemplateByName(session, templateName);
        var vmRef = VM.clone(session, templateRef, newVmName).opaque_ref;
        Provision(session, vmRef);

        // Assign the vGPU: device "0" is the VM's first vGPU slot, other_config is empty. This is the
        // same call XenCenter makes from the New VM wizard GPU page and the VM Properties GPU page.
        var vgpuRef = VGPU.create(session, vmRef, groupRef, "0", new Dictionary<string, string>(), typeRef).opaque_ref;
        Console.WriteLine($"Created vGPU: {VGPU.get_uuid(session, vgpuRef)}");

        // Read the assignment back, as XenCenter's GPU tab does.
        var vgpus = VM.get_VGPUs(session, vmRef);
        var assigned = VGPU_type.get_model_name(session, VGPU.get_type(session, vgpus[0].opaque_ref).opaque_ref);
        Console.WriteLine($"VM now has {vgpus.Count} vGPU(s); type = {assigned}");

        // Tidy up so the example is repeatable.
        VGPU.destroy(session, vgpuRef);
        DestroyVmAndDisks(session, vmRef);
        Console.WriteLine("Cleaned up the example VM and its vGPU.");
        Console.WriteLine("OK: create-vm-with-vgpu");
        session.logout();
    }
    // Run it:
    //   CreateVmWithVgpu("https://xenserver", "root", password, "Rocky Linux 8");

    /// <summary>Find a (GPU_group, VGPU_type) pair where the group offers a non-passthrough vGPU type.</summary>
    private static (string, string) GpuGroupWithVgpuType(Session session)
    {
        foreach (var (groupRef, group) in GPU_group.get_all_records(session))
        {
            if (group.PGPUs.Count == 0) continue;
            foreach (var typeRef in group.supported_VGPU_types)
                if (VGPU_type.get_model_name(session, typeRef.opaque_ref) != "passthrough")
                    return (groupRef.opaque_ref, typeRef.opaque_ref);
        }
        throw new Exception("no GPU group offers a vGPU type");
    }

    // --- 15. Tag and organize objects --------------------------------------------------
    private static void TagsAndFolders(string url, string user, string password, string vmName)
    {
        var session = Connect(url, user, password);
        var vm = VmByName(session, vmName);
        var host = Host.get_all(session)[0].opaque_ref;

        // Tags work on any object type (VM, host, SR, network, …).
        VM.add_tags(session, vm, "web");
        Host.add_tags(session, host, "gold");
        Console.WriteLine($"VM tags:   {string.Join(", ", VM.get_tags(session, vm))}");
        Console.WriteLine($"Host tags: {string.Join(", ", Host.get_tags(session, host))}");

        // Folder placement lives in other_config["folder"] as a leading-slash path.
        VM.add_to_other_config(session, vm, "folder", "/Production/Web");
        Console.WriteLine($"VM folder: {VM.get_other_config(session, vm)["folder"]}");

        VM.remove_tags(session, vm, "web");
        Host.remove_tags(session, host, "gold");
        VM.remove_from_other_config(session, vm, "folder");
        Console.WriteLine("OK: tags-and-folders");
        session.logout();
    }
    // Run it:
    //   TagsAndFolders("https://xenserver", "root", password, "web-01");

    // --- 16. Configure updates (CDN) ---------------------------------------------------
    private static void ConfigureUpdates(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        // update=true: without it this introduces only a base package mirror, not an actual UPDATE
        // repository - pool.sync_updates needs one with update=true enabled (NO_REPOSITORY_ENABLED
        // otherwise), which is exactly what apply-update and rolling-pool-update rely on.
        var repo = Repository.introduce(session, "sdk-cdn", "SDK example repository",
            "https://cdn.example/base", "https://cdn.example/source", true, "").opaque_ref;
        Console.WriteLine($"Introduced repository: {Repository.get_name_label(session, repo)}");

        var pool = Pool.get_all(session)[0].opaque_ref;
        // Remember the pool's own repositories, to put them back afterwards.
        var previous = Pool.get_repositories(session, pool);
        Pool.set_repositories(session, pool, new List<XenRef<Repository>> { new(repo) });
        Pool.set_update_sync_enabled(session, pool, true);
        Console.WriteLine($"Pool repositories: {Pool.get_repositories(session, pool).Count}; " +
            $"auto-sync enabled: {Pool.get_update_sync_enabled(session, pool)}");

        // Tidy up so the example is repeatable.
        Pool.set_update_sync_enabled(session, pool, false);
        Pool.set_repositories(session, pool, previous);
        Repository.forget(session, repo);
        Console.WriteLine("OK: configure-updates");
        session.logout();
    }
    // Run it:
    //   ConfigureUpdates("https://xenserver", "root", password);

    // --- 17. Clone a VM (fast, copy-on-write) ------------------------------------------
    private static void CloneVm(string url, string user, string password,
        string vmName, string cloneName = "sdk-example-clone")
    {
        var session = Connect(url, user, password);
        // Unlike Copy (a full, independent copy onto a chosen SR), Clone is a fast copy-on-write
        // duplicate on the same SR — ideal for a halted "golden" VM.
        var source = VmByName(session, vmName);
        var clone = VM.clone(session, source, cloneName).opaque_ref;
        Console.WriteLine($"Cloned '{VM.get_name_label(session, source)}' → {VM.get_name_label(session, clone)}");
        Console.WriteLine($"Clone has {VM.get_VBDs(session, clone).Count} VBD(s)");

        // Tidy up: destroy the clone and its (owned) disks.
        DestroyVmAndDisks(session, clone);
        Console.WriteLine("OK: clone-vm");
        session.logout();
    }
    // Run it:
    //   CloneVm("https://xenserver", "root", password, "db-01");

    // --- 18. Delete a VM ---------------------------------------------------------------
    private static void DeleteVm(string url, string user, string password,
        string templateName, string newVmName = "sdk-example-delete")
    {
        var session = Connect(url, user, password);
        // Make a throwaway VM to delete. VM.destroy removes the VM but leaves its disks, so the
        // owned VDIs are destroyed explicitly afterward — exactly what XenCenter's Delete VM does.
        var vm = VM.clone(session, TemplateByName(session, templateName), newVmName).opaque_ref;
        Provision(session, vm);
        var uuid = VM.get_uuid(session, vm);
        var vdis = DiskVdis(session, vm);
        Console.WriteLine($"Deleting VM {uuid} with {vdis.Count} disk(s)");

        VM.destroy(session, vm);
        foreach (var vdi in vdis) VDI.destroy(session, vdi);

        var stillThere = VM.get_all_records(session).Values.Any(v => v.uuid == uuid);
        Console.WriteLine($"VM still present: {stillThere}");
        Console.WriteLine("OK: delete-vm");
        session.logout();
    }
    // Run it:
    //   DeleteVm("https://xenserver", "root", password, "Rocky Linux 8");

    // --- 19. Storage live-migration (move a disk to another SR) -------------------------
    private static void StorageMigrate(string url, string user, string password,
        string sourceVm, string newVmName = "sdk-example-storagemigrate")
    {
        var session = Connect(url, user, password);
        // Moving a running VM's disk needs the guest's cooperation (VM_LACKS_FEATURE without PV
        // drivers), so this works on a throwaway copy of sourceVm, a VM with a guest OS and PV drivers.
        // (A halted VM's disk moves too, without the guest; what VDI.pool_migrate always needs is a VM
        // to move the disk for - a VDI no VBD points at fails VDI_NEEDS_VM_FOR_MIGRATE.)
        var vm = CopyOfGuest(session, sourceVm, newVmName);
        VM.start(session, vm, false, true);
        WaitForGuestAgent(session, vm);
        var vdi = DiskVdis(session, vm).First();
        var sourceSr = VDI.get_SR(session, vdi).opaque_ref;
        Console.WriteLine($"Disk is on SR: {SR.get_name_label(session, sourceSr)}");

        // Pick a different SR that holds disks and that the VM's host can reach (an attached PBD
        // there).
        var host = VM.get_resident_on(session, vm).opaque_ref;
        var destSr = SR.get_all_records(session)
            .First(kv => kv.Key.opaque_ref != sourceSr && kv.Value.content_type != "iso"
                && kv.Value.type != "iso" && kv.Value.type != "udev"
                && kv.Value.PBDs.Any(pbd => PBD.get_host(session, pbd.opaque_ref).opaque_ref == host
                    && PBD.get_currently_attached(session, pbd.opaque_ref))).Key.opaque_ref;
        // pool_migrate returns the disk's new VDI: the copy on the destination SR replaces the
        // original. Copying a disk takes minutes, so run it as a task (see AwaitTask).
        vdi = AwaitTask(session, VDI.async_pool_migrate(session, vdi, destSr, new Dictionary<string, string>()));

        var nowOn = VDI.get_SR(session, vdi).opaque_ref;
        Console.WriteLine($"Disk moved to:  {SR.get_name_label(session, nowOn)}");

        // Tidy up: the VM and the disks it now owns.
        VM.hard_shutdown(session, vm);
        DestroyVmAndDisks(session, vm);
        Console.WriteLine("OK: storage-migrate");
        session.logout();
    }
    // Run it:
    //   StorageMigrate("https://xenserver", "root", password, "web-01");

    // --- 20. Apply updates from the CDN ------------------------------------------------
    private static void ApplyUpdate(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        // pool.sync_updates needs at least one repository with update=true enabled
        // (NO_REPOSITORY_ENABLED otherwise) - introduce and attach a throwaway one, and forget it again
        // afterwards.
        var pool = Pool.get_all(session)[0].opaque_ref;
        var repo = Repository.introduce(session, "sdk-cdn", "SDK example repository",
            "https://cdn.example/base", "https://cdn.example/source", true, "").opaque_ref;
        // Remember the pool's own repositories, to put them back afterwards.
        var previous = Pool.get_repositories(session, pool);
        Pool.set_repositories(session, pool, new List<XenRef<Repository>> { new(repo) });
        try
        {
            // Sync the pool's update metadata; the returned hash identifies the synced set.
            var hash = Pool.sync_updates(session, pool, false, "", "");
            Console.WriteLine($"Synced updates; hash length {hash.Length}");

            // Apply the synced updates to each host. XenCenter then reads the reboot guidance to decide
            // whether a Rolling Pool Upgrade reboot is needed. Applying a batch whose mandatory guidance
            // needs an evacuation fails with HOST_EVACUATION_IS_REQUIRED unless the host's resident VMs
            // are moved off first - handle that rather than assuming an update batch never needs one.
            foreach (var (hostRef, host) in Host.get_all_records(session))
            {
                try
                {
                    Host.apply_updates(session, hostRef.opaque_ref, hash);
                }
                catch (Failure f) when (f.ErrorDescription[0] == "HOST_EVACUATION_IS_REQUIRED")
                {
                    Console.WriteLine($"  {host.name_label}: needs evacuating first; evacuating and retrying");
                    Host.disable(session, hostRef.opaque_ref);
                    Host.evacuate(session, hostRef.opaque_ref);
                    Host.apply_updates(session, hostRef.opaque_ref, hash);
                    Host.enable(session, hostRef.opaque_ref);
                }
                var guidance = Host.get_pending_guidances(session, hostRef.opaque_ref);
                Console.WriteLine($"  {host.name_label}: applied; pending guidance = " +
                                  $"[{string.Join(", ", guidance)}]");
                // Modern xapi (>=23.18.0) doesn't reboot a host for you: it only records pending_guidances,
                // so only reboot (or restart the toolstack) when the applied batch actually asks for it.
                if (guidance.Contains(update_guidances.reboot_host))
                    Host.reboot(session, hostRef.opaque_ref);
                else if (guidance.Contains(update_guidances.restart_toolstack))
                    Host.restart_agent(session, hostRef.opaque_ref);
            }
        }
        finally
        {
            Pool.set_repositories(session, pool, previous);
            Repository.forget(session, repo);
        }
        Console.WriteLine("OK: apply-update");
        session.logout();
    }
    // Run it:
    //   ApplyUpdate("https://xenserver", "root", password);

    // --- 21. Checkpoint & revert -------------------------------------------------------
    private static void CheckpointVm(string url, string user, string password,
        string sourceVm, string newVmName = "sdk-example-checkpoint")
    {
        var session = Connect(url, user, password);
        // A checkpoint captures disk AND memory (unlike a plain snapshot), so the VM must be running.
        // Checkpointing needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers), hence a
        // copy of sourceVm - a VM with a guest OS and PV drivers - rather than an OS-less template
        // clone.
        var vm = CopyOfGuest(session, sourceVm, newVmName);
        VM.start(session, vm, false, true);
        WaitForGuestAgent(session, vm);

        var checkpoint = VM.checkpoint(session, vm, "sdk-example-checkpoint-1").opaque_ref;
        Console.WriteLine($"Created checkpoint: {VM.get_uuid(session, checkpoint)}");
        Console.WriteLine($"is_a_snapshot = {VM.get_is_a_snapshot(session, checkpoint)}");

        // A checkpoint's own power_state is always Suspended (it captures memory as well as disk), and
        // VM.revert restores exactly that - so the VM is Suspended here, not Running as it was before
        // the checkpoint, with a suspend_VDI holding the checkpoint's memory image. Always resume
        // (never a bare "if Running: hard_shutdown" check, which never fires since the VM is never
        // Running here) before destroying it, or the suspend_VDI leaks as a storage orphan.
        VM.revert(session, checkpoint);
        Console.WriteLine($"Reverted the VM to the checkpoint; power state now: {VM.get_power_state(session, vm)}");
        VM.resume(session, vm, false, true);

        // Tidy up. The checkpoint owns its own snapshot disks, separate from the VM's.
        DestroyVmAndDisks(session, checkpoint);
        VM.hard_shutdown(session, vm);
        DestroyVmAndDisks(session, vm);
        Console.WriteLine("OK: checkpoint-vm");
        session.logout();
    }
    // Run it:
    //   CheckpointVm("https://xenserver", "root", password, "web-01");

    // --- 22. Attach a new disk to a VM -------------------------------------------------
    private static void AttachDisk(string url, string user, string password,
        string templateName, string srName, string newVmName = "sdk-example-attachdisk")
    {
        const long GiB = 1024L * 1024 * 1024;
        var session = Connect(url, user, password);
        var vm = VM.clone(session, TemplateByName(session, templateName), newVmName).opaque_ref;
        Provision(session, vm);
        var srRef = SrByName(session, srName);

        // Create a fresh VDI on the SR and attach it as a new VBD (a new virtual disk).
        var vdi = VDI.create(session, new VDI
        {
            name_label = "sdk-example-data-disk",
            SR = new XenRef<SR>(srRef),
            virtual_size = 8 * GiB,
            type = vdi_type.user,
            sharable = false,
            read_only = false,
            other_config = new Dictionary<string, string>(),
        }).opaque_ref;
        var device = VM.get_allowed_VBD_devices(session, vm)[0];
        VBD.create(session, new VBD
        {
            VM = new XenRef<VM>(vm),
            VDI = new XenRef<VDI>(vdi),
            userdevice = device,
            mode = vbd_mode.RW,
            type = vbd_type.Disk,
            empty = false,
            other_config = new Dictionary<string, string>(),
            qos_algorithm_type = "",
            qos_algorithm_params = new Dictionary<string, string>(),
        });
        Console.WriteLine($"Attached an 8 GiB disk on {SR.get_name_label(session, srRef)} as device {device}");
        Console.WriteLine($"VM now has {VM.get_VBDs(session, vm).Count} VBD(s)");

        // Tidy up: destroy the VM (which removes its VBDs) and then its disks (VM.destroy leaves VDIs
        // behind), including the one just attached.
        DestroyVmAndDisks(session, vm);
        Console.WriteLine("OK: attach-disk");
        session.logout();
    }
    // Run it:
    //   AttachDisk("https://xenserver", "root", password, "Rocky Linux 8", "Shared NFS");

    // --- 23. Drive an asynchronous task ------------------------------------------------
    private static void WaitForTask(string url, string user, string password,
        string templateName, string newVmName = "sdk-example-asynctask")
    {
        var session = Connect(url, user, password);
        // Every message has an Async.* twin that returns a Task ref immediately; poll it to completion.
        var task = VM.async_clone(session, TemplateByName(session, templateName), newVmName).opaque_ref;
        Console.WriteLine($"Started task: {Task.get_uuid(session, task)}");

        while (Task.get_status(session, task) == task_status_type.pending)
        {
            Console.WriteLine($"  progress: {Task.get_progress(session, task):P0}");
            System.Threading.Thread.Sleep(200);
        }
        Console.WriteLine($"Task status: {Task.get_status(session, task)}");

        // The result of an object-creating task is <value>OpaqueRef:...</value>.
        var result = Task.get_result(session, task);
        var vmRef = result.Replace("<value>", "").Replace("</value>", "").Trim();
        Console.WriteLine($"Task produced VM: {VM.get_name_label(session, vmRef)}");

        // Tidy up.
        VM.destroy(session, vmRef);
        Task.destroy(session, task);
        Console.WriteLine("OK: wait-for-task");
        session.logout();
    }
    // Run it:
    //   WaitForTask("https://xenserver", "root", password, "Rocky Linux 8");

    // --- 24. Handle an API error ------------------------------------------------------
    private static void ErrorHandling(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        // XenAPI errors surface as a Failure whose ErrorDescription is [CODE, param1, param2, ...].
        try
        {
            Host.get_by_uuid(session, "this-uuid-does-not-exist");
            Console.WriteLine("unexpected: no error");
        }
        catch (Failure f)
        {
            Console.WriteLine($"Caught expected failure: {f.ErrorDescription[0]}");
            // Failure.Message (ShortMessage is obsolete and returns the same text).
            Console.WriteLine($"Short message: {f.Message}");
        }
        Console.WriteLine("OK: error-handling");
        session.logout();
    }
    // Run it:
    //   ErrorHandling("https://xenserver", "root", password);

    // --- 25. List templates -----------------------------------------------------------
    private static void ListTemplates(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var templates = VM.get_all_records(session).Values
            .Where(v => v.is_a_template).OrderBy(v => v.name_label).ToList();
        Console.WriteLine($"Templates ({templates.Count}):");
        foreach (var t in templates.Take(8))
        {
            var isDefault = t.other_config.ContainsKey("default_template");
            Console.WriteLine($"  - {t.name_label}{(isDefault ? " [built-in]" : "")}");
        }
        Console.WriteLine("OK: list-templates");
        session.logout();
    }
    // Run it:
    //   ListTemplates("https://xenserver", "root", password);

    // --- 26. Custom fields ------------------------------------------------------------
    private static void CustomFields(string url, string user, string password, string vmName)
    {
        var session = Connect(url, user, password);
        // XenCenter's custom fields are stored in other_config under "XenCenter.CustomFields.<name>".
        var vm = VmByName(session, vmName);
        const string key = "XenCenter.CustomFields.Owner";
        VM.add_to_other_config(session, vm, key, "Platform Team");
        Console.WriteLine($"Custom field Owner = {VM.get_other_config(session, vm)[key]}");

        VM.remove_from_other_config(session, vm, key);
        Console.WriteLine("OK: custom-fields");
        session.logout();
    }
    // Run it:
    //   CustomFields("https://xenserver", "root", password, "web-01");

    // --- 27. GPU inventory ------------------------------------------------------------
    private static void GpuInventory(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var groups = GPU_group.get_all_records(session);
        Console.WriteLine($"GPU groups ({groups.Count}):");
        foreach (var group in groups.Values)
        {
            var types = group.supported_VGPU_types
                .Select(t => VGPU_type.get_model_name(session, t.opaque_ref));
            Console.WriteLine($"  - {group.name_label}: {group.PGPUs.Count} pGPU(s), " +
                $"vGPU types: {string.Join(", ", types)}");
        }
        // How the pool spreads vGPUs across the physical GPUs in a group: depth-first packs each pGPU
        // full before using the next, breadth-first spreads them out.
        var groupRef = groups.Keys.First().opaque_ref;
        var beforeAlloc = GPU_group.get_allocation_algorithm(session, groupRef);
        GPU_group.set_allocation_algorithm(session, groupRef, allocation_algorithm.breadth_first);
        Console.WriteLine($"Allocation:      {beforeAlloc} -> {GPU_group.get_allocation_algorithm(session, groupRef)}");
        GPU_group.set_allocation_algorithm(session, groupRef, beforeAlloc);
        Console.WriteLine("OK: gpu-inventory");
        session.logout();
    }
    // Run it:
    //   GpuInventory("https://xenserver", "root", password);

    // --- 28. Read host & VM metrics ---------------------------------------------------
    private static void ReadMetrics(string url, string user, string password)
    {
        const long MiB = 1024L * 1024;
        var session = Connect(url, user, password);
        var (hostRef, host) = Host.get_all_records(session).First();
        var hm = Host.get_metrics(session, hostRef.opaque_ref).opaque_ref;
        Console.WriteLine($"Host {host.name_label}: " +
            $"{Host_metrics.get_memory_total(session, hm) / MiB} MiB total, " +
            $"{Host.compute_free_memory(session, hostRef.opaque_ref) / MiB} MiB free, " +
            $"live = {Host_metrics.get_live(session, hm)}");

        var vm = VM.get_all_records(session).First(kv => !kv.Value.is_a_template
            && !kv.Value.is_control_domain && kv.Value.power_state == vm_power_state.Running).Key.opaque_ref;
        var vmm = VM.get_metrics(session, vm).opaque_ref;
        Console.WriteLine($"VM {VM.get_name_label(session, vm)}: " +
            $"{VM_metrics.get_VCPUs_number(session, vmm)} vCPU(s), " +
            $"{VM_metrics.get_memory_actual(session, vmm) / MiB} MiB");
        Console.WriteLine("OK: read-metrics");
        session.logout();
    }
    // Run it:
    //   ReadMetrics("https://xenserver", "root", password);

    // --- 29. Rename an object ----------------------------------------------------------
    private static void RenameObject(string url, string user, string password, string vmName)
    {
        var session = Connect(url, user, password);
        var vm = VmByName(session, vmName);
        var original = VM.get_name_label(session, vm);
        VM.set_name_label(session, vm, "sdk-renamed");
        Console.WriteLine($"Renamed '{original}' → '{VM.get_name_label(session, vm)}'");
        VM.set_name_label(session, vm, original); // restore so the example is repeatable
        Console.WriteLine("OK: rename-object");
        session.logout();
    }
    // Run it:
    //   RenameObject("https://xenserver", "root", password, "web-01");

    // --- 30. VM boot configuration -----------------------------------------------------
    private static void VmBootConfig(string url, string user, string password,
        string templateName, string newVmName = "sdk-example-boot")
    {
        var session = Connect(url, user, password);
        var vm = VM.clone(session, TemplateByName(session, templateName), newVmName).opaque_ref;
        Provision(session, vm);

        VM.set_VCPUs_max(session, vm, 4);
        VM.set_VCPUs_at_startup(session, vm, 2);
        Console.WriteLine($"vCPUs: {VM.get_VCPUs_at_startup(session, vm)}/{VM.get_VCPUs_max(session, vm)}");

        // Boot mode: firmware ("bios"/"uefi") lives in HVM_boot_params; Secure Boot in
        // platform["secureboot"]. "auto" (not a hard-coded "true") is the real xe/XenCenter convention:
        // xapi resolves it against whether the pool actually holds Secure Boot certificates, at
        // VM.start time - a hard "true" would claim Secure Boot is on even on a template that was never
        // set up for it, since set_platform does no validation of its own.
        VM.set_HVM_boot_params(session, vm, new Dictionary<string, string> { ["order"] = "cdn", ["firmware"] = "uefi" });
        var platform = VM.get_platform(session, vm);
        platform["secureboot"] = "auto";
        VM.set_platform(session, vm, platform);
        Console.WriteLine($"Boot order: {VM.get_HVM_boot_params(session, vm)["order"]}");
        Console.WriteLine($"Boot mode: firmware={VM.get_HVM_boot_params(session, vm)["firmware"]}, " +
                          $"secureboot={VM.get_platform(session, vm)["secureboot"]} " +
                          "(resolved against pool certificates at boot)");

        DestroyVmAndDisks(session, vm);
        Console.WriteLine("OK: vm-boot-config");
        session.logout();
    }
    // Run it:
    //   VmBootConfig("https://xenserver", "root", password, "Rocky Linux 8");

    // --- 31. Host information ----------------------------------------------------------
    private static void HostInfo(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var (hostRef, host) = Host.get_all_records(session).First();
        var sw = host.software_version;
        var cpu = host.cpu_info;
        Console.WriteLine($"Host:     {host.name_label}");
        Console.WriteLine($"Version:  {(sw.TryGetValue("product_version", out var pv) ? pv : "?")}");
        Console.WriteLine($"Edition:  {host.edition}");
        Console.WriteLine($"CPUs:     {(cpu.TryGetValue("cpu_count", out var cc) ? cc : "?")} across " +
                          $"{(cpu.TryGetValue("socket_count", out var sc) ? sc : "?")} socket(s)");
        // The physical identity, straight off the host's DMI/SMBIOS tables. The serial number is what
        // you quote to the hardware vendor, so it is the one field here that identifies this machine
        // and not just its model.
        var bios = host.bios_strings;
        string Bios(string k) => bios.TryGetValue(k, out var v) ? v : "?";
        Console.WriteLine($"Hardware: {Bios("system-manufacturer")} {Bios("system-product-name")}");
        Console.WriteLine($"Serial:   {Bios("system-serial-number")}");
        Console.WriteLine($"BIOS:     {Bios("bios-version")}");
        Console.WriteLine("OK: host-info");
        session.logout();
    }
    // Run it:
    //   HostInfo("https://xenserver", "root", password);

    // --- 32. List roles ----------------------------------------------------------------
    private static void ListRoles(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        // Role is the one class XenCenter still bulk-downloads; RBAC subjects map to these roles.
        var roles = Role.get_all_records(session).Values
            .Select(r => r.name_label).Distinct().OrderBy(n => n).ToList();
        Console.WriteLine($"Roles ({roles.Count}): {string.Join(", ", roles.Take(8))}");
        Console.WriteLine("OK: list-roles");
        session.logout();
    }
    // Run it:
    //   ListRoles("https://xenserver", "root", password);

    // --- 33. Pool properties -----------------------------------------------------------
    private static void PoolProperties(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var poolRef = Pool.get_all(session)[0].opaque_ref;
        var original = Pool.get_name_label(session, poolRef);
        var defaultSr = Pool.get_default_SR(session, poolRef).opaque_ref;
        Console.WriteLine($"Pool:       '{original}'");
        Console.WriteLine($"Default SR: {(defaultSr == "OpaqueRef:NULL" ? "(none)" : SR.get_name_label(session, defaultSr))}");

        Pool.set_name_label(session, poolRef, "sdk-pool-renamed");
        Console.WriteLine($"Renamed to: '{Pool.get_name_label(session, poolRef)}'");
        Pool.set_name_label(session, poolRef, original); // restore
        Console.WriteLine("OK: pool-properties");
        session.logout();
    }
    // Run it:
    //   PoolProperties("https://xenserver", "root", password);

    // --- 34. Storage repository usage --------------------------------------------------
    private static void SrUsage(string url, string user, string password)
    {
        const long GiB = 1024L * 1024 * 1024;
        var session = Connect(url, user, password);
        foreach (var sr in SR.get_all_records(session).Values.OrderBy(s => s.name_label))
        {
            if (sr.physical_size <= 0) continue; // skip ISO/DVD pseudo-SRs
            Console.WriteLine($"  {sr.name_label}: {sr.physical_utilisation / GiB} / {sr.physical_size / GiB} GiB used");
        }
        // A rescan refreshes an SR's utilisation from its backend.
        var scanMe = SR.get_all_records(session).First(kv => kv.Value.physical_size > 0).Key.opaque_ref;
        SR.scan(session, scanMe);

        // Read caching keeps recently-read blocks in the host's memory. It is switched off per SR by
        // setting o_direct, which asks the storage layer to bypass the cache entirely.
        SR.remove_from_other_config(session, scanMe, "o_direct");
        SR.add_to_other_config(session, scanMe, "o_direct", "true");
        var offOn = SR.get_other_config(session, scanMe).TryGetValue("o_direct", out var oDirect)
            && oDirect == "true" ? "off" : "on";
        Console.WriteLine($"  read caching on {SR.get_name_label(session, scanMe)}: {offOn}");
        SR.remove_from_other_config(session, scanMe, "o_direct");
        Console.WriteLine("OK: sr-usage");
        session.logout();
    }
    // Run it:
    //   SrUsage("https://xenserver", "root", password);

    // --- 35. Manage a VM's network interfaces ------------------------------------------
    private static void ManageVif(string url, string user, string password,
        string templateName, string newVmName = "sdk-example-vif")
    {
        var session = Connect(url, user, password);
        var vm = VM.clone(session, TemplateByName(session, templateName), newVmName).opaque_ref;
        Provision(session, vm);
        var netRef = Network.get_all(session)[0].opaque_ref;
        var device = VM.get_allowed_VIF_devices(session, vm)[0];

        var vif = VIF.create(session, new VIF
        {
            VM = new XenRef<VM>(vm),
            network = new XenRef<Network>(netRef),
            device = device,
            MAC = "",
            MTU = 1500,
            other_config = new Dictionary<string, string>(),
            qos_algorithm_type = "",
            qos_algorithm_params = new Dictionary<string, string>(),
        }).opaque_ref;
        Console.WriteLine($"Attached a VIF on device {device}; VM now has {VM.get_VIFs(session, vm).Count} NIC(s)");

        VIF.destroy(session, vif);
        DestroyVmAndDisks(session, vm);
        Console.WriteLine("OK: manage-vif");
        session.logout();
    }
    // Run it:
    //   ManageVif("https://xenserver", "root", password, "Rocky Linux 8");

    // --- 36. List networks -------------------------------------------------------------
    private static void ListNetworks(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var nets = Network.get_all_records(session).Values.OrderBy(n => n.name_label).ToList();
        Console.WriteLine($"Networks ({nets.Count}):");
        foreach (var net in nets)
            Console.WriteLine($"  - {net.name_label}: {net.PIFs.Count} PIF(s), {net.VIFs.Count} VIF(s)");
        Console.WriteLine("OK: list-networks");
        session.logout();
    }
    // Run it:
    //   ListNetworks("https://xenserver", "root", password);

    // --- 37. Inventory a VM's disks ----------------------------------------------------
    private static void VbdInventory(string url, string user, string password, string vmName)
    {
        const long GiB = 1024L * 1024 * 1024;
        var session = Connect(url, user, password);
        var vm = VmByName(session, vmName);
        Console.WriteLine($"Disks of '{VM.get_name_label(session, vm)}':");
        foreach (var vbdRef in VM.get_VBDs(session, vm))
        {
            var vbd = VBD.get_record(session, vbdRef.opaque_ref);
            if (vbd.type != vbd_type.Disk) continue;
            var vdi = VBD.get_VDI(session, vbdRef.opaque_ref).opaque_ref;
            var size = vdi == "OpaqueRef:NULL" ? 0 : VDI.get_virtual_size(session, vdi) / GiB;
            Console.WriteLine($"  - device {vbd.userdevice}: {size} GiB");
        }
        Console.WriteLine("OK: vbd-inventory");
        session.logout();
    }
    // Run it:
    //   VbdInventory("https://xenserver", "root", password, "db-01");

    // --- 38. Tag the pool --------------------------------------------------------------
    private static void PoolTags(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var poolRef = Pool.get_all(session)[0].opaque_ref;
        Pool.add_tags(session, poolRef, "sdk-managed");
        Console.WriteLine($"Pool tags: {string.Join(", ", Pool.get_tags(session, poolRef))}");
        Pool.remove_tags(session, poolRef, "sdk-managed");
        Console.WriteLine("OK: pool-tags");
        session.logout();
    }
    // Run it:
    //   PoolTags("https://xenserver", "root", password);

    // --- 39. Convert a VM to a template ------------------------------------------------
    private static void ConvertToTemplate(string url, string user, string password,
        string templateName, string newVmName = "sdk-example-totemplate")
    {
        var session = Connect(url, user, password);
        var vm = VM.clone(session, TemplateByName(session, templateName), newVmName).opaque_ref;
        Provision(session, vm); // now a real (halted) VM
        Console.WriteLine($"is_a_template after provision: {VM.get_is_a_template(session, vm)}");

        // Converting a VM to a custom template is a one-way operation.
        VM.set_is_a_template(session, vm, true);
        Console.WriteLine($"is_a_template after convert:  {VM.get_is_a_template(session, vm)}");

        DestroyVmAndDisks(session, vm);
        Console.WriteLine("OK: convert-to-template");
        session.logout();
    }
    // Run it:
    //   ConvertToTemplate("https://xenserver", "root", password, "Rocky Linux 8");

    // --- 40. Look up an object by UUID -------------------------------------------------
    private static void FindByUuid(string url, string user, string password, string vmName)
    {
        var session = Connect(url, user, password);
        // UUIDs are stable identifiers you can persist and resolve back to a (session-scoped) ref.
        var vm = VmByName(session, vmName);
        var uuid = VM.get_uuid(session, vm);
        var resolved = VM.get_by_uuid(session, uuid).opaque_ref;
        Console.WriteLine($"UUID {uuid} resolves to {VM.get_name_label(session, resolved)}");
        Console.WriteLine($"Same object: {resolved == vm}");
        Console.WriteLine("OK: find-by-uuid");
        session.logout();
    }
    // Run it:
    //   FindByUuid("https://xenserver", "root", password, "web-01");

    // --- 41. Rolling pool update -------------------------------------------------------
    private static void RollingPoolUpdate(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        // Needs an enabled update repository the same way apply-update does - introduce and attach a
        // throwaway one, forget it again afterwards.
        var pool = Pool.get_all(session)[0].opaque_ref;
        var repo = Repository.introduce(session, "sdk-cdn", "SDK example repository",
            "https://cdn.example/base", "https://cdn.example/source", true, "").opaque_ref;
        // Remember the pool's own repositories, to put them back afterwards.
        var previous = Pool.get_repositories(session, pool);
        Pool.set_repositories(session, pool, new List<XenRef<Repository>> { new(repo) });
        try
        {
            // Sync the pool's update metadata; the returned hash identifies the synced set.
            var hash = Pool.sync_updates(session, pool, false, "", "");
            Console.WriteLine($"Synced updates; hash length {hash.Length}");

            // Apply them host-by-host so the pool never goes fully offline (the rolling pattern behind
            // XenCenter's automated Install Updates): disable → evacuate → apply → reboot (only if asked)
            // → re-enable. Modern xapi (>=23.18.0) doesn't reboot a host for you: it only records
            // pending_guidances, so only reboot (or restart the toolstack) when the applied batch
            // actually asks for it.
            foreach (var (hostRef, host) in Host.get_all_records(session))
            {
                var h = hostRef.opaque_ref;
                Console.WriteLine($"Updating {host.name_label}:");
                Host.disable(session, h);              // stop new VMs landing here
                Host.evacuate(session, h);             // move running guests to the rest of the pool
                Host.apply_updates(session, h, hash);  // apply the synced updates
                var guidance = Host.get_pending_guidances(session, h);
                Console.WriteLine($"  applied; pending guidance = [{string.Join(", ", guidance)}]");
                if (guidance.Contains(update_guidances.reboot_host))
                    Host.reboot(session, h);           // reboot into the updated software
                else if (guidance.Contains(update_guidances.restart_toolstack))
                    Host.restart_agent(session, h);
                Host.enable(session, h);               // return the host to service
            }
        }
        finally
        {
            Pool.set_repositories(session, pool, previous);
            Repository.forget(session, repo);
        }
        Console.WriteLine("OK: rolling-pool-update");
        session.logout();
    }
    // Run it:
    //   RollingPoolUpdate("https://xenserver", "root", password);

    // --- 42. Cross-pool copy a VM ------------------------------------------------------
    // Copy a VM from one pool to another (Storage XenMotion copy) — the API behind XenCenter's
    // cross-pool Copy. Open a session to each pool, get a receiver token from the destination with
    // host.migrate_receive, then VM.migrate_send with copy=true on the source (which is left intact).
    private static void CrossPoolCopyVm(string url, string user, string password, string destUrl,
        string vmName = "db-01")
    {
        var source = Connect(url, user, password);
        var dest = Connect(destUrl, user, password);
        // Destination: choose a host, a network and an SR, then ask for a receiver token.
        var destHost = Host.get_all(dest)[0].opaque_ref;
        var destNetwork = Network.get_all(dest)[0].opaque_ref;
        var destSr = SrByName(dest, "Shared NFS");
        var receiver = Host.migrate_receive(dest, destHost, destNetwork, new Dictionary<string, string>());

        // Source: map every disk to the destination SR and every NIC to the destination network
        // (a cross-pool copy needs a complete mapping), then send with copy=true.
        var vm = VmByName(source, vmName);
        var vdiMap = new Dictionary<XenRef<VDI>, XenRef<SR>>();
        foreach (var vbdRef in VM.get_VBDs(source, vm))
        {
            if (VBD.get_type(source, vbdRef.opaque_ref) != vbd_type.Disk) continue;
            var vdi = VBD.get_VDI(source, vbdRef.opaque_ref);
            if (vdi.opaque_ref != "OpaqueRef:NULL") vdiMap[vdi] = new XenRef<SR>(destSr);
        }
        var vifMap = new Dictionary<XenRef<VIF>, XenRef<Network>>();
        foreach (var vifRef in VM.get_VIFs(source, vm)) vifMap[vifRef] = new XenRef<Network>(destNetwork);

        var options = new Dictionary<string, string> { ["copy"] = "true" };
        VM.migrate_send(source, vm, receiver, false, vdiMap, vifMap, options,
            new Dictionary<XenRef<VGPU>, XenRef<GPU_group>>());

        // Copy (not move): the source VM is still on the source pool.
        Console.WriteLine($"Sent '{vmName}' to the destination pool (copy); source still present: " +
                          $"{VmByName(source, vmName) == vm}");
        Console.WriteLine("OK: cross-pool-copy-vm");
        source.logout();
        dest.logout();
    }
    // Run it:
    //   CrossPoolCopyVm("https://poolA", "root", password, "https://poolB");


    // Maps the <workflow> argument to the matching self-contained method above, supplying the concrete
    // objects each one operates on. In your own code you would call these methods directly (see the
    // "Run it:" line under each) rather than through this dispatcher.
    // --- 43. PVS Accelerator inventory -------------------------------------------------
    private static void PvsAccelerator(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var sites = PVS_site.get_all_records(session);
        if (sites.Count == 0) Console.WriteLine("No PVS Accelerator sites are configured.");
        foreach (var site in sites.Values)
        {
            Console.WriteLine($"Site: {site.name_label}");
            foreach (var csRef in site.cache_storage)
            {
                var cs = PVS_cache_storage.get_record(session, csRef.opaque_ref);
                var cacheHost = Host.get_record(session, cs.host.opaque_ref);
                var sr = SR.get_record(session, cs.SR.opaque_ref);
                Console.WriteLine($"  cache:  {cacheHost.name_label}  {cs.size / (1024L * 1024 * 1024)} GiB on {sr.name_label}");
            }
            foreach (var serverRef in site.servers)
            {
                var server = PVS_server.get_record(session, serverRef.opaque_ref);
                Console.WriteLine($"  server: {string.Join(", ", server.addresses)}  ports {server.first_port}-{server.last_port}");
            }
            // Which VMs are accelerated: walk each proxy to its VIF to its VM.
            var accelerated = new HashSet<string>();
            foreach (var proxyRef in site.proxies)
            {
                var proxy = PVS_proxy.get_record(session, proxyRef.opaque_ref);
                var vif = VIF.get_record(session, proxy.VIF.opaque_ref);
                accelerated.Add(vif.VM.opaque_ref);
            }
            var guests = VM.get_all_records(session)
                .Where(kv => !kv.Value.is_control_domain && !kv.Value.is_a_template && !kv.Value.is_a_snapshot).ToList();
            var count = guests.Count(kv => accelerated.Contains(kv.Key.opaque_ref));
            Console.WriteLine($"  {count} of {guests.Count} VM(s) accelerated");
        }
        Console.WriteLine("OK: pvs-accelerator");
        session.logout();
    }

    // --- 44. Read RRD performance metrics ----------------------------------------------
    private static void RrdMetrics(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var nameByUuid = Host.get_all_records(session).Values.ToDictionary(h => h.uuid, h => h.name_label);

        // The RRD time-series isn't a XenAPI call; read rrd_updates over HTTP. Legends look like
        // "AVERAGE:host:<uuid>:<datasource>"; values[] aligns to legend[].
        var start = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 300;
        using var http = new HttpClient(new HttpClientHandler
        {
            ServerCertificateCustomValidationCallback = (_, _, _, _) => true
        });
        http.DefaultRequestHeaders.Add("accept", "application/json");
        var json = http.GetStringAsync($"{url}/rrd_updates?session_id={session.opaque_ref}&host=true&start={start}").Result;

        using var doc = JsonDocument.Parse(json);
        var legends = doc.RootElement.GetProperty("meta").GetProperty("legend")
            .EnumerateArray().Select(e => e.GetString()!).ToArray();
        var peak = new Dictionary<string, double>();
        foreach (var point in doc.RootElement.GetProperty("data").EnumerateArray())
        {
            var values = point.GetProperty("values");
            for (int k = 0; k < legends.Length; k++)
            {
                var parts = legends[k].Split(':');
                if (parts[1] == "host" && parts[3] == "pvsaccelerator_space_utilization")
                {
                    // A host sends each value as a string ("0.0", or "NaN" for a gap in the series).
                    var v = values[k].ValueKind == JsonValueKind.String
                        ? double.Parse(values[k].GetString()!, CultureInfo.InvariantCulture)
                        : values[k].GetDouble();
                    if (double.IsNaN(v)) continue;
                    if (!peak.TryGetValue(parts[2], out var cur) || v > cur) peak[parts[2]] = v;
                }
            }
        }
        foreach (var (uuid, p) in peak)
            Console.WriteLine($"  {nameByUuid[uuid]}: peak PVS cache utilisation {p:F0}%");
        Console.WriteLine("OK: rrd-metrics");
        session.logout();
    }

    // --- 45. Reclaim freed space on a thin SR ------------------------------------------
    private static void ReclaimSpace(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        // Storage-manager backends that advertise SR_TRIM in their features map are trim-capable.
        var trimTypes = SM.get_all_records(session).Values
            .Where(sm => sm.features.ContainsKey("SR_TRIM")).Select(sm => sm.type).ToHashSet();
        var sr = SR.get_all_records(session).Values
            .First(s => s.physical_size > 0 && trimTypes.Contains(s.type));
        // A host with a currently-attached PBD can reach the SR to run the plugin.
        var host = sr.PBDs.Select(r => PBD.get_record(session, r))
            .First(pbd => pbd.currently_attached).host;
        var args = new Dictionary<string, string> { ["sr_uuid"] = sr.uuid };
        var result = Host.call_plugin(session, host.opaque_ref, "trim", "do_trim", args);
        Console.WriteLine($"  reclaimed freed space on {sr.name_label}: {result}");
        // Compare case-insensitively: a real host's trim plugin answers "True" (capitalised).
        if (result.Trim().ToLowerInvariant() != "true") throw new Exception($"trim plugin returned '{result}'");
        Console.WriteLine("OK: reclaim-space");
        session.logout();
    }
    // Run it:
    //   ReclaimSpace("https://xenserver", "root", password);

    // --- 46. Get a VM's IP address -----------------------------------------------------
    // A VM that has only just started may not have reported in yet (no guest_metrics at all, or an empty
    // networks map) - retry for a while rather than giving up on the first look, the way XenRT's own
    // IP-discovery helpers do (they retry and fall back through several strategies for up to several
    // minutes before concluding a guest has no usable address).
    private static void VmIpAddress(string url, string user, string password,
        int timeoutSeconds = 60, int intervalSeconds = 2)
    {
        var session = Connect(url, user, password);
        var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
        while (true)
        {
            // A running guest reports its IP in networks, keyed "<vif device>/ip" (e.g. "0/ip").
            var vm = VM.get_all_records(session).Values.FirstOrDefault(v =>
                v.power_state == vm_power_state.Running && !v.is_a_template && !v.is_control_domain
                && v.guest_metrics.opaque_ref != "OpaqueRef:NULL");
            string ip = null;
            if (vm != null)
            {
                var networks = VM_guest_metrics.get_record(session, vm.guest_metrics).networks;
                networks.TryGetValue("0/ip", out ip);
            }
            if (!string.IsNullOrEmpty(ip))
            {
                Console.WriteLine($"  {vm.name_label}: {ip}");
                break;
            }
            if (DateTime.UtcNow > deadline)
                throw new Exception($"no running guest reported an IP address within {timeoutSeconds}s");
            System.Threading.Thread.Sleep(intervalSeconds * 1000);
        }
        Console.WriteLine("OK: vm-ip-address");
        session.logout();
    }
    // Run it:
    //   VmIpAddress("https://xenserver", "root", password);

    // --- 47. Manage Active Directory users ---------------------------------------------
    // Join AD, add a user as a subject with an RBAC role, read it back, then tidy up. Needs a real,
    // reachable AD domain controller - enable_external_auth fails at the very first call
    // (DNS/LDAP/Kerberos) without one, so domain/admin_user/admin_password have to identify a real
    // domain to join. new_user is the account to grant a role to; its subject identity is looked up
    // against the directory just joined, so it has to be a real account there too. The simulator models
    // a single-user, domain-less fake directory (hence the empty domain default) - override every one of
    // these on a real pool.
    private static void ManageAdUsers(string url, string user, string password, string domain = "",
        string adminUser = "alice", string adminPassword = "Password1", string newUser = "alice")
    {
        var session = Connect(url, user, password);
        var pool = Pool.get_all(session)[0].opaque_ref;
        Pool.enable_external_auth(session, pool,
            new Dictionary<string, string> { ["user"] = adminUser, ["pass"] = adminPassword, ["ldaps"] = "false" },
            domain, "AD");
        Console.WriteLine($"Joined domain: {(string.IsNullOrEmpty(domain) ? "(none - simulator's fake directory)" : domain)}");

        var subjectName = string.IsNullOrEmpty(domain) ? newUser : $"{newUser}@{domain}";
        var sid = Auth.get_subject_identifier(session, subjectName);
        var info = Auth.get_subject_information_from_identifier(session, sid);
        // other_config/roles are accepted here but discarded by real xapi (it re-derives other_config
        // from AD itself, and roles isn't a settable constructor field) - subject.add_to_roles below is
        // the call that actually matters.
        var subject = Subject.create(session, new Subject
        {
            subject_identifier = sid,
            other_config = new Dictionary<string, string>(),
            roles = new List<XenRef<Role>>(),
        }).opaque_ref;
        var adminRole = Role.get_by_name_label(session, "pool-admin")[0];
        Subject.add_to_roles(session, subject, adminRole);
        Console.WriteLine($"Added subject {info["subject-displayname"]} ({info["subject-name"]}) as " +
            string.Join(", ", Subject.get_roles(session, subject).Select(r => Role.get_name_label(session, r.opaque_ref))));

        // Revoking access does not end sessions the user already has: logging the subject out is a
        // separate act, and the one that actually gets them off the pool now rather than at next login.
        Console.WriteLine($"Logged-in subjects: {Session.get_all_subject_identifiers(session).Length}");
        Session.logout_subject_identifier(session, sid);
        Console.WriteLine($"  logged out {info["subject-name"]}");

        Subject.remove_from_roles(session, subject, adminRole);
        Subject.destroy(session, subject);
        Pool.disable_external_auth(session, pool, new Dictionary<string, string>());
        Console.WriteLine("OK: manage-ad-users");
        session.logout();
    }
    // Run it:
    //   ManageAdUsers("https://xenserver", "root", password);

    // --- 48. Create an iSCSI SR --------------------------------------------------------
    // Connect an SR to a LUN on the iSCSI target, discovering the IQN and the LUN the way the New SR
    // wizard and XenRT do: a device-config that's missing a piece makes the backend fail on purpose, and
    // the failure carries an XML fragment listing what it needs next.
    //
    // SR.create formats the chosen LUN - this is destructive, so pick carefully on a real target: pass
    // targetIqn to name yours (see ChooseTargetIqn).
    private static void CreateIscsiSr(string url, string user, string password, string target,
        int? port, string chapUser, string chapPassword, string targetIqn = null,
        string srName = "sdk-example-iscsi")
    {
        const long GiB = 1024L * 1024 * 1024;
        var session = Connect(url, user, password);
        var host = Host.get_all(session)[0].opaque_ref;
        var dc = new Dictionary<string, string> { ["target"] = target };
        if (port.HasValue) dc["port"] = port.Value.ToString();
        if (!string.IsNullOrEmpty(chapUser))
        {
            dc["chapuser"] = chapUser;
            dc["chappassword"] = chapPassword;
        }

        // First failing probe: target only -> the backend lists the IQNs it offers.
        var iqnXml = XDocument.Parse(ProbeForFailure(session, host, dc, "lvmoiscsi"));
        dc["targetIQN"] = ChooseTargetIqn(iqnXml, target, targetIqn);
        Console.WriteLine($"Discovered IQN: {dc["targetIQN"]}");

        // Second failing probe: +targetIQN -> the backend lists the LUNs behind it. Real create also
        // carries LUNid, which XenRT's own LUN-preparation helper always includes when known.
        var lunXml = XDocument.Parse(ProbeForFailure(session, host, dc, "lvmoiscsi"));
        var luns = lunXml.Descendants("LUN").ToList();
        var lun = luns[0];
        dc["SCSIid"] = lun.Element("SCSIid")!.Value;
        var lunId = lun.Element("LUNid");
        dc["LUNid"] = lunId != null ? lunId.Value : luns.IndexOf(lun).ToString();
        Console.WriteLine($"Discovered LUN {dc["LUNid"]} (SCSIid {dc["SCSIid"]})");

        var sr = SR.create(session, host, dc, 0, srName, "iSCSI SR created by the SDK example",
            "lvmoiscsi", "user", true, new Dictionary<string, string>());
        Console.WriteLine($"Created SR: {SR.get_uuid(session, sr)} ({SR.get_physical_size(session, sr) / GiB} GiB)");
        DetachAndForgetSr(session, sr);
        Console.WriteLine("OK: create-iscsi-sr");
        session.logout();
    }
    // Run it:
    //   CreateIscsiSr("https://xenserver", "root", password, "192.0.2.30", null, null, null);

    // --- 49. Create an SMB SR ----------------------------------------------------------
    // Connect a shared SR to an SMB/CIFS file share (create validates + sizes from the share). The
    // password travels as a Secret, not plaintext device-config - the way XenRT and XenCenter both do
    // it, and the only form seen in real captured sr-create calls for this SR type.
    private static void CreateSmbSr(string url, string user, string password, string server, string share,
        string smbUsername, string smbPassword, string srName = "sdk-example-smb")
    {
        const long GiB = 1024L * 1024 * 1024;
        var session = Connect(url, user, password);
        var host = Host.get_all(session)[0].opaque_ref;

        var secret = Secret.create(session, new Secret
        {
            value = smbPassword,
            other_config = new Dictionary<string, string>(),
        }).opaque_ref;
        var dc = new Dictionary<string, string>
        {
            ["server"] = server,
            ["serverpath"] = share,
            ["username"] = smbUsername,
            ["password_secret"] = Secret.get_uuid(session, secret),
        };
        var sr = SR.create(session, host, dc, 0, srName, "SMB SR created by the SDK example",
            "smb", "user", true, new Dictionary<string, string>());
        Console.WriteLine($"Created SR: {SR.get_uuid(session, sr)} ({SR.get_physical_size(session, sr) / GiB} GiB)");
        DetachAndForgetSr(session, sr);
        Secret.destroy(session, secret);
        Console.WriteLine("OK: create-smb-sr");
        session.logout();
    }
    // Run it:
    //   CreateSmbSr("https://xenserver", "root", password, "192.0.2.40", "/vmstore", "Administrator", "Password1");

    // --- 50. Create an HBA SR ----------------------------------------------------------
    // Connect a shared SR to a fibre-channel (HBA) LUN, discovering it the way the New SR wizard does:
    // probing with no SCSIid fails on purpose and lists every LUN the backend can see.
    //
    // SR.create formats the chosen LUN - this is destructive, so pick carefully on a real target.
    private static void CreateHbaSr(string url, string user, string password, string srName = "sdk-example-hba")
    {
        const long GiB = 1024L * 1024 * 1024;
        var session = Connect(url, user, password);
        var host = Host.get_all(session)[0].opaque_ref;

        // The root element varies by backend; find BlockDevice entries by tag wherever they are.
        var devlistXml = XDocument.Parse(ProbeForFailure(session, host, new Dictionary<string, string>(), "lvmohba"));
        var device = devlistXml.Descendants("BlockDevice").First();
        var scsiId = device.Element("SCSIid")!.Value;
        var path = device.Element("path")!.Value;
        Console.WriteLine($"Discovered LUN: SCSIid {scsiId} on {path}");

        // SCSIid is all lvmohba needs - it is what XenCenter's New SR wizard sends. (The probe's <path> is
        // for display: on a real host it reads like "/dev/sde [sdc] [sdg] [sdi]", one entry per path.)
        var dc = new Dictionary<string, string> { ["SCSIid"] = scsiId };
        var sr = SR.create(session, host, dc, 0, srName, "HBA SR created by the SDK example",
            "lvmohba", "user", true, new Dictionary<string, string>());
        Console.WriteLine($"Created SR: {SR.get_uuid(session, sr)} ({SR.get_physical_size(session, sr) / GiB} GiB)");
        DetachAndForgetSr(session, sr);
        Console.WriteLine("OK: create-hba-sr");
        session.logout();
    }
    // Run it:
    //   CreateHbaSr("https://xenserver", "root", password);

    // --- 51. Create an ISO library SR --------------------------------------------------
    private static void CreateIsoSr(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var host = Host.get_all(session)[0].opaque_ref;
        // Connect an ISO-library SR to a file share of ISO images (here an NFS export).
        var dc = new Dictionary<string, string> { ["location"] = "192.0.2.10:/isos", ["type"] = "nfs_iso" };
        var sr = SR.create(session, host, dc, 0, "sdk-iso-sr", "ISO library created by the SDK example",
            "iso", "iso", true, new Dictionary<string, string>());
        Console.WriteLine($"Created ISO SR: {SR.get_uuid(session, sr)}");
        DetachAndForgetSr(session, sr);
        Console.WriteLine("OK: create-iso-sr");
        session.logout();
    }
    // Run it:
    //   CreateIsoSr("https://xenserver", "root", password);

    // --- 52. Configure NRPE monitoring -------------------------------------------------
    private static void ConfigureNrpe(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        // host.call_plugin is per-host - there is no pool-wide fan-out for plugin calls the way there is
        // for pool.enable_ssh - so configure every host in the pool, and restore each one to disabled
        // again afterwards.
        foreach (var host in Host.get_all(session))
        {
            string Nrpe(string fn, Dictionary<string, string> args) =>
                Host.call_plugin(session, host.opaque_ref, "nrpe", fn, args);
            var label = Host.get_name_label(session, host.opaque_ref);
            Console.WriteLine($"{label}: NRPE status before: {Nrpe("status", new()).Trim()}");
            Nrpe("enable", new());
            Nrpe("set-config", new()
            {
                ["allowed_hosts"] = "127.0.0.1,::1,10.0.0.5",
                ["debug"] = "0",
                ["ssl_logging"] = "0x00",
            });
            Nrpe("restart", new());
            Console.WriteLine($"  status after:  {Nrpe("status", new()).Trim()}");
            foreach (var line in Nrpe("get-config", new()).Split('\n'))
                if (line.StartsWith("allowed_hosts:"))
                    Console.WriteLine($"  allowed hosts: {line.Split(':', 2)[1].Trim()}");
            Nrpe("disable", new()); // restore: leave it as we found it
        }
        Console.WriteLine("OK: configure-nrpe");
        session.logout();
    }
    // Run it:
    //   ConfigureNrpe("https://xenserver", "root", password);

    // --- 53. Configure SNMP monitoring -------------------------------------------------
    private static void ConfigureSnmp(string url, string user, string password,
        string trapDestination = "192.0.2.50")
    {
        var session = Connect(url, user, password);
        // nmss is the list of real trap destinations SNMP notifications go to - an empty list never
        // configures where traps actually go, which is the whole point of "configure SNMP monitoring".
        var config =
            "{\"common\":{\"enabled\":\"yes\",\"debug_log\":\"no\"}," +
            "\"agent\":{\"v2c\":\"yes\",\"v3\":\"no\",\"community\":\"sdk-community\",\"user_name\":\"\"," +
            "\"authentication_password\":\"\",\"authentication_protocol\":\"\"," +
            "\"privacy_password\":\"\",\"privacy_protocol\":\"\"}," +
            $"\"nmss\":[{{\"address\":\"{trapDestination}\",\"port\":162,\"v2c\":\"yes\",\"v3\":\"no\"," +
            "\"community\":\"sdk-community\",\"user_name\":\"\",\"authentication_password\":\"\"," +
            "\"authentication_protocol\":\"\",\"privacy_password\":\"\",\"privacy_protocol\":\"\"}]}";
        // Plugin calls are per-host, so configure every host, and restore each one to disabled again
        // afterwards, the way XenRT's own SNMPServer.disable() does.
        foreach (var host in Host.get_all(session))
        {
            string Snmp(string fn, Dictionary<string, string> args) =>
                Host.call_plugin(session, host.opaque_ref, "snmp", fn, args);
            Snmp("set-config", new() { ["config"] = config });
            using var status = JsonDocument.Parse(Snmp("status", new()));
            using var cfg = JsonDocument.Parse(Snmp("get-config", new()));
            var result = status.RootElement.GetProperty("result");
            var agentCfg = cfg.RootElement.GetProperty("result");
            var nmss = agentCfg.GetProperty("nmss");
            var label = Host.get_name_label(session, host.opaque_ref);
            Console.WriteLine($"{label}: SNMP enabled: {result.GetProperty("enabled").GetString()} / " +
                              $"{result.GetProperty("active").GetString()}");
            Console.WriteLine($"  community: {agentCfg.GetProperty("agent").GetProperty("community").GetString()}, " +
                              $"trap destination: {(nmss.GetArrayLength() > 0 ? nmss[0].GetProperty("address").GetString() : "(none)")}");
            Snmp("set-config", new() { ["config"] = "{\"common\":{\"enabled\":\"no\"}}" }); // restore
        }
        Console.WriteLine("OK: configure-snmp");
        session.logout();
    }
    // Run it:
    //   ConfigureSnmp("https://xenserver", "root", password, trapDestination: "192.0.2.50");

    // --- Manage a vApp -----------------------------------------------------------------------
    private static void ManageVapp(string url, string user, string password, string vmName)
    {
        var session = Connect(url, user, password);
        var vm = VM.get_by_name_label(session, vmName)[0];

        var vapp = VM_appliance.create(session, new VM_appliance
        {
            name_label = "sdk-example-vapp",
            name_description = "Created by the SDK example",
        });

        // `order` decides the sequence: ascending to start, descending to shut down. That ordering is the
        // reason to use a vApp at all rather than selecting several VMs — the database comes up first and
        // goes down last.
        VM.set_appliance(session, vm.opaque_ref, vapp.opaque_ref);
        VM.set_order(session, vm.opaque_ref, 0);
        VM.set_start_delay(session, vm.opaque_ref, 5);

        VM_appliance.start(session, vapp.opaque_ref, false);
        Console.WriteLine($"Started:        {VM.get_power_state(session, vm.opaque_ref)}");

        VM_appliance.clean_shutdown(session, vapp.opaque_ref);
        Console.WriteLine($"Shut down:      {VM.get_power_state(session, vm.opaque_ref)}");

        VM.set_appliance(session, vm.opaque_ref, null);
        VM_appliance.destroy(session, vapp.opaque_ref);
        Console.WriteLine("OK: manage-vapp");
        session.logout();
    }
    // Run it:
    //   ManageVapp("https://xenserver", "root", password, "web-01");

    // --- Attach a USB device to a VM ----------------------------------------------------------
    private static void AttachUsbDevice(string url, string user, string password, string vmName)
    {
        var session = Connect(url, user, password);
        var vm = VM.get_by_name_label(session, vmName)[0];

        var pusb = PUSB.get_all_records(session).First();
        Console.WriteLine($"Device:         {pusb.Value.description}");

        // Passthrough is off until an administrator enables it on the device — a VUSB.create against a
        // device that has not been released fails rather than silently doing nothing.
        PUSB.set_passthrough_enabled(session, pusb.Key, true);

        var vusb = VUSB.create(session, vm.opaque_ref, pusb.Value.USB_group, new Dictionary<string, string>());
        Console.WriteLine($"Attached:       {VM.get_VUSBs(session, vm.opaque_ref).Count} device(s)");

        // VUSB.destroy refuses a VUSB that is still attached (OPERATION_NOT_ALLOWED) - on a running VM
        // it gets plugged in as soon as it's created, so unplug it first.
        if (VUSB.get_currently_attached(session, vusb.opaque_ref)) VUSB.unplug(session, vusb.opaque_ref);
        VUSB.destroy(session, vusb.opaque_ref);
        PUSB.set_passthrough_enabled(session, pusb.Key, false);
        Console.WriteLine("OK: attach-usb-device");
        session.logout();
    }
    // Run it:
    //   AttachUsbDevice("https://xenserver", "root", password, "web-01");

    // --- Read workload-balancing recommendations ----------------------------------------------
    // Connect a workload-balancing appliance and read its placement advice. Needs a real, reachable WLB
    // appliance: pool.initialize_wlb makes a synchronous HTTP call to it and raises
    // WLB_CONNECTION_REFUSED/WLB_CONNECTION_RESET if it can't connect - there is no way to fake this with
    // a placeholder. wlbHostPort is host:port, with no URL scheme - that is the real wire format
    // (xe pool-initialize-wlb wlb_url="10.x.x.x:30601" ...), not a URL.
    private static void WlbRecommendations(string url, string user, string password, string vmName,
        string wlbHostPort = "wlb.example:8012", string wlbUsername = "wlbuser", string wlbPassword = "wlbpass")
    {
        var session = Connect(url, user, password);
        var poolRef = Pool.get_all(session)[0].opaque_ref;

        Pool.initialize_wlb(session, wlbHostPort, wlbUsername, wlbPassword, user, password);
        Console.WriteLine($"WLB: {Pool.get_wlb_url(session, poolRef)}");

        // Read BY POSITION, and the two calls do not share a shape. The pool's recommendations are keyed
        // by VM and say where to move it: [0] "wlb", [1] the destination host's UUID (a uuid, not a ref),
        // [2] and [3] ids, [4] the reason.
        foreach (var entry in Pool.retrieve_wlb_recommendations(session))
            Console.WriteLine($"  move {VM.get_name_label(session, entry.Key.opaque_ref)} " +
                              $"-> host {entry.Value[1]} ({entry.Value[4]})");

        // A VM's own recommendations are keyed by host and star-rate each as a destination:
        // [0] "wlb", [1] the rating from 0.0 to 5.0.
        var vm = VM.get_by_name_label(session, vmName)[0];
        foreach (var entry in VM.retrieve_wlb_recommendations(session, vm.opaque_ref))
            Console.WriteLine($"  {Host.get_name_label(session, entry.Key.opaque_ref)} " +
                              $"rated {entry.Value[1]}");

        // The appliance's own settings are read and written as one flat map of strings. Send a
        // nightly reporting schedule, then read the configuration back to confirm it took.
        Pool.send_wlb_configuration(session, new Dictionary<string, string> { ["ReportingCronString"] = "0 3 * * *" });
        var wlbConfig = Pool.retrieve_wlb_configuration(session);
        Console.WriteLine("  appliance configuration: " +
            string.Join(", ", wlbConfig.OrderBy(kv => kv.Key).Select(kv => $"{kv.Key}={kv.Value}")));

        Pool.deconfigure_wlb(session);
        Console.WriteLine("OK: wlb-recommendations");
        session.logout();
    }
    // Run it:
    //   WlbRecommendations("https://xenserver", "root", password, "web-01");

    // --- Configure clustering (GFS2) ----------------------------------------------------------
    private static void ConfigureClustering(string url, string user, string password)
    {
        var session = Connect(url, user, password);

        // Clustering is what shared block storage needs before it can be thin-provisioned with GFS2.
        // Pick a network every host can reach: corosync is latency-sensitive, and a cluster that loses
        // quorum takes its GFS2 storage offline with it.
        var network = Network.get_all(session)[0].opaque_ref;

        var existing = Cluster.get_all(session);
        var cluster = existing.Count > 0
            ? existing[0].opaque_ref
            : Cluster.pool_create(session, network, "corosync", 20000, 1000).opaque_ref;

        var record = Cluster.get_record(session, cluster);
        Console.WriteLine($"Stack:      {record.cluster_stack}");
        Console.WriteLine($"Quorate:    {record.is_quorate} ({record.live_hosts}/{record.quorum} needed)");

        // Taking a host out is what a management-interface change does; it can cost the pool quorum,
        // which is why the field is worth reading back rather than assuming.
        var member = Cluster_host.get_all(session)[0].opaque_ref;
        Cluster_host.disable(session, member);
        Console.WriteLine($"One member out, quorate: {Cluster.get_is_quorate(session, cluster)}");

        Cluster_host.enable(session, member);
        Cluster.pool_resync(session, cluster);
        Console.WriteLine($"Resynced,   quorate: {Cluster.get_is_quorate(session, cluster)}");

        Console.WriteLine("OK: configure-clustering");
        session.logout();
    }
    // Run it:
    //   ConfigureClustering("https://xenserver", "root", password);

    // --- Manage pool membership ---------------------------------------------------------------
    private static void ManagePoolMembership(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var poolRef = Pool.get_all(session)[0].opaque_ref;

        var hosts = Host.get_all_records(session);
        var original = Pool.get_master(session, poolRef).opaque_ref;
        Console.WriteLine($"Coordinator: {hosts[new XenRef<Host>(original)].name_label}");
        foreach (var h in hosts)
            Console.WriteLine($"  member: {h.Value.name_label}{(h.Key.opaque_ref == original ? " (coordinator)" : "")}");

        // Promote another member. The pool database moves with the role and clients are redirected, so
        // this briefly interrupts management traffic — it does not move any VM.
        var other = hosts.Keys.First(k => k.opaque_ref != original).opaque_ref;
        Pool.designate_new_master(session, other);
        Console.WriteLine($"Promoting:   {hosts[new XenRef<Host>(other)].name_label} " +
                          "(xapi restarts pool-wide; reconnecting)");

        // designate_new_master runs a two-phase commit across every host and ends by restarting xapi
        // pool-wide - the session this call was made on, and the connection itself, do not survive it.
        // Reconnect (with a bounded wait, the same way XenRT's own helper for this call does) before
        // touching the pool again, and re-resolve every ref from the fresh session rather than assuming
        // the old ones are still good.
        session = ReconnectAfterMasterChange(url, user, password);
        poolRef = Pool.get_all(session)[0].opaque_ref;
        Console.WriteLine($"Promoted:    {Host.get_name_label(session, Pool.get_master(session, poolRef).opaque_ref)}");

        // Put it back. Ejecting a member (Pool.eject) is the other half of this surface and is
        // deliberately not shown: it cannot be undone from the pool, because rejoining is initiated by
        // the ejected host.
        Pool.designate_new_master(session, original);
        Console.WriteLine($"Restoring:   {hosts[new XenRef<Host>(original)].name_label} (reconnecting again)");

        session = ReconnectAfterMasterChange(url, user, password);
        poolRef = Pool.get_all(session)[0].opaque_ref;
        Console.WriteLine($"Restored:    {Host.get_name_label(session, Pool.get_master(session, poolRef).opaque_ref)}");

        Console.WriteLine("OK: manage-pool-membership");
        session.logout();
    }
    // Run it:
    //   ManagePoolMembership("https://xenserver", "root", password);

    // --- Create a NIC bond ----------------------------------------------------------------------
    private static void CreateBond(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var host = Host.get_all(session)[0].opaque_ref;

        // Pick up any NIC racked since the host booted. Cheap, and without it a card added a moment ago
        // is not there to bond.
        PIF.scan(session, host);

        // Spare NICs only. A bond that includes the management interface moves the management address
        // onto the bond master — on a real host that is how you lose the connection you are working over.
        var spares = PIF.get_all_records(session)
            .Where(p => p.Value.host.opaque_ref == host && !p.Value.management && p.Value.physical)
            .Take(2).Select(p => p.Key).ToList();
        Console.WriteLine($"Bonding:      {string.Join(", ", spares.Select(p => PIF.get_device(session, p.opaque_ref)))}");

        // The bond needs a network to sit on.
        var network = Network.create(session, new Network
        {
            name_label = "sdk-example-bond",
            name_description = "Created by the SDK example",
            other_config = new Dictionary<string, string>(),
        });

        var bond = Bond.create(session, network.opaque_ref, spares, "", bond_mode.balance_slb);
        var master = Bond.get_master(session, bond.opaque_ref);
        Console.WriteLine($"Bond master:  {PIF.get_device(session, master.opaque_ref)}");
        Console.WriteLine($"Mode:         {Bond.get_mode(session, bond.opaque_ref)}");

        // Dissolving returns the NICs to standalone use (and moves management back, had it been bonded).
        Bond.destroy(session, bond.opaque_ref);
        Network.destroy(session, network.opaque_ref);
        Console.WriteLine($"Bonds left:   {Bond.get_all(session).Count}");
        Console.WriteLine("OK: create-bond");
        session.logout();
    }
    // Run it:
    //   CreateBond("https://xenserver", "root", password);

    // --- Configure PVS Accelerator -----------------------------------------------------
    private static void ConfigurePvsAccelerator(string url, string user, string password)
    {
        var session = Connect(url, user, password);

        var site = PVS_site.introduce(session, "sdk-pvs-farm", "Created by the SDK examples", "");
        PVS_server.introduce(session, new[] { "10.62.0.90" }, 6910, 6930, site);

        // The read cache must be on LOCAL storage. The point of the accelerator is to keep reads off
        // the network, so a cache on a shared SR would defeat it and the server rejects one.
        foreach (var hostRef in Host.get_all(session))
        {
            var local = LocalSr(session, hostRef);
            if (local == null) continue;
            PVS_cache_storage.create(session, new PVS_cache_storage
            {
                host = new XenRef<Host>(hostRef.opaque_ref),
                SR = new XenRef<SR>(local),
                site = new XenRef<PVS_site>(site),
                size = 10L * 1024 * 1024 * 1024,
            });
        }

        // A proxy may only sit on the VM's LOWEST-numbered NIC, so sort by device rather than taking
        // VIFs[0] — the list comes back in creation order, which is the same thing only by luck.
        var vm = FirstUnacceleratedGuest(session);
        var vif = VM.get_VIFs(session, vm.opaque_ref)
            .OrderBy(r => int.Parse(VIF.get_device(session, r.opaque_ref)))
            .First();
        var proxy = PVS_proxy.create(session, site, vif.opaque_ref);

        var record = PVS_site.get_record(session, site);
        Console.WriteLine($"Site '{record.name_label}' with {record.cache_storage.Count} cache(s) "
                          + $"and {record.servers.Count} server(s)");
        // "caching" means it is actually accelerating. A site with no cache storage reports
        // "initialised", and a proxy on a VM whose NIC is unplugged reports "stopped".
        Console.WriteLine($"  {vm.name_label}: {PVS_proxy.get_status(session, proxy)}");

        // Forgetting the site only cascades its cache storage - a running proxy or a server it still has
        // makes forget refuse with PVS_SITE_CONTAINS_RUNNING_PROXIES/_SERVERS, so tear those down
        // ourselves first, in the same order every real PVS teardown uses.
        PVS_proxy.destroy(session, proxy);
        foreach (var serverRef in PVS_site.get_servers(session, site)) PVS_server.forget(session, serverRef.opaque_ref);
        PVS_site.forget(session, site);
        Console.WriteLine("OK: configure-pvs-accelerator");
        session.logout();
    }
    // Run it:
    //   ConfigurePvsAccelerator("https://xenserver", "root", password);

    /// <summary>The host's own non-ISO storage, found through its PBDs.</summary>
    private static string LocalSr(Session session, XenRef<Host> host)
    {
        foreach (var pbdRef in Host.get_PBDs(session, host.opaque_ref))
        {
            // Keep the REF and read the record through it: a record fetched by get_record does not
            // carry its own opaque_ref, so reaching for sr.opaque_ref afterwards hands you a null.
            var srRef = PBD.get_SR(session, pbdRef.opaque_ref);
            var sr = SR.get_record(session, srRef.opaque_ref);
            if (!sr.shared && sr.content_type != "iso" && sr.type != "udev")
                return srRef.opaque_ref;
        }
        return null;
    }

    /// <summary>
    /// A running guest with a NIC that no proxy already covers. A VIF can carry only one proxy, so a VM
    /// the pool already accelerates fails with PVS_PROXY_ALREADY_PRESENT.
    /// </summary>
    private static VM FirstUnacceleratedGuest(Session session)
    {
        var taken = new HashSet<string>();
        foreach (var proxyRef in PVS_proxy.get_all(session))
        {
            var vifRef = PVS_proxy.get_VIF(session, proxyRef.opaque_ref);
            taken.Add(VIF.get_VM(session, vifRef.opaque_ref).opaque_ref);
        }
        foreach (var kv in VM.get_all_records(session))
        {
            var v = kv.Value;
            if (v.is_a_template || v.is_control_domain || v.is_a_snapshot) continue;
            if (v.power_state != vm_power_state.Running || v.VIFs.Count == 0) continue;
            if (taken.Contains(kv.Key.opaque_ref)) continue;
            v.opaque_ref = kv.Key.opaque_ref;
            return v;
        }
        throw new Exception("no unaccelerated running guest with a NIC");
    }

    // --- Manage SSH access -------------------------------------------------------------
    private static void ManageSshAccess(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var pool = Pool.get_all(session)[0];

        // Timed access is the point: set the timeout first and the server stamps an ssh_expiry when SSH
        // is enabled, so a window opened for troubleshooting closes itself. set_ssh_enabled_timeout is
        // itself a pool-wide fan-out call, exactly like enable_ssh/disable_ssh - no need to loop hosts.
        Pool.set_ssh_enabled_timeout(session, pool.opaque_ref, 3600);

        // The pool call fans out to every host, so there is no need to loop for the enable itself.
        Pool.enable_ssh(session, pool.opaque_ref);
        foreach (var record in Host.get_all_records(session).Values)
            Console.WriteLine($"{record.name_label}: ssh enabled={record.ssh_enabled}, "
                              + $"expires {record.ssh_expiry:u}");

        Pool.disable_ssh(session, pool.opaque_ref);
        Console.WriteLine("After disable: " + string.Join(", ",
            Host.get_all_records(session).Values.Select(h => $"{h.name_label}={h.ssh_enabled}")));
        Console.WriteLine("OK: manage-ssh-access");
        session.logout();
    }
    // Run it:
    //   ManageSshAccess("https://xenserver", "root", password);

    // --- Change control domain memory ---------------------------------------------------
    private static void ControlDomainMemory(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var host = Host.get_all(session)[0];
        var dom0 = Host.get_resident_VMs(session, host.opaque_ref)
            .First(vm => VM.get_is_control_domain(session, vm.opaque_ref));

        var original = VM.get_memory_dynamic_min(session, dom0.opaque_ref);
        Console.WriteLine($"{Host.get_name_label(session, host.opaque_ref)} dom0: "
                          + $"{original / (double)(1024 * 1024 * 1024):F1} GiB");

        // One setter, not a range: dom0 does not balloon, so set_memory pins the static and dynamic
        // bounds and the target together. The new size takes effect at the next reboot, which is why
        // XenCenter offers this only in maintenance mode — the API itself does not stop you.
        VM.set_memory(session, dom0.opaque_ref, original + 1024L * 1024 * 1024);
        var record = VM.get_record(session, dom0.opaque_ref);
        Console.WriteLine($"  now {record.memory_dynamic_min / (double)(1024 * 1024 * 1024):F1} GiB "
                          + $"(static {record.memory_static_min}-{record.memory_static_max}, "
                          + $"dynamic {record.memory_dynamic_min}-{record.memory_dynamic_max})");

        VM.set_memory(session, dom0.opaque_ref, original);   // leave the pool as we found it
        Console.WriteLine("OK: control-domain-memory");
        session.logout();
    }
    // Run it:
    //   ControlDomainMemory("https://xenserver", "root", password);

    // --- Manage a vTPM -----------------------------------------------------------------
    private static void ManageVtpm(string url, string user, string password)
    {
        var session = Connect(url, user, password);

        var vm = VM.get_all_records(session).First(kv =>
            !kv.Value.is_a_template && !kv.Value.is_control_domain && !kv.Value.is_a_snapshot &&
            kv.Value.power_state == vm_power_state.Halted && kv.Value.VTPMs.Count == 0);
        Console.WriteLine($"Attaching a vTPM to {vm.Value.name_label}");

        // is_unique=false: the vTPM may be copied along with the VM. A VM may have at most one, and it
        // can only be attached while Halted — the device is presented at boot.
        var vtpm = VTPM.create(session, vm.Key.opaque_ref, false);
        var record = VTPM.get_record(session, vtpm.opaque_ref);
        Console.WriteLine($"  persistence backend: {record.persistence_backend}");
        Console.WriteLine($"  unique to this VM:   {record.is_unique}");
        Console.WriteLine($"  VM now has {VM.get_VTPMs(session, vm.Key.opaque_ref).Count} vTPM(s)");

        // The VM advertises whether another can be added; once it has one, it cannot.
        Console.WriteLine("  can add another:     " +
            VM.get_allowed_operations(session, vm.Key.opaque_ref).Contains(vm_operations.create_vtpm));

        VTPM.destroy(session, vtpm.opaque_ref);
        Console.WriteLine($"  after removal:       {VM.get_VTPMs(session, vm.Key.opaque_ref).Count} vTPM(s)");
        Console.WriteLine("OK: manage-vtpm");
        session.logout();
    }
    // Run it:
    //   ManageVtpm("https://xenserver", "root", password);

    // --- Back up with changed block tracking ---------------------------------------------
    private static void ChangedBlockTracking(string url, string user, string password)
    {
        var session = Connect(url, user, password);

        var vm = VM.get_all_records(session).First(kv =>
            !kv.Value.is_a_template && !kv.Value.is_control_domain && !kv.Value.is_a_snapshot &&
            kv.Value.VBDs.Count > 0);
        Console.WriteLine($"Backing up {vm.Value.name_label}");

        // CBT is switched on for the VM's own disk, and every snapshot taken from then on inherits it.
        // It can't be switched on for a snapshot's disk after the fact (OPERATION_NOT_ALLOWED).
        var live = FirstDisk(session, vm.Key.opaque_ref);
        var wasEnabled = VDI.get_cbt_enabled(session, live);
        if (!wasEnabled) VDI.enable_cbt(session, live);

        var first = VM.snapshot(session, vm.Key.opaque_ref, "cbt-backup-1");
        var second = VM.snapshot(session, vm.Key.opaque_ref, "cbt-backup-2");
        var vdiFrom = FirstDisk(session, first.opaque_ref);
        var vdiTo = FirstDisk(session, second.opaque_ref);

        // One bit per 64 KiB block, base64-encoded; bit N set means block N changed. A real backup reads
        // only those blocks, over NBD.
        var bitmap = Convert.FromBase64String(VDI.list_changed_blocks(session, vdiFrom, vdiTo));
        var changed = bitmap.Sum(b => System.Numerics.BitOperations.PopCount(b));
        Console.WriteLine($"  {changed} blocks of {bitmap.Length * 8} changed "
                          + $"({changed * 64 / 1024.0:F1} MiB to copy, not "
                          + $"{VDI.get_virtual_size(session, vdiTo) / (1024.0 * 1024):F1} MiB)");

        // Release the older snapshot's blocks but keep its change metadata, so the next incremental can
        // still diff against it. data_destroy refuses a disk that a VM still uses (VDI_IN_USE), so drop the
        // older snapshot's VM record first, as a backup tool does. The VDI record stays; its type changes.
        VM.destroy(session, first.opaque_ref);
        VDI.data_destroy(session, vdiFrom);
        Console.WriteLine($"  older snapshot is now type={VDI.get_type(session, vdiFrom)}, "
                          + $"still cbt_enabled={VDI.get_cbt_enabled(session, vdiFrom)}");

        // Tidy up: the newer snapshot and its disk, the metadata-only VDI, and CBT on the VM's own disk
        // if this example switched it on.
        DestroyVmAndDisks(session, second.opaque_ref);
        VDI.destroy(session, vdiFrom);
        if (!wasEnabled) VDI.disable_cbt(session, live);
        Console.WriteLine("OK: changed-block-tracking");
        session.logout();
    }
    // Run it:
    //   ChangedBlockTracking("https://xenserver", "root", password);

    /// <summary>The VDI behind a VM's first real disk (a CD drive is a VBD too).</summary>
    private static string FirstDisk(Session session, string vmRef)
    {
        foreach (var vbdRef in VM.get_VBDs(session, vmRef))
            if (VBD.get_type(session, vbdRef.opaque_ref) == vbd_type.Disk)
                return VBD.get_VDI(session, vbdRef.opaque_ref).opaque_ref;
        throw new Exception("no disk found");
    }

    // --- Export and import a VM ---------------------------------------------------------
    private static void ExportImportVm(string url, string user, string password)
    {
        var session = Connect(url, user, password);

        // Only a halted VM can be exported: its disks must not be changing underneath the copy.
        var vm = VM.get_all_records(session).First(kv =>
            !kv.Value.is_a_template && !kv.Value.is_control_domain && !kv.Value.is_a_snapshot &&
            kv.Value.power_state == vm_power_state.Halted);
        Console.WriteLine($"Exporting {vm.Value.name_label}");

        // Export and import are HTTP transfers alongside the API, not API calls, so the session id
        // travels in the query string.
        // A unique file, not a fixed name: an export is a real file on disk and two of them running at
        // once would otherwise fight over it.
        var path = Path.Combine(Path.GetTempPath(), $"sdk-example-export-{Guid.NewGuid():N}.xva");
        using (var client = InsecureHttpClient())
        {
            var uuid = VM.get_uuid(session, vm.Key.opaque_ref);
            var bytes = client.GetByteArrayAsync(
                $"{url}/export?session_id={session.opaque_ref}&uuid={uuid}").Result;
            File.WriteAllBytes(path, bytes);
            Console.WriteLine($"  wrote {bytes.Length / (1024.0 * 1024):F1} MiB to {Path.GetFileName(path)}");
        }

        // An XVA is a tar: ova.xml describes the VM, and the disk blocks follow in 1 MiB pieces, each
        // with its own checksum.
        var names = new List<string>();
        using (var reader = new System.Formats.Tar.TarReader(File.OpenRead(path)))
            while (reader.GetNextEntry() is { } entry) names.Add(entry.Name);
        Console.WriteLine($"  archive holds {names[0]} and "
                          + $"{names.Count(n => !n.EndsWith(".checksum")) - 1} disk block(s)");

        // The imported VM's ref is NOT in the /import response body on a real host (only this simulator's
        // convenience echoes it there). Create a task first, append &task_id=<task> to the /import URL,
        // poll the task, and parse the ref out of task.get_result() (same <value>...</value> string-strip
        // wait-for-task already uses).
        var task = Task.create(session, "vm_import", $"importing {vm.Value.name_label} back").opaque_ref;
        string imported;
        try
        {
            using (var client = InsecureHttpClient())
            {
                var response = client.PutAsync(
                    $"{url}/import?session_id={session.opaque_ref}&task_id={task}",
                    new ByteArrayContent(File.ReadAllBytes(path))).Result;
                response.EnsureSuccessStatusCode();
            }

            while (Task.get_status(session, task) == task_status_type.pending)
                System.Threading.Thread.Sleep(500);
            if (Task.get_status(session, task) != task_status_type.success)
                throw new Exception($"import failed: {string.Join(", ", Task.get_error_info(session, task))}");
            imported = Task.get_result(session, task).Replace("<value>", "").Replace("</value>", "").Trim();
        }
        finally
        {
            Task.destroy(session, task);
        }
        Console.WriteLine($"  imported as {VM.get_name_label(session, imported)}");

        DestroyVmAndDisks(session, imported);
        File.Delete(path);
        Console.WriteLine("OK: export-import-vm");
        session.logout();
    }
    // Run it:
    //   ExportImportVm("https://xenserver", "root", password);

    /// <summary>An HTTP client that accepts the host's self-signed certificate, as Connect does.</summary>
    private static HttpClient InsecureHttpClient() =>
        new(new HttpClientHandler { ServerCertificateCustomValidationCallback = (_, _, _, _) => true })
        {
            Timeout = TimeSpan.FromMinutes(5),
        };

    // --- Configure dynamic memory ---------------------------------------------------------
    private static void ConfigureDynamicMemory(string url, string user, string password)
    {
        var session = Connect(url, user, password);

        var vm = VM.get_all_records(session).First(kv =>
            !kv.Value.is_a_template && !kv.Value.is_control_domain && !kv.Value.is_a_snapshot &&
            kv.Value.power_state == vm_power_state.Halted);
        var before = vm.Value;
        Console.WriteLine($"{before.name_label}: static {Gib(before.memory_static_min)}-"
                          + $"{Gib(before.memory_static_max)}, dynamic {Gib(before.memory_dynamic_min)}-"
                          + $"{Gib(before.memory_dynamic_max)}");

        // Room to balloon: let the host squeeze the VM down to a quarter of its maximum, but never below
        // the static floor, which is the least the guest can boot in.
        var floor = Math.Max(before.memory_static_min, before.memory_static_max / 4);
        var ceiling = before.memory_static_max;
        VM.set_memory_dynamic_range(session, vm.Key.opaque_ref, floor, ceiling);
        Console.WriteLine($"  dynamic range now {Gib(VM.get_memory_dynamic_min(session, vm.Key.opaque_ref))}-"
                          + $"{Gib(VM.get_memory_dynamic_max(session, vm.Key.opaque_ref))}");

        // The ordering is enforced, not advisory: a range wider than the static bounds is refused rather
        // than quietly clamped.
        try
        {
            VM.set_memory_dynamic_range(session, vm.Key.opaque_ref, floor, ceiling * 2);
            Console.WriteLine("  ERROR: an out-of-range maximum was accepted");
        }
        catch (Failure failure)
        {
            Console.WriteLine($"  refused a dynamic_max above static_max: {failure.ErrorDescription[0]}");
        }

        VM.set_memory_dynamic_range(session, vm.Key.opaque_ref,
            before.memory_dynamic_min, before.memory_dynamic_max);
        Console.WriteLine("OK: configure-dynamic-memory");
        session.logout();
    }
    // Run it:
    //   ConfigureDynamicMemory("https://xenserver", "root", password);

    private static string Gib(long bytes) => $"{bytes / (1024.0 * 1024 * 1024):F1} GiB";

    // --- Manage a VM's CD drive -----------------------------------------------------------
    private static void ManageVmMedia(string url, string user, string password)
    {
        var session = Connect(url, user, password);

        var vm = VM.get_all_records(session).First(kv =>
            !kv.Value.is_a_template && !kv.Value.is_control_domain && !kv.Value.is_a_snapshot &&
            kv.Value.power_state == vm_power_state.Halted);
        Console.WriteLine($"Adding a DVD drive to {vm.Value.name_label}");

        // A CD drive is a VBD like any other, distinguished by type=CD; the media is whichever VDI it
        // points at, and an empty drive points at none.
        var device = VM.get_allowed_VBD_devices(session, vm.Key.opaque_ref)[0];
        var drive = VBD.create(session, new VBD
        {
            VM = vm.Key,
            VDI = new XenRef<VDI>(Helper.NullOpaqueRef),
            userdevice = device,
            bootable = false,
            mode = vbd_mode.RO,
            type = vbd_type.CD,
            empty = true,
            unpluggable = true,
            other_config = new Dictionary<string, string>(),
            qos_algorithm_type = "",
            qos_algorithm_params = new Dictionary<string, string>(),
        }).opaque_ref;
        Console.WriteLine($"  drive {device} is empty: {VBD.get_empty(session, drive)}");

        // The ISO library is an SR of content type "iso"; its VDIs are the available images.
        var isoSr = SR.get_all_records(session)
            .First(kv => kv.Value.content_type == "iso" && kv.Value.type != "udev");
        var iso = SR.get_VDIs(session, isoSr.Key.opaque_ref)
            .Select(v => v.opaque_ref)
            .OrderBy(v => VDI.get_name_label(session, v))
            .First();
        Console.WriteLine($"  inserting {VDI.get_name_label(session, iso)}");
        VBD.insert(session, drive, iso);
        Console.WriteLine($"  drive now holds {VDI.get_name_label(session, VBD.get_VDI(session, drive).opaque_ref)}"
                          + $" (empty={VBD.get_empty(session, drive)})");

        VBD.eject(session, drive);
        Console.WriteLine($"  after eject, empty={VBD.get_empty(session, drive)}");

        VBD.destroy(session, drive);
        Console.WriteLine("OK: manage-vm-media");
        session.logout();
    }
    // Run it:
    //   ManageVmMedia("https://xenserver", "root", password);

    // --- Back up a host's configuration ----------------------------------------------------
    // Both /host_backup and /host_restore are served only by whichever host physically accepted the HTTP
    // connection - the handler is keyed off the connection's own address, not any ref= in the query
    // string. So backing up/restoring a host means opening the connection to THAT host's own address,
    // not the pool's (coordinator) url - a restore sent to the wrong host's connection silently restores
    // the WRONG host. ref= is kept in the query string purely for log-readability on a real host, and
    // because the currently-frozen simulator build still requires it.
    private static void BackupHostConfig(string url, string user, string password)
    {
        var session = Connect(url, user, password);

        var hosts = Host.get_all(session).Select(h => h.opaque_ref).ToList();
        var host = hosts[0];
        var hostUrl = HostUrl(url, Host.get_address(session, host));
        Console.WriteLine($"Backing up {Host.get_name_label(session, host)}");

        var path = Path.Combine(Path.GetTempPath(), $"sdk-example-host-{Guid.NewGuid():N}.backup");
        using (var client = InsecureHttpClient())
        {
            var bytes = client.GetByteArrayAsync(
                $"{hostUrl}/host_backup?session_id={session.opaque_ref}&ref={host}").Result;
            File.WriteAllBytes(path, bytes);
            Console.WriteLine($"  wrote {bytes.Length} bytes to {Path.GetFileName(path)}");
        }

        Console.WriteLine($"  restoring it to {Host.get_name_label(session, host)}: "
                          + RestoreHostConfig(session, hostUrl, host, path));
        if (hosts.Count > 1)
        {
            var other = hosts[1];
            var otherUrl = HostUrl(url, Host.get_address(session, other));
            string result;
            try
            {
                result = RestoreHostConfig(session, otherUrl, other, path);
            }
            catch (Exception e)
            {
                // A real pool's hosts are all reachable from a management client; this only guards an
                // environment (e.g. a simulator whose second host's address isn't actually routable from
                // here) where that isn't true, so the example still finishes cleanly.
                result = $"could not connect to {otherUrl} directly ({e.Message})";
            }
            Console.WriteLine($"  restoring it to {Host.get_name_label(session, other)}: {result}");
        }

        File.Delete(path);
        Console.WriteLine("OK: backup-host-config");
        session.logout();
    }
    // Run it:
    //   BackupHostConfig("https://xenserver", "root", password);

    /// <summary>
    /// Upload a backup to a host - over a connection opened to THAT host's own address - and report
    /// what the task says about it.
    /// </summary>
    /// <remarks>
    /// An upload answers 200 as soon as it has read the request headers, because the client waits for that
    /// before it starts sending the file. The outcome therefore cannot be in the status line: it arrives on
    /// a task you create first, name in the URL, and poll once the upload has finished.
    /// </remarks>
    private static string RestoreHostConfig(Session session, string hostUrl, string host, string path)
    {
        var task = Task.create(session, "host_restore", "restoring a configuration backup").opaque_ref;
        try
        {
            using (var client = InsecureHttpClient())
            {
                var response = client.PutAsync(
                    $"{hostUrl}/host_restore?session_id={session.opaque_ref}&ref={host}&task_id={task}",
                    new ByteArrayContent(File.ReadAllBytes(path))).Result;
                response.EnsureSuccessStatusCode();
            }

            while (Task.get_status(session, task) == task_status_type.pending)
                System.Threading.Thread.Sleep(500);
            if (Task.get_status(session, task) == task_status_type.success) return "accepted";
            return $"refused ({Task.get_error_info(session, task).Last()})";
        }
        finally
        {
            Task.destroy(session, task);
        }
    }

    // --- Detach, reattach and forget storage -----------------------------------------------
    private static void ManageSrLifecycle(string url, string user, string password,
        string nfsServer = "192.0.2.10", string nfsPath = "/export/spare")
    {
        var session = Connect(url, user, password);

        // There is no "detach" call on an SR. A shared SR is joined to each host by one PBD — a physical
        // block device — and detaching the SR means unplugging every one of them. That is why an SR can
        // be attached on some hosts and not others, and why a repair action exists at all: it plugs back
        // the PBDs that are missing.
        var host = Host.get_all(session).First().opaque_ref;
        var sr = SR.create(session, host, new Dictionary<string, string>
        {
            ["server"] = nfsServer,
            ["serverpath"] = nfsPath,
            ["nfsversion"] = "3",
        }, 0, "sdk-example-lifecycle", "SR used by the SDK lifecycle example",
            "nfs", "user", true, new Dictionary<string, string>()).opaque_ref;

        var pbds = SR.get_PBDs(session, sr).Select(p => p.opaque_ref).ToList();
        Console.WriteLine($"{SR.get_name_label(session, sr)}: connected on "
                          + $"{AttachedPbds(session, pbds)} of {pbds.Count} host(s)");

        foreach (var pbd in pbds) PBD.unplug(session, pbd);
        Console.WriteLine($"  detached:   connected on {AttachedPbds(session, pbds)} host(s)");

        // Plugging them back is exactly what a repair does.
        foreach (var pbd in pbds) PBD.plug(session, pbd);
        Console.WriteLine($"  reattached: connected on {AttachedPbds(session, pbds)} host(s)");

        SR.scan(session, sr);
        Console.WriteLine($"  rescanned:  {SR.get_VDIs(session, sr).Count} disk(s)");

        // Forgetting drops the pool's record of the SR but leaves the storage itself untouched, so the
        // same export can be introduced again later. Detach before forgetting: a connected SR is in use.
        foreach (var pbd in pbds) PBD.unplug(session, pbd);
        SR.forget(session, sr);
        Console.WriteLine("  forgotten");
        Console.WriteLine("OK: manage-sr-lifecycle");
        session.logout();
    }

    /// <summary>How many of these connections are currently live.</summary>
    private static int AttachedPbds(Session session, IEnumerable<string> pbds) =>
        pbds.Count(pbd => PBD.get_currently_attached(session, pbd));
    // Run it:
    //   ManageSrLifecycle("https://xenserver", "root", password);

    // --- Set the pool's default storage ------------------------------------------------------
    private static void SetDefaultSr(string url, string user, string password,
        string nfsServer = "192.0.2.10", string nfsPath = "/export/spare")
    {
        var session = Connect(url, user, password);
        var pool = Pool.get_all(session).First().opaque_ref;

        // Capture all three separately. New disks land on the default SR, a suspended VM's memory image
        // goes to the suspend-image SR and host crash dumps to the crash-dump SR. They are usually the
        // same storage but need not be, and a pool that has never suspended or crashed anything can
        // legitimately leave the latter two unset — so restoring all three from the default would
        // quietly invent settings that were not there.
        var before = Pool.get_default_SR(session, pool).opaque_ref;
        var beforeSuspend = Pool.get_suspend_image_SR(session, pool).opaque_ref;
        var beforeCrash = Pool.get_crash_dump_SR(session, pool).opaque_ref;
        Console.WriteLine($"default storage:  {SrLabel(session, before)}");
        Console.WriteLine($"  suspend images: {SrLabel(session, beforeSuspend)}");
        Console.WriteLine($"  crash dumps:    {SrLabel(session, beforeCrash)}");

        // Somewhere to switch to. A pool default has to be reachable from every host, so it is a shared
        // SR; a local one would strand any VM whose disk landed on the wrong host.
        var sr = SR.create(session, Host.get_all(session).First().opaque_ref,
            new Dictionary<string, string>
            {
                ["server"] = nfsServer,
                ["serverpath"] = nfsPath,
                ["nfsversion"] = "3",
            }, 0, "sdk-example-default", "SR used by the SDK default-storage example",
            "nfs", "user", true, new Dictionary<string, string>()).opaque_ref;

        Pool.set_default_SR(session, pool, sr);
        Pool.set_suspend_image_SR(session, pool, sr);
        Pool.set_crash_dump_SR(session, pool, sr);
        Console.WriteLine($"  switched to:    {SrLabel(session, Pool.get_default_SR(session, pool).opaque_ref)}");

        // Restore the original choice before tidying up: an SR that is still the pool default is the
        // awkward one to remove.
        Pool.set_default_SR(session, pool, before);
        Pool.set_suspend_image_SR(session, pool, beforeSuspend);
        Pool.set_crash_dump_SR(session, pool, beforeCrash);
        foreach (var pbd in SR.get_PBDs(session, sr)) PBD.unplug(session, pbd.opaque_ref);
        SR.forget(session, sr);
        Console.WriteLine($"  restored to:    {SrLabel(session, Pool.get_default_SR(session, pool).opaque_ref)}");
        Console.WriteLine("OK: set-default-sr");
        session.logout();
    }

    /// <summary>An SR's name, tolerating the null reference an unset pool field holds.</summary>
    private static string SrLabel(Session session, string sr) =>
        string.IsNullOrEmpty(sr) || sr == "OpaqueRef:NULL" ? "(none)" : SR.get_name_label(session, sr);
    // Run it:
    //   SetDefaultSr("https://xenserver", "root", password);

    // --- Collect a server status report ------------------------------------------------------
    private static void ServerStatusReport(string url, string user, string password)
    {
        var session = Connect(url, user, password);

        // Report on the coordinator. Each host answers for itself, so which one you ask decides whose
        // logs you get — support normally wants every host, one download each.
        var host = Pool.get_master(session, Pool.get_all(session).First().opaque_ref).opaque_ref;
        Console.WriteLine($"Status report for {Host.get_name_label(session, host)}");

        // The host publishes a catalogue of the sections it can report on, each with a size estimate and
        // whether it may contain personal data, so a client can offer an informed choice rather than
        // hard-coding the list.
        var keys = new List<string>();
        foreach (var capability in XDocument.Parse(
                     Host.get_system_status_capabilities(session, host)).Root!.Elements())
        {
            keys.Add((string)capability.Attribute("key")!);
            Console.WriteLine($"  {(string)capability.Attribute("key")!,-22} "
                              + $"max {(string)capability.Attribute("max-size")!,9} bytes  "
                              + $"default={(string)capability.Attribute("default-checked")!,-3} "
                              + $"pii={(string)capability.Attribute("pii")!}");
        }

        var whole = FetchStatusReport(session, url, keys);
        Console.WriteLine($"everything ({keys.Count} sections): {whole} bytes");

        // Pick a real, small section from the host's own catalogue rather than assuming a name: the
        // catalogue is server-defined (xen-bugtool's own --capabilities output), not a fixed client
        // list, and "xenserver-config" isn't one of the real keys any host actually publishes.
        var subsetKey = keys.FirstOrDefault(k => k is "firstboot" or "network-status") ?? keys[0];
        var subset = FetchStatusReport(session, url, new[] { subsetKey });
        Console.WriteLine($"{subsetKey} only:   {subset} bytes");
        if (subset >= whole)
            Console.WriteLine("  ERROR: selecting fewer sections did not produce a smaller bundle");

        Console.WriteLine("OK: server-status-report");
        session.logout();
    }

    /// <summary>Download the bundle for the given capability keys (a tar archive) and report its size.</summary>
    private static int FetchStatusReport(Session session, string url, IEnumerable<string> entries)
    {
        using var client = InsecureHttpClient();
        // A full report (all sections) can take well over the default 5-minute client timeout on a real
        // host with a lot to report on; this download alone gets a much longer allowance.
        client.Timeout = TimeSpan.FromMinutes(30);
        return client.GetByteArrayAsync(
            $"{url}/system-status?session_id={session.opaque_ref}&output=tar"
            + $"&entries={string.Join(",", entries)}").Result.Length;
    }
    // Run it:
    //   ServerStatusReport("https://xenserver", "root", password);

    // --- Recover VMs after a disaster --------------------------------------------------------
    // Replicate the pool's database to shared storage, then recover a VM out of it onto a second,
    // standby pool. That destination has to be a DIFFERENT, standby pool: recovering a VM back into the
    // exact pool it was replicated from can't actually succeed with force=false (VM_TO_IMPORT_IS_NOT_
    // NEWER_VERSION), and passing force=true instead would succeed by REPLACING the live original -
    // exactly the opposite of what a DR demo should show, and the thing that would actually destroy a
    // live VM if ever pointed at the same pool it replicated from. Track the recovered VM by uuid, never
    // by name: a name can coincidentally collide with something already on the destination pool.
    private static void DisasterRecovery(string url, string user, string password, string drUrl)
    {
        if (string.IsNullOrEmpty(drUrl))
            throw new Exception("disaster-recovery needs a second pool to recover into: pass " +
                                "dr_url=<url of a standby pool>");

        var session = Connect(url, user, password);
        var drSession = Connect(drUrl, user, password);

        // Replication needs storage every host can reach and that can hold data. The server checks rather
        // than taking your word for it, so ask before enabling.
        var sr = SR.get_all_records(session).First(kv =>
            kv.Value.shared && kv.Value.content_type != "iso"
            && kv.Value.type != "iso" && kv.Value.type != "udev").Key.opaque_ref;
        SR.assert_supports_database_replication(session, sr);
        Console.WriteLine($"Replicating pool metadata to {SR.get_name_label(session, sr)}");
        SR.enable_database_replication(session, sr);

        var vdi = SR.get_VDIs(session, sr)
            .First(v => VDI.get_type(session, v.opaque_ref) == vdi_type.metadata).opaque_ref;
        Console.WriteLine($"  metadata disk: {VDI.get_uuid(session, vdi)}");

        // A session onto the replicated database rather than the live pool. Assembled from the URL and the
        // session id we were handed rather than with Session(url, opaqueRef): that constructor queries the
        // pool immediately to work out the API version, which happens before there is any chance to accept
        // the host's self-signed certificate.
        var metadata = new Session(url) { opaque_ref = VDI.open_database(session, vdi).opaque_ref };
        metadata.JsonRpcClient.ServerCertificateValidationCallback = (req, cert, chain, errors) => true;

        // Only real guest VMs are recoverable - exclude templates, control domains and snapshots.
        var recoverable = VM.get_all_records(metadata).Where(kv =>
            !kv.Value.is_a_template && !kv.Value.is_control_domain && !kv.Value.is_a_snapshot).ToList();
        Console.WriteLine($"  the replicated database describes {recoverable.Count} recoverable VM(s)");

        var target = recoverable.OrderBy(kv => kv.Value.name_label).First();
        var targetUuid = target.Value.uuid;
        var name = target.Value.name_label;
        Console.WriteLine($"  recovering {name}");

        // Both calls run on the METADATA session; session_to says where the VM should land - the
        // STANDBY pool's session, not this one.
        VM.assert_can_be_recovered(metadata, target.Key.opaque_ref, drSession.opaque_ref);
        VM.recover(metadata, target.Key.opaque_ref, drSession.opaque_ref, false);

        // It is a real VM on the standby pool now, not merely a call that returned - look it up by the
        // uuid full_restore preserved, not by name. NO fallback to the source pool: a second pool is the
        // only correct target, and on a real pool this lookup always succeeds. (A frozen simulator build
        // under test may not honour session_to - that is a simulator gap being fixed there, not
        // something this sample should work around.)
        var recovered = VM.get_by_uuid(drSession, targetUuid).opaque_ref;
        Console.WriteLine($"  {name} is {VM.get_power_state(drSession, recovered)} on the standby pool");

        // Tidy up on the standby pool only, by uuid - never touch the source pool's VMs, and never
        // guess by name.
        DestroyVmAndDisks(drSession, recovered);
        SR.disable_database_replication(session, sr);
        Console.WriteLine("OK: disaster-recovery");
        session.logout();
        drSession.logout();
    }
    // Run it:
    //   DisasterRecovery("https://xenserver", "root", password, "https://standby-pool");

    // --- Manage Secure Boot certificates -----------------------------------------------------
    private static void ManageSecurebootCertificates(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var pool = Pool.get_all(session).First().opaque_ref;

        // A Secure Boot guest carries its own copy of the pool's UEFI certificates, taken when it was
        // created. Rotating the pool's leaves the guest's stale, and the fix is applied at the guest's
        // next boot rather than underneath a running VM — so you flag it and reboot when convenient.
        //
        // First, whether the pool holds the certificates to hand out at all. "ready_no_dbx" means it has
        // the essentials but no revocation list — usable, and not the same answer as "ready".
        Console.WriteLine($"Pool Secure Boot readiness: {Pool.get_guest_secureboot_readiness(session, pool)}");
        Console.WriteLine("  pool holds certificates:  "
                          + !string.IsNullOrEmpty(Pool.get_uefi_certificates(session, pool)));

        // A guest whose certificates have gone stale. Its state is what a client gates the flag/unflag
        // actions on, so it is the field to watch. This is a deliberately-provisioned state, not one a
        // normally-provisioned Secure Boot guest is ever in - so report and stop cleanly rather than
        // letting a bare "no such element" lookup error propagate when nothing needs it right now.
        var candidate = VM.get_all_records(session).FirstOrDefault(kv =>
            !kv.Value.is_a_template && !kv.Value.is_control_domain && !kv.Value.is_a_snapshot
            && kv.Value.secureboot_certificates_state == vm_secureboot_certificates_state.update_available);
        if (candidate.Key == null)
        {
            Console.WriteLine("No guest needs a Secure Boot certificate refresh right now.");
            Console.WriteLine("OK: manage-secureboot-certificates");
            session.logout();
            return;
        }
        var vm = candidate.Key.opaque_ref;
        Console.WriteLine($"{VM.get_name_label(session, vm)}: readiness "
                          + $"{VM.get_secureboot_readiness(session, vm)}, certificates "
                          + $"{VM.get_secureboot_certificates_state(session, vm)}");

        // Flagging and unflagging are the same call with opposite booleans.
        VM.update_secureboot_certificates_on_boot(session, vm, true);
        Console.WriteLine($"  flagged for refresh:      {VM.get_secureboot_certificates_state(session, vm)}");

        VM.update_secureboot_certificates_on_boot(session, vm, false);
        Console.WriteLine($"  unflagged:                {VM.get_secureboot_certificates_state(session, vm)}");

        Console.WriteLine("OK: manage-secureboot-certificates");
        session.logout();
    }
    // Run it:
    //   ManageSecurebootCertificates("https://xenserver", "root", password);

    // --- Restart a host ----------------------------------------------------------------------
    private static void RestartHost(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var pool = Pool.get_all(session).First().opaque_ref;

        // Rebooting a host is never just the reboot: anything running on it has to go somewhere first,
        // and the host has to stop accepting new VMs while that happens.
        //
        // Not the coordinator: it is the host this session is talking to, and taking it down would drop
        // the connection underneath the rest of the example.
        var coordinator = Pool.get_master(session, pool).opaque_ref;
        var host = Host.get_all(session).First(h => h.opaque_ref != coordinator).opaque_ref;
        Console.WriteLine($"Restarting {Host.get_name_label(session, host)}");
        Console.WriteLine($"  enabled={Host.get_enabled(session, host)}, guests={GuestCount(session, host)}");

        // Disabled means "accept no new VMs"; it does not move anything on its own.
        Host.disable(session, host);
        Console.WriteLine($"  disabled:   enabled={Host.get_enabled(session, host)}");

        // Evacuate moves the guests elsewhere in the pool. Afterwards only the control domain — the
        // host's own management VM, which cannot move — is left.
        Host.evacuate(session, host);
        Console.WriteLine($"  evacuated:  guests={GuestCount(session, host)}");

        Host.reboot(session, host);
        // A real reboot takes minutes; a production tool would poll host_metrics/boot_time for as long as
        // XenRT's own waitForEnabled() does (up to 900s). This demo waits only long enough for the reboot
        // to get underway, then explicitly re-enables - disabling does not clear itself, not even across
        // a reboot, so nothing else re-enables the host for us.
        System.Threading.Thread.Sleep(5000);
        Host.enable(session, host);
        Console.WriteLine($"  rebooted, re-enabled: enabled={Host.get_enabled(session, host)}");

        // The other ending: off, and back on out of band - but only demonstrated if that is actually
        // configured: a real host.power_on has no retry of its own and simply fails,
        // "The host failed to power on.", if no mechanism is configured or working.
        if (!string.IsNullOrEmpty(Host.get_power_on_mode(session, host)))
        {
            Host.disable(session, host);
            Host.shutdown(session, host);
            WaitForHostLive(session, host, false);
            Console.WriteLine($"  shut down:  live={HostLive(session, host)}");
            Host.power_on(session, host);
            WaitForHostLive(session, host, true);
            Console.WriteLine($"  powered on: live={HostLive(session, host)}");
            Host.enable(session, host);
            Console.WriteLine($"  re-enabled: enabled={Host.get_enabled(session, host)}");
        }
        else
        {
            Console.WriteLine("  skipping shutdown/power-on: no out-of-band power-on mode is configured on this host");
        }

        Console.WriteLine("OK: restart-host");
        session.logout();
    }

    /// <summary>Resident VMs excluding the control domain, which never moves.</summary>
    private static int GuestCount(Session session, string host) =>
        Host.get_resident_VMs(session, host).Count(v => !VM.get_is_control_domain(session, v.opaque_ref));

    private static bool HostLive(Session session, string host) =>
        Host_metrics.get_live(session, Host.get_metrics(session, host).opaque_ref);
    // Run it:
    //   RestartHost("https://xenserver", "root", password);

    // --- Create a VM and a template from a snapshot ------------------------------------------
    private static void VmFromSnapshot(string url, string user, string password, string vmName)
    {
        var session = Connect(url, user, password);

        // A snapshot is a VM record with is_a_snapshot (and is_a_template) set, and cloning it gives a
        // custom template that stands on its own while the snapshot stays put.
        var vm = VmByName(session, vmName);
        var snapshot = VM.snapshot(session, vm, "sdk-example-source-snapshot").opaque_ref;
        Console.WriteLine($"Snapshot of {vmName} taken");

        // A clone of a snapshot is a template, not another snapshot: it stands on its own instead of
        // being filed under the original VM. Provision it to get an ordinary VM you can start.
        var newVm = VM.clone(session, snapshot, "sdk-example-vm-from-snapshot").opaque_ref;
        Provision(session, newVm);
        Console.WriteLine($"  new VM:      {VM.get_name_label(session, newVm)} "
                          + $"(is_a_template={VM.get_is_a_template(session, newVm)})");

        // Another clone, left as the template it already is: a starting point to stamp more VMs from.
        var template = VM.clone(session, snapshot, "sdk-example-template-from-snapshot").opaque_ref;
        Console.WriteLine($"  new template:{VM.get_name_label(session, template)} "
                          + $"(is_a_template={VM.get_is_a_template(session, template)})");

        foreach (var r in new[] { newVm, template, snapshot }) DestroyVmAndDisks(session, r);
        Console.WriteLine("OK: vm-from-snapshot");
        session.logout();
    }
    // Run it:
    //   VmFromSnapshot("https://xenserver", "root", password, "db-01");

    // --- Attach an existing disk to another VM -----------------------------------------------
    private static void AttachExistingDisk(string url, string user, string password)
    {
        const long GiB = 1024L * 1024 * 1024;
        var session = Connect(url, user, password);

        // A disk and the VM it belongs to are separate objects joined by a VBD, so moving a disk between
        // VMs is removing one VBD and creating another — no copying, and the data stays where it is.
        var halted = VM.get_all_records(session)
            .Where(kv => !kv.Value.is_a_template && !kv.Value.is_control_domain && !kv.Value.is_a_snapshot
                         && kv.Value.power_state == vm_power_state.Halted)
            .Select(kv => kv.Key.opaque_ref).ToList();

        var sr = SR.get_all_records(session).First(kv =>
            kv.Value.shared && kv.Value.content_type != "iso"
            && kv.Value.type != "iso" && kv.Value.type != "udev").Key.opaque_ref;
        var vdi = VDI.create(session, new VDI
        {
            name_label = "sdk-example-portable-disk",
            SR = new XenRef<SR>(sr),
            virtual_size = 4 * GiB,
            type = vdi_type.user,
            sharable = false,
            read_only = false,
            other_config = new Dictionary<string, string>(),
        }).opaque_ref;
        Console.WriteLine($"Disk {VDI.get_name_label(session, vdi)} created on "
                          + SR.get_name_label(session, sr));

        var vbd = AttachVdi(session, halted[0], vdi);
        Console.WriteLine($"  attached to {VM.get_name_label(session, halted[0])}");

        // Destroying the VBD detaches the disk; the disk itself is untouched and keeps its data.
        VBD.destroy(session, vbd);
        Console.WriteLine($"  detached:   the disk still exists ({VDI.get_virtual_size(session, vdi)} bytes)");

        AttachVdi(session, halted[1], vdi);
        Console.WriteLine($"  attached to {VM.get_name_label(session, halted[1])}");
        Console.WriteLine($"  the disk is on {VDI.get_VBDs(session, vdi).Count} VM(s)");

        foreach (var r in VDI.get_VBDs(session, vdi)) VBD.destroy(session, r.opaque_ref);
        VDI.destroy(session, vdi);
        Console.WriteLine("OK: attach-existing-disk");
        session.logout();
    }

    /// <summary>Join an existing disk to a VM on its next free device slot.</summary>
    private static string AttachVdi(Session session, string vm, string vdi) => VBD.create(session, new VBD
    {
        VM = new XenRef<VM>(vm),
        VDI = new XenRef<VDI>(vdi),
        userdevice = VM.get_allowed_VBD_devices(session, vm).First(),
        mode = vbd_mode.RW,
        type = vbd_type.Disk,
        empty = false,
        other_config = new Dictionary<string, string>(),
        qos_algorithm_type = "",
        qos_algorithm_params = new Dictionary<string, string>(),
    }).opaque_ref;
    // Run it:
    //   AttachExistingDisk("https://xenserver", "root", password);

    // --- Clear a host's crash dumps ------------------------------------------------------------
    private static void ManageCrashDumps(string url, string user, string password)
    {
        var session = Connect(url, user, password);

        // When a host crashes it writes a dump to its local disk and keeps it. They are large, nothing
        // cleans them up, and a host that has crashed more than once accumulates them — so clearing them
        // once support has what it needs is ordinary housekeeping. They belong to the host that wrote
        // them, so clear them a host at a time.
        var host = Host.get_all(session)
            .FirstOrDefault(h => Host.get_crashdumps(session, h.opaque_ref).Count > 0)?.opaque_ref;
        if (host == null)
        {
            Console.WriteLine("No crash dumps in this pool — nothing to clear.");
            Console.WriteLine("OK: manage-crash-dumps");
            session.logout();
            return;
        }

        var dumps = Host.get_crashdumps(session, host);
        long total = 0;
        Console.WriteLine($"{Host.get_name_label(session, host)} has {dumps.Count} crash dump(s)");
        foreach (var dump in dumps)
        {
            var record = Host_crashdump.get_record(session, dump.opaque_ref);
            total += record.size;
            Console.WriteLine($"  {record.timestamp:yyyyMMdd'T'HH:mm:ss'Z'}  {Mib(record.size)}");
        }
        Console.WriteLine($"  {Mib(total)} in total");

        // Deleting a dump frees the space on the host; the host itself is untouched.
        foreach (var dump in dumps) Host_crashdump.destroy(session, dump.opaque_ref);
        Console.WriteLine($"  cleared:  {Host.get_name_label(session, host)} now has "
                          + Host.get_crashdumps(session, host).Count);

        Console.WriteLine("OK: manage-crash-dumps");
        session.logout();
    }

    private static string Mib(long size) => $"{size / (1024 * 1024)} MiB";
    // Run it:
    //   ManageCrashDumps("https://xenserver", "root", password);

    // --- Configure pool options ----------------------------------------------------------------
    private static void ConfigurePoolOptions(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var pool = Pool.get_all(session)[0].opaque_ref;

        // None of these is a wizard: they are plain pool settings that a client exposes on a
        // properties page, and each is a single field. Read them, change them, put them back.
        var livePatchingDisabled = Pool.get_live_patching_disabled(session, pool);
        var igmpSnooping = Pool.get_igmp_snooping_enabled(session, pool);
        var migrationCompression = Pool.get_migration_compression(session, pool);
        Console.WriteLine($"  {"live patching disabled",-22} {livePatchingDisabled}");
        Console.WriteLine($"  {"IGMP snooping",-22} {igmpSnooping}");
        Console.WriteLine($"  {"migration compression",-22} {migrationCompression}");

        // Live patching applies host updates without a reboot; disabling it forces the reboot.
        Pool.set_live_patching_disabled(session, pool, !livePatchingDisabled);
        // IGMP snooping keeps multicast off ports that did not ask for it.
        Pool.set_igmp_snooping_enabled(session, pool, !igmpSnooping);
        // Compression trades CPU for bandwidth when a VM's memory is moved between hosts.
        Pool.set_migration_compression(session, pool, !migrationCompression);

        Console.WriteLine("after changing:");
        Console.WriteLine($"  {"live patching disabled",-22} {Pool.get_live_patching_disabled(session, pool)}");
        Console.WriteLine($"  {"IGMP snooping",-22} {Pool.get_igmp_snooping_enabled(session, pool)}");
        Console.WriteLine($"  {"migration compression",-22} {Pool.get_migration_compression(session, pool)}");

        Pool.set_live_patching_disabled(session, pool, livePatchingDisabled);
        Pool.set_igmp_snooping_enabled(session, pool, igmpSnooping);
        Pool.set_migration_compression(session, pool, migrationCompression);
        Console.WriteLine("  restored");
        Console.WriteLine("OK: configure-pool-options");
        session.logout();
    }
    // Run it:
    //   ConfigurePoolOptions("https://xenserver", "root", password);

    // --- Configure console access ----------------------------------------------------------------
    // Tighten how consoles and management traffic may be used. Idle console sessions are set at two
    // levels — the pool's own management consoles and the VM consoles it serves — and a host can
    // override the pool's. Requiring HTTPS refuses plain HTTP to the management interface altogether.
    //
    // NOTE: SDK 26.14's C# binding has Pool.set_console_idle_timeout and Pool.set_https_only but no
    // matching GETTERS (unlike host.console_idle_timeout, which has both) — so the pool's own
    // management-console timeout and its HTTPS-only flag can be set here but not read back through
    // this binding. Those two read lines are therefore omitted rather than worked around.
    private static void ConfigureConsoleAccess(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var pool = Pool.get_all(session)[0].opaque_ref;
        var host = Pool.get_master(session, pool).opaque_ref;

        Console.WriteLine($"  {"VM console idle timeout",-26} {Pool.get_vm_console_idle_timeout(session, pool)}s");
        Console.WriteLine($"  {"limit console sessions",-26} {Pool.get_limit_console_sessions(session, pool)}");
        Console.WriteLine($"  {"host console idle timeout",-26} {Host.get_console_idle_timeout(session, host)}s");

        // Ten minutes of inactivity, one console session at a time, and no plain HTTP.
        Pool.set_console_idle_timeout(session, pool, 600);
        Pool.set_vm_console_idle_timeout(session, pool, 600);
        Pool.set_limit_console_sessions(session, pool, true);
        Host.set_console_idle_timeout(session, host, 300);
        Pool.set_https_only(session, pool, true);

        Console.WriteLine("after tightening:");
        Console.WriteLine($"  {"VM console idle timeout",-26} {Pool.get_vm_console_idle_timeout(session, pool)}s");
        Console.WriteLine($"  {"limit console sessions",-26} {Pool.get_limit_console_sessions(session, pool)}");
        Console.WriteLine($"  {"host console idle timeout",-26} {Host.get_console_idle_timeout(session, host)}s");

        Pool.set_https_only(session, pool, false);
        Pool.set_console_idle_timeout(session, pool, 0);
        Pool.set_vm_console_idle_timeout(session, pool, 0);
        Pool.set_limit_console_sessions(session, pool, false);
        Host.set_console_idle_timeout(session, host, 0);
        Console.WriteLine("  restored");
        Console.WriteLine("OK: configure-console-access");
        session.logout();
    }
    // Run it:
    //   ConfigureConsoleAccess("https://xenserver", "root", password);

    // --- Configure host storage --------------------------------------------------------------------
    private static void ConfigureHostStorage(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var host = Pool.get_master(session, Pool.get_all(session)[0].opaque_ref).opaque_ref;

        // The IQN identifies this host to iSCSI targets, so a target's access list is written against
        // it — changing it on a host with live iSCSI storage cuts it off. Multipathing uses every path
        // to the storage rather than one, and on real hardware you put the host into maintenance mode
        // before changing it, because the paths are rebuilt.
        var beforeIqn = Host.get_iscsi_iqn(session, host);
        var beforeMultipathing = Host.get_multipathing(session, host);
        Console.WriteLine($"{Host.get_name_label(session, host)}: iSCSI IQN '{beforeIqn}', " +
                          $"multipathing {beforeMultipathing}");

        Host.set_iscsi_iqn(session, host, $"iqn.2026-01.com.example:{Host.get_name_label(session, host)}");
        Host.set_multipathing(session, host, true);
        Console.WriteLine($"  IQN now:      {Host.get_iscsi_iqn(session, host)}");
        Console.WriteLine($"  multipathing: {Host.get_multipathing(session, host)}");

        // set_iscsi_iqn refuses an empty string (INVALID_VALUE); only restore it if this host actually
        // had one set before - a host that has never had an IQN configured has it empty, and there is no
        // way to set it back to empty through this call.
        if (!string.IsNullOrEmpty(beforeIqn)) Host.set_iscsi_iqn(session, host, beforeIqn);
        Host.set_multipathing(session, host, beforeMultipathing);
        Console.WriteLine("  restored");
        Console.WriteLine("OK: configure-host-storage");
        session.logout();
    }
    // Run it:
    //   ConfigureHostStorage("https://xenserver", "root", password);

    // --- Configure remote syslog ---------------------------------------------------------------
    private static void ConfigureSyslog(string url, string user, string password,
        string syslogServer = "192.0.2.50")
    {
        var session = Connect(url, user, password);
        var host = Pool.get_master(session, Pool.get_all(session)[0].opaque_ref).opaque_ref;

        Console.WriteLine($"{Host.get_name_label(session, host)} logging: {LoggingLabel(session, host)}");

        // Two steps, and the second is the one that is easy to miss: setting the destination only
        // records it, and the host keeps logging locally until the syslog daemon is reconfigured to
        // pick the setting up.
        Host.remove_from_logging(session, host, "syslog_destination");
        Host.add_to_logging(session, host, "syslog_destination", syslogServer);
        Host.syslog_reconfigure(session, host);
        Console.WriteLine($"  now logging to: {Host.get_logging(session, host)["syslog_destination"]}");

        Host.remove_from_logging(session, host, "syslog_destination");
        Host.syslog_reconfigure(session, host);
        Console.WriteLine($"  restored: {LoggingLabel(session, host)}");
        Console.WriteLine("OK: configure-syslog");
        session.logout();
    }

    /// <summary>The host's logging config, or "(local only)" when nothing is configured.</summary>
    private static string LoggingLabel(Session session, string host)
    {
        var logging = Host.get_logging(session, host);
        return logging.Count == 0 ? "(local only)" : string.Join(", ", logging.Select(kv => $"{kv.Key}={kv.Value}"));
    }
    // Run it:
    //   ConfigureSyslog("https://xenserver", "root", password);

    // --- Manage driver variants ----------------------------------------------------------------
    private static void ManageDriverVariants(string url, string user, string password)
    {
        var session = Connect(url, user, password);
        var host = Pool.get_master(session, Pool.get_all(session)[0].opaque_ref).opaque_ref;

        // A driver can ship in several variants — a vendor build alongside the one in the
        // distribution, say. One is SELECTED (what the host will load) and one is ACTIVE (what it has
        // loaded); they differ until the host reboots, which is what makes selecting a variant a
        // scheduled change rather than an immediate one.
        var drivers = Host_driver.get_all_records(session)
            .Where(kv => kv.Value.host.opaque_ref == host)
            .OrderBy(kv => kv.Value.name).ToList();
        Console.WriteLine($"{Host.get_name_label(session, host)} has {drivers.Count} driver(s)");
        foreach (var (_, driver) in drivers.Take(3))
            Console.WriteLine($"  {driver.name,-14} {driver.type,-10} {driver.variants.Count} variant(s), " +
                $"active={VariantName(session, driver.active_variant.opaque_ref)}");

        // Select a variant explicitly. It becomes the selected one immediately; whether it is also
        // active depends on whether the hardware is present and the driver already loaded.
        // Host_driver.select refuses a variant whose hardware isn't present (HOST_DRIVER_NO_HARDWARE),
        // and variant order isn't guaranteed to put the usable one first.
        var (chosenRef, chosen) = drivers[0];
        var variant = chosen.variants
            .FirstOrDefault(v => Driver_variant.get_hardware_present(session, v.opaque_ref))
            ?.opaque_ref ?? chosen.variants[0].opaque_ref;
        Host_driver.select(session, chosenRef.opaque_ref, variant);
        var after = Host_driver.get_record(session, chosenRef.opaque_ref);
        Console.WriteLine($"  {after.name}: selected {VariantName(session, after.selected_variant.opaque_ref)}, " +
            $"active {VariantName(session, after.active_variant.opaque_ref)}");

        Console.WriteLine("OK: manage-driver-variants");
        session.logout();
    }

    /// <summary>A driver variant's name, tolerating the null reference an unloaded driver has.</summary>
    private static string VariantName(Session session, string variantRef) =>
        !string.IsNullOrEmpty(variantRef) && variantRef != "OpaqueRef:NULL"
            ? Driver_variant.get_name(session, variantRef) : "(none)";
    // Run it:
    //   ManageDriverVariants("https://xenserver", "root", password);

    // --- end of workflows ---

    // Maps the <workflow> argument to the matching self-contained method above, merging the
    // dispatcher's own (simulator-friendly) defaults with any key=value overrides supplied on the
    // command line - the equivalent of the Python reference's `_wf(fn, **defaults)` wrapper. In your own
    // code you would call these methods directly (see the "Run it:" line under each) rather than through
    // this dispatcher.
    private static readonly Dictionary<string, Action<string, string, string, Dictionary<string, string>>> Workflows = new()
    {
        ["connect-inventory"] = (u, n, p, ov) => ConnectInventory(u, n, p),
        ["create-vm"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["template_name"] = "Rocky Linux 8", ["new_vm_name"] = "sdk-example-vm" }, ov);
            CreateVm(u, n, p, d["template_name"], d["new_vm_name"]);
        },
        ["vm-lifecycle"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["source_vm"] = "web-01", ["new_vm_name"] = "sdk-example-lifecycle" }, ov);
            VmLifecycle(u, n, p, d["source_vm"], d["new_vm_name"]);
        },
        ["manage-vm-disks"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["template_name"] = "Rocky Linux 8", ["sr_name"] = "Shared NFS",
                                   ["new_vm_name"] = "sdk-example-vm-disks" }, ov);
            ManageVmDisks(u, n, p, d["template_name"], d["sr_name"], d["new_vm_name"]);
        },
        ["dismiss-alerts"] = (u, n, p, ov) => DismissAlerts(u, n, p),
        ["host-power-on"] = (u, n, p, ov) => HostPowerOn(u, n, p),
        ["rotate-pool-secret"] = (u, n, p, ov) => RotatePoolSecret(u, n, p),
        ["change-root-password"] = (u, n, p, ov) => ChangeRootPassword(u, n, p),
        ["manage-certificates"] = (u, n, p, ov) => ManageCertificates(u, n, p),
        ["snapshot-schedule"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01", ["schedule_name"] = "sdk-example-schedule" }, ov);
            SnapshotSchedule(u, n, p, d["vm_name"], d["schedule_name"]);
        },
        ["manage-vm-groups"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01", ["group_name"] = "sdk-example-group" }, ov);
            ManageVmGroups(u, n, p, d["vm_name"], d["group_name"]);
        },
        ["snapshot-revert"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01", ["snapshot_name"] = "sdk-example-snapshot" }, ov);
            SnapshotRevert(u, n, p, d["vm_name"], d["snapshot_name"]);
        },
        ["create-nfs-sr"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["nfs_server"] = "192.0.2.10", ["nfs_path"] = "/export/sdk",
                                   ["sr_name"] = "sdk-example-nfs" }, ov);
            CreateNfsSr(u, n, p, d["nfs_server"], d["nfs_path"], d["sr_name"]);
        },
        ["create-network"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["network_name"] = "sdk-example-net" }, ov);
            CreateNetwork(u, n, p, d["network_name"]);
        },
        ["edit-vm-properties"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01" }, ov);
            EditVmProperties(u, n, p, d["vm_name"]);
        },
        ["events"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01" }, ov);
            Events(u, n, p, d["vm_name"]);
        },
        ["new-vm-wizard"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["template_name"] = "Rocky Linux 8", ["new_vm_name"] = "wizard-vm" }, ov);
            NewVmWizard(u, n, p, d["template_name"], d["new_vm_name"]);
        },
        ["live-migrate"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["source_vm"] = "web-01", ["sr_name"] = "Shared NFS",
                                   ["new_vm_name"] = "sdk-example-migrate" }, ov);
            LiveMigrate(u, n, p, d["source_vm"], d["sr_name"], d["new_vm_name"]);
        },
        ["host-maintenance"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["source_vm"] = "web-01", ["sr_name"] = "Shared NFS",
                                   ["new_vm_name"] = "sdk-example-maint" }, ov);
            HostMaintenance(u, n, p, d["source_vm"], d["sr_name"], d["new_vm_name"]);
        },
        ["configure-ha"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["heartbeat_sr_name"] = "Shared NFS" }, ov);
            ConfigureHa(u, n, p, d["heartbeat_sr_name"]);
        },
        ["copy-vm"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "db-01", ["sr_name"] = "Shared NFS",
                                   ["copy_name"] = "sdk-example-copy" }, ov);
            CopyVm(u, n, p, d["vm_name"], d["sr_name"], d["copy_name"]);
        },
        ["create-vm-with-vgpu"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["template_name"] = "Rocky Linux 8", ["new_vm_name"] = "sdk-example-vgpu-vm" }, ov);
            CreateVmWithVgpu(u, n, p, d["template_name"], d["new_vm_name"]);
        },
        ["tags-and-folders"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01" }, ov);
            TagsAndFolders(u, n, p, d["vm_name"]);
        },
        ["configure-updates"] = (u, n, p, ov) => ConfigureUpdates(u, n, p),
        ["clone-vm"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "db-01", ["clone_name"] = "sdk-example-clone" }, ov);
            CloneVm(u, n, p, d["vm_name"], d["clone_name"]);
        },
        ["delete-vm"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["template_name"] = "Rocky Linux 8", ["new_vm_name"] = "sdk-example-delete" }, ov);
            DeleteVm(u, n, p, d["template_name"], d["new_vm_name"]);
        },
        ["storage-migrate"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["source_vm"] = "web-01", ["new_vm_name"] = "sdk-example-storagemigrate" }, ov);
            StorageMigrate(u, n, p, d["source_vm"], d["new_vm_name"]);
        },
        ["apply-update"] = (u, n, p, ov) => ApplyUpdate(u, n, p),
        ["checkpoint-vm"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["source_vm"] = "web-01", ["new_vm_name"] = "sdk-example-checkpoint" }, ov);
            CheckpointVm(u, n, p, d["source_vm"], d["new_vm_name"]);
        },
        ["attach-disk"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["template_name"] = "Rocky Linux 8", ["sr_name"] = "Shared NFS",
                                   ["new_vm_name"] = "sdk-example-attachdisk" }, ov);
            AttachDisk(u, n, p, d["template_name"], d["sr_name"], d["new_vm_name"]);
        },
        ["wait-for-task"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["template_name"] = "Rocky Linux 8", ["new_vm_name"] = "sdk-example-asynctask" }, ov);
            WaitForTask(u, n, p, d["template_name"], d["new_vm_name"]);
        },
        ["error-handling"] = (u, n, p, ov) => ErrorHandling(u, n, p),
        ["list-templates"] = (u, n, p, ov) => ListTemplates(u, n, p),
        ["custom-fields"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01" }, ov);
            CustomFields(u, n, p, d["vm_name"]);
        },
        ["gpu-inventory"] = (u, n, p, ov) => GpuInventory(u, n, p),
        ["read-metrics"] = (u, n, p, ov) => ReadMetrics(u, n, p),
        ["rename-object"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01" }, ov);
            RenameObject(u, n, p, d["vm_name"]);
        },
        ["vm-boot-config"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["template_name"] = "Rocky Linux 8", ["new_vm_name"] = "sdk-example-boot" }, ov);
            VmBootConfig(u, n, p, d["template_name"], d["new_vm_name"]);
        },
        ["host-info"] = (u, n, p, ov) => HostInfo(u, n, p),
        ["list-roles"] = (u, n, p, ov) => ListRoles(u, n, p),
        ["pool-properties"] = (u, n, p, ov) => PoolProperties(u, n, p),
        ["sr-usage"] = (u, n, p, ov) => SrUsage(u, n, p),
        ["manage-vif"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["template_name"] = "Rocky Linux 8", ["new_vm_name"] = "sdk-example-vif" }, ov);
            ManageVif(u, n, p, d["template_name"], d["new_vm_name"]);
        },
        ["list-networks"] = (u, n, p, ov) => ListNetworks(u, n, p),
        ["vbd-inventory"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "db-01" }, ov);
            VbdInventory(u, n, p, d["vm_name"]);
        },
        ["pool-tags"] = (u, n, p, ov) => PoolTags(u, n, p),
        ["convert-to-template"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["template_name"] = "Rocky Linux 8", ["new_vm_name"] = "sdk-example-totemplate" }, ov);
            ConvertToTemplate(u, n, p, d["template_name"], d["new_vm_name"]);
        },
        ["find-by-uuid"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01" }, ov);
            FindByUuid(u, n, p, d["vm_name"]);
        },
        ["rolling-pool-update"] = (u, n, p, ov) => RollingPoolUpdate(u, n, p),
        ["pvs-accelerator"] = (u, n, p, ov) => PvsAccelerator(u, n, p),
        ["configure-pvs-accelerator"] = (u, n, p, ov) => ConfigurePvsAccelerator(u, n, p),
        ["manage-ssh-access"] = (u, n, p, ov) => ManageSshAccess(u, n, p),
        ["manage-vtpm"] = (u, n, p, ov) => ManageVtpm(u, n, p),
        ["export-import-vm"] = (u, n, p, ov) => ExportImportVm(u, n, p),
        ["configure-dynamic-memory"] = (u, n, p, ov) => ConfigureDynamicMemory(u, n, p),
        ["manage-vm-media"] = (u, n, p, ov) => ManageVmMedia(u, n, p),
        ["backup-host-config"] = (u, n, p, ov) => BackupHostConfig(u, n, p),
        ["manage-sr-lifecycle"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["nfs_server"] = "192.0.2.10", ["nfs_path"] = "/export/spare" }, ov);
            ManageSrLifecycle(u, n, p, d["nfs_server"], d["nfs_path"]);
        },
        ["set-default-sr"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["nfs_server"] = "192.0.2.10", ["nfs_path"] = "/export/spare" }, ov);
            SetDefaultSr(u, n, p, d["nfs_server"], d["nfs_path"]);
        },
        ["server-status-report"] = (u, n, p, ov) => ServerStatusReport(u, n, p),
        ["disaster-recovery"] = (u, n, p, ov) =>
            DisasterRecovery(u, n, p, ov.TryGetValue("dr_url", out var drUrl) ? drUrl : null),
        ["manage-secureboot-certificates"] = (u, n, p, ov) => ManageSecurebootCertificates(u, n, p),
        ["restart-host"] = (u, n, p, ov) => RestartHost(u, n, p),
        ["manage-crash-dumps"] = (u, n, p, ov) => ManageCrashDumps(u, n, p),
        ["vm-from-snapshot"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "db-01" }, ov);
            VmFromSnapshot(u, n, p, d["vm_name"]);
        },
        ["attach-existing-disk"] = (u, n, p, ov) => AttachExistingDisk(u, n, p),
        ["changed-block-tracking"] = (u, n, p, ov) => ChangedBlockTracking(u, n, p),
        ["control-domain-memory"] = (u, n, p, ov) => ControlDomainMemory(u, n, p),
        ["rrd-metrics"] = (u, n, p, ov) => RrdMetrics(u, n, p),
        ["reclaim-space"] = (u, n, p, ov) => ReclaimSpace(u, n, p),
        ["vm-ip-address"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["timeout"] = "60", ["interval"] = "2" }, ov);
            VmIpAddress(u, n, p, int.Parse(d["timeout"]), int.Parse(d["interval"]));
        },
        ["manage-ad-users"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["domain"] = "", ["admin_user"] = "alice", ["admin_password"] = "Password1",
                                   ["new_user"] = "alice" }, ov);
            ManageAdUsers(u, n, p, d["domain"], d["admin_user"], d["admin_password"], d["new_user"]);
        },
        ["create-iscsi-sr"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["target"] = "192.0.2.30", ["sr_name"] = "sdk-example-iscsi" }, ov);
            int? port = ov.TryGetValue("port", out var portStr) ? int.Parse(portStr) : (int?)null;
            var chapUser = ov.TryGetValue("chap_user", out var cu) ? cu : null;
            var chapPassword = ov.TryGetValue("chap_password", out var cp) ? cp : null;
            CreateIscsiSr(u, n, p, d["target"], port, chapUser, chapPassword,
                ov.GetValueOrDefault("target_iqn"), d["sr_name"]);
        },
        ["create-smb-sr"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["server"] = "192.0.2.40", ["share"] = "/vmstore",
                                   ["smb_username"] = "Administrator", ["smb_password"] = "Password1",
                                   ["sr_name"] = "sdk-example-smb" }, ov);
            CreateSmbSr(u, n, p, d["server"], d["share"], d["smb_username"], d["smb_password"], d["sr_name"]);
        },
        ["create-hba-sr"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["sr_name"] = "sdk-example-hba" }, ov);
            CreateHbaSr(u, n, p, d["sr_name"]);
        },
        ["create-iso-sr"] = (u, n, p, ov) => CreateIsoSr(u, n, p),
        ["configure-nrpe"] = (u, n, p, ov) => ConfigureNrpe(u, n, p),
        ["configure-snmp"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["trap_destination"] = "192.0.2.50" }, ov);
            ConfigureSnmp(u, n, p, d["trap_destination"]);
        },
        ["configure-clustering"] = (u, n, p, ov) => ConfigureClustering(u, n, p),
        ["manage-pool-membership"] = (u, n, p, ov) => ManagePoolMembership(u, n, p),
        ["create-bond"] = (u, n, p, ov) => CreateBond(u, n, p),
        ["manage-vapp"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01" }, ov);
            ManageVapp(u, n, p, d["vm_name"]);
        },
        ["attach-usb-device"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01" }, ov);
            AttachUsbDevice(u, n, p, d["vm_name"]);
        },
        ["wlb-recommendations"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["vm_name"] = "web-01", ["wlb_host_port"] = "wlb.example:8012",
                                   ["wlb_username"] = "wlbuser", ["wlb_password"] = "wlbpass" }, ov);
            WlbRecommendations(u, n, p, d["vm_name"], d["wlb_host_port"], d["wlb_username"], d["wlb_password"]);
        },
        ["configure-pool-options"] = (u, n, p, ov) => ConfigurePoolOptions(u, n, p),
        ["configure-console-access"] = (u, n, p, ov) => ConfigureConsoleAccess(u, n, p),
        ["configure-host-storage"] = (u, n, p, ov) => ConfigureHostStorage(u, n, p),
        ["configure-syslog"] = (u, n, p, ov) =>
        {
            var d = Merge(new() { ["syslog_server"] = "192.0.2.50" }, ov);
            ConfigureSyslog(u, n, p, d["syslog_server"]);
        },
        ["manage-driver-variants"] = (u, n, p, ov) => ManageDriverVariants(u, n, p),
    };

    private static int Main(string[] args)
    {
        // cross-pool-copy-vm is the one workflow that spans two pools, so it takes an extra 5th
        // argument: the destination pool URL. Every other workflow uses the uniform 4-arg contract.
        if (args.Length >= 1 && args[0] == "cross-pool-copy-vm")
        {
            if (args.Length != 5)
            {
                Console.Error.WriteLine(
                    "usage: XenSdkExamples.CSharp cross-pool-copy-vm <sourceUrl> <user> <password> <destUrl>");
                return 2;
            }
            CrossPoolCopyVm(args[1], args[2], args[3], args[4]);
            return 0;
        }

        if (args.Length < 4 || !Workflows.ContainsKey(args[0]))
        {
            Console.Error.WriteLine(
                $"usage: XenSdkExamples.CSharp <{string.Join("|", Workflows.Keys)}|cross-pool-copy-vm> " +
                "<url> <user> <password> [key=value ...]");
            return 2;
        }

        var (workflow, url, user, password) = (args[0], args[1], args[2], args[3]);
        var overrides = new Dictionary<string, string>();
        foreach (var arg in args.Skip(4))
        {
            var idx = arg.IndexOf('=');
            if (idx < 0)
            {
                Console.Error.WriteLine($"extra arguments must be key=value (got '{arg}')");
                return 2;
            }
            overrides[arg.Substring(0, idx)] = arg.Substring(idx + 1);
        }
        Workflows[workflow](url, user, password, overrides);
        return 0;
    }
}
