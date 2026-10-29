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
//
//	go run . <workflow> <url> <username> <password>
//
//	<workflow>  any workflow id from the dispatcher (see also README.md)
package main

import (
	"archive/tar"
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"encoding/xml"
	"fmt"
	"io"
	"math/big"
	"math/bits"
	"net/http"
	"net/url"
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

// detachAndForgetSR detaches an SR from every host, then forgets it: XenCenter's Detach followed by
// Forget. SR.Forget refuses an SR that is still attached (SR_HAS_PBD), so unplug its PBDs first.
// Forgetting drops the pool's record of the SR but leaves the data on the storage itself.
func detachAndForgetSR(session *xenapi.Session, sr xenapi.SRRef) {
	pbds, err := xenapi.SR.GetPBDs(session, sr)
	check(err)
	for _, pbd := range pbds {
		attached, err := xenapi.PBD.GetCurrentlyAttached(session, pbd)
		check(err)
		if attached {
			check(xenapi.PBD.Unplug(session, pbd))
		}
	}
	check(xenapi.SR.Forget(session, sr))
}

// provision is VM.Provision, after filling in the SR for every disk the template describes. A template's
// other_config["disks"] names each disk's SR as sr="" (empty); a real host takes that literally and
// VM.Provision fails with UUID_INVALID, so point the disks at the pool's default SR first - exactly what
// `xe vm-install` does before calling VM.provision itself.
func provision(session *xenapi.Session, vm xenapi.VMRef) {
	otherConfig, err := xenapi.VM.GetOtherConfig(session, vm)
	check(err)
	if disks, ok := otherConfig["disks"]; ok && strings.Contains(disks, `sr=""`) {
		pools, err := xenapi.Pool.GetAll(session)
		check(err)
		defaultSR, err := xenapi.Pool.GetDefaultSR(session, pools[0])
		check(err)
		srUUID, err := xenapi.SR.GetUUID(session, defaultSR)
		check(err)
		check(xenapi.VM.RemoveFromOtherConfig(session, vm, "disks"))
		check(xenapi.VM.AddToOtherConfig(session, vm, "disks", strings.ReplaceAll(disks, `sr=""`, `sr="`+srUUID+`"`)))
	}
	check(xenapi.VM.Provision(session, vm))
}

// copyOfGuest makes a throwaway VM with a working guest OS: a copy of an existing VM that has one.
//
// Suspend, checkpoint, live migration and clean shutdown all need the guest's cooperation: on a
// running VM with no PV drivers xapi refuses them up front with VM_LACKS_FEATURE (a VM freshly
// cloned from a template has no OS at all). So copy a VM that does have an OS and PV drivers,
// without disturbing it: snapshot it (fine while it runs), clone the snapshot - a clone of a
// snapshot is a template - and provision that into an ordinary VM. The snapshot is only needed for
// the clone, so it goes again straight away.
func copyOfGuest(session *xenapi.Session, sourceVMName, newVMName string) xenapi.VMRef {
	source := vmByName(session, sourceVMName)
	snapshot, err := xenapi.VM.Snapshot(session, source, newVMName+"-source", nil)
	check(err)
	vm, err := xenapi.VM.Clone(session, snapshot, newVMName)
	check(err)
	provision(session, vm)
	destroyVMAndDisks(session, snapshot)
	return vm
}

// waitForGuestAgent waits, after VM.Start, until the guest's PV drivers have reported in.
//
// xapi only offers the guest-dependent operations once the guest says it can do them, and
// allowed_operations is where it says so: wait for clean_shutdown to appear there (the same check
// that refuses it with VM_LACKS_FEATURE beforehand). A booting OS takes a while.
// guestAgentReady: clean_shutdown in allowed_operations says the guest can shut down; a Linux kernel offers
// that early in boot, before the agent runs (hot-plug needs the agent, and suspend needs its emulated disk
// unplugged), so the guest metrics must report the PV drivers too.
func guestAgentReady(session *xenapi.Session, vm xenapi.VMRef) bool {
	ops, err := xenapi.VM.GetAllowedOperations(session, vm)
	check(err)
	canShutDown := false
	for _, op := range ops {
		canShutDown = canShutDown || op == xenapi.VMOperationsCleanShutdown
	}
	if !canShutDown {
		return false
	}
	metrics, err := xenapi.VM.GetGuestMetrics(session, vm)
	check(err)
	if metrics == xenapi.VMGuestMetricsRef("OpaqueRef:NULL") {
		return false
	}
	detected, err := xenapi.VMGuestMetrics.GetPVDriversDetected(session, metrics)
	check(err)
	return detected
}

func waitForGuestAgent(session *xenapi.Session, vm xenapi.VMRef) {
	const timeout = 300 * time.Second
	const interval = 2 * time.Second
	deadline := time.Now().Add(timeout)
	for {
		if guestAgentReady(session, vm) {
			return
		}
		if time.Now().After(deadline) {
			panic(fmt.Sprintf("the guest's PV drivers did not report in within %s; does the source "+
				"VM have a guest OS with PV drivers (XenServer VM Tools)?", timeout))
		}
		time.Sleep(interval)
	}
}

// probeForFailure runs SR.probe's deliberately-incomplete discovery call and returns the XML
// fragment its failure carries describing what it found. The New SR wizard (and XenRT) discover
// iSCSI/HBA LUNs by asking with an incomplete device-config on purpose: the backend can't create
// anything from it yet, so it fails with an error whose params carry an XML fragment describing
// what it found. A probe that unexpectedly succeeds means the device-config was already complete -
// not the discovery prompt this helper is looking for. Never fall back to SR.create instead: on
// real storage a create that unexpectedly succeeds formats the LUN.
func probeForFailure(session *xenapi.Session, host xenapi.HostRef, deviceConfig map[string]string, smType string) string {
	_, err := xenapi.SR.Probe(session, host, deviceConfig, smType, map[string]string{})
	if err == nil {
		panic(fmt.Sprintf("SR.probe for %s succeeded without asking for more information; "+
			"check the target address", smType))
	}
	if xml := xmlFromFailure(err); xml != "" {
		return xml
	}
	panic(err)
}

// xmlFromFailure pulls the XML fragment out of a XenAPI failure's text. The Go binding renders an
// API error as a formatted string ending "... data [<code> <param> <param> ...]" (see
// coordinatorFromSlaveError) rather than keeping the params as separate values, so splitting on
// whitespace would break up the XML itself wherever it contains one. The XML fragment is always
// the last parameter in these errors, so take everything from the first "<" onward instead.
func xmlFromFailure(err error) string {
	msg := err.Error()
	i := strings.Index(msg, "data [")
	if i < 0 {
		return ""
	}
	inner := strings.TrimSuffix(msg[i+len("data ["):], "]")
	if j := strings.Index(inner, "<"); j >= 0 {
		return inner[j:]
	}
	return ""
}

// selfSignedCertPEM generates a throwaway self-signed certificate and private key (PEM), the way
// XenRT provisions one for its own certificate tests. Go's standard library crypto/x509 and
// crypto/rsa need no external tool for this, unlike some other languages here.
func selfSignedCertPEM() (certPEM, keyPEM string) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	check(err)
	template := x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: "sdk-example"},
		NotBefore:    time.Now().Add(-24 * time.Hour),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	check(err)
	certPEM = string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
	keyPEM = string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}))
	return
}

// reconnectAfterMasterChange waits out a pool-wide xapi restart (pool.DesignateNewMaster) and
// reconnects.
//
// DesignateNewMaster returns BEFORE the change: for a while the old coordinator still answers, and
// still says it is the coordinator, until xapi restarts across the pool. So reconnecting is not
// enough - keep reconnecting until the pool names the new coordinator (by uuid; connect follows
// HOST_IS_SLAVE to wherever the coordinator now is). XenRT's own helper likewise waits minutes
// before trusting the pool again.
func reconnectAfterMasterChange(url, user, password, newMasterUUID string) (session *xenapi.Session) {
	deadline := time.Now().Add(600 * time.Second)
	var lastErr any
	for time.Now().Before(deadline) {
		settled := func() (ok bool) {
			defer func() {
				if r := recover(); r != nil {
					lastErr = r
					ok = false
				}
			}()
			session = connect(url, user, password)
			pools, err := xenapi.Pool.GetAll(session)
			check(err)
			master, err := xenapi.Pool.GetMaster(session, pools[0])
			check(err)
			uuid, err := xenapi.Host.GetUUID(session, master)
			check(err)
			// The new coordinator answers before the pool has settled - calls made too soon fail
			// (HANDLE_INVALID on the operation's own task) - so also wait for every host to be back,
			// live and enabled.
			if uuid != newMasterUUID {
				lastErr = "the pool has not settled under the new coordinator"
				return false
			}
			hosts, err := xenapi.Host.GetAllRecords(session)
			check(err)
			for _, h := range hosts {
				live, err := xenapi.HostMetrics.GetLive(session, h.Metrics)
				check(err)
				if !h.Enabled || !live {
					lastErr = "the pool has not settled under the new coordinator"
					return false
				}
			}
			return true
		}()
		if settled {
			return session
		}
		if session != nil {
			session.Logout()
		}
		time.Sleep(5 * time.Second)
	}
	panic(fmt.Sprintf("the pool did not come back after the master change: %v", lastErr))
}

// waitForHostLive polls host_metrics.live until it matches, rather than issuing the next power
// command immediately - real out-of-band power control has no retry of its own, so a tool that
// doesn't wait can issue a second command while the first is still in flight.
func waitForHostLive(session *xenapi.Session, host xenapi.HostRef, want bool) {
	waitForHostLiveTimeout(session, host, want, 60*time.Second, 2*time.Second)
}

func waitForHostLiveTimeout(session *xenapi.Session, host xenapi.HostRef, want bool, timeout, interval time.Duration) {
	deadline := time.Now().Add(timeout)
	for hostLive(session, host) != want {
		if time.Now().After(deadline) {
			panic(fmt.Sprintf("host did not reach live=%t in time", want))
		}
		time.Sleep(interval)
	}
}

// enableWhenBooted re-enables a host that has just come back. It reports itself live before xapi
// on it has finished starting, and until then Host.Enable fails HOST_STILL_BOOTING - so retry that.
func enableWhenBooted(session *xenapi.Session, host xenapi.HostRef) {
	deadline := time.Now().Add(600 * time.Second)
	for {
		err := xenapi.Host.Enable(session, host)
		if err == nil {
			return
		}
		if failureCode(err) != xenapi.ErrorHostStillBooting || time.Now().After(deadline) {
			panic(err)
		}
		time.Sleep(10 * time.Second)
	}
}

// waitForRestart waits for a host to come back from a reboot (key "boot_time") or toolstack
// restart ("agent_start_time"): until that other_config entry differs from before and the host is
// live. It reconnects every time round, because the host restarting may be the coordinator this
// session talks to; returns the new session.
func waitForRestart(url, user, password, hostUUID, key, before string) (session *xenapi.Session) {
	deadline := time.Now().Add(1800 * time.Second)
	for {
		ready := func() (ok bool) {
			defer func() {
				if recover() != nil { // down, or xapi still starting
					ok = false
				}
			}()
			session = connect(url, user, password)
			host, err := xenapi.Host.GetByUUID(session, hostUUID)
			check(err)
			otherConfig, err := xenapi.Host.GetOtherConfig(session, host)
			check(err)
			return otherConfig[key] != before && hostLive(session, host)
		}()
		if ready {
			return session
		}
		if session != nil {
			session.Logout()
		}
		if time.Now().After(deadline) {
			panic(fmt.Sprintf("host %s did not come back in time", hostUUID))
		}
		time.Sleep(10 * time.Second)
	}
}

// hostURL rebuilds a URL for a different host's own address, keeping the original scheme and port
// (a host's management "address" field carries no port of its own). Needed anywhere a workflow
// does raw HTTP against a SPECIFIC host rather than the pool's connection URL.
func hostURL(rawURL, address string) string {
	u, err := url.Parse(rawURL)
	check(err)
	host := address
	if port := u.Port(); port != "" {
		host = address + ":" + port
	}
	return u.Scheme + "://" + host
}

// moveDisksToSR relocates every one of a (not-yet-started) VM's disks onto the given SR, the same
// VDI.PoolMigrate call storage-migrate already demonstrates.
func moveDisksToSR(session *xenapi.Session, vm xenapi.VMRef, sr xenapi.SRRef) {
	for _, vdi := range diskVdis(session, vm) {
		current, err := xenapi.VDI.GetSR(session, vdi)
		check(err)
		if current != sr {
			_, err := xenapi.VDI.PoolMigrate(session, vdi, sr, map[string]string{})
			check(err)
		}
	}
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

	provision(session, vmRef)
	isTemplate, _ := xenapi.VM.GetIsATemplate(session, vmRef)
	fmt.Printf("Provisioned. is_a_template = %v\n", isTemplate)

	destroyVMAndDisks(session, vmRef)
	fmt.Println("Cleaned up the example VM.")

	fmt.Println("OK: create-vm")
	session.Logout()
}

// Run it:
//   createVM("https://xenserver", "root", password, "Rocky Linux 8", "sdk-example-vm")

// --- 3. VM power lifecycle -------------------------------------------------------------
// vmLifecycle takes a throwaway copy of a VM with a guest OS through start -> suspend -> resume ->
// clean shutdown, and deletes it again.
//
// Suspend and clean shutdown need the guest's cooperation (VM_LACKS_FEATURE without PV drivers),
// so the copy is made from sourceVM, a VM with a guest OS and PV drivers, and the example waits
// for the guest to report in after starting. Suspend also needs a suspend-image SR (the VM's own,
// else the pool's, else the host's); check one is actually configured before trying.
func vmLifecycle(url, user, password, sourceVM, newVMName string) {
	session := connect(url, user, password)
	vmRef := copyOfGuest(session, sourceVM, newVMName)

	state := func() xenapi.VMPowerState {
		s, _ := xenapi.VM.GetPowerState(session, vmRef)
		return s
	}

	fmt.Printf("Initial power state: %s\n", state())
	check(xenapi.VM.Start(session, vmRef, false, true))
	waitForGuestAgent(session, vmRef)
	fmt.Printf("After start:    %s\n", state())

	// The emulated hardware (the device model) can be restarted under a running guest without
	// rebooting it - what you reach for when the VM's virtual devices misbehave.
	check(xenapi.VM.RestartDeviceModels(session, vmRef))
	fmt.Printf("Device models restarted; still %s\n", state())

	// Suspend needs a suspend-image SR (the VM's own, else the pool's, else the host's); check
	// one is actually configured before trying, rather than assuming it is (VM_NO_SUSPEND_SR
	// otherwise on a real host).
	if hasSuspendSR(session, vmRef) {
		check(xenapi.VM.Suspend(session, vmRef))
		fmt.Printf("After suspend:  %s\n", state())
		check(xenapi.VM.Resume(session, vmRef, false, true))
		waitForGuestAgent(session, vmRef) // the PV drivers reconnect after a resume
		fmt.Printf("After resume:   %s\n", state())
	} else {
		fmt.Println("Skipping suspend/resume: no suspend-image SR is configured for this VM/pool/host")
	}

	// A clean shutdown asks the guest OS to shut itself down, as pressing the power button would -
	// possible here because the copy has a guest OS with PV drivers.
	check(xenapi.VM.CleanShutdown(session, vmRef))
	fmt.Printf("After shutdown: %s\n", state())

	destroyVMAndDisks(session, vmRef)
	fmt.Println("OK: vm-lifecycle")
	session.Logout()
}

// hasSuspendSR reports whether VM.Suspend has a suspend-image SR to use: the VM's own, else the
// pool's, else the resident host's - the same fallback order xapi's choose_suspend_sr uses.
func hasSuspendSR(session *xenapi.Session, vm xenapi.VMRef) bool {
	if sr, err := xenapi.VM.GetSuspendSR(session, vm); err == nil && sr != "" && sr != "OpaqueRef:NULL" {
		return true
	}
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	if sr, err := xenapi.Pool.GetSuspendImageSR(session, pools[0]); err == nil && sr != "" && sr != "OpaqueRef:NULL" {
		return true
	}
	host, err := xenapi.Pool.GetMaster(session, pools[0])
	check(err)
	sr, err := xenapi.Host.GetSuspendImageSr(session, host)
	return err == nil && sr != "" && sr != "OpaqueRef:NULL"
}

// Run it:
//   vmLifecycle("https://xenserver", "root", password, "web-01", "sdk-example-lifecycle")

// --- 4. Manage VM disks: Deactivate / Resize / Activate ------------------------------
// A real VM's root/boot disk is unpluggable=false (only non-system disks from VM.Provision default
// to unpluggable), and the VM has to be Running for VBD.Unplug to be legal at all
// (VM_BAD_POWER_STATE otherwise on a halted VM). So this works on a NEW data disk added to a
// throwaway VM of its own, matching XenCenter's own "deactivate" action, which only ever targets
// additional disks. No shrink demonstration: real SR backends refuse one outright
// (SR_BACKEND_FAILURE_79).
//
// Plugging and unplugging a disk on a running VM needs the guest's PV drivers
// (VM_MISSING_PV_DRIVERS otherwise), so the VM is a throwaway copy of sourceVM, a VM with a guest OS
// and PV drivers.
func manageVMDisks(url, user, password, sourceVM, srName, newVMName string) {
	const GiB = 1024 * 1024 * 1024
	session := connect(url, user, password)
	vmRef := copyOfGuest(session, sourceVM, newVMName)
	check(xenapi.VM.Start(session, vmRef, false, true))
	waitForGuestAgent(session, vmRef)

	srRef := srByName(session, srName, false)
	vdiRef, err := xenapi.VDI.Create(session, xenapi.VDIRecord{
		NameLabel:   "sdk-example-data-disk",
		SR:          srRef,
		VirtualSize: 4 * GiB,
		Type:        xenapi.VdiTypeUser,
		Sharable:    false,
		ReadOnly:    false,
		OtherConfig: map[string]string{},
	})
	check(err)
	devices, err := xenapi.VM.GetAllowedVBDDevices(session, vmRef)
	check(err)
	vbdRef, err := xenapi.VBD.Create(session, xenapi.VBDRecord{
		VM: vmRef, VDI: vdiRef, Userdevice: devices[0],
		Bootable: false,
		Mode:     xenapi.VbdModeRW, Type: xenapi.VbdTypeDisk, Empty: false,
		// A Go record sends every field, so say so explicitly: a VBD created with unpluggable=false
		// can't be hot-unplugged (VBD_NOT_UNPLUGGABLE). xapi's own default, when the field is left
		// out, is true.
		Unpluggable: true,
		OtherConfig: map[string]string{}, QosAlgorithmParams: map[string]string{},
	})
	check(err)
	check(xenapi.VBD.Plug(session, vbdRef))
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
	// ResizeOnline tells the storage layer the guest is using the disk while it grows. Only some
	// storage drivers can (none of a stock XenServer 9's do), and the rest refuse with
	// SR_OPERATION_NOT_SUPPORTED - so ask the SR's driver (its SM record's features) first.
	srType, err := xenapi.SR.GetType(session, srRef)
	check(err)
	sms, err := xenapi.SM.GetAllRecords(session)
	check(err)
	resizeOnline := false
	for _, sm := range sms {
		if sm.Type == srType {
			_, resizeOnline = sm.Features["VDI_RESIZE_ONLINE"]
			break
		}
	}
	if resizeOnline {
		grownOnline := grown + GiB
		check(xenapi.VDI.ResizeOnline(session, vdiRef, grownOnline))
		final, _ := xenapi.VDI.GetVirtualSize(session, vdiRef)
		fmt.Printf("Grown online:   %d bytes\n", final)
	} else {
		fmt.Printf("Grown online:   not supported by %s storage; unplug, resize, plug as above\n", srType)
	}

	check(xenapi.VM.HardShutdown(session, vmRef))
	destroyVMAndDisks(session, vmRef)
	fmt.Println("OK: manage-vm-disks")
	session.Logout()
}

// --- Raise and dismiss alerts --------------------------------------------------------
func dismissAlerts(url, user, password string) {
	session := connect(url, user, password)
	messages, err := xenapi.Message.GetAllRecords(session)
	check(err)
	fmt.Printf("Alerts:         %d\n", len(messages))

	if len(messages) == 0 {
		fmt.Println("No alerts to dismiss.")
	} else {
		// Sorted, for a deterministic choice of which one to dismiss.
		refs := make([]string, 0, len(messages))
		for ref := range messages {
			refs = append(refs, string(ref))
		}
		sort.Strings(refs)
		ref := xenapi.MessageRef(refs[0])
		m := messages[ref]
		fmt.Printf("Dismissing:     %s (priority %d)\n", m.Name, m.Priority)
		check(xenapi.Message.Destroy(session, ref))
		left, _ := xenapi.Message.GetAllRecords(session)
		fmt.Printf("Alerts left:    %d\n", len(left))
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
	// "wake-on-lan" is a real, still-supported mode and needs no credentials; the legacy "iLO"/
	// "DRAC" modes were removed from the real power-on plugin and fail the moment host.power_on is
	// actually called ("{mode} script has been removed").
	check(xenapi.Host.SetPowerOnMode(session, hostRef, "wake-on-lan", map[string]string{}))
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

	// xapi checks its own preconditions before rotating - HA must be disabled, every host must be
	// live, no rolling pool upgrade may be in progress, and the pool must be licensed for it - and
	// raises a clear error naming which one failed rather than silently refusing. Report that
	// explanation instead of letting the failure speak for itself; the point here is demonstrating
	// the precondition handling, not requiring the rotation to succeed.
	explanations := map[string]string{
		xenapi.ErrorHaIsEnabled:               "HA is enabled on this pool; disable it first.",
		xenapi.ErrorCannotContactHost:         "a host in the pool is not reachable.",
		xenapi.ErrorNotSupportedDuringUpgrade: "a rolling pool upgrade is in progress.",
		xenapi.ErrorLicenceRestriction:        "this edition is not licensed for pool secret rotation.",
	}
	if err := xenapi.Pool.RotateSecret(session); err != nil {
		code := failureCode(err)
		explanation, ok := explanations[code]
		if !ok {
			explanation = "see the error for detail"
		}
		fmt.Printf("Could not rotate the pool secret: %s (%s)\n", code, explanation)
	} else {
		after, _ := xenapi.Pool.GetAll(session)
		fmt.Printf("Rotated. Still connected: %t\n", len(after) == 1)
	}
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
	// Whatever happens next, put the password back: a failure part-way would otherwise leave root on
	// the temporary one.
	restored := false
	defer func() {
		if !restored {
			session.ChangePassword(temporary, password)
		}
	}()

	// The existing session stays valid afterwards - only NEW connections need the new password.
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	fmt.Printf("Session still usable: %t\n", len(pools) == 1)

	// session.change_password on a ROOT session ignores old_pwd entirely (CA-13567, confirmed in
	// xapi_session.ml) - any string would also be accepted, so there is no "wrong old password is
	// rejected" failure to demonstrate here. The real gate is upstream of that: only a session
	// authenticated as the local superuser may call this at all. The Go binding keeps its session
	// id private, so check that the same way the RRD/export examples obtain one of their own - with
	// the NEW password, which is the one any new connection needs now.
	sid := rawLogin(url, user, temporary)
	isSuperuser := rawRPC(url, "session.get_is_local_superuser", sid, sid)
	fmt.Printf("Allowed because session.is_local_superuser = %s\n", isSuperuser)
	rawRPC(url, "session.logout", sid)

	check(session.ChangePassword(temporary, password))
	restored = true
	fmt.Println("Password restored.")
	fmt.Println("OK: change-root-password")
	session.Logout()
}

// --- Manage TLS certificates ---------------------------------------------------------
func manageCertificates(url, user, password string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	poolRef := pools[0]

	// A real, generated self-signed certificate, not a placeholder string: xapi decodes whatever is
	// handed to install_trusted_certificate/install_server_certificate as PEM and rejects anything
	// that isn't a well-formed certificate (INVALID_VALUE).
	certPEM, keyPEM := selfSignedCertPEM()

	certs, _ := xenapi.Certificate.GetAll(session)
	fmt.Printf("Certificates:   %d\n", len(certs))

	// ca=true: trusted as a root to verify a chain, not pinned as one specific leaf certificate.
	// purpose=[]: general pool trust. install_trusted_certificate is the current API (the
	// deprecated install_ca_certificate/uninstall_ca_certificate pair took a name instead) and
	// returns nothing, so find the new record by diffing the set.
	before := map[xenapi.CertificateRef]bool{}
	for _, ref := range certs {
		before[ref] = true
	}
	check(xenapi.Pool.InstallTrustedCertificate(session, poolRef, true, certPEM, []xenapi.CertificatePurpose{}))
	certs, _ = xenapi.Certificate.GetAll(session)
	fmt.Printf("After CA add:   %d\n", len(certs))
	var certRef xenapi.CertificateRef
	for _, ref := range certs {
		if !before[ref] {
			certRef = ref
			break
		}
	}

	// Actually replace the host's own TLS identity with a real certificate (beyond CA trust), then
	// reset it back to a fresh self-signed one, as before.
	check(xenapi.Host.InstallServerCertificate(session, hosts[0], certPEM, keyPEM, ""))
	fmt.Println("Host certificate replaced with a real, generated certificate.")
	check(xenapi.Host.ResetServerCertificate(session, hosts[0]))
	fmt.Println("Host certificate reset (a fresh self-signed identity).")

	check(xenapi.Pool.UninstallTrustedCertificate(session, poolRef, certRef))
	certs, _ = xenapi.Certificate.GetAll(session)
	fmt.Printf("After CA remove:%d\n", len(certs))

	// Separately from which certificates exist: whether the pool actually CHECKS the ones its members
	// present to each other. Turning it on is a one-way door from here - there is no matching disable,
	// because a pool that could be talked out of verifying would not be verifying - so the call is
	// idempotent and safe to repeat.
	verifying, _ := xenapi.Pool.GetTLSVerificationEnabled(session, poolRef)
	fmt.Printf("TLS verification: %t\n", verifying)
	check(xenapi.Pool.EnableTLSVerification(session))
	verifying, _ = xenapi.Pool.GetTLSVerificationEnabled(session, poolRef)
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

	// Run it three times against a retention of two: the oldest is pruned away. Compare against the
	// snapshots the VM already had, so only the schedule's own are counted (and tidied up below).
	existing, err := xenapi.VM.GetSnapshots(session, vmRef)
	check(err)
	before := map[xenapi.VMRef]bool{}
	for _, s := range existing {
		before[s] = true
	}
	for i := 0; i < 3; i++ {
		_, err = xenapi.VMSS.SnapshotNow(session, vmssRef)
		check(err)
	}
	snaps, err := xenapi.VM.GetSnapshots(session, vmRef)
	check(err)
	var kept []xenapi.VMRef
	for _, s := range snaps {
		if !before[s] {
			kept = append(kept, s)
		}
	}
	fmt.Printf("Snapshots kept:   %d (retention 2)\n", len(kept))

	// Tidy up: a schedule with VMs still on it cannot be destroyed (VMSS_HAS_VM), so take the VM off it
	// first. Destroying the schedule leaves the snapshots it took, so destroy those too, with their disks.
	check(xenapi.VM.SetSnapshotSchedule(session, vmRef, "OpaqueRef:NULL"))
	check(xenapi.VMSS.Destroy(session, vmssRef))
	for _, s := range kept {
		destroyVMAndDisks(session, s)
	}
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

	// VM_group.destroy already clears the group from every member VM's groups field - no need to
	// remove membership ourselves first.
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
	wasRunning := false
	if state, _ := xenapi.VM.GetPowerState(session, vmRef); state == xenapi.VMPowerStateRunning {
		wasRunning = true
	}

	snapRef, err := xenapi.VM.Snapshot(session, vmRef, snapshotName, nil)
	check(err)
	uuid, _ := xenapi.VM.GetUUID(session, snapRef)
	fmt.Printf("Created snapshot: %s\n", uuid)

	// A client shows a thumbnail of what was on screen when the snapshot was taken, captured from the VM's
	// console at that moment. It is an HTTP transfer alongside the API, not an API call, so the session id
	// travels in the query string. ref names the VM's VNC (rfb) console, as XenCenter does (the VM itself
	// works too). Only a running VM has a console to capture, and a host that can't reach it answers 404 or
	// 500 instead of an image: the picture is incidental, so carry on. The Go binding keeps its own session
	// private, so obtain one of our own the same way the RRD/export examples do.
	if state, _ := xenapi.VM.GetPowerState(session, vmRef); state == xenapi.VMPowerStateRunning {
		consoles, err := xenapi.VM.GetConsoles(session, vmRef)
		check(err)
		var console xenapi.ConsoleRef
		for _, c := range consoles {
			if p, err := xenapi.Console.GetProtocol(session, c); err == nil && p == xenapi.ConsoleProtocolRfb {
				console = c
				break
			}
		}
		sid := rawLogin(url, user, password)
		resp, err := insecureClient().Get(fmt.Sprintf("%s/vncsnapshot?session_id=%s&ref=%s", url, sid, console))
		check(err)
		thumb, err := io.ReadAll(resp.Body)
		check(err)
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			fmt.Printf("Thumbnail:      %d bytes of PNG\n", len(thumb))
		} else {
			fmt.Printf("Thumbnail:      none (the host answered HTTP %d)\n", resp.StatusCode)
		}
	} else {
		fmt.Println("Thumbnail:      none (the VM is not running, so it has no console)")
	}

	check(xenapi.VM.Revert(session, snapRef))
	fmt.Println("Reverted VM to the snapshot.")

	// Reverting to a plain snapshot always leaves the VM Halted (xapi hard-shuts-down a running VM
	// before reverting it), even if it was Running a moment ago - restart it if that is how we
	// found it, so the workflow actually restores what it changed.
	if wasRunning {
		check(xenapi.VM.Start(session, vmRef, false, true))
		fmt.Println("Restarted the VM (it was running before the revert).")
	}

	// A snapshot is itself a (special) VM record, with its own snapshot disks; destroy both to clean up
	// (the source VM's disks are untouched - they are not the snapshot's).
	destroyVMAndDisks(session, snapRef)
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

	detachAndForgetSR(session, srRef)
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
		// Managed by xapi (bridge and PIFs created for it). Say so: the binding sends every field, and
		// the zero value is false - an unmanaged network, which a bond refuses.
		Managed: true,
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
	original, err := xenapi.VM.GetNameDescription(session, vmRef)
	check(err)
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

	check(xenapi.VM.SetNameDescription(session, vmRef, original)) // put it back
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
	// A Go record sends every field, enums included, and a real host rejects an empty enum value
	// (INTERNAL_ERROR "Unknown tag/contents"), so set the enums to the defaults xapi applies when
	// they are left out.
	_, err = xenapi.VIF.Create(session, xenapi.VIFRecord{
		VM: vm, Network: netRef, Device: vifDevices[0], MAC: "", MTU: 1500,
		OtherConfig: map[string]string{}, QosAlgorithmParams: map[string]string{},
		LockingMode:           xenapi.VifLockingModeNetworkDefault,
		Ipv4ConfigurationMode: xenapi.VifIpv4ConfigurationModeNone,
		Ipv6ConfigurationMode: xenapi.VifIpv6ConfigurationModeNone,
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
// liveMigrate live-migrates a running VM to another host in the pool, with no downtime. Moves a
// throwaway copy of sourceVM, a VM with a guest OS and PV drivers: live migration needs the
// guest's cooperation (VM_LACKS_FEATURE without PV drivers). Only the VM's memory moves, so the
// destination host has to see its disks already: a disk on local storage refuses with
// VM_REQUIRES_SR. Put the copy's disks on the shared SR srName first.
func liveMigrate(url, user, password, sourceVM, srName, newVMName string) {
	session := connect(url, user, password)
	vm := copyOfGuest(session, sourceVM, newVMName)
	moveDisksToSR(session, vm, srByName(session, srName, true))
	check(xenapi.VM.Start(session, vm, false, true))
	waitForGuestAgent(session, vm)

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
	destroyVMAndDisks(session, vm)
	fmt.Println("OK: live-migrate")
	session.Logout()
}

// Run it:
//   liveMigrate("https://xenserver", "root", password, "web-01", "Shared NFS", "sdk-example-migrate")

// --- 11. Enter & exit maintenance mode -------------------------------------------------
// hostMaintenance disables a host, evacuates its running guests to another host, then re-enables
// it. Pins a throwaway copy of sourceVM to the host so evacuation has work to do. Evacuation
// live-migrates the guest, which needs its cooperation (VM_LACKS_FEATURE without PV drivers), so
// sourceVM must have a guest OS with PV drivers.
func hostMaintenance(url, user, password, sourceVM, srName, newVMName string) {
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
	vm := copyOfGuest(session, sourceVM, newVMName)
	// Evacuation needs somewhere else in the pool that can actually see the VM's disk - a VM whose
	// only disk is on local (non-shared) storage can't be evacuated at all (VM_REQUIRES_SR), and a
	// pool's installation-time default SR is commonly local storage. Put the pinned VM's disk on a
	// shared SR explicitly rather than trusting whatever the pool default happens to be.
	moveDisksToSR(session, vm, srByName(session, srName, true))
	check(xenapi.VM.SetAffinity(session, vm, hostRef))
	check(xenapi.VM.Start(session, vm, false, true))
	waitForGuestAgent(session, vm)
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
	destroyVMAndDisks(session, vm)
	fmt.Println("OK: host-maintenance")
	session.Logout()
}

// Run it:
//   hostMaintenance("https://xenserver", "root", password, "web-01", "Shared NFS", "sdk-example-maint")

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

	// VM.Copy (like VM.Clone) requires a Halted source - VM_BAD_POWER_STATE otherwise - so shut a
	// running source down first and start it back up again afterwards, rather than assuming it is
	// already halted.
	wasRunning := false
	if state, _ := xenapi.VM.GetPowerState(session, source); state == xenapi.VMPowerStateRunning {
		wasRunning = true
		check(xenapi.VM.CleanShutdown(session, source))
	}

	copyRef, err := xenapi.VM.Copy(session, source, copyName, srRef)
	check(err)
	uuid, _ := xenapi.VM.GetUUID(session, copyRef)
	vbds, _ := xenapi.VM.GetVBDs(session, copyRef)
	isTemplate, _ := xenapi.VM.GetIsATemplate(session, copyRef)
	fmt.Printf("Copied VM:     %s\n", uuid)
	fmt.Printf("Copy has %d VBD(s), is_a_template = %v\n", len(vbds), isTemplate)

	if wasRunning {
		check(xenapi.VM.Start(session, source, false, true))
	}

	// Tidy up: destroy the copy and its disks, leaving the source VM intact.
	destroyVMAndDisks(session, copyRef)
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
	provision(session, vmRef)

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
	destroyVMAndDisks(session, vmRef)
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
// introduceUpdateRepositories introduces the pool's update repositories the way XenCenter does: the
// release's base packages (update=false) and its update stream (update=true, which
// Pool.SyncUpdates needs - otherwise NO_REPOSITORY_ENABLED). A real host checks the URLs
// (INVALID_BASE_URL for an unknown domain), so these are the XenServer CDN's, e.g.
// https://repo.ops.xenserver.com/xs9/{base,normal}.
func introduceUpdateRepositories(session *xenapi.Session, repoURL, sourceURL string) []xenapi.RepositoryRef {
	var repos []xenapi.RepositoryRef
	for _, stage := range []string{"base", "normal"} {
		repo, err := xenapi.Repository.Introduce(session, "sdk-example-"+stage,
			"SDK example "+stage+" repository",
			repoURL+"/"+stage, sourceURL+"/"+stage, stage != "base", "")
		check(err)
		repos = append(repos, repo)
	}
	return repos
}

func configureUpdates(url, user, password, repoURL, sourceURL string) {
	session := connect(url, user, password)
	repos := introduceUpdateRepositories(session, repoURL, sourceURL)
	var names []string
	for _, repo := range repos {
		name, _ := xenapi.Repository.GetNameLabel(session, repo)
		names = append(names, name)
	}
	fmt.Printf("Introduced repositories: %s\n", strings.Join(names, ", "))

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	pool := pools[0]
	// Remember the pool's own repositories, to put them back afterwards.
	previous, perr := xenapi.Pool.GetRepositories(session, pool)
	check(perr)
	check(xenapi.Pool.SetRepositories(session, pool, repos))
	check(xenapi.Pool.SetUpdateSyncEnabled(session, pool, true))
	nowRepos, _ := xenapi.Pool.GetRepositories(session, pool)
	enabled, _ := xenapi.Pool.GetUpdateSyncEnabled(session, pool)
	fmt.Printf("Pool repositories: %d; auto-sync enabled: %v\n", len(nowRepos), enabled)

	// Tidy up so the example is repeatable.
	check(xenapi.Pool.SetUpdateSyncEnabled(session, pool, false))
	check(xenapi.Pool.SetRepositories(session, pool, previous))
	for _, repo := range repos {
		check(xenapi.Repository.Forget(session, repo))
	}
	fmt.Println("OK: configure-updates")
	session.Logout()
}

// Run it:
//   configureUpdates("https://xenserver", "root", password, "https://repo.ops.xenserver.com/xs9",
//       "https://repo-src.ops.xenserver.com/xs9")

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

// destroyVMAndDisks destroys a VM (or snapshot, or template) an example made, and the disks it owns.
// VM.Destroy removes only the VM record and leaves its disks behind, so collect them first and destroy
// them afterwards - exactly what deleteVM does by hand.
func destroyVMAndDisks(session *xenapi.Session, vm xenapi.VMRef) {
	vdis := diskVdis(session, vm)
	// A checkpoint (or a suspended VM) also owns a suspend image holding its memory, which no VBD
	// points at: destroy that as well.
	suspendVDI, err := xenapi.VM.GetSuspendVDI(session, vm)
	check(err)
	if suspendVDI != "OpaqueRef:NULL" {
		vdis = append(vdis, suspendVDI)
	}
	check(xenapi.VM.Destroy(session, vm))
	for _, vdi := range vdis {
		check(xenapi.VDI.Destroy(session, vdi))
	}
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
	destroyVMAndDisks(session, clone)
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
	provision(session, vm)
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
// storageMigrate relocates a running VM's disk to a different SR without stopping it (live
// storage migration) with VDI.PoolMigrate.
//
// Moving a running VM's disk needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers),
// so this works on a throwaway copy of sourceVM, a VM with a guest OS and PV drivers. (A halted
// VM's disk moves too, without the guest; what VDI.PoolMigrate always needs is a VM to move the
// disk for - a VDI no VBD points at fails VDI_NEEDS_VM_FOR_MIGRATE.)
func storageMigrate(url, user, password, sourceVM, newVMName string) {
	session := connect(url, user, password)
	vm := copyOfGuest(session, sourceVM, newVMName)
	check(xenapi.VM.Start(session, vm, false, true))
	waitForGuestAgent(session, vm)
	vdi := diskVdis(session, vm)[0]
	sourceSr, err := xenapi.VDI.GetSR(session, vdi)
	check(err)
	srcSrName, _ := xenapi.SR.GetNameLabel(session, sourceSr)
	fmt.Printf("Disk is on SR: %s\n", srcSrName)

	// Pick a different SR that holds disks and that the VM's host can reach (an attached PBD there).
	host, err := xenapi.VM.GetResidentOn(session, vm)
	check(err)
	srs, err := xenapi.SR.GetAllRecords(session)
	check(err)
	var destSr xenapi.SRRef
	found := false
	for ref, sr := range srs {
		if ref == sourceSr || sr.ContentType == "iso" || sr.Type == "iso" || sr.Type == "udev" {
			continue
		}
		for _, pbdRef := range sr.PBDs {
			pbdHost, err := xenapi.PBD.GetHost(session, pbdRef)
			check(err)
			attached, err := xenapi.PBD.GetCurrentlyAttached(session, pbdRef)
			check(err)
			if pbdHost == host && attached {
				destSr, found = ref, true
				break
			}
		}
		if found {
			break
		}
	}
	if !found {
		panic("no destination SR reachable from the VM's resident host was found")
	}

	// PoolMigrate returns the disk's new VDI: the copy on the destination SR replaces the original.
	vdi, err = xenapi.VDI.PoolMigrate(session, vdi, destSr, map[string]string{})
	check(err)

	nowOn, _ := xenapi.VDI.GetSR(session, vdi)
	nowName, _ := xenapi.SR.GetNameLabel(session, nowOn)
	fmt.Printf("Disk moved to:  %s\n", nowName)

	// Tidy up: the VM and the disks it now owns.
	check(xenapi.VM.HardShutdown(session, vm))
	destroyVMAndDisks(session, vm)
	fmt.Println("OK: storage-migrate")
	session.Logout()
}

// Run it:
//   storageMigrate("https://xenserver", "root", password, "web-01", "sdk-example-storagemigrate")

// --- 20. Apply updates from the CDN -----------------------------------------------------
// pool.sync_updates needs at least one repository with update=true enabled
// (NO_REPOSITORY_ENABLED otherwise) - introduce and attach a throwaway one, and forget it again
// afterwards. Applying a batch whose mandatory guidance needs an evacuation fails with
// HOST_EVACUATION_IS_REQUIRED unless the host's resident VMs are moved off first; handle that
// rather than assuming an update batch never asks for one.
func applyUpdate(url, user, password, repoURL, sourceURL string) {
	session := connect(url, user, password)
	// Deferred first, so it runs LAST: after the deferred repository restore below, which needs
	// the session. A closure, so it logs out whichever session is current by then.
	defer func() { session.Logout() }()
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	pool := pools[0]
	repos := introduceUpdateRepositories(session, repoURL, sourceURL)
	// Remember the pool's own repositories, to put them back afterwards.
	previous, perr := xenapi.Pool.GetRepositories(session, pool)
	check(perr)
	check(xenapi.Pool.SetRepositories(session, pool, repos))
	defer func() {
		check(xenapi.Pool.SetRepositories(session, pool, previous))
		for _, repo := range repos {
			check(xenapi.Repository.Forget(session, repo))
		}
	}()

	// Sync the pool's update metadata; the returned hash identifies the synced set.
	hash, err := xenapi.Pool.SyncUpdates5(session, pool, false, "", "")
	check(err)
	fmt.Printf("Synced updates; hash length %d\n", len(hash))

	// Apply the synced updates to each host. XenCenter then reads the reboot guidance to decide
	// whether a Rolling Pool Upgrade reboot is needed.
	hosts, err := xenapi.Host.GetAllRecords(session)
	check(err)
	for hostRef, host := range hosts {
		if _, err := xenapi.Host.ApplyUpdates(session, hostRef, hash); err != nil {
			if failureCode(err) != xenapi.ErrorHostEvacuationIsRequired {
				panic(err)
			}
			fmt.Printf("  %s: needs evacuating first; evacuating and retrying\n", host.NameLabel)
			check(xenapi.Host.Disable(session, hostRef, false))
			check(xenapi.Host.Evacuate2(session, hostRef))
			_, err := xenapi.Host.ApplyUpdates(session, hostRef, hash)
			check(err)
			check(xenapi.Host.Enable(session, hostRef))
		}
		guidance, _ := xenapi.Host.GetPendingGuidances(session, hostRef)
		fmt.Printf("  %s: applied; pending guidance = %v\n", host.NameLabel, guidance)
		// Modern xapi (>=23.18.0) doesn't reboot a host for you: it only records pending_guidances,
		// so only reboot (or restart the toolstack) when the applied batch actually asks for it.
		rebootHost := containsGuidance(guidance, xenapi.UpdateGuidancesRebootHost)
		if rebootHost || containsGuidance(guidance, xenapi.UpdateGuidancesRestartToolstack) {
			// As in rolling-pool-update: either restart returns before it has happened, and the
			// coordinator's takes this session with it - so wait for it, reconnecting.
			key := "agent_start_time"
			if rebootHost {
				key = "boot_time"
			}
			otherConfig, err := xenapi.Host.GetOtherConfig(session, hostRef)
			check(err)
			before := otherConfig[key]
			if rebootHost {
				check(xenapi.Host.Reboot(session, hostRef))
			} else {
				check(xenapi.Host.RestartAgent(session, hostRef))
			}
			session = waitForRestart(url, user, password, host.UUID, key, before)
		}
		// apply_updates disables the host while it works (auto_enable: a restart puts it back) - with
		// no restart to do, nothing re-enables it. Return it to service either way.
		enableWhenBooted(session, hostRef)
	}
	fmt.Println("OK: apply-update")
}

// containsGuidance reports whether a host's pending_guidances includes the named one.
func containsGuidance(guidance []xenapi.UpdateGuidances, want xenapi.UpdateGuidances) bool {
	for _, g := range guidance {
		if g == want {
			return true
		}
	}
	return false
}

// Run it:
//   applyUpdate("https://xenserver", "root", password, "https://repo.ops.xenserver.com/xs9",
//       "https://repo-src.ops.xenserver.com/xs9")

// --- 21. Checkpoint & revert ------------------------------------------------------------
// checkpointVM checkpoints a throwaway copy of a VM with a guest OS, then reverts it back to that
// checkpoint. A checkpoint captures disk AND memory (unlike a plain snapshot), so the VM must be
// running. Checkpointing needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers),
// hence a copy of sourceVM - a VM with a guest OS and PV drivers - rather than an OS-less template
// clone.
func checkpointVM(url, user, password, sourceVM, newVMName string) {
	session := connect(url, user, password)
	vm := copyOfGuest(session, sourceVM, newVMName)
	check(xenapi.VM.Start(session, vm, false, true))
	waitForGuestAgent(session, vm)

	checkpoint, err := xenapi.VM.Checkpoint(session, vm, "sdk-example-checkpoint-1")
	check(err)
	uuid, _ := xenapi.VM.GetUUID(session, checkpoint)
	fmt.Printf("Created checkpoint: %s\n", uuid)
	isSnapshot, _ := xenapi.VM.GetIsASnapshot(session, checkpoint)
	fmt.Printf("is_a_snapshot = %v\n", isSnapshot)

	check(xenapi.VM.Revert(session, checkpoint))
	// A checkpoint's own power_state is always Suspended (it captures memory as well as disk), and
	// VM.Revert restores exactly that - so the VM is Suspended here, not Running as it was before
	// the checkpoint, with a suspend_VDI holding the checkpoint's memory image. VM.Resume clears
	// that: destroying a Suspended VM directly (as a bare "if Running: hard_shutdown" guard would,
	// since the VM is never Running here) leaves that suspend_VDI behind as a storage leak.
	ps, _ := xenapi.VM.GetPowerState(session, vm)
	fmt.Printf("Reverted the VM to the checkpoint; power state now: %s\n", ps)
	check(xenapi.VM.Resume(session, vm, false, true))

	// Tidy up. The checkpoint owns its own snapshot disks, separate from the VM's.
	destroyVMAndDisks(session, checkpoint)
	check(xenapi.VM.HardShutdown(session, vm))
	destroyVMAndDisks(session, vm)
	fmt.Println("OK: checkpoint-vm")
	session.Logout()
}

// Run it:
//   checkpointVM("https://xenserver", "root", password, "web-01", "sdk-example-checkpoint")

// --- 22. Attach a new disk to a VM ------------------------------------------------------
func attachDisk(url, user, password, templateName, srName, newVMName string) {
	const GiB = 1024 * 1024 * 1024

	session := connect(url, user, password)
	vm, err := xenapi.VM.Clone(session, templateByName(session, templateName), newVMName)
	check(err)
	provision(session, vm)
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
		Bootable: false,
		Mode:     xenapi.VbdModeRW, Type: xenapi.VbdTypeDisk, Empty: false,
		OtherConfig: map[string]string{}, QosAlgorithmParams: map[string]string{},
	})
	check(err)
	srLabel, _ := xenapi.SR.GetNameLabel(session, srRef)
	fmt.Printf("Attached an 8 GiB disk on %s as device %s\n", srLabel, device)
	vbds, _ := xenapi.VM.GetVBDs(session, vm)
	fmt.Printf("VM now has %d VBD(s)\n", len(vbds))

	// Tidy up: destroy the VM (which removes its VBDs) and then its disks (VM.Destroy leaves VDIs
	// behind), including the one just attached.
	destroyVMAndDisks(session, vm)
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
	free, _ := xenapi.Host.ComputeFreeMemory(session, hostRef)
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
	provision(session, vm)

	check(xenapi.VM.SetVCPUsMax(session, vm, 4))
	check(xenapi.VM.SetVCPUsAtStartup(session, vm, 2))

	// Boot mode: firmware ("bios"/"uefi") lives in HVM_boot_params; Secure Boot in
	// platform["secureboot"]. "auto" (not a hard-coded "true") is the real xe/XenCenter convention:
	// xapi resolves it against whether the pool actually holds Secure Boot certificates, at
	// VM.start time - a hard "true" would claim Secure Boot is on even on a template that was never
	// set up for it, since set_platform does no validation of its own.
	check(xenapi.VM.SetHVMBootParams(session, vm, map[string]string{"order": "cdn", "firmware": "uefi"}))
	platform, _ := xenapi.VM.GetPlatform(session, vm)
	platform["secureboot"] = "auto"
	check(xenapi.VM.SetPlatform(session, vm, platform))
	atStartup, _ := xenapi.VM.GetVCPUsAtStartup(session, vm)
	max, _ := xenapi.VM.GetVCPUsMax(session, vm)
	fmt.Printf("vCPUs: %d/%d\n", atStartup, max)
	bootParams, _ := xenapi.VM.GetHVMBootParams(session, vm)
	fmt.Printf("Boot order: %s\n", bootParams["order"])
	platform, _ = xenapi.VM.GetPlatform(session, vm)
	fmt.Printf("Boot mode: firmware=%s, secureboot=%s (resolved against pool certificates at boot)\n",
		bootParams["firmware"], platform["secureboot"])

	destroyVMAndDisks(session, vm)
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
	// Role is the one class XenCenter still bulk-downloads; RBAC subjects map to these roles. Role records
	// include every permission too; the roles a user can be granted are the ones made of permissions
	// (non-empty subroles), as xe role-list shows.
	roles, err := xenapi.Role.GetAllRecords(session)
	check(err)
	seen := map[string]bool{}
	var names []string
	for _, r := range roles {
		if len(r.Subroles) > 0 && !seen[r.NameLabel] {
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
	provision(session, vm)
	nets, err := xenapi.Network.GetAll(session)
	check(err)
	netRef := nets[0]
	devices, err := xenapi.VM.GetAllowedVIFDevices(session, vm)
	check(err)
	device := devices[0]

	// A Go record sends every field, enums included, and a real host rejects an empty enum value
	// (INTERNAL_ERROR "Unknown tag/contents"), so set the enums to the defaults xapi applies when
	// they are left out.
	vif, err := xenapi.VIF.Create(session, xenapi.VIFRecord{
		VM: vm, Network: netRef, Device: device, MAC: "", MTU: 1500,
		OtherConfig: map[string]string{}, QosAlgorithmParams: map[string]string{},
		LockingMode:           xenapi.VifLockingModeNetworkDefault,
		Ipv4ConfigurationMode: xenapi.VifIpv4ConfigurationModeNone,
		Ipv6ConfigurationMode: xenapi.VifIpv6ConfigurationModeNone,
	})
	check(err)
	vifs, _ := xenapi.VM.GetVIFs(session, vm)
	fmt.Printf("Attached a VIF on device %s; VM now has %d NIC(s)\n", device, len(vifs))

	check(xenapi.VIF.Destroy(session, vif))
	destroyVMAndDisks(session, vm)
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
		var size int64
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
	provision(session, vm) // now a real (halted) VM
	isTemplate, _ := xenapi.VM.GetIsATemplate(session, vm)
	fmt.Printf("is_a_template after provision: %v\n", isTemplate)

	// Converting a VM to a custom template is a one-way operation.
	check(xenapi.VM.SetIsATemplate(session, vm, true))
	isTemplate, _ = xenapi.VM.GetIsATemplate(session, vm)
	fmt.Printf("is_a_template after convert:  %v\n", isTemplate)

	destroyVMAndDisks(session, vm)
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
// rollingPoolUpdate needs an enabled update repository the same way apply-update does - introduce
// and attach a throwaway one, forget it again afterwards. Modern xapi (>=23.18.0) doesn't reboot a
// host for you: it only records pending_guidances, so only reboot (or restart the toolstack) when
// the applied batch actually asks for it.
func rollingPoolUpdate(url, user, password, repoURL, sourceURL string) {
	session := connect(url, user, password)
	// Deferred first, so it runs LAST: after the deferred repository restore below, which needs
	// the session. A closure, so it logs out whichever session is current by then.
	defer func() { session.Logout() }()
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	pool := pools[0]
	repos := introduceUpdateRepositories(session, repoURL, sourceURL)
	// Remember the pool's own repositories, to put them back afterwards.
	previous, perr := xenapi.Pool.GetRepositories(session, pool)
	check(perr)
	check(xenapi.Pool.SetRepositories(session, pool, repos))
	defer func() {
		check(xenapi.Pool.SetRepositories(session, pool, previous))
		for _, repo := range repos {
			check(xenapi.Repository.Forget(session, repo))
		}
	}()

	hash, err := xenapi.Pool.SyncUpdates5(session, pool, false, "", "")
	check(err)
	fmt.Printf("Synced updates; hash length %d\n", len(hash))

	// The rolling pattern behind XenCenter's automated Install Updates:
	// disable -> evacuate -> apply -> reboot (only if asked) -> re-enable, one host at a time.
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
		rebootHost := containsGuidance(guidance, xenapi.UpdateGuidancesRebootHost)
		restartToolstack := containsGuidance(guidance, xenapi.UpdateGuidancesRestartToolstack)
		if rebootHost || restartToolstack {
			// Either restart returns before it has happened, and if this host is the coordinator it
			// takes this session with it - so note when the host last started, restart it, and
			// reconnect until it reports a newer start and is live again.
			key := "agent_start_time"
			if rebootHost {
				key = "boot_time"
			}
			otherConfig, err := xenapi.Host.GetOtherConfig(session, hostRef)
			check(err)
			before := otherConfig[key]
			if rebootHost {
				check(xenapi.Host.Reboot(session, hostRef)) // reboot into the updated software
			} else {
				check(xenapi.Host.RestartAgent(session, hostRef))
			}
			session = waitForRestart(url, user, password, host.UUID, key, before)
		}
		enableWhenBooted(session, hostRef) // return the host to service
	}
	fmt.Println("OK: rolling-pool-update")
}

// --- 42. Cross-pool copy a VM --------------------------------------------------------
// Copy a VM from one pool to another (Storage XenMotion copy): get a receiver token from the
// destination with host.migrate_receive, then VM.migrate_send with copy=true on the source.
func crossPoolCopyVM(url, user, password, destURL, vmName, destUser, destPassword string) {
	source := connect(url, user, password)
	if destUser == "" {
		destUser, destPassword = user, password
	}
	dest := connect(destURL, destUser, destPassword)
	// Destination: choose a host, network and SR, then ask for a receiver token. The disks go to
	// the destination pool's default SR and the data travels over the host's management network -
	// one both pools can certainly reach (the first network listed may well not be).
	destPools, err := xenapi.Pool.GetAll(dest)
	check(err)
	destHost, err := xenapi.Pool.GetMaster(dest, destPools[0])
	check(err)
	destSr, err := xenapi.Pool.GetDefaultSR(dest, destPools[0])
	check(err)
	pifs, err := xenapi.Host.GetPIFs(dest, destHost)
	check(err)
	var destNetwork xenapi.NetworkRef
	for _, pif := range pifs {
		if management, _ := xenapi.PIF.GetManagement(dest, pif); management {
			destNetwork, err = xenapi.PIF.GetNetwork(dest, pif)
			check(err)
		}
	}
	receiver, err := xenapi.Host.MigrateReceive(dest, destHost, destNetwork, map[string]string{})
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
		vifMap[vif] = destNetwork
	}

	// MigrateSend8 is the 8-argument form every pool version accepts; MigrateSend itself takes newer
	// arguments that older hosts reject.
	copied, err := xenapi.VM.MigrateSend8(source, vm, receiver, false, vdiMap, vifMap,
		map[string]string{"copy": "true"}, map[xenapi.VGPURef]xenapi.GPUGroupRef{})
	check(err)
	fmt.Printf("Sent '%s' to the destination pool (copy); source still present: %v\n",
		vmName, vmByName(source, vmName) == vm)
	// The result is the new VM's ref on the DESTINATION pool - use the destination session to read it.
	copyName, err := xenapi.VM.GetNameLabel(dest, copied)
	check(err)
	copyUUID, err := xenapi.VM.GetUUID(dest, copied)
	check(err)
	fmt.Printf("  the copy on the destination: %s (%s)\n", copyName, copyUUID)
	fmt.Println("OK: cross-pool-copy-vm")
	dest.Logout()
	source.Logout()
}

// Run it:
//   crossPoolCopyVM("https://poolA", "root", password, "https://poolB", "db-01", "", "")

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
			Values []any `json:"values"`
		} `json:"data"`
	}
	check(json.NewDecoder(resp.Body).Decode(&rrd))

	peak := map[string]float64{}
	for _, point := range rrd.Data {
		for k, legend := range rrd.Meta.Legend {
			parts := strings.Split(legend, ":")
			if parts[1] != "host" || parts[3] != "pvsaccelerator_space_utilization" {
				continue
			}
			// A host sends each value as a string ("0.0", or "NaN" for a gap in the series).
			var v float64
			switch x := point.Values[k].(type) {
			case string:
				v, _ = strconv.ParseFloat(x, 64)
			case float64:
				v = x
			}
			if v != v { // NaN: a gap in the series, not a real sample - never let it stick
				continue
			}
			// A plain `v > peak[key]` relies on a zero-valued map default, so a real 0.0 reading
			// (the common, unconfigured-PVS case) would never get inserted and the whole per-host
			// loop would silently print nothing - track presence explicitly instead.
			if cur, ok := peak[parts[2]]; !ok || v > cur {
				peak[parts[2]] = v
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
	// Compare case-insensitively: a real host's trim plugin answers "True" (capitalised).
	if strings.ToLower(strings.TrimSpace(result)) != "true" {
		panic("trim plugin returned " + result)
	}
	fmt.Println("OK: reclaim-space")
	session.Logout()
}

// --- 46. Get a VM's IP address --------------------------------------------------------
// A VM that has only just started may not have reported in yet (no guest_metrics at all, or an
// empty networks map) - retry for a while rather than giving up on the first look, the way XenRT's
// own IP-discovery helpers do. The CLI version of this example already does this; timeoutStr and
// intervalStr bring the SDK languages in line with it (seconds, as decimal strings).
func vmIpAddress(url, user, password, timeoutStr, intervalStr string) {
	timeout, err := strconv.Atoi(timeoutStr)
	check(err)
	interval, err := strconv.Atoi(intervalStr)
	check(err)
	session := connect(url, user, password)

	deadline := time.Now().Add(time.Duration(timeout) * time.Second)
	for {
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
		var ip string
		if found {
			gm, err := xenapi.VMGuestMetrics.GetRecord(session, vm.GuestMetrics)
			check(err)
			ip = gm.Networks["0/ip"]
		}
		if ip != "" {
			fmt.Printf("  %s: %s\n", vm.NameLabel, ip)
			break
		}
		if time.Now().After(deadline) {
			panic(fmt.Sprintf("no running guest reported an IP address within %ds", timeout))
		}
		time.Sleep(time.Duration(interval) * time.Second)
	}
	fmt.Println("OK: vm-ip-address")
	session.Logout()
}

// --- 47. Manage Active Directory users ------------------------------------------------
// manageAdUsers joins AD, adds a user as a subject with an RBAC role, reads it back, then tidies
// up. Needs a real, reachable AD domain controller - EnableExternalAuth fails at the very first
// call (DNS/LDAP/Kerberos) without one, so domain/adminUser/adminPassword have to identify a real
// domain to join. Before joining, every host must resolve the domain (point its DNS at a domain
// controller) and keep its clock close to the DC's (Kerberos). Current Windows DCs want LDAPS
// (ldaps="true"), which also needs the pool to trust the DC's CA certificate
// (xenapi.Pool.InstallTrustedCertificate with purpose "ldaps"). newUser is the account to grant a
// role to; its subject identity is looked up against the directory, so it has to be a real account
// there too. A pool already joined to this domain is used as it is - and left joined. The
// simulator models a single-user, domain-less fake directory (hence the empty domain default) -
// override every one of these on a real pool.
func manageAdUsers(url, user, password, domain, adminUser, adminPassword, newUser, ldaps string) {
	session := connect(url, user, password)

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	pool := pools[0]
	coordinator, err := xenapi.Pool.GetMaster(session, pool)
	check(err)
	authType, err := xenapi.Host.GetExternalAuthType(session, coordinator)
	check(err)
	authDomain, err := xenapi.Host.GetExternalAuthServiceName(session, coordinator)
	check(err)
	alreadyJoined := domain != "" && authType == "AD" && strings.EqualFold(authDomain, domain)
	if alreadyJoined {
		fmt.Printf("Already joined to domain: %s\n", domain)
	} else {
		check(xenapi.Pool.EnableExternalAuth(session, pool,
			map[string]string{"user": adminUser, "pass": adminPassword, "ldaps": ldaps}, domain, "AD"))
		if domain != "" {
			fmt.Printf("Joined domain: %s\n", domain)
		} else {
			fmt.Println("Joined domain: (none - simulator's fake directory)")
		}
	}

	subjectName := newUser
	if domain != "" {
		subjectName = newUser + "@" + domain
	}
	sid, err := xenapi.Auth.GetSubjectIdentifier(session, subjectName)
	check(err)
	info, err := xenapi.Auth.GetSubjectInformationFromIdentifier(session, sid)
	check(err)
	subject, err := xenapi.Subject.Create(session, xenapi.SubjectRecord{SubjectIdentifier: sid, OtherConfig: info})
	check(err)

	// role.get_by_name_label is simpler/more idiomatic than filtering get_all_records, and matches
	// what `xe subject-role-add role-name=` does server-side.
	roleRefs, err := xenapi.Role.GetByNameLabel(session, "pool-admin")
	check(err)
	admin := roleRefs[0]
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
	if !alreadyJoined {
		// Leave the way it was found. Passing the admin credentials also removes the pool's computer
		// accounts from the directory; with {} they stay behind in AD.
		check(xenapi.Pool.DisableExternalAuth(session, pool,
			map[string]string{"user": adminUser, "pass": adminPassword}))
	}
	fmt.Println("OK: manage-ad-users")
	session.Logout()
}

// firstXMLElement scans an XML document for the first element named tag, at any depth (the root
// element name and nesting both vary by host/backend - the probe helpers below must not assume
// either), and returns a map of its immediate child elements' tag name to text content.
func firstXMLElement(xmlText, tag string) map[string]string {
	return findXMLElement(xmlText, tag, "", "")
}

// findXMLElement is firstXMLElement for the first <tag> whose child <key> has the given text (any
// <tag>, when value is "").
func findXMLElement(xmlText, tag, key, value string) map[string]string {
	decoder := xml.NewDecoder(strings.NewReader(xmlText))
	for {
		tok, err := decoder.Token()
		if err != nil {
			panic(fmt.Sprintf("no <%s> element found in: %s", tag, xmlText))
		}
		start, ok := tok.(xml.StartElement)
		if !ok || start.Name.Local != tag {
			continue
		}
		var raw struct {
			Fields []struct {
				XMLName xml.Name
				Value   string `xml:",chardata"`
			} `xml:",any"`
		}
		check(decoder.DecodeElement(&raw, &start))
		fields := map[string]string{}
		for _, f := range raw.Fields {
			fields[f.XMLName.Local] = f.Value
		}
		if value == "" || fields[key] == value {
			return fields
		}
	}
}

// chooseTargetIQN picks the IQN from an iSCSI discovery probe's XML: the caller's, if named (it must
// be one the target offers), else the first. An array usually offers many targets - one per LUN,
// often belonging to different users - so on shared storage always name yours: SR.create formats
// the LUN behind it.
func chooseTargetIQN(xmlText, target, targetIQN string) string {
	var offered []string
	decoder := xml.NewDecoder(strings.NewReader(xmlText))
	for {
		tok, err := decoder.Token()
		if err != nil {
			break
		}
		if start, ok := tok.(xml.StartElement); ok && start.Name.Local == "TargetIQN" {
			var iqn string
			check(decoder.DecodeElement(&iqn, &start))
			offered = append(offered, strings.TrimSpace(iqn))
		}
	}
	if len(offered) == 0 {
		panic(fmt.Sprintf("target %s offered no IQNs: %s", target, xmlText))
	}
	if targetIQN == "" {
		return offered[0]
	}
	for _, iqn := range offered {
		if iqn == targetIQN {
			return iqn
		}
	}
	panic(fmt.Sprintf("target %s does not offer IQN %s", target, targetIQN))
}

// --- 48. Create an iSCSI SR -----------------------------------------------------------
// Connect an SR to a LUN on the iSCSI target, discovering the IQN and the LUN the way the New SR
// wizard and XenRT do: a device-config that's missing a piece makes the backend fail on purpose,
// and the failure carries an XML fragment listing what it needs next.
//
// SR.create formats the chosen LUN - this is destructive, so pick carefully on a real target: pass
// targetIQN to name yours (see chooseTargetIQN).
func createIscsiSr(url, user, password, target, port, chapUser, chapPassword, targetIQN, srName string) {
	const GiB = 1024 * 1024 * 1024
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	host := hosts[0]
	dc := map[string]string{"target": target}
	if port != "" {
		dc["port"] = port
	}
	if chapUser != "" {
		dc["chapuser"] = chapUser
		dc["chappassword"] = chapPassword
	}

	// First failing probe: target only -> the backend lists the IQNs it offers.
	dc["targetIQN"] = chooseTargetIQN(probeForFailure(session, host, dc, "lvmoiscsi"), target, targetIQN)
	fmt.Printf("Discovered IQN: %s\n", dc["targetIQN"])

	// Second failing probe: +targetIQN -> the backend lists the LUNs behind it. Real create also
	// carries LUNid, which XenRT's own LUN-preparation helper always includes when known; fall
	// back to the first LUN's list index (0) if the backend doesn't report one.
	lun := firstXMLElement(probeForFailure(session, host, dc, "lvmoiscsi"), "LUN")
	dc["SCSIid"] = lun["SCSIid"]
	if id := lun["LUNid"]; id != "" {
		dc["LUNid"] = id
	} else {
		dc["LUNid"] = "0"
	}
	fmt.Printf("Discovered LUN %s (SCSIid %s)\n", dc["LUNid"], dc["SCSIid"])

	sr, err := xenapi.SR.Create(session, host, dc, 0, srName,
		"iSCSI SR created by the SDK example", "lvmoiscsi", "user", true, map[string]string{})
	check(err)
	size, _ := xenapi.SR.GetPhysicalSize(session, sr)
	uuid, _ := xenapi.SR.GetUUID(session, sr)
	fmt.Printf("Created SR: %s (%d GiB)\n", uuid, size/GiB)
	detachAndForgetSR(session, sr)
	fmt.Println("OK: create-iscsi-sr")
	session.Logout()
}

// --- 49. Create an SMB SR -------------------------------------------------------------
// Connect a shared SR to an SMB/CIFS file share. The password travels as a Secret, not plaintext
// device-config - the way XenRT and XenCenter both do it, and the only form seen in real captured
// sr-create calls for this SR type.
func createSmbSr(url, user, password, server, share, smbUsername, smbPassword, srName string) {
	const GiB = 1024 * 1024 * 1024
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	host := hosts[0]

	secret, err := xenapi.Secret.Create(session, xenapi.SecretRecord{
		Value: smbPassword, OtherConfig: map[string]string{},
	})
	check(err)
	secretUUID, err := xenapi.Secret.GetUUID(session, secret)
	check(err)
	// server is the share as one UNC path, //server/share: the SMB driver has no separate serverpath.
	dc := map[string]string{
		"server": "//" + server + share, "username": smbUsername,
		"password_secret": secretUUID,
	}
	sr, err := xenapi.SR.Create(session, host, dc, 0, srName,
		"SMB SR created by the SDK example", "smb", "user", true, map[string]string{})
	check(err)
	size, _ := xenapi.SR.GetPhysicalSize(session, sr)
	uuid, _ := xenapi.SR.GetUUID(session, sr)
	fmt.Printf("Created SR: %s (%d GiB)\n", uuid, size/GiB)
	detachAndForgetSR(session, sr)
	check(xenapi.Secret.Destroy(session, secret))
	fmt.Println("OK: create-smb-sr")
	session.Logout()
}

// --- 50. Create an HBA SR -------------------------------------------------------------
// Connect a shared SR to a fibre-channel (HBA) LUN, discovering it the way the New SR wizard does:
// probing with no SCSIid fails on purpose and lists every LUN the backend can see. The failure's
// XML root element name and error code both vary by host/simulator build, so parse by tag name
// BlockDevice wherever it occurs.
//
// SR.create formats the chosen LUN - this is destructive, so pick carefully on a real target.
func createHbaSr(url, user, password, scsiID, srName string) {
	const GiB = 1024 * 1024 * 1024
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	host := hosts[0]

	// SR.create formats the LUN: on shared FC storage name yours (scsiID); with none, the first is taken.
	device := findXMLElement(probeForFailure(session, host, map[string]string{}, "lvmohba"), "BlockDevice",
		"SCSIid", scsiID)
	fmt.Printf("Discovered LUN: SCSIid %s on %s\n", device["SCSIid"], device["path"])

	// SCSIid is all lvmohba needs - it is what XenCenter's New SR wizard sends. (The probe's <path> is
	// for display: on a real host it reads like "/dev/sde [sdc] [sdg] [sdi]", one entry per path.)
	dc := map[string]string{"SCSIid": device["SCSIid"]}
	sr, err := xenapi.SR.Create(session, host, dc, 0, srName,
		"HBA SR created by the SDK example", "lvmohba", "user", true, map[string]string{})
	check(err)
	size, _ := xenapi.SR.GetPhysicalSize(session, sr)
	uuid, _ := xenapi.SR.GetUUID(session, sr)
	fmt.Printf("Created SR: %s (%d GiB)\n", uuid, size/GiB)
	detachAndForgetSR(session, sr)
	fmt.Println("OK: create-hba-sr")
	session.Logout()
}

// --- 51. Create an ISO library SR -----------------------------------------------------
// Connect an ISO-library SR to a file share of ISO images (here an NFS export, location
// "server:/path").
func createIsoSr(url, user, password, location string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	dc := map[string]string{"location": location, "type": "nfs_iso"}
	sr, err := xenapi.SR.Create(session, hosts[0], dc, 0, "sdk-example-iso",
		"ISO library created by the SDK example", "iso", "iso", true, map[string]string{})
	check(err)
	uuid, _ := xenapi.SR.GetUUID(session, sr)
	fmt.Printf("Created ISO SR: %s\n", uuid)
	detachAndForgetSR(session, sr)
	fmt.Println("OK: create-iso-sr")
	session.Logout()
}

// --- 52. Configure NRPE monitoring ----------------------------------------------------
// host.call_plugin is per-host - there is no pool-wide fan-out for plugin calls the way there is
// for pool.enable_ssh - so configure every host in the pool, and restore each one to disabled
// again afterwards.
func configureNrpe(url, user, password string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	for _, host := range hosts {
		nrpe := func(fn string, args map[string]string) string {
			r, e := xenapi.Host.CallPlugin(session, host, "nrpe", fn, args)
			check(e)
			return r
		}
		label, _ := xenapi.Host.GetNameLabel(session, host)
		fmt.Printf("%s: NRPE status before: %s\n", label, strings.TrimSpace(nrpe("status", map[string]string{})))
		nrpe("enable", map[string]string{})
		nrpe("set-config", map[string]string{"allowed_hosts": "127.0.0.1,::1,10.0.0.5", "debug": "0", "ssl_logging": "0x00"})
		nrpe("restart", map[string]string{})
		fmt.Printf("  status after:  %s\n", strings.TrimSpace(nrpe("status", map[string]string{})))
		for _, line := range strings.Split(nrpe("get-config", map[string]string{}), "\n") {
			if strings.HasPrefix(line, "allowed_hosts:") {
				fmt.Printf("  allowed hosts: %s\n", strings.TrimSpace(strings.SplitN(line, ":", 2)[1]))
			}
		}
		nrpe("disable", map[string]string{}) // restore: leave it as we found it
	}
	fmt.Println("OK: configure-nrpe")
	session.Logout()
}

// newUUID returns a random (version 4) UUID.
func newUUID() string {
	b := make([]byte, 16)
	_, err := rand.Read(b)
	check(err)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// --- 53. Configure SNMP monitoring ----------------------------------------------------
// nmss is the list of real trap destinations SNMP notifications go to - an empty list never
// configures where traps actually go, which is the whole point of "configure SNMP monitoring".
// Plugin calls are per-host, so configure every host, and restore each one to disabled again
// afterwards, the way XenRT's own SNMPServer.disable() does.
func configureSnmp(url, user, password, trapDestination string) {
	session := connect(url, user, password)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	config := `{"common":{"enabled":"yes","debug_log":"no"},` +
		`"agent":{"v2c":"yes","v3":"no","community":"sdk-community","user_name":"",` +
		`"authentication_password":"","authentication_protocol":"",` +
		// Each trap destination needs a uuid of its own: the plugin refuses the whole config without one.
		`"privacy_password":"","privacy_protocol":""},"nmss":[{"uuid":"` + newUUID() + `","address":"` + trapDestination + `",` +
		`"port":162,"v2c":"yes","v3":"no","community":"sdk-community","user_name":"",` +
		`"authentication_password":"","authentication_protocol":"",` +
		`"privacy_password":"","privacy_protocol":""}]}`
	for _, host := range hosts {
		snmp := func(fn string, args map[string]string) map[string]interface{} {
			r, e := xenapi.Host.CallPlugin(session, host, "snmp", fn, args)
			check(e)
			var env map[string]interface{}
			check(json.Unmarshal([]byte(r), &env))
			return env
		}
		// The plugin reports a refused config in its answer, not as an API error: check it.
		if answer := snmp("set-config", map[string]string{"config": config}); answer["code"] != float64(0) {
			panic(fmt.Sprintf("set-config refused the configuration: %v", answer["message"]))
		}
		status := snmp("status", map[string]string{})["result"].(map[string]interface{})
		cfg := snmp("get-config", map[string]string{})["result"].(map[string]interface{})
		agent := cfg["agent"].(map[string]interface{})
		nmss, _ := cfg["nmss"].([]interface{})
		label, _ := xenapi.Host.GetNameLabel(session, host)
		fmt.Printf("%s: SNMP enabled: %v / %v\n", label, status["enabled"], status["active"])
		trap := "(none)"
		if len(nmss) > 0 {
			if first, ok := nmss[0].(map[string]interface{}); ok {
				trap = fmt.Sprintf("%v", first["address"])
			}
		}
		fmt.Printf("  community: %v, trap destination: %s\n", agent["community"], trap)
		snmp("set-config", map[string]string{"config": `{"common":{"enabled":"no"}}`}) // restore
	}
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

	// Shutdown tries each VM's clean shutdown and falls back to a hard one. CleanShutdown alone fails
	// OPERATION_PARTIALLY_FAILED if any member can't shut down cleanly (no guest OS or PV drivers).
	check(xenapi.VMAppliance.Shutdown(session, vapp))
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

	// VUSB.Destroy refuses a VUSB that is still attached (OPERATION_NOT_ALLOWED) - on a running VM
	// it gets plugged in as soon as it's created, so unplug it first.
	vusbRecord, err := xenapi.VUSB.GetRecord(session, vusb)
	check(err)
	if vusbRecord.CurrentlyAttached {
		check(xenapi.VUSB.Unplug(session, vusb))
	}
	check(xenapi.VUSB.Destroy(session, vusb))
	check(xenapi.PUSB.SetPassthroughEnabled(session, pusbRef, false))
	fmt.Println("OK: attach-usb-device")
	session.Logout()
}

// --- Read workload-balancing recommendations ----------------------------------------------
// wlbRecommendations needs a real, reachable WLB appliance: pool.InitializeWlb makes a synchronous
// HTTP call to it and raises WLB_CONNECTION_REFUSED/WLB_CONNECTION_RESET if it can't connect -
// there is no way to fake this with a placeholder. wlbHostPort is host:port, with no URL scheme -
// that is the real wire format (xe pool-initialize-wlb wlb_url="10.x.x.x:30601" ...), not a URL.
//
// The pool checks the appliance's TLS certificate (pool.wlb_verify_cert), and only against the
// certificates installed with Pool.CertificateInstall - not install_trusted_certificate's. A fresh
// appliance has a self-signed one, so pass it as wlbCertificate (a PEM file): without it
// InitializeWlb fails with INTERNAL_ERROR "Connection failed: configuration failed." and no hint
// that the certificate is the reason.
func wlbRecommendations(url, user, password, vmName, wlbHostPort, wlbUsername, wlbPassword, wlbCertificate string) {
	session := connect(url, user, password)
	// Deferred first, so it runs LAST: after the deferred WLB tidy-up below, which needs the session.
	defer session.Logout()

	certName := ""
	if wlbCertificate != "" {
		certName = "sdk-example-wlb.pem"
		cert, err := os.ReadFile(wlbCertificate)
		check(err)
		check(xenapi.Pool.CertificateInstall(session, certName, string(cert))) // pool-wide: no pool argument
	}
	check(xenapi.Pool.InitializeWlb(session, wlbHostPort, wlbUsername, wlbPassword, user, password))
	defer func() {
		// Disconnect from the appliance however the above went, or the pool stays attached to it.
		check(xenapi.Pool.DeconfigureWlb(session))
		if certName != "" {
			check(xenapi.Pool.CertificateUninstall(session, certName))
		}
	}()

	// Initializing connects the pool to the appliance but leaves balancing off: every WLB call after
	// this would fail WLB_DISABLED until it's switched on.
	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	check(xenapi.Pool.SetWlbEnabled(session, pools[0], true))
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

	// A VM's own are keyed by host and star-rate each destination: [0] "wlb", [1] the rating - higher
	// is better (a real appliance rated hosts 6.1 here, so not capped at XenCenter's five stars).
	// Right after connecting, the appliance is still discovering the pool and answers
	// WLB_INTERNAL_ERROR 4024 ("Pool discovery has not been started"), 4025 ("... has not been
	// completed"), then 4016 ("WLB does not have current metrics") - keep asking for a while.
	vms, err := xenapi.VM.GetByNameLabel(session, vmName)
	check(err)
	deadline := time.Now().Add(10 * time.Minute)
	var vmRecs map[xenapi.HostRef][]string
	for {
		vmRecs, err = xenapi.VM.RetrieveWlbRecommendations(session, vms[0])
		if err == nil || !isWlbStillDiscovering(err) || time.Now().After(deadline) {
			check(err)
			break
		}
		time.Sleep(15 * time.Second)
	}
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

	fmt.Println("OK: wlb-recommendations")
}

// isWlbStillDiscovering reports whether err is a WLB_INTERNAL_ERROR whose WLB code is 4024, 4025 or
// 4016 - the appliance is still discovering the pool, or has no metrics for it yet. See
// coordinatorFromSlaveError for why the data slice has to be parsed out of the formatted error string.
func isWlbStillDiscovering(err error) bool {
	msg := err.Error()
	if !strings.Contains(msg, xenapi.ErrorWlbInternalError) {
		return false
	}
	m := regexp.MustCompile(`data \[(.+)\]`).FindStringSubmatch(msg)
	if m == nil {
		return false
	}
	fields := strings.Fields(m[1])
	// The binding prints the code in the message and only its parameters in data: [4024 Pool ...].
	return len(fields) > 0 && (fields[0] == "4024" || fields[0] == "4025" || fields[0] == "4016")
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
// managePoolMembership lists the pool's hosts, promotes a different coordinator, then promotes
// the original back. designate_new_master runs a two-phase commit across every host and ends by
// restarting xapi pool-wide (the new coordinator becomes master, every other host becomes its
// slave) - so the session this call was made on, and the connection itself, do not survive it.
// Reconnect (with a bounded wait) before touching the pool again, rather than assuming the session
// is still good, and re-resolve pool/host refs from the fresh session each time.
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
	otherName, _ := xenapi.Host.GetNameLabel(session, other)
	otherUUID, _ := xenapi.Host.GetUUID(session, other)
	originalUUID, _ := xenapi.Host.GetUUID(session, original)

	// Promote another member. The pool database moves with the role and clients are redirected, so this
	// briefly interrupts management traffic — it does not move any VM.
	check(xenapi.Pool.DesignateNewMaster(session, other))
	fmt.Printf("Promoting:   %s (xapi restarts pool-wide; reconnecting)\n", otherName)

	session = reconnectAfterMasterChange(url, user, password, otherUUID)
	pools, err = xenapi.Pool.GetAll(session)
	check(err)
	master, _ := xenapi.Pool.GetMaster(session, pools[0])
	masterName, _ := xenapi.Host.GetNameLabel(session, master)
	fmt.Printf("Promoted:    %s\n", masterName)

	// Put it back. Ejecting a member (Pool.Eject) is the other half of this surface and is deliberately
	// not shown: it cannot be undone from the pool, because rejoining is initiated by the ejected host.
	check(xenapi.Pool.DesignateNewMaster(session, original))
	fmt.Printf("Restoring:   %s (reconnecting again)\n", name)

	session = reconnectAfterMasterChange(url, user, password, originalUUID)
	pools, err = xenapi.Pool.GetAll(session)
	check(err)
	master, _ = xenapi.Pool.GetMaster(session, pools[0])
	masterName, _ = xenapi.Host.GetNameLabel(session, master)
	fmt.Printf("Restored:    %s\n", masterName)

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
	if len(spares) < 2 {
		name, _ := xenapi.Host.GetNameLabel(session, hosts[0])
		panic(fmt.Sprintf("%s has %d spare NIC(s); a bond needs two that aren't the management interface",
			name, len(spares)))
	}
	fmt.Printf("Bonding:      %s\n", strings.Join(devices, ", "))

	// The bond needs a network to sit on.
	network, err := xenapi.Network.Create(session, xenapi.NetworkRecord{
		NameLabel:       "sdk-example-bond",
		NameDescription: "Created by the SDK example",
		Managed:         true, // as in createNetwork: the zero value would be NETWORK_UNMANAGED
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
func configurePvsAccelerator(url, user, password, vmName string) {
	session := connect(url, user, password)
	defer session.Logout()

	// Check the VM first, before creating anything: it needs a NIC for the proxy to sit on. It need
	// not be running - a proxy on a halted VM just reports "stopped" until it starts.
	vm := vmByName(session, vmName)
	vifs, err := xenapi.VM.GetVIFs(session, vm)
	check(err)
	if len(vifs) == 0 {
		panic(fmt.Sprintf("%s has no network interface to accelerate", vmName))
	}
	// A proxy may only sit on the VM's LOWEST-numbered NIC, so sort by device rather than taking
	// VIFs[0] — the list comes back in creation order, which is the same thing only by luck.
	sort.Slice(vifs, func(i, j int) bool { return vifDevice(session, vifs[i]) < vifDevice(session, vifs[j]) })
	// ... and one that no site accelerates yet (a VIF takes one proxy: PVS_PROXY_ALREADY_PRESENT).
	proxies, err := xenapi.PVSProxy.GetAllRecords(session)
	check(err)
	for _, proxy := range proxies {
		if proxy.VIF == vifs[0] {
			siteName, _ := xenapi.PVSSite.GetNameLabel(session, proxy.Site)
			panic(fmt.Sprintf("%s is already accelerated by site '%s'", vmName, siteName))
		}
	}

	site, err := xenapi.PVSSite.Introduce(session, "sdk-example-pvs", "Created by the SDK examples", "")
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

	// A proxy may only sit on the VM's LOWEST-numbered NIC, hence sorting by device above rather than
	// taking VIFs[0] — the list comes back in creation order, which is the same thing only by luck.
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
	vmLabel, _ := xenapi.VM.GetNameLabel(session, vm)
	fmt.Printf("  %s: %s\n", vmLabel, status)

	// Forgetting the site only cascades its cache storage - a running proxy or a server it still
	// has makes forget refuse with PVS_SITE_CONTAINS_RUNNING_PROXIES/_SERVERS, so tear those down
	// ourselves first, in the same order every real PVS teardown uses. (Cache storage doesn't need
	// a separate call - forget cascades it correctly.)
	check(xenapi.PVSProxy.Destroy(session, proxy))
	servers, err := xenapi.PVSSite.GetServers(session, site)
	check(err)
	for _, server := range servers {
		check(xenapi.PVSServer.Forget(session, server))
	}
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

// --- Manage SSH access ---
func manageSSHAccess(url, user, password string) {
	session := connect(url, user, password)
	defer session.Logout()

	pools, err := xenapi.Pool.GetAll(session)
	check(err)
	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	// Each host's SSH as we found it, to put back at the end: disabling it is not the example's to keep.
	before, err := xenapi.Host.GetAllRecords(session)
	check(err)

	// Timed access is the point: set the timeout first and the server stamps an expiry when SSH is
	// enabled, so a window opened for troubleshooting closes itself. This is itself a pool-wide
	// fan-out call, exactly like EnableSSH/DisableSSH - no need to loop hosts for it either.
	check(xenapi.Pool.SetSSHEnabledTimeout(session, pools[0], 3600))

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

	for host, record := range before {
		// first: enabling stamps the expiry from it
		check(xenapi.Host.SetSSHEnabledTimeout(session, host, record.SSHEnabledTimeout))
		if record.SSHEnabled {
			check(xenapi.Host.EnableSSH(session, host))
		}
	}
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

	// CBT is switched on for the VM's own disk, and every snapshot taken from then on inherits it. It
	// can't be switched on for a snapshot's disk after the fact (OPERATION_NOT_ALLOWED).
	live := firstDisk(session, vm)
	wasEnabled, err := xenapi.VDI.GetCbtEnabled(session, live)
	check(err)
	if !wasEnabled {
		check(xenapi.VDI.EnableCbt(session, live))
	}

	first, err := xenapi.VM.Snapshot(session, vm, "cbt-backup-1", nil)
	check(err)
	second, err := xenapi.VM.Snapshot(session, vm, "cbt-backup-2", nil)
	check(err)
	vdiFrom, vdiTo := firstDisk(session, first), firstDisk(session, second)

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
	// still diff against it. DataDestroy refuses a disk that a VM still uses (VDI_IN_USE), so drop the
	// older snapshot's VM record first, as a backup tool does. The VDI record stays; its type changes.
	check(xenapi.VM.Destroy(session, first))
	check(xenapi.VDI.DataDestroy(session, vdiFrom))
	vdiType, err := xenapi.VDI.GetType(session, vdiFrom)
	check(err)
	stillTracked, err := xenapi.VDI.GetCbtEnabled(session, vdiFrom)
	check(err)
	fmt.Printf("  older snapshot is now type=%s, still cbt_enabled=%t\n", vdiType, stillTracked)

	// Tidy up: the newer snapshot and its disk, the metadata-only VDI, and CBT on the VM's own disk if
	// this example switched it on.
	destroyVMAndDisks(session, second)
	check(xenapi.VDI.Destroy(session, vdiFrom))
	if !wasEnabled {
		check(xenapi.VDI.DisableCbt(session, live))
	}
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
func exportImportVm(url, user, password, vmName string) {
	session := connect(url, user, password)
	defer session.Logout()

	// Name the VM: an export carries every block of its disks, so which VM matters (a large one takes a
	// long time, and fills the disk). Only a halted VM can be exported: its disks must not be changing
	// underneath the copy.
	vm := vmByName(session, vmName)
	powerState, err := xenapi.VM.GetPowerState(session, vm)
	check(err)
	if powerState != xenapi.VMPowerStateHalted {
		panic(fmt.Sprintf("%s must be halted to be exported", vmName))
	}
	fmt.Printf("Exporting %s\n", vmName)

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
	// Always clean up the file, on failure too: a real export is gigabytes, not worth leaving behind.
	defer os.Remove(path)

	// Stream both directions: a real VM's export is gigabytes, too large to hold in memory.
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

	// The imported VM's ref is NOT in the /import response body on a real host (only this
	// simulator's convenience echoes it there) - the only place it appears is the task named in the
	// task_id query parameter, so create one, pass it, and read task.get_result() once the upload
	// finishes (the same <value>...</value> string-strip wait-for-task already uses).
	task, err := xenapi.Task.Create(session, "vm_import", "importing "+vmName+" back")
	check(err)
	defer xenapi.Task.Destroy(session, task)

	archive, err := os.Open(path)
	check(err)
	request, err := http.NewRequest(http.MethodPut,
		fmt.Sprintf("%s/import?session_id=%s&task_id=%s", url, sid, task), archive)
	check(err)
	info, err := archive.Stat()
	check(err)
	request.ContentLength = info.Size()
	putResp, err := insecureClient().Do(request)
	check(err)
	io.Copy(io.Discard, putResp.Body)
	putResp.Body.Close()
	archive.Close()

	for {
		status, err := xenapi.Task.GetStatus(session, task)
		check(err)
		if status != xenapi.TaskStatusTypePending {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if status, _ := xenapi.Task.GetStatus(session, task); status != xenapi.TaskStatusTypeSuccess {
		errInfo, _ := xenapi.Task.GetErrorInfo(session, task)
		panic(fmt.Sprintf("import failed: %v", errInfo))
	}
	result, err := xenapi.Task.GetResult(session, task)
	check(err)
	// The result lists the imported VMs (<value><array><data>OpaqueRef:...</data></array></value>
	// on a real host), so take the first reference in it.
	imported := xenapi.VMRef(regexp.MustCompile(`OpaqueRef:[^<]+`).FindString(result))
	name, err := xenapi.VM.GetNameLabel(session, imported)
	check(err)
	fmt.Printf("  imported as %s\n", name)

	// The import brought its own disks along; destroy those too, not just the VM record.
	destroyVMAndDisks(session, imported)
	fmt.Println("OK: export-import-vm")
}

// Run it:
//   exportImportVm("https://xenserver", "root", password, "db-01")

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

func gib(size int64) string {
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
// Both /host_backup and /host_restore are served only by whichever host physically accepted the
// HTTP connection - the handler ignores any ref= in the query string entirely, there is no
// forwarding to another pool member. So backing up/restoring a host means opening the connection
// to THAT host's own address, not to the pool's (coordinator) url - a restore sent to the wrong
// host's connection silently restores the WRONG host, not the one named by ref=. ref= is kept in
// the query string purely for log-readability (a real host ignores it).
//
// Both halves are hundreds of MB on a real host, so they stream to/from a temp file rather than
// holding the backup in memory. A transfer takes long enough on a slow link for the network to drop
// an API connection left idle meanwhile, and the next call would then hang on it until the socket
// timed out - so this session sends "Connection: close", giving every API call its own connection.
func backupHostConfig(url, user, password string) {
	session := xenapi.NewSession(&xenapi.ClientOpts{URL: url, Headers: map[string]string{"Connection": "close"}})
	_, err := session.LoginWithPassword(user, password, "1.0", "sdk-examples")
	check(err)
	defer session.Logout()

	hosts, err := xenapi.Host.GetAll(session)
	check(err)
	host := hosts[0]
	name, err := xenapi.Host.GetNameLabel(session, host)
	check(err)
	address, err := xenapi.Host.GetAddress(session, host)
	check(err)
	hostAddr := hostURL(url, address)
	fmt.Printf("Backing up %s\n", name)

	// Backup and restore are HTTP transfers alongside the API, not API calls, so the session id travels
	// in the query string. The Go binding keeps its own session private, so obtain one of our own.
	sid := rawLogin(url, user, password)
	temp, err := os.CreateTemp("", "sdk-example-host-*.backup")
	check(err)
	path := temp.Name()

	resp, err := insecureClient().Get(
		fmt.Sprintf("%s/host_backup?session_id=%s&ref=%s", hostAddr, sid, host))
	check(err)
	// Hundreds of MB on a real host: stream it to disk, don't hold it in memory.
	_, err = io.Copy(temp, resp.Body)
	check(err)
	resp.Body.Close()
	check(temp.Close())
	info, err := os.Stat(path)
	check(err)
	fmt.Printf("  wrote %d bytes to %s\n", info.Size(), filepath.Base(path))

	fmt.Printf("  restoring it to %s: %s\n", name, restoreHostConfig(session, hostAddr, sid, host, path))
	if len(hosts) > 1 {
		other := hosts[1]
		otherName, err := xenapi.Host.GetNameLabel(session, other)
		check(err)
		otherAddress, err := xenapi.Host.GetAddress(session, other)
		check(err)
		otherURL := hostURL(url, otherAddress)
		// The refusal is the half worth rehearsing: restoring one host's configuration onto another is
		// destructive and unrecoverable, so the pool checks rather than trusting the caller. Guard
		// against a transport error with a friendly message instead of letting the whole example
		// fail - a real pool's hosts are all reachable from a management client, so this only
		// matters in topologies (like this simulator fixture) where a second host's address isn't
		// actually routable from the caller.
		fmt.Printf("  restoring it to %s: %s\n", otherName,
			safeRestoreHostConfig(session, otherURL, sid, other, path))
	}

	check(os.Remove(path))
	fmt.Println("OK: backup-host-config")
}

// safeRestoreHostConfig calls restoreHostConfig but turns any transport error into a friendly
// message instead of letting the whole example fail.
func safeRestoreHostConfig(session *xenapi.Session, hostURL, sid string, host xenapi.HostRef, path string) (result string) {
	defer func() {
		if r := recover(); r != nil {
			result = fmt.Sprintf("could not connect to %s directly (%v)", hostURL, r)
		}
	}()
	return restoreHostConfig(session, hostURL, sid, host, path)
}

// restoreHostConfig uploads a backup to a host - over a connection opened to THAT host's own
// address - and reports what the task says about it.
//
// An upload answers 200 as soon as it has read the request headers, because the client waits for that
// before it starts sending the file. The outcome therefore cannot be in the status line: it arrives on a
// task you create first, name in the URL, and poll once the upload has finished.
func restoreHostConfig(session *xenapi.Session, url, sid string, host xenapi.HostRef, path string) string {
	task, err := xenapi.Task.Create(session, "host_restore", "restoring a configuration backup")
	check(err)
	defer xenapi.Task.Destroy(session, task)

	file, err := os.Open(path)
	check(err)
	defer file.Close()
	info, err := os.Stat(path)
	check(err)

	// Stream the file as the request body rather than reading it into memory first: a real host's
	// backup is hundreds of MB. http.NewRequest can't infer the length of an arbitrary io.Reader, so
	// set ContentLength explicitly - without it Go would send chunked Transfer-Encoding, which isn't
	// what a real host's /host_restore handler expects.
	request, err := http.NewRequest(http.MethodPut,
		fmt.Sprintf("%s/host_restore?session_id=%s&ref=%s&task_id=%s", url, sid, host, task),
		file)
	check(err)
	request.ContentLength = info.Size()
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
	var keys, defaults []string
	for _, capability := range catalogue.Capabilities {
		keys = append(keys, capability.Key)
		if capability.DefaultChecked == "yes" {
			defaults = append(defaults, capability.Key)
		}
		fmt.Printf("  %-22s max %9s bytes  default=%-3s pii=%s\n",
			capability.Key, capability.MaxSize, capability.DefaultChecked, capability.Pii)
	}

	// The download is an HTTP transfer alongside the API, so the session id travels in the query string.
	// The Go binding keeps its own session private, so obtain one of our own.
	sid := rawLogin(url, user, password)
	// Take the sections the host marks default-checked, as XenCenter's dialog does: asking for every
	// section can mean gigabytes (VM memory dumps, every log) and a long wait while the host builds it.
	whole := fetchStatusReport(url, sid, defaults)
	fmt.Printf("default sections (%d of %d): %d bytes\n", len(defaults), len(keys), whole)

	// Pick a real, small section from the host's own catalogue rather than assuming a name: the
	// catalogue is server-defined (xen-bugtool's own --capabilities output), not a fixed client
	// list, and "xenserver-config" isn't one of the real keys any host actually publishes.
	subsetKey := keys[0]
	for _, k := range keys {
		if k == "firstboot" || k == "network-status" {
			subsetKey = k
			break
		}
	}
	subset := fetchStatusReport(url, sid, []string{subsetKey})
	fmt.Printf("%s only:   %d bytes\n", subsetKey, subset)
	if subset >= whole {
		fmt.Println("  ERROR: selecting fewer sections did not produce a smaller bundle")
	}

	fmt.Println("OK: server-status-report")
}

// fetchStatusReport downloads the bundle for the given capability keys (a tar archive) to a temp file,
// streaming it - a report can be large - and returns its size. This example then deletes it; you'd keep it.
func fetchStatusReport(url, sid string, entries []string) int {
	resp, err := insecureClient().Get(fmt.Sprintf("%s/system-status?session_id=%s&output=tar&entries=%s",
		url, sid, strings.Join(entries, ",")))
	check(err)
	defer resp.Body.Close()

	temp, err := os.CreateTemp("", "sdk-example-status-*.tar")
	check(err)
	path := temp.Name()
	defer os.Remove(path)

	written, err := io.Copy(temp, resp.Body)
	check(err)
	temp.Close()
	return int(written)
}

// Run it:
//   serverStatusReport("https://xenserver", "root", password)

// --- Recover VMs after a disaster ---
// Disaster recovery works by writing the pool's own database out to a storage repository as a disk
// of type "metadata". That disk can be read back as a SEPARATE database, so the ordinary calls
// describe the pool as it was replicated rather than the pool you are connected to. Recovering
// reads from that database and writes into a live pool, which is why the recover call is made on
// the metadata session and takes a live session as its destination.
//
// That destination has to be a DIFFERENT, standby pool: recovering a VM back into the exact pool
// it was replicated from can't actually succeed with force=false - the VM's uuid already exists
// there, so VM.recover always takes the replace-or-fail path, and nothing replicated a moment ago
// from a live database can ever be "newer" than the live object it came from
// (VM_TO_IMPORT_IS_NOT_NEWER_VERSION). The one-line "fix" of passing force=true instead would make
// it succeed by REPLACING (destroying and recreating) the live original - exactly the opposite of
// what a DR demo should show, and the thing that would actually destroy a live VM if ever pointed
// at the same pool it replicated from. A second pool is the only way force=false succeeds, and
// what every real DR workflow actually does. Track the recovered VM by uuid, never by name: a
// name can coincidentally collide with something already on the destination pool.
func disasterRecovery(url, user, password, drURL string) {
	if drURL == "" {
		panic("disaster-recovery needs a second pool to recover into: pass dr_url=<url of a standby pool>")
	}
	session := connect(url, user, password)
	defer session.Logout()
	drSession := connect(drURL, user, password)
	defer drSession.Logout()

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
	// not create, so the metadata database has to be driven over plain JSON-RPC. Same reason the
	// destination pool's session id is obtained separately: recover() needs one to say where the VM
	// should land.
	drSessionID := rawLogin(drURL, user, password)
	var recoverable map[string]struct {
		UUID            string `json:"uuid"`
		NameLabel       string `json:"name_label"`
		IsATemplate     bool   `json:"is_a_template"`
		IsControlDomain bool   `json:"is_control_domain"`
		IsASnapshot     bool   `json:"is_a_snapshot"`
	}
	check(json.Unmarshal(rawRPC(url, "VM.get_all_records", string(metadataSession)), &recoverable))

	// Only real guest VMs are recoverable - exclude templates, control domains and snapshots.
	targets := make([]string, 0, len(recoverable))
	for ref, r := range recoverable {
		if !r.IsATemplate && !r.IsControlDomain && !r.IsASnapshot {
			targets = append(targets, ref)
		}
	}
	fmt.Printf("  the replicated database describes %d recoverable VM(s)\n", len(targets))

	sort.Slice(targets, func(i, j int) bool {
		return recoverable[targets[i]].NameLabel < recoverable[targets[j]].NameLabel
	})
	target := targets[0]
	targetUUID := recoverable[target].UUID
	name := recoverable[target].NameLabel
	fmt.Printf("  recovering %s\n", name)

	// Both calls run on the METADATA session; session_to says where the VM should land - the
	// STANDBY pool's session, not this one. Never force=true: see the doc comment above.
	rawRPC(url, "VM.assert_can_be_recovered", string(metadataSession), target, drSessionID)
	rawRPC(url, "VM.recover", string(metadataSession), target, drSessionID, false)

	// It is a real VM on the standby pool now, not merely a call that returned - look it up by the
	// uuid full_restore preserved, never by name.
	recovered, err := xenapi.VM.GetByUUID(drSession, targetUUID)
	check(err)
	ps, _ := xenapi.VM.GetPowerState(drSession, recovered)
	fmt.Printf("  %s is %s on the standby pool\n", name, ps)

	// Tidy up on the standby pool only, by uuid - never touch the source pool's VMs, and never guess
	// by name (a coincidentally-same-named VM must not be destroyed).
	destroyVMAndDisks(drSession, recovered)

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
	// actions on, so it is the field to watch. This is a deliberately-provisioned state, not one a
	// normally-provisioned Secure Boot guest is ever in - report and stop cleanly when no VM needs
	// it, rather than failing with a bare lookup error.
	vms, err := xenapi.VM.GetAllRecords(session)
	check(err)
	var vm xenapi.VMRef
	var name string
	found := false
	for ref, r := range vms {
		if !r.IsATemplate && !r.IsControlDomain && !r.IsASnapshot &&
			r.SecurebootCertificatesState == xenapi.VMSecurebootCertificatesStateUpdateAvailable {
			vm, name, found = ref, r.NameLabel, true
			break
		}
	}
	if !found {
		fmt.Println("No guest needs a Secure Boot certificate refresh right now.")
		fmt.Println("OK: manage-secureboot-certificates")
		return
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
	check(xenapi.Host.Evacuate2(session, host))
	fmt.Printf("  evacuated:  guests=%d\n", guestCount(session, host))

	check(xenapi.Host.Reboot(session, host))
	// A real reboot takes minutes. Wait for the host to drop out and come back (live in its
	// host_metrics), then enable it. A host disabled the default way (auto_enable=true) re-enables
	// itself once its toolstack is up again, but only then - and one disabled with auto_enable=false
	// never does - so enable it explicitly rather than depend on either.
	waitForHostLiveTimeout(session, host, false, 600*time.Second, 2*time.Second)
	waitForHostLiveTimeout(session, host, true, 1200*time.Second, 10*time.Second)
	enableWhenBooted(session, host)
	enabled, _ = xenapi.Host.GetEnabled(session, host)
	fmt.Printf("  rebooted, re-enabled: enabled=%t\n", enabled)

	// The other ending: off, and back on out of band - but only demonstrated if that is actually
	// configured (host.power_on has no fallback and simply fails if no mechanism is configured or
	// working), and waiting for each transition before starting the next.
	mode, _ := xenapi.Host.GetPowerOnMode(session, host)
	if mode != "" {
		check(xenapi.Host.Disable(session, host, false))
		check(xenapi.Host.Shutdown(session, host))
		waitForHostLive(session, host, false)
		fmt.Printf("  shut down:  live=%t\n", hostLive(session, host))
		check(xenapi.Host.PowerOn(session, host))
		waitForHostLiveTimeout(session, host, true, 1200*time.Second, 10*time.Second)
		fmt.Printf("  powered on: live=%t\n", hostLive(session, host))
		enableWhenBooted(session, host)
		enabled, _ = xenapi.Host.GetEnabled(session, host)
		fmt.Printf("  re-enabled: enabled=%t\n", enabled)
	} else {
		fmt.Println("  skipping shutdown/power-on: no out-of-band power-on mode is configured on this host")
	}

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

	// A snapshot is a VM record with is_a_snapshot (and is_a_template) set, and cloning it gives a custom
	// template that stands on its own while the snapshot stays put.
	vm := vmByName(session, vmName)
	snapshot, err := xenapi.VM.Snapshot(session, vm, "sdk-example-source-snapshot", nil)
	check(err)
	fmt.Printf("Snapshot of %s taken\n", vmName)

	// A clone of a snapshot is a template, not another snapshot: it stands on its own instead of being
	// filed under the original VM. Provision it to get an ordinary VM you can start.
	newVM, err := xenapi.VM.Clone(session, snapshot, "sdk-example-vm-from-snapshot")
	check(err)
	provision(session, newVM)
	newName, _ := xenapi.VM.GetNameLabel(session, newVM)
	newIsTmpl, _ := xenapi.VM.GetIsATemplate(session, newVM)
	fmt.Printf("  new VM:      %s (is_a_template=%t)\n", newName, newIsTmpl)

	// Another clone, left as the template it already is: a starting point to stamp more VMs from.
	template, err := xenapi.VM.Clone(session, snapshot, "sdk-example-template-from-snapshot")
	check(err)
	tmplName, _ := xenapi.VM.GetNameLabel(session, template)
	isTmpl, _ := xenapi.VM.GetIsATemplate(session, template)
	fmt.Printf("  new template:%s (is_a_template=%t)\n", tmplName, isTmpl)

	// Each clone made its own disks, and the snapshot has its own snapshot disks; destroy them all.
	for _, ref := range []xenapi.VMRef{newVM, template, snapshot} {
		destroyVMAndDisks(session, ref)
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
		Bootable: false,
		Mode:     xenapi.VbdModeRW, Type: xenapi.VbdTypeDisk, Empty: false,
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
	var total int64
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

func mib(size int64) string { return fmt.Sprintf("%d MiB", size/(1024*1024)) }

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

	// set_iscsi_iqn refuses an empty string (INVALID_VALUE) - only restore it if this host actually
	// had one set before; a host that has never had an IQN configured can't be "restored" to empty.
	if beforeIqn != "" {
		check(xenapi.Host.SetIscsiIqn(session, host, beforeIqn))
	}
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
	// Host_driver.select refuses a variant whose hardware isn't present (HOST_DRIVER_NO_HARDWARE) -
	// and a host lists drivers for plenty of devices it doesn't have - so pick a driver for hardware
	// this host actually has, and one of its variants that is usable.
	var chosenDriver xenapi.HostDriverRef
	var chosenVariant xenapi.DriverVariantRef
	found := false
	for _, ref := range refs {
		for _, v := range drivers[ref].Variants {
			if present, _ := xenapi.DriverVariant.GetHardwarePresent(session, v); present {
				chosenDriver, chosenVariant, found = ref, v, true
				break
			}
		}
		if found {
			break
		}
	}
	if !found {
		panic(fmt.Sprintf("no driver on %s has a variant for hardware it has", hostName))
	}
	check(xenapi.HostDriver.Select(session, chosenDriver, chosenVariant))
	after, err := xenapi.HostDriver.GetRecord(session, chosenDriver)
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
		Error  *struct {
			Message string   `json:"message"`
			Data    []string `json:"data"`
		} `json:"error"`
	}
	check(json.NewDecoder(resp.Body).Decode(&r))
	if r.Error != nil {
		// A pool member names the coordinator's address; log in there instead, as connect does.
		if r.Error.Message == xenapi.ErrorHostIsSlave && len(r.Error.Data) > 0 {
			return rawLogin("https://"+r.Error.Data[0], user, password)
		}
		panic(fmt.Sprintf("login failed: %s %v", r.Error.Message, r.Error.Data))
	}
	return r.Result
}

// workflow pairs a workflow's dispatcher defaults (chosen to work against the simulator) with the
// function that resolves a merged parameter set into a call - the Go equivalent of Python's
// `_wf(fn, **defaults)` wrapper.
type workflow struct {
	defaults map[string]string
	run      func(url, user, password string, params map[string]string)
}

// wf builds a workflow entry: defaults, merged with CLI-supplied overrides (see main), are handed
// to fn as one resolved parameter map.
func wf(defaults map[string]string, fn func(url, user, password string, params map[string]string)) workflow {
	return workflow{defaults: defaults, run: fn}
}

var workflows = map[string]workflow{
	"connect-inventory": wf(nil, func(u, n, p string, m map[string]string) { connectInventory(u, n, p) }),
	"create-vm": wf(map[string]string{"template_name": "Rocky Linux 8", "new_vm_name": "sdk-example-vm"},
		func(u, n, p string, m map[string]string) { createVM(u, n, p, m["template_name"], m["new_vm_name"]) }),
	"vm-lifecycle": wf(map[string]string{"source_vm": "web-01", "new_vm_name": "sdk-example-lifecycle"},
		func(u, n, p string, m map[string]string) { vmLifecycle(u, n, p, m["source_vm"], m["new_vm_name"]) }),
	"manage-vm-disks": wf(map[string]string{
		"source_vm": "web-01", "sr_name": "Shared NFS", "new_vm_name": "sdk-example-vm-disks",
	}, func(u, n, p string, m map[string]string) {
		manageVMDisks(u, n, p, m["source_vm"], m["sr_name"], m["new_vm_name"])
	}),
	"dismiss-alerts":       wf(nil, func(u, n, p string, m map[string]string) { dismissAlerts(u, n, p) }),
	"host-power-on":        wf(nil, func(u, n, p string, m map[string]string) { hostPowerOn(u, n, p) }),
	"rotate-pool-secret":   wf(nil, func(u, n, p string, m map[string]string) { rotatePoolSecret(u, n, p) }),
	"change-root-password": wf(nil, func(u, n, p string, m map[string]string) { changeRootPassword(u, n, p) }),
	"manage-certificates":  wf(nil, func(u, n, p string, m map[string]string) { manageCertificates(u, n, p) }),
	"snapshot-schedule": wf(map[string]string{"vm_name": "web-01", "schedule_name": "sdk-example-schedule"},
		func(u, n, p string, m map[string]string) { snapshotSchedule(u, n, p, m["vm_name"], m["schedule_name"]) }),
	"manage-vm-groups": wf(map[string]string{"vm_name": "web-01", "group_name": "sdk-example-group"},
		func(u, n, p string, m map[string]string) { manageVMGroups(u, n, p, m["vm_name"], m["group_name"]) }),
	"snapshot-revert": wf(map[string]string{"vm_name": "web-01", "snapshot_name": "sdk-example-snapshot"},
		func(u, n, p string, m map[string]string) { snapshotRevert(u, n, p, m["vm_name"], m["snapshot_name"]) }),
	"create-nfs-sr": wf(map[string]string{
		"nfs_server": "192.0.2.10", "nfs_path": "/export/sdk", "sr_name": "sdk-example-nfs",
	}, func(u, n, p string, m map[string]string) {
		createNfsSR(u, n, p, m["nfs_server"], m["nfs_path"], m["sr_name"])
	}),
	"create-network": wf(map[string]string{"network_name": "sdk-example-net"},
		func(u, n, p string, m map[string]string) { createNetwork(u, n, p, m["network_name"]) }),
	"edit-vm-properties": wf(map[string]string{"vm_name": "web-01"},
		func(u, n, p string, m map[string]string) { editVMProperties(u, n, p, m["vm_name"]) }),
	"events": wf(map[string]string{"vm_name": "web-01"},
		func(u, n, p string, m map[string]string) { events(u, n, p, m["vm_name"]) }),
	"new-vm-wizard": wf(map[string]string{"template_name": "Rocky Linux 8", "new_vm_name": "wizard-vm"},
		func(u, n, p string, m map[string]string) { newVMWizard(u, n, p, m["template_name"], m["new_vm_name"]) }),
	"live-migrate": wf(map[string]string{
		"source_vm": "web-01", "sr_name": "Shared NFS", "new_vm_name": "sdk-example-migrate",
	}, func(u, n, p string, m map[string]string) {
		liveMigrate(u, n, p, m["source_vm"], m["sr_name"], m["new_vm_name"])
	}),
	"host-maintenance": wf(map[string]string{
		"source_vm": "web-01", "sr_name": "Shared NFS", "new_vm_name": "sdk-example-maint",
	}, func(u, n, p string, m map[string]string) {
		hostMaintenance(u, n, p, m["source_vm"], m["sr_name"], m["new_vm_name"])
	}),
	"configure-ha": wf(map[string]string{"heartbeat_sr_name": "Shared NFS"},
		func(u, n, p string, m map[string]string) { configureHa(u, n, p, m["heartbeat_sr_name"]) }),
	"copy-vm": wf(map[string]string{"vm_name": "db-01", "sr_name": "Shared NFS", "copy_name": "sdk-example-copy"},
		func(u, n, p string, m map[string]string) { copyVM(u, n, p, m["vm_name"], m["sr_name"], m["copy_name"]) }),
	"create-vm-with-vgpu": wf(map[string]string{"template_name": "Rocky Linux 8", "new_vm_name": "sdk-example-vgpu-vm"},
		func(u, n, p string, m map[string]string) {
			createVMWithVgpu(u, n, p, m["template_name"], m["new_vm_name"])
		}),
	"tags-and-folders": wf(map[string]string{"vm_name": "web-01"},
		func(u, n, p string, m map[string]string) { tagsAndFolders(u, n, p, m["vm_name"]) }),
	"configure-updates": wf(map[string]string{
		"repo_url": "https://repo.ops.xenserver.com/xs9", "source_url": "https://repo-src.ops.xenserver.com/xs9",
	}, func(u, n, p string, m map[string]string) { configureUpdates(u, n, p, m["repo_url"], m["source_url"]) }),
	"clone-vm": wf(map[string]string{"vm_name": "db-01", "clone_name": "sdk-example-clone"},
		func(u, n, p string, m map[string]string) { cloneVM(u, n, p, m["vm_name"], m["clone_name"]) }),
	"delete-vm": wf(map[string]string{"template_name": "Rocky Linux 8", "new_vm_name": "sdk-example-delete"},
		func(u, n, p string, m map[string]string) { deleteVM(u, n, p, m["template_name"], m["new_vm_name"]) }),
	"storage-migrate": wf(map[string]string{"source_vm": "web-01", "new_vm_name": "sdk-example-storagemigrate"},
		func(u, n, p string, m map[string]string) {
			storageMigrate(u, n, p, m["source_vm"], m["new_vm_name"])
		}),
	"apply-update": wf(map[string]string{
		"repo_url": "https://repo.ops.xenserver.com/xs9", "source_url": "https://repo-src.ops.xenserver.com/xs9",
	}, func(u, n, p string, m map[string]string) { applyUpdate(u, n, p, m["repo_url"], m["source_url"]) }),
	"checkpoint-vm": wf(map[string]string{"source_vm": "web-01", "new_vm_name": "sdk-example-checkpoint"},
		func(u, n, p string, m map[string]string) { checkpointVM(u, n, p, m["source_vm"], m["new_vm_name"]) }),
	"attach-disk": wf(map[string]string{
		"template_name": "Rocky Linux 8", "sr_name": "Shared NFS", "new_vm_name": "sdk-example-attachdisk",
	}, func(u, n, p string, m map[string]string) {
		attachDisk(u, n, p, m["template_name"], m["sr_name"], m["new_vm_name"])
	}),
	"wait-for-task": wf(map[string]string{"template_name": "Rocky Linux 8", "new_vm_name": "sdk-example-asynctask"},
		func(u, n, p string, m map[string]string) { waitForTask(u, n, p, m["template_name"], m["new_vm_name"]) }),
	"error-handling": wf(nil, func(u, n, p string, m map[string]string) { errorHandling(u, n, p) }),
	"list-templates": wf(nil, func(u, n, p string, m map[string]string) { listTemplates(u, n, p) }),
	"custom-fields": wf(map[string]string{"vm_name": "web-01"},
		func(u, n, p string, m map[string]string) { customFields(u, n, p, m["vm_name"]) }),
	"gpu-inventory": wf(nil, func(u, n, p string, m map[string]string) { gpuInventory(u, n, p) }),
	"read-metrics":  wf(nil, func(u, n, p string, m map[string]string) { readMetrics(u, n, p) }),
	"rename-object": wf(map[string]string{"vm_name": "web-01"},
		func(u, n, p string, m map[string]string) { renameObject(u, n, p, m["vm_name"]) }),
	"vm-boot-config": wf(map[string]string{"template_name": "Rocky Linux 8", "new_vm_name": "sdk-example-boot"},
		func(u, n, p string, m map[string]string) { vmBootConfig(u, n, p, m["template_name"], m["new_vm_name"]) }),
	"host-info":       wf(nil, func(u, n, p string, m map[string]string) { hostInfo(u, n, p) }),
	"list-roles":      wf(nil, func(u, n, p string, m map[string]string) { listRoles(u, n, p) }),
	"pool-properties": wf(nil, func(u, n, p string, m map[string]string) { poolProperties(u, n, p) }),
	"sr-usage":        wf(nil, func(u, n, p string, m map[string]string) { srUsage(u, n, p) }),
	"manage-vif": wf(map[string]string{"template_name": "Rocky Linux 8", "new_vm_name": "sdk-example-vif"},
		func(u, n, p string, m map[string]string) { manageVif(u, n, p, m["template_name"], m["new_vm_name"]) }),
	"list-networks": wf(nil, func(u, n, p string, m map[string]string) { listNetworks(u, n, p) }),
	"vbd-inventory": wf(map[string]string{"vm_name": "db-01"},
		func(u, n, p string, m map[string]string) { vbdInventory(u, n, p, m["vm_name"]) }),
	"pool-tags": wf(nil, func(u, n, p string, m map[string]string) { poolTags(u, n, p) }),
	"convert-to-template": wf(map[string]string{"template_name": "Rocky Linux 8", "new_vm_name": "sdk-example-totemplate"},
		func(u, n, p string, m map[string]string) {
			convertToTemplate(u, n, p, m["template_name"], m["new_vm_name"])
		}),
	"find-by-uuid": wf(map[string]string{"vm_name": "web-01"},
		func(u, n, p string, m map[string]string) { findByUUID(u, n, p, m["vm_name"]) }),
	"rolling-pool-update": wf(map[string]string{
		"repo_url": "https://repo.ops.xenserver.com/xs9", "source_url": "https://repo-src.ops.xenserver.com/xs9",
	}, func(u, n, p string, m map[string]string) { rollingPoolUpdate(u, n, p, m["repo_url"], m["source_url"]) }),
	"pvs-accelerator": wf(nil, func(u, n, p string, m map[string]string) { pvsAccelerator(u, n, p) }),
	"configure-pvs-accelerator": wf(map[string]string{"vm_name": "db-01"},
		func(u, n, p string, m map[string]string) { configurePvsAccelerator(u, n, p, m["vm_name"]) }),
	"manage-ssh-access": wf(nil, func(u, n, p string, m map[string]string) { manageSSHAccess(u, n, p) }),
	"manage-vtpm":       wf(nil, func(u, n, p string, m map[string]string) { manageVtpm(u, n, p) }),
	"export-import-vm": wf(map[string]string{"vm_name": "db-01"},
		func(u, n, p string, m map[string]string) { exportImportVm(u, n, p, m["vm_name"]) }),
	"configure-dynamic-memory": wf(nil, func(u, n, p string, m map[string]string) { configureDynamicMemory(u, n, p) }),
	"manage-vm-media":          wf(nil, func(u, n, p string, m map[string]string) { manageVmMedia(u, n, p) }),
	"backup-host-config":       wf(nil, func(u, n, p string, m map[string]string) { backupHostConfig(u, n, p) }),
	"manage-sr-lifecycle": wf(map[string]string{"nfs_server": "192.0.2.10", "nfs_path": "/export/spare"},
		func(u, n, p string, m map[string]string) { manageSrLifecycle(u, n, p, m["nfs_server"], m["nfs_path"]) }),
	"set-default-sr": wf(map[string]string{"nfs_server": "192.0.2.10", "nfs_path": "/export/spare"},
		func(u, n, p string, m map[string]string) { setDefaultSr(u, n, p, m["nfs_server"], m["nfs_path"]) }),
	"server-status-report": wf(nil, func(u, n, p string, m map[string]string) { serverStatusReport(u, n, p) }),
	// disaster-recovery has no usable default for dr_url (null/None/empty) - a second pool is
	// structurally required, so raise a clear error naming what's missing if it's not supplied.
	"disaster-recovery": wf(map[string]string{"dr_url": ""},
		func(u, n, p string, m map[string]string) { disasterRecovery(u, n, p, m["dr_url"]) }),
	"manage-secureboot-certificates": wf(nil, func(u, n, p string, m map[string]string) { manageSecurebootCertificates(u, n, p) }),
	"restart-host":                   wf(nil, func(u, n, p string, m map[string]string) { restartHost(u, n, p) }),
	"manage-crash-dumps":             wf(nil, func(u, n, p string, m map[string]string) { manageCrashDumps(u, n, p) }),
	"vm-from-snapshot": wf(map[string]string{"vm_name": "db-01"},
		func(u, n, p string, m map[string]string) { vmFromSnapshot(u, n, p, m["vm_name"]) }),
	"attach-existing-disk":   wf(nil, func(u, n, p string, m map[string]string) { attachExistingDisk(u, n, p) }),
	"changed-block-tracking": wf(nil, func(u, n, p string, m map[string]string) { changedBlockTracking(u, n, p) }),
	"control-domain-memory":  wf(nil, func(u, n, p string, m map[string]string) { controlDomainMemory(u, n, p) }),
	"rrd-metrics":            wf(nil, func(u, n, p string, m map[string]string) { rrdMetrics(u, n, p) }),
	"reclaim-space":          wf(nil, func(u, n, p string, m map[string]string) { reclaimSpace(u, n, p) }),
	"vm-ip-address": wf(map[string]string{"timeout": "60", "interval": "2"},
		func(u, n, p string, m map[string]string) { vmIpAddress(u, n, p, m["timeout"], m["interval"]) }),
	"manage-ad-users": wf(map[string]string{
		"domain": "", "admin_user": "alice", "admin_password": "Password1", "new_user": "alice",
		"ldaps": "false",
	}, func(u, n, p string, m map[string]string) {
		manageAdUsers(u, n, p, m["domain"], m["admin_user"], m["admin_password"], m["new_user"], m["ldaps"])
	}),
	"create-iscsi-sr": wf(map[string]string{
		"target": "192.0.2.30", "port": "", "chap_user": "", "chap_password": "", "target_iqn": "",
		"sr_name": "sdk-example-iscsi",
	}, func(u, n, p string, m map[string]string) {
		createIscsiSr(u, n, p, m["target"], m["port"], m["chap_user"], m["chap_password"], m["target_iqn"],
			m["sr_name"])
	}),
	"create-smb-sr": wf(map[string]string{
		"server": "192.0.2.40", "share": "/vmstore", "smb_username": "Administrator",
		"smb_password": "Password1", "sr_name": "sdk-example-smb",
	}, func(u, n, p string, m map[string]string) {
		createSmbSr(u, n, p, m["server"], m["share"], m["smb_username"], m["smb_password"], m["sr_name"])
	}),
	"create-hba-sr": wf(map[string]string{"scsi_id": "", "sr_name": "sdk-example-hba"},
		func(u, n, p string, m map[string]string) { createHbaSr(u, n, p, m["scsi_id"], m["sr_name"]) }),
	"create-iso-sr": wf(map[string]string{"location": "192.0.2.10:/isos"},
		func(u, n, p string, m map[string]string) { createIsoSr(u, n, p, m["location"]) }),
	"configure-nrpe": wf(nil, func(u, n, p string, m map[string]string) { configureNrpe(u, n, p) }),
	"configure-snmp": wf(map[string]string{"trap_destination": "192.0.2.50"},
		func(u, n, p string, m map[string]string) { configureSnmp(u, n, p, m["trap_destination"]) }),
	"configure-clustering":   wf(nil, func(u, n, p string, m map[string]string) { configureClustering(u, n, p) }),
	"manage-pool-membership": wf(nil, func(u, n, p string, m map[string]string) { managePoolMembership(u, n, p) }),
	"create-bond":            wf(nil, func(u, n, p string, m map[string]string) { createBond(u, n, p) }),
	"manage-vapp": wf(map[string]string{"vm_name": "db-01"},
		func(u, n, p string, m map[string]string) { manageVapp(u, n, p, m["vm_name"]) }),
	"attach-usb-device": wf(map[string]string{"vm_name": "web-01"},
		func(u, n, p string, m map[string]string) { attachUsbDevice(u, n, p, m["vm_name"]) }),
	"wlb-recommendations": wf(map[string]string{
		"vm_name": "web-01", "wlb_host_port": "wlb.example:8012", "wlb_username": "wlbuser", "wlb_password": "wlbpass",
		"wlb_certificate": "",
	}, func(u, n, p string, m map[string]string) {
		wlbRecommendations(u, n, p, m["vm_name"], m["wlb_host_port"], m["wlb_username"], m["wlb_password"],
			m["wlb_certificate"])
	}),
	"configure-pool-options":   wf(nil, func(u, n, p string, m map[string]string) { configurePoolOptions(u, n, p) }),
	"configure-console-access": wf(nil, func(u, n, p string, m map[string]string) { configureConsoleAccess(u, n, p) }),
	"configure-host-storage":   wf(nil, func(u, n, p string, m map[string]string) { configureHostStorage(u, n, p) }),
	"configure-syslog": wf(map[string]string{"syslog_server": "192.0.2.50"},
		func(u, n, p string, m map[string]string) { configureSyslog(u, n, p, m["syslog_server"]) }),
	"manage-driver-variants": wf(nil, func(u, n, p string, m map[string]string) { manageDriverVariants(u, n, p) }),
}

func main() {
	// cross-pool-copy-vm spans two pools, so it keeps its own positional form - the destination URL,
	// then optionally that pool's credentials (if they differ from the source's) and the VM to copy -
	// with no key=value overrides.
	if len(os.Args) >= 2 && os.Args[1] == "cross-pool-copy-vm" {
		n := len(os.Args)
		if n != 6 && n != 8 && n != 9 {
			fmt.Fprintln(os.Stderr, "usage: go run . cross-pool-copy-vm <sourceUrl> <user> <password> <destUrl>"+
				" [<destUser> <destPassword> [<vmName>]]")
			os.Exit(2)
		}
		vmName, destUser, destPassword := "db-01", "", ""
		if n >= 8 {
			destUser, destPassword = os.Args[6], os.Args[7]
		}
		if n == 9 {
			vmName = os.Args[8]
		}
		crossPoolCopyVM(os.Args[2], os.Args[3], os.Args[4], os.Args[5], vmName, destUser, destPassword)
		return
	}
	if len(os.Args) < 5 {
		fmt.Fprintln(os.Stderr, "usage: go run . <workflow> <url> <user> <password> [key=value ...]")
		os.Exit(2)
	}
	workflow, ok := workflows[os.Args[1]]
	if !ok {
		fmt.Fprintf(os.Stderr, "unknown workflow: %s\n", os.Args[1])
		os.Exit(2)
	}

	// Everything else is a named parameter with a default chosen to work against the simulator;
	// key=value arguments after the password override that workflow's default for the named
	// parameter.
	params := make(map[string]string, len(workflow.defaults))
	for k, v := range workflow.defaults {
		params[k] = v
	}
	for _, arg := range os.Args[5:] {
		key, value, found := strings.Cut(arg, "=")
		if !found {
			fmt.Fprintf(os.Stderr, "extra arguments must be key=value (got %q)\n", arg)
			os.Exit(2)
		}
		params[key] = value
	}

	workflow.run(os.Args[2], os.Args[3], os.Args[4], params)
}
