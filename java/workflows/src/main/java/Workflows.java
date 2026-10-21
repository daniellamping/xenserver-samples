// XenServer Java SDK - real-world workflow examples.
//
// Each example mirrors a task you would perform in XenCenter, driven through the XenServer
// Management API (XenAPI). The Java binding speaks JSON-RPC (Apache HttpClient 5 + Jackson).
//
// Every example is self-contained: it takes the connection details (and any object it acts on,
// looked up by name) as parameters, opens its own connection and logs out when done - so you can copy
// one out and run it on its own; see the "Run it:" line under each. The dispatcher in main() is only
// what lets this one file run any of them from the command line.
//
// Usage:
//   java -cp <classpath> Workflows <workflow> <url> <username> <password>
//
//   <workflow>  any workflow id from the dispatcher (see also README.md)

import com.xensource.xenapi.Connection;
import com.xensource.xenapi.VTPM;
import com.xensource.xenapi.EventBatch;
import com.xensource.xenapi.Event;
import com.xensource.xenapi.GPUGroup;
import com.xensource.xenapi.Host;
import com.xensource.xenapi.HostCrashdump;
import com.xensource.xenapi.HostMetrics;
import com.xensource.xenapi.JsonRpcClient;
import com.xensource.xenapi.Network;
import com.xensource.xenapi.Pool;
import com.xensource.xenapi.Repository;
import com.xensource.xenapi.Role;
import com.xensource.xenapi.Auth;
import com.xensource.xenapi.PBD;
import com.xensource.xenapi.SM;
import com.xensource.xenapi.SR;
import com.xensource.xenapi.Subject;
import com.xensource.xenapi.Session;
import com.xensource.xenapi.Task;
import com.xensource.xenapi.Types;
import com.xensource.xenapi.VBD;
import com.xensource.xenapi.Message;
import com.xensource.xenapi.Certificate;
import com.xensource.xenapi.VMGroup;
import com.xensource.xenapi.VMSS;
import com.xensource.xenapi.VDI;
import com.xensource.xenapi.VGPU;
import com.xensource.xenapi.VGPUType;
import com.xensource.xenapi.VIF;
import com.xensource.xenapi.VM;
import com.xensource.xenapi.VMMetrics;
import com.xensource.xenapi.PVSSite;
import com.xensource.xenapi.PVSCacheStorage;
import com.xensource.xenapi.PVSServer;
import com.xensource.xenapi.PVSProxy;
import com.xensource.xenapi.VMAppliance;
import com.xensource.xenapi.PUSB;
import com.xensource.xenapi.VUSB;
import com.xensource.xenapi.Cluster;
import com.xensource.xenapi.ClusterHost;
import com.xensource.xenapi.PIF;
import com.xensource.xenapi.Bond;
import com.xensource.xenapi.HostDriver;
import com.xensource.xenapi.DriverVariant;
import org.apache.hc.client5.http.classic.methods.HttpGet;
import org.apache.hc.client5.http.classic.methods.HttpPut;
import org.apache.hc.core5.http.io.entity.EntityUtils;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.JsonNode;

import org.apache.hc.client5.http.impl.classic.CloseableHttpClient;
import org.apache.hc.client5.http.impl.classic.HttpClients;
import org.apache.hc.client5.http.impl.io.PoolingHttpClientConnectionManager;
import org.apache.hc.client5.http.impl.io.PoolingHttpClientConnectionManagerBuilder;
import org.apache.hc.client5.http.ssl.NoopHostnameVerifier;
import org.apache.hc.client5.http.ssl.SSLConnectionSocketFactory;
import org.apache.hc.core5.ssl.SSLContexts;

import javax.net.ssl.SSLContext;
import java.net.URL;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.ArrayList;
import java.util.List;

public class Workflows {

    // --- connect ---
    private static Connection connect(String url, String user, String password) throws Exception {
        CloseableHttpClient http = trustingHttpClient();
        try {
            return login(http, url, user, password);
        } catch (Types.HostIsSlave e) {
            // A pool member names the coordinator's address; reconnect there (assuming the coordinator
            // is up), exactly as XenCenter does when you add a member server.
            return login(http, "https://" + e.masterIPAddress, user, password);
        }
    }

    // An HTTP client that trusts the host's self-signed certificate. (Apache HttpClient 5 uses its own
    // SSL context, so we configure it here rather than relying on JVM-wide defaults.)
    private static CloseableHttpClient trustingHttpClient() throws Exception {
        SSLContext ssl = SSLContexts.custom()
            .loadTrustMaterial((chain, authType) -> true)
            .build();
        SSLConnectionSocketFactory sslsf = new SSLConnectionSocketFactory(ssl, NoopHostnameVerifier.INSTANCE);
        PoolingHttpClientConnectionManager cm = PoolingHttpClientConnectionManagerBuilder.create()
            .setSSLSocketFactory(sslsf)
            .build();
        return HttpClients.custom().setConnectionManager(cm).build();
    }

    private static Connection login(CloseableHttpClient http, String url, String user, String password) throws Exception {
        Connection conn = new Connection(new JsonRpcClient(http, new URL(url + "/jsonrpc")));
        Session.loginWithPassword(conn, user, password, "1.0", "sdk-examples");
        return conn;
    }

    // Look up a template VM by its exact name (rather than picking an arbitrary one).
    private static VM templateByName(Connection conn, String name) throws Exception {
        for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet())
            if (e.getValue().isATemplate && name.equals(e.getValue().nameLabel)) return e.getKey();
        throw new RuntimeException("no template named '" + name + "' was found");
    }

    // Look up a guest VM (not a template, control domain or snapshot) by its exact name.
    private static VM vmByName(Connection conn, String name) throws Exception {
        for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
            VM.Record r = e.getValue();
            if (!r.isATemplate && !r.isControlDomain && !r.isASnapshot && name.equals(r.nameLabel))
                return e.getKey();
        }
        throw new RuntimeException("no VM named '" + name + "' was found");
    }

    // Look up an SR by its exact name (optionally requiring it to be shared).
    private static SR srByName(Connection conn, String name, boolean shared) throws Exception {
        for (Map.Entry<SR, SR.Record> e : SR.getAllRecords(conn).entrySet())
            if (name.equals(e.getValue().nameLabel) && (!shared || e.getValue().shared)) return e.getKey();
        throw new RuntimeException("no " + (shared ? "shared " : "") + "SR named '" + name + "' was found");
    }

    // The VDIs backing a VM's disk VBDs (used to clean up a clone/copy/created VM's disks). VM.destroy
    // leaves VDIs behind, so callers destroy these explicitly afterward.
    private static Set<VDI> diskVdis(Connection conn, VM vm) throws Exception {
        Set<VDI> vdis = new LinkedHashSet<>();
        for (VBD vbd : vm.getVBDs(conn))
            if (vbd.getType(conn) == Types.VbdType.DISK) vdis.add(vbd.getVDI(conn));
        return vdis;
    }

    // --- 1. Connect & inventory --------------------------------------------------------
    private static void connectInventory(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        Pool.Record pool = Pool.getAllRecords(conn).values().iterator().next();
        System.out.println("Connected to pool: " + pool.nameLabel);

        Map<Host, Host.Record> hosts = Host.getAllRecords(conn);
        System.out.println("Hosts (" + hosts.size() + "):");
        for (Host.Record h : hosts.values())
            System.out.println("  - " + h.nameLabel + " (" + h.address + ")");

        int count = 0;
        System.out.println("VMs:");
        for (VM.Record v : VM.getAllRecords(conn).values()) {
            if (!v.isATemplate && !v.isControlDomain) {
                count++;
                System.out.println("  - " + v.nameLabel + " [" + v.powerState + "]");
            }
        }
        System.out.println("VMs (" + count + ")");

        System.out.println("OK: connect-inventory");
        Session.logout(conn);
    }
    // Run it:
    //   connectInventory("https://xenserver", "root", password);

    // --- 2. Create a VM from a template ------------------------------------------------
    private static void createVm(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        VM template = templateByName(conn, templateName);
        System.out.println("Using template: " + template.getNameLabel(conn));

        VM vm = template.createClone(conn, newVmName);
        System.out.println("Cloned new VM: " + vm.getUuid(conn));

        vm.provision(conn);
        System.out.println("Provisioned. is_a_template = " + vm.getIsATemplate(conn));

        vm.destroy(conn);
        System.out.println("Cleaned up the example VM.");

        System.out.println("OK: create-vm");
        Session.logout(conn);
    }
    // Run it:
    //   createVm("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-vm");

    // --- 3. VM power lifecycle ---------------------------------------------------------
    private static void vmLifecycle(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        // Power operations are destructive, so work on a throwaway VM cloned from the template.
        VM vm = templateByName(conn, templateName).createClone(conn, newVmName);
        vm.provision(conn);

        System.out.println("Initial power state: " + vm.getPowerState(conn));
        vm.start(conn, false, true);
        System.out.println("After start:    " + vm.getPowerState(conn));

        // The emulated hardware (the device model) can be restarted under a running guest without
        // rebooting it - what you reach for when the VM's virtual devices misbehave.
        vm.restartDeviceModels(conn);
        System.out.println("Device models restarted; still " + vm.getPowerState(conn));

        vm.suspend(conn);
        System.out.println("After suspend:  " + vm.getPowerState(conn));
        vm.resume(conn, false, true);
        System.out.println("After resume:   " + vm.getPowerState(conn));
        vm.cleanShutdown(conn);
        System.out.println("After shutdown: " + vm.getPowerState(conn));

        vm.destroy(conn);
        System.out.println("OK: vm-lifecycle");
        Session.logout(conn);
    }
    // Run it:
    //   vmLifecycle("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-lifecycle");

    // --- 4. Manage VM disks: Deactivate / Resize / Activate --------------------------
    private static void manageVmDisks(String url, String user, String password, String vmName)
            throws Exception {
        Connection conn = connect(url, user, password);
        VM vm = vmByName(conn, vmName);

        // The VM's first real disk (a CD drive is a VBD too, hence the type filter).
        VBD vbd = null;
        for (VBD candidate : vm.getVBDs(conn)) {
            if (candidate.getType(conn) == Types.VbdType.DISK) { vbd = candidate; break; }
        }
        VDI vdi = vbd.getVDI(conn);
        System.out.println("Disk attached:  " + vbd.getCurrentlyAttached(conn));

        // Deactivate = VBD.unplug. The disk stays with the VM; it is just no longer live.
        vbd.unplug(conn);
        System.out.println("After unplug:   " + vbd.getCurrentlyAttached(conn));

        Long size = vdi.getVirtualSize(conn);
        vdi.resize(conn, size * 2);
        System.out.println("Resized:        " + size + " -> " + vdi.getVirtualSize(conn) + " bytes");

        vbd.plug(conn);
        System.out.println("After plug:     " + vbd.getCurrentlyAttached(conn));

        // Growing a disk that is attached and live is a DIFFERENT call, not a flag on the same one:
        // resizeOnline tells the storage layer the guest is using the disk while it grows.
        long grown = vdi.getVirtualSize(conn) + (1024L * 1024 * 1024);
        vdi.resizeOnline(conn, grown);
        System.out.println("Grown online:   " + vdi.getVirtualSize(conn) + " bytes");
        System.out.println("OK: manage-vm-disks");
        Session.logout(conn);
    }

    // --- Raise and dismiss alerts ----------------------------------------------------
    private static void dismissAlerts(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        Map<Message, Message.Record> messages = Message.getAllRecords(conn);
        System.out.println("Alerts:         " + messages.size());

        if (messages.isEmpty()) {
            System.out.println("No alerts to dismiss.");
        } else {
            Map.Entry<Message, Message.Record> first = messages.entrySet().iterator().next();
            System.out.println("Dismissing:     " + first.getValue().name
                    + " (priority " + first.getValue().priority + ")");
            first.getKey().destroy(conn);
            System.out.println("Alerts left:    " + Message.getAllRecords(conn).size());
        }
        System.out.println("OK: dismiss-alerts");
        Session.logout(conn);
    }

    // --- Configure host power on -----------------------------------------------------
    private static void hostPowerOn(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        Host host = Host.getAll(conn).iterator().next();

        // Mode and config travel together: the config carries the credentials the mode needs.
        Map<String, String> cfg = new HashMap<>();
        cfg.put("power_on_ip", "192.0.2.9");
        cfg.put("power_on_user", "poweradmin");
        host.setPowerOnMode(conn, "iLO", cfg);
        System.out.println("Power-on mode:  " + host.getPowerOnMode(conn));
        for (Map.Entry<String, String> e : new TreeMap<>(host.getPowerOnConfig(conn)).entrySet()) {
            System.out.println("  " + e.getKey() + " = " + e.getValue());
        }

        host.setPowerOnMode(conn, "", new HashMap<String, String>());
        System.out.println("OK: host-power-on");
        Session.logout(conn);
    }

    // --- Rotate the pool secret ------------------------------------------------------
    private static void rotatePoolSecret(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        Pool pool = Pool.getAll(conn).iterator().next();
        System.out.println("Pool:           " + pool.getNameLabel(conn));

        // A pool-wide operation; existing sessions survive it.
        Pool.rotateSecret(conn);
        System.out.println("Rotated. Still connected: " + (Pool.getAll(conn).size() == 1));
        System.out.println("OK: rotate-pool-secret");
        Session.logout(conn);
    }

    // --- Change the root password ----------------------------------------------------
    private static void changeRootPassword(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        final String temporary = "sdk-example-temp-password";

        // changePassword takes the OLD password as well as the new one, even though you are already
        // authenticated.
        Session.changePassword(conn, password, temporary);
        System.out.println("Password changed.");

        // The existing session stays valid afterwards - only NEW connections need the new password.
        System.out.println("Session still usable: " + (Pool.getAll(conn).size() == 1));

        // Supplying the wrong current password is the failure worth handling.
        try {
            Session.changePassword(conn, "definitely-not-it", "irrelevant");
            System.out.println("unexpected: the wrong old password was accepted");
        } catch (Types.XenAPIException e) {
            System.out.println("Wrong old password rejected: " + e.shortDescription);
        }

        Session.changePassword(conn, temporary, password);
        System.out.println("Password restored.");
        System.out.println("OK: change-root-password");
        Session.logout(conn);
    }

    // --- Manage TLS certificates -----------------------------------------------------
    private static void manageCertificates(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        Host host = Host.getAll(conn).iterator().next();

        System.out.println("Certificates:   " + Certificate.getAll(conn).size());

        // A CA certificate is pool-wide; a server certificate belongs to one host.
        Pool.installCaCertificate(conn, "sdk-example-ca",
                "-----BEGIN CERTIFICATE-----sdk-example-----END CERTIFICATE-----");
        System.out.println("After CA add:   " + Certificate.getAll(conn).size());

        host.resetServerCertificate(conn);
        System.out.println("Host certificate reset (a fresh self-signed identity).");

        Pool.uninstallCaCertificate(conn, "sdk-example-ca", false);
        System.out.println("After CA remove:" + Certificate.getAll(conn).size());

        // Separately from which certificates exist: whether the pool actually CHECKS the ones its
        // members present to each other. Turning it on is a one-way door from here - there is no
        // matching disable, because a pool that could be talked out of verifying would not be
        // verifying - so the call is idempotent and safe to repeat.
        Pool pool = Pool.getAll(conn).iterator().next();
        System.out.println("TLS verification: " + pool.getTlsVerificationEnabled(conn));
        Pool.enableTlsVerification(conn);
        System.out.println("  after enabling: " + pool.getTlsVerificationEnabled(conn));
        System.out.println("OK: manage-certificates");
        Session.logout(conn);
    }

    // --- Snapshot schedule -----------------------------------------------------------
    private static void snapshotSchedule(String url, String user, String password,
            String vmName, String scheduleName) throws Exception {
        Connection conn = connect(url, user, password);
        VM vm = vmByName(conn, vmName);

        // retainedSnapshots is the interesting field: the schedule prunes to it every time it runs.
        VMSS.Record spec = new VMSS.Record();
        spec.nameLabel = scheduleName;
        spec.nameDescription = "Scheduled snapshots created by the SDK example";
        spec.enabled = true;
        spec.type = Types.VmssType.SNAPSHOT;
        spec.frequency = Types.VmssFrequency.DAILY;
        spec.retainedSnapshots = 2L;
        Map<String, String> when = new HashMap<>();
        when.put("hour", "2");
        when.put("min", "0");
        spec.schedule = when;
        VMSS vmss = VMSS.create(conn, spec);
        System.out.println("Created schedule: " + vmss.getUuid(conn));

        vm.setSnapshotSchedule(conn, vmss);
        System.out.println("Members:          " + vmss.getVMs(conn).size());

        // Run it three times against a retention of two: the oldest is pruned away.
        for (int i = 0; i < 3; i++) {
            vmss.snapshotNow(conn);
        }
        System.out.println("Snapshots kept:   " + vm.getSnapshots(conn).size() + " (retention 2)");

        vmss.destroy(conn);
        System.out.println("OK: snapshot-schedule");
        Session.logout(conn);
    }

    // --- Manage VM groups ------------------------------------------------------------
    private static void manageVmGroups(String url, String user, String password,
            String vmName, String groupName) throws Exception {
        Connection conn = connect(url, user, password);
        VM vm = vmByName(conn, vmName);

        // anti_affinity asks the pool to keep the group's members on different hosts.
        VMGroup.Record spec = new VMGroup.Record();
        spec.nameLabel = groupName;
        spec.nameDescription = "Anti-affinity group created by the SDK example";
        spec.placement = Types.PlacementPolicy.ANTI_AFFINITY;
        VMGroup group = VMGroup.create(conn, spec);
        System.out.println("Created group:  " + group.getUuid(conn));

        // Membership is written from the VM side...
        Set<VMGroup> groups = new LinkedHashSet<>();
        groups.add(group);
        vm.setGroups(conn, groups);

        // ...and read back from the group side, which is the half that is easy to get wrong.
        Set<VM> members = group.getVMs(conn);
        System.out.println("Group members:  " + members.size());
        for (VM m : members) {
            System.out.println("  " + m.getNameLabel(conn));
        }

        vm.setGroups(conn, new LinkedHashSet<VMGroup>());
        System.out.println("After removal:  " + group.getVMs(conn).size() + " member(s)");

        group.destroy(conn);
        System.out.println("OK: manage-vm-groups");
        Session.logout(conn);
    }

    // --- Snapshot & revert -----------------------------------------------------------
    private static void snapshotRevert(String url, String user, String password,
            String vmName, String snapshotName) throws Exception {
        Connection conn = connect(url, user, password);
        VM vm = vmByName(conn, vmName);
        System.out.println("Snapshotting VM: " + vm.getNameLabel(conn));

        VM snap = vm.snapshot(conn, snapshotName);
        System.out.println("Created snapshot: " + snap.getUuid(conn));

        snap.revert(conn);
        System.out.println("Reverted VM to the snapshot.");

        // A client shows a thumbnail of what was on screen when the snapshot was taken. It is an HTTP
        // transfer alongside the API, not an API call, so the session id travels in the query string.
        HttpGet thumbGet = new HttpGet(url + "/vncsnapshot?session_id=" + conn.getSessionReference()
                + "&ref=" + snap.toWireString());
        try (CloseableHttpClient http = trustingHttpClient()) {
            byte[] png = http.execute(thumbGet, resp -> EntityUtils.toByteArray(resp.getEntity()));
            System.out.println("Thumbnail:      " + png.length + " bytes of PNG");
        }

        // A snapshot is itself a (special) VM record; destroy it to clean up.
        snap.destroy(conn);
        System.out.println("OK: snapshot-revert");
        Session.logout(conn);
    }
    // Run it:
    //   snapshotRevert("https://xenserver", "root", password, "web-01", "sdk-example-snapshot");

    // --- 5. Create an NFS storage repository -------------------------------------------
    private static void createNfsSr(String url, String user, String password,
            String nfsServer, String nfsPath, String srName) throws Exception {
        Connection conn = connect(url, user, password);
        Host host = Host.getAllRecords(conn).keySet().iterator().next();
        Map<String, String> deviceConfig = new java.util.HashMap<>();
        deviceConfig.put("server", nfsServer);
        deviceConfig.put("serverpath", nfsPath);
        deviceConfig.put("nfsversion", "3");

        SR sr = SR.create(conn, host, deviceConfig, 0L,
            srName, "NFS SR created by the SDK example",
            "nfs", "user", true, new java.util.HashMap<>());
        System.out.println("Created SR: " + sr.getUuid(conn));

        sr.forget(conn);
        System.out.println("OK: create-nfs-sr");
        Session.logout(conn);
    }
    // Run it:
    //   createNfsSr("https://xenserver", "root", password, "192.0.2.10", "/export/sdk", "sdk-example-nfs");

    // --- 6. Create a network -----------------------------------------------------------
    private static void createNetwork(String url, String user, String password,
            String networkName) throws Exception {
        Connection conn = connect(url, user, password);
        Network.Record record = new Network.Record();
        record.nameLabel = networkName;
        record.nameDescription = "Internal network created by the SDK example";
        record.MTU = 1500L;
        record.otherConfig = new java.util.HashMap<>();

        Network net = Network.create(conn, record);
        System.out.println("Created network: " + net.getUuid(conn));

        // Raise the MTU to use jumbo frames. Every NIC and switch along the path has to agree, so this
        // is a property of the network rather than of any one interface on it.
        net.setMTU(conn, 9000L);
        System.out.println("MTU now:         " + net.getMTU(conn));

        net.destroy(conn);
        System.out.println("OK: create-network");
        Session.logout(conn);
    }
    // Run it:
    //   createNetwork("https://xenserver", "root", password, "sdk-example-net");

    // --- 7. Edit VM properties ---------------------------------------------------------
    private static void editVmProperties(String url, String user, String password,
            String vmName) throws Exception {
        Connection conn = connect(url, user, password);
        VM vm = vmByName(conn, vmName);

        String originalDesc = vm.getNameDescription(conn);
        vm.setNameDescription(conn, "Edited by the SDK example");
        vm.addToOtherConfig(conn, "sdk_example", "true");
        System.out.println("New description: " + vm.getNameDescription(conn));
        System.out.println("other_config[sdk_example] = " + vm.getOtherConfig(conn).get("sdk_example"));

        vm.setNameDescription(conn, originalDesc);
        vm.removeFromOtherConfig(conn, "sdk_example");
        System.out.println("OK: edit-vm-properties");
        Session.logout(conn);
    }
    // Run it:
    //   editVmProperties("https://xenserver", "root", password, "web-01");

    // --- 8. Event monitoring -----------------------------------------------------------
    private static void events(String url, String user, String password, String vmName) throws Exception {
        Connection conn = connect(url, user, password);
        Set<String> classes = new LinkedHashSet<>();
        classes.add("VM");

        EventBatch batch = Event.from(conn, classes, "", 1.0);
        String token = batch.token;
        System.out.println("Established event token after initial snapshot.");

        VM vm = vmByName(conn, vmName);
        vm.setNameDescription(conn, "changed-to-trigger-event");

        batch = Event.from(conn, classes, token, 5.0);
        System.out.println("Received " + batch.events.size() + " event(s) after the change.");
        int shown = 0;
        for (Event.Record ev : batch.events) {
            if (shown++ >= 3) break;
            System.out.println("  - " + ev.operation + " " + ev.clazz);
        }

        System.out.println("OK: events");
        Session.logout(conn);
    }
    // Run it:
    //   events("https://xenserver", "root", password, "web-01");

    // --- 9. New VM wizard (full) -------------------------------------------------------
    private static void newVmWizard(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        final long GiB = 1024L * 1024 * 1024, MiB = 1024L * 1024;

        Connection conn = connect(url, user, password);
        // Page 1 - Template.
        VM template = templateByName(conn, templateName);
        System.out.println("Template:      " + template.getNameLabel(conn));

        // Page 2 - Name and description.
        VM vm = template.createClone(conn, newVmName);
        vm.setNameDescription(conn, "Created by the full New VM wizard example");
        vm.setIsATemplate(conn, false);
        System.out.println("Created VM:    " + vm.getUuid(conn));

        // Page 3 - Installation media (a network install repository).
        vm.addToOtherConfig(conn, "install-repository", "http://mirror.example.com/rocky/9/os/x86_64");
        System.out.println("Install media: network repository");

        // Page 4 - Home server (affinity).
        Map.Entry<Host, Host.Record> he = Host.getAllRecords(conn).entrySet().iterator().next();
        vm.setAffinity(conn, he.getKey());
        System.out.println("Home server:   " + he.getValue().nameLabel);

        // Page 5 - CPU & Memory.
        vm.setVCPUsMax(conn, 2L);
        vm.setVCPUsAtStartup(conn, 2L);
        vm.setMemoryLimits(conn, 512 * MiB, 2 * GiB, 2 * GiB, 2 * GiB);
        System.out.println("CPU/memory:    2 vCPUs, 2 GiB");

        // Page 6 - Storage: add a disk on a (non-ISO) SR.
        SR sr = null;
        String srName = null;
        for (Map.Entry<SR, SR.Record> e : SR.getAllRecords(conn).entrySet()) {
            if (!"iso".equals(e.getValue().contentType)
                    && !"iso".equals(e.getValue().type) && !"udev".equals(e.getValue().type)) {
                sr = e.getKey();
                srName = e.getValue().nameLabel;
                break;
            }
        }
        VDI.Record vdiRec = new VDI.Record();
        vdiRec.nameLabel = newVmName + " disk 0";
        vdiRec.nameDescription = "System disk created by the wizard example";
        vdiRec.SR = sr;
        vdiRec.virtualSize = 24 * GiB;
        vdiRec.type = Types.VdiType.SYSTEM;
        vdiRec.sharable = false;
        vdiRec.readOnly = false;
        vdiRec.otherConfig = new java.util.HashMap<>();
        VDI vdi = VDI.create(conn, vdiRec);

        VBD.Record vbdRec = new VBD.Record();
        vbdRec.VM = vm;
        vbdRec.VDI = vdi;
        vbdRec.userdevice = vm.getAllowedVBDDevices(conn).iterator().next();
        vbdRec.bootable = true;
        vbdRec.mode = Types.VbdMode.RW;
        vbdRec.type = Types.VbdType.DISK;
        vbdRec.empty = false;
        vbdRec.otherConfig = new java.util.HashMap<>();
        vbdRec.qosAlgorithmType = "";
        vbdRec.qosAlgorithmParams = new java.util.HashMap<>();
        VBD.create(conn, vbdRec);
        System.out.println("Storage:       24 GiB disk on " + srName);

        // Page 7 - Networking: attach a VIF to a network.
        Map.Entry<Network, Network.Record> ne = Network.getAllRecords(conn).entrySet().iterator().next();
        VIF.Record vifRec = new VIF.Record();
        vifRec.VM = vm;
        vifRec.network = ne.getKey();
        vifRec.device = vm.getAllowedVIFDevices(conn).iterator().next();
        vifRec.MAC = "";
        vifRec.MTU = 1500L;
        vifRec.otherConfig = new java.util.HashMap<>();
        vifRec.qosAlgorithmType = "";
        vifRec.qosAlgorithmParams = new java.util.HashMap<>();
        VIF.create(conn, vifRec);
        System.out.println("Networking:    NIC on " + ne.getValue().nameLabel);

        // Page 8 - Finish: start the VM.
        vm.start(conn, false, true);

        System.out.println("--- Result ---");
        System.out.println("power state:   " + vm.getPowerState(conn));
        System.out.println("vCPUs:         " + vm.getVCPUsMax(conn));
        System.out.println("disks:         " + vm.getVBDs(conn).size() + ", NICs: " + vm.getVIFs(conn).size());

        // Tidy up so the example is repeatable.
        vm.hardShutdown(conn);
        vm.destroy(conn);
        vdi.destroy(conn);
        System.out.println("Cleaned up the example VM.");

        System.out.println("OK: new-vm-wizard");
        Session.logout(conn);
    }
    // Run it:
    //   newVmWizard("https://xenserver", "root", password, "Rocky Linux 8", "wizard-vm");

    // --- 10. Live migrate a VM ---------------------------------------------------------
    private static void liveMigrate(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        // Start a throwaway VM so there is something running to migrate.
        VM vm = templateByName(conn, templateName).createClone(conn, newVmName);
        vm.provision(conn);
        vm.start(conn, false, true);

        Host sourceHost = vm.getResidentOn(conn);
        System.out.println("VM is running on: " + sourceHost.getNameLabel(conn));

        // Pick a different host in the pool to receive the VM.
        Host destHost = null;
        for (Host h : Host.getAllRecords(conn).keySet())
            if (!h.equals(sourceHost)) { destHost = h; break; }

        // Check the destination can boot it, then live-migrate (empty options = default live migration).
        vm.assertCanBootHere(conn, destHost);
        vm.poolMigrate(conn, destHost, new java.util.HashMap<>());

        System.out.println("Migrated to:      " + vm.getResidentOn(conn).getNameLabel(conn));
        System.out.println("Still running:    " + vm.getPowerState(conn));

        // Tidy up so the example is repeatable.
        vm.hardShutdown(conn);
        vm.destroy(conn);
        System.out.println("OK: live-migrate");
        Session.logout(conn);
    }
    // Run it:
    //   liveMigrate("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-migrate");

    // --- 11. Enter & exit maintenance mode ---------------------------------------------
    private static void hostMaintenance(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        // Choose a host that is not the pool coordinator, so the coordinator can receive its guests.
        Host master = Pool.getAllRecords(conn).values().iterator().next().master;
        Host hostRef = null;
        for (Host h : Host.getAllRecords(conn).keySet())
            if (!h.equals(master)) { hostRef = h; break; }
        System.out.println("Maintenance host: " + hostRef.getNameLabel(conn));

        // Pin a running VM to that host so evacuation has something to move.
        VM vm = templateByName(conn, templateName).createClone(conn, newVmName);
        vm.provision(conn);
        vm.setAffinity(conn, hostRef);
        vm.start(conn, false, true);
        System.out.println("Guest resident on:" + vm.getResidentOn(conn).getNameLabel(conn));

        // Enter maintenance mode: disable the host, then evacuate its guests.
        hostRef.disable(conn);
        System.out.println("After disable:    host.enabled = " + hostRef.getEnabled(conn));
        hostRef.evacuate(conn);
        System.out.println("After evacuate:   guest now on " + vm.getResidentOn(conn).getNameLabel(conn));

        // Exit maintenance mode.
        hostRef.enable(conn);
        System.out.println("After enable:     host.enabled = " + hostRef.getEnabled(conn));

        // Tidy up so the example is repeatable.
        vm.hardShutdown(conn);
        vm.destroy(conn);
        System.out.println("OK: host-maintenance");
        Session.logout(conn);
    }
    // Run it:
    //   hostMaintenance("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-maint");

    // --- 12. Configure high availability -----------------------------------------------
    private static void configureHa(String url, String user, String password,
            String heartbeatSrName) throws Exception {
        Connection conn = connect(url, user, password);
        Pool pool = Pool.getAllRecords(conn).keySet().iterator().next();

        // The HA heartbeat statefile needs a shared SR; confirm the chosen one can host it.
        SR sr = srByName(conn, heartbeatSrName, true);
        System.out.println("Heartbeat SR:  " + sr.getNameLabel(conn));
        sr.assertCanHostHaStatefile(conn);

        // How many host failures can the pool tolerate? Set that as the target and enable HA.
        long ntol = Pool.haComputeHypotheticalMaxHostFailuresToTolerate(conn, new java.util.HashMap<>());
        System.out.println("Max failures:  " + ntol);
        pool.setHaHostFailuresToTolerate(conn, ntol);
        Set<SR> heartbeatSrs = new LinkedHashSet<>();
        heartbeatSrs.add(sr);
        Pool.enableHa(conn, heartbeatSrs, new java.util.HashMap<>());
        System.out.println("HA enabled:    " + pool.getHaEnabled(conn));

        // What HA does per VM. The restart priority decides which guests come back first after a host
        // failure, and whether a VM is protected at all; "restart" is protected, an empty string is not.
        VM guest = null;
        for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
            VM.Record r = e.getValue();
            if (!r.isATemplate && !r.isControlDomain && !r.isASnapshot) { guest = e.getKey(); break; }
        }
        String was = guest.getHaRestartPriority(conn);
        guest.setHaRestartPriority(conn, "restart");
        System.out.println(guest.getNameLabel(conn) + " priority: '" + was + "' -> '"
                + guest.getHaRestartPriority(conn) + "'");
        guest.setHaRestartPriority(conn, was);

        // And a pool-wide judgement call: if a guest shuts itself down from the inside, is that a
        // failure HA should undo, or an administrator's intent it should respect?
        boolean internal = pool.getHaRebootVmOnInternalShutdown(conn);
        System.out.println("Restart on internal shutdown: " + internal);

        // Turn HA back off so the example is repeatable.
        Pool.disableHa(conn);
        System.out.println("HA enabled:    " + pool.getHaEnabled(conn));
        System.out.println("OK: configure-ha");
        Session.logout(conn);
    }
    // Run it:
    //   configureHa("https://xenserver", "root", password, "Shared NFS");

    // --- 13. Copy a VM -----------------------------------------------------------------
    private static void copyVm(String url, String user, String password,
            String vmName, String srName, String copyName) throws Exception {
        Connection conn = connect(url, user, password);
        // A full copy needs a halted source; it places an independent set of disks on the chosen SR.
        VM source = vmByName(conn, vmName);
        SR sr = srByName(conn, srName, false);
        System.out.println("Copying '" + source.getNameLabel(conn) + "' to SR: " + sr.getNameLabel(conn));

        VM copy = source.copy(conn, copyName, sr);
        System.out.println("Copied VM:     " + copy.getUuid(conn));
        System.out.println("Copy has " + copy.getVBDs(conn).size()
                + " VBD(s), is_a_template = " + copy.getIsATemplate(conn));

        // Tidy up: destroy the copy and its disks, leaving the source VM intact.
        Set<VDI> copyVdis = new LinkedHashSet<>();
        for (VBD vbd : copy.getVBDs(conn))
            if (vbd.getType(conn) == Types.VbdType.DISK) copyVdis.add(vbd.getVDI(conn));
        copy.destroy(conn);
        for (VDI vdi : copyVdis) vdi.destroy(conn);
        System.out.println("Cleaned up the copied VM (left the source intact).");
        System.out.println("OK: copy-vm");
        Session.logout(conn);
    }
    // Run it:
    //   copyVm("https://xenserver", "root", password, "db-01", "Shared NFS", "sdk-example-copy");

    // --- 14. Create a VM with a vGPU ---------------------------------------------------
    private static void createVmWithVgpu(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        // Find a GPU group that offers a real (non-passthrough) vGPU type, plus that type.
        GPUGroup group = null;
        VGPUType vgpuType = null;
        outer:
        for (Map.Entry<GPUGroup, GPUGroup.Record> e : GPUGroup.getAllRecords(conn).entrySet()) {
            if (e.getValue().PGPUs.isEmpty()) continue;
            for (VGPUType t : e.getValue().supportedVGPUTypes) {
                if (!"passthrough".equals(t.getModelName(conn))) {
                    group = e.getKey();
                    vgpuType = t;
                    break outer;
                }
            }
        }
        if (group == null) throw new RuntimeException("no GPU group offers a vGPU type");
        System.out.println("Using vGPU type: " + vgpuType.getModelName(conn)
                + " (" + vgpuType.getFramebufferSize(conn) / (1024 * 1024) + " MB framebuffer)");

        // Provision a fresh VM from the template to attach the vGPU to.
        VM vm = templateByName(conn, templateName).createClone(conn, newVmName);
        vm.provision(conn);

        // Assign the vGPU: device "0" is the VM's first vGPU slot, other_config is empty. Same call
        // as XenCenter's New VM wizard GPU page and the VM Properties GPU page.
        VGPU vgpu = VGPU.create(conn, vm, group, "0", new HashMap<String, String>(), vgpuType);
        System.out.println("Created vGPU: " + vgpu.getUuid(conn));

        // Read the assignment back, as XenCenter's GPU tab does.
        Set<VGPU> vgpus = vm.getVGPUs(conn);
        String assigned = vgpus.iterator().next().getType(conn).getModelName(conn);
        System.out.println("VM now has " + vgpus.size() + " vGPU(s); type = " + assigned);

        // Tidy up so the example is repeatable.
        vgpu.destroy(conn);
        vm.destroy(conn);
        System.out.println("Cleaned up the example VM and its vGPU.");

        System.out.println("OK: create-vm-with-vgpu");
        Session.logout(conn);
    }
    // Run it:
    //   createVmWithVgpu("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-vgpu-vm");

    // --- 15. Tag and organize objects --------------------------------------------------
    private static void tagsAndFolders(String url, String user, String password, String vmName) throws Exception {
        Connection conn = connect(url, user, password);
        VM vm = vmByName(conn, vmName);
        Host host = Host.getAll(conn).iterator().next();

        // Tags work on any object type (VM, host, SR, network, …).
        vm.addTags(conn, "web");
        host.addTags(conn, "gold");
        System.out.println("VM tags:   " + vm.getTags(conn));
        System.out.println("Host tags: " + host.getTags(conn));

        // Folder placement lives in other_config["folder"] as a leading-slash path.
        vm.addToOtherConfig(conn, "folder", "/Production/Web");
        System.out.println("VM folder: " + vm.getOtherConfig(conn).get("folder"));

        vm.removeTags(conn, "web");
        host.removeTags(conn, "gold");
        vm.removeFromOtherConfig(conn, "folder");
        System.out.println("OK: tags-and-folders");
        Session.logout(conn);
    }
    // Run it:
    //   tagsAndFolders("https://xenserver", "root", password, "web-01");

    // --- 16. Configure updates (CDN) ---------------------------------------------------
    private static void configureUpdates(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        Repository repo = Repository.introduce(conn, "sdk-cdn", "SDK example repository",
                "https://cdn.example/base", "https://cdn.example/source", false, "");
        System.out.println("Introduced repository: " + repo.getNameLabel(conn));

        Pool pool = Pool.getAll(conn).iterator().next();
        pool.setRepositories(conn, new LinkedHashSet<>(java.util.List.of(repo)));
        pool.setUpdateSyncEnabled(conn, true);
        System.out.println("Pool repositories: " + pool.getRepositories(conn).size()
                + "; auto-sync enabled: " + pool.getUpdateSyncEnabled(conn));

        // Tidy up so the example is repeatable.
        pool.setUpdateSyncEnabled(conn, false);
        pool.setRepositories(conn, new LinkedHashSet<>());
        repo.forget(conn);
        System.out.println("OK: configure-updates");
        Session.logout(conn);
    }
    // Run it:
    //   configureUpdates("https://xenserver", "root", password);

    // --- 17. Clone a VM (fast, copy-on-write) ------------------------------------------
    private static void cloneVm(String url, String user, String password,
            String vmName, String cloneName) throws Exception {
        Connection conn = connect(url, user, password);
        // Unlike Copy (a full, independent copy onto a chosen SR), Clone is a fast copy-on-write
        // duplicate on the same SR — ideal for a halted "golden" VM.
        VM source = vmByName(conn, vmName);
        VM clone = source.createClone(conn, cloneName);
        System.out.println("Cloned '" + source.getNameLabel(conn) + "' → " + clone.getNameLabel(conn));
        System.out.println("Clone has " + clone.getVBDs(conn).size() + " VBD(s)");

        // Tidy up: destroy the clone and its (owned) disks.
        Set<VDI> vdis = diskVdis(conn, clone);
        clone.destroy(conn);
        for (VDI vdi : vdis) vdi.destroy(conn);
        System.out.println("OK: clone-vm");
        Session.logout(conn);
    }
    // Run it:
    //   cloneVm("https://xenserver", "root", password, "db-01", "sdk-example-clone");

    // --- 18. Delete a VM ---------------------------------------------------------------
    private static void deleteVm(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        // Make a throwaway VM to delete. VM.destroy removes the VM but leaves its disks, so the
        // owned VDIs are destroyed explicitly afterward — exactly what XenCenter's Delete VM does.
        VM vm = templateByName(conn, templateName).createClone(conn, newVmName);
        vm.provision(conn);
        String uuid = vm.getUuid(conn);
        Set<VDI> vdis = diskVdis(conn, vm);
        System.out.println("Deleting VM " + uuid + " with " + vdis.size() + " disk(s)");

        vm.destroy(conn);
        for (VDI vdi : vdis) vdi.destroy(conn);

        boolean stillThere = false;
        for (VM.Record r : VM.getAllRecords(conn).values())
            if (uuid.equals(r.uuid)) { stillThere = true; break; }
        System.out.println("VM still present: " + stillThere);
        System.out.println("OK: delete-vm");
        Session.logout(conn);
    }
    // Run it:
    //   deleteVm("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-delete");

    // --- 19. Storage live-migration (move a disk to another SR) -------------------------
    private static void storageMigrate(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        // Provision a VM so it has a disk to relocate, note the disk's current SR.
        VM vm = templateByName(conn, templateName).createClone(conn, newVmName);
        vm.provision(conn);
        VDI vdi = diskVdis(conn, vm).iterator().next();
        SR sourceSr = vdi.getSR(conn);
        System.out.println("Disk is on SR: " + sourceSr.getNameLabel(conn));

        // Pick a different SR that can hold a VDI and move the disk there (live storage migration).
        SR destSr = null;
        for (Map.Entry<SR, SR.Record> e : SR.getAllRecords(conn).entrySet()) {
            if (!e.getKey().equals(sourceSr)
                    && !"iso".equals(e.getValue().type) && !"udev".equals(e.getValue().type)) {
                destSr = e.getKey();
                break;
            }
        }
        vdi.poolMigrate(conn, destSr, new java.util.HashMap<>());

        System.out.println("Disk moved to:  " + vdi.getSR(conn).getNameLabel(conn));

        // Tidy up.
        vm.destroy(conn);
        vdi.destroy(conn);
        System.out.println("OK: storage-migrate");
        Session.logout(conn);
    }
    // Run it:
    //   storageMigrate("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-storagemigrate");

    // --- 20. Apply updates from the CDN ------------------------------------------------
    private static void applyUpdate(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        // Sync the pool's update metadata from the CDN; the returned hash identifies the synced set.
        Pool pool = Pool.getAll(conn).iterator().next();
        String hash = pool.syncUpdates(conn, false, "", "");
        System.out.println("Synced updates; hash length " + hash.length());

        // Apply the synced updates to each host. XenCenter then reads the reboot guidance to decide
        // whether a Rolling Pool Upgrade reboot is needed.
        for (Map.Entry<Host, Host.Record> e : Host.getAllRecords(conn).entrySet()) {
            e.getKey().applyUpdates(conn, hash);
            System.out.println("  " + e.getValue().nameLabel + ": applied; pending guidance = "
                    + e.getKey().getPendingGuidances(conn));
        }
        System.out.println("OK: apply-update");
        Session.logout(conn);
    }
    // Run it:
    //   applyUpdate("https://xenserver", "root", password);

    // --- 21. Checkpoint & revert -------------------------------------------------------
    private static void checkpointVm(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        // A checkpoint captures disk AND memory (unlike a plain snapshot), so the VM must be running.
        VM vm = templateByName(conn, templateName).createClone(conn, newVmName);
        vm.provision(conn);
        vm.start(conn, false, true);

        VM checkpoint = vm.checkpoint(conn, "sdk-example-checkpoint-1");
        System.out.println("Created checkpoint: " + checkpoint.getUuid(conn));
        System.out.println("is_a_snapshot = " + checkpoint.getIsASnapshot(conn));

        checkpoint.revert(conn);
        System.out.println("Reverted the VM to the checkpoint.");

        // Tidy up.
        checkpoint.destroy(conn);
        if (vm.getPowerState(conn) == Types.VmPowerState.RUNNING) vm.hardShutdown(conn);
        vm.destroy(conn);
        System.out.println("OK: checkpoint-vm");
        Session.logout(conn);
    }
    // Run it:
    //   checkpointVm("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-checkpoint");

    // --- 22. Attach a new disk to a VM -------------------------------------------------
    private static void attachDisk(String url, String user, String password,
            String templateName, String srName, String newVmName) throws Exception {
        final long GiB = 1024L * 1024 * 1024;
        Connection conn = connect(url, user, password);
        VM vm = templateByName(conn, templateName).createClone(conn, newVmName);
        vm.provision(conn);
        SR sr = srByName(conn, srName, false);

        // Create a fresh VDI on the SR and attach it as a new VBD (a new virtual disk).
        VDI.Record vdiRec = new VDI.Record();
        vdiRec.nameLabel = "sdk-example-data-disk";
        vdiRec.SR = sr;
        vdiRec.virtualSize = 8 * GiB;
        vdiRec.type = Types.VdiType.USER;
        vdiRec.sharable = false;
        vdiRec.readOnly = false;
        vdiRec.otherConfig = new java.util.HashMap<>();
        VDI vdi = VDI.create(conn, vdiRec);

        String device = vm.getAllowedVBDDevices(conn).iterator().next();
        VBD.Record vbdRec = new VBD.Record();
        vbdRec.VM = vm;
        vbdRec.VDI = vdi;
        vbdRec.userdevice = device;
        vbdRec.mode = Types.VbdMode.RW;
        vbdRec.type = Types.VbdType.DISK;
        vbdRec.empty = false;
        vbdRec.otherConfig = new java.util.HashMap<>();
        vbdRec.qosAlgorithmType = "";
        vbdRec.qosAlgorithmParams = new java.util.HashMap<>();
        VBD.create(conn, vbdRec);
        System.out.println("Attached an 8 GiB disk on " + sr.getNameLabel(conn) + " as device " + device);
        System.out.println("VM now has " + vm.getVBDs(conn).size() + " VBD(s)");

        // Tidy up: gather the owned disks first, then destroy the VM (which removes its VBDs), then
        // destroy the disks (VM.destroy leaves VDIs behind).
        Set<VDI> owned = diskVdis(conn, vm);
        vm.destroy(conn);
        for (VDI d : owned) d.destroy(conn);
        System.out.println("OK: attach-disk");
        Session.logout(conn);
    }
    // Run it:
    //   attachDisk("https://xenserver", "root", password, "Rocky Linux 8", "Shared NFS", "sdk-example-attachdisk");

    // --- 23. Drive an asynchronous task ------------------------------------------------
    private static void waitForTask(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        // Every message has an Async.* twin that returns a Task ref immediately; poll it to completion.
        Task task = templateByName(conn, templateName).createCloneAsync(conn, newVmName);
        System.out.println("Started task: " + task.getUuid(conn));

        while (task.getStatus(conn) == Types.TaskStatusType.PENDING) {
            System.out.println("  progress: " + Math.round(task.getProgress(conn) * 100) + "%");
            Thread.sleep(200);
        }
        System.out.println("Task status: " + task.getStatus(conn));

        // The result of an object-creating task is <value>OpaqueRef:...</value>.
        String result = task.getResult(conn);
        String vmRef = result.replace("<value>", "").replace("</value>", "").trim();
        VM vm = new VM(vmRef);
        System.out.println("Task produced VM: " + vm.getNameLabel(conn));

        // Tidy up.
        vm.destroy(conn);
        task.destroy(conn);
        System.out.println("OK: wait-for-task");
        Session.logout(conn);
    }
    // Run it:
    //   waitForTask("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-asynctask");

    // --- 24. Handle an API error ------------------------------------------------------
    private static void errorHandling(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        // XenAPI errors surface as a XenAPIException. Specific errors are typed subclasses (e.g.
        // UuidInvalid): the class name identifies the error and getMessage() is the readable text.
        try {
            Host.getByUuid(conn, "this-uuid-does-not-exist");
            System.out.println("unexpected: no error");
        } catch (Types.XenAPIException e) {
            System.out.println("Caught expected failure: " + e.getClass().getSimpleName());
            System.out.println("Short message: " + e.getMessage());
        }
        System.out.println("OK: error-handling");
        Session.logout(conn);
    }
    // Run it:
    //   errorHandling("https://xenserver", "root", password);

    // --- 25. List templates -----------------------------------------------------------
    private static void listTemplates(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        java.util.List<VM.Record> templates = new java.util.ArrayList<>();
        for (VM.Record v : VM.getAllRecords(conn).values())
            if (v.isATemplate) templates.add(v);
        templates.sort(java.util.Comparator.comparing((VM.Record r) -> r.nameLabel));
        System.out.println("Templates (" + templates.size() + "):");
        int shown = 0;
        for (VM.Record t : templates) {
            if (shown++ >= 8) break;
            boolean isDefault = t.otherConfig.containsKey("default_template");
            System.out.println("  - " + t.nameLabel + (isDefault ? " [built-in]" : ""));
        }
        System.out.println("OK: list-templates");
        Session.logout(conn);
    }
    // Run it:
    //   listTemplates("https://xenserver", "root", password);

    // --- 26. Custom fields ------------------------------------------------------------
    private static void customFields(String url, String user, String password, String vmName) throws Exception {
        Connection conn = connect(url, user, password);
        // XenCenter's custom fields are stored in other_config under "XenCenter.CustomFields.<name>".
        VM vm = vmByName(conn, vmName);
        final String key = "XenCenter.CustomFields.Owner";
        vm.addToOtherConfig(conn, key, "Platform Team");
        System.out.println("Custom field Owner = " + vm.getOtherConfig(conn).get(key));

        vm.removeFromOtherConfig(conn, key);
        System.out.println("OK: custom-fields");
        Session.logout(conn);
    }
    // Run it:
    //   customFields("https://xenserver", "root", password, "web-01");

    // --- 27. GPU inventory ------------------------------------------------------------
    private static void gpuInventory(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        Map<GPUGroup, GPUGroup.Record> groups = GPUGroup.getAllRecords(conn);
        System.out.println("GPU groups (" + groups.size() + "):");
        for (GPUGroup.Record group : groups.values()) {
            StringBuilder types = new StringBuilder();
            for (VGPUType t : group.supportedVGPUTypes) {
                if (types.length() > 0) types.append(", ");
                types.append(t.getModelName(conn));
            }
            System.out.println("  - " + group.nameLabel + ": " + group.PGPUs.size()
                    + " pGPU(s), vGPU types: " + types);
        }
        // How the pool spreads vGPUs across the physical GPUs in a group: depth-first packs each pGPU
        // full before using the next, breadth-first spreads them out.
        GPUGroup groupRef = groups.keySet().iterator().next();
        Types.AllocationAlgorithm before = groupRef.getAllocationAlgorithm(conn);
        groupRef.setAllocationAlgorithm(conn, Types.AllocationAlgorithm.BREADTH_FIRST);
        System.out.println("Allocation:      " + before + " -> " + groupRef.getAllocationAlgorithm(conn));
        groupRef.setAllocationAlgorithm(conn, before);
        System.out.println("OK: gpu-inventory");
        Session.logout(conn);
    }
    // Run it:
    //   gpuInventory("https://xenserver", "root", password);

    // --- 28. Read host & VM metrics ---------------------------------------------------
    private static void readMetrics(String url, String user, String password) throws Exception {
        final long MiB = 1024L * 1024;
        Connection conn = connect(url, user, password);
        Map.Entry<Host, Host.Record> he = Host.getAllRecords(conn).entrySet().iterator().next();
        HostMetrics hm = he.getKey().getMetrics(conn);
        System.out.println("Host " + he.getValue().nameLabel + ": "
                + hm.getMemoryTotal(conn) / MiB + " MiB total, "
                + he.getKey().computeFreeMemory(conn) / MiB + " MiB free, "
                + "live = " + hm.getLive(conn));

        VM vm = null;
        for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
            VM.Record r = e.getValue();
            if (!r.isATemplate && !r.isControlDomain && r.powerState == Types.VmPowerState.RUNNING) {
                vm = e.getKey();
                break;
            }
        }
        VMMetrics vmm = vm.getMetrics(conn);
        System.out.println("VM " + vm.getNameLabel(conn) + ": "
                + vmm.getVCPUsNumber(conn) + " vCPU(s), "
                + vmm.getMemoryActual(conn) / MiB + " MiB");
        System.out.println("OK: read-metrics");
        Session.logout(conn);
    }
    // Run it:
    //   readMetrics("https://xenserver", "root", password);

    // --- 29. Rename an object ----------------------------------------------------------
    private static void renameObject(String url, String user, String password, String vmName) throws Exception {
        Connection conn = connect(url, user, password);
        VM vm = vmByName(conn, vmName);
        String original = vm.getNameLabel(conn);
        vm.setNameLabel(conn, "sdk-renamed");
        System.out.println("Renamed '" + original + "' → '" + vm.getNameLabel(conn) + "'");
        vm.setNameLabel(conn, original); // restore so the example is repeatable
        System.out.println("OK: rename-object");
        Session.logout(conn);
    }
    // Run it:
    //   renameObject("https://xenserver", "root", password, "web-01");

    // --- 30. VM boot configuration -----------------------------------------------------
    private static void vmBootConfig(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        VM vm = templateByName(conn, templateName).createClone(conn, newVmName);
        vm.provision(conn);

        vm.setVCPUsMax(conn, 4L);
        vm.setVCPUsAtStartup(conn, 2L);

        // Boot mode: firmware ("bios"/"uefi") lives in HVM_boot_params; Secure Boot in
        // platform["secureboot"]. Switch to UEFI Secure Boot (as the New VM wizard does for a
        // UEFI-capable template) and read it back.
        Map<String, String> bootParams = new java.util.HashMap<>();
        bootParams.put("order", "cdn");
        bootParams.put("firmware", "uefi");
        vm.setHVMBootParams(conn, bootParams);
        Map<String, String> platform = vm.getPlatform(conn);
        platform.put("secureboot", "true");
        vm.setPlatform(conn, platform);
        System.out.println("vCPUs: " + vm.getVCPUsAtStartup(conn) + "/" + vm.getVCPUsMax(conn));
        System.out.println("Boot order: " + vm.getHVMBootParams(conn).get("order"));
        System.out.println("Boot mode: firmware=" + vm.getHVMBootParams(conn).get("firmware")
                + ", secureboot=" + vm.getPlatform(conn).get("secureboot"));

        vm.destroy(conn);
        System.out.println("OK: vm-boot-config");
        Session.logout(conn);
    }
    // Run it:
    //   vmBootConfig("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-boot");

    // --- 31. Host information ----------------------------------------------------------
    private static void hostInfo(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        Host.Record host = Host.getAllRecords(conn).values().iterator().next();
        Map<String, String> sw = host.softwareVersion;
        Map<String, String> cpu = host.cpuInfo;
        System.out.println("Host:     " + host.nameLabel);
        System.out.println("Version:  " + (sw.containsKey("product_version") ? sw.get("product_version") : "?"));
        System.out.println("Edition:  " + host.edition);
        System.out.println("CPUs:     " + (cpu.containsKey("cpu_count") ? cpu.get("cpu_count") : "?")
                + " across " + (cpu.containsKey("socket_count") ? cpu.get("socket_count") : "?") + " socket(s)");
        // The physical identity, straight off the host's DMI/SMBIOS tables. The serial number is what
        // you quote to the hardware vendor, so it identifies this machine and not just its model.
        Map<String, String> bios = host.biosStrings;
        System.out.println("Hardware: " + bios.getOrDefault("system-manufacturer", "?")
                + " " + bios.getOrDefault("system-product-name", "?"));
        System.out.println("Serial:   " + bios.getOrDefault("system-serial-number", "?"));
        System.out.println("BIOS:     " + bios.getOrDefault("bios-version", "?"));
        System.out.println("OK: host-info");
        Session.logout(conn);
    }
    // Run it:
    //   hostInfo("https://xenserver", "root", password);

    // --- 32. List roles ----------------------------------------------------------------
    private static void listRoles(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        // Role is the one class XenCenter still bulk-downloads; RBAC subjects map to these roles.
        Set<String> roles = new java.util.TreeSet<>(); // distinct + sorted by name
        for (Role.Record r : Role.getAllRecords(conn).values()) roles.add(r.nameLabel);
        StringBuilder first = new StringBuilder();
        int shown = 0;
        for (String name : roles) {
            if (shown++ >= 8) break;
            if (first.length() > 0) first.append(", ");
            first.append(name);
        }
        System.out.println("Roles (" + roles.size() + "): " + first);
        System.out.println("OK: list-roles");
        Session.logout(conn);
    }
    // Run it:
    //   listRoles("https://xenserver", "root", password);

    // --- 33. Pool properties -----------------------------------------------------------
    private static void poolProperties(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        Pool pool = Pool.getAll(conn).iterator().next();
        String original = pool.getNameLabel(conn);
        SR defaultSr = pool.getDefaultSR(conn);
        System.out.println("Pool:       '" + original + "'");
        System.out.println("Default SR: " + (defaultSr.toWireString().equals("OpaqueRef:NULL")
                ? "(none)" : defaultSr.getNameLabel(conn)));

        pool.setNameLabel(conn, "sdk-pool-renamed");
        System.out.println("Renamed to: '" + pool.getNameLabel(conn) + "'");
        pool.setNameLabel(conn, original); // restore
        System.out.println("OK: pool-properties");
        Session.logout(conn);
    }
    // Run it:
    //   poolProperties("https://xenserver", "root", password);

    // --- 34. Storage repository usage --------------------------------------------------
    private static void srUsage(String url, String user, String password) throws Exception {
        final long GiB = 1024L * 1024 * 1024;
        Connection conn = connect(url, user, password);
        java.util.List<SR.Record> srs = new java.util.ArrayList<>(SR.getAllRecords(conn).values());
        srs.sort(java.util.Comparator.comparing((SR.Record s) -> s.nameLabel));
        for (SR.Record sr : srs) {
            if (sr.physicalSize <= 0) continue; // skip ISO/DVD pseudo-SRs
            System.out.println("  " + sr.nameLabel + ": " + sr.physicalUtilisation / GiB
                    + " / " + sr.physicalSize / GiB + " GiB used");
        }
        // A rescan refreshes an SR's utilisation from its backend.
        SR scanMe = null;
        for (Map.Entry<SR, SR.Record> e : SR.getAllRecords(conn).entrySet())
            if (e.getValue().physicalSize > 0) { scanMe = e.getKey(); break; }
        scanMe.scan(conn);

        // Read caching keeps recently-read blocks in the host's memory. It is switched off per SR by
        // setting o_direct, which asks the storage layer to bypass the cache entirely.
        scanMe.removeFromOtherConfig(conn, "o_direct");
        scanMe.addToOtherConfig(conn, "o_direct", "true");
        System.out.println("  read caching on " + scanMe.getNameLabel(conn) + ": "
                + ("true".equals(scanMe.getOtherConfig(conn).get("o_direct")) ? "off" : "on"));
        scanMe.removeFromOtherConfig(conn, "o_direct");
        System.out.println("OK: sr-usage");
        Session.logout(conn);
    }
    // Run it:
    //   srUsage("https://xenserver", "root", password);

    // --- 35. Manage a VM's network interfaces ------------------------------------------
    private static void manageVif(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        VM vm = templateByName(conn, templateName).createClone(conn, newVmName);
        vm.provision(conn);
        Network net = Network.getAll(conn).iterator().next();
        String device = vm.getAllowedVIFDevices(conn).iterator().next();

        VIF.Record vifRec = new VIF.Record();
        vifRec.VM = vm;
        vifRec.network = net;
        vifRec.device = device;
        vifRec.MAC = "";
        vifRec.MTU = 1500L;
        vifRec.otherConfig = new java.util.HashMap<>();
        vifRec.qosAlgorithmType = "";
        vifRec.qosAlgorithmParams = new java.util.HashMap<>();
        VIF vif = VIF.create(conn, vifRec);
        System.out.println("Attached a VIF on device " + device + "; VM now has "
                + vm.getVIFs(conn).size() + " NIC(s)");

        vif.destroy(conn);
        vm.destroy(conn);
        System.out.println("OK: manage-vif");
        Session.logout(conn);
    }
    // Run it:
    //   manageVif("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-vif");

    // --- 36. List networks -------------------------------------------------------------
    private static void listNetworks(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        java.util.List<Network.Record> nets = new java.util.ArrayList<>(Network.getAllRecords(conn).values());
        nets.sort(java.util.Comparator.comparing((Network.Record n) -> n.nameLabel));
        System.out.println("Networks (" + nets.size() + "):");
        for (Network.Record net : nets)
            System.out.println("  - " + net.nameLabel + ": " + net.PIFs.size() + " PIF(s), " + net.VIFs.size() + " VIF(s)");
        System.out.println("OK: list-networks");
        Session.logout(conn);
    }
    // Run it:
    //   listNetworks("https://xenserver", "root", password);

    // --- 37. Inventory a VM's disks ----------------------------------------------------
    private static void vbdInventory(String url, String user, String password, String vmName) throws Exception {
        final long GiB = 1024L * 1024 * 1024;
        Connection conn = connect(url, user, password);
        VM vm = vmByName(conn, vmName);
        System.out.println("Disks of '" + vm.getNameLabel(conn) + "':");
        for (VBD vbd : vm.getVBDs(conn)) {
            VBD.Record rec = vbd.getRecord(conn);
            if (rec.type != Types.VbdType.DISK) continue;
            VDI vdi = vbd.getVDI(conn);
            long size = vdi.toWireString().equals("OpaqueRef:NULL") ? 0 : vdi.getVirtualSize(conn) / GiB;
            System.out.println("  - device " + rec.userdevice + ": " + size + " GiB");
        }
        System.out.println("OK: vbd-inventory");
        Session.logout(conn);
    }
    // Run it:
    //   vbdInventory("https://xenserver", "root", password, "db-01");

    // --- 38. Tag the pool --------------------------------------------------------------
    private static void poolTags(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        Pool pool = Pool.getAll(conn).iterator().next();
        pool.addTags(conn, "sdk-managed");
        System.out.println("Pool tags: " + String.join(", ", pool.getTags(conn)));
        pool.removeTags(conn, "sdk-managed");
        System.out.println("OK: pool-tags");
        Session.logout(conn);
    }
    // Run it:
    //   poolTags("https://xenserver", "root", password);

    // --- 39. Convert a VM to a template ------------------------------------------------
    private static void convertToTemplate(String url, String user, String password,
            String templateName, String newVmName) throws Exception {
        Connection conn = connect(url, user, password);
        VM vm = templateByName(conn, templateName).createClone(conn, newVmName);
        vm.provision(conn); // now a real (halted) VM
        System.out.println("is_a_template after provision: " + vm.getIsATemplate(conn));

        // Converting a VM to a custom template is a one-way operation.
        vm.setIsATemplate(conn, true);
        System.out.println("is_a_template after convert:  " + vm.getIsATemplate(conn));

        vm.destroy(conn);
        System.out.println("OK: convert-to-template");
        Session.logout(conn);
    }
    // Run it:
    //   convertToTemplate("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-totemplate");

    // --- 40. Look up an object by UUID -------------------------------------------------
    private static void findByUuid(String url, String user, String password, String vmName) throws Exception {
        Connection conn = connect(url, user, password);
        // UUIDs are stable identifiers you can persist and resolve back to a (session-scoped) ref.
        VM vm = vmByName(conn, vmName);
        String uuid = vm.getUuid(conn);
        VM resolved = VM.getByUuid(conn, uuid);
        System.out.println("UUID " + uuid + " resolves to " + resolved.getNameLabel(conn));
        System.out.println("Same object: " + resolved.equals(vm));
        System.out.println("OK: find-by-uuid");
        Session.logout(conn);
    }
    // Run it:
    //   findByUuid("https://xenserver", "root", password, "web-01");

    // --- 41. Rolling pool update ------------------------------------------------------
    private static void rollingPoolUpdate(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        Pool pool = Pool.getAll(conn).iterator().next();
        String hash = pool.syncUpdates(conn, false, "", "");
        System.out.println("Synced updates; hash length " + hash.length());

        // The rolling pattern behind XenCenter's automated Install Updates:
        // disable -> evacuate -> apply -> reboot -> re-enable, one host at a time.
        for (Map.Entry<Host, Host.Record> e : Host.getAllRecords(conn).entrySet()) {
            Host host = e.getKey();
            System.out.println("Updating " + e.getValue().nameLabel + ":");
            host.disable(conn);            // stop new VMs landing here
            host.evacuate(conn);           // move running guests to the rest of the pool
            host.applyUpdates(conn, hash); // apply the synced updates
            System.out.println("  applied; pending guidance = " + host.getPendingGuidances(conn));
            host.reboot(conn);             // reboot into the updated software
            host.enable(conn);             // return the host to service
        }
        System.out.println("OK: rolling-pool-update");
        Session.logout(conn);
    }
    // Run it:
    //   rollingPoolUpdate("https://xenserver", "root", password);

    // --- 42. Cross-pool copy a VM -----------------------------------------------------
    // Copy a VM from one pool to another (Storage XenMotion copy): get a receiver token from the
    // destination with host.migrate_receive, then VM.migrate_send with copy=true on the source.
    private static void crossPoolCopyVm(String url, String user, String password, String destUrl,
            String vmName) throws Exception {
        Connection source = connect(url, user, password);
        Connection dest = connect(destUrl, user, password);
        // Destination: choose a host, network and SR, then ask for a receiver token.
        Host destHost = Host.getAll(dest).iterator().next();
        Network destNetwork = Network.getAll(dest).iterator().next();
        SR destSr = srByName(dest, "Shared NFS", false);
        Map<String, String> receiver = destHost.migrateReceive(dest, destNetwork, new HashMap<>());

        // Source: map every disk to the destination SR and every NIC to the destination network,
        // then send with copy=true (the source VM is left intact).
        VM vm = vmByName(source, vmName);
        Map<VDI, SR> vdiMap = new HashMap<>();
        for (VBD vbd : vm.getVBDs(source))
            if (vbd.getType(source) == Types.VbdType.DISK) vdiMap.put(vbd.getVDI(source), destSr);
        Map<VIF, Network> vifMap = new HashMap<>();
        for (VIF vif : vm.getVIFs(source)) vifMap.put(vif, destNetwork);

        Map<String, String> options = new HashMap<>();
        options.put("copy", "true");
        vm.migrateSend(source, receiver, false, vdiMap, vifMap, options,
                new HashMap<VGPU, GPUGroup>());
        System.out.println("Sent '" + vmName + "' to the destination pool (copy); source still present: "
                + vmByName(source, vmName).equals(vm));
        System.out.println("OK: cross-pool-copy-vm");
        Session.logout(source);
        Session.logout(dest);
    }
    // Run it:
    //   crossPoolCopyVm("https://poolA", "root", password, "https://poolB", "db-01");


    // --- 43. PVS Accelerator inventory ---
    private static void pvsAccelerator(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Map<PVSSite, PVSSite.Record> sites = PVSSite.getAllRecords(conn);
            if (sites.isEmpty()) System.out.println("No PVS Accelerator sites are configured.");
            for (PVSSite.Record site : sites.values()) {
                System.out.println("Site: " + site.nameLabel);
                for (PVSCacheStorage cs : site.cacheStorage) {
                    PVSCacheStorage.Record r = cs.getRecord(conn);
                    System.out.printf("  cache:  %s  %d GiB on %s%n",
                        r.host.getNameLabel(conn), r.size / (1024L * 1024 * 1024), r.SR.getNameLabel(conn));
                }
                for (PVSServer server : site.servers) {
                    PVSServer.Record r = server.getRecord(conn);
                    System.out.printf("  server: %s  ports %d-%d%n", String.join(", ", r.addresses), r.firstPort, r.lastPort);
                }
                // Which VMs are accelerated: walk each proxy to its VIF to its VM.
                java.util.Set<String> accelerated = new java.util.HashSet<>();
                for (PVSProxy proxy : site.proxies) {
                    VIF vif = proxy.getRecord(conn).VIF;
                    accelerated.add(vif.getRecord(conn).VM.toWireString());
                }
                int total = 0, count = 0;
                for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
                    VM.Record v = e.getValue();
                    if (v.isControlDomain || v.isATemplate || v.isASnapshot) continue;
                    total++;
                    if (accelerated.contains(e.getKey().toWireString())) count++;
                }
                System.out.printf("  %d of %d VM(s) accelerated%n", count, total);
            }
            System.out.println("OK: pvs-accelerator");
        } finally {
            Session.logout(conn);
        }
    }

    // --- 44. Read RRD performance metrics ---
    private static void rrdMetrics(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Map<String, String> nameByUuid = new java.util.HashMap<>();
            for (Host.Record h : Host.getAllRecords(conn).values()) nameByUuid.put(h.uuid, h.nameLabel);

            // The RRD time-series isn't a XenAPI call; read rrd_updates over HTTP. Legends look like
            // "AVERAGE:host:<uuid>:<datasource>"; values[] aligns to legend[].
            long start = System.currentTimeMillis() / 1000 - 300;
            HttpGet get = new HttpGet(url + "/rrd_updates?session_id=" + conn.getSessionReference() + "&host=true&start=" + start);
            get.addHeader("accept", "application/json");
            String body;
            try (CloseableHttpClient http = trustingHttpClient()) {
                body = http.execute(get, resp -> EntityUtils.toString(resp.getEntity()));
            }
            JsonNode root = new ObjectMapper().readTree(body);
            JsonNode legends = root.get("meta").get("legend");
            Map<String, Double> peak = new java.util.HashMap<>();
            for (JsonNode point : root.get("data")) {
                JsonNode values = point.get("values");
                for (int k = 0; k < legends.size(); k++) {
                    String[] parts = legends.get(k).asText().split(":");
                    if (parts[1].equals("host") && parts[3].equals("pvsaccelerator_space_utilization")) {
                        peak.merge(parts[2], values.get(k).asDouble(), Math::max);
                    }
                }
            }
            for (Map.Entry<String, Double> e : peak.entrySet())
                System.out.printf("  %s: peak PVS cache utilisation %.0f%%%n", nameByUuid.get(e.getKey()), e.getValue());
            System.out.println("OK: rrd-metrics");
        } finally {
            Session.logout(conn);
        }
    }

    // --- 45. Reclaim freed space on a thin SR ------------------------------------------
    private static void reclaimSpace(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // Storage-manager backends that advertise SR_TRIM in their features map are trim-capable.
            java.util.Set<String> trimTypes = new java.util.HashSet<>();
            for (SM.Record sm : SM.getAllRecords(conn).values())
                if (sm.features.containsKey("SR_TRIM")) trimTypes.add(sm.type);
            SR.Record sr = null;
            for (SR.Record r : SR.getAllRecords(conn).values())
                if (r.physicalSize > 0 && trimTypes.contains(r.type)) { sr = r; break; }
            // A host with a currently-attached PBD can reach the SR to run the plugin.
            Host host = null;
            for (PBD pbd : sr.PBDs) {
                PBD.Record pr = pbd.getRecord(conn);
                if (pr.currentlyAttached) { host = pr.host; break; }
            }
            java.util.Map<String, String> pargs = new java.util.HashMap<>();
            pargs.put("sr_uuid", sr.uuid);
            String result = host.callPlugin(conn, "trim", "do_trim", pargs);
            System.out.println("  reclaimed freed space on " + sr.nameLabel + ": " + result);
            if (!"true".equals(result)) throw new RuntimeException("trim plugin returned '" + result + "'");
            System.out.println("OK: reclaim-space");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   reclaimSpace("https://xenserver", "root", password);

    // --- 46. Get a VM's IP address -----------------------------------------------------
    private static void vmIpAddress(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // A running guest reports its IP in VM_guest_metrics.networks, keyed "<vif device>/ip".
            VM.Record vm = null;
            for (VM.Record r : VM.getAllRecords(conn).values())
                if (r.powerState == Types.VmPowerState.RUNNING && !r.isATemplate && !r.isControlDomain
                        && !r.guestMetrics.toWireString().equals("OpaqueRef:NULL")) { vm = r; break; }
            java.util.Map<String, String> networks = vm.guestMetrics.getRecord(conn).networks;
            String ip = networks.getOrDefault("0/ip", "(no address reported)");
            System.out.println("  " + vm.nameLabel + ": " + ip);
            System.out.println("OK: vm-ip-address");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   vmIpAddress("https://xenserver", "root", password);

    // --- 47. Manage Active Directory users ---------------------------------------------
    private static void manageAdUsers(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Pool pool = Pool.getAll(conn).iterator().next();
            java.util.Map<String, String> config = new java.util.HashMap<>();
            config.put("user", "administrator"); config.put("pass", "secret"); config.put("ldaps", "false");
            pool.enableExternalAuth(conn, config, "citrix.local", "AD");
            System.out.println("Joined domain: citrix.local");

            String sid = Auth.getSubjectIdentifier(conn, "alice@citrix.local");
            java.util.Map<String, String> info = Auth.getSubjectInformationFromIdentifier(conn, sid);
            Subject.Record srec = new Subject.Record();
            srec.subjectIdentifier = sid;
            srec.otherConfig = info;
            Subject subject = Subject.create(conn, srec);

            Role admin = null;
            for (Map.Entry<Role, Role.Record> e : Role.getAllRecords(conn).entrySet())
                if (e.getValue().nameLabel.equals("pool-admin") && e.getValue().subroles.size() > 0) { admin = e.getKey(); break; }
            subject.addToRoles(conn, admin);
            StringBuilder roles = new StringBuilder();
            for (Role r : subject.getRoles(conn)) roles.append(r.getNameLabel(conn)).append(" ");
            System.out.println("Added subject " + info.get("subject-displayname") + " (" + info.get("subject-name")
                    + ") as " + roles.toString().trim());

            // Revoking access does not end sessions the user already has: logging the subject out is a
            // separate act, and the one that actually gets them off the pool now rather than at next login.
            System.out.println("Logged-in subjects: " + Session.getAllSubjectIdentifiers(conn).size());
            Session.logoutSubjectIdentifier(conn, sid);
            System.out.println("  logged out " + info.get("subject-name"));

            subject.removeFromRoles(conn, admin);
            subject.destroy(conn);
            pool.disableExternalAuth(conn, config);
            System.out.println("OK: manage-ad-users");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   manageAdUsers("https://xenserver", "root", password);

    // --- 48. Create an iSCSI SR --------------------------------------------------------
    private static void createIscsiSr(String url, String user, String password) throws Exception {
        final long GiB = 1024L * 1024 * 1024;
        Connection conn = connect(url, user, password);
        try {
            Host host = Host.getAllRecords(conn).keySet().iterator().next();
            Map<String, String> dc = new java.util.HashMap<>();
            dc.put("target", "192.0.2.30");
            dc.put("targetIQN", "iqn.2009-01.com.xenpretender:target-0");
            dc.put("SCSIid", "360a980004265656d5f4a2d63764e5734");
            SR sr = SR.create(conn, host, dc, 0L, "sdk-iscsi-sr", "iSCSI SR created by the SDK example",
                "lvmoiscsi", "user", true, new java.util.HashMap<>());
            System.out.println("Created SR: " + sr.getUuid(conn) + " (" + sr.getPhysicalSize(conn) / GiB + " GiB)");
            sr.forget(conn);
            System.out.println("OK: create-iscsi-sr");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   createIscsiSr("https://xenserver", "root", password);

    // --- 49. Create an SMB SR ----------------------------------------------------------
    private static void createSmbSr(String url, String user, String password) throws Exception {
        final long GiB = 1024L * 1024 * 1024;
        Connection conn = connect(url, user, password);
        try {
            Host host = Host.getAllRecords(conn).keySet().iterator().next();
            Map<String, String> dc = new java.util.HashMap<>();
            dc.put("server", "192.0.2.40");
            dc.put("serverpath", "/vmstore");
            dc.put("username", "Administrator");
            dc.put("password", "Password1");
            SR sr = SR.create(conn, host, dc, 0L, "sdk-smb-sr", "SMB SR created by the SDK example",
                "smb", "user", true, new java.util.HashMap<>());
            System.out.println("Created SR: " + sr.getUuid(conn) + " (" + sr.getPhysicalSize(conn) / GiB + " GiB)");
            sr.forget(conn);
            System.out.println("OK: create-smb-sr");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   createSmbSr("https://xenserver", "root", password);

    // --- 50. Create an HBA SR ----------------------------------------------------------
    private static void createHbaSr(String url, String user, String password) throws Exception {
        final long GiB = 1024L * 1024 * 1024;
        Connection conn = connect(url, user, password);
        try {
            Host host = Host.getAllRecords(conn).keySet().iterator().next();
            Map<String, String> dc = new java.util.HashMap<>();
            dc.put("SCSIid", "360a980004265656d5f4a2d63764e5736");
            SR sr = SR.create(conn, host, dc, 0L, "sdk-hba-sr", "HBA SR created by the SDK example",
                "lvmohba", "user", true, new java.util.HashMap<>());
            System.out.println("Created SR: " + sr.getUuid(conn) + " (" + sr.getPhysicalSize(conn) / GiB + " GiB)");
            sr.forget(conn);
            System.out.println("OK: create-hba-sr");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   createHbaSr("https://xenserver", "root", password);

    // --- 51. Create a GFS2 SR ----------------------------------------------------------
    private static void createGfs2Sr(String url, String user, String password) throws Exception {
        final long GiB = 1024L * 1024 * 1024;
        Connection conn = connect(url, user, password);
        try {
            Host host = Host.getAllRecords(conn).keySet().iterator().next();
            Map<String, String> dc = new java.util.HashMap<>();
            dc.put("provider", "iscsi");
            dc.put("target", "192.0.2.30");
            dc.put("targetIQN", "iqn.2009-01.com.xenpretender:target-0");
            dc.put("SCSIid", "360a980004265656d5f4a2d63764e5735");
            SR sr = SR.create(conn, host, dc, 0L, "sdk-gfs2-sr", "GFS2 SR created by the SDK example",
                "gfs2", "user", true, new java.util.HashMap<>());
            System.out.println("Created SR: " + sr.getUuid(conn) + " (" + sr.getPhysicalSize(conn) / GiB + " GiB)");
            sr.forget(conn);
            System.out.println("OK: create-gfs2-sr");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   createGfs2Sr("https://xenserver", "root", password);

    // --- 52. Create an ISO library SR --------------------------------------------------
    private static void createIsoSr(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Host host = Host.getAllRecords(conn).keySet().iterator().next();
            Map<String, String> dc = new java.util.HashMap<>();
            dc.put("location", "192.0.2.10:/isos");
            dc.put("type", "nfs_iso");
            SR sr = SR.create(conn, host, dc, 0L, "sdk-iso-sr", "ISO library created by the SDK example",
                "iso", "iso", true, new java.util.HashMap<>());
            System.out.println("Created ISO SR: " + sr.getUuid(conn));
            sr.forget(conn);
            System.out.println("OK: create-iso-sr");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   createIsoSr("https://xenserver", "root", password);

    // --- 53. Configure NRPE monitoring -------------------------------------------------
    private static void configureNrpe(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Host host = Host.getAllRecords(conn).keySet().iterator().next();
            System.out.println("NRPE status before: " + host.callPlugin(conn, "nrpe", "status", new java.util.HashMap<>()).trim());
            host.callPlugin(conn, "nrpe", "enable", new java.util.HashMap<>());
            Map<String, String> cfg = new java.util.HashMap<>();
            cfg.put("allowed_hosts", "127.0.0.1,::1,10.0.0.5");
            cfg.put("debug", "0");
            cfg.put("ssl_logging", "0x00");
            host.callPlugin(conn, "nrpe", "set-config", cfg);
            host.callPlugin(conn, "nrpe", "restart", new java.util.HashMap<>());
            System.out.println("NRPE status after:  " + host.callPlugin(conn, "nrpe", "status", new java.util.HashMap<>()).trim());
            for (String line : host.callPlugin(conn, "nrpe", "get-config", new java.util.HashMap<>()).split("\n")) {
                if (line.startsWith("allowed_hosts:"))
                    System.out.println("Allowed hosts: " + line.split(":", 2)[1].trim());
            }
            System.out.println("OK: configure-nrpe");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   configureNrpe("https://xenserver", "root", password);

    // --- 54. Configure SNMP monitoring -------------------------------------------------
    private static void configureSnmp(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Host host = Host.getAllRecords(conn).keySet().iterator().next();
            String config = "{\"common\":{\"enabled\":\"yes\",\"debug_log\":\"no\"},"
                + "\"agent\":{\"v2c\":\"yes\",\"v3\":\"no\",\"community\":\"sdk-community\",\"user_name\":\"\","
                + "\"authentication_password\":\"\",\"authentication_protocol\":\"\","
                + "\"privacy_password\":\"\",\"privacy_protocol\":\"\"},\"nmss\":[]}";
            Map<String, String> args = new java.util.HashMap<>();
            args.put("config", config);
            host.callPlugin(conn, "snmp", "set-config", args);
            String status = host.callPlugin(conn, "snmp", "status", new java.util.HashMap<>());
            String cfg = host.callPlugin(conn, "snmp", "get-config", new java.util.HashMap<>());
            System.out.println("SNMP enabled: " + jsonField(status, "enabled") + " / " + jsonField(status, "active"));
            System.out.println("Community: " + jsonField(cfg, "community"));
            System.out.println("OK: configure-snmp");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   configureSnmp("https://xenserver", "root", password);

    // --- Manage a vApp ---------------------------------------------------------------
    private static void manageVapp(String url, String user, String password, String vmName)
            throws Exception {
        Connection conn = connect(url, user, password);
        try {
            VM vm = VM.getByNameLabel(conn, vmName).iterator().next();

            VMAppliance.Record spec = new VMAppliance.Record();
            spec.nameLabel = "sdk-example-vapp";
            spec.nameDescription = "Created by the SDK example";
            VMAppliance vapp = VMAppliance.create(conn, spec);

            // `order` decides the sequence: ascending to start, descending to shut down. That ordering
            // is the reason to use a vApp rather than selecting several VMs.
            vm.setAppliance(conn, vapp);
            vm.setOrder(conn, 0L);
            vm.setStartDelay(conn, 5L);

            vapp.start(conn, false);
            System.out.println("Started:        " + vm.getPowerState(conn));

            vapp.cleanShutdown(conn);
            System.out.println("Shut down:      " + vm.getPowerState(conn));

            vm.setAppliance(conn, null);
            vapp.destroy(conn);
            System.out.println("OK: manage-vapp");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   manageVapp("https://xenserver", "root", password, "web-01");

    // --- Attach a USB device to a VM -------------------------------------------------
    private static void attachUsbDevice(String url, String user, String password, String vmName)
            throws Exception {
        Connection conn = connect(url, user, password);
        try {
            VM vm = VM.getByNameLabel(conn, vmName).iterator().next();

            Map.Entry<PUSB, PUSB.Record> entry =
                    PUSB.getAllRecords(conn).entrySet().iterator().next();
            System.out.println("Device:         " + entry.getValue().description);

            // Passthrough is off until an administrator releases the device: attaching one that has
            // not been released fails rather than silently doing nothing.
            entry.getKey().setPassthroughEnabled(conn, true);

            VUSB vusb = VUSB.create(conn, vm, entry.getValue().USBGroup,
                    new HashMap<String, String>());
            System.out.println("Attached:       " + vm.getVUSBs(conn).size() + " device(s)");

            vusb.destroy(conn);
            entry.getKey().setPassthroughEnabled(conn, false);
            System.out.println("OK: attach-usb-device");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   attachUsbDevice("https://xenserver", "root", password, "web-01");

    // --- Read workload-balancing recommendations -------------------------------------
    private static void wlbRecommendations(String url, String user, String password, String vmName)
            throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Pool.initializeWlb(conn, "https://wlb.example:8012", "wlbuser", "wlbpass", user, password);
            Pool pool = Pool.getAll(conn).iterator().next();
            System.out.println("WLB: " + pool.getWlbUrl(conn));

            // Other bindings read these BY POSITION -- [0] "wlb", [1] the destination host's UUID,
            // [2] and [3] ids, [4] the reason -- but Java CANNOT, and this is the one example where the
            // binding's type matters more than the API's.
            //
            // The datamodel declares the value as `Set String`, so this binding hands back a real
            // java.util.Set. Two things follow, and neither is visible from C#, whose binding uses
            // String[]: equal elements collapse, and iteration order is not the wire order. Indexing a
            // copy of the set returns whichever element happens to land there -- in testing, index 1 was
            // the reason and index 4 the "wlb" tag. So print the whole recommendation and let a human
            // read it; a program that needs the fields must use an ordered binding or the raw JSON.
            for (Map.Entry<VM, Set<String>> rec : Pool.retrieveWlbRecommendations(conn).entrySet()) {
                System.out.println("  move " + rec.getKey().getNameLabel(conn)
                        + ": " + String.join(" ", rec.getValue()));
            }

            // Same caveat for a VM's own recommendations, which are keyed by host.
            VM vm = VM.getByNameLabel(conn, vmName).iterator().next();
            for (Map.Entry<Host, Set<String>> rec : vm.retrieveWlbRecommendations(conn).entrySet()) {
                System.out.println("  " + rec.getKey().getNameLabel(conn)
                        + ": " + String.join(" ", rec.getValue()));
            }

            // The appliance's own settings are read and written as one flat map of strings. Send a
            // nightly reporting schedule, then read the configuration back to confirm it took.
            Map<String, String> wlbConfig = new HashMap<>();
            wlbConfig.put("ReportingCronString", "0 3 * * *");
            Pool.sendWlbConfiguration(conn, wlbConfig);
            Map<String, String> config = new TreeMap<>(Pool.retrieveWlbConfiguration(conn));
            StringBuilder cfgStr = new StringBuilder();
            for (Map.Entry<String, String> kv : config.entrySet()) {
                if (cfgStr.length() > 0) cfgStr.append(", ");
                cfgStr.append(kv.getKey()).append("=").append(kv.getValue());
            }
            System.out.println("  appliance configuration: " + cfgStr);

            Pool.deconfigureWlb(conn);
            System.out.println("OK: wlb-recommendations");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   wlbRecommendations("https://xenserver", "root", password, "web-01");

    // --- Configure clustering (GFS2) -------------------------------------------------
    private static void configureClustering(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // Clustering is what shared block storage needs before GFS2 thin provisioning. Pick a
            // network every host can reach: corosync is latency-sensitive, and a cluster that loses
            // quorum takes its GFS2 storage offline with it.
            Network network = Network.getAll(conn).iterator().next();

            Set<Cluster> existing = Cluster.getAll(conn);
            Cluster cluster = existing.isEmpty()
                    ? Cluster.poolCreate(conn, network, "corosync", 20000.0, 1000.0)
                    : existing.iterator().next();

            System.out.println("Stack:      " + cluster.getClusterStack(conn));
            System.out.println("Quorate:    " + cluster.getIsQuorate(conn)
                    + " (" + cluster.getLiveHosts(conn) + "/" + cluster.getQuorum(conn) + " needed)");

            // Taking a host out is what a management-interface change does; it can cost quorum.
            ClusterHost member = ClusterHost.getAll(conn).iterator().next();
            member.disable(conn);
            System.out.println("One member out, quorate: " + cluster.getIsQuorate(conn));

            member.enable(conn);
            cluster.poolResync(conn);
            System.out.println("Resynced,   quorate: " + cluster.getIsQuorate(conn));

            System.out.println("OK: configure-clustering");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   configureClustering("https://xenserver", "root", password);

    // --- Manage pool membership ------------------------------------------------------
    private static void managePoolMembership(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Pool pool = Pool.getAll(conn).iterator().next();
            Host original = pool.getMaster(conn);
            System.out.println("Coordinator: " + original.getNameLabel(conn));

            Host other = null;
            for (Host h : Host.getAll(conn)) {
                System.out.println("  member: " + h.getNameLabel(conn)
                        + (h.equals(original) ? " (coordinator)" : ""));
                if (!h.equals(original)) other = h;
            }

            // Promote another member. The pool database moves with the role and clients are redirected,
            // so this briefly interrupts management traffic — it does not move any VM.
            Pool.designateNewMaster(conn, other);
            System.out.println("Promoted:    " + other.getNameLabel(conn));

            // Put it back. Ejecting a member (Pool.eject) is the other half of this surface and is
            // deliberately not shown: it cannot be undone from the pool, because rejoining is initiated
            // by the ejected host.
            Pool.designateNewMaster(conn, original);
            System.out.println("Restored:    " + original.getNameLabel(conn));

            System.out.println("OK: manage-pool-membership");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   managePoolMembership("https://xenserver", "root", password);

    // --- Create a NIC bond -----------------------------------------------------------
    private static void createBond(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Host xenHost = Host.getAll(conn).iterator().next();

            // Pick up any NIC racked since the host booted. Cheap, and without it a card added a moment
            // ago is not there to bond.
            PIF.scan(conn, xenHost);

            // Spare NICs only. A bond that includes the management interface moves the management
            // address onto the bond master — on a real host that is how you lose your connection.
            Set<PIF> spares = new LinkedHashSet<PIF>();
            for (Map.Entry<PIF, PIF.Record> e : PIF.getAllRecords(conn).entrySet()) {
                if (e.getValue().host.equals(xenHost) && !e.getValue().management && e.getValue().physical
                        && spares.size() < 2) {
                    spares.add(e.getKey());
                }
            }
            StringBuilder devices = new StringBuilder();
            for (PIF p : spares) devices.append(devices.length() > 0 ? ", " : "").append(p.getDevice(conn));
            System.out.println("Bonding:      " + devices);

            // The bond needs a network to sit on.
            Network.Record netSpec = new Network.Record();
            netSpec.nameLabel = "sdk-example-bond";
            netSpec.nameDescription = "Created by the SDK example";
            netSpec.otherConfig = new HashMap<String, String>();
            Network network = Network.create(conn, netSpec);

            Bond bond = Bond.create(conn, network, spares, "", Types.BondMode.BALANCE_SLB);
            System.out.println("Bond master:  " + bond.getMaster(conn).getDevice(conn));
            System.out.println("Mode:         " + bond.getMode(conn));

            bond.destroy(conn);
            network.destroy(conn);
            System.out.println("Bonds left:   " + Bond.getAll(conn).size());
            System.out.println("OK: create-bond");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   createBond("https://xenserver", "root", password);

    // --- Configure PVS Accelerator ---
    private static void configurePvsAccelerator(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            PVSSite site = PVSSite.introduce(conn, "sdk-pvs-farm", "Created by the SDK examples", "");
            PVSServer.introduce(conn, new java.util.HashSet<>(java.util.Arrays.asList("10.62.0.90")),
                6910L, 6930L, site);

            // The read cache must be on LOCAL storage. The point of the accelerator is to keep reads off
            // the network, so a cache on a shared SR would defeat it and the server rejects one.
            for (Host host : Host.getAll(conn)) {
                SR local = localSr(conn, host);
                if (local == null) continue;
                PVSCacheStorage.Record cache = new PVSCacheStorage.Record();
                cache.host = host;
                cache.SR = local;
                cache.site = site;
                cache.size = 10L * 1024 * 1024 * 1024;
                PVSCacheStorage.create(conn, cache);
            }

            // A proxy may only sit on the VM's LOWEST-numbered NIC, so sort by device rather than taking
            // the first VIF — the set comes back unordered, so "the first one" means nothing here.
            Map.Entry<VM, VM.Record> guest = firstUnacceleratedGuest(conn);
            VIF first = null;
            int lowest = Integer.MAX_VALUE;
            for (VIF vif : guest.getValue().VIFs) {
                int device = Integer.parseInt(vif.getDevice(conn));
                if (device < lowest) { lowest = device; first = vif; }
            }
            PVSProxy proxy = PVSProxy.create(conn, site, first);

            PVSSite.Record record = site.getRecord(conn);
            System.out.printf("Site '%s' with %d cache(s) and %d server(s)%n",
                record.nameLabel, record.cacheStorage.size(), record.servers.size());
            // "caching" means it is actually accelerating. A site with no cache storage reports
            // "initialised", and a proxy on a VM whose NIC is unplugged reports "stopped".
            System.out.printf("  %s: %s%n", guest.getValue().nameLabel, proxy.getStatus(conn));

            // Forgetting the site takes its servers, caches and proxies with it.
            site.forget(conn);
            System.out.println("OK: configure-pvs-accelerator");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   configurePvsAccelerator("https://xenserver", "root", password);

    /** The host's own non-ISO storage, found through its PBDs. */
    private static SR localSr(Connection conn, Host host) throws Exception {
        for (PBD pbd : host.getPBDs(conn)) {
            SR sr = pbd.getSR(conn);
            SR.Record r = sr.getRecord(conn);
            if (!r.shared && !"iso".equals(r.contentType) && r.type != null && !r.type.equals("udev"))
                return sr;
        }
        return null;
    }

    /**
     * A running guest with a NIC that no proxy already covers. A VIF can carry only one proxy, so a VM
     * the pool already accelerates fails with PVS_PROXY_ALREADY_PRESENT.
     */
    private static Map.Entry<VM, VM.Record> firstUnacceleratedGuest(Connection conn) throws Exception {
        java.util.Set<String> taken = new java.util.HashSet<>();
        for (PVSProxy proxy : PVSProxy.getAll(conn))
            taken.add(proxy.getVIF(conn).getVM(conn).toWireString());
        for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
            VM.Record v = e.getValue();
            if (v.isATemplate || v.isControlDomain || v.isASnapshot) continue;
            if (v.powerState != Types.VmPowerState.RUNNING || v.VIFs.isEmpty()) continue;
            if (taken.contains(e.getKey().toWireString())) continue;
            return e;
        }
        throw new Exception("no unaccelerated running guest with a NIC");
    }

    // --- Manage SSH access ---
    private static void manageSshAccess(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Pool pool = Pool.getAll(conn).iterator().next();

            // Timed access is the point: set the timeout first and the server stamps an expiry when SSH
            // is enabled, so a window opened for troubleshooting closes itself.
            for (Host host : Host.getAll(conn)) host.setSshEnabledTimeout(conn, 3600L);

            // The pool call fans out to every host, so there is no need to loop for the enable itself.
            pool.enableSsh(conn);
            for (Host.Record record : Host.getAllRecords(conn).values())
                System.out.printf("%s: ssh enabled=%b, expires %tFT%<tTZ%n",
                    record.nameLabel, record.sshEnabled, record.sshExpiry);

            pool.disableSsh(conn);
            StringBuilder after = new StringBuilder();
            for (Host.Record record : Host.getAllRecords(conn).values()) {
                if (after.length() > 0) after.append(", ");
                after.append(record.nameLabel).append("=").append(record.sshEnabled);
            }
            System.out.println("After disable: " + after);
            System.out.println("OK: manage-ssh-access");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   manageSshAccess("https://xenserver", "root", password);

    // --- Change control domain memory ---
    private static void controlDomainMemory(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Host host = Host.getAll(conn).iterator().next();
            VM dom0 = null;
            for (VM vm : host.getResidentVMs(conn))
                if (vm.getIsControlDomain(conn)) { dom0 = vm; break; }
            if (dom0 == null) throw new Exception("the host reports no control domain");

            long original = dom0.getMemoryDynamicMin(conn);
            System.out.printf("%s dom0: %.1f GiB%n", host.getNameLabel(conn),
                original / (double) (1024L * 1024 * 1024));

            // One setter, not a range: dom0 does not balloon, so setMemory pins the static and dynamic
            // bounds and the target together. The new size takes effect at the next reboot, which is why
            // XenCenter offers this only in maintenance mode — the API itself does not stop you.
            dom0.setMemory(conn, original + 1024L * 1024 * 1024);
            VM.Record record = dom0.getRecord(conn);
            System.out.printf("  now %.1f GiB (static %d-%d, dynamic %d-%d)%n",
                record.memoryDynamicMin / (double) (1024L * 1024 * 1024),
                record.memoryStaticMin, record.memoryStaticMax,
                record.memoryDynamicMin, record.memoryDynamicMax);

            dom0.setMemory(conn, original);   // leave the pool as we found it
            System.out.println("OK: control-domain-memory");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   controlDomainMemory("https://xenserver", "root", password);

    // --- Manage a vTPM ---
    private static void manageVtpm(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            VM vm = null;
            VM.Record record = null;
            for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
                VM.Record v = e.getValue();
                if (!v.isATemplate && !v.isControlDomain && !v.isASnapshot
                        && v.powerState == Types.VmPowerState.HALTED && v.VTPMs.isEmpty()) {
                    vm = e.getKey(); record = v; break;
                }
            }
            if (vm == null) throw new Exception("no halted VM without a vTPM");
            System.out.println("Attaching a vTPM to " + record.nameLabel);

            // isUnique=false: the vTPM may be copied along with the VM. A VM may have at most one, and
            // it can only be attached while Halted — the device is presented at boot.
            VTPM vtpm = VTPM.create(conn, vm, false);
            VTPM.Record vtpmRecord = vtpm.getRecord(conn);
            System.out.println("  persistence backend: " + vtpmRecord.persistenceBackend);
            System.out.println("  unique to this VM:   " + vtpmRecord.isUnique);
            System.out.println("  VM now has " + vm.getVTPMs(conn).size() + " vTPM(s)");

            // The VM advertises whether another can be added; once it has one, it cannot.
            System.out.println("  can add another:     "
                + vm.getAllowedOperations(conn).contains(Types.VmOperations.CREATE_VTPM));

            vtpm.destroy(conn);
            System.out.println("  after removal:       " + vm.getVTPMs(conn).size() + " vTPM(s)");
            System.out.println("OK: manage-vtpm");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   manageVtpm("https://xenserver", "root", password);

    // --- Back up with changed block tracking ---
    private static void changedBlockTracking(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            VM vm = null;
            VM.Record record = null;
            for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
                VM.Record v = e.getValue();
                if (!v.isATemplate && !v.isControlDomain && !v.isASnapshot && !v.VBDs.isEmpty()) {
                    vm = e.getKey(); record = v; break;
                }
            }
            if (vm == null) throw new Exception("no VM with a disk");
            System.out.println("Backing up " + record.nameLabel);

            VM first = vm.snapshot(conn, "cbt-backup-1");
            VM second = vm.snapshot(conn, "cbt-backup-2");
            VDI vdiFrom = firstDisk(conn, first);
            VDI vdiTo = firstDisk(conn, second);
            vdiFrom.enableCbt(conn);
            vdiTo.enableCbt(conn);

            // One bit per 64 KiB block, base64-encoded; bit N set means block N changed. A real backup
            // reads only those blocks, over NBD.
            byte[] bitmap = java.util.Base64.getDecoder().decode(vdiFrom.listChangedBlocks(conn, vdiTo));
            int changed = 0;
            for (byte b : bitmap) changed += Integer.bitCount(b & 0xFF);
            System.out.printf("  %d blocks of %d changed (%.1f MiB to copy, not %.1f MiB)%n",
                changed, bitmap.length * 8, changed * 64 / 1024.0,
                vdiTo.getVirtualSize(conn) / (1024.0 * 1024));

            // Release the older snapshot's blocks but keep its change metadata, so the next incremental
            // can still diff against it. The VDI record stays; its type changes.
            vdiFrom.dataDestroy(conn);
            System.out.printf("  older snapshot is now type=%s, still cbt_enabled=%b%n",
                vdiFrom.getType(conn), vdiFrom.getCbtEnabled(conn));

            first.destroy(conn);
            second.destroy(conn);
            System.out.println("OK: changed-block-tracking");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   changedBlockTracking("https://xenserver", "root", password);

    /** The VDI behind a VM's first real disk (a CD drive is a VBD too). */
    private static VDI firstDisk(Connection conn, VM vm) throws Exception {
        for (VBD vbd : vm.getVBDs(conn))
            if (vbd.getType(conn) == Types.VbdType.DISK)
                return vbd.getVDI(conn);
        throw new Exception("no disk found");
    }

    // --- Export and import a VM ---
    private static void exportImportVm(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // Only a halted VM can be exported: its disks must not be changing underneath the copy.
            VM vm = null;
            VM.Record record = null;
            for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
                VM.Record v = e.getValue();
                if (!v.isATemplate && !v.isControlDomain && !v.isASnapshot
                        && v.powerState == Types.VmPowerState.HALTED) {
                    vm = e.getKey(); record = v; break;
                }
            }
            if (vm == null) throw new Exception("no halted VM to export");
            System.out.println("Exporting " + record.nameLabel);

            // Export and import are HTTP transfers alongside the API, not API calls, so the session id
            // travels in the query string.
            String session = conn.getSessionReference();
            java.io.File file = java.io.File.createTempFile("sdk-example-export", ".xva");
            HttpGet get = new HttpGet(url + "/export?session_id=" + session + "&uuid=" + vm.getUuid(conn));
            try (CloseableHttpClient http = trustingHttpClient()) {
                byte[] archive = http.execute(get, resp -> EntityUtils.toByteArray(resp.getEntity()));
                java.nio.file.Files.write(file.toPath(), archive);
                System.out.printf("  wrote %.1f MiB to %s%n", archive.length / (1024.0 * 1024), file.getName());
            }

            // An XVA is a tar: ova.xml describes the VM, and the disk blocks follow in 1 MiB pieces, each
            // with its own checksum.
            java.util.List<String> names = tarNames(file);
            long blocks = names.stream().filter(n -> !n.endsWith(".checksum")).count() - 1;
            System.out.printf("  archive holds %s and %d disk block(s)%n", names.get(0), blocks);

            String imported;
            HttpPut put = new HttpPut(url + "/import?session_id=" + session);
            put.setEntity(new org.apache.hc.core5.http.io.entity.ByteArrayEntity(
                java.nio.file.Files.readAllBytes(file.toPath()), null));
            try (CloseableHttpClient http = trustingHttpClient()) {
                imported = http.execute(put, resp -> EntityUtils.toString(resp.getEntity())).trim();
            }
            VM importedVm = new VM(imported);   // the response body is the new VM's reference
            System.out.println("  imported as " + importedVm.getNameLabel(conn));

            importedVm.destroy(conn);
            file.delete();
            System.out.println("OK: export-import-vm");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   exportImportVm("https://xenserver", "root", password);

    /**
     * The names of a tar archive's entries.
     *
     * Read with the format's own layout rather than a library: the name is the first 100 bytes of each
     * 512-byte header, the size is octal at offset 124, and every file is padded up to the next 512-byte
     * boundary. Small enough to do here, and it keeps the example free of another dependency.
     */
    private static java.util.List<String> tarNames(java.io.File file) throws Exception {
        java.util.List<String> names = new java.util.ArrayList<>();
        try (java.io.DataInputStream in = new java.io.DataInputStream(
                new java.io.BufferedInputStream(new java.io.FileInputStream(file)))) {
            byte[] header = new byte[512];
            while (in.read(header) == 512) {
                String name = new String(header, 0, 100, java.nio.charset.StandardCharsets.US_ASCII)
                    .trim().replace("\0", "");
                if (name.isEmpty()) break;                      // the end-of-archive marker
                names.add(name);
                String octal = new String(header, 124, 12, java.nio.charset.StandardCharsets.US_ASCII)
                    .trim().replace("\0", "");
                long size = octal.isEmpty() ? 0 : Long.parseLong(octal, 8);
                in.skipBytes((int) ((size + 511) / 512 * 512));
            }
        }
        return names;
    }

    // --- Configure dynamic memory ---
    private static void configureDynamicMemory(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            VM vm = null;
            VM.Record before = null;
            for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
                VM.Record v = e.getValue();
                if (!v.isATemplate && !v.isControlDomain && !v.isASnapshot
                        && v.powerState == Types.VmPowerState.HALTED) {
                    vm = e.getKey(); before = v; break;
                }
            }
            if (vm == null) throw new Exception("no halted VM");
            System.out.printf("%s: static %s-%s, dynamic %s-%s%n", before.nameLabel,
                    gib(before.memoryStaticMin), gib(before.memoryStaticMax),
                    gib(before.memoryDynamicMin), gib(before.memoryDynamicMax));

            // Room to balloon: let the host squeeze the VM down to a quarter of its maximum, but never
            // below the static floor, which is the least the guest can boot in.
            long floor = Math.max(before.memoryStaticMin, before.memoryStaticMax / 4);
            long ceiling = before.memoryStaticMax;
            vm.setMemoryDynamicRange(conn, floor, ceiling);
            System.out.printf("  dynamic range now %s-%s%n",
                    gib(vm.getMemoryDynamicMin(conn)), gib(vm.getMemoryDynamicMax(conn)));

            // The ordering is enforced, not advisory: a range wider than the static bounds is refused
            // rather than quietly clamped.
            try {
                vm.setMemoryDynamicRange(conn, floor, ceiling * 2);
                System.out.println("  ERROR: an out-of-range maximum was accepted");
            } catch (Types.XenAPIException e) {
                System.out.println("  refused a dynamic_max above static_max: " + e.shortDescription);
            }

            vm.setMemoryDynamicRange(conn, before.memoryDynamicMin, before.memoryDynamicMax);
            System.out.println("OK: configure-dynamic-memory");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   configureDynamicMemory("https://xenserver", "root", password);

    private static String gib(long bytes) {
        return String.format("%.1f GiB", bytes / (1024.0 * 1024 * 1024));
    }

    // --- Manage a VM's CD drive ---
    private static void manageVmMedia(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            VM vm = null;
            VM.Record record = null;
            for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
                VM.Record v = e.getValue();
                if (!v.isATemplate && !v.isControlDomain && !v.isASnapshot
                        && v.powerState == Types.VmPowerState.HALTED) {
                    vm = e.getKey(); record = v; break;
                }
            }
            if (vm == null) throw new Exception("no halted VM");
            System.out.println("Adding a DVD drive to " + record.nameLabel);

            // A CD drive is a VBD like any other, distinguished by type=CD; the media is whichever VDI it
            // points at, and an empty drive points at none.
            String device = vm.getAllowedVBDDevices(conn).iterator().next();
            VBD.Record spec = new VBD.Record();
            spec.VM = vm;
            spec.VDI = new VDI("OpaqueRef:NULL");
            spec.userdevice = device;
            spec.bootable = false;
            spec.mode = Types.VbdMode.RO;
            spec.type = Types.VbdType.CD;
            spec.empty = true;
            spec.unpluggable = true;
            spec.otherConfig = new HashMap<String, String>();
            spec.qosAlgorithmType = "";
            spec.qosAlgorithmParams = new HashMap<String, String>();
            VBD drive = VBD.create(conn, spec);
            System.out.println("  drive " + device + " is empty: " + drive.getEmpty(conn));

            // The ISO library is an SR of content type "iso"; its VDIs are the available images.
            SR isoSr = null;
            for (Map.Entry<SR, SR.Record> e : SR.getAllRecords(conn).entrySet())
                if ("iso".equals(e.getValue().contentType) && !"udev".equals(e.getValue().type)) {
                    isoSr = e.getKey(); break;
                }
            if (isoSr == null) throw new Exception("no ISO library");
            java.util.List<VDI> images = new java.util.ArrayList<VDI>(isoSr.getVDIs(conn));
            java.util.Map<VDI, String> names = new HashMap<VDI, String>();
            for (VDI image : images) names.put(image, image.getNameLabel(conn));
            images.sort(java.util.Comparator.comparing(names::get));
            VDI iso = images.get(0);
            System.out.println("  inserting " + names.get(iso));
            drive.insert(conn, iso);
            System.out.println("  drive now holds " + drive.getVDI(conn).getNameLabel(conn)
                    + " (empty=" + drive.getEmpty(conn) + ")");

            drive.eject(conn);
            System.out.println("  after eject, empty=" + drive.getEmpty(conn));

            drive.destroy(conn);
            System.out.println("OK: manage-vm-media");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   manageVmMedia("https://xenserver", "root", password);

    // --- Back up a host's configuration ---
    private static void backupHostConfig(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            java.util.List<Host> hosts = new java.util.ArrayList<Host>(Host.getAll(conn));
            Host host = hosts.get(0);
            System.out.println("Backing up " + host.getNameLabel(conn));

            // Backup and restore are HTTP transfers alongside the API, not API calls, so the session id
            // travels in the query string.
            String session = conn.getSessionReference();
            java.io.File file = java.io.File.createTempFile("sdk-example-host", ".backup");
            HttpGet get = new HttpGet(url + "/host_backup?session_id=" + session
                    + "&ref=" + host.toWireString());
            byte[] backup;
            try (CloseableHttpClient http = trustingHttpClient()) {
                backup = http.execute(get, resp -> EntityUtils.toByteArray(resp.getEntity()));
            }
            java.nio.file.Files.write(file.toPath(), backup);
            System.out.printf("  wrote %d bytes to %s%n", backup.length, file.getName());

            System.out.println("  restoring it to " + host.getNameLabel(conn) + ": "
                    + restoreHostConfig(conn, url, session, host, backup));
            if (hosts.size() > 1) {
                // The refusal is the half worth rehearsing: restoring one host's configuration onto
                // another is destructive and unrecoverable, so the pool checks rather than trusting
                // the caller.
                Host other = hosts.get(1);
                System.out.println("  restoring it to " + other.getNameLabel(conn) + ": "
                        + restoreHostConfig(conn, url, session, other, backup));
            }

            file.delete();
            System.out.println("OK: backup-host-config");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   backupHostConfig("https://xenserver", "root", password);

    /**
     * Uploads a backup to a host and reports what the task says about it.
     *
     * An upload answers 200 as soon as it has read the request headers, because the client waits for
     * that before it starts sending the file. The outcome therefore cannot be in the status line: it
     * arrives on a task you create first, name in the URL, and poll once the upload has finished.
     */
    private static String restoreHostConfig(Connection conn, String url, String session,
                                            Host host, byte[] backup) throws Exception {
        Task task = Task.create(conn, "host_restore", "restoring a configuration backup");
        try {
            HttpPut put = new HttpPut(url + "/host_restore?session_id=" + session
                    + "&ref=" + host.toWireString() + "&task_id=" + task.toWireString());
            put.setEntity(new org.apache.hc.core5.http.io.entity.ByteArrayEntity(backup, null));
            try (CloseableHttpClient http = trustingHttpClient()) {
                http.execute(put, resp -> EntityUtils.toString(resp.getEntity()));
            }

            while (task.getStatus(conn) == Types.TaskStatusType.PENDING) Thread.sleep(500);
            if (task.getStatus(conn) == Types.TaskStatusType.SUCCESS) return "accepted";
            // error_info is declared as a SET of strings, and the Java binding hands back a real Set - so
            // there is no "last element" to read the detail from. Print it whole rather than indexing
            // into something unordered; see the WLB example, where guessing at an order silently lied.
            return "refused " + task.getErrorInfo(conn);
        } finally {
            task.destroy(conn);
        }
    }

    // --- Detach, reattach and forget storage ---
    private static void manageSrLifecycle(String url, String user, String password,
            String nfsServer, String nfsPath) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // There is no "detach" call on an SR. A shared SR is joined to each host by one PBD - a
            // physical block device - and detaching the SR means unplugging every one of them. That is
            // why an SR can be attached on some hosts and not others, and why a repair action exists at
            // all: it plugs back the PBDs that are missing.
            Host host = Host.getAll(conn).iterator().next();
            Map<String, String> deviceConfig = new java.util.HashMap<>();
            deviceConfig.put("server", nfsServer);
            deviceConfig.put("serverpath", nfsPath);
            deviceConfig.put("nfsversion", "3");
            SR sr = SR.create(conn, host, deviceConfig, 0L,
                "sdk-example-lifecycle", "SR used by the SDK lifecycle example",
                "nfs", "user", true, new java.util.HashMap<>());

            java.util.List<PBD> pbds = new java.util.ArrayList<>(sr.getPBDs(conn));
            System.out.printf("%s: connected on %d of %d host(s)%n",
                sr.getNameLabel(conn), attachedPbds(conn, pbds), pbds.size());

            for (PBD pbd : pbds) pbd.unplug(conn);
            System.out.printf("  detached:   connected on %d host(s)%n", attachedPbds(conn, pbds));

            // Plugging them back is exactly what a repair does.
            for (PBD pbd : pbds) pbd.plug(conn);
            System.out.printf("  reattached: connected on %d host(s)%n", attachedPbds(conn, pbds));

            sr.scan(conn);
            System.out.printf("  rescanned:  %d disk(s)%n", sr.getVDIs(conn).size());

            // Forgetting drops the pool's record of the SR but leaves the storage itself untouched, so
            // the same export can be introduced again later. Detach before forgetting: a connected SR
            // is still in use.
            for (PBD pbd : pbds) pbd.unplug(conn);
            sr.forget(conn);
            System.out.println("  forgotten");
            System.out.println("OK: manage-sr-lifecycle");
        } finally {
            Session.logout(conn);
        }
    }

    /** How many of these connections are currently live. */
    private static int attachedPbds(Connection conn, java.util.List<PBD> pbds) throws Exception {
        int live = 0;
        for (PBD pbd : pbds) if (pbd.getCurrentlyAttached(conn)) live++;
        return live;
    }
    // Run it:
    //   manageSrLifecycle("https://xenserver", "root", password, "192.0.2.10", "/export/spare");

    // --- Set the pool's default storage ---
    private static void setDefaultSr(String url, String user, String password,
            String nfsServer, String nfsPath) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Pool pool = Pool.getAll(conn).iterator().next();

            // Capture all three separately. New disks land on the default SR, a suspended VM's memory
            // image goes to the suspend-image SR and host crash dumps to the crash-dump SR. They are
            // usually the same storage but need not be, and a pool that has never suspended or crashed
            // anything can legitimately leave the latter two unset - so restoring all three from the
            // default would quietly invent settings that were not there.
            SR before = pool.getDefaultSR(conn);
            SR beforeSuspend = pool.getSuspendImageSR(conn);
            SR beforeCrash = pool.getCrashDumpSR(conn);
            System.out.println("default storage:  " + srLabel(conn, before));
            System.out.println("  suspend images: " + srLabel(conn, beforeSuspend));
            System.out.println("  crash dumps:    " + srLabel(conn, beforeCrash));

            // Somewhere to switch to. A pool default has to be reachable from every host, so it is a
            // shared SR; a local one would strand any VM whose disk landed on the wrong host.
            Map<String, String> deviceConfig = new java.util.HashMap<>();
            deviceConfig.put("server", nfsServer);
            deviceConfig.put("serverpath", nfsPath);
            deviceConfig.put("nfsversion", "3");
            SR sr = SR.create(conn, Host.getAll(conn).iterator().next(), deviceConfig, 0L,
                "sdk-example-default", "SR used by the SDK default-storage example",
                "nfs", "user", true, new java.util.HashMap<>());

            pool.setDefaultSR(conn, sr);
            pool.setSuspendImageSR(conn, sr);
            pool.setCrashDumpSR(conn, sr);
            System.out.println("  switched to:    " + srLabel(conn, pool.getDefaultSR(conn)));

            // Restore the original choice before tidying up: an SR that is still the pool default is
            // the awkward one to remove.
            pool.setDefaultSR(conn, before);
            pool.setSuspendImageSR(conn, beforeSuspend);
            pool.setCrashDumpSR(conn, beforeCrash);
            for (PBD pbd : sr.getPBDs(conn)) pbd.unplug(conn);
            sr.forget(conn);
            System.out.println("  restored to:    " + srLabel(conn, pool.getDefaultSR(conn)));
            System.out.println("OK: set-default-sr");
        } finally {
            Session.logout(conn);
        }
    }

    /** An SR's name, tolerating the null reference an unset pool field holds. */
    private static String srLabel(Connection conn, SR sr) throws Exception {
        if (sr == null || sr.toWireString() == null || sr.toWireString().equals("OpaqueRef:NULL"))
            return "(none)";
        return sr.getNameLabel(conn);
    }
    // Run it:
    //   setDefaultSr("https://xenserver", "root", password, "192.0.2.10", "/export/spare");

    // --- Collect a server status report ---
    private static void serverStatusReport(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // Report on the coordinator. Each host answers for itself, so which one you ask decides
            // whose logs you get - support normally wants every host, one download each.
            Host host = Pool.getAll(conn).iterator().next().getMaster(conn);
            System.out.println("Status report for " + host.getNameLabel(conn));

            // The host publishes a catalogue of the sections it can report on, each with a size
            // estimate and whether it may contain personal data, so a client can offer an informed
            // choice rather than hard-coding the list.
            org.w3c.dom.NodeList capabilities = javax.xml.parsers.DocumentBuilderFactory.newInstance()
                .newDocumentBuilder()
                .parse(new org.xml.sax.InputSource(new java.io.StringReader(
                    host.getSystemStatusCapabilities(conn))))
                .getElementsByTagName("capability");
            java.util.List<String> keys = new java.util.ArrayList<>();
            for (int i = 0; i < capabilities.getLength(); i++) {
                org.w3c.dom.Element capability = (org.w3c.dom.Element) capabilities.item(i);
                keys.add(capability.getAttribute("key"));
                System.out.printf("  %-22s max %9s bytes  default=%-3s pii=%s%n",
                    capability.getAttribute("key"), capability.getAttribute("max-size"),
                    capability.getAttribute("default-checked"), capability.getAttribute("pii"));
            }

            // The download is an HTTP transfer alongside the API, so the session id travels in the
            // query string.
            String session = conn.getSessionReference();
            int whole = fetchStatusReport(url, session, keys);
            System.out.printf("everything (%d sections): %d bytes%n", keys.size(), whole);

            // Worth checking rather than assuming: a server that ignored the selection would look
            // identical from here until someone opened the archive and found the whole thing.
            int subset = fetchStatusReport(url, session, java.util.Arrays.asList("xenserver-config"));
            System.out.printf("xenserver-config only:   %d bytes%n", subset);
            if (subset >= whole)
                System.out.println("  ERROR: selecting fewer sections did not produce a smaller bundle");

            System.out.println("OK: server-status-report");
        } finally {
            Session.logout(conn);
        }
    }

    /** Downloads the bundle for the given capability keys (a tar archive) and reports its size. */
    private static int fetchStatusReport(String url, String session,
                                         java.util.List<String> entries) throws Exception {
        HttpGet get = new HttpGet(url + "/system-status?session_id=" + session + "&output=tar"
            + "&entries=" + String.join(",", entries));
        try (CloseableHttpClient http = trustingHttpClient()) {
            return http.execute(get, resp -> EntityUtils.toByteArray(resp.getEntity())).length;
        }
    }
    // Run it:
    //   serverStatusReport("https://xenserver", "root", password);

    // --- Recover VMs after a disaster ---
    private static void disasterRecovery(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // Disaster recovery works by writing the pool's own database out to a storage repository as a
            // disk of type "metadata". That disk can be read back as a SEPARATE database, so the ordinary
            // calls describe the pool as it was replicated rather than the pool you are connected to.
            //
            // Replication needs storage every host can reach and that can hold data. The server checks
            // rather than taking your word for it, so ask before enabling.
            SR sr = null;
            for (Map.Entry<SR, SR.Record> e : SR.getAllRecords(conn).entrySet()) {
                SR.Record r = e.getValue();
                if (r.shared && !"iso".equals(r.contentType)
                        && r.type != null && !r.type.equals("iso") && !r.type.equals("udev")) {
                    sr = e.getKey(); break;
                }
            }
            if (sr == null) throw new RuntimeException("no shared data SR to replicate to");
            sr.assertSupportsDatabaseReplication(conn);
            System.out.println("Replicating pool metadata to " + sr.getNameLabel(conn));
            sr.enableDatabaseReplication(conn);

            VDI metadataVdi = null;
            for (VDI v : sr.getVDIs(conn))
                if (v.getType(conn) == Types.VdiType.METADATA) { metadataVdi = v; break; }
            System.out.println("  metadata disk: " + metadataVdi.getUuid(conn));

            Session metadata = metadataVdi.openDatabase(conn);

            // The generated classes always send the Connection's own session, so reading the replicated
            // database means dispatching by hand with the metadata session in its place. Connection
            // .dispatch is the binding's own entry point, so this still goes over the trusting HTTP
            // client that connect() set up.
            Map<VM, VM.Record> recoverable = conn.dispatch("VM.get_all_records",
                new Object[]{metadata.toWireString()},
                new com.fasterxml.jackson.core.type.TypeReference<Map<VM, VM.Record>>() {});
            System.out.printf("  the replicated database describes %d recoverable VM(s)%n", recoverable.size());

            VM target = null;
            String name = null;
            for (Map.Entry<VM, VM.Record> e : recoverable.entrySet())
                if (name == null || e.getValue().nameLabel.compareTo(name) < 0) {
                    target = e.getKey(); name = e.getValue().nameLabel;
                }
            System.out.println("  recovering " + name);

            // Both calls run on the METADATA session; the live one says where the VM should land.
            conn.<Object>dispatch("VM.assert_can_be_recovered",
                new Object[]{metadata.toWireString(), target.toWireString(), conn.getSessionReference()});
            conn.<Object>dispatch("VM.recover",
                new Object[]{metadata.toWireString(), target.toWireString(), conn.getSessionReference(), false});

            // It is a real VM in the live pool now, not merely a call that returned.
            for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet())
                if (name.equals(e.getValue().nameLabel)) {
                    System.out.printf("  %s is %s in the live pool%n", name, e.getValue().powerState);
                    e.getKey().destroy(conn);
                    break;
                }

            sr.disableDatabaseReplication(conn);
            System.out.println("OK: disaster-recovery");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   disasterRecovery("https://xenserver", "root", password);

    // --- Manage Secure Boot certificates ---
    private static void manageSecurebootCertificates(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            Pool pool = Pool.getAll(conn).iterator().next();

            // A Secure Boot guest carries its own copy of the pool's UEFI certificates, taken when it
            // was created. Rotating the pool's leaves the guest's stale, and the fix is applied at the
            // guest's next boot rather than underneath a running VM - so you flag it and reboot when
            // convenient.
            //
            // First, whether the pool holds the certificates to hand out at all. "ready_no_dbx" means it
            // has the essentials but no revocation list - usable, and not the same answer as "ready".
            System.out.println("Pool Secure Boot readiness: " + pool.getGuestSecurebootReadiness(conn));
            System.out.println("  pool holds certificates:  "
                + !pool.getUefiCertificates(conn).isEmpty());

            // A guest whose certificates have gone stale. Its state is what a client gates the
            // flag/unflag actions on, so it is the field to watch.
            VM vm = null;
            String name = null;
            for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
                VM.Record r = e.getValue();
                if (!r.isATemplate && !r.isControlDomain && !r.isASnapshot
                        && r.securebootCertificatesState == Types.VmSecurebootCertificatesState.UPDATE_AVAILABLE) {
                    vm = e.getKey(); name = r.nameLabel; break;
                }
            }
            if (vm == null) throw new RuntimeException("no guest has a pending certificate update");
            System.out.printf("%s: readiness %s, certificates %s%n", name,
                vm.getSecurebootReadiness(conn), vm.getSecurebootCertificatesState(conn));

            // Flagging and unflagging are the same call with opposite booleans.
            vm.updateSecurebootCertificatesOnBoot(conn, true);
            System.out.println("  flagged for refresh:      " + vm.getSecurebootCertificatesState(conn));

            vm.updateSecurebootCertificatesOnBoot(conn, false);
            System.out.println("  unflagged:                " + vm.getSecurebootCertificatesState(conn));

            System.out.println("OK: manage-secureboot-certificates");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   manageSecurebootCertificates("https://xenserver", "root", password);

    // --- Restart a host ---
    private static void restartHost(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // Rebooting a host is never just the reboot: anything running on it has to go somewhere
            // first, and the host has to stop accepting new VMs while that happens.
            //
            // Not the coordinator: it is the host this session is talking to, and taking it down would
            // drop the connection underneath the rest of the example.
            Host coordinator = Pool.getAll(conn).iterator().next().getMaster(conn);
            Host host = null;
            for (Host h : Host.getAll(conn)) if (!h.equals(coordinator)) { host = h; break; }

            System.out.println("Restarting " + host.getNameLabel(conn));
            System.out.printf("  enabled=%s, guests=%d%n", host.getEnabled(conn), guestCount(conn, host));

            // Disabled means "accept no new VMs"; it does not move anything on its own.
            host.disable(conn);
            System.out.println("  disabled:   enabled=" + host.getEnabled(conn));

            // Evacuate moves the guests elsewhere in the pool. Afterwards only the control domain - the
            // host's own management VM, which cannot move - is left.
            host.evacuate(conn);
            System.out.printf("  evacuated:  guests=%d%n", guestCount(conn, host));

            host.reboot(conn);
            System.out.println("  rebooted:   enabled=" + host.getEnabled(conn));

            // The other ending: off, and back on out of band.
            host.shutdown(conn);
            System.out.println("  shut down:  live=" + host.getMetrics(conn).getLive(conn));
            host.powerOn(conn);
            System.out.println("  powered on: live=" + host.getMetrics(conn).getLive(conn));

            System.out.println("OK: restart-host");
        } finally {
            Session.logout(conn);
        }
    }

    /** Resident VMs excluding the control domain, which never moves. */
    private static int guestCount(Connection conn, Host host) throws Exception {
        int n = 0;
        for (VM vm : host.getResidentVMs(conn)) if (!vm.getIsControlDomain(conn)) n++;
        return n;
    }
    // Run it:
    //   restartHost("https://xenserver", "root", password);

    // --- Create a VM and a template from a snapshot ---
    private static void vmFromSnapshot(String url, String user, String password, String vmName)
            throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // A snapshot is a VM record with is_a_snapshot set, so both of these are clones of it - the
            // difference is only what you mark the result as.
            VM vm = vmByName(conn, vmName);
            VM snapshot = vm.snapshot(conn, "sdk-example-source-snapshot");
            System.out.println("Snapshot of " + vmName + " taken");

            // A clone of a snapshot is an ordinary VM. Worth reading back rather than assuming: a result
            // still flagged as a snapshot would be filed under the original VM instead of standing on
            // its own, and would not appear in a VM listing at all.
            VM newVm = snapshot.createClone(conn, "sdk-example-vm-from-snapshot");
            System.out.printf("  new VM:      %s (is_a_snapshot=%s)%n",
                newVm.getNameLabel(conn), newVm.getIsASnapshot(conn));

            // The same clone, marked as a template instead: a starting point to stamp more VMs from.
            VM template = snapshot.createClone(conn, "sdk-example-template-from-snapshot");
            template.setIsATemplate(conn, true);
            System.out.printf("  new template:%s (is_a_template=%s)%n",
                template.getNameLabel(conn), template.getIsATemplate(conn));

            newVm.destroy(conn);
            template.destroy(conn);
            snapshot.destroy(conn);
            System.out.println("OK: vm-from-snapshot");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   vmFromSnapshot("https://xenserver", "root", password, "db-01");

    // --- Attach an existing disk to another VM ---
    private static void attachExistingDisk(String url, String user, String password) throws Exception {
        final long GiB = 1024L * 1024 * 1024;
        Connection conn = connect(url, user, password);
        try {
            // A disk and the VM it belongs to are separate objects joined by a VBD, so moving a disk
            // between VMs is removing one VBD and creating another - no copying, and the data stays
            // exactly where it is.
            java.util.List<VM> halted = new java.util.ArrayList<>();
            for (Map.Entry<VM, VM.Record> e : VM.getAllRecords(conn).entrySet()) {
                VM.Record r = e.getValue();
                if (!r.isATemplate && !r.isControlDomain && !r.isASnapshot
                        && r.powerState == Types.VmPowerState.HALTED)
                    halted.add(e.getKey());
            }

            SR sr = null;
            for (Map.Entry<SR, SR.Record> e : SR.getAllRecords(conn).entrySet()) {
                SR.Record r = e.getValue();
                if (r.shared && !"iso".equals(r.contentType)
                        && r.type != null && !r.type.equals("iso") && !r.type.equals("udev")) {
                    sr = e.getKey(); break;
                }
            }

            VDI.Record vdiRecord = new VDI.Record();
            vdiRecord.nameLabel = "sdk-example-portable-disk";
            vdiRecord.SR = sr;
            vdiRecord.virtualSize = 4 * GiB;
            vdiRecord.type = Types.VdiType.USER;
            vdiRecord.sharable = false;
            vdiRecord.readOnly = false;
            vdiRecord.otherConfig = new java.util.HashMap<>();
            VDI vdi = VDI.create(conn, vdiRecord);
            System.out.printf("Disk %s created on %s%n", vdi.getNameLabel(conn), sr.getNameLabel(conn));

            VBD vbd = attachVdi(conn, halted.get(0), vdi);
            System.out.println("  attached to " + halted.get(0).getNameLabel(conn));

            // Destroying the VBD detaches the disk; the disk itself is untouched and keeps its data.
            vbd.destroy(conn);
            System.out.printf("  detached:   the disk still exists (%d bytes)%n", vdi.getVirtualSize(conn));

            attachVdi(conn, halted.get(1), vdi);
            System.out.println("  attached to " + halted.get(1).getNameLabel(conn));
            System.out.printf("  the disk is on %d VM(s)%n", vdi.getVBDs(conn).size());

            for (VBD b : vdi.getVBDs(conn)) b.destroy(conn);
            vdi.destroy(conn);
            System.out.println("OK: attach-existing-disk");
        } finally {
            Session.logout(conn);
        }
    }

    /** Join an existing disk to a VM on its next free device slot. */
    private static VBD attachVdi(Connection conn, VM vm, VDI vdi) throws Exception {
        VBD.Record record = new VBD.Record();
        record.VM = vm;
        record.VDI = vdi;
        record.userdevice = vm.getAllowedVBDDevices(conn).iterator().next();
        record.mode = Types.VbdMode.RW;
        record.type = Types.VbdType.DISK;
        record.empty = false;
        record.otherConfig = new java.util.HashMap<>();
        record.qosAlgorithmType = "";
        record.qosAlgorithmParams = new java.util.HashMap<>();
        return VBD.create(conn, record);
    }
    // Run it:
    //   attachExistingDisk("https://xenserver", "root", password);

    // --- Clear a host's crash dumps ---
    private static void manageCrashDumps(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // When a host crashes it writes a dump to its local disk and keeps it. They are large,
            // nothing cleans them up, and a host that has crashed more than once accumulates them - so
            // clearing them once support has what it needs is ordinary housekeeping. They belong to the
            // host that wrote them, so clear them a host at a time.
            Host host = null;
            Set<HostCrashdump> dumps = null;
            for (Host h : Host.getAll(conn)) {
                Set<HostCrashdump> d = h.getCrashdumps(conn);
                if (!d.isEmpty()) { host = h; dumps = d; break; }
            }
            if (host == null) {
                System.out.println("No crash dumps in this pool - nothing to clear.");
                System.out.println("OK: manage-crash-dumps");
                return;
            }

            System.out.printf("%s has %d crash dump(s)%n", host.getNameLabel(conn), dumps.size());
            long total = 0;
            java.text.SimpleDateFormat stamp = new java.text.SimpleDateFormat("yyyyMMdd'T'HH:mm:ss'Z'");
            stamp.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
            for (HostCrashdump dump : dumps) {
                HostCrashdump.Record record = dump.getRecord(conn);
                total += record.size;
                System.out.printf("  %s  %s%n", stamp.format(record.timestamp), mib(record.size));
            }
            System.out.printf("  %s in total%n", mib(total));

            // Deleting a dump frees the space on the host; the host itself is untouched.
            for (HostCrashdump dump : dumps) dump.destroy(conn);
            System.out.printf("  cleared:  %s now has %d%n",
                host.getNameLabel(conn), host.getCrashdumps(conn).size());

            System.out.println("OK: manage-crash-dumps");
        } finally {
            Session.logout(conn);
        }
    }

    private static String mib(long size) { return (size / (1024 * 1024)) + " MiB"; }
    // Run it:
    //   manageCrashDumps("https://xenserver", "root", password);

    // --- Configure pool options -------------------------------------------------------
    private static void configurePoolOptions(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // None of these is a wizard: they are plain pool settings that a client exposes on a
            // properties page, and each is a single field. Read them, change them, put them back.
            Pool pool = Pool.getAll(conn).iterator().next();

            boolean beforeLivePatching = pool.getLivePatchingDisabled(conn);
            boolean beforeIgmp = pool.getIgmpSnoopingEnabled(conn);
            boolean beforeMigrationCompression = pool.getMigrationCompression(conn);
            System.out.printf("  %-22s %s%n", "live patching disabled", beforeLivePatching);
            System.out.printf("  %-22s %s%n", "IGMP snooping", beforeIgmp);
            System.out.printf("  %-22s %s%n", "migration compression", beforeMigrationCompression);

            // Live patching applies host updates without a reboot; disabling it forces the reboot.
            pool.setLivePatchingDisabled(conn, !beforeLivePatching);
            // IGMP snooping keeps multicast off ports that did not ask for it.
            pool.setIgmpSnoopingEnabled(conn, !beforeIgmp);
            // Compression trades CPU for bandwidth when a VM's memory is moved between hosts.
            pool.setMigrationCompression(conn, !beforeMigrationCompression);

            System.out.println("after changing:");
            System.out.printf("  %-22s %s%n", "live patching disabled", pool.getLivePatchingDisabled(conn));
            System.out.printf("  %-22s %s%n", "IGMP snooping", pool.getIgmpSnoopingEnabled(conn));
            System.out.printf("  %-22s %s%n", "migration compression", pool.getMigrationCompression(conn));

            pool.setLivePatchingDisabled(conn, beforeLivePatching);
            pool.setIgmpSnoopingEnabled(conn, beforeIgmp);
            pool.setMigrationCompression(conn, beforeMigrationCompression);
            System.out.println("  restored");
            System.out.println("OK: configure-pool-options");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   configurePoolOptions("https://xenserver", "root", password);

    // --- Configure console access -----------------------------------------------------
    private static void configureConsoleAccess(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // Idle console sessions are set at two levels - the pool's own management consoles and the
            // VM consoles it serves - and a host can override the pool's. Requiring HTTPS refuses plain
            // HTTP to the management interface altogether.
            Pool pool = Pool.getAll(conn).iterator().next();
            Host host = pool.getMaster(conn);

            // NB: pool.https_only and pool.console_idle_timeout are SET below but never read back. SDK
            // 26.14 generates a setter and no getter for both (unlike host.console_idle_timeout, which
            // has both), so they cannot be read through the typed bindings at all - and a sample that
            // reached past its own binding to show a value would be teaching a workaround rather than
            // the API.
            System.out.printf("  %-26s %ss%n", "VM console idle timeout", pool.getVmConsoleIdleTimeout(conn));
            System.out.printf("  %-26s %s%n", "limit console sessions", pool.getLimitConsoleSessions(conn));
            System.out.printf("  %-26s %ss%n", "host console idle timeout", host.getConsoleIdleTimeout(conn));

            // Ten minutes of inactivity, one console session at a time, and no plain HTTP.
            pool.setConsoleIdleTimeout(conn, 600L);
            pool.setVmConsoleIdleTimeout(conn, 600L);
            pool.setLimitConsoleSessions(conn, true);
            host.setConsoleIdleTimeout(conn, 300L);
            pool.setHttpsOnly(conn, true);

            System.out.println("after tightening:");
            System.out.printf("  %-26s %ss%n", "VM console idle timeout", pool.getVmConsoleIdleTimeout(conn));
            System.out.printf("  %-26s %s%n", "limit console sessions", pool.getLimitConsoleSessions(conn));
            System.out.printf("  %-26s %ss%n", "host console idle timeout", host.getConsoleIdleTimeout(conn));

            pool.setHttpsOnly(conn, false);
            pool.setConsoleIdleTimeout(conn, 0L);
            pool.setVmConsoleIdleTimeout(conn, 0L);
            pool.setLimitConsoleSessions(conn, false);
            host.setConsoleIdleTimeout(conn, 0L);
            System.out.println("  restored");
            System.out.println("OK: configure-console-access");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   configureConsoleAccess("https://xenserver", "root", password);

    // --- Configure host storage --------------------------------------------------------
    private static void configureHostStorage(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // The IQN identifies this host to iSCSI targets, so a target's access list is written
            // against it - changing it on a host with live iSCSI storage cuts it off. Multipathing uses
            // every path to the storage rather than one, and on real hardware you put the host into
            // maintenance mode before changing it, because the paths are rebuilt.
            Host host = Pool.getAll(conn).iterator().next().getMaster(conn);

            String beforeIqn = host.getIscsiIqn(conn);
            boolean beforeMultipathing = host.getMultipathing(conn);
            System.out.println(host.getNameLabel(conn) + ": iSCSI IQN '" + beforeIqn
                    + "', multipathing " + beforeMultipathing);

            host.setIscsiIqn(conn, "iqn.2026-01.com.example:" + host.getNameLabel(conn));
            host.setMultipathing(conn, true);
            System.out.println("  IQN now:      " + host.getIscsiIqn(conn));
            System.out.println("  multipathing: " + host.getMultipathing(conn));

            host.setIscsiIqn(conn, beforeIqn);
            host.setMultipathing(conn, beforeMultipathing);
            System.out.println("  restored");
            System.out.println("OK: configure-host-storage");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   configureHostStorage("https://xenserver", "root", password);

    // --- Configure remote syslog -------------------------------------------------------
    private static void configureSyslog(String url, String user, String password, String syslogServer)
            throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // Two steps, and the second is the one that is easy to miss: setting the destination only
            // records it, and the host keeps logging locally until the syslog daemon is reconfigured to
            // pick the setting up.
            Host host = Pool.getAll(conn).iterator().next().getMaster(conn);

            Map<String, String> logging = host.getLogging(conn);
            System.out.println(host.getNameLabel(conn) + " logging: "
                    + (logging.isEmpty() ? "(local only)" : logging));

            host.removeFromLogging(conn, "syslog_destination");
            host.addToLogging(conn, "syslog_destination", syslogServer);
            host.syslogReconfigure(conn);
            System.out.println("  now logging to: " + host.getLogging(conn).get("syslog_destination"));

            host.removeFromLogging(conn, "syslog_destination");
            host.syslogReconfigure(conn);
            Map<String, String> after = host.getLogging(conn);
            System.out.println("  restored: " + (after.isEmpty() ? "(local only)" : after));
            System.out.println("OK: configure-syslog");
        } finally {
            Session.logout(conn);
        }
    }
    // Run it:
    //   configureSyslog("https://xenserver", "root", password);

    // --- Manage driver variants ---------------------------------------------------------
    private static void manageDriverVariants(String url, String user, String password) throws Exception {
        Connection conn = connect(url, user, password);
        try {
            // A driver can ship in several variants - a vendor build alongside the one in the
            // distribution, say. One is SELECTED (what the host will load) and one is ACTIVE (what it
            // has loaded); they differ until the host reboots, which is what makes selecting a variant a
            // scheduled change rather than an immediate one.
            Host host = Pool.getAll(conn).iterator().next().getMaster(conn);

            java.util.List<Map.Entry<HostDriver, HostDriver.Record>> drivers = new java.util.ArrayList<>();
            for (Map.Entry<HostDriver, HostDriver.Record> e : HostDriver.getAllRecords(conn).entrySet())
                if (e.getValue().host.equals(host)) drivers.add(e);
            drivers.sort(java.util.Comparator.comparing(e -> e.getValue().name));
            System.out.println(host.getNameLabel(conn) + " has " + drivers.size() + " driver(s)");
            for (Map.Entry<HostDriver, HostDriver.Record> e : drivers.subList(0, Math.min(3, drivers.size()))) {
                HostDriver.Record d = e.getValue();
                System.out.printf("  %-14s %-10s %d variant(s), active=%s%n",
                    d.name, d.type, d.variants.size(), variantName(conn, d.activeVariant));
            }

            // Select a variant explicitly. It becomes the selected one immediately; whether it is also
            // active depends on whether the hardware is present and the driver already loaded.
            Map.Entry<HostDriver, HostDriver.Record> first = drivers.get(0);
            DriverVariant variant = first.getValue().variants.iterator().next();
            first.getKey().select(conn, variant);
            HostDriver.Record after = first.getKey().getRecord(conn);
            System.out.printf("  %s: selected %s, active %s%n",
                after.name, variantName(conn, after.selectedVariant), variantName(conn, after.activeVariant));

            System.out.println("OK: manage-driver-variants");
        } finally {
            Session.logout(conn);
        }
    }

    /** A driver variant's name, tolerating the null reference an unloaded driver has. */
    private static String variantName(Connection conn, DriverVariant variant) throws Exception {
        if (variant == null || variant.toWireString() == null
                || variant.toWireString().equals("OpaqueRef:NULL"))
            return "(none)";
        return variant.getName(conn);
    }
    // Run it:
    //   manageDriverVariants("https://xenserver", "root", password);

    // --- end of workflows ---

    // Minimal extractor for a "key":"value" pair in the SNMP plugin's JSON reply (avoids a JSON dependency).
    private static String jsonField(String json, String key) {
        java.util.regex.Matcher m = java.util.regex.Pattern
            .compile("\"" + key + "\"\\s*:\\s*\"([^\"]*)\"").matcher(json);
        return m.find() ? m.group(1) : "";
    }

    // Maps the <workflow> argument to the matching self-contained method above, supplying the concrete
    // objects each one operates on. In your own code you would call these methods directly (see the
    // "Run it:" line under each) rather than through this dispatcher.
    public static void main(String[] args) throws Exception {
        // cross-pool-copy-vm spans two pools, so it takes an extra 5th argument: the destination URL.
        if (args.length >= 1 && args[0].equals("cross-pool-copy-vm")) {
            if (args.length != 5) {
                System.err.println("usage: java Workflows cross-pool-copy-vm <sourceUrl> <user> <password> <destUrl>");
                System.exit(2);
            }
            crossPoolCopyVm(args[1], args[2], args[3], args[4], "db-01");
            return;
        }
        if (args.length != 4) {
            System.err.println("usage: java Workflows <workflow> <url> <user> <password>");
            System.exit(2);
        }

        String url = args[1], user = args[2], password = args[3];
        switch (args[0]) {
            case "connect-inventory": connectInventory(url, user, password); break;
            case "create-vm": createVm(url, user, password, "Rocky Linux 8", "sdk-example-vm"); break;
            case "vm-lifecycle": vmLifecycle(url, user, password, "Rocky Linux 8", "sdk-example-lifecycle"); break;
            case "manage-vm-disks": manageVmDisks(url, user, password, "web-01"); break;
            case "dismiss-alerts": dismissAlerts(url, user, password); break;
            case "host-power-on": hostPowerOn(url, user, password); break;
            case "rotate-pool-secret": rotatePoolSecret(url, user, password); break;
            case "change-root-password": changeRootPassword(url, user, password); break;
            case "manage-certificates": manageCertificates(url, user, password); break;
            case "snapshot-schedule": snapshotSchedule(url, user, password, "web-01", "sdk-example-schedule"); break;
            case "manage-vm-groups": manageVmGroups(url, user, password, "web-01", "sdk-example-group"); break;
            case "snapshot-revert": snapshotRevert(url, user, password, "web-01", "sdk-example-snapshot"); break;
            case "create-nfs-sr": createNfsSr(url, user, password, "192.0.2.10", "/export/sdk", "sdk-example-nfs"); break;
            case "create-network": createNetwork(url, user, password, "sdk-example-net"); break;
            case "edit-vm-properties": editVmProperties(url, user, password, "web-01"); break;
            case "events": events(url, user, password, "web-01"); break;
            case "new-vm-wizard": newVmWizard(url, user, password, "Rocky Linux 8", "wizard-vm"); break;
            case "live-migrate": liveMigrate(url, user, password, "Rocky Linux 8", "sdk-example-migrate"); break;
            case "host-maintenance": hostMaintenance(url, user, password, "Rocky Linux 8", "sdk-example-maint"); break;
            case "configure-ha": configureHa(url, user, password, "Shared NFS"); break;
            case "copy-vm": copyVm(url, user, password, "db-01", "Shared NFS", "sdk-example-copy"); break;
            case "create-vm-with-vgpu": createVmWithVgpu(url, user, password, "Rocky Linux 8", "sdk-example-vgpu-vm"); break;
            case "tags-and-folders": tagsAndFolders(url, user, password, "web-01"); break;
            case "configure-updates": configureUpdates(url, user, password); break;
            case "clone-vm": cloneVm(url, user, password, "db-01", "sdk-example-clone"); break;
            case "delete-vm": deleteVm(url, user, password, "Rocky Linux 8", "sdk-example-delete"); break;
            case "storage-migrate": storageMigrate(url, user, password, "Rocky Linux 8", "sdk-example-storagemigrate"); break;
            case "apply-update": applyUpdate(url, user, password); break;
            case "checkpoint-vm": checkpointVm(url, user, password, "Rocky Linux 8", "sdk-example-checkpoint"); break;
            case "attach-disk": attachDisk(url, user, password, "Rocky Linux 8", "Shared NFS", "sdk-example-attachdisk"); break;
            case "wait-for-task": waitForTask(url, user, password, "Rocky Linux 8", "sdk-example-asynctask"); break;
            case "error-handling": errorHandling(url, user, password); break;
            case "list-templates": listTemplates(url, user, password); break;
            case "custom-fields": customFields(url, user, password, "web-01"); break;
            case "gpu-inventory": gpuInventory(url, user, password); break;
            case "read-metrics": readMetrics(url, user, password); break;
            case "rename-object": renameObject(url, user, password, "web-01"); break;
            case "vm-boot-config": vmBootConfig(url, user, password, "Rocky Linux 8", "sdk-example-boot"); break;
            case "host-info": hostInfo(url, user, password); break;
            case "list-roles": listRoles(url, user, password); break;
            case "pool-properties": poolProperties(url, user, password); break;
            case "sr-usage": srUsage(url, user, password); break;
            case "manage-vif": manageVif(url, user, password, "Rocky Linux 8", "sdk-example-vif"); break;
            case "list-networks": listNetworks(url, user, password); break;
            case "vbd-inventory": vbdInventory(url, user, password, "db-01"); break;
            case "pool-tags": poolTags(url, user, password); break;
            case "convert-to-template": convertToTemplate(url, user, password, "Rocky Linux 8", "sdk-example-totemplate"); break;
            case "find-by-uuid": findByUuid(url, user, password, "web-01"); break;
            case "rolling-pool-update": rollingPoolUpdate(url, user, password); break;
            case "pvs-accelerator": pvsAccelerator(url, user, password); break;
            case "configure-pvs-accelerator": configurePvsAccelerator(url, user, password); break;
            case "manage-ssh-access": manageSshAccess(url, user, password); break;
            case "manage-vtpm": manageVtpm(url, user, password); break;
            case "export-import-vm": exportImportVm(url, user, password); break;
            case "configure-dynamic-memory": configureDynamicMemory(url, user, password); break;
            case "manage-vm-media": manageVmMedia(url, user, password); break;
            case "backup-host-config": backupHostConfig(url, user, password); break;
            case "manage-sr-lifecycle":
                manageSrLifecycle(url, user, password, "192.0.2.10", "/export/spare"); break;
            case "set-default-sr":
                setDefaultSr(url, user, password, "192.0.2.10", "/export/spare"); break;
            case "server-status-report": serverStatusReport(url, user, password); break;
            case "disaster-recovery": disasterRecovery(url, user, password); break;
            case "manage-secureboot-certificates":
                manageSecurebootCertificates(url, user, password); break;
            case "restart-host": restartHost(url, user, password); break;
            case "manage-crash-dumps": manageCrashDumps(url, user, password); break;
            case "vm-from-snapshot": vmFromSnapshot(url, user, password, "db-01"); break;
            case "attach-existing-disk": attachExistingDisk(url, user, password); break;
            case "changed-block-tracking": changedBlockTracking(url, user, password); break;
            case "control-domain-memory": controlDomainMemory(url, user, password); break;
            case "rrd-metrics": rrdMetrics(url, user, password); break;
            case "reclaim-space": reclaimSpace(url, user, password); break;
            case "vm-ip-address": vmIpAddress(url, user, password); break;
            case "manage-ad-users": manageAdUsers(url, user, password); break;
            case "create-iscsi-sr": createIscsiSr(url, user, password); break;
            case "create-smb-sr": createSmbSr(url, user, password); break;
            case "create-hba-sr": createHbaSr(url, user, password); break;
            case "create-gfs2-sr": createGfs2Sr(url, user, password); break;
            case "create-iso-sr": createIsoSr(url, user, password); break;
            case "configure-nrpe": configureNrpe(url, user, password); break;
            case "configure-snmp": configureSnmp(url, user, password); break;
            case "configure-clustering": configureClustering(url, user, password); break;
            case "manage-pool-membership": managePoolMembership(url, user, password); break;
            case "create-bond": createBond(url, user, password); break;
            case "manage-vapp": manageVapp(url, user, password, "web-01"); break;
            case "attach-usb-device": attachUsbDevice(url, user, password, "web-01"); break;
            case "wlb-recommendations": wlbRecommendations(url, user, password, "web-01"); break;
            case "configure-pool-options": configurePoolOptions(url, user, password); break;
            case "configure-console-access": configureConsoleAccess(url, user, password); break;
            case "configure-host-storage": configureHostStorage(url, user, password); break;
            case "configure-syslog": configureSyslog(url, user, password, "192.0.2.50"); break;
            case "manage-driver-variants": manageDriverVariants(url, user, password); break;
            default:
                System.err.println("unknown workflow: " + args[0]);
                System.exit(2);
        }
    }
}
