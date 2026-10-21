// XenServer Go SDK - real-world workflow examples.
//
// Each example mirrors a task you would perform in XenCenter, driven through the XenServer
// Management API (XenAPI). The Go binding speaks JSON-RPC and skips certificate validation
// by default for https URLs, which suits a host with a self-signed certificate.
//
// Every example is self-contained: it takes the connection details (and any object it acts on,
// looked up by name) as parameters, opens its own session and logs out when done - so you can copy
// one out and run it on its own; see the "Run it:" line under each. The dispatcher in main() is only
// what lets this one file run any of them from the command line.
//
// Usage:
//   go run . <workflow> <url> <username> <password>
//
//   <workflow>  any workflow id from the dispatcher (see also README.md)
package main

import (
	"archive/tar"
	"bytes"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"math/bits"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"go/xenapi"
)

// --- connect ---
func connect(url, user, password string) *xenapi.Session {
	session, err := login(url, user, password)
	if err == nil {
		return session
	}
	// A pool member names the coordinator's address; reconnect there (assuming the coordinator is up),
	// exactly as XenCenter does when you add a member server.
	coordinator := coordinatorFromSlaveError(err)
	if coordinator == "" {
		panic(err)
	}
	session, err = login("https://"+coordinator, user, password)
	if err != nil {
		panic(err)
	}
	return session
}

func login(url, user, password string) (*xenapi.Session, error) {
	session := xenapi.NewSession(&xenapi.ClientOpts{URL: url})
	_, err := session.LoginWithPassword(user, password, "1.0", "sdk-examples")
	return session, err
}

// coordinatorFromSlaveError returns the coordinator address carried by a HOST_IS_SLAVE error, or "".
// The Go binding surfaces API errors as a formatted string, rendering the error's data slice (the full
// XenAPI description, [code, ...params]) as "data [HOST_IS_SLAVE <addr>]" - so we recognise the code and
// take the address, which is the last element of that slice.
func coordinatorFromSlaveError(err error) string {
	msg := err.Error()
	if !strings.Contains(msg, xenapi.ErrorHostIsSlave) {
		return ""
	}
	if m := regexp.MustCompile(`data \[(.+)\]`).FindStringSubmatch(msg); m != nil {
		if fields := strings.Fields(m[1]); len(fields) > 0 {
			return fields[len(fields)-1]
		}
	}
	return ""
}

func check(err error) {
	if err != nil {
		panic(err)
	}
}

// templateByName finds a template VM by its exact name (rather than picking an arbitrary one).
func templateByName(session *xenapi.Session, name string) xenapi.VMRef {
	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	for ref, vm := range vms {
		if vm.IsATemplate && vm.NameLabel == name {
			return ref
		}
	}
	panic(fmt.Sprintf("no template named %q was found", name))
}

// vmByName finds a guest VM (not a template, control domain or snapshot) by its exact name.
func vmByName(session *xenapi.Session, name string) xenapi.VMRef {
	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	for ref, vm := range vms {
		if !vm.IsATemplate && !vm.IsControlDomain && !vm.IsASnapshot && vm.NameLabel == name {
			return ref
		}
	}
	panic(fmt.Sprintf("no VM named %q was found", name))
}

// srByName finds an SR by its exact name (optionally requiring it to be shared).
func srByName(session *xenapi.Session, name string, shared bool) xenapi.SRRef {
	srs, err := xenapi.SR.GetAllRecords(session)
	check(err)
	for ref, sr := range srs {
		if sr.NameLabel == name && (!shared || sr.Shared) {
			return ref
		}
	}
	panic(fmt.Sprintf("no SR named %q was found", name))
}

// --- 1. Connect & inventory ------------------------------------------------------------
func connectInventory(url, user, password string) {
	session := connect(url, user, password)
	pools, err := xenapi.Pool.GetAllRecords(session)
	check(err)
	for _, pool := range pools {
		fmt.Printf("Connected to pool: %s\n", pool.NameLabel)
		break
	}

	hosts, err := xenapi.Host.GetAllRecords(session)
	check(err)
	fmt.Printf("Hosts (%d):\n", len(hosts))
	for _, host := range hosts {
		fmt.Printf("  - %s (%s)\n", host.NameLabel, host.Address)
	}

	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	count := 0
	for _, vm := range vms {
		if !vm.IsATemplate && !vm.IsControlDomain {
			count++
			fmt.Printf("  - %s [%s]\n", vm.NameLabel, vm.PowerState)
		}
	}
	fmt.Printf("VMs (%d)\n", count)

	fmt.Println("OK: connect-inventory")
	session.Logout()
}

// Run it:
//   connectInventory("https://xenserver", "root", password)

// --- 2. Create a VM from a template ----------------------------------------------------
func createVM(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	templateRef := templateByName(session, templateName)
	name, _ := xenapi.VM.GetNameLabel(session, templateRef)
	fmt.Printf("Using template: %s\n", name)

	vmRef, err := xenapi.VM.Clone(session, templateRef, newVMName)
	check(err)
	uuid, _ := xenapi.VM.GetUUID(session, vmRef)
	fmt.Printf("Cloned new VM: %s\n", uuid)

	check(xenapi.VM.Provision(session, vmRef))
	isTemplate, _ := xenapi.VM.GetIsATemplate(session, vmRef)
	fmt.Printf("Provisioned. is_a_template = %v\n", isTemplate)

	check(xenapi.VM.Destroy(session, vmRef))
	fmt.Println("Cleaned up the example VM.")

	fmt.Println("OK: create-vm")
	session.Logout()
}

// Run it:
//   createVM("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-vm")

// --- 3. VM power lifecycle -------------------------------------------------------------
func vmLifecycle(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	// Power operations are destructive, so work on a throwaway VM cloned from the template.
	vmRef, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	check(xenapi.VM.Provision(session, vmRef))

	state := func() xenapi.VMPowerState {
		s, _ := xenapi.VM.GetPowerState(session, vmRef)
		return s
	}

	fmt.Printf("Initial power state: %s\n", state())
	check(xenapi.VM.Start(session, vmRef, false, true))
	fmt.Printf("After start:    %s\n", state())

	// The emulated hardware (the device model) can be restarted under a running guest without
	// rebooting it - what you reach for when the VM's virtual devices misbehave.
	check(xenapi.VM.RestartDeviceModels(session, vmRef))
	fmt.Printf("Device models restarted; still %s\n", state())

	check(xenapi.VM.Suspend(session, vmRef))
	fmt.Printf("After suspend:  %s\n", state())
	check(xenapi.VM.Resume(session, vmRef, false, true))
	fmt.Printf("After resume:   %s\n", state())
	check(xenapi.VM.CleanShutdown(session, vmRef))
	fmt.Printf("After shutdown: %s\n", state())

	check(xenapi.VM.Destroy(session, vmRef))
	fmt.Println("OK: vm-lifecycle")
	session.Logout()
}

// Run it:
//   vmLifecycle("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-lifecycle")

// --- 4. Manage VM disks: Deactivate / Resize / Activate ------------------------------
func manageVMDisks(url, user, password, vmName string) {
	session := connect(url, user, password)
	vmRef := vmByName(session, vmName)

	// The VM's first real disk (a CD drive is a VBD too, hence the type filter).
	vbds, err := xenapi.VM.GetVBDs(session, vmRef)
	check(err)
	var vbdRef xenapi.VBDRef
	for _, v := range vbds {
		if kind, _ := xenapi.VBD.GetType(session, v); kind == xenapi.VbdTypeDisk {
			vbdRef = v
			break
		}
	}
	vdiRef, err := xenapi.VBD.GetVDI(session, vbdRef)
	check(err)
	attached, _ := xenapi.VBD.GetCurrentlyAttached(session, vbdRef)
	fmt.Printf("Disk attached:  %t\n", attached)

	// Deactivate = VBD.unplug. The disk stays with the VM; it is just no longer live.
	check(xenapi.VBD.Unplug(session, vbdRef))
	attached, _ = xenapi.VBD.GetCurrentlyAttached(session, vbdRef)
	fmt.Printf("After unplug:   %t\n", attached)

	size, err := xenapi.VDI.GetVirtualSize(session, vdiRef)
	check(err)
	check(xenapi.VDI.Resize(session, vdiRef, size*2))
	grown, _ := xenapi.VDI.GetVirtualSize(session, vdiRef)
	fmt.Printf("Resized:        %d -> %d bytes\n", size, grown)

	check(xenapi.VBD.Plug(session, vbdRef))
	attached, _ = xenapi.VBD.GetCurrentlyAttached(session, vbdRef)
	fmt.Printf("After plug:     %t\n", attached)

	// Growing a disk that is attached and live is a DIFFERENT call, not a flag on the same one:
	// ResizeOnline tells the storage layer the guest is using the disk while it grows.
	grownOnline := grown + 1024*1024*1024
	check(xenapi.VDI.ResizeOnline(session, vdiRef, grownOnline))
	final, _ := xenapi.VDI.GetVirtualSize(session, vdiRef)
	fmt.Printf("Grown online:   %d bytes\n", final)
	fmt.Println("OK: manage-vm-disks")
	session.Logout()
}

// --- Raise and dismiss alerts --------------------------------------------------------
func dismissAlerts(url, user, password string) {
	session := connect(url, user, password)
	messages, err := xenapi.Message.GetAllRecords(session)
	check(err)
	fmt.Printf("Alerts:         %d\n", len(messages))

	for ref, m := range messages {
		fmt.Printf("Dismissing:     %s (priority %d)\n", m.Name, m.Priority)
		check(xenapi.Message.Destroy(session, ref))
		left, _ := xenapi.Message.GetAllRecords(session)
		fmt.Printf("Alerts left:    %d\n", len(left))
		break
	}
	fmt.Println("OK: dismiss-alerts")
	session.Logout()
}

// --- Configure host power on ---------------------------------------------------------
func hostPowerOn(url, user, password string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	hostRef := hosts[0]

	// Mode and config travel together: the config carries the credentials the mode needs.
	check(xenapi.Host.SetPowerOnMode(session, hostRef, "iLO", map[string]string{
		"power_on_ip":   "192.0.2.9",
		"power_on_user": "poweradmin",
	}))
	mode, _ := xenapi.Host.GetPowerOnMode(session, hostRef)
	fmt.Printf("Power-on mode:  %s\n", mode)
	cfg, _ := xenapi.Host.GetPowerOnConfig(session, hostRef)
	for k, v := range cfg {
		fmt.Printf("  %s = %s\n", k, v)
	}

	check(xenapi.Host.SetPowerOnMode(session, hostRef, "", map[string]string{}))
	fmt.Println("OK: host-power-on")
	session.Logout()
}

// --- Rotate the pool secret ----------------------------------------------------------
func rotatePoolSecret(url, user, password string) {
	session := connect(url, user, password)
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	name, _ := xenapi.Pool.GetNameLabel(session, pools[0])
	fmt.Printf("Pool:           %s\n", name)

	// A pool-wide operation; existing sessions survive it.
	check(xenapi.Pool.RotateSecret(session))
	after, _ := xenapi.Pool.GetAll(session)
	fmt.Printf("Rotated. Still connected: %t\n", len(after) == 1)
	fmt.Println("OK: rotate-pool-secret")
	session.Logout()
}

// --- Change the root password --------------------------------------------------------
func changeRootPassword(url, user, password string) {
	session := connect(url, user, password)
	const temporary = "sdk-example-temp-password"

	// ChangePassword takes the OLD password as well as the new one, even though you are already
	// authenticated.
	check(session.ChangePassword(password, temporary))
	fmt.Println("Password changed.")

	// The existing session stays valid afterwards - only NEW connections need the new password.
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	fmt.Printf("Session still usable: %t\n", len(pools) == 1)

	// Supplying the wrong current password is the failure worth handling.
	if err := session.ChangePassword("definitely-not-it", "irrelevant"); err != nil {
		fmt.Printf("Wrong old password rejected: %s\n", err)
	} else {
		fmt.Println("unexpected: the wrong old password was accepted")
	}

	check(session.ChangePassword(temporary, password))
	fmt.Println("Password restored.")
	fmt.Println("OK: change-root-password")
	session.Logout()
}

// --- Manage TLS certificates ---------------------------------------------------------
func manageCertificates(url, user, password string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)

	certs, _ := xenapi.Certificate.GetAll(session)
	fmt.Printf("Certificates:   %d\n", len(certs))

	// A CA certificate is pool-wide; a server certificate belongs to one host.
	// Both take the certificate by NAME rather than by pool ref - they are inherently pool-wide.
	check(xenapi.Pool.InstallCaCertificate(session, "sdk-example-ca",
		"-----BEGIN CERTIFICATE-----sdk-example-----END CERTIFICATE-----"))
	certs, _ = xenapi.Certificate.GetAll(session)
	fmt.Printf("After CA add:   %d\n", len(certs))

	check(xenapi.Host.ResetServerCertificate(session, hosts[0]))
	fmt.Println("Host certificate reset (a fresh self-signed identity).")

	check(xenapi.Pool.UninstallCaCertificate(session, "sdk-example-ca", false))
	certs, _ = xenapi.Certificate.GetAll(session)
	fmt.Printf("After CA remove:%d\n", len(certs))

	// Separately from which certificates exist: whether the pool actually CHECKS the ones its members
	// present to each other. Turning it on is a one-way door from here - there is no matching disable,
	// because a pool that could be talked out of verifying would not be verifying - so the call is
	// idempotent and safe to repeat.
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	verifying, _ := xenapi.Pool.GetTLSVerificationEnabled(session, pools[0])
	fmt.Printf("TLS verification: %t\n", verifying)
	check(xenapi.Pool.EnableTLSVerification(session))
	verifying, _ = xenapi.Pool.GetTLSVerificationEnabled(session, pools[0])
	fmt.Printf("  after enabling: %t\n", verifying)
	fmt.Println("OK: manage-certificates")
	session.Logout()
}

// --- Snapshot schedule ---------------------------------------------------------------
func snapshotSchedule(url, user, password, vmName, scheduleName string) {
	session := connect(url, user, password)
	vmRef := vmByName(session, vmName)

	// RetainedSnapshots is the interesting field: the schedule prunes to it every time it runs.
	vmssRef, err := xenapi.VMSS.Create(session, xenapi.VMSSRecord{
		NameLabel:         scheduleName,
		NameDescription:   "Scheduled snapshots created by the SDK example",
		Enabled:           true,
		Type:              xenapi.VmssTypeSnapshot,
		Frequency:         xenapi.VmssFrequencyDaily,
		RetainedSnapshots: 2,
		Schedule:          map[string]string{"hour": "2", "min": "0"},
	})
	check(err)
	vmssUUID, _ := xenapi.VMSS.GetUUID(session, vmssRef)
	fmt.Printf("Created schedule: %s\n", vmssUUID)

	check(xenapi.VM.SetSnapshotSchedule(session, vmRef, vmssRef))
	members, _ := xenapi.VMSS.GetVMs(session, vmssRef)
	fmt.Printf("Members:          %d\n", len(members))

	// Run it three times against a retention of two: the oldest is pruned away.
	for i := 0; i < 3; i++ {
		_, err = xenapi.VMSS.SnapshotNow(session, vmssRef)
		check(err)
	}
	snaps, _ := xenapi.VM.GetSnapshots(session, vmRef)
	fmt.Printf("Snapshots kept:   %d (retention 2)\n", len(snaps))

	check(xenapi.VM.SetSnapshotSchedule(session, vmRef, "OpaqueRef:NULL"))
	check(xenapi.VMSS.Destroy(session, vmssRef))
	fmt.Println("OK: snapshot-schedule")
	session.Logout()
}

// --- Manage VM groups ----------------------------------------------------------------
func manageVMGroups(url, user, password, vmName, groupName string) {
	session := connect(url, user, password)
	vmRef := vmByName(session, vmName)

	// anti_affinity asks the pool to keep the group's members on different hosts.
	groupRef, err := xenapi.VMGroup.Create(session, xenapi.VMGroupRecord{
		NameLabel:       groupName,
		NameDescription: "Anti-affinity group created by the SDK example",
		Placement:       xenapi.PlacementPolicyAntiAffinity,
	})
	check(err)
	groupUUID, _ := xenapi.VMGroup.GetUUID(session, groupRef)
	fmt.Printf("Created group:  %s\n", groupUUID)

	// Membership is written from the VM side...
	check(xenapi.VM.SetGroups(session, vmRef, []xenapi.VMGroupRef{groupRef}))

	// ...and read back from the group side, which is the half that is easy to get wrong.
	members, err := xenapi.VMGroup.GetVMs(session, groupRef)
	check(err)
	fmt.Printf("Group members:  %d\n", len(members))
	for _, m := range members {
		name, _ := xenapi.VM.GetNameLabel(session, m)
		fmt.Printf("  %s\n", name)
	}

	check(xenapi.VM.SetGroups(session, vmRef, []xenapi.VMGroupRef{}))
	after, _ := xenapi.VMGroup.GetVMs(session, groupRef)
	fmt.Printf("After removal:  %d member(s)\n", len(after))

	check(xenapi.VMGroup.Destroy(session, groupRef))
	fmt.Println("OK: manage-vm-groups")
	session.Logout()
}

// --- Snapshot & revert ---------------------------------------------------------------
func snapshotRevert(url, user, password, vmName, snapshotName string) {
	session := connect(url, user, password)
	vmRef := vmByName(session, vmName)
	name, _ := xenapi.VM.GetNameLabel(session, vmRef)
	fmt.Printf("Snapshotting VM: %s\n", name)

	snapRef, err := xenapi.VM.Snapshot(session, vmRef, snapshotName, nil)
	check(err)
	uuid, _ := xenapi.VM.GetUUID(session, snapRef)
	fmt.Printf("Created snapshot: %s\n", uuid)

	check(xenapi.VM.Revert(session, snapRef))
	fmt.Println("Reverted VM to the snapshot.")

	// A client shows a thumbnail of what was on screen when the snapshot was taken. It is an HTTP
	// transfer alongside the API, not an API call, so the session id travels in the query string. The Go
	// binding keeps its own session private, so obtain one of our own the same way the RRD/export
	// examples do.
	sid := rawLogin(url, user, password)
	resp, err := insecureClient().Get(fmt.Sprintf("%s/vncsnapshot?session_id=%s&ref=%s", url, sid, snapRef))
	check(err)
	thumb, err := io.ReadAll(resp.Body)
	check(err)
	resp.Body.Close()
	fmt.Printf("Thumbnail:      %d bytes of PNG\n", len(thumb))

	// A snapshot is itself a (special) VM record; destroy it to clean up.
	check(xenapi.VM.Destroy(session, snapRef))
	fmt.Println("OK: snapshot-revert")
	session.Logout()
}

// Run it:
//   snapshotRevert("https://xenserver", "root", password, "web-01", "sdk-example-snapshot")

// --- 5. Create an NFS storage repository -----------------------------------------------
func createNfsSR(url, user, password, nfsServer, nfsPath, srName string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAllRecords(session)
	check(err)
	var hostRef xenapi.HostRef
	for ref := range hosts {
		hostRef = ref
		break
	}

	deviceConfig := map[string]string{
		"server":     nfsServer,
		"serverpath": nfsPath,
		"nfsversion": "3",
	}
	srRef, err := xenapi.SR.Create(session, hostRef, deviceConfig, 0,
		srName, "NFS SR created by the SDK example",
		"nfs", "user", true, map[string]string{})
	check(err)
	uuid, _ := xenapi.SR.GetUUID(session, srRef)
	fmt.Printf("Created SR: %s\n", uuid)

	check(xenapi.SR.Forget(session, srRef))
	fmt.Println("OK: create-nfs-sr")
	session.Logout()
}

// Run it:
//   createNfsSR("https://xenserver", "root", password, "192.0.2.10", "/export/sdk", "sdk-example-nfs")

// --- 6. Create a network ---------------------------------------------------------------
func createNetwork(url, user, password, networkName string) {
	session := connect(url, user, password)
	netRef, err := xenapi.Network.Create(session, xenapi.NetworkRecord{
		NameLabel:       networkName,
		NameDescription: "Internal network created by the SDK example",
		MTU:             1500,
		OtherConfig:     map[string]string{},
	})
	check(err)
	uuid, _ := xenapi.Network.GetUUID(session, netRef)
	fmt.Printf("Created network: %s\n", uuid)

	// Raise the MTU to use jumbo frames. Every NIC and switch along the path has to agree, so this is a
	// property of the network rather than of any one interface on it.
	check(xenapi.Network.SetMTU(session, netRef, 9000))
	mtu, _ := xenapi.Network.GetMTU(session, netRef)
	fmt.Printf("MTU now:         %d\n", mtu)

	check(xenapi.Network.Destroy(session, netRef))
	fmt.Println("OK: create-network")
	session.Logout()
}

// Run it:
//   createNetwork("https://xenserver", "root", password, "sdk-example-net")

// --- 7. Edit VM properties -------------------------------------------------------------
func editVMProperties(url, user, password, vmName string) {
	session := connect(url, user, password)
	vmRef := vmByName(session, vmName)

	originalDesc, _ := xenapi.VM.GetNameDescription(session, vmRef)
	check(xenapi.VM.SetNameDescription(session, vmRef, "Edited by the SDK example"))
	check(xenapi.VM.AddToOtherConfig(session, vmRef, "sdk_example", "true"))
	desc, _ := xenapi.VM.GetNameDescription(session, vmRef)
	fmt.Printf("New description: %s\n", desc)
	oc, _ := xenapi.VM.GetOtherConfig(session, vmRef)
	fmt.Printf("other_config[sdk_example] = %s\n", oc["sdk_example"])

	check(xenapi.VM.SetNameDescription(session, vmRef, originalDesc))
	check(xenapi.VM.RemoveFromOtherConfig(session, vmRef, "sdk_example"))
	fmt.Println("OK: edit-vm-properties")
	session.Logout()
}

// Run it:
//   editVMProperties("https://xenserver", "root", password, "web-01")

// --- 8. Event monitoring ---------------------------------------------------------------
func events(url, user, password, vmName string) {
	session := connect(url, user, password)
	classes := []string{"VM"}
	batch, err := xenapi.Event.From(session, classes, "", 1.0)
	check(err)
	token := batch.Token
	fmt.Println("Established event token after initial snapshot.")

	vmRef := vmByName(session, vmName)
	check(xenapi.VM.SetNameDescription(session, vmRef, "changed-to-trigger-event"))

	batch, err = xenapi.Event.From(session, classes, token, 5.0)
	check(err)
	fmt.Printf("Received %d event(s) after the change.\n", len(batch.Events))
	for i, ev := range batch.Events {
		if i >= 3 {
			break
		}
		fmt.Printf("  - %s %s\n", ev.Operation, ev.Class)
	}

	fmt.Println("OK: events")
	session.Logout()
}

// Run it:
//   events("https://xenserver", "root", password, "web-01")

// --- 9. New VM wizard (full) -----------------------------------------------------------
func newVMWizard(url, user, password, templateName, newVMName string) {
	const GiB = 1024 * 1024 * 1024
	const MiB = 1024 * 1024

	session := connect(url, user, password)
	// Page 1 - Template.
	templateRef := templateByName(session, templateName)
	tname, _ := xenapi.VM.GetNameLabel(session, templateRef)
	fmt.Printf("Template:      %s\n", tname)

	// Page 2 - Name and description.
	vm, err := xenapi.VM.Clone(session, templateRef, newVMName)
	check(err)
	check(xenapi.VM.SetNameDescription(session, vm, "Created by the full New VM wizard example"))
	check(xenapi.VM.SetIsATemplate(session, vm, false))
	uuid, _ := xenapi.VM.GetUUID(session, vm)
	fmt.Printf("Created VM:    %s\n", uuid)

	// Page 3 - Installation media (a network install repository).
	check(xenapi.VM.AddToOtherConfig(session, vm, "install-repository",
		"http://mirror.example.com/rocky/9/os/x86_64"))
	fmt.Println("Install media: network repository")

	// Page 4 - Home server (affinity).
	hosts, err := xenapi.Host.GetAllRecords(session)
	check(err)
	var hostRef xenapi.HostRef
	var hostName string
	for ref, h := range hosts {
		hostRef, hostName = ref, h.NameLabel
		break
	}
	check(xenapi.VM.SetAffinity(session, vm, hostRef))
	fmt.Printf("Home server:   %s\n", hostName)

	// Page 5 - CPU & Memory.
	check(xenapi.VM.SetVCPUsMax(session, vm, 2))
	check(xenapi.VM.SetVCPUsAtStartup(session, vm, 2))
	check(xenapi.VM.SetMemoryLimits(session, vm, 512*MiB, 2*GiB, 2*GiB, 2*GiB))
	fmt.Println("CPU/memory:    2 vCPUs, 2 GiB")

	// Page 6 - Storage: add a disk on a (non-ISO) SR.
	srs, err := xenapi.SR.GetAllRecords(session)
	check(err)
	var srRef xenapi.SRRef
	var srName string
	for ref, sr := range srs {
		if sr.ContentType != "iso" && sr.Type != "iso" && sr.Type != "udev" {
			srRef, srName = ref, sr.NameLabel
			break
		}
	}
	vbdDevices, err := xenapi.VM.GetAllowedVBDDevices(session, vm)
	check(err)
	vdi, err := xenapi.VDI.Create(session, xenapi.VDIRecord{
		NameLabel:       newVMName + " disk 0",
		NameDescription: "System disk created by the wizard example",
		SR:              srRef,
		VirtualSize:     24 * GiB,
		Type:            xenapi.VdiTypeSystem,
		Sharable:        false,
		ReadOnly:        false,
		OtherConfig:     map[string]string{},
	})
	check(err)
	_, err = xenapi.VBD.Create(session, xenapi.VBDRecord{
		VM: vm, VDI: vdi, Userdevice: vbdDevices[0], Bootable: true,
		Mode: xenapi.VbdModeRW, Type: xenapi.VbdTypeDisk, Empty: false,
		OtherConfig: map[string]string{}, QosAlgorithmParams: map[string]string{},
	})
	check(err)
	fmt.Printf("Storage:       24 GiB disk on %s\n", srName)

	// Page 7 - Networking: attach a VIF to a network.
	nets, err := xenapi.Network.GetAllRecords(session)
	check(err)
	var netRef xenapi.NetworkRef
	var netName string
	for ref, n := range nets {
		netRef, netName = ref, n.NameLabel
		break
	}
	vifDevices, err := xenapi.VM.GetAllowedVIFDevices(session, vm)
	check(err)
	_, err = xenapi.VIF.Create(session, xenapi.VIFRecord{
		VM: vm, Network: netRef, Device: vifDevices[0], MAC: "", MTU: 1500,
		OtherConfig: map[string]string{}, QosAlgorithmParams: map[string]string{},
	})
	check(err)
	fmt.Printf("Networking:    NIC on %s\n", netName)

	// Page 8 - Finish: start the VM.
	check(xenapi.VM.Start(session, vm, false, true))

	fmt.Println("--- Result ---")
	ps, _ := xenapi.VM.GetPowerState(session, vm)
	vcpus, _ := xenapi.VM.GetVCPUsMax(session, vm)
	vbds, _ := xenapi.VM.GetVBDs(session, vm)
	vifs, _ := xenapi.VM.GetVIFs(session, vm)
	fmt.Printf("power state:   %s\n", ps)
	fmt.Printf("vCPUs:         %d\n", vcpus)
	fmt.Printf("disks:         %d, NICs: %d\n", len(vbds), len(vifs))

	// Tidy up so the example is repeatable.
	check(xenapi.VM.HardShutdown(session, vm))
	check(xenapi.VM.Destroy(session, vm))
	check(xenapi.VDI.Destroy(session, vdi))
	fmt.Println("Cleaned up the example VM.")

	fmt.Println("OK: new-vm-wizard")
	session.Logout()
}

// Run it:
//   newVMWizard("https://xenserver", "root", password, "Rocky Linux 8", "wizard-vm")

// --- 10. Live migrate a VM -------------------------------------------------------------
func liveMigrate(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	// Start a throwaway VM so there is something running to migrate.
	vm, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	check(xenapi.VM.Provision(session, vm))
	check(xenapi.VM.Start(session, vm, false, true))

	sourceHost, err := xenapi.VM.GetResidentOn(session, vm)
	check(err)
	srcName, _ := xenapi.Host.GetNameLabel(session, sourceHost)
	fmt.Printf("VM is running on: %s\n", srcName)

	// Pick a different host in the pool to receive the VM.
	hosts, err := xenapi.Host.GetAllRecords(session)
	check(err)
	var destHost xenapi.HostRef
	for ref := range hosts {
		if ref != sourceHost {
			destHost = ref
			break
		}
	}

	// Check the destination can boot it, then live-migrate (empty options = default live migration).
	check(xenapi.VM.AssertCanBootHere(session, vm, destHost))
	check(xenapi.VM.PoolMigrate(session, vm, destHost, map[string]string{}))

	nowHost, _ := xenapi.VM.GetResidentOn(session, vm)
	nowName, _ := xenapi.Host.GetNameLabel(session, nowHost)
	ps, _ := xenapi.VM.GetPowerState(session, vm)
	fmt.Printf("Migrated to:      %s\n", nowName)
	fmt.Printf("Still running:    %s\n", ps)

	// Tidy up so the example is repeatable.
	check(xenapi.VM.HardShutdown(session, vm))
	check(xenapi.VM.Destroy(session, vm))
	fmt.Println("OK: live-migrate")
	session.Logout()
}

// Run it:
//   liveMigrate("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-migrate")

// --- 11. Enter & exit maintenance mode -------------------------------------------------
func hostMaintenance(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	// Choose a host that is not the pool coordinator, so the coordinator can receive its guests.
	pools, err := xenapi.Pool.GetAllRecords(session)
	check(err)
	var master xenapi.HostRef
	for _, p := range pools {
		master = p.Master
		break
	}
	hosts, err := xenapi.Host.GetAllRecords(session)
	check(err)
	var hostRef xenapi.HostRef
	for ref := range hosts {
		if ref != master {
			hostRef = ref
			break
		}
	}
	hostName, _ := xenapi.Host.GetNameLabel(session, hostRef)
	fmt.Printf("Maintenance host: %s\n", hostName)

	// Pin a running VM to that host so evacuation has something to move.
	vm, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	check(xenapi.VM.Provision(session, vm))
	check(xenapi.VM.SetAffinity(session, vm, hostRef))
	check(xenapi.VM.Start(session, vm, false, true))
	on, _ := xenapi.VM.GetResidentOn(session, vm)
	onName, _ := xenapi.Host.GetNameLabel(session, on)
	fmt.Printf("Guest resident on:%s\n", onName)

	// Enter maintenance mode: disable the host, then evacuate its guests.
	check(xenapi.Host.Disable(session, hostRef, false))
	enabled, _ := xenapi.Host.GetEnabled(session, hostRef)
	fmt.Printf("After disable:    host.enabled = %v\n", enabled)
	check(xenapi.Host.Evacuate2(session, hostRef))
	moved, _ := xenapi.VM.GetResidentOn(session, vm)
	movedName, _ := xenapi.Host.GetNameLabel(session, moved)
	fmt.Printf("After evacuate:   guest now on %s\n", movedName)

	// Exit maintenance mode.
	check(xenapi.Host.Enable(session, hostRef))
	enabled, _ = xenapi.Host.GetEnabled(session, hostRef)
	fmt.Printf("After enable:     host.enabled = %v\n", enabled)

	// Tidy up so the example is repeatable.
	check(xenapi.VM.HardShutdown(session, vm))
	check(xenapi.VM.Destroy(session, vm))
	fmt.Println("OK: host-maintenance")
	session.Logout()
}

// Run it:
//   hostMaintenance("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-maint")

// --- 12. Configure high availability ---------------------------------------------------
func configureHa(url, user, password, heartbeatSRName string) {
	session := connect(url, user, password)
	pools, err := xenapi.Pool.GetAllRecords(session)
	check(err)
	var poolRef xenapi.PoolRef
	for ref := range pools {
		poolRef = ref
		break
	}

	// The HA heartbeat statefile needs a shared SR; confirm the chosen one can host it.
	srRef := srByName(session, heartbeatSRName, true)
	srName, _ := xenapi.SR.GetNameLabel(session, srRef)
	fmt.Printf("Heartbeat SR:  %s\n", srName)
	check(xenapi.SR.AssertCanHostHaStatefile(session, srRef))

	// How many host failures can the pool tolerate? Set that as the target and enable HA.
	ntol, err := xenapi.Pool.HaComputeHypotheticalMaxHostFailuresToTolerate(session, map[xenapi.VMRef]string{})
	check(err)
	fmt.Printf("Max failures:  %d\n", ntol)
	check(xenapi.Pool.SetHaHostFailuresToTolerate(session, poolRef, ntol))
	check(xenapi.Pool.EnableHa(session, []xenapi.SRRef{srRef}, map[string]string{}))
	enabled, _ := xenapi.Pool.GetHaEnabled(session, poolRef)
	fmt.Printf("HA enabled:    %v\n", enabled)

	// What HA does per VM. The restart priority decides which guests come back first after a host
	// failure, and whether a VM is protected at all; "restart" is protected, an empty string is not.
	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var guest xenapi.VMRef
	var guestName string
	for ref, v := range vms {
		if !v.IsATemplate && !v.IsControlDomain && !v.IsASnapshot {
			guest, guestName = ref, v.NameLabel
			break
		}
	}
	was, err := xenapi.VM.GetHaRestartPriority(session, guest)
	check(err)
	check(xenapi.VM.SetHaRestartPriority(session, guest, "restart"))
	now, _ := xenapi.VM.GetHaRestartPriority(session, guest)
	fmt.Printf("%s priority: %q -> %q\n", guestName, was, now)
	check(xenapi.VM.SetHaRestartPriority(session, guest, was))

	// And a pool-wide judgement call: if a guest shuts itself down from the inside, is that a failure HA
	// should undo, or an administrator's intent it should respect?
	internal, _ := xenapi.Pool.GetHaRebootVMOnInternalShutdown(session, poolRef)
	fmt.Printf("Restart on internal shutdown: %v\n", internal)

	// Turn HA back off so the example is repeatable.
	check(xenapi.Pool.DisableHa(session))
	enabled, _ = xenapi.Pool.GetHaEnabled(session, poolRef)
	fmt.Printf("HA enabled:    %v\n", enabled)
	fmt.Println("OK: configure-ha")
	session.Logout()
}

// Run it:
//   configureHa("https://xenserver", "root", password, "Shared NFS")

// --- 13. Copy a VM ---------------------------------------------------------------------
func copyVM(url, user, password, vmName, srName, copyName string) {
	session := connect(url, user, password)
	// A full copy needs a halted source; it places an independent set of disks on the chosen SR.
	source := vmByName(session, vmName)
	srRef := srByName(session, srName, false)
	srLabel, _ := xenapi.SR.GetNameLabel(session, srRef)
	srcLabel, _ := xenapi.VM.GetNameLabel(session, source)
	fmt.Printf("Copying '%s' to SR: %s\n", srcLabel, srLabel)

	copyRef, err := xenapi.VM.Copy(session, source, copyName, srRef)
	check(err)
	uuid, _ := xenapi.VM.GetUUID(session, copyRef)
	vbds, _ := xenapi.VM.GetVBDs(session, copyRef)
	isTemplate, _ := xenapi.VM.GetIsATemplate(session, copyRef)
	fmt.Printf("Copied VM:     %s\n", uuid)
	fmt.Printf("Copy has %d VBD(s), is_a_template = %v\n", len(vbds), isTemplate)

	// Tidy up: destroy the copy and its disks, leaving the source VM intact.
	var copyVdis []xenapi.VDIRef
	for _, vbd := range vbds {
		t, _ := xenapi.VBD.GetType(session, vbd)
		if t != xenapi.VbdTypeDisk {
			continue
		}
		vdi, _ := xenapi.VBD.GetVDI(session, vbd)
		if vdi != xenapi.VDIRef("OpaqueRef:NULL") {
			copyVdis = append(copyVdis, vdi)
		}
	}
	check(xenapi.VM.Destroy(session, copyRef))
	for _, vdi := range copyVdis {
		check(xenapi.VDI.Destroy(session, vdi))
	}
	fmt.Println("Cleaned up the copied VM (left the source intact).")
	fmt.Println("OK: copy-vm")
	session.Logout()
}

// Run it:
//   copyVM("https://xenserver", "root", password, "db-01", "Shared NFS", "sdk-example-copy")

// --- 14. Create a VM with a vGPU -------------------------------------------------------
func createVMWithVgpu(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	// Find a GPU group that offers a real (non-passthrough) vGPU type, plus that type.
	groupRef, typeRef := gpuGroupWithVgpuType(session)
	typeRec, err := xenapi.VGPUType.GetRecord(session, typeRef)
	check(err)
	fmt.Printf("Using vGPU type: %s (%d MB framebuffer)\n", typeRec.ModelName, typeRec.FramebufferSize/(1024*1024))

	// Provision a fresh VM from the template to attach the vGPU to.
	vmRef, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	check(xenapi.VM.Provision(session, vmRef))

	// Assign the vGPU: device "0" is the VM's first vGPU slot, other_config is empty. Same call as
	// XenCenter's New VM wizard GPU page and the VM Properties GPU page.
	vgpuRef, err := xenapi.VGPU.Create(session, vmRef, groupRef, "0", map[string]string{}, typeRef)
	check(err)
	uuid, _ := xenapi.VGPU.GetUUID(session, vgpuRef)
	fmt.Printf("Created vGPU: %s\n", uuid)

	// Read the assignment back, as XenCenter's GPU tab does.
	vgpus, _ := xenapi.VM.GetVGPUs(session, vmRef)
	assignedType, _ := xenapi.VGPU.GetType(session, vgpus[0])
	assigned, _ := xenapi.VGPUType.GetModelName(session, assignedType)
	fmt.Printf("VM now has %d vGPU(s); type = %s\n", len(vgpus), assigned)

	// Tidy up so the example is repeatable.
	check(xenapi.VGPU.Destroy(session, vgpuRef))
	check(xenapi.VM.Destroy(session, vmRef))
	fmt.Println("Cleaned up the example VM and its vGPU.")

	fmt.Println("OK: create-vm-with-vgpu")
	session.Logout()
}

// Run it:
//   createVMWithVgpu("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-vgpu-vm")

// gpuGroupWithVgpuType finds a (GPU_group, VGPU_type) pair where the group offers a non-passthrough type.
func gpuGroupWithVgpuType(session *xenapi.Session) (xenapi.GPUGroupRef, xenapi.VGPUTypeRef) {
	groups, err := xenapi.GPUGroup.GetAllRecords(session)
	check(err)
	for ref, r := range groups {
		if len(r.PGPUs) == 0 {
			continue
		}
		for _, typeRef := range r.SupportedVGPUTypes {
			model, _ := xenapi.VGPUType.GetModelName(session, typeRef)
			if model != "passthrough" {
				return ref, typeRef
			}
		}
	}
	panic("no GPU group offers a vGPU type")
}

// --- 15. Tag and organize objects -----------------------------------------------------
func tagsAndFolders(url, user, password, vmName string) {
	session := connect(url, user, password)
	vm := vmByName(session, vmName)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	host := hosts[0]

	// Tags work on any object type (VM, host, SR, network, …).
	check(xenapi.VM.AddTags(session, vm, "web"))
	check(xenapi.Host.AddTags(session, host, "gold"))
	vmTags, _ := xenapi.VM.GetTags(session, vm)
	hostTags, _ := xenapi.Host.GetTags(session, host)
	fmt.Printf("VM tags:   %v\n", vmTags)
	fmt.Printf("Host tags: %v\n", hostTags)

	// Folder placement lives in other_config["folder"] as a leading-slash path.
	check(xenapi.VM.AddToOtherConfig(session, vm, "folder", "/Production/Web"))
	oc, _ := xenapi.VM.GetOtherConfig(session, vm)
	fmt.Printf("VM folder: %s\n", oc["folder"])

	check(xenapi.VM.RemoveTags(session, vm, "web"))
	check(xenapi.Host.RemoveTags(session, host, "gold"))
	check(xenapi.VM.RemoveFromOtherConfig(session, vm, "folder"))
	fmt.Println("OK: tags-and-folders")
	session.Logout()
}

// Run it:
//   tagsAndFolders("https://xenserver", "root", password, "web-01")

// --- 16. Configure updates (CDN) ------------------------------------------------------
func configureUpdates(url, user, password string) {
	session := connect(url, user, password)
	repo, err := xenapi.Repository.Introduce(session, "sdk-cdn", "SDK example repository",
		"https://cdn.example/base", "https://cdn.example/source", false, "")
	check(err)
	name, _ := xenapi.Repository.GetNameLabel(session, repo)
	fmt.Printf("Introduced repository: %s\n", name)

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	pool := pools[0]
	check(xenapi.Pool.SetRepositories(session, pool, []xenapi.RepositoryRef{repo}))
	check(xenapi.Pool.SetUpdateSyncEnabled(session, pool, true))
	repos, _ := xenapi.Pool.GetRepositories(session, pool)
	enabled, _ := xenapi.Pool.GetUpdateSyncEnabled(session, pool)
	fmt.Printf("Pool repositories: %d; auto-sync enabled: %v\n", len(repos), enabled)

	// Tidy up so the example is repeatable.
	check(xenapi.Pool.SetUpdateSyncEnabled(session, pool, false))
	check(xenapi.Pool.SetRepositories(session, pool, []xenapi.RepositoryRef{}))
	check(xenapi.Repository.Forget(session, repo))
	fmt.Println("OK: configure-updates")
	session.Logout()
}

// Run it:
//   configureUpdates("https://xenserver", "root", password)

// diskVdis returns the VDIs backing a VM's disk VBDs (used to clean up a VM's owned disks).
func diskVdis(session *xenapi.Session, vmRef xenapi.VMRef) []xenapi.VDIRef {
	var vdis []xenapi.VDIRef
	vbds, err := xenapi.VM.GetVBDs(session, vmRef)
	check(err)
	for _, vbd := range vbds {
		t, err := xenapi.VBD.GetType(session, vbd)
		check(err)
		if t != xenapi.VbdTypeDisk {
			continue
		}
		vdi, err := xenapi.VBD.GetVDI(session, vbd)
		check(err)
		if vdi != xenapi.VDIRef("OpaqueRef:NULL") {
			vdis = append(vdis, vdi)
		}
	}
	return vdis
}

// --- 17. Clone a VM (fast, copy-on-write) ------------------------------------------------
func cloneVM(url, user, password, vmName, cloneName string) {
	session := connect(url, user, password)
	// Unlike Copy (a full, independent copy onto a chosen SR), Clone is a fast copy-on-write
	// duplicate on the same SR - ideal for a halted "golden" VM.
	source := vmByName(session, vmName)
	clone, err := xenapi.VM.Clone(session, source, cloneName)
	check(err)
	srcName, _ := xenapi.VM.GetNameLabel(session, source)
	cloneLabel, _ := xenapi.VM.GetNameLabel(session, clone)
	fmt.Printf("Cloned '%s' -> %s\n", srcName, cloneLabel)
	vbds, _ := xenapi.VM.GetVBDs(session, clone)
	fmt.Printf("Clone has %d VBD(s)\n", len(vbds))

	// Tidy up: destroy the clone and its (owned) disks.
	vdis := diskVdis(session, clone)
	check(xenapi.VM.Destroy(session, clone))
	for _, vdi := range vdis {
		check(xenapi.VDI.Destroy(session, vdi))
	}
	fmt.Println("OK: clone-vm")
	session.Logout()
}

// Run it:
//   cloneVM("https://xenserver", "root", password, "db-01", "sdk-example-clone")

// --- 18. Delete a VM ---------------------------------------------------------------------
func deleteVM(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	// Make a throwaway VM to delete. VM.Destroy removes the VM but leaves its disks, so the
	// owned VDIs are destroyed explicitly afterward - exactly what XenCenter's Delete VM does.
	vm, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	check(xenapi.VM.Provision(session, vm))
	uuid, _ := xenapi.VM.GetUUID(session, vm)
	vdis := diskVdis(session, vm)
	fmt.Printf("Deleting VM %s with %d disk(s)\n", uuid, len(vdis))

	check(xenapi.VM.Destroy(session, vm))
	for _, vdi := range vdis {
		check(xenapi.VDI.Destroy(session, vdi))
	}

	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	stillThere := false
	for _, v := range vms {
		if v.UUID == uuid {
			stillThere = true
			break
		}
	}
	fmt.Printf("VM still present: %v\n", stillThere)
	fmt.Println("OK: delete-vm")
	session.Logout()
}

// Run it:
//   deleteVM("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-delete")

// --- 19. Storage live-migration (move a disk to another SR) ------------------------------
func storageMigrate(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	// Provision a VM so it has a disk to relocate, note the disk's current SR.
	vm, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	check(xenapi.VM.Provision(session, vm))
	vdi := diskVdis(session, vm)[0]
	sourceSr, err := xenapi.VDI.GetSR(session, vdi)
	check(err)
	srcSrName, _ := xenapi.SR.GetNameLabel(session, sourceSr)
	fmt.Printf("Disk is on SR: %s\n", srcSrName)

	// Pick a different SR that can hold a VDI and move the disk there (live storage migration).
	srs, err := xenapi.SR.GetAllRecords(session)
	check(err)
	var destSr xenapi.SRRef
	for ref, sr := range srs {
		if ref != sourceSr && sr.Type != "iso" && sr.Type != "udev" {
			destSr = ref
			break
		}
	}
	_, err = xenapi.VDI.PoolMigrate(session, vdi, destSr, map[string]string{})
	check(err)

	nowOn, _ := xenapi.VDI.GetSR(session, vdi)
	nowName, _ := xenapi.SR.GetNameLabel(session, nowOn)
	fmt.Printf("Disk moved to:  %s\n", nowName)

	// Tidy up.
	check(xenapi.VM.Destroy(session, vm))
	check(xenapi.VDI.Destroy(session, vdi))
	fmt.Println("OK: storage-migrate")
	session.Logout()
}

// Run it:
//   storageMigrate("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-storagemigrate")

// --- 20. Apply updates from the CDN -----------------------------------------------------
func applyUpdate(url, user, password string) {
	session := connect(url, user, password)
	// Sync the pool's update metadata from the CDN; the returned hash identifies the synced set.
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	pool := pools[0]
	hash, err := xenapi.Pool.SyncUpdates(session, pool, false, "", "", "", "")
	check(err)
	fmt.Printf("Synced updates; hash length %d\n", len(hash))

	// Apply the synced updates to each host. XenCenter then reads the reboot guidance to decide
	// whether a Rolling Pool Upgrade reboot is needed.
	hosts, err := xenapi.Host.GetAllRecords(session)
	check(err)
	for hostRef, host := range hosts {
		_, err := xenapi.Host.ApplyUpdates(session, hostRef, hash)
		check(err)
		guidance, _ := xenapi.Host.GetPendingGuidances(session, hostRef)
		fmt.Printf("  %s: applied; pending guidance = %v\n", host.NameLabel, guidance)
	}
	fmt.Println("OK: apply-update")
	session.Logout()
}

// Run it:
//   applyUpdate("https://xenserver", "root", password)

// --- 21. Checkpoint & revert ------------------------------------------------------------
func checkpointVM(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	// A checkpoint captures disk AND memory (unlike a plain snapshot), so the VM must be running.
	vm, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	check(xenapi.VM.Provision(session, vm))
	check(xenapi.VM.Start(session, vm, false, true))

	checkpoint, err := xenapi.VM.Checkpoint(session, vm, "sdk-example-checkpoint-1")
	check(err)
	uuid, _ := xenapi.VM.GetUUID(session, checkpoint)
	fmt.Printf("Created checkpoint: %s\n", uuid)
	isSnapshot, _ := xenapi.VM.GetIsASnapshot(session, checkpoint)
	fmt.Printf("is_a_snapshot = %v\n", isSnapshot)

	check(xenapi.VM.Revert(session, checkpoint))
	fmt.Println("Reverted the VM to the checkpoint.")

	// Tidy up.
	check(xenapi.VM.Destroy(session, checkpoint))
	ps, _ := xenapi.VM.GetPowerState(session, vm)
	if ps == xenapi.VMPowerStateRunning {
		check(xenapi.VM.HardShutdown(session, vm))
	}
	check(xenapi.VM.Destroy(session, vm))
	fmt.Println("OK: checkpoint-vm")
	session.Logout()
}

// Run it:
//   checkpointVM("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-checkpoint")

// --- 22. Attach a new disk to a VM ------------------------------------------------------
func attachDisk(url, user, password, templateName, srName, newVMName string) {
	const GiB = 1024 * 1024 * 1024

	session := connect(url, user, password)
	vm, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	check(xenapi.VM.Provision(session, vm))
	srRef := srByName(session, srName, false)

	// Create a fresh VDI on the SR and attach it as a new VBD (a new virtual disk).
	vdi, err := xenapi.VDI.Create(session, xenapi.VDIRecord{
		NameLabel:   "sdk-example-data-disk",
		SR:          srRef,
		VirtualSize: 8 * GiB,
		Type:        xenapi.VdiTypeUser,
		Sharable:    false,
		ReadOnly:    false,
		OtherConfig: map[string]string{},
	})
	check(err)
	devices, err := xenapi.VM.GetAllowedVBDDevices(session, vm)
	check(err)
	device := devices[0]
	_, err = xenapi.VBD.Create(session, xenapi.VBDRecord{
		VM: vm, VDI: vdi, Userdevice: device,
		Mode: xenapi.VbdModeRW, Type: xenapi.VbdTypeDisk, Empty: false,
		OtherConfig: map[string]string{}, QosAlgorithmParams: map[string]string{},
	})
	check(err)
	srLabel, _ := xenapi.SR.GetNameLabel(session, srRef)
	fmt.Printf("Attached an 8 GiB disk on %s as device %s\n", srLabel, device)
	vbds, _ := xenapi.VM.GetVBDs(session, vm)
	fmt.Printf("VM now has %d VBD(s)\n", len(vbds))

	// Tidy up: gather the owned disks first, then destroy the VM (which removes its VBDs), then
	// destroy the disks (VM.Destroy leaves VDIs behind).
	owned := diskVdis(session, vm)
	check(xenapi.VM.Destroy(session, vm))
	for _, d := range owned {
		check(xenapi.VDI.Destroy(session, d))
	}
	fmt.Println("OK: attach-disk")
	session.Logout()
}

// Run it:
//   attachDisk("https://xenserver", "root", password, "Rocky Linux 8", "Shared NFS", "sdk-example-attachdisk")

// --- 23. Drive an asynchronous task -----------------------------------------------------
func waitForTask(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	// Every message has an Async.* twin that returns a Task ref immediately; poll it to completion.
	task, err := xenapi.VM.AsyncClone(session, templateByName(session, templateName), newVMName)
	check(err)
	uuid, _ := xenapi.Task.GetUUID(session, task)
	fmt.Printf("Started task: %s\n", uuid)

	for {
		status, err := xenapi.Task.GetStatus(session, task)
		check(err)
		if status != xenapi.TaskStatusTypePending {
			break
		}
		progress, _ := xenapi.Task.GetProgress(session, task)
		fmt.Printf("  progress: %.0f%%\n", progress*100)
	}
	status, _ := xenapi.Task.GetStatus(session, task)
	fmt.Printf("Task status: %s\n", status)

	// The result of an object-creating task is <value>OpaqueRef:...</value>.
	result, err := xenapi.Task.GetResult(session, task)
	check(err)
	result = strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(result, "<value>", ""), "</value>", ""))
	vmRef := xenapi.VMRef(result)
	name, _ := xenapi.VM.GetNameLabel(session, vmRef)
	fmt.Printf("Task produced VM: %s\n", name)

	// Tidy up.
	check(xenapi.VM.Destroy(session, vmRef))
	check(xenapi.Task.Destroy(session, task))
	fmt.Println("OK: wait-for-task")
	session.Logout()
}

// Run it:
//   waitForTask("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-asynctask")

// --- 24. Handle an API error ------------------------------------------------------------
func errorHandling(url, user, password string) {
	session := connect(url, user, password)
	// XenAPI errors surface as an error whose text carries the XenAPI error code.
	_, err := xenapi.Host.GetByUUID(session, "this-uuid-does-not-exist")
	if err != nil {
		fmt.Printf("Caught expected failure: %s\n", err)
	} else {
		fmt.Println("unexpected: no error")
	}
	fmt.Println("OK: error-handling")
	session.Logout()
}

// Run it:
//   errorHandling("https://xenserver", "root", password)

// --- 25. List templates -----------------------------------------------------------------
func listTemplates(url, user, password string) {
	session := connect(url, user, password)
	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var templates []xenapi.VMRecord
	for _, v := range vms {
		if v.IsATemplate {
			templates = append(templates, v)
		}
	}
	fmt.Printf("Templates (%d):\n", len(templates))
	for i, t := range templates {
		if i >= 8 {
			break
		}
		badge := ""
		if _, ok := t.OtherConfig["default_template"]; ok {
			badge = " [built-in]"
		}
		fmt.Printf("  - %s%s\n", t.NameLabel, badge)
	}
	fmt.Println("OK: list-templates")
	session.Logout()
}

// Run it:
//   listTemplates("https://xenserver", "root", password)

// --- 26. Custom fields ------------------------------------------------------------------
func customFields(url, user, password, vmName string) {
	session := connect(url, user, password)
	// XenCenter's custom fields are stored in other_config under "XenCenter.CustomFields.<name>".
	vm := vmByName(session, vmName)
	const key = "XenCenter.CustomFields.Owner"
	check(xenapi.VM.AddToOtherConfig(session, vm, key, "Platform Team"))
	oc, _ := xenapi.VM.GetOtherConfig(session, vm)
	fmt.Printf("Custom field Owner = %s\n", oc[key])

	check(xenapi.VM.RemoveFromOtherConfig(session, vm, key))
	fmt.Println("OK: custom-fields")
	session.Logout()
}

// Run it:
//   customFields("https://xenserver", "root", password, "web-01")

// --- 27. GPU inventory ------------------------------------------------------------------
func gpuInventory(url, user, password string) {
	session := connect(url, user, password)
	groups, err := xenapi.GPUGroup.GetAllRecords(session)
	check(err)
	fmt.Printf("GPU groups (%d):\n", len(groups))
	var firstGroup xenapi.GPUGroupRef
	haveGroup := false
	for ref, group := range groups {
		var types []string
		for _, t := range group.SupportedVGPUTypes {
			model, _ := xenapi.VGPUType.GetModelName(session, t)
			types = append(types, model)
		}
		fmt.Printf("  - %s: %d pGPU(s), vGPU types: %s\n",
			group.NameLabel, len(group.PGPUs), strings.Join(types, ", "))
		if !haveGroup {
			firstGroup, haveGroup = ref, true
		}
	}

	// How the pool spreads vGPUs across the physical GPUs in a group: depth-first packs each pGPU full
	// before using the next, breadth-first spreads them out.
	before, err := xenapi.GPUGroup.GetAllocationAlgorithm(session, firstGroup)
	check(err)
	check(xenapi.GPUGroup.SetAllocationAlgorithm(session, firstGroup, xenapi.AllocationAlgorithmBreadthFirst))
	after, _ := xenapi.GPUGroup.GetAllocationAlgorithm(session, firstGroup)
	fmt.Printf("Allocation:      %s -> %s\n", before, after)
	check(xenapi.GPUGroup.SetAllocationAlgorithm(session, firstGroup, before))

	fmt.Println("OK: gpu-inventory")
	session.Logout()
}

// Run it:
//   gpuInventory("https://xenserver", "root", password)

// --- 28. Read host & VM metrics ---------------------------------------------------------
func readMetrics(url, user, password string) {
	const MiB = 1024 * 1024

	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAllRecords(session)
	check(err)
	var hostRef xenapi.HostRef
	var hostName string
	for ref, h := range hosts {
		hostRef, hostName = ref, h.NameLabel
		break
	}
	hm, err := xenapi.Host.GetMetrics(session, hostRef)
	check(err)
	total, _ := xenapi.HostMetrics.GetMemoryTotal(session, hm)
	free, _ := xenapi.HostMetrics.GetMemoryFree(session, hm)
	live, _ := xenapi.HostMetrics.GetLive(session, hm)
	fmt.Printf("Host %s: %d MiB total, %d MiB free, live = %v\n",
		hostName, total/MiB, free/MiB, live)

	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var vmRef xenapi.VMRef
	for ref, v := range vms {
		if !v.IsATemplate && !v.IsControlDomain && v.PowerState == xenapi.VMPowerStateRunning {
			vmRef = ref
			break
		}
	}
	vmm, err := xenapi.VM.GetMetrics(session, vmRef)
	check(err)
	vcpus, _ := xenapi.VMMetrics.GetVCPUsNumber(session, vmm)
	mem, _ := xenapi.VMMetrics.GetMemoryActual(session, vmm)
	name, _ := xenapi.VM.GetNameLabel(session, vmRef)
	fmt.Printf("VM %s: %d vCPU(s), %d MiB\n", name, vcpus, mem/MiB)
	fmt.Println("OK: read-metrics")
	session.Logout()
}

// Run it:
//   readMetrics("https://xenserver", "root", password)

// --- 29. Rename an object --------------------------------------------------------------
func renameObject(url, user, password, vmName string) {
	session := connect(url, user, password)
	vm := vmByName(session, vmName)
	original, _ := xenapi.VM.GetNameLabel(session, vm)
	check(xenapi.VM.SetNameLabel(session, vm, "sdk-renamed"))
	now, _ := xenapi.VM.GetNameLabel(session, vm)
	fmt.Printf("Renamed '%s' -> '%s'\n", original, now)
	check(xenapi.VM.SetNameLabel(session, vm, original)) // restore so the example is repeatable
	fmt.Println("OK: rename-object")
	session.Logout()
}

// Run it:
//   renameObject("https://xenserver", "root", password, "web-01")

// --- 30. VM boot configuration ---------------------------------------------------------
func vmBootConfig(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	vm, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	check(xenapi.VM.Provision(session, vm))

	check(xenapi.VM.SetVCPUsMax(session, vm, 4))
	check(xenapi.VM.SetVCPUsAtStartup(session, vm, 2))

	// Boot mode: firmware ("bios"/"uefi") lives in HVM_boot_params; Secure Boot in
	// platform["secureboot"]. Switch to UEFI Secure Boot (as the New VM wizard does for a
	// UEFI-capable template) and read it back.
	check(xenapi.VM.SetHVMBootParams(session, vm, map[string]string{"order": "cdn", "firmware": "uefi"}))
	platform, _ := xenapi.VM.GetPlatform(session, vm)
	platform["secureboot"] = "true"
	check(xenapi.VM.SetPlatform(session, vm, platform))
	atStartup, _ := xenapi.VM.GetVCPUsAtStartup(session, vm)
	max, _ := xenapi.VM.GetVCPUsMax(session, vm)
	fmt.Printf("vCPUs: %d/%d\n", atStartup, max)
	bootParams, _ := xenapi.VM.GetHVMBootParams(session, vm)
	fmt.Printf("Boot order: %s\n", bootParams["order"])
	platform, _ = xenapi.VM.GetPlatform(session, vm)
	fmt.Printf("Boot mode: firmware=%s, secureboot=%s\n", bootParams["firmware"], platform["secureboot"])

	check(xenapi.VM.Destroy(session, vm))
	fmt.Println("OK: vm-boot-config")
	session.Logout()
}

// Run it:
//   vmBootConfig("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-boot")

// --- 31. Host information --------------------------------------------------------------
func hostInfo(url, user, password string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAllRecords(session)
	check(err)
	var host xenapi.HostRecord
	for _, h := range hosts {
		host = h
		break
	}

	// A map lookup that falls back to "?" for a key the host does not report.
	get := func(m map[string]string, key string) string {
		if v, ok := m[key]; ok {
			return v
		}
		return "?"
	}

	fmt.Printf("Host:     %s\n", host.NameLabel)
	fmt.Printf("Version:  %s\n", get(host.SoftwareVersion, "product_version"))
	fmt.Printf("Edition:  %s\n", host.Edition)
	fmt.Printf("CPUs:     %s across %s socket(s)\n",
		get(host.CPUInfo, "cpu_count"), get(host.CPUInfo, "socket_count"))
	// The physical identity, straight off the host's DMI/SMBIOS tables. The serial number is what you
	// quote to the hardware vendor, so it is the one field here that identifies this machine, not its model.
	fmt.Printf("Hardware: %s %s\n", get(host.BiosStrings, "system-manufacturer"),
		get(host.BiosStrings, "system-product-name"))
	fmt.Printf("Serial:   %s\n", get(host.BiosStrings, "system-serial-number"))
	fmt.Printf("BIOS:     %s\n", get(host.BiosStrings, "bios-version"))
	fmt.Println("OK: host-info")
	session.Logout()
}

// Run it:
//   hostInfo("https://xenserver", "root", password)

// --- 32. List roles -------------------------------------------------------------------
func listRoles(url, user, password string) {
	session := connect(url, user, password)
	// Role is the one class XenCenter still bulk-downloads; RBAC subjects map to these roles.
	roles, err := xenapi.Role.GetAllRecords(session)
	check(err)
	seen := map[string]bool{}
	var names []string
	for _, r := range roles {
		if !seen[r.NameLabel] {
			seen[r.NameLabel] = true
			names = append(names, r.NameLabel)
		}
	}
	shown := names
	if len(shown) > 8 {
		shown = shown[:8]
	}
	fmt.Printf("Roles (%d): %s\n", len(names), strings.Join(shown, ", "))
	fmt.Println("OK: list-roles")
	session.Logout()
}

// Run it:
//   listRoles("https://xenserver", "root", password)

// --- 33. Pool properties --------------------------------------------------------------
func poolProperties(url, user, password string) {
	session := connect(url, user, password)
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	poolRef := pools[0]
	original, _ := xenapi.Pool.GetNameLabel(session, poolRef)
	defaultSr, _ := xenapi.Pool.GetDefaultSR(session, poolRef)
	srName := "(none)"
	if defaultSr != xenapi.SRRef("OpaqueRef:NULL") {
		srName, _ = xenapi.SR.GetNameLabel(session, defaultSr)
	}
	fmt.Printf("Pool:       '%s'\n", original)
	fmt.Printf("Default SR: %s\n", srName)

	check(xenapi.Pool.SetNameLabel(session, poolRef, "sdk-pool-renamed"))
	now, _ := xenapi.Pool.GetNameLabel(session, poolRef)
	fmt.Printf("Renamed to: '%s'\n", now)
	check(xenapi.Pool.SetNameLabel(session, poolRef, original)) // restore
	fmt.Println("OK: pool-properties")
	session.Logout()
}

// Run it:
//   poolProperties("https://xenserver", "root", password)

// --- 34. Storage repository usage -----------------------------------------------------
func srUsage(url, user, password string) {
	const GiB = 1024 * 1024 * 1024

	session := connect(url, user, password)
	srs, err := xenapi.SR.GetAllRecords(session)
	check(err)
	var scanMe xenapi.SRRef
	haveScan := false
	for ref, sr := range srs {
		if sr.PhysicalSize <= 0 { // skip ISO/DVD pseudo-SRs
			continue
		}
		fmt.Printf("  %s: %d / %d GiB used\n", sr.NameLabel, sr.PhysicalUtilisation/GiB, sr.PhysicalSize/GiB)
		if !haveScan {
			scanMe, haveScan = ref, true
		}
	}
	// A rescan refreshes an SR's utilisation from its backend.
	if haveScan {
		check(xenapi.SR.Scan(session, scanMe))
	}

	// Read caching keeps recently-read blocks in the host's memory. It is switched off per SR by setting
	// o_direct, which asks the storage layer to bypass the cache entirely.
	if haveScan {
		check(xenapi.SR.RemoveFromOtherConfig(session, scanMe, "o_direct"))
		check(xenapi.SR.AddToOtherConfig(session, scanMe, "o_direct", "true"))
		oc, _ := xenapi.SR.GetOtherConfig(session, scanMe)
		name, _ := xenapi.SR.GetNameLabel(session, scanMe)
		readCaching := "on"
		if oc["o_direct"] == "true" {
			readCaching = "off"
		}
		fmt.Printf("  read caching on %s: %s\n", name, readCaching)
		check(xenapi.SR.RemoveFromOtherConfig(session, scanMe, "o_direct"))
	}
	fmt.Println("OK: sr-usage")
	session.Logout()
}

// Run it:
//   srUsage("https://xenserver", "root", password)

// --- 35. Manage a VM's network interfaces ---------------------------------------------
func manageVif(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	vm, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	check(xenapi.VM.Provision(session, vm))
	nets, err := xenapi.Network.GetAll(session)
	check(err)
	netRef := nets[0]
	devices, err := xenapi.VM.GetAllowedVIFDevices(session, vm)
	check(err)
	device := devices[0]

	vif, err := xenapi.VIF.Create(session, xenapi.VIFRecord{
		VM: vm, Network: netRef, Device: device, MAC: "", MTU: 1500,
		OtherConfig: map[string]string{}, QosAlgorithmParams: map[string]string{},
	})
	check(err)
	vifs, _ := xenapi.VM.GetVIFs(session, vm)
	fmt.Printf("Attached a VIF on device %s; VM now has %d NIC(s)\n", device, len(vifs))

	check(xenapi.VIF.Destroy(session, vif))
	check(xenapi.VM.Destroy(session, vm))
	fmt.Println("OK: manage-vif")
	session.Logout()
}

// Run it:
//   manageVif("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-vif")

// --- 36. List networks ----------------------------------------------------------------
func listNetworks(url, user, password string) {
	session := connect(url, user, password)
	nets, err := xenapi.Network.GetAllRecords(session)
	check(err)
	fmt.Printf("Networks (%d):\n", len(nets))
	for _, net := range nets {
		fmt.Printf("  - %s: %d PIF(s), %d VIF(s)\n", net.NameLabel, len(net.PIFs), len(net.VIFs))
	}
	fmt.Println("OK: list-networks")
	session.Logout()
}

// Run it:
//   listNetworks("https://xenserver", "root", password)

// --- 37. Inventory a VM's disks -------------------------------------------------------
func vbdInventory(url, user, password, vmName string) {
	const GiB = 1024 * 1024 * 1024

	session := connect(url, user, password)
	vm := vmByName(session, vmName)
	name, _ := xenapi.VM.GetNameLabel(session, vm)
	fmt.Printf("Disks of '%s':\n", name)
	vbds, err := xenapi.VM.GetVBDs(session, vm)
	check(err)
	for _, vbdRef := range vbds {
		vbd, err := xenapi.VBD.GetRecord(session, vbdRef)
		check(err)
		if vbd.Type != xenapi.VbdTypeDisk {
			continue
		}
		vdi, _ := xenapi.VBD.GetVDI(session, vbdRef)
		size := 0
		if vdi != xenapi.VDIRef("OpaqueRef:NULL") {
			virtualSize, _ := xenapi.VDI.GetVirtualSize(session, vdi)
			size = virtualSize / GiB
		}
		fmt.Printf("  - device %s: %d GiB\n", vbd.Userdevice, size)
	}
	fmt.Println("OK: vbd-inventory")
	session.Logout()
}

// Run it:
//   vbdInventory("https://xenserver", "root", password, "db-01")

// --- 38. Tag the pool -----------------------------------------------------------------
func poolTags(url, user, password string) {
	session := connect(url, user, password)
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	poolRef := pools[0]
	check(xenapi.Pool.AddTags(session, poolRef, "sdk-managed"))
	tags, _ := xenapi.Pool.GetTags(session, poolRef)
	fmt.Printf("Pool tags: %s\n", strings.Join(tags, ", "))
	check(xenapi.Pool.RemoveTags(session, poolRef, "sdk-managed"))
	fmt.Println("OK: pool-tags")
	session.Logout()
}

// Run it:
//   poolTags("https://xenserver", "root", password)

// --- 39. Convert a VM to a template ---------------------------------------------------
func convertToTemplate(url, user, password, templateName, newVMName string) {
	session := connect(url, user, password)
	vm, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	check(xenapi.VM.Provision(session, vm)) // now a real (halted) VM
	isTemplate, _ := xenapi.VM.GetIsATemplate(session, vm)
	fmt.Printf("is_a_template after provision: %v\n", isTemplate)

	// Converting a VM to a custom template is a one-way operation.
	check(xenapi.VM.SetIsATemplate(session, vm, true))
	isTemplate, _ = xenapi.VM.GetIsATemplate(session, vm)
	fmt.Printf("is_a_template after convert:  %v\n", isTemplate)

	check(xenapi.VM.Destroy(session, vm))
	fmt.Println("OK: convert-to-template")
	session.Logout()
}

// Run it:
//   convertToTemplate("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-totemplate")

// --- 40. Look up an object by UUID ----------------------------------------------------
func findByUUID(url, user, password, vmName string) {
	session := connect(url, user, password)
	// UUIDs are stable identifiers you can persist and resolve back to a (session-scoped) ref.
	vm := vmByName(session, vmName)
	uuid, _ := xenapi.VM.GetUUID(session, vm)
	resolved, err := xenapi.VM.GetByUUID(session, uuid)
	check(err)
	name, _ := xenapi.VM.GetNameLabel(session, resolved)
	fmt.Printf("UUID %s resolves to %s\n", uuid, name)
	fmt.Printf("Same object: %v\n", resolved == vm)
	fmt.Println("OK: find-by-uuid")
	session.Logout()
}

// --- 41. Rolling pool update ---------------------------------------------------------
func rollingPoolUpdate(url, user, password string) {
	session := connect(url, user, password)
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	hash, err := xenapi.Pool.SyncUpdates(session, pools[0], false, "", "", "", "")
	check(err)
	fmt.Printf("Synced updates; hash length %d\n", len(hash))

	// The rolling pattern behind XenCenter's automated Install Updates:
	// disable -> evacuate -> apply -> reboot -> re-enable, one host at a time.
	hosts, err := xenapi.Host.GetAllRecords(session)
	check(err)
	for hostRef, host := range hosts {
		fmt.Printf("Updating %s:\n", host.NameLabel)
		check(xenapi.Host.Disable(session, hostRef, false)) // stop new VMs landing here
		check(xenapi.Host.Evacuate2(session, hostRef))      // move running guests to the rest of the pool
		_, err := xenapi.Host.ApplyUpdates(session, hostRef, hash)
		check(err) // apply the synced updates
		guidance, _ := xenapi.Host.GetPendingGuidances(session, hostRef)
		fmt.Printf("  applied; pending guidance = %v\n", guidance)
		check(xenapi.Host.Reboot(session, hostRef)) // reboot into the updated software
		check(xenapi.Host.Enable(session, hostRef)) // return the host to service
	}
	fmt.Println("OK: rolling-pool-update")
	session.Logout()
}

// --- 42. Cross-pool copy a VM --------------------------------------------------------
// Copy a VM from one pool to another (Storage XenMotion copy): get a receiver token from the
// destination with host.migrate_receive, then VM.migrate_send with copy=true on the source.
func crossPoolCopyVM(url, user, password, destURL, vmName string) {
	source := connect(url, user, password)
	dest := connect(destURL, user, password)
	// Destination: choose a host, network and SR, then ask for a receiver token.
	destHosts, err := xenapi.Host.GetAll(dest)
	check(err)
	destNets, err := xenapi.Network.GetAll(dest)
	check(err)
	destSr := srByName(dest, "Shared NFS", true)
	receiver, err := xenapi.Host.MigrateReceive(dest, destHosts[0], destNets[0], map[string]string{})
	check(err)

	// Source: map every disk to the destination SR and every NIC to the destination network,
	// then send with copy=true (the source VM is left intact).
	vm := vmByName(source, vmName)
	vbds, _ := xenapi.VM.GetVBDs(source, vm)
	vdiMap := map[xenapi.VDIRef]xenapi.SRRef{}
	for _, vbd := range vbds {
		if t, _ := xenapi.VBD.GetType(source, vbd); t != xenapi.VbdTypeDisk {
			continue
		}
		vdi, _ := xenapi.VBD.GetVDI(source, vbd)
		vdiMap[vdi] = destSr
	}
	vifs, _ := xenapi.VM.GetVIFs(source, vm)
	vifMap := map[xenapi.VIFRef]xenapi.NetworkRef{}
	for _, vif := range vifs {
		vifMap[vif] = destNets[0]
	}

	_, err = xenapi.VM.MigrateSend(source, vm, receiver, false, vdiMap, vifMap,
		map[string]string{"copy": "true"}, map[xenapi.VGPURef]xenapi.GPUGroupRef{})
	check(err)
	fmt.Printf("Sent '%s' to the destination pool (copy); source still present: %v\n",
		vmName, vmByName(source, vmName) == vm)
	fmt.Println("OK: cross-pool-copy-vm")
	dest.Logout()
	source.Logout()
}

// Run it:
//   findByUUID("https://xenserver", "root", password, "web-01")


// Maps the <workflow> argument to the matching self-contained function above, supplying the concrete
// objects each one operates on. In your own code you would call these functions directly (see the
// "Run it:" line under each) rather than through this dispatcher.
// --- 43. PVS Accelerator inventory ---
func pvsAccelerator(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	sites, err := xenapi.PVSSite.GetAllRecords(session)
	check(err)
	if len(sites) == 0 {
		fmt.Println("No PVS Accelerator sites are configured.")
	}
	for _, site := range sites {
		fmt.Printf("Site: %s\n", site.NameLabel)
		for _, csRef := range site.CacheStorage {
			cs, err := xenapi.PVSCacheStorage.GetRecord(session, csRef)
			check(err)
			host, _ := xenapi.Host.GetRecord(session, cs.Host)
			sr, _ := xenapi.SR.GetRecord(session, cs.SR)
			fmt.Printf("  cache:  %s  %d GiB on %s\n", host.NameLabel, cs.Size/(1024*1024*1024), sr.NameLabel)
		}
		for _, serverRef := range site.Servers {
			server, err := xenapi.PVSServer.GetRecord(session, serverRef)
			check(err)
			fmt.Printf("  server: %s  ports %d-%d\n", strings.Join(server.Addresses, ", "), server.FirstPort, server.LastPort)
		}
		// Which VMs are accelerated: walk each proxy to its VIF to its VM.
		accelerated := map[xenapi.VMRef]bool{}
		for _, proxyRef := range site.Proxies {
			proxy, err := xenapi.PVSProxy.GetRecord(session, proxyRef)
			check(err)
			vif, err := xenapi.VIF.GetRecord(session, proxy.VIF)
			check(err)
			accelerated[vif.VM] = true
		}
		vms, err := xenapi.VM.GetAllRecords(session)
		check(err)
		total, count := 0, 0
		for ref, v := range vms {
			if v.IsControlDomain || v.IsATemplate || v.IsASnapshot {
				continue
			}
			total++
			if accelerated[ref] {
				count++
			}
		}
		fmt.Printf("  %d of %d VM(s) accelerated\n", count, total)
	}
	fmt.Println("OK: pvs-accelerator")
}

// --- 44. Read RRD performance metrics ---
func rrdMetrics(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	hosts, err := xenapi.Host.GetAllRecords(session)
	check(err)
	nameByUUID := map[string]string{}
	for _, h := range hosts {
		nameByUUID[h.UUID] = h.NameLabel
	}

	// The RRD time-series isn't a XenAPI call; read rrd_updates over HTTP. It needs a session id (the SDK
	// keeps its own private), so obtain one with a small JSON-RPC login. Legends are
	// "AVERAGE:host:<uuid>:<datasource>"; values[] aligns to legend[].
	sid := rawLogin(url, user, password)
	start := time.Now().Unix() - 300
	req, _ := http.NewRequest("GET", fmt.Sprintf("%s/rrd_updates?session_id=%s&host=true&start=%d", url, sid, start), nil)
	req.Header.Set("accept", "application/json")
	resp, err := insecureClient().Do(req)
	check(err)
	defer resp.Body.Close()

	var rrd struct {
		Meta struct {
			Legend []string `json:"legend"`
		} `json:"meta"`
		Data []struct {
			Values []float64 `json:"values"`
		} `json:"data"`
	}
	check(json.NewDecoder(resp.Body).Decode(&rrd))

	peak := map[string]float64{}
	for _, point := range rrd.Data {
		for k, legend := range rrd.Meta.Legend {
			parts := strings.Split(legend, ":")
			if parts[1] == "host" && parts[3] == "pvsaccelerator_space_utilization" && point.Values[k] > peak[parts[2]] {
				peak[parts[2]] = point.Values[k]
			}
		}
	}
	for uuid, p := range peak {
		fmt.Printf("  %s: peak PVS cache utilisation %.0f%%\n", nameByUUID[uuid], p)
	}
	fmt.Println("OK: rrd-metrics")
}

// --- 45. Reclaim freed space on a thin SR ---------------------------------------------
func reclaimSpace(url, user, password string) {
	session := connect(url, user, password)

	// Storage-manager backends that advertise SR_TRIM in their features map are trim-capable.
	sms, err := xenapi.SM.GetAllRecords(session)
	check(err)
	trimTypes := map[string]bool{}
	for _, sm := range sms {
		if _, ok := sm.Features["SR_TRIM"]; ok {
			trimTypes[sm.Type] = true
		}
	}

	srs, err := xenapi.SR.GetAllRecords(session)
	check(err)
	var sr xenapi.SRRecord
	found := false
	for _, r := range srs {
		if r.PhysicalSize > 0 && trimTypes[r.Type] {
			sr, found = r, true
			break
		}
	}
	if !found {
		panic("no trim-capable SR found")
	}

	// A host with a currently-attached PBD can reach the SR to run the plugin.
	var host xenapi.HostRef
	for _, pbdRef := range sr.PBDs {
		pbd, err := xenapi.PBD.GetRecord(session, pbdRef)
		check(err)
		if pbd.CurrentlyAttached {
			host = pbd.Host
			break
		}
	}

	result, err := xenapi.Host.CallPlugin(session, host, "trim", "do_trim",
		map[string]string{"sr_uuid": sr.UUID})
	check(err)
	fmt.Printf("  reclaimed freed space on %s: %s\n", sr.NameLabel, result)
	if result != "true" {
		panic("trim plugin returned " + result)
	}
	fmt.Println("OK: reclaim-space")
	session.Logout()
}

// --- 46. Get a VM's IP address --------------------------------------------------------
func vmIpAddress(url, user, password string) {
	session := connect(url, user, password)

	// A running guest reports its IP in VM_guest_metrics.networks, keyed "<vif device>/ip".
	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var vm xenapi.VMRecord
	found := false
	for _, r := range vms {
		if r.PowerState == xenapi.VMPowerStateRunning && !r.IsATemplate && !r.IsControlDomain &&
			r.GuestMetrics != xenapi.VMGuestMetricsRef("OpaqueRef:NULL") {
			vm, found = r, true
			break
		}
	}
	if !found {
		panic("no running guest VM found")
	}

	gm, err := xenapi.VMGuestMetrics.GetRecord(session, vm.GuestMetrics)
	check(err)
	ip, ok := gm.Networks["0/ip"]
	if !ok {
		ip = "(no address reported)"
	}
	fmt.Printf("  %s: %s\n", vm.NameLabel, ip)
	fmt.Println("OK: vm-ip-address")
	session.Logout()
}

// --- 47. Manage Active Directory users ------------------------------------------------
func manageAdUsers(url, user, password string) {
	session := connect(url, user, password)

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	pool := pools[0]
	check(xenapi.Pool.EnableExternalAuth(session, pool,
		map[string]string{"user": "administrator", "pass": "secret", "ldaps": "false"}, "citrix.local", "AD"))
	fmt.Println("Joined domain: citrix.local")

	sid, err := xenapi.Auth.GetSubjectIdentifier(session, "alice@citrix.local")
	check(err)
	info, err := xenapi.Auth.GetSubjectInformationFromIdentifier(session, sid)
	check(err)
	subject, err := xenapi.Subject.Create(session, xenapi.SubjectRecord{SubjectIdentifier: sid, OtherConfig: info})
	check(err)

	roles, err := xenapi.Role.GetAllRecords(session)
	check(err)
	var admin xenapi.RoleRef
	for ref, r := range roles {
		if r.NameLabel == "pool-admin" && len(r.Subroles) > 0 {
			admin = ref
			break
		}
	}
	check(xenapi.Subject.AddToRoles(session, subject, admin))
	assigned, err := xenapi.Subject.GetRoles(session, subject)
	check(err)
	names := ""
	for _, r := range assigned {
		n, _ := xenapi.Role.GetNameLabel(session, r)
		names += n + " "
	}
	fmt.Printf("Added subject %s (%s) as %s\n",
		info["subject-displayname"], info["subject-name"], strings.TrimSpace(names))

	// Revoking access does not end sessions the user already has: logging the subject out is a separate
	// act, and the one that actually gets them off the pool now rather than at next login.
	loggedIn, err := session.GetAllSubjectIdentifiers()
	check(err)
	fmt.Printf("Logged-in subjects: %d\n", len(loggedIn))
	check(session.LogoutSubjectIdentifier(sid))
	fmt.Printf("  logged out %s\n", info["subject-name"])

	check(xenapi.Subject.RemoveFromRoles(session, subject, admin))
	check(xenapi.Subject.Destroy(session, subject))
	check(xenapi.Pool.DisableExternalAuth(session, pool, map[string]string{}))
	fmt.Println("OK: manage-ad-users")
	session.Logout()
}

// --- 48. Create an iSCSI SR -----------------------------------------------------------
func createIscsiSr(url, user, password string) {
	const GiB = 1024 * 1024 * 1024
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	dc := map[string]string{
		"target":    "192.0.2.30",
		"targetIQN": "iqn.2009-01.com.xenpretender:target-0",
		"SCSIid":    "360a980004265656d5f4a2d63764e5734",
	}
	sr, err := xenapi.SR.Create(session, hosts[0], dc, 0, "sdk-iscsi-sr",
		"iSCSI SR created by the SDK example", "lvmoiscsi", "user", true, map[string]string{})
	check(err)
	size, _ := xenapi.SR.GetPhysicalSize(session, sr)
	uuid, _ := xenapi.SR.GetUUID(session, sr)
	fmt.Printf("Created SR: %s (%d GiB)\n", uuid, size/GiB)
	check(xenapi.SR.Forget(session, sr))
	fmt.Println("OK: create-iscsi-sr")
	session.Logout()
}

// --- 49. Create an SMB SR -------------------------------------------------------------
func createSmbSr(url, user, password string) {
	const GiB = 1024 * 1024 * 1024
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	dc := map[string]string{
		"server":     "192.0.2.40",
		"serverpath": "/vmstore",
		"username":   "Administrator",
		"password":   "Password1",
	}
	sr, err := xenapi.SR.Create(session, hosts[0], dc, 0, "sdk-smb-sr",
		"SMB SR created by the SDK example", "smb", "user", true, map[string]string{})
	check(err)
	size, _ := xenapi.SR.GetPhysicalSize(session, sr)
	uuid, _ := xenapi.SR.GetUUID(session, sr)
	fmt.Printf("Created SR: %s (%d GiB)\n", uuid, size/GiB)
	check(xenapi.SR.Forget(session, sr))
	fmt.Println("OK: create-smb-sr")
	session.Logout()
}

// --- 50. Create an HBA SR -------------------------------------------------------------
func createHbaSr(url, user, password string) {
	const GiB = 1024 * 1024 * 1024
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	dc := map[string]string{"SCSIid": "360a980004265656d5f4a2d63764e5736"}
	sr, err := xenapi.SR.Create(session, hosts[0], dc, 0, "sdk-hba-sr",
		"HBA SR created by the SDK example", "lvmohba", "user", true, map[string]string{})
	check(err)
	size, _ := xenapi.SR.GetPhysicalSize(session, sr)
	uuid, _ := xenapi.SR.GetUUID(session, sr)
	fmt.Printf("Created SR: %s (%d GiB)\n", uuid, size/GiB)
	check(xenapi.SR.Forget(session, sr))
	fmt.Println("OK: create-hba-sr")
	session.Logout()
}

// --- 51. Create a GFS2 SR -------------------------------------------------------------
func createGfs2Sr(url, user, password string) {
	const GiB = 1024 * 1024 * 1024
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	dc := map[string]string{
		"provider":  "iscsi",
		"target":    "192.0.2.30",
		"targetIQN": "iqn.2009-01.com.xenpretender:target-0",
		"SCSIid":    "360a980004265656d5f4a2d63764e5735",
	}
	sr, err := xenapi.SR.Create(session, hosts[0], dc, 0, "sdk-gfs2-sr",
		"GFS2 SR created by the SDK example", "gfs2", "user", true, map[string]string{})
	check(err)
	size, _ := xenapi.SR.GetPhysicalSize(session, sr)
	uuid, _ := xenapi.SR.GetUUID(session, sr)
	fmt.Printf("Created SR: %s (%d GiB)\n", uuid, size/GiB)
	check(xenapi.SR.Forget(session, sr))
	fmt.Println("OK: create-gfs2-sr")
	session.Logout()
}

// --- 52. Create an ISO library SR -----------------------------------------------------
func createIsoSr(url, user, password string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	dc := map[string]string{"location": "192.0.2.10:/isos", "type": "nfs_iso"}
	sr, err := xenapi.SR.Create(session, hosts[0], dc, 0, "sdk-iso-sr",
		"ISO library created by the SDK example", "iso", "iso", true, map[string]string{})
	check(err)
	uuid, _ := xenapi.SR.GetUUID(session, sr)
	fmt.Printf("Created ISO SR: %s\n", uuid)
	check(xenapi.SR.Forget(session, sr))
	fmt.Println("OK: create-iso-sr")
	session.Logout()
}

// --- 53. Configure NRPE monitoring ----------------------------------------------------
func configureNrpe(url, user, password string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	host := hosts[0]
	nrpe := func(fn string, args map[string]string) string {
		r, e := xenapi.Host.CallPlugin(session, host, "nrpe", fn, args)
		check(e)
		return r
	}
	fmt.Printf("NRPE status before: %s\n", strings.TrimSpace(nrpe("status", map[string]string{})))
	nrpe("enable", map[string]string{})
	nrpe("set-config", map[string]string{"allowed_hosts": "127.0.0.1,::1,10.0.0.5", "debug": "0", "ssl_logging": "0x00"})
	nrpe("restart", map[string]string{})
	fmt.Printf("NRPE status after:  %s\n", strings.TrimSpace(nrpe("status", map[string]string{})))
	for _, line := range strings.Split(nrpe("get-config", map[string]string{}), "\n") {
		if strings.HasPrefix(line, "allowed_hosts:") {
			fmt.Printf("Allowed hosts: %s\n", strings.TrimSpace(strings.SplitN(line, ":", 2)[1]))
		}
	}
	fmt.Println("OK: configure-nrpe")
	session.Logout()
}

// --- 54. Configure SNMP monitoring ----------------------------------------------------
func configureSnmp(url, user, password string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	host := hosts[0]
	snmp := func(fn string, args map[string]string) map[string]interface{} {
		r, e := xenapi.Host.CallPlugin(session, host, "snmp", fn, args)
		check(e)
		var env map[string]interface{}
		check(json.Unmarshal([]byte(r), &env))
		return env
	}
	config := `{"common":{"enabled":"yes","debug_log":"no"},` +
		`"agent":{"v2c":"yes","v3":"no","community":"sdk-community","user_name":"",` +
		`"authentication_password":"","authentication_protocol":"",` +
		`"privacy_password":"","privacy_protocol":""},"nmss":[]}`
	snmp("set-config", map[string]string{"config": config})
	status := snmp("status", map[string]string{})["result"].(map[string]interface{})
	cfg := snmp("get-config", map[string]string{})["result"].(map[string]interface{})
	agent := cfg["agent"].(map[string]interface{})
	fmt.Printf("SNMP enabled: %v / %v\n", status["enabled"], status["active"])
	fmt.Printf("Community: %v\n", agent["community"])
	fmt.Println("OK: configure-snmp")
	session.Logout()
}

// --- Manage a vApp ---------------------------------------------------------------------
func manageVapp(url, user, password, vmName string) {
	session := connect(url, user, password)
	vms, err := xenapi.VM.GetByNameLabel(session, vmName)
	check(err)
	vm := vms[0]

	vapp, err := xenapi.VMAppliance.Create(session, xenapi.VMApplianceRecord{
		NameLabel:       "sdk-example-vapp",
		NameDescription: "Created by the SDK example",
	})
	check(err)

	// `order` decides the sequence: ascending to start, descending to shut down. That ordering is the
	// reason to use a vApp rather than selecting several VMs.
	check(xenapi.VM.SetAppliance(session, vm, vapp))
	check(xenapi.VM.SetOrder(session, vm, 0))
	check(xenapi.VM.SetStartDelay(session, vm, 5))

	check(xenapi.VMAppliance.Start(session, vapp, false))
	state, _ := xenapi.VM.GetPowerState(session, vm)
	fmt.Printf("Started:        %s\n", state)

	check(xenapi.VMAppliance.CleanShutdown(session, vapp))
	state, _ = xenapi.VM.GetPowerState(session, vm)
	fmt.Printf("Shut down:      %s\n", state)

	check(xenapi.VM.SetAppliance(session, vm, ""))
	check(xenapi.VMAppliance.Destroy(session, vapp))
	fmt.Println("OK: manage-vapp")
	session.Logout()
}

// --- Attach a USB device to a VM ---------------------------------------------------------
func attachUsbDevice(url, user, password, vmName string) {
	session := connect(url, user, password)
	vms, err := xenapi.VM.GetByNameLabel(session, vmName)
	check(err)
	vm := vms[0]

	pusbs, err := xenapi.PUSB.GetAllRecords(session)
	check(err)
	var pusbRef xenapi.PUSBRef
	var pusb xenapi.PUSBRecord
	for ref, rec := range pusbs {
		pusbRef, pusb = ref, rec
		break
	}
	fmt.Printf("Device:         %s\n", pusb.Description)

	// Passthrough is off until an administrator releases the device: attaching one that has not been
	// released fails rather than silently doing nothing.
	check(xenapi.PUSB.SetPassthroughEnabled(session, pusbRef, true))

	vusb, err := xenapi.VUSB.Create(session, vm, pusb.USBGroup, map[string]string{})
	check(err)
	attached, _ := xenapi.VM.GetVUSBs(session, vm)
	fmt.Printf("Attached:       %d device(s)\n", len(attached))

	check(xenapi.VUSB.Destroy(session, vusb))
	check(xenapi.PUSB.SetPassthroughEnabled(session, pusbRef, false))
	fmt.Println("OK: attach-usb-device")
	session.Logout()
}

// --- Read workload-balancing recommendations ----------------------------------------------
func wlbRecommendations(url, user, password, vmName string) {
	session := connect(url, user, password)
	check(xenapi.Pool.InitializeWlb(session, "https://wlb.example:8012", "wlbuser", "wlbpass",
		user, password))

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	wlbURL, _ := xenapi.Pool.GetWlbURL(session, pools[0])
	fmt.Printf("WLB: %s\n", wlbURL)

	// Read BY POSITION, and the two calls do not share a shape. The pool's are keyed by VM and say
	// where to move it: [0] "wlb", [1] the destination host's UUID (a uuid, not a ref), [2] and [3]
	// ids, [4] the reason.
	poolRecs, err := xenapi.Pool.RetrieveWlbRecommendations(session)
	check(err)
	for vmRef, fields := range poolRecs {
		name, _ := xenapi.VM.GetNameLabel(session, vmRef)
		fmt.Printf("  move %s -> host %s (%s)\n", name, fields[1], fields[4])
	}

	// A VM's own are keyed by host and star-rate each destination: [0] "wlb", [1] the rating.
	vms, err := xenapi.VM.GetByNameLabel(session, vmName)
	check(err)
	vmRecs, err := xenapi.VM.RetrieveWlbRecommendations(session, vms[0])
	check(err)
	for hostRef, fields := range vmRecs {
		name, _ := xenapi.Host.GetNameLabel(session, hostRef)
		fmt.Printf("  %s rated %s\n", name, fields[1])
	}

	// The appliance's own settings are read and written as one flat map of strings. Send a nightly
	// reporting schedule, then read the configuration back to confirm it took.
	check(xenapi.Pool.SendWlbConfiguration(session, map[string]string{"ReportingCronString": "0 3 * * *"}))
	config, err := xenapi.Pool.RetrieveWlbConfiguration(session)
	check(err)
	keys := make([]string, 0, len(config))
	for k := range config {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	pairs := make([]string, 0, len(keys))
	for _, k := range keys {
		pairs = append(pairs, fmt.Sprintf("%s=%s", k, config[k]))
	}
	fmt.Printf("  appliance configuration: %s\n", strings.Join(pairs, ", "))

	check(xenapi.Pool.DeconfigureWlb(session))
	fmt.Println("OK: wlb-recommendations")
	session.Logout()
}

// --- Configure clustering (GFS2) ---------------------------------------------------------
func configureClustering(url, user, password string) {
	session := connect(url, user, password)

	// Clustering is what shared block storage needs before GFS2 thin provisioning. Pick a network every
	// host can reach: corosync is latency-sensitive, and a cluster that loses quorum takes its GFS2
	// storage offline with it.
	networks, err := xenapi.Network.GetAll(session)
	check(err)

	existing, err := xenapi.Cluster.GetAll(session)
	check(err)
	var cluster xenapi.ClusterRef
	if len(existing) > 0 {
		cluster = existing[0]
	} else {
		cluster, err = xenapi.Cluster.PoolCreate(session, networks[0], "corosync", 20000, 1000)
		check(err)
	}

	stack, _ := xenapi.Cluster.GetClusterStack(session, cluster)
	quorate, _ := xenapi.Cluster.GetIsQuorate(session, cluster)
	live, _ := xenapi.Cluster.GetLiveHosts(session, cluster)
	quorum, _ := xenapi.Cluster.GetQuorum(session, cluster)
	fmt.Printf("Stack:      %s\n", stack)
	fmt.Printf("Quorate:    %t (%d/%d needed)\n", quorate, live, quorum)

	// Taking a host out is what a management-interface change does; it can cost quorum.
	members, err := xenapi.ClusterHost.GetAll(session)
	check(err)
	check(xenapi.ClusterHost.Disable(session, members[0]))
	quorate, _ = xenapi.Cluster.GetIsQuorate(session, cluster)
	fmt.Printf("One member out, quorate: %t\n", quorate)

	check(xenapi.ClusterHost.Enable(session, members[0]))
	check(xenapi.Cluster.PoolResync(session, cluster))
	quorate, _ = xenapi.Cluster.GetIsQuorate(session, cluster)
	fmt.Printf("Resynced,   quorate: %t\n", quorate)

	fmt.Println("OK: configure-clustering")
	session.Logout()
}

// --- Manage pool membership --------------------------------------------------------------
func managePoolMembership(url, user, password string) {
	session := connect(url, user, password)
	pools, err := xenapi.Pool.GetAll(session)
	check(err)

	original, err := xenapi.Pool.GetMaster(session, pools[0])
	check(err)
	name, _ := xenapi.Host.GetNameLabel(session, original)
	fmt.Printf("Coordinator: %s\n", name)

	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	var other xenapi.HostRef
	for _, h := range hosts {
		hn, _ := xenapi.Host.GetNameLabel(session, h)
		suffix := ""
		if h == original {
			suffix = " (coordinator)"
		} else {
			other = h
		}
		fmt.Printf("  member: %s%s\n", hn, suffix)
	}

	// Promote another member. The pool database moves with the role and clients are redirected, so this
	// briefly interrupts management traffic — it does not move any VM.
	check(xenapi.Pool.DesignateNewMaster(session, other))
	otherName, _ := xenapi.Host.GetNameLabel(session, other)
	fmt.Printf("Promoted:    %s\n", otherName)

	// Put it back. Ejecting a member (Pool.Eject) is the other half of this surface and is deliberately
	// not shown: it cannot be undone from the pool, because rejoining is initiated by the ejected host.
	check(xenapi.Pool.DesignateNewMaster(session, original))
	fmt.Printf("Restored:    %s\n", name)

	fmt.Println("OK: manage-pool-membership")
	session.Logout()
}

// --- Create a NIC bond ---------------------------------------------------------------------
func createBond(url, user, password string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)

	// Pick up any NIC racked since the host booted. Cheap, and without it a card added a moment
	// ago is not there to bond.
	check(xenapi.PIF.Scan(session, hosts[0]))

	// Spare NICs only. A bond that includes the management interface moves the management address onto
	// the bond master — on a real host that is how you lose the connection you are working over.
	pifs, err := xenapi.PIF.GetAllRecords(session)
	check(err)
	var spares []xenapi.PIFRef
	var devices []string
	for ref, pif := range pifs {
		if pif.Host == hosts[0] && !pif.Management && pif.Physical && len(spares) < 2 {
			spares = append(spares, ref)
			devices = append(devices, pif.Device)
		}
	}
	fmt.Printf("Bonding:      %s\n", strings.Join(devices, ", "))

	// The bond needs a network to sit on.
	network, err := xenapi.Network.Create(session, xenapi.NetworkRecord{
		NameLabel:       "sdk-example-bond",
		NameDescription: "Created by the SDK example",
	})
	check(err)

	// The Go binding's Create carries the properties map the other bindings default for you.
	bond, err := xenapi.Bond.Create(session, network, spares, "", xenapi.BondModeBalanceSlb,
		map[string]string{})
	check(err)
	master, _ := xenapi.Bond.GetMaster(session, bond)
	masterDev, _ := xenapi.PIF.GetDevice(session, master)
	mode, _ := xenapi.Bond.GetMode(session, bond)
	fmt.Printf("Bond master:  %s\n", masterDev)
	fmt.Printf("Mode:         %s\n", mode)

	check(xenapi.Bond.Destroy(session, bond))
	check(xenapi.Network.Destroy(session, network))
	left, _ := xenapi.Bond.GetAll(session)
	fmt.Printf("Bonds left:   %d\n", len(left))
	fmt.Println("OK: create-bond")
	session.Logout()
}

// --- Configure PVS Accelerator ---
func configurePvsAccelerator(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	site, err := xenapi.PVSSite.Introduce(session, "sdk-pvs-farm", "Created by the SDK examples", "")
	check(err)
	_, err = xenapi.PVSServer.Introduce(session, []string{"10.62.0.90"}, 6910, 6930, site)
	check(err)

	// The read cache must be on LOCAL storage. The point of the accelerator is to keep reads off the
	// network, so a cache on a shared SR would defeat it and the server rejects one.
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	for _, host := range hosts {
		local, ok := localSR(session, host)
		if !ok {
			continue
		}
		_, err = xenapi.PVSCacheStorage.Create(session, xenapi.PVSCacheStorageRecord{
			Host: host, SR: local, Site: site, Size: 10 * 1024 * 1024 * 1024,
		})
		check(err)
	}

	// A proxy may only sit on the VM's LOWEST-numbered NIC, so sort by device rather than taking
	// VIFs[0] — the list comes back in creation order, which is the same thing only by luck.
	vm := firstUnacceleratedGuest(session)
	vifs := append([]xenapi.VIFRef(nil), vm.VIFs...)
	sort.Slice(vifs, func(i, j int) bool { return vifDevice(session, vifs[i]) < vifDevice(session, vifs[j]) })
	proxy, err := xenapi.PVSProxy.Create(session, site, vifs[0])
	check(err)

	record, err := xenapi.PVSSite.GetRecord(session, site)
	check(err)
	fmt.Printf("Site '%s' with %d cache(s) and %d server(s)\n",
		record.NameLabel, len(record.CacheStorage), len(record.Servers))
	// "caching" means it is actually accelerating. A site with no cache storage reports "initialised",
	// and a proxy on a VM whose NIC is unplugged reports "stopped".
	status, err := xenapi.PVSProxy.GetStatus(session, proxy)
	check(err)
	fmt.Printf("  %s: %s\n", vm.NameLabel, status)

	// Forgetting the site takes its servers, caches and proxies with it.
	check(xenapi.PVSSite.Forget(session, site))
	fmt.Println("OK: configure-pvs-accelerator")
}

// localSR returns the host's own non-ISO storage, found through its PBDs.
func localSR(session *xenapi.Session, host xenapi.HostRef) (xenapi.SRRef, bool) {
	pbds, err := xenapi.Host.GetPBDs(session, host)
	check(err)
	for _, pbd := range pbds {
		ref, err := xenapi.PBD.GetSR(session, pbd)
		check(err)
		sr, err := xenapi.SR.GetRecord(session, ref)
		check(err)
		if !sr.Shared && sr.ContentType != "iso" && sr.Type != "udev" {
			return ref, true
		}
	}
	return "", false
}

func vifDevice(session *xenapi.Session, vif xenapi.VIFRef) int {
	device, err := xenapi.VIF.GetDevice(session, vif)
	check(err)
	n, _ := strconv.Atoi(device)
	return n
}

// firstUnacceleratedGuest returns a running guest with a NIC that no proxy already covers. A VIF can
// carry only one proxy, so a VM the pool already accelerates fails with PVS_PROXY_ALREADY_PRESENT.
func firstUnacceleratedGuest(session *xenapi.Session) xenapi.VMRecord {
	taken := map[xenapi.VMRef]bool{}
	proxies, err := xenapi.PVSProxy.GetAll(session)
	check(err)
	for _, proxy := range proxies {
		vif, err := xenapi.PVSProxy.GetVIF(session, proxy)
		check(err)
		vm, err := xenapi.VIF.GetVM(session, vif)
		check(err)
		taken[vm] = true
	}
	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	for ref, v := range vms {
		if v.IsATemplate || v.IsControlDomain || v.IsASnapshot || taken[ref] {
			continue
		}
		if v.PowerState == xenapi.VMPowerStateRunning && len(v.VIFs) > 0 {
			return v
		}
	}
	panic("no unaccelerated running guest with a NIC")
}

// --- Manage SSH access ---
func manageSSHAccess(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)

	// Timed access is the point: set the timeout first and the server stamps an expiry when SSH is
	// enabled, so a window opened for troubleshooting closes itself.
	for _, host := range hosts {
		check(xenapi.Host.SetSSHEnabledTimeout(session, host, 3600))
	}

	// The pool call fans out to every host, so there is no need to loop for the enable itself.
	check(xenapi.Pool.EnableSSH(session, pools[0]))
	for _, host := range hosts {
		record, err := xenapi.Host.GetRecord(session, host)
		check(err)
		fmt.Printf("%s: ssh enabled=%t, expires %s\n", record.NameLabel, record.SSHEnabled,
			record.SSHExpiry.UTC().Format("20060102T15:04:05Z"))
	}

	check(xenapi.Pool.DisableSSH(session, pools[0]))
	states := []string{}
	for _, host := range hosts {
		record, err := xenapi.Host.GetRecord(session, host)
		check(err)
		states = append(states, fmt.Sprintf("%s=%t", record.NameLabel, record.SSHEnabled))
	}
	fmt.Printf("After disable: %s\n", strings.Join(states, ", "))
	fmt.Println("OK: manage-ssh-access")
}

// --- Change control domain memory ---
func controlDomainMemory(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	dom0, ok := controlDomainOf(session, hosts[0])
	if !ok {
		panic("the host reports no control domain")
	}

	original, err := xenapi.VM.GetMemoryDynamicMin(session, dom0)
	check(err)
	name, _ := xenapi.Host.GetNameLabel(session, hosts[0])
	fmt.Printf("%s dom0: %.1f GiB\n", name, float64(original)/(1024*1024*1024))

	// One setter, not a range: dom0 does not balloon, so SetMemory pins the static and dynamic bounds
	// and the target together. The new size takes effect at the next reboot, which is why XenCenter
	// offers this only in maintenance mode — the API itself does not stop you.
	check(xenapi.VM.SetMemory(session, dom0, original+1024*1024*1024))
	record, err := xenapi.VM.GetRecord(session, dom0)
	check(err)
	fmt.Printf("  now %.1f GiB (static %d-%d, dynamic %d-%d)\n",
		float64(record.MemoryDynamicMin)/(1024*1024*1024),
		record.MemoryStaticMin, record.MemoryStaticMax,
		record.MemoryDynamicMin, record.MemoryDynamicMax)

	check(xenapi.VM.SetMemory(session, dom0, original)) // leave the pool as we found it
	fmt.Println("OK: control-domain-memory")
}

func controlDomainOf(session *xenapi.Session, host xenapi.HostRef) (xenapi.VMRef, bool) {
	vms, err := xenapi.Host.GetResidentVMs(session, host)
	check(err)
	for _, vm := range vms {
		isDom0, err := xenapi.VM.GetIsControlDomain(session, vm)
		check(err)
		if isDom0 {
			return vm, true
		}
	}
	return "", false
}

// --- Manage a vTPM ---
func manageVtpm(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var vm xenapi.VMRef
	var record xenapi.VMRecord
	for ref, v := range vms {
		if !v.IsATemplate && !v.IsControlDomain && !v.IsASnapshot &&
			v.PowerState == xenapi.VMPowerStateHalted && len(v.VTPMs) == 0 {
			vm, record = ref, v
			break
		}
	}
	fmt.Printf("Attaching a vTPM to %s\n", record.NameLabel)

	// isUnique=false: the vTPM may be copied along with the VM. A VM may have at most one, and it can
	// only be attached while Halted — the device is presented at boot.
	vtpm, err := xenapi.VTPM.Create(session, vm, false)
	check(err)
	vtpmRecord, err := xenapi.VTPM.GetRecord(session, vtpm)
	check(err)
	fmt.Printf("  persistence backend: %s\n", vtpmRecord.PersistenceBackend)
	fmt.Printf("  unique to this VM:   %t\n", vtpmRecord.IsUnique)
	attached, err := xenapi.VM.GetVTPMs(session, vm)
	check(err)
	fmt.Printf("  VM now has %d vTPM(s)\n", len(attached))

	// The VM advertises whether another can be added; once it has one, it cannot.
	ops, err := xenapi.VM.GetAllowedOperations(session, vm)
	check(err)
	canAdd := false
	for _, op := range ops {
		if op == xenapi.VMOperationsCreateVtpm {
			canAdd = true
		}
	}
	fmt.Printf("  can add another:     %t\n", canAdd)

	check(xenapi.VTPM.Destroy(session, vtpm))
	attached, err = xenapi.VM.GetVTPMs(session, vm)
	check(err)
	fmt.Printf("  after removal:       %d vTPM(s)\n", len(attached))
	fmt.Println("OK: manage-vtpm")
}

// --- Back up with changed block tracking ---
func changedBlockTracking(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var vm xenapi.VMRef
	var record xenapi.VMRecord
	for ref, v := range vms {
		if !v.IsATemplate && !v.IsControlDomain && !v.IsASnapshot && len(v.VBDs) > 0 {
			vm, record = ref, v
			break
		}
	}
	fmt.Printf("Backing up %s\n", record.NameLabel)

	first, err := xenapi.VM.Snapshot(session, vm, "cbt-backup-1", nil)
	check(err)
	second, err := xenapi.VM.Snapshot(session, vm, "cbt-backup-2", nil)
	check(err)
	vdiFrom, vdiTo := firstDisk(session, first), firstDisk(session, second)
	check(xenapi.VDI.EnableCbt(session, vdiFrom))
	check(xenapi.VDI.EnableCbt(session, vdiTo))

	// One bit per 64 KiB block, base64-encoded; bit N set means block N changed. A real backup reads
	// only those blocks, over NBD.
	encoded, err := xenapi.VDI.ListChangedBlocks(session, vdiFrom, vdiTo)
	check(err)
	bitmap, err := base64.StdEncoding.DecodeString(encoded)
	check(err)
	changed := 0
	for _, b := range bitmap {
		changed += bits.OnesCount8(b)
	}
	size, err := xenapi.VDI.GetVirtualSize(session, vdiTo)
	check(err)
	fmt.Printf("  %d blocks of %d changed (%.1f MiB to copy, not %.1f MiB)\n",
		changed, len(bitmap)*8, float64(changed)*64/1024, float64(size)/(1024*1024))

	// Release the older snapshot's blocks but keep its change metadata, so the next incremental can
	// still diff against it. The VDI record stays; its type changes.
	check(xenapi.VDI.DataDestroy(session, vdiFrom))
	vdiType, err := xenapi.VDI.GetType(session, vdiFrom)
	check(err)
	stillTracked, err := xenapi.VDI.GetCbtEnabled(session, vdiFrom)
	check(err)
	fmt.Printf("  older snapshot is now type=%s, still cbt_enabled=%t\n", vdiType, stillTracked)

	check(xenapi.VM.Destroy(session, first))
	check(xenapi.VM.Destroy(session, second))
	fmt.Println("OK: changed-block-tracking")
}

// firstDisk returns the VDI behind a VM's first real disk (a CD drive is a VBD too).
func firstDisk(session *xenapi.Session, vm xenapi.VMRef) xenapi.VDIRef {
	vbds, err := xenapi.VM.GetVBDs(session, vm)
	check(err)
	for _, vbd := range vbds {
		vbdType, err := xenapi.VBD.GetType(session, vbd)
		check(err)
		if vbdType == xenapi.VbdTypeDisk {
			vdi, err := xenapi.VBD.GetVDI(session, vbd)
			check(err)
			return vdi
		}
	}
	panic("no disk found")
}

// --- Export and import a VM ---
func exportImportVm(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	// Only a halted VM can be exported: its disks must not be changing underneath the copy.
	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var vm xenapi.VMRef
	var record xenapi.VMRecord
	for ref, v := range vms {
		if !v.IsATemplate && !v.IsControlDomain && !v.IsASnapshot &&
			v.PowerState == xenapi.VMPowerStateHalted {
			vm, record = ref, v
			break
		}
	}
	fmt.Printf("Exporting %s\n", record.NameLabel)

	// Export and import are HTTP transfers alongside the API, not API calls, so the session id travels
	// in the query string. The Go binding keeps its own session private, so obtain one the same way the
	// RRD example does: a small JSON-RPC login of our own.
	sid := rawLogin(url, user, password)
	// A unique file, not a fixed name: an export is a real file on disk and two of them running at once
	// would otherwise fight over it.
	temp, err := os.CreateTemp("", "sdk-example-export-*.xva")
	check(err)
	path := temp.Name()
	temp.Close()
	uuid, err := xenapi.VM.GetUUID(session, vm)
	check(err)
	resp, err := insecureClient().Get(fmt.Sprintf("%s/export?session_id=%s&uuid=%s", url, sid, uuid))
	check(err)
	out, err := os.Create(path)
	check(err)
	written, err := io.Copy(out, resp.Body)
	check(err)
	resp.Body.Close()
	out.Close()
	fmt.Printf("  wrote %.1f MiB to %s\n", float64(written)/(1024*1024), filepath.Base(path))

	// An XVA is a tar: ova.xml describes the VM, and the disk blocks follow in 1 MiB pieces, each with
	// its own checksum.
	names := tarNames(path)
	blocks := 0
	for _, n := range names {
		if !strings.HasSuffix(n, ".checksum") {
			blocks++
		}
	}
	fmt.Printf("  archive holds %s and %d disk block(s)\n", names[0], blocks-1)

	archive, err := os.Open(path)
	check(err)
	request, err := http.NewRequest(http.MethodPut,
		fmt.Sprintf("%s/import?session_id=%s", url, sid), archive)
	check(err)
	info, err := archive.Stat()
	check(err)
	request.ContentLength = info.Size()
	putResp, err := insecureClient().Do(request)
	check(err)
	body, err := io.ReadAll(putResp.Body)
	check(err)
	putResp.Body.Close()
	archive.Close()

	imported := xenapi.VMRef(strings.TrimSpace(string(body)))
	name, err := xenapi.VM.GetNameLabel(session, imported)
	check(err)
	fmt.Printf("  imported as %s\n", name)

	check(xenapi.VM.Destroy(session, imported))
	check(os.Remove(path))
	fmt.Println("OK: export-import-vm")
}

// tarNames lists the entries of a tar archive.
func tarNames(path string) []string {
	file, err := os.Open(path)
	check(err)
	defer file.Close()
	var names []string
	reader := tar.NewReader(file)
	for {
		header, err := reader.Next()
		if err != nil {
			break
		}
		names = append(names, header.Name)
	}
	return names
}

// --- Configure dynamic memory ---
func configureDynamicMemory(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var vm xenapi.VMRef
	var before xenapi.VMRecord
	for ref, v := range vms {
		if !v.IsATemplate && !v.IsControlDomain && !v.IsASnapshot &&
			v.PowerState == xenapi.VMPowerStateHalted {
			vm, before = ref, v
			break
		}
	}
	fmt.Printf("%s: static %s-%s, dynamic %s-%s\n", before.NameLabel,
		gib(before.MemoryStaticMin), gib(before.MemoryStaticMax),
		gib(before.MemoryDynamicMin), gib(before.MemoryDynamicMax))

	// Room to balloon: let the host squeeze the VM down to a quarter of its maximum, but never below the
	// static floor, which is the least the guest can boot in.
	floor := before.MemoryStaticMax / 4
	if before.MemoryStaticMin > floor {
		floor = before.MemoryStaticMin
	}
	ceiling := before.MemoryStaticMax
	check(xenapi.VM.SetMemoryDynamicRange(session, vm, floor, ceiling))
	low, err := xenapi.VM.GetMemoryDynamicMin(session, vm)
	check(err)
	high, err := xenapi.VM.GetMemoryDynamicMax(session, vm)
	check(err)
	fmt.Printf("  dynamic range now %s-%s\n", gib(low), gib(high))

	// The ordering is enforced, not advisory: a range wider than the static bounds is refused rather than
	// quietly clamped.
	if err := xenapi.VM.SetMemoryDynamicRange(session, vm, floor, ceiling*2); err == nil {
		fmt.Println("  ERROR: an out-of-range maximum was accepted")
	} else {
		fmt.Printf("  refused a dynamic_max above static_max: %s\n", failureCode(err))
	}

	check(xenapi.VM.SetMemoryDynamicRange(session, vm, before.MemoryDynamicMin, before.MemoryDynamicMax))
	fmt.Println("OK: configure-dynamic-memory")
}

// failureCode picks the XenAPI error code out of the binding's error text. A failure arrives as a plain
// error whose message is the code followed by its arguments, so the code is the leading run of capitals.
var errorCodePattern = regexp.MustCompile(`[A-Z][A-Z0-9_]{3,}`)

func failureCode(err error) string {
	if code := errorCodePattern.FindString(err.Error()); code != "" {
		return code
	}
	return err.Error()
}

func gib(size int) string {
	return fmt.Sprintf("%.1f GiB", float64(size)/(1024*1024*1024))
}

// --- Manage a VM's CD drive ---
func manageVmMedia(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var vm xenapi.VMRef
	var record xenapi.VMRecord
	for ref, v := range vms {
		if !v.IsATemplate && !v.IsControlDomain && !v.IsASnapshot &&
			v.PowerState == xenapi.VMPowerStateHalted {
			vm, record = ref, v
			break
		}
	}
	fmt.Printf("Adding a DVD drive to %s\n", record.NameLabel)

	// A CD drive is a VBD like any other, distinguished by type=CD; the media is whichever VDI it points
	// at, and an empty drive points at none.
	devices, err := xenapi.VM.GetAllowedVBDDevices(session, vm)
	check(err)
	drive, err := xenapi.VBD.Create(session, xenapi.VBDRecord{
		VM:                 vm,
		VDI:                "OpaqueRef:NULL",
		Userdevice:         devices[0],
		Bootable:           false,
		Mode:               xenapi.VbdModeRO,
		Type:               xenapi.VbdTypeCD,
		Empty:              true,
		Unpluggable:        true,
		OtherConfig:        map[string]string{},
		QosAlgorithmParams: map[string]string{},
	})
	check(err)
	empty, err := xenapi.VBD.GetEmpty(session, drive)
	check(err)
	fmt.Printf("  drive %s is empty: %t\n", devices[0], empty)

	// The ISO library is an SR of content type "iso"; its VDIs are the available images.
	srs, err := xenapi.SR.GetAllRecords(session)
	check(err)
	var isoSr xenapi.SRRef
	for ref, s := range srs {
		if s.ContentType == "iso" && s.Type != "udev" {
			isoSr = ref
			break
		}
	}
	vdis, err := xenapi.SR.GetVDIs(session, isoSr)
	check(err)
	names := map[xenapi.VDIRef]string{}
	for _, v := range vdis {
		name, err := xenapi.VDI.GetNameLabel(session, v)
		check(err)
		names[v] = name
	}
	sort.Slice(vdis, func(i, j int) bool { return names[vdis[i]] < names[vdis[j]] })
	iso := vdis[0]
	fmt.Printf("  inserting %s\n", names[iso])
	check(xenapi.VBD.Insert(session, drive, iso))

	loaded, err := xenapi.VBD.GetVDI(session, drive)
	check(err)
	empty, err = xenapi.VBD.GetEmpty(session, drive)
	check(err)
	fmt.Printf("  drive now holds %s (empty=%t)\n", names[loaded], empty)

	check(xenapi.VBD.Eject(session, drive))
	empty, err = xenapi.VBD.GetEmpty(session, drive)
	check(err)
	fmt.Printf("  after eject, empty=%t\n", empty)

	check(xenapi.VBD.Destroy(session, drive))
	fmt.Println("OK: manage-vm-media")
}

// --- Back up a host's configuration ---
func backupHostConfig(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	host := hosts[0]
	name, err := xenapi.Host.GetNameLabel(session, host)
	check(err)
	fmt.Printf("Backing up %s\n", name)

	// Backup and restore are HTTP transfers alongside the API, not API calls, so the session id travels
	// in the query string. The Go binding keeps its own session private, so obtain one of our own.
	sid := rawLogin(url, user, password)
	temp, err := os.CreateTemp("", "sdk-example-host-*.backup")
	check(err)
	path := temp.Name()
	temp.Close()

	resp, err := insecureClient().Get(
		fmt.Sprintf("%s/host_backup?session_id=%s&ref=%s", url, sid, host))
	check(err)
	backup, err := io.ReadAll(resp.Body)
	check(err)
	resp.Body.Close()
	check(os.WriteFile(path, backup, 0o600))
	fmt.Printf("  wrote %d bytes to %s\n", len(backup), filepath.Base(path))

	fmt.Printf("  restoring it to %s: %s\n", name, restoreHostConfig(session, url, sid, host, backup))
	if len(hosts) > 1 {
		// The refusal is the half worth rehearsing: restoring one host's configuration onto another is
		// destructive and unrecoverable, so the pool checks rather than trusting the caller.
		other, err := xenapi.Host.GetNameLabel(session, hosts[1])
		check(err)
		fmt.Printf("  restoring it to %s: %s\n", other,
			restoreHostConfig(session, url, sid, hosts[1], backup))
	}

	check(os.Remove(path))
	fmt.Println("OK: backup-host-config")
}

// restoreHostConfig uploads a backup to a host and reports what the task says about it.
//
// An upload answers 200 as soon as it has read the request headers, because the client waits for that
// before it starts sending the file. The outcome therefore cannot be in the status line: it arrives on a
// task you create first, name in the URL, and poll once the upload has finished.
func restoreHostConfig(session *xenapi.Session, url, sid string, host xenapi.HostRef, backup []byte) string {
	task, err := xenapi.Task.Create(session, "host_restore", "restoring a configuration backup")
	check(err)
	defer xenapi.Task.Destroy(session, task)

	request, err := http.NewRequest(http.MethodPut,
		fmt.Sprintf("%s/host_restore?session_id=%s&ref=%s&task_id=%s", url, sid, host, task),
		bytes.NewReader(backup))
	check(err)
	request.ContentLength = int64(len(backup))
	resp, err := insecureClient().Do(request)
	check(err)
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()

	for {
		status, err := xenapi.Task.GetStatus(session, task)
		check(err)
		if status != xenapi.TaskStatusTypePending {
			if status == xenapi.TaskStatusTypeSuccess {
				return "accepted"
			}
			info, err := xenapi.Task.GetErrorInfo(session, task)
			check(err)
			return fmt.Sprintf("refused (%s)", info[len(info)-1])
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// --- Detach, reattach and forget storage ---
func manageSrLifecycle(url, user, password, nfsServer, nfsPath string) {
	session := connect(url, user, password)
	defer session.Logout()

	// There is no "detach" call on an SR. A shared SR is joined to each host by one PBD - a physical
	// block device - and detaching the SR means unplugging every one of them. That is why an SR can be
	// attached on some hosts and not others, and why a repair action exists at all: it plugs back the
	// PBDs that are missing.
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	sr, err := xenapi.SR.Create(session, hosts[0], map[string]string{
		"server":     nfsServer,
		"serverpath": nfsPath,
		"nfsversion": "3",
	}, 0, "sdk-example-lifecycle", "SR used by the SDK lifecycle example",
		"nfs", "user", true, map[string]string{})
	check(err)

	pbds, err := xenapi.SR.GetPBDs(session, sr)
	check(err)
	name, _ := xenapi.SR.GetNameLabel(session, sr)
	fmt.Printf("%s: connected on %d of %d host(s)\n", name, attachedPbds(session, pbds), len(pbds))

	for _, pbd := range pbds {
		check(xenapi.PBD.Unplug(session, pbd))
	}
	fmt.Printf("  detached:   connected on %d host(s)\n", attachedPbds(session, pbds))

	// Plugging them back is exactly what a repair does.
	for _, pbd := range pbds {
		check(xenapi.PBD.Plug(session, pbd))
	}
	fmt.Printf("  reattached: connected on %d host(s)\n", attachedPbds(session, pbds))

	check(xenapi.SR.Scan(session, sr))
	vdis, err := xenapi.SR.GetVDIs(session, sr)
	check(err)
	fmt.Printf("  rescanned:  %d disk(s)\n", len(vdis))

	// Forgetting drops the pool's record of the SR but leaves the storage itself untouched, so the same
	// export can be introduced again later. Detach before forgetting: a connected SR is still in use.
	for _, pbd := range pbds {
		check(xenapi.PBD.Unplug(session, pbd))
	}
	check(xenapi.SR.Forget(session, sr))
	fmt.Println("  forgotten")
	fmt.Println("OK: manage-sr-lifecycle")
}

// attachedPbds reports how many of these connections are currently live.
func attachedPbds(session *xenapi.Session, pbds []xenapi.PBDRef) int {
	live := 0
	for _, pbd := range pbds {
		attached, err := xenapi.PBD.GetCurrentlyAttached(session, pbd)
		check(err)
		if attached {
			live++
		}
	}
	return live
}

// Run it:
//   manageSrLifecycle("https://xenserver", "root", password, "192.0.2.10", "/export/spare")

// --- Set the pool's default storage ---
func setDefaultSr(url, user, password, nfsServer, nfsPath string) {
	session := connect(url, user, password)
	defer session.Logout()

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	pool := pools[0]

	// Capture all three separately. New disks land on the default SR, a suspended VM's memory image goes
	// to the suspend-image SR and host crash dumps to the crash-dump SR. They are usually the same
	// storage but need not be, and a pool that has never suspended or crashed anything can legitimately
	// leave the latter two unset - so restoring all three from the default would quietly invent settings
	// that were not there.
	before, err := xenapi.Pool.GetDefaultSR(session, pool)
	check(err)
	beforeSuspend, err := xenapi.Pool.GetSuspendImageSR(session, pool)
	check(err)
	beforeCrash, err := xenapi.Pool.GetCrashDumpSR(session, pool)
	check(err)
	fmt.Printf("default storage:  %s\n", srLabel(session, before))
	fmt.Printf("  suspend images: %s\n", srLabel(session, beforeSuspend))
	fmt.Printf("  crash dumps:    %s\n", srLabel(session, beforeCrash))

	// Somewhere to switch to. A pool default has to be reachable from every host, so it is a shared SR;
	// a local one would strand any VM whose disk landed on the wrong host.
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	sr, err := xenapi.SR.Create(session, hosts[0], map[string]string{
		"server":     nfsServer,
		"serverpath": nfsPath,
		"nfsversion": "3",
	}, 0, "sdk-example-default", "SR used by the SDK default-storage example",
		"nfs", "user", true, map[string]string{})
	check(err)

	check(xenapi.Pool.SetDefaultSR(session, pool, sr))
	check(xenapi.Pool.SetSuspendImageSR(session, pool, sr))
	check(xenapi.Pool.SetCrashDumpSR(session, pool, sr))
	now, _ := xenapi.Pool.GetDefaultSR(session, pool)
	fmt.Printf("  switched to:    %s\n", srLabel(session, now))

	// Restore the original choice before tidying up: an SR that is still the pool default is the awkward
	// one to remove.
	check(xenapi.Pool.SetDefaultSR(session, pool, before))
	check(xenapi.Pool.SetSuspendImageSR(session, pool, beforeSuspend))
	check(xenapi.Pool.SetCrashDumpSR(session, pool, beforeCrash))
	pbds, err := xenapi.SR.GetPBDs(session, sr)
	check(err)
	for _, pbd := range pbds {
		check(xenapi.PBD.Unplug(session, pbd))
	}
	check(xenapi.SR.Forget(session, sr))
	restored, _ := xenapi.Pool.GetDefaultSR(session, pool)
	fmt.Printf("  restored to:    %s\n", srLabel(session, restored))
	fmt.Println("OK: set-default-sr")
}

// srLabel is an SR's name, tolerating the null reference an unset pool field holds.
func srLabel(session *xenapi.Session, sr xenapi.SRRef) string {
	if sr == "" || sr == "OpaqueRef:NULL" {
		return "(none)"
	}
	name, err := xenapi.SR.GetNameLabel(session, sr)
	check(err)
	return name
}

// Run it:
//   setDefaultSr("https://xenserver", "root", password, "192.0.2.10", "/export/spare")

// --- Collect a server status report ---
func serverStatusReport(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	// Report on the coordinator. Each host answers for itself, so which one you ask decides whose logs
	// you get - support normally wants every host, one download each.
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	host, err := xenapi.Pool.GetMaster(session, pools[0])
	check(err)
	name, err := xenapi.Host.GetNameLabel(session, host)
	check(err)
	fmt.Printf("Status report for %s\n", name)

	// The host publishes a catalogue of the sections it can report on, each with a size estimate and
	// whether it may contain personal data, so a client can offer an informed choice rather than
	// hard-coding the list.
	capabilitiesXML, err := xenapi.Host.GetSystemStatusCapabilities(session, host)
	check(err)
	var catalogue struct {
		Capabilities []struct {
			Key            string `xml:"key,attr"`
			MaxSize        string `xml:"max-size,attr"`
			DefaultChecked string `xml:"default-checked,attr"`
			Pii            string `xml:"pii,attr"`
		} `xml:"capability"`
	}
	check(xml.Unmarshal([]byte(capabilitiesXML), &catalogue))
	var keys []string
	for _, capability := range catalogue.Capabilities {
		keys = append(keys, capability.Key)
		fmt.Printf("  %-22s max %9s bytes  default=%-3s pii=%s\n",
			capability.Key, capability.MaxSize, capability.DefaultChecked, capability.Pii)
	}

	// The download is an HTTP transfer alongside the API, so the session id travels in the query string.
	// The Go binding keeps its own session private, so obtain one of our own.
	sid := rawLogin(url, user, password)
	whole := fetchStatusReport(url, sid, keys)
	fmt.Printf("everything (%d sections): %d bytes\n", len(keys), whole)

	// Worth checking rather than assuming: a server that ignored the selection would look identical from
	// here until someone opened the archive and found the whole thing.
	subset := fetchStatusReport(url, sid, []string{"xenserver-config"})
	fmt.Printf("xenserver-config only:   %d bytes\n", subset)
	if subset >= whole {
		fmt.Println("  ERROR: selecting fewer sections did not produce a smaller bundle")
	}

	fmt.Println("OK: server-status-report")
}

// fetchStatusReport downloads the bundle for the given capability keys (a tar archive) and sizes it.
func fetchStatusReport(url, sid string, entries []string) int {
	resp, err := insecureClient().Get(fmt.Sprintf("%s/system-status?session_id=%s&output=tar&entries=%s",
		url, sid, strings.Join(entries, ",")))
	check(err)
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	check(err)
	return len(body)
}

// Run it:
//   serverStatusReport("https://xenserver", "root", password)

// --- Recover VMs after a disaster ---
func disasterRecovery(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	// Disaster recovery works by writing the pool's own database out to a storage repository as a disk of
	// type "metadata". That disk can be read back as a SEPARATE database, so the ordinary calls describe
	// the pool as it was replicated rather than the pool you are connected to.
	//
	// Replication needs storage every host can reach and that can hold data. The server checks rather
	// than taking your word for it, so ask before enabling.
	srs, err := xenapi.SR.GetAllRecords(session)
	check(err)
	var sr xenapi.SRRef
	for ref, r := range srs {
		if r.Shared && r.ContentType != "iso" && r.Type != "iso" && r.Type != "udev" {
			sr = ref
			break
		}
	}
	check(xenapi.SR.AssertSupportsDatabaseReplication(session, sr))
	srName, _ := xenapi.SR.GetNameLabel(session, sr)
	fmt.Printf("Replicating pool metadata to %s\n", srName)
	check(xenapi.SR.EnableDatabaseReplication(session, sr))

	vdis, err := xenapi.SR.GetVDIs(session, sr)
	check(err)
	var metadataVdi xenapi.VDIRef
	for _, v := range vdis {
		if t, _ := xenapi.VDI.GetType(session, v); t == xenapi.VdiTypeMetadata {
			metadataVdi = v
			break
		}
	}
	uuid, _ := xenapi.VDI.GetUUID(session, metadataVdi)
	fmt.Printf("  metadata disk: %s\n", uuid)

	metadataSession, err := xenapi.VDI.OpenDatabase(session, metadataVdi)
	check(err)

	// The Go binding keeps its session private and offers no way to build one from a session id it did
	// not create, so the metadata database has to be driven over plain JSON-RPC. Same reason the live
	// session id is obtained separately: recover() needs one to say where the VM should land.
	liveSession := rawLogin(url, user, password)
	var recoverable map[string]struct {
		NameLabel string `json:"name_label"`
	}
	check(json.Unmarshal(rawRPC(url, "VM.get_all_records", string(metadataSession)), &recoverable))
	fmt.Printf("  the replicated database describes %d recoverable VM(s)\n", len(recoverable))

	targets := make([]string, 0, len(recoverable))
	for ref := range recoverable {
		targets = append(targets, ref)
	}
	sort.Slice(targets, func(i, j int) bool {
		return recoverable[targets[i]].NameLabel < recoverable[targets[j]].NameLabel
	})
	target := targets[0]
	name := recoverable[target].NameLabel
	fmt.Printf("  recovering %s\n", name)

	// Both calls run on the METADATA session; the live session says where the VM should land.
	rawRPC(url, "VM.assert_can_be_recovered", string(metadataSession), target, liveSession)
	rawRPC(url, "VM.recover", string(metadataSession), target, liveSession, false)

	// It is a real VM in the live pool now, not merely a call that returned.
	live, err := xenapi.VM.GetAllRecords(session)
	check(err)
	for ref, r := range live {
		if r.NameLabel == name {
			fmt.Printf("  %s is %s in the live pool\n", name, r.PowerState)
			check(xenapi.VM.Destroy(session, ref))
			break
		}
	}

	check(xenapi.SR.DisableDatabaseReplication(session, sr))
	fmt.Println("OK: disaster-recovery")
}

// rawRPC makes a JSON-RPC call with an explicit session id — for the one thing the Go binding cannot
// express, a session it did not create itself.
func rawRPC(url, method string, params ...any) json.RawMessage {
	body, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": method, "params": params,
	})
	check(err)
	resp, err := insecureClient().Post(url+"/jsonrpc", "application/json", bytes.NewReader(body))
	check(err)
	defer resp.Body.Close()
	var r struct {
		Result json.RawMessage `json:"result"`
		Error  json.RawMessage `json:"error"`
	}
	check(json.NewDecoder(resp.Body).Decode(&r))
	if len(r.Error) > 0 && string(r.Error) != "null" {
		panic(fmt.Sprintf("%s failed: %s", method, r.Error))
	}
	return r.Result
}

// Run it:
//   disasterRecovery("https://xenserver", "root", password)

// --- Manage Secure Boot certificates ---
func manageSecurebootCertificates(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	// A Secure Boot guest carries its own copy of the pool's UEFI certificates, taken when it was
	// created. Rotating the pool's leaves the guest's stale, and the fix is applied at the guest's next
	// boot rather than underneath a running VM - so you flag it and reboot when convenient.
	//
	// First, whether the pool holds the certificates to hand out at all. "ready_no_dbx" means it has the
	// essentials but no revocation list - usable, and not the same answer as "ready".
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	readiness, err := xenapi.Pool.GetGuestSecurebootReadiness(session, pools[0])
	check(err)
	certs, err := xenapi.Pool.GetUefiCertificates(session, pools[0])
	check(err)
	fmt.Printf("Pool Secure Boot readiness: %s\n", readiness)
	fmt.Printf("  pool holds certificates:  %t\n", certs != "")

	// A guest whose certificates have gone stale. Its state is what a client gates the flag/unflag
	// actions on, so it is the field to watch.
	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var vm xenapi.VMRef
	var name string
	for ref, r := range vms {
		if !r.IsATemplate && !r.IsControlDomain && !r.IsASnapshot &&
			r.SecurebootCertificatesState == xenapi.VMSecurebootCertificatesStateUpdateAvailable {
			vm, name = ref, r.NameLabel
			break
		}
	}
	vmReadiness, err := xenapi.VM.GetSecurebootReadiness(session, vm)
	check(err)
	state, err := xenapi.VM.GetSecurebootCertificatesState(session, vm)
	check(err)
	fmt.Printf("%s: readiness %s, certificates %s\n", name, vmReadiness, state)

	// Flagging and unflagging are the same call with opposite booleans.
	check(xenapi.VM.UpdateSecurebootCertificatesOnBoot(session, vm, true))
	state, _ = xenapi.VM.GetSecurebootCertificatesState(session, vm)
	fmt.Printf("  flagged for refresh:      %s\n", state)

	check(xenapi.VM.UpdateSecurebootCertificatesOnBoot(session, vm, false))
	state, _ = xenapi.VM.GetSecurebootCertificatesState(session, vm)
	fmt.Printf("  unflagged:                %s\n", state)

	fmt.Println("OK: manage-secureboot-certificates")
}

// Run it:
//   manageSecurebootCertificates("https://xenserver", "root", password)

// --- Restart a host ---
func restartHost(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	// Rebooting a host is never just the reboot: anything running on it has to go somewhere first, and
	// the host has to stop accepting new VMs while that happens.
	//
	// Not the coordinator: it is the host this session is talking to, and taking it down would drop the
	// connection underneath the rest of the example.
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	coordinator, err := xenapi.Pool.GetMaster(session, pools[0])
	check(err)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	var host xenapi.HostRef
	for _, h := range hosts {
		if h != coordinator {
			host = h
			break
		}
	}
	name, _ := xenapi.Host.GetNameLabel(session, host)
	enabled, _ := xenapi.Host.GetEnabled(session, host)
	fmt.Printf("Restarting %s\n", name)
	fmt.Printf("  enabled=%t, guests=%d\n", enabled, guestCount(session, host))

	// Disabled means "accept no new VMs"; it does not move anything on its own.
	check(xenapi.Host.Disable(session, host, false))
	enabled, _ = xenapi.Host.GetEnabled(session, host)
	fmt.Printf("  disabled:   enabled=%t\n", enabled)

	// Evacuate moves the guests elsewhere in the pool. Afterwards only the control domain - the host's
	// own management VM, which cannot move - is left.
	check(xenapi.Host.Evacuate(session, host, "", 0))
	fmt.Printf("  evacuated:  guests=%d\n", guestCount(session, host))

	check(xenapi.Host.Reboot(session, host))
	enabled, _ = xenapi.Host.GetEnabled(session, host)
	fmt.Printf("  rebooted:   enabled=%t\n", enabled)

	// The other ending: off, and back on out of band.
	check(xenapi.Host.Shutdown(session, host))
	fmt.Printf("  shut down:  live=%t\n", hostLive(session, host))
	check(xenapi.Host.PowerOn(session, host))
	fmt.Printf("  powered on: live=%t\n", hostLive(session, host))

	fmt.Println("OK: restart-host")
}

// guestCount reports resident VMs excluding the control domain, which never moves.
func guestCount(session *xenapi.Session, host xenapi.HostRef) int {
	resident, err := xenapi.Host.GetResidentVMs(session, host)
	check(err)
	n := 0
	for _, vm := range resident {
		if dom0, _ := xenapi.VM.GetIsControlDomain(session, vm); !dom0 {
			n++
		}
	}
	return n
}

func hostLive(session *xenapi.Session, host xenapi.HostRef) bool {
	metrics, err := xenapi.Host.GetMetrics(session, host)
	check(err)
	live, err := xenapi.HostMetrics.GetLive(session, metrics)
	check(err)
	return live
}

// Run it:
//   restartHost("https://xenserver", "root", password)

// --- Create a VM and a template from a snapshot ---
func vmFromSnapshot(url, user, password, vmName string) {
	session := connect(url, user, password)
	defer session.Logout()

	// A snapshot is a VM record with is_a_snapshot set, so both of these are clones of it - the
	// difference is only what you mark the result as.
	vm := vmByName(session, vmName)
	snapshot, err := xenapi.VM.Snapshot(session, vm, "sdk-example-source-snapshot", nil)
	check(err)
	fmt.Printf("Snapshot of %s taken\n", vmName)

	// A clone of a snapshot is an ordinary VM. Worth reading back rather than assuming: a result still
	// flagged as a snapshot would be filed under the original VM instead of standing on its own, and
	// would not appear in a VM listing at all.
	newVM, err := xenapi.VM.Clone(session, snapshot, "sdk-example-vm-from-snapshot")
	check(err)
	newName, _ := xenapi.VM.GetNameLabel(session, newVM)
	isSnap, _ := xenapi.VM.GetIsASnapshot(session, newVM)
	fmt.Printf("  new VM:      %s (is_a_snapshot=%t)\n", newName, isSnap)

	// The same clone, marked as a template instead: a starting point to stamp more VMs from.
	template, err := xenapi.VM.Clone(session, snapshot, "sdk-example-template-from-snapshot")
	check(err)
	check(xenapi.VM.SetIsATemplate(session, template, true))
	tmplName, _ := xenapi.VM.GetNameLabel(session, template)
	isTmpl, _ := xenapi.VM.GetIsATemplate(session, template)
	fmt.Printf("  new template:%s (is_a_template=%t)\n", tmplName, isTmpl)

	for _, ref := range []xenapi.VMRef{newVM, template, snapshot} {
		check(xenapi.VM.Destroy(session, ref))
	}
	fmt.Println("OK: vm-from-snapshot")
}

// Run it:
//   vmFromSnapshot("https://xenserver", "root", password, "db-01")

// --- Attach an existing disk to another VM ---
func attachExistingDisk(url, user, password string) {
	const GiB = 1024 * 1024 * 1024
	session := connect(url, user, password)
	defer session.Logout()

	// A disk and the VM it belongs to are separate objects joined by a VBD, so moving a disk between VMs
	// is removing one VBD and creating another - no copying, and the data stays where it is.
	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var halted []xenapi.VMRef
	for ref, r := range vms {
		if !r.IsATemplate && !r.IsControlDomain && !r.IsASnapshot && r.PowerState == xenapi.VMPowerStateHalted {
			halted = append(halted, ref)
		}
	}

	srs, err := xenapi.SR.GetAllRecords(session)
	check(err)
	var sr xenapi.SRRef
	for ref, r := range srs {
		if r.Shared && r.ContentType != "iso" && r.Type != "iso" && r.Type != "udev" {
			sr = ref
			break
		}
	}
	vdi, err := xenapi.VDI.Create(session, xenapi.VDIRecord{
		NameLabel:   "sdk-example-portable-disk",
		SR:          sr,
		VirtualSize: 4 * GiB,
		Type:        xenapi.VdiTypeUser,
		OtherConfig: map[string]string{},
	})
	check(err)
	vdiName, _ := xenapi.VDI.GetNameLabel(session, vdi)
	srName, _ := xenapi.SR.GetNameLabel(session, sr)
	fmt.Printf("Disk %s created on %s\n", vdiName, srName)

	vbd := attachVdi(session, halted[0], vdi)
	firstName, _ := xenapi.VM.GetNameLabel(session, halted[0])
	fmt.Printf("  attached to %s\n", firstName)

	// Destroying the VBD detaches the disk; the disk itself is untouched and keeps its data.
	check(xenapi.VBD.Destroy(session, vbd))
	size, _ := xenapi.VDI.GetVirtualSize(session, vdi)
	fmt.Printf("  detached:   the disk still exists (%d bytes)\n", size)

	attachVdi(session, halted[1], vdi)
	secondName, _ := xenapi.VM.GetNameLabel(session, halted[1])
	fmt.Printf("  attached to %s\n", secondName)
	vbds, _ := xenapi.VDI.GetVBDs(session, vdi)
	fmt.Printf("  the disk is on %d VM(s)\n", len(vbds))

	for _, ref := range vbds {
		check(xenapi.VBD.Destroy(session, ref))
	}
	check(xenapi.VDI.Destroy(session, vdi))
	fmt.Println("OK: attach-existing-disk")
}

// attachVdi joins an existing disk to a VM on its next free device slot.
func attachVdi(session *xenapi.Session, vm xenapi.VMRef, vdi xenapi.VDIRef) xenapi.VBDRef {
	devices, err := xenapi.VM.GetAllowedVBDDevices(session, vm)
	check(err)
	vbd, err := xenapi.VBD.Create(session, xenapi.VBDRecord{
		VM: vm, VDI: vdi, Userdevice: devices[0],
		Mode: xenapi.VbdModeRW, Type: xenapi.VbdTypeDisk, Empty: false,
		OtherConfig: map[string]string{}, QosAlgorithmParams: map[string]string{},
	})
	check(err)
	return vbd
}

// Run it:
//   attachExistingDisk("https://xenserver", "root", password)

// --- Clear a host's crash dumps ---
func manageCrashDumps(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	// When a host crashes it writes a dump to its local disk and keeps it. They are large, nothing cleans
	// them up, and a host that has crashed more than once accumulates them - so clearing them once support
	// has what it needs is ordinary housekeeping. They belong to the host that wrote them, so clear them a
	// host at a time.
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	var host xenapi.HostRef
	var dumps []xenapi.HostCrashdumpRef
	for _, h := range hosts {
		d, err := xenapi.Host.GetCrashdumps(session, h)
		check(err)
		if len(d) > 0 {
			host, dumps = h, d
			break
		}
	}
	if len(dumps) == 0 {
		fmt.Println("No crash dumps in this pool - nothing to clear.")
		fmt.Println("OK: manage-crash-dumps")
		return
	}

	name, _ := xenapi.Host.GetNameLabel(session, host)
	fmt.Printf("%s has %d crash dump(s)\n", name, len(dumps))
	var total int
	for _, dump := range dumps {
		record, err := xenapi.HostCrashdump.GetRecord(session, dump)
		check(err)
		total += record.Size
		fmt.Printf("  %s  %s\n", record.Timestamp.Format("20060102T15:04:05Z"), mib(record.Size))
	}
	fmt.Printf("  %s in total\n", mib(total))

	// Deleting a dump frees the space on the host; the host itself is untouched.
	for _, dump := range dumps {
		check(xenapi.HostCrashdump.Destroy(session, dump))
	}
	left, _ := xenapi.Host.GetCrashdumps(session, host)
	fmt.Printf("  cleared:  %s now has %d\n", name, len(left))

	fmt.Println("OK: manage-crash-dumps")
}

func mib(size int) string { return fmt.Sprintf("%d MiB", size/(1024*1024)) }

// Run it:
//   manageCrashDumps("https://xenserver", "root", password)

// --- Configure pool options ---
func configurePoolOptions(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	pool := pools[0]

	// None of these is a wizard: they are plain pool settings that a client exposes on a properties
	// page, and each is a single field. Read them, change them, put them back.
	livePatching, err := xenapi.Pool.GetLivePatchingDisabled(session, pool)
	check(err)
	igmp, err := xenapi.Pool.GetIgmpSnoopingEnabled(session, pool)
	check(err)
	migrationCompression, err := xenapi.Pool.GetMigrationCompression(session, pool)
	check(err)
	fmt.Printf("  %-22s %t\n", "live patching disabled", livePatching)
	fmt.Printf("  %-22s %t\n", "IGMP snooping", igmp)
	fmt.Printf("  %-22s %t\n", "migration compression", migrationCompression)

	// Live patching applies host updates without a reboot; disabling it forces the reboot.
	check(xenapi.Pool.SetLivePatchingDisabled(session, pool, !livePatching))
	// IGMP snooping keeps multicast off ports that did not ask for it.
	check(xenapi.Pool.SetIgmpSnoopingEnabled(session, pool, !igmp))
	// Compression trades CPU for bandwidth when a VM's memory is moved between hosts.
	check(xenapi.Pool.SetMigrationCompression(session, pool, !migrationCompression))

	fmt.Println("after changing:")
	after1, _ := xenapi.Pool.GetLivePatchingDisabled(session, pool)
	after2, _ := xenapi.Pool.GetIgmpSnoopingEnabled(session, pool)
	after3, _ := xenapi.Pool.GetMigrationCompression(session, pool)
	fmt.Printf("  %-22s %t\n", "live patching disabled", after1)
	fmt.Printf("  %-22s %t\n", "IGMP snooping", after2)
	fmt.Printf("  %-22s %t\n", "migration compression", after3)

	check(xenapi.Pool.SetLivePatchingDisabled(session, pool, livePatching))
	check(xenapi.Pool.SetIgmpSnoopingEnabled(session, pool, igmp))
	check(xenapi.Pool.SetMigrationCompression(session, pool, migrationCompression))
	fmt.Println("  restored")
	fmt.Println("OK: configure-pool-options")
}

// Run it:
//   configurePoolOptions("https://xenserver", "root", password)

// --- Configure console access ---
//
// Idle console sessions are set at two levels - the pool's own management consoles and the VM
// consoles it serves - and a host can override the pool's. Requiring HTTPS refuses plain HTTP to the
// management interface altogether.
func configureConsoleAccess(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	pool := pools[0]
	host, err := xenapi.Pool.GetMaster(session, pool)
	check(err)

	// NB: pool.https_only and pool.console_idle_timeout are SET below but never read back. SDK 26.14
	// generates a setter and no getter for both (unlike host.console_idle_timeout, which has both), so
	// they cannot be read through the typed bindings at all - and a sample that reached past its own
	// binding to show a value would be teaching a workaround rather than the API.
	vmConsoleTimeout, err := xenapi.Pool.GetVMConsoleIdleTimeout(session, pool)
	check(err)
	limitSessions, err := xenapi.Pool.GetLimitConsoleSessions(session, pool)
	check(err)
	hostTimeout, err := xenapi.Host.GetConsoleIdleTimeout(session, host)
	check(err)
	fmt.Printf("  %-26s %ds\n", "VM console idle timeout", vmConsoleTimeout)
	fmt.Printf("  %-26s %t\n", "limit console sessions", limitSessions)
	fmt.Printf("  %-26s %ds\n", "host console idle timeout", hostTimeout)

	// Ten minutes of inactivity, one console session at a time, and no plain HTTP.
	check(xenapi.Pool.SetConsoleIdleTimeout(session, pool, 600))
	check(xenapi.Pool.SetVMConsoleIdleTimeout(session, pool, 600))
	check(xenapi.Pool.SetLimitConsoleSessions(session, pool, true))
	check(xenapi.Host.SetConsoleIdleTimeout(session, host, 300))
	check(xenapi.Pool.SetHTTPSOnly(session, pool, true))

	fmt.Println("after tightening:")
	vmConsoleTimeout, _ = xenapi.Pool.GetVMConsoleIdleTimeout(session, pool)
	limitSessions, _ = xenapi.Pool.GetLimitConsoleSessions(session, pool)
	hostTimeout, _ = xenapi.Host.GetConsoleIdleTimeout(session, host)
	fmt.Printf("  %-26s %ds\n", "VM console idle timeout", vmConsoleTimeout)
	fmt.Printf("  %-26s %t\n", "limit console sessions", limitSessions)
	fmt.Printf("  %-26s %ds\n", "host console idle timeout", hostTimeout)

	check(xenapi.Pool.SetHTTPSOnly(session, pool, false))
	check(xenapi.Pool.SetConsoleIdleTimeout(session, pool, 0))
	check(xenapi.Pool.SetVMConsoleIdleTimeout(session, pool, 0))
	check(xenapi.Pool.SetLimitConsoleSessions(session, pool, false))
	check(xenapi.Host.SetConsoleIdleTimeout(session, host, 0))
	fmt.Println("  restored")
	fmt.Println("OK: configure-console-access")
}

// Run it:
//   configureConsoleAccess("https://xenserver", "root", password)

// --- Configure host storage ---
//
// The IQN identifies this host to iSCSI targets, so a target's access list is written against it -
// changing it on a host with live iSCSI storage cuts it off. Multipathing uses every path to the
// storage rather than one, and on real hardware you put the host into maintenance mode before
// changing it, because the paths are rebuilt.
func configureHostStorage(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	host, err := xenapi.Pool.GetMaster(session, pools[0])
	check(err)
	hostName, err := xenapi.Host.GetNameLabel(session, host)
	check(err)

	beforeIqn, err := xenapi.Host.GetIscsiIqn(session, host)
	check(err)
	beforeMultipathing, err := xenapi.Host.GetMultipathing(session, host)
	check(err)
	fmt.Printf("%s: iSCSI IQN %q, multipathing %t\n", hostName, beforeIqn, beforeMultipathing)

	check(xenapi.Host.SetIscsiIqn(session, host, "iqn.2026-01.com.example:"+hostName))
	check(xenapi.Host.SetMultipathing(session, host, true))
	iqn, _ := xenapi.Host.GetIscsiIqn(session, host)
	multipathing, _ := xenapi.Host.GetMultipathing(session, host)
	fmt.Printf("  IQN now:      %s\n", iqn)
	fmt.Printf("  multipathing: %t\n", multipathing)

	check(xenapi.Host.SetIscsiIqn(session, host, beforeIqn))
	check(xenapi.Host.SetMultipathing(session, host, beforeMultipathing))
	fmt.Println("  restored")
	fmt.Println("OK: configure-host-storage")
}

// Run it:
//   configureHostStorage("https://xenserver", "root", password)

// --- Configure remote syslog ---
//
// Two steps, and the second is the one that is easy to miss: setting the destination only records
// it, and the host keeps logging locally until the syslog daemon is reconfigured to pick the setting
// up.
func configureSyslog(url, user, password, syslogServer string) {
	session := connect(url, user, password)
	defer session.Logout()

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	host, err := xenapi.Pool.GetMaster(session, pools[0])
	check(err)
	hostName, err := xenapi.Host.GetNameLabel(session, host)
	check(err)

	logging, err := xenapi.Host.GetLogging(session, host)
	check(err)
	fmt.Printf("%s logging: %s\n", hostName, loggingOrLocal(logging))

	check(xenapi.Host.RemoveFromLogging(session, host, "syslog_destination"))
	check(xenapi.Host.AddToLogging(session, host, "syslog_destination", syslogServer))
	check(xenapi.Host.SyslogReconfigure(session, host))
	logging, _ = xenapi.Host.GetLogging(session, host)
	fmt.Printf("  now logging to: %s\n", logging["syslog_destination"])

	check(xenapi.Host.RemoveFromLogging(session, host, "syslog_destination"))
	check(xenapi.Host.SyslogReconfigure(session, host))
	logging, _ = xenapi.Host.GetLogging(session, host)
	fmt.Printf("  restored: %s\n", loggingOrLocal(logging))
	fmt.Println("OK: configure-syslog")
}

// loggingOrLocal renders a host's logging map, or "(local only)" once it is empty.
func loggingOrLocal(logging map[string]string) string {
	if len(logging) == 0 {
		return "(local only)"
	}
	return fmt.Sprintf("%v", logging)
}

// Run it:
//   configureSyslog("https://xenserver", "root", password, "192.0.2.50")

// --- Manage driver variants ---
//
// A driver can ship in several variants - a vendor build alongside the one in the distribution, say.
// One is SELECTED (what the host will load) and one is ACTIVE (what it has loaded); they differ
// until the host reboots, which is what makes selecting a variant a scheduled change rather than an
// immediate one.
func manageDriverVariants(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	host, err := xenapi.Pool.GetMaster(session, pools[0])
	check(err)
	hostName, err := xenapi.Host.GetNameLabel(session, host)
	check(err)

	all, err := xenapi.HostDriver.GetAllRecords(session)
	check(err)
	drivers := map[xenapi.HostDriverRef]xenapi.HostDriverRecord{}
	var refs []xenapi.HostDriverRef
	for ref, r := range all {
		if r.Host != host {
			continue
		}
		drivers[ref] = r
		refs = append(refs, ref)
	}
	fmt.Printf("%s has %d driver(s)\n", hostName, len(refs))

	sort.Slice(refs, func(i, j int) bool { return drivers[refs[i]].Name < drivers[refs[j]].Name })
	shown := refs
	if len(shown) > 3 {
		shown = shown[:3]
	}
	for _, ref := range shown {
		d := drivers[ref]
		fmt.Printf("  %-14s %-10s %d variant(s), active=%s\n",
			d.Name, d.Type, len(d.Variants), variantName(session, d.ActiveVariant))
	}

	// Select a variant explicitly. It becomes the selected one immediately; whether it is also active
	// depends on whether the hardware is present and the driver already loaded.
	first := refs[0]
	variant := drivers[first].Variants[0]
	check(xenapi.HostDriver.Select(session, first, variant))
	after, err := xenapi.HostDriver.GetRecord(session, first)
	check(err)
	fmt.Printf("  %s: selected %s, active %s\n",
		after.Name, variantName(session, after.SelectedVariant), variantName(session, after.ActiveVariant))

	fmt.Println("OK: manage-driver-variants")
}

// variantName is a driver variant's name, tolerating the null reference an unloaded driver has.
func variantName(session *xenapi.Session, ref xenapi.DriverVariantRef) string {
	if ref == "" || ref == "OpaqueRef:NULL" {
		return "(none)"
	}
	name, err := xenapi.DriverVariant.GetName(session, ref)
	check(err)
	return name
}

// Run it:
//   manageDriverVariants("https://xenserver", "root", password)

// --- end of workflows ---

func insecureClient() *http.Client {
	return &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
}

// rawLogin obtains a session id via a plain JSON-RPC call (for the HTTP-only rrd_updates endpoint).
func rawLogin(url, user, password string) string {
	body := fmt.Sprintf(`{"jsonrpc":"2.0","id":1,"method":"session.login_with_password","params":[%q,%q,"1.0","rrd"]}`, user, password)
	resp, err := insecureClient().Post(url+"/jsonrpc", "application/json", strings.NewReader(body))
	check(err)
	defer resp.Body.Close()
	var r struct {
		Result string `json:"result"`
	}
	check(json.NewDecoder(resp.Body).Decode(&r))
	return r.Result
}

var workflows = map[string]func(url, user, password string){
	"connect-inventory":  func(u, n, p string) { connectInventory(u, n, p) },
	"create-vm":          func(u, n, p string) { createVM(u, n, p, "Rocky Linux 8", "sdk-example-vm") },
	"vm-lifecycle":       func(u, n, p string) { vmLifecycle(u, n, p, "Rocky Linux 8", "sdk-example-lifecycle") },
	"manage-vm-disks":    func(u, n, p string) { manageVMDisks(u, n, p, "web-01") },
	"dismiss-alerts":     func(u, n, p string) { dismissAlerts(u, n, p) },
	"host-power-on":      func(u, n, p string) { hostPowerOn(u, n, p) },
	"rotate-pool-secret": func(u, n, p string) { rotatePoolSecret(u, n, p) },
	"change-root-password": func(u, n, p string) { changeRootPassword(u, n, p) },
	"manage-certificates": func(u, n, p string) { manageCertificates(u, n, p) },
	"snapshot-schedule":  func(u, n, p string) { snapshotSchedule(u, n, p, "web-01", "sdk-example-schedule") },
	"manage-vm-groups":   func(u, n, p string) { manageVMGroups(u, n, p, "web-01", "sdk-example-group") },
	"snapshot-revert":    func(u, n, p string) { snapshotRevert(u, n, p, "web-01", "sdk-example-snapshot") },
	"create-nfs-sr":      func(u, n, p string) { createNfsSR(u, n, p, "192.0.2.10", "/export/sdk", "sdk-example-nfs") },
	"create-network":     func(u, n, p string) { createNetwork(u, n, p, "sdk-example-net") },
	"edit-vm-properties": func(u, n, p string) { editVMProperties(u, n, p, "web-01") },
	"events":             func(u, n, p string) { events(u, n, p, "web-01") },
	"new-vm-wizard":      func(u, n, p string) { newVMWizard(u, n, p, "Rocky Linux 8", "wizard-vm") },
	"live-migrate":       func(u, n, p string) { liveMigrate(u, n, p, "Rocky Linux 8", "sdk-example-migrate") },
	"host-maintenance":   func(u, n, p string) { hostMaintenance(u, n, p, "Rocky Linux 8", "sdk-example-maint") },
	"configure-ha":       func(u, n, p string) { configureHa(u, n, p, "Shared NFS") },
	"copy-vm":            func(u, n, p string) { copyVM(u, n, p, "db-01", "Shared NFS", "sdk-example-copy") },
	"create-vm-with-vgpu": func(u, n, p string) { createVMWithVgpu(u, n, p, "Rocky Linux 8", "sdk-example-vgpu-vm") },
	"tags-and-folders":    func(u, n, p string) { tagsAndFolders(u, n, p, "web-01") },
	"configure-updates":   func(u, n, p string) { configureUpdates(u, n, p) },
	"clone-vm":            func(u, n, p string) { cloneVM(u, n, p, "db-01", "sdk-example-clone") },
	"delete-vm":           func(u, n, p string) { deleteVM(u, n, p, "Rocky Linux 8", "sdk-example-delete") },
	"storage-migrate":     func(u, n, p string) { storageMigrate(u, n, p, "Rocky Linux 8", "sdk-example-storagemigrate") },
	"apply-update":        func(u, n, p string) { applyUpdate(u, n, p) },
	"checkpoint-vm":       func(u, n, p string) { checkpointVM(u, n, p, "Rocky Linux 8", "sdk-example-checkpoint") },
	"attach-disk":         func(u, n, p string) { attachDisk(u, n, p, "Rocky Linux 8", "Shared NFS", "sdk-example-attachdisk") },
	"wait-for-task":       func(u, n, p string) { waitForTask(u, n, p, "Rocky Linux 8", "sdk-example-asynctask") },
	"error-handling":      func(u, n, p string) { errorHandling(u, n, p) },
	"list-templates":      func(u, n, p string) { listTemplates(u, n, p) },
	"custom-fields":       func(u, n, p string) { customFields(u, n, p, "web-01") },
	"gpu-inventory":       func(u, n, p string) { gpuInventory(u, n, p) },
	"read-metrics":        func(u, n, p string) { readMetrics(u, n, p) },
	"rename-object":       func(u, n, p string) { renameObject(u, n, p, "web-01") },
	"vm-boot-config":      func(u, n, p string) { vmBootConfig(u, n, p, "Rocky Linux 8", "sdk-example-boot") },
	"host-info":           func(u, n, p string) { hostInfo(u, n, p) },
	"list-roles":          func(u, n, p string) { listRoles(u, n, p) },
	"pool-properties":     func(u, n, p string) { poolProperties(u, n, p) },
	"sr-usage":            func(u, n, p string) { srUsage(u, n, p) },
	"manage-vif":          func(u, n, p string) { manageVif(u, n, p, "Rocky Linux 8", "sdk-example-vif") },
	"list-networks":       func(u, n, p string) { listNetworks(u, n, p) },
	"vbd-inventory":       func(u, n, p string) { vbdInventory(u, n, p, "db-01") },
	"pool-tags":           func(u, n, p string) { poolTags(u, n, p) },
	"convert-to-template": func(u, n, p string) { convertToTemplate(u, n, p, "Rocky Linux 8", "sdk-example-totemplate") },
	"find-by-uuid":        func(u, n, p string) { findByUUID(u, n, p, "web-01") },
	"rolling-pool-update": func(u, n, p string) { rollingPoolUpdate(u, n, p) },
	"pvs-accelerator":     func(u, n, p string) { pvsAccelerator(u, n, p) },
	"configure-pvs-accelerator": func(u, n, p string) { configurePvsAccelerator(u, n, p) },
	"manage-ssh-access":  func(u, n, p string) { manageSSHAccess(u, n, p) },
	"manage-vtpm":        func(u, n, p string) { manageVtpm(u, n, p) },
	"export-import-vm":   func(u, n, p string) { exportImportVm(u, n, p) },
	"configure-dynamic-memory": func(u, n, p string) { configureDynamicMemory(u, n, p) },
	"manage-vm-media":          func(u, n, p string) { manageVmMedia(u, n, p) },
	"backup-host-config":       func(u, n, p string) { backupHostConfig(u, n, p) },
	"manage-sr-lifecycle":      func(u, n, p string) { manageSrLifecycle(u, n, p, "192.0.2.10", "/export/spare") },
	"set-default-sr":           func(u, n, p string) { setDefaultSr(u, n, p, "192.0.2.10", "/export/spare") },
	"server-status-report":     func(u, n, p string) { serverStatusReport(u, n, p) },
	"disaster-recovery":        func(u, n, p string) { disasterRecovery(u, n, p) },
	"manage-secureboot-certificates": func(u, n, p string) { manageSecurebootCertificates(u, n, p) },
	"restart-host":             func(u, n, p string) { restartHost(u, n, p) },
	"manage-crash-dumps":       func(u, n, p string) { manageCrashDumps(u, n, p) },
	"vm-from-snapshot":         func(u, n, p string) { vmFromSnapshot(u, n, p, "db-01") },
	"attach-existing-disk":     func(u, n, p string) { attachExistingDisk(u, n, p) },
	"changed-block-tracking": func(u, n, p string) { changedBlockTracking(u, n, p) },
	"control-domain-memory": func(u, n, p string) { controlDomainMemory(u, n, p) },
	"rrd-metrics":         func(u, n, p string) { rrdMetrics(u, n, p) },
	"reclaim-space":       func(u, n, p string) { reclaimSpace(u, n, p) },
	"vm-ip-address":       func(u, n, p string) { vmIpAddress(u, n, p) },
	"manage-ad-users":     func(u, n, p string) { manageAdUsers(u, n, p) },
	"create-iscsi-sr":     func(u, n, p string) { createIscsiSr(u, n, p) },
	"create-smb-sr":       func(u, n, p string) { createSmbSr(u, n, p) },
	"create-hba-sr":       func(u, n, p string) { createHbaSr(u, n, p) },
	"create-gfs2-sr":      func(u, n, p string) { createGfs2Sr(u, n, p) },
	"create-iso-sr":       func(u, n, p string) { createIsoSr(u, n, p) },
	"configure-nrpe":      func(u, n, p string) { configureNrpe(u, n, p) },
	"configure-snmp":      func(u, n, p string) { configureSnmp(u, n, p) },
	"configure-clustering": func(u, n, p string) { configureClustering(u, n, p) },
	"manage-pool-membership": func(u, n, p string) { managePoolMembership(u, n, p) },
	"create-bond": func(u, n, p string) { createBond(u, n, p) },
	"manage-vapp":         func(u, n, p string) { manageVapp(u, n, p, "web-01") },
	"attach-usb-device":   func(u, n, p string) { attachUsbDevice(u, n, p, "web-01") },
	"wlb-recommendations": func(u, n, p string) { wlbRecommendations(u, n, p, "web-01") },
	"configure-pool-options":   func(u, n, p string) { configurePoolOptions(u, n, p) },
	"configure-console-access": func(u, n, p string) { configureConsoleAccess(u, n, p) },
	"configure-host-storage":   func(u, n, p string) { configureHostStorage(u, n, p) },
	"configure-syslog":         func(u, n, p string) { configureSyslog(u, n, p, "192.0.2.50") },
	"manage-driver-variants":   func(u, n, p string) { manageDriverVariants(u, n, p) },
}

func main() {
	// cross-pool-copy-vm spans two pools, so it takes an extra 5th argument: the destination URL.
	if len(os.Args) >= 2 && os.Args[1] == "cross-pool-copy-vm" {
		if len(os.Args) != 6 {
			fmt.Fprintln(os.Stderr, "usage: go run . cross-pool-copy-vm <sourceUrl> <user> <password> <destUrl>")
			os.Exit(2)
		}
		crossPoolCopyVM(os.Args[2], os.Args[3], os.Args[4], os.Args[5], "db-01")
		return
	}
	if len(os.Args) != 5 {
		fmt.Fprintln(os.Stderr, "usage: go run . <workflow> <url> <user> <password>")
		os.Exit(2)
	}
	workflow, ok := workflows[os.Args[1]]
	if !ok {
		fmt.Fprintf(os.Stderr, "unknown workflow: %s\n", os.Args[1])
		os.Exit(2)
	}

	workflow(os.Args[2], os.Args[3], os.Args[4])
}
