#!/usr/bin/env python3
"""
XenServer Python SDK - real-world workflow examples.

Each example is a self-contained function that mirrors a task you would perform in
XenCenter, driven entirely through the XenServer Management API (XenAPI). The Python
binding (XenAPI.py) speaks XML-RPC and is included with the SDK.

Every example takes the connection details (and any object it acts on, looked up by name)
as parameters, opens its own session and logs out when done - so you can copy one out and
run it on its own; see the "Run it:" line under each. The dispatcher at the bottom is only
what lets this one file run any of them from the command line.

Usage:
    python workflows.py <workflow> <url> <username> <password> [key=value ...]

    <workflow>  any workflow id from the dispatcher at the bottom (see also README.md)
    <url>       e.g. https://coordinator.example.com

Most workflows need only the connection details and run against the dispatcher's built-in
(simulator-friendly) defaults. A few need environment-specific values to do anything real - an
iSCSI target address, an AD domain, a second pool to recover into - and take them as extra
`key=value` arguments after the password, overriding that workflow's default for the named
parameter (e.g. `create-iscsi-sr <url> <user> <pw> target=10.1.2.3`,
`disaster-recovery <url> <user> <pw> dr_url=https://standby-pool`). See each function's docstring
for its parameters.
"""

import base64
import json
import subprocess
import tarfile
import tempfile
import os
import re
import shutil
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import xmlrpc.client

# The SDK's Python binding: `pip install XenAPI`, or copy XenServerPython/XenAPI.py from the SDK
# next to this file.
import XenAPI


# --- connect ---
def connect(url, username, password):
    """Open a session, skipping certificate validation for the host's self-signed cert.

    If url points at a pool *member* rather than the coordinator, login fails with HOST_IS_SLAVE
    naming the coordinator's address; we reconnect to it (assuming the coordinator is up), exactly
    as XenCenter does when you add a member server."""
    session = XenAPI.Session(url, ignore_ssl=True)
    try:
        session.login_with_password(username, password, "1.0", "sdk-examples")
    except XenAPI.Failure as e:
        if e.details[0] != "HOST_IS_SLAVE":
            raise
        session = XenAPI.Session("https://%s" % e.details[1], ignore_ssl=True)  # the coordinator
        session.login_with_password(username, password, "1.0", "sdk-examples")
    return session


def template_by_name(session, name):
    """Find a template VM by its exact name (rather than picking an arbitrary one)."""
    for ref, r in session.xenapi.VM.get_all_records().items():
        if r["is_a_template"] and r["name_label"] == name:
            return ref
    raise RuntimeError("no template named %r was found" % name)


def vm_by_name(session, name):
    """Find a guest VM (not a template, control domain or snapshot) by its exact name."""
    for ref, r in session.xenapi.VM.get_all_records().items():
        if (not r["is_a_template"] and not r["is_control_domain"]
                and not r["is_a_snapshot"] and r["name_label"] == name):
            return ref
    raise RuntimeError("no VM named %r was found" % name)


def sr_by_name(session, name, shared=False):
    """Find an SR by its exact name (optionally requiring it to be shared)."""
    for ref, r in session.xenapi.SR.get_all_records().items():
        if r["name_label"] == name and (not shared or r["shared"]):
            return ref
    raise RuntimeError("no %sSR named %r was found" % ("shared " if shared else "", name))


def detach_and_forget_sr(session, sr):
    """Detach an SR from every host, then forget it - XenCenter's Detach followed by Forget.

    SR.forget refuses an SR that is still attached (SR_HAS_PBD), so unplug its PBDs first. Forgetting
    drops the pool's record of the SR but leaves the data on the storage itself."""
    for pbd in session.xenapi.SR.get_PBDs(sr):
        if session.xenapi.PBD.get_currently_attached(pbd):
            session.xenapi.PBD.unplug(pbd)
    session.xenapi.SR.forget(sr)


def provision(session, vm):
    """Provision a cloned template into a real VM, filling in the SR first.

    A template's other_config["disks"] is <provision><disk ... sr="" .../></provision> - sr="" means
    "whoever provisions this names the SR". VM.provision takes it literally and fails with
    UUID_INVALID, so rewrite every <disk>'s sr to the pool's default SR first, exactly as
    `xe vm-install` does, before provisioning."""
    pool_ref = session.xenapi.pool.get_all()[0]
    sr_uuid = session.xenapi.SR.get_uuid(session.xenapi.pool.get_default_SR(pool_ref))

    disks_xml = session.xenapi.VM.get_other_config(vm).get("disks")
    if disks_xml:
        root = ET.fromstring(disks_xml)
        for disk in root.findall("disk"):
            disk.set("sr", sr_uuid)
        session.xenapi.VM.remove_from_other_config(vm, "disks")
        session.xenapi.VM.add_to_other_config(vm, "disks", ET.tostring(root, encoding="unicode"))

    session.xenapi.VM.provision(vm)


def copy_of_guest(session, source_vm_name, new_vm_name):
    """A throwaway VM with a working guest OS: a copy of an existing VM that has one.

    Suspend, checkpoint, live migration and clean shutdown all need the guest's cooperation: on a
    running VM with no PV drivers xapi refuses them up front with VM_LACKS_FEATURE (a VM freshly
    cloned from a template has no OS at all). So copy a VM that does have an OS and PV drivers,
    without disturbing it: snapshot it (fine while it runs), clone the snapshot - a clone of a
    snapshot is a template - and provision that into an ordinary VM. The snapshot is only needed
    for the clone, so it goes again straight away."""
    source = vm_by_name(session, source_vm_name)
    snapshot = session.xenapi.VM.snapshot(source, new_vm_name + "-source")
    vm = session.xenapi.VM.clone(snapshot, new_vm_name)
    provision(session, vm)
    destroy_vm_and_disks(session, snapshot)
    return vm


def wait_for_guest_agent(session, vm, timeout=300, interval=2):
    """Wait, after VM.start, until the guest's PV drivers have reported in.

    xapi only offers the guest-dependent operations once the guest says it can do them, and
    allowed_operations is where it says so: wait for clean_shutdown to appear there (the same
    check that refuses it with VM_LACKS_FEATURE beforehand). A Linux kernel offers that early in
    boot, before the agent runs (hot-plug needs the agent, and suspend needs its emulated disk
    unplugged), so wait for the guest metrics to report the PV drivers too. A booting OS takes a while."""
    def ready():
        if "clean_shutdown" not in session.xenapi.VM.get_allowed_operations(vm):
            return False
        metrics = session.xenapi.VM.get_guest_metrics(vm)
        return metrics != "OpaqueRef:NULL" and session.xenapi.VM_guest_metrics.get_PV_drivers_detected(metrics)

    deadline = time.time() + timeout
    while not ready():
        if time.time() > deadline:
            raise RuntimeError("the guest's PV drivers did not report in within %ds; does the source "
                               "VM have a guest OS with PV drivers (XenServer VM Tools)?" % timeout)
        time.sleep(interval)


def _xml_from_failure(e):
    """The first (from the end) XenAPI.Failure detail that looks like an XML fragment, or None."""
    for detail in reversed(e.details):
        if detail and detail.lstrip().startswith("<"):
            return detail
    return None


def _probe_for_failure(session, host, device_config, sm_type):
    """Return the XML a backend sends back on its deliberately-failing discovery probe.

    The New SR wizard (and XenRT) discover iSCSI/HBA LUNs by asking with an incomplete
    device-config on purpose: the backend can't create anything from it yet, so it fails with an
    SR_BACKEND_FAILURE_<n> error whose params carry an XML fragment describing what it found (the
    IQNs on offer, then the LUNs behind one of them, or - for HBA - every LUN visible at all).
    A probe that unexpectedly *succeeds* means the device-config was already complete - not the
    discovery prompt this helper is looking for. (Never probe by attempting SR.create instead: on
    real storage a create that succeeds formats the LUN.)"""
    try:
        session.xenapi.SR.probe(host, device_config, sm_type, {})
    except XenAPI.Failure as e:
        xml = _xml_from_failure(e)
        if xml:
            return xml
        raise
    raise RuntimeError("SR.probe for %s succeeded without asking for more information; "
                       "check the target address" % sm_type)


def _choose_target_iqn(iqn_xml, target, target_iqn):
    """Pick the IQN from an iSCSI discovery probe: the caller's, if named (it must be one the target
    offers), else the first. An array usually offers many targets - one per LUN, often belonging to
    different users - so on shared storage always name yours: SR.create formats the LUN behind it."""
    offered = [e.text for e in iqn_xml.findall(".//TargetIQN")]
    if target_iqn and target_iqn not in offered:
        raise RuntimeError("target %s does not offer IQN %s" % (target, target_iqn))
    return target_iqn or offered[0]


def _self_signed_cert_pem():
    """A throwaway self-signed certificate and private key (PEM), the way XenRT provisions one for
    its own certificate tests.

    Prefers the `cryptography` package (pure Python, no external tool needed) when it's installed;
    falls back to shelling out to `openssl req -x509` - the same tool XenRT itself uses - when it
    isn't, so this works either way without forcing an extra dependency on everyone."""
    try:
        import datetime
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID

        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "sdk-example")])
        now = datetime.datetime.utcnow()
        cert = (x509.CertificateBuilder()
                .subject_name(name).issuer_name(name).public_key(key.public_key())
                .serial_number(x509.random_serial_number())
                .not_valid_before(now - datetime.timedelta(days=1))
                .not_valid_after(now + datetime.timedelta(days=365))
                .sign(key, hashes.SHA256()))
        cert_pem = cert.public_bytes(serialization.Encoding.PEM).decode()
        key_pem = key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
            serialization.NoEncryption()).decode()
        return cert_pem, key_pem
    except ImportError:
        handle, keypath = tempfile.mkstemp(prefix="sdk-example-key-", suffix=".pem")
        os.close(handle)
        handle, certpath = tempfile.mkstemp(prefix="sdk-example-cert-", suffix=".pem")
        os.close(handle)
        try:
            subprocess.run(
                ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", keypath, "-out", certpath, "-days", "365", "-subj", "/CN=sdk-example"],
                check=True, capture_output=True)
            with open(certpath) as f:
                cert_pem = f.read()
            with open(keypath) as f:
                key_pem = f.read()
            return cert_pem, key_pem
        finally:
            os.remove(keypath)
            os.remove(certpath)


def _reconnect_after_master_change(url, username, password, new_master_uuid, timeout=600, interval=5):
    """Wait out a pool-wide xapi restart (pool.designate_new_master) and reconnect.

    designate_new_master returns BEFORE the change: for a while the old coordinator still answers,
    and still says it is the coordinator, until xapi restarts across the pool. So reconnecting is not
    enough - keep reconnecting until the pool names the new coordinator (by uuid; connect() follows
    HOST_IS_SLAVE to wherever the coordinator now is). XenRT's own helper likewise waits minutes
    before trusting the pool again."""
    deadline = time.time() + timeout
    last_error = None
    while time.time() < deadline:
        try:
            session = connect(url, username, password)
            x = session.xenapi
            master = x.pool.get_master(x.pool.get_all()[0])
            # The new coordinator answers before the pool has settled - calls made too soon fail
            # (HANDLE_INVALID on the operation's own task) - so also wait for every host to be back,
            # live and enabled.
            if x.host.get_uuid(master) == new_master_uuid and all(
                    r["enabled"] and x.host_metrics.get_live(r["metrics"])
                    for r in x.host.get_all_records().values()):
                return session
            x.session.logout()
            last_error = "the pool has not settled under the new coordinator"
        except Exception as e:
            last_error = e
        time.sleep(interval)
    raise RuntimeError("the pool did not come back after the master change: %s" % last_error)


def _wait_for_host_live(x, host, want, timeout=60, interval=2):
    """Poll host_metrics.live until it matches, rather than issuing the next power command
    immediately - real out-of-band power control has no retry of its own, so a tool that doesn't
    wait can issue a second command while the first is still in flight."""
    deadline = time.time() + timeout
    while host_live(x, host) != want:
        if time.time() > deadline:
            raise RuntimeError("host did not reach live=%s in time" % want)
        time.sleep(interval)


def _wait_for_restart(url, username, password, host_uuid, key, before, timeout=1800, interval=10):
    """Wait for a host to come back from a reboot (key "boot_time") or toolstack restart
    ("agent_start_time"): until that other_config entry differs from `before` and the host is live.
    Reconnects every time round, because the host restarting may be the coordinator this session
    talks to; returns the new session."""
    deadline = time.time() + timeout
    while True:
        try:
            session = connect(url, username, password)
            x = session.xenapi
            host = x.host.get_by_uuid(host_uuid)
            if x.host.get_other_config(host).get(key) != before and host_live(x, host):
                return session
            x.session.logout()
        except (OSError, xmlrpc.client.ProtocolError, XenAPI.Failure):
            pass                     # down, or xapi still starting
        if time.time() > deadline:
            raise RuntimeError("host %s did not come back in time" % host_uuid)
        time.sleep(interval)


def _enable_when_booted(x, host, timeout=600, interval=10):
    """Re-enable a host that has just come back. It reports itself live before xapi on it has
    finished starting, and until then host.enable fails HOST_STILL_BOOTING - so retry that."""
    deadline = time.time() + timeout
    while True:
        try:
            x.host.enable(host)
            return
        except XenAPI.Failure as e:
            if e.details[0] != "HOST_STILL_BOOTING" or time.time() > deadline:
                raise
            time.sleep(interval)


def _host_url(url, address):
    """Build the URL for a given host's own address, keeping the scheme and port the caller
    originally connected with (a host's management address carries no port of its own)."""
    parts = urllib.parse.urlsplit(url)
    port = ":%d" % parts.port if parts.port else ""
    return "%s://%s%s" % (parts.scheme, address, port)


def _move_disks_to_sr(session, vm, sr_ref):
    """Relocate every one of a (not-yet-started) VM's disks onto the given SR, the same
    VDI.pool_migrate storage-migrate already demonstrates."""
    for vdi in _disk_vdis(session, vm):
        if session.xenapi.VDI.get_SR(vdi) != sr_ref:
            session.xenapi.VDI.pool_migrate(vdi, sr_ref, {})


# --- 1. Connect & inventory -------------------------------------------------------------
def connect_inventory(url, username, password):
    """Log in and take an inventory of the pool: its name, its hosts and its VMs."""
    session = connect(url, username, password)
    pool = list(session.xenapi.pool.get_all_records().values())[0]
    print("Connected to pool: %s" % pool["name_label"])

    hosts = session.xenapi.host.get_all_records()
    print("Hosts (%d):" % len(hosts))
    for host in hosts.values():
        print("  - %s (%s)" % (host["name_label"], host["address"]))

    vms = [v for v in session.xenapi.VM.get_all_records().values()
           if not v["is_a_template"] and not v["is_control_domain"]]
    print("VMs (%d):" % len(vms))
    for vm in vms:
        print("  - %s [%s]" % (vm["name_label"], vm["power_state"]))

    print("OK: connect-inventory")
    session.xenapi.session.logout()
# Run it:
#   connect_inventory("https://xenserver", "root", password)


# --- 2. Create a VM from a template -----------------------------------------------------
def create_vm(url, username, password, template_name, new_vm_name="sdk-example-vm"):
    """Clone the named template and provision it into a real, installable VM."""
    session = connect(url, username, password)
    template_ref = template_by_name(session, template_name)
    print("Using template: %s" % session.xenapi.VM.get_name_label(template_ref))

    vm_ref = session.xenapi.VM.clone(template_ref, new_vm_name)
    print("Cloned new VM: %s" % session.xenapi.VM.get_uuid(vm_ref))

    # provision() turns the template clone into a normal (installable) VM.
    provision(session, vm_ref)
    print("Provisioned. is_a_template = %s" % session.xenapi.VM.get_is_a_template(vm_ref))

    # Tidy up so the example is repeatable.
    destroy_vm_and_disks(session, vm_ref)
    print("Cleaned up the example VM.")

    print("OK: create-vm")
    session.xenapi.session.logout()
# Run it:
#   create_vm("https://xenserver", "root", password, "Rocky Linux 8")


# --- 3. VM power lifecycle --------------------------------------------------------------
def vm_lifecycle(url, username, password, source_vm, new_vm_name="sdk-example-lifecycle"):
    """Take a throwaway copy of a VM with a guest OS through start -> suspend -> resume -> clean
    shutdown, and delete it again.

    Suspend and clean shutdown need the guest's cooperation (VM_LACKS_FEATURE without PV drivers),
    so the copy is made from source_vm, a VM with a guest OS and PV drivers, and the example waits
    for the guest to report in after starting. Suspend also needs a suspend-image SR (the VM's own,
    else the pool's, else the host's); check one is actually configured before trying."""
    session = connect(url, username, password)
    vm_ref = copy_of_guest(session, source_vm, new_vm_name)

    def state():
        return session.xenapi.VM.get_power_state(vm_ref)

    print("Initial power state: %s" % state())
    session.xenapi.VM.start(vm_ref, False, True)
    wait_for_guest_agent(session, vm_ref)
    print("After start:   %s" % state())

    # The emulated hardware (the device model) can be restarted under a running guest without
    # rebooting it -- what you reach for when the VM's virtual devices misbehave.
    session.xenapi.VM.restart_device_models(vm_ref)
    print("Device models restarted; still %s" % state())

    if _has_suspend_sr(session, vm_ref):
        session.xenapi.VM.suspend(vm_ref)
        print("After suspend: %s" % state())
        session.xenapi.VM.resume(vm_ref, False, True)
        wait_for_guest_agent(session, vm_ref)   # the PV drivers reconnect after a resume
        print("After resume:  %s" % state())
    else:
        print("Skipping suspend/resume: no suspend-image SR is configured for this VM/pool/host")

    # A clean shutdown asks the guest OS to shut itself down, as pressing the power button would.
    session.xenapi.VM.clean_shutdown(vm_ref)
    print("After shutdown:%s" % state())

    destroy_vm_and_disks(session, vm_ref)
    print("OK: vm-lifecycle")
    session.xenapi.session.logout()


def _has_suspend_sr(session, vm):
    """Whether VM.suspend has a suspend-image SR to use: the VM's own, else the pool's, else the
    resident host's - the same fallback order xapi's choose_suspend_sr uses."""
    x = session.xenapi
    if x.VM.get_suspend_SR(vm) != "OpaqueRef:NULL":
        return True
    pool = x.pool.get_all()[0]
    if x.pool.get_suspend_image_SR(pool) != "OpaqueRef:NULL":
        return True
    host = x.pool.get_master(pool)
    return x.host.get_suspend_image_sr(host) != "OpaqueRef:NULL"
# Run it:
#   vm_lifecycle("https://xenserver", "root", password, "web-01")


# --- 4. Manage VM disks: Deactivate / Resize / Activate -------------------------------
def manage_vm_disks(url, username, password, source_vm, sr_name, new_vm_name="sdk-example-vm-disks"):
    """Deactivate a data disk, resize it, and reactivate it.

    Not the VM's root/boot disk: a real VM's system disk is unpluggable=false (only a template's
    non-system disks default to unpluggable), so VBD.unplug on it fails on a real host with
    VBD_NOT_UNPLUGGABLE - and the VM has to be running in the first place, or unplug fails with
    VM_BAD_POWER_STATE. Work on a data disk this example adds to its own throwaway VM instead,
    matching XenCenter's own "deactivate" action, which only ever targets additional disks, and
    tidy up afterwards so the example is repeatable. No shrink: real SR backends refuse one
    outright (SR_BACKEND_FAILURE_79), so this only ever grows.

    Plugging and unplugging a disk on a running VM needs the guest's PV drivers
    (VM_MISSING_PV_DRIVERS otherwise), so the VM is a throwaway copy of source_vm, a VM with a
    guest OS and PV drivers."""
    GIB = 1024 * 1024 * 1024
    session = connect(url, username, password)
    vm_ref = copy_of_guest(session, source_vm, new_vm_name)
    session.xenapi.VM.start(vm_ref, False, True)
    wait_for_guest_agent(session, vm_ref)

    sr_ref = sr_by_name(session, sr_name)
    vdi_ref = session.xenapi.VDI.create({
        "name_label": "sdk-example-data-disk", "SR": sr_ref, "virtual_size": str(4 * GIB),
        "type": "user", "sharable": False, "read_only": False, "other_config": {},
    })
    vbd_ref = session.xenapi.VBD.create({
        "VM": vm_ref, "VDI": vdi_ref,
        "userdevice": session.xenapi.VM.get_allowed_VBD_devices(vm_ref)[0],
        "bootable": False,
        "mode": "RW", "type": "Disk", "empty": False, "other_config": {},
        "qos_algorithm_type": "", "qos_algorithm_params": {},
    })
    session.xenapi.VBD.plug(vbd_ref)
    print("Disk attached:  %s" % session.xenapi.VBD.get_currently_attached(vbd_ref))

    # Deactivate = VBD.unplug. The disk stays with the VM; it is just no longer live.
    session.xenapi.VBD.unplug(vbd_ref)
    print("After unplug:   %s" % session.xenapi.VBD.get_currently_attached(vbd_ref))

    size = int(session.xenapi.VDI.get_virtual_size(vdi_ref))
    session.xenapi.VDI.resize(vdi_ref, str(size * 2))
    print("Resized:        %d -> %s bytes" % (size, session.xenapi.VDI.get_virtual_size(vdi_ref)))

    session.xenapi.VBD.plug(vbd_ref)
    print("After plug:     %s" % session.xenapi.VBD.get_currently_attached(vbd_ref))

    # Growing a disk that is attached and live is a DIFFERENT call, not a flag on the same one:
    # resize_online tells the storage layer the guest is using the disk while it grows. Only some
    # storage drivers can (none of a stock XenServer 9's do), and the rest refuse with
    # SR_OPERATION_NOT_SUPPORTED - so ask the SR's driver (its SM record's features) first.
    sr_type = session.xenapi.SR.get_type(sr_ref)
    features = next((r["features"] for r in session.xenapi.SM.get_all_records().values()
                     if r["type"] == sr_type), {})
    if "VDI_RESIZE_ONLINE" in features:
        grown = int(session.xenapi.VDI.get_virtual_size(vdi_ref)) + GIB
        session.xenapi.VDI.resize_online(vdi_ref, str(grown))
        print("Grown online:   %s bytes" % session.xenapi.VDI.get_virtual_size(vdi_ref))
    else:
        print("Grown online:   not supported by %s storage; unplug, resize, plug as above" % sr_type)

    session.xenapi.VM.hard_shutdown(vm_ref)
    destroy_vm_and_disks(session, vm_ref)
    print("OK: manage-vm-disks")
    session.xenapi.session.logout()


# --- Raise and dismiss alerts ---------------------------------------------------------
def dismiss_alerts(url, username, password):
    """List the pool's alerts and dismiss one, as the Notifications view does."""
    session = connect(url, username, password)
    messages = session.xenapi.message.get_all_records()
    print("Alerts:         %d" % len(messages))

    if not messages:
        print("No alerts to dismiss.")
    else:
        ref = sorted(messages.keys())[0]
        print("Dismissing:     %s (priority %s)" % (messages[ref]["name"], messages[ref]["priority"]))
        session.xenapi.message.destroy(ref)
        print("Alerts left:    %d" % len(session.xenapi.message.get_all_records()))
    print("OK: dismiss-alerts")
    session.xenapi.session.logout()


# --- Configure host power on ----------------------------------------------------------
def host_power_on(url, username, password):
    """Set a host's out-of-band power-on mode and credentials, then read them back."""
    session = connect(url, username, password)
    host_ref = session.xenapi.host.get_all()[0]

    # Mode and config travel together: the config carries the credentials the mode needs.
    # "wake-on-lan" is a real, still-supported mode and needs no credentials; the legacy "iLO"/
    # "DRAC" modes were removed from the real power-on plugin (REQ-811) and fail the moment
    # host.power_on is actually called.
    session.xenapi.host.set_power_on_mode(host_ref, "wake-on-lan", {})
    print("Power-on mode:  %s" % session.xenapi.host.get_power_on_mode(host_ref))
    for k, v in sorted(session.xenapi.host.get_power_on_config(host_ref).items()):
        print("  %s = %s" % (k, v))

    session.xenapi.host.set_power_on_mode(host_ref, "", {})
    print("OK: host-power-on")
    session.xenapi.session.logout()


# --- Rotate the pool secret -----------------------------------------------------------
def rotate_pool_secret(url, username, password):
    """Rotate the shared secret pool members authenticate to each other with.

    xapi checks its own preconditions before rotating - HA must be disabled, every host must be
    live, no rolling pool upgrade may be in progress, and the pool must be licensed for it - and
    raises a clear error naming which one failed rather than silently refusing. Report that
    explanation instead of letting an unhandled XenAPI.Failure speak for itself."""
    session = connect(url, username, password)
    pool_ref = list(session.xenapi.pool.get_all_records().keys())[0]
    print("Pool:           %s" % session.xenapi.pool.get_name_label(pool_ref))

    explanations = {
        "HA_IS_ENABLED": "HA is enabled on this pool; disable it first.",
        "CANNOT_CONTACT_HOST": "a host in the pool is not reachable.",
        "NOT_SUPPORTED_DURING_UPGRADE": "a rolling pool upgrade is in progress.",
        "LICENCE_RESTRICTION": "this edition is not licensed for pool secret rotation.",
    }
    try:
        # A pool-wide operation; existing sessions survive it.
        session.xenapi.pool.rotate_secret()
        print("Rotated. Still connected: %s" % (len(session.xenapi.pool.get_all()) == 1))
    except XenAPI.Failure as e:
        print("Could not rotate the pool secret: %s (%s)"
              % (e.details[0], explanations.get(e.details[0], "see the error for detail")))
    print("OK: rotate-pool-secret")
    session.xenapi.session.logout()


# --- Change the root password ---------------------------------------------------------
def change_root_password(url, username, password):
    """Change the local superuser password, then change it back."""
    session = connect(url, username, password)
    temporary = "sdk-example-temp-password"

    # change_password takes the OLD password as well as the new one, even though you are already
    # authenticated.
    session.xenapi.session.change_password(password, temporary)
    print("Password changed.")

    # The existing session stays valid afterwards - only NEW connections need the new password.
    print("Session still usable: %s" % (len(session.xenapi.pool.get_all()) == 1))

    # change_password on a ROOT session ignores the old password entirely (CA-13567): the call
    # succeeds whatever old_pwd is, so a wrong old password is not a failure to demonstrate here. The
    # real gate is who may call this at all: only a local superuser session.
    print("Is local superuser (may call change_password): %s"
          % session.xenapi.session.get_is_local_superuser(session._session))

    session.xenapi.session.change_password(temporary, password)
    print("Password restored.")
    print("OK: change-root-password")
    session.xenapi.session.logout()
# Run it:
#   change_root_password("https://xenserver", "root", password)


# --- Manage TLS certificates ----------------------------------------------------------
def manage_certificates(url, username, password):
    """Install a pool-wide trusted certificate, replace a host's own TLS identity with a real
    certificate, reset it back to a fresh self-signed one, and read the counts back.

    A real, generated self-signed certificate, not a placeholder string: xapi decodes whatever is
    handed to install_trusted_certificate/install_server_certificate as PEM and rejects anything
    that isn't a well-formed certificate (INVALID_VALUE), so a dummy string fails on a real host
    even though it has no such check in the simulator. install_trusted_certificate/
    uninstall_trusted_certificate are the current API; the CA-specific pair this example used to
    call (install_ca_certificate/uninstall_ca_certificate) were deprecated in their favour."""
    session = connect(url, username, password)
    host_ref = session.xenapi.host.get_all()[0]
    pool_ref = session.xenapi.pool.get_all()[0]
    cert_pem, key_pem = _self_signed_cert_pem()

    print("Certificates:   %d" % len(session.xenapi.Certificate.get_all()))

    # ca=True: trusted as a root to verify a chain, not pinned as one specific leaf certificate.
    # purpose=[]: general pool trust, not the licensing/ldaps-specific uses that enum also covers.
    # install_trusted_certificate returns nothing, so find the new record by diffing the set.
    before = set(session.xenapi.Certificate.get_all())
    session.xenapi.pool.install_trusted_certificate(pool_ref, True, cert_pem, [])
    cert_ref = next(iter(set(session.xenapi.Certificate.get_all()) - before))
    print("After CA add:   %d" % len(session.xenapi.Certificate.get_all()))

    # Actually replace the host's own TLS identity with a real certificate (what this workflow's
    # name promises, beyond CA trust), then reset it back to a fresh self-signed one.
    session.xenapi.host.install_server_certificate(host_ref, cert_pem, key_pem, "")
    print("Host certificate replaced with a real, generated certificate.")
    session.xenapi.host.reset_server_certificate(host_ref)
    print("Host certificate reset (a fresh self-signed identity).")

    session.xenapi.pool.uninstall_trusted_certificate(pool_ref, cert_ref)
    print("After CA remove:%d" % len(session.xenapi.Certificate.get_all()))

    # Separately from which certificates exist: whether the pool actually CHECKS the ones its members
    # present to each other. Turning it on is a one-way door from here -- there is no matching disable,
    # because a pool that could be talked out of verifying would not be verifying -- so the call is
    # idempotent and safe to repeat.
    pool = session.xenapi.pool.get_all()[0]
    print("TLS verification: %s" % session.xenapi.pool.get_tls_verification_enabled(pool))
    session.xenapi.pool.enable_tls_verification()
    print("  after enabling: %s" % session.xenapi.pool.get_tls_verification_enabled(pool))
    print("OK: manage-certificates")
    session.xenapi.session.logout()


# --- Snapshot schedule ----------------------------------------------------------------
def snapshot_schedule(url, username, password, vm_name, schedule_name="sdk-example-schedule"):
    """Create a scheduled-snapshot policy, attach a VM, run it, and watch retention prune."""
    session = connect(url, username, password)
    vm_ref = vm_by_name(session, vm_name)

    # retained_snapshots is the interesting field: the schedule prunes to it every time it runs.
    vmss_ref = session.xenapi.VMSS.create({
        "name_label": schedule_name,
        "name_description": "Scheduled snapshots created by the SDK example",
        "enabled": True,
        "type": "snapshot",
        "frequency": "daily",
        "retained_snapshots": "2",
        "schedule": {"hour": "2", "min": "0"},
    })
    print("Created schedule: %s" % session.xenapi.VMSS.get_uuid(vmss_ref))

    session.xenapi.VM.set_snapshot_schedule(vm_ref, vmss_ref)
    print("Members:          %d" % len(session.xenapi.VMSS.get_VMs(vmss_ref)))

    # Run it three times against a retention of two: the oldest is pruned away. Compare against the
    # snapshots the VM already had, so only the schedule's own are counted (and tidied up below).
    before = set(session.xenapi.VM.get_snapshots(vm_ref))
    for _ in range(3):
        session.xenapi.VMSS.snapshot_now(vmss_ref)
    kept = [s for s in session.xenapi.VM.get_snapshots(vm_ref) if s not in before]
    print("Snapshots kept:   %d (retention 2)" % len(kept))

    # Tidy up: a schedule with VMs still on it cannot be destroyed (VMSS_HAS_VM), so take the VM off it
    # first. Destroying the schedule leaves the snapshots it took, so destroy those too, with their disks.
    session.xenapi.VM.set_snapshot_schedule(vm_ref, "OpaqueRef:NULL")
    session.xenapi.VMSS.destroy(vmss_ref)
    for snapshot in kept:
        destroy_vm_and_disks(session, snapshot)
    print("OK: snapshot-schedule")
    session.xenapi.session.logout()
# Run it:
#   snapshot_schedule("https://xenserver", "root", password, "web-01")


# --- Manage VM groups -----------------------------------------------------------------
def manage_vm_groups(url, username, password, vm_name, group_name="sdk-example-group"):
    """Create an anti-affinity VM group, add a VM, read the membership back, then tidy up."""
    session = connect(url, username, password)
    vm_ref = vm_by_name(session, vm_name)

    # anti_affinity asks the pool to keep the group's members on different hosts.
    group_ref = session.xenapi.VM_group.create({
        "name_label": group_name,
        "name_description": "Anti-affinity group created by the SDK example",
        "placement": "anti_affinity",
    })
    print("Created group:  %s" % session.xenapi.VM_group.get_uuid(group_ref))

    # Membership is written from the VM side...
    session.xenapi.VM.set_groups(vm_ref, [group_ref])

    # ...and read back from the group side, which is the half that is easy to get wrong.
    members = session.xenapi.VM_group.get_VMs(group_ref)
    print("Group members:  %d" % len(members))
    for m in members:
        print("  %s" % session.xenapi.VM.get_name_label(m))

    # VM_group.destroy already clears the group from every member VM's groups field - no need to
    # remove membership ourselves first.
    session.xenapi.VM_group.destroy(group_ref)
    print("OK: manage-vm-groups")
    session.xenapi.session.logout()
# Run it:
#   manage_vm_groups("https://xenserver", "root", password, "web-01")


# --- Snapshot & revert ----------------------------------------------------------------
def snapshot_revert(url, username, password, vm_name, snapshot_name="sdk-example-snapshot"):
    """Snapshot the named VM, then revert the VM back to that snapshot.

    Reverting to a plain snapshot always leaves the VM Halted (xapi hard-shuts-down a running VM
    before reverting it), even if it was Running a moment ago - restart it afterwards if that's
    how we found it, so the workflow actually restores what it changed."""
    session = connect(url, username, password)
    vm_ref = vm_by_name(session, vm_name)
    print("Snapshotting VM: %s" % session.xenapi.VM.get_name_label(vm_ref))
    was_running = session.xenapi.VM.get_power_state(vm_ref) == "Running"

    snap_ref = session.xenapi.VM.snapshot(vm_ref, snapshot_name)
    print("Created snapshot: %s" % session.xenapi.VM.get_uuid(snap_ref))

    # A client shows a thumbnail of what was on screen when the snapshot was taken, captured from the
    # VM's console at that moment. It is an HTTP transfer alongside the API, not an API call, so the
    # session id travels in the query string. ref names the VM's VNC (rfb) console, as XenCenter does
    # (the VM itself works too). Only a running VM has a console to capture, and a host that can't
    # reach it answers 404 or 500 instead of an image: the picture is incidental, so carry on.
    if session.xenapi.VM.get_power_state(vm_ref) == "Running":
        console = next(c for c in session.xenapi.VM.get_consoles(vm_ref)
                       if session.xenapi.console.get_protocol(c) == "rfb")
        try:
            with urllib.request.urlopen(
                    "%s/vncsnapshot?session_id=%s&ref=%s" % (url, session._session, console),
                    context=ssl._create_unverified_context()) as response:
                print("Thumbnail:      %d bytes of PNG" % len(response.read()))
        except urllib.error.HTTPError as e:
            print("Thumbnail:      none (the host answered HTTP %d)" % e.code)
    else:
        print("Thumbnail:      none (the VM is not running, so it has no console)")

    session.xenapi.VM.revert(snap_ref)
    print("Reverted VM to the snapshot.")

    if was_running:
        session.xenapi.VM.start(vm_ref, False, True)
        print("Restarted the VM (it was running before the revert).")

    # A snapshot is itself a (special) VM record, with its own snapshot disks; destroy both to
    # clean up (the source VM's disks are untouched - they are not the snapshot's).
    destroy_vm_and_disks(session, snap_ref)
    print("OK: snapshot-revert")
    session.xenapi.session.logout()
# Run it:
#   snapshot_revert("https://xenserver", "root", password, "web-01")


# --- 5. Create an NFS storage repository ------------------------------------------------
def create_nfs_sr(url, username, password, nfs_server, nfs_path, sr_name="sdk-example-nfs"):
    """Create a shared NFS SR (as the New SR wizard does), then forget it."""
    session = connect(url, username, password)
    host_ref = next(iter(session.xenapi.host.get_all_records().keys()))
    device_config = {"server": nfs_server, "serverpath": nfs_path, "nfsversion": "3"}

    sr_ref = session.xenapi.SR.create(
        host_ref, device_config, "0",
        sr_name, "NFS SR created by the SDK example",
        "nfs", "user", True, {})
    print("Created SR: %s" % session.xenapi.SR.get_uuid(sr_ref))

    detach_and_forget_sr(session, sr_ref)
    print("OK: create-nfs-sr")
    session.xenapi.session.logout()
# Run it:
#   create_nfs_sr("https://xenserver", "root", password, "192.0.2.10", "/export/sdk")


# --- 6. Create a network ----------------------------------------------------------------
def create_network(url, username, password, network_name="sdk-example-net"):
    """Create an internal network (an isolated switch with no physical NIC)."""
    session = connect(url, username, password)
    net_ref = session.xenapi.network.create({
        "name_label": network_name,
        "name_description": "Internal network created by the SDK example",
        "MTU": "1500",
        "other_config": {},
    })
    print("Created network: %s" % session.xenapi.network.get_uuid(net_ref))

    # Raise the MTU to use jumbo frames. Every NIC and switch along the path has to agree, so this is
    # a property of the network rather than of any one interface on it.
    session.xenapi.network.set_MTU(net_ref, "9000")
    print("MTU now:         %s" % session.xenapi.network.get_MTU(net_ref))

    session.xenapi.network.destroy(net_ref)
    print("OK: create-network")
    session.xenapi.session.logout()
# Run it:
#   create_network("https://xenserver", "root", password, "sdk-example-net")


# --- 7. Edit VM properties --------------------------------------------------------------
def edit_vm_properties(url, username, password, vm_name):
    """Edit the named VM's description and other_config, then restore the originals."""
    session = connect(url, username, password)
    vm_ref = vm_by_name(session, vm_name)

    original_desc = session.xenapi.VM.get_name_description(vm_ref)
    session.xenapi.VM.set_name_description(vm_ref, "Edited by the SDK example")
    session.xenapi.VM.add_to_other_config(vm_ref, "sdk_example", "true")
    print("New description: %s" % session.xenapi.VM.get_name_description(vm_ref))
    print("other_config[sdk_example] = %s" %
          session.xenapi.VM.get_other_config(vm_ref).get("sdk_example"))

    # Restore original state.
    session.xenapi.VM.set_name_description(vm_ref, original_desc)
    session.xenapi.VM.remove_from_other_config(vm_ref, "sdk_example")
    print("OK: edit-vm-properties")
    session.xenapi.session.logout()
# Run it:
#   edit_vm_properties("https://xenserver", "root", password, "web-01")


# --- 8. Event monitoring ----------------------------------------------------------------
def events(url, username, password, vm_name):
    """Watch the event stream and observe a change we make to the named VM land as an event."""
    session = connect(url, username, password)
    event_from = getattr(session.xenapi.event, "from")  # 'from' is a Python keyword

    # An empty token yields the current world and a fresh token to watch from.
    batch = event_from(["VM"], "", 1.0)
    token = batch["token"]
    print("Established event token after initial snapshot.")

    # Make a change, then poll for it.
    vm_ref = vm_by_name(session, vm_name)
    original = session.xenapi.VM.get_name_description(vm_ref)
    session.xenapi.VM.set_name_description(vm_ref, "changed-to-trigger-event")

    batch = event_from(["VM"], token, 5.0)
    print("Received %d event(s) after the change." % len(batch["events"]))
    for ev in batch["events"][:3]:
        print("  - %s %s" % (ev["operation"], ev["class"]))

    session.xenapi.VM.set_name_description(vm_ref, original)  # put it back
    print("OK: events")
    session.xenapi.session.logout()
# Run it:
#   events("https://xenserver", "root", password, "web-01")


# --- 9. New VM wizard (full) -----------------------------------------------------------
def new_vm_wizard(url, username, password, template_name, new_vm_name="wizard-vm"):
    """
    Reproduce XenCenter's New VM wizard end to end: start from the named template, name the VM,
    choose an installation source, a home server, CPU & memory, add a disk, attach a network,
    then start it.
    """
    GIB = 1024 * 1024 * 1024
    MIB = 1024 * 1024

    session = connect(url, username, password)
    # Page 1 - Template.
    template_ref = template_by_name(session, template_name)
    print("Template:      %s" % session.xenapi.VM.get_name_label(template_ref))

    # Page 2 - Name and description.
    vm = session.xenapi.VM.clone(template_ref, new_vm_name)
    session.xenapi.VM.set_name_description(vm, "Created by the full New VM wizard example")
    session.xenapi.VM.set_is_a_template(vm, False)
    print("Created VM:    %s" % session.xenapi.VM.get_uuid(vm))

    # Page 3 - Installation media (a network install repository).
    session.xenapi.VM.add_to_other_config(vm, "install-repository",
                                          "http://mirror.example.com/rocky/9/os/x86_64")
    print("Install media: network repository")

    # Page 4 - Home server (affinity).
    host_ref, host = next(iter(session.xenapi.host.get_all_records().items()))
    session.xenapi.VM.set_affinity(vm, host_ref)
    print("Home server:   %s" % host["name_label"])

    # Page 5 - CPU & Memory (memory sizes are passed as strings: they exceed XML-RPC's 32-bit int).
    session.xenapi.VM.set_VCPUs_max(vm, "2")
    session.xenapi.VM.set_VCPUs_at_startup(vm, "2")
    session.xenapi.VM.set_memory_limits(vm, str(512 * MIB), str(2 * GIB), str(2 * GIB), str(2 * GIB))
    print("CPU/memory:    2 vCPUs, 2 GiB")

    # Page 6 - Storage: add a disk on a (non-ISO) SR.
    sr_ref = next(ref for ref, r in session.xenapi.SR.get_all_records().items()
                  if r["content_type"] != "iso" and r["type"] not in ("iso", "udev"))
    vbd_device = session.xenapi.VM.get_allowed_VBD_devices(vm)[0]
    vdi = session.xenapi.VDI.create({
        "name_label": "%s disk 0" % new_vm_name,
        "name_description": "System disk created by the wizard example",
        "SR": sr_ref,
        "virtual_size": str(24 * GIB),
        "type": "system",
        "sharable": False,
        "read_only": False,
        "other_config": {},
    })
    session.xenapi.VBD.create({
        "VM": vm, "VDI": vdi, "userdevice": vbd_device, "bootable": True,
        "mode": "RW", "type": "Disk", "empty": False, "other_config": {},
        "qos_algorithm_type": "", "qos_algorithm_params": {},
    })
    print("Storage:       24 GiB disk on %s" % session.xenapi.SR.get_name_label(sr_ref))

    # Page 7 - Networking: attach a VIF to a network.
    net_ref, net = next(iter(session.xenapi.network.get_all_records().items()))
    vif_device = session.xenapi.VM.get_allowed_VIF_devices(vm)[0]
    session.xenapi.VIF.create({
        "VM": vm, "network": net_ref, "device": vif_device, "MAC": "",
        "MTU": "1500", "other_config": {},
        "qos_algorithm_type": "", "qos_algorithm_params": {},
    })
    print("Networking:    NIC on %s" % net["name_label"])

    # Page 8 - Finish: start the VM.
    session.xenapi.VM.start(vm, False, True)

    # Report the assembled VM.
    print("--- Result ---")
    print("power state:   %s" % session.xenapi.VM.get_power_state(vm))
    print("vCPUs:         %s" % session.xenapi.VM.get_VCPUs_max(vm))
    print("disks:         %d, NICs: %d" %
          (len(session.xenapi.VM.get_VBDs(vm)), len(session.xenapi.VM.get_VIFs(vm))))

    # Tidy up so the example is repeatable.
    session.xenapi.VM.hard_shutdown(vm)
    session.xenapi.VM.destroy(vm)
    session.xenapi.VDI.destroy(vdi)
    print("Cleaned up the example VM.")

    print("OK: new-vm-wizard")
    session.xenapi.session.logout()
# Run it:
#   new_vm_wizard("https://xenserver", "root", password, "Rocky Linux 8")


# --- 10. Live migrate a VM -------------------------------------------------------------
def live_migrate(url, username, password, source_vm, sr_name, new_vm_name="sdk-example-migrate"):
    """Live-migrate a running VM to another host in the pool, with no downtime. Moves a throwaway
    copy of source_vm, a VM with a guest OS and PV drivers: live migration needs the guest's
    cooperation (VM_LACKS_FEATURE without PV drivers).

    Only the VM's memory moves, so the destination host has to see its disks already: a disk on
    local storage refuses with VM_REQUIRES_SR. Put the copy's disks on the shared SR sr_name first."""
    session = connect(url, username, password)
    vm = copy_of_guest(session, source_vm, new_vm_name)
    _move_disks_to_sr(session, vm, sr_by_name(session, sr_name, shared=True))
    session.xenapi.VM.start(vm, False, True)
    wait_for_guest_agent(session, vm)

    source_host = session.xenapi.VM.get_resident_on(vm)
    print("VM is running on: %s" % session.xenapi.host.get_name_label(source_host))

    # Pick a different host in the pool to receive the VM.
    dest_host = next(ref for ref in session.xenapi.host.get_all_records()
                     if ref != source_host)

    # Check the destination can boot it, then live-migrate (empty options = default live migration).
    session.xenapi.VM.assert_can_boot_here(vm, dest_host)
    session.xenapi.VM.pool_migrate(vm, dest_host, {})

    print("Migrated to:      %s" % session.xenapi.host.get_name_label(session.xenapi.VM.get_resident_on(vm)))
    print("Still running:    %s" % session.xenapi.VM.get_power_state(vm))

    # Tidy up so the example is repeatable.
    session.xenapi.VM.hard_shutdown(vm)
    destroy_vm_and_disks(session, vm)
    print("OK: live-migrate")
    session.xenapi.session.logout()
# Run it:
#   live_migrate("https://xenserver", "root", password, "web-01", "Shared NFS")


# --- 11. Enter & exit maintenance mode -------------------------------------------------
def host_maintenance(url, username, password, source_vm, sr_name, new_vm_name="sdk-example-maint"):
    """Disable a host, evacuate its running guests to another host, then re-enable it. Pins a
    throwaway copy of source_vm to the host so evacuation has work to do. Evacuation live-migrates
    the guest, which needs its cooperation (VM_LACKS_FEATURE without PV drivers), so source_vm must
    have a guest OS with PV drivers.

    Evacuation needs somewhere else in the pool that can actually see the VM's disk - a VM whose
    only disk is on local (non-shared) storage can't be evacuated at all (VM_REQUIRES_SR), and a
    pool's installation-time default SR is commonly local storage. Put the pinned VM's disk on a
    shared SR explicitly rather than trusting whatever the pool default happens to be."""
    session = connect(url, username, password)
    # Choose a host that is not the pool coordinator, so the coordinator can receive its guests.
    master = list(session.xenapi.pool.get_all_records().values())[0]["master"]
    host_ref = next(ref for ref in session.xenapi.host.get_all_records() if ref != master)
    print("Maintenance host: %s" % session.xenapi.host.get_name_label(host_ref))

    # Pin a running VM to that host so evacuation has something to move.
    vm = copy_of_guest(session, source_vm, new_vm_name)
    _move_disks_to_sr(session, vm, sr_by_name(session, sr_name, shared=True))
    session.xenapi.VM.set_affinity(vm, host_ref)
    session.xenapi.VM.start(vm, False, True)
    wait_for_guest_agent(session, vm)
    print("Guest resident on:%s" % session.xenapi.host.get_name_label(session.xenapi.VM.get_resident_on(vm)))

    # Enter maintenance mode: disable the host, then evacuate its guests.
    session.xenapi.host.disable(host_ref)
    print("After disable:    host.enabled = %s" % session.xenapi.host.get_enabled(host_ref))
    session.xenapi.host.evacuate(host_ref)
    print("After evacuate:   guest now on %s"
          % session.xenapi.host.get_name_label(session.xenapi.VM.get_resident_on(vm)))

    # Exit maintenance mode.
    session.xenapi.host.enable(host_ref)
    print("After enable:     host.enabled = %s" % session.xenapi.host.get_enabled(host_ref))

    # Tidy up so the example is repeatable.
    session.xenapi.VM.hard_shutdown(vm)
    destroy_vm_and_disks(session, vm)
    print("OK: host-maintenance")
    session.xenapi.session.logout()
# Run it:
#   host_maintenance("https://xenserver", "root", password, "web-01", "Shared NFS")


# --- 12. Configure high availability ---------------------------------------------------
def configure_ha(url, username, password, heartbeat_sr_name):
    """Enable pool HA on the named shared heartbeat SR, then disable it again."""
    session = connect(url, username, password)
    pool_ref = list(session.xenapi.pool.get_all_records().keys())[0]

    # The HA heartbeat statefile needs a shared SR; confirm the chosen one can host it.
    sr_ref = sr_by_name(session, heartbeat_sr_name, shared=True)
    print("Heartbeat SR:  %s" % session.xenapi.SR.get_name_label(sr_ref))
    session.xenapi.SR.assert_can_host_ha_statefile(sr_ref)

    # How many host failures can the pool tolerate? Set that as the target and enable HA.
    ntol = session.xenapi.pool.ha_compute_hypothetical_max_host_failures_to_tolerate({})
    print("Max failures:  %s" % ntol)
    session.xenapi.pool.set_ha_host_failures_to_tolerate(pool_ref, ntol)
    session.xenapi.pool.enable_ha([sr_ref], {})
    print("HA enabled:    %s" % session.xenapi.pool.get_ha_enabled(pool_ref))

    # What HA does per VM. The restart priority decides which guests come back first after a host
    # failure, and whether a VM is protected at all; "restart" is protected, an empty string is not.
    guest = next(ref for ref, r in session.xenapi.VM.get_all_records().items()
                 if not r["is_a_template"] and not r["is_control_domain"] and not r["is_a_snapshot"])
    was = session.xenapi.VM.get_ha_restart_priority(guest)
    session.xenapi.VM.set_ha_restart_priority(guest, "restart")
    print("%s priority: %r -> %r"
          % (session.xenapi.VM.get_name_label(guest), was,
             session.xenapi.VM.get_ha_restart_priority(guest)))
    session.xenapi.VM.set_ha_restart_priority(guest, was)

    # And a pool-wide judgement call: if a guest shuts itself down from the inside, is that a
    # failure HA should undo, or an administrator's intent it should respect?
    internal = session.xenapi.pool.get_ha_reboot_vm_on_internal_shutdown(pool_ref)
    print("Restart on internal shutdown: %s" % internal)

    # Turn HA back off so the example is repeatable.
    session.xenapi.pool.disable_ha()
    print("HA enabled:    %s" % session.xenapi.pool.get_ha_enabled(pool_ref))
    print("OK: configure-ha")
    session.xenapi.session.logout()
# Run it:
#   configure_ha("https://xenserver", "root", password, "Shared NFS")


# --- 13. Copy a VM ---------------------------------------------------------------------
def copy_vm(url, username, password, vm_name, sr_name, copy_name="sdk-example-copy"):
    """Make a full, independent copy of the named VM onto the named SR (a deep copy of its disks).

    VM.copy (like VM.clone) only works on a Halted VM - a running source fails with
    VM_BAD_POWER_STATE - so shut it down first if it's running, and start it back up again after
    the copy, rather than assuming the VM is already halted."""
    session = connect(url, username, password)
    # A full copy needs a halted source; it places an independent set of disks on the chosen SR.
    source = vm_by_name(session, vm_name)
    sr_ref = sr_by_name(session, sr_name)
    print("Copying '%s' to SR: %s"
          % (session.xenapi.VM.get_name_label(source), session.xenapi.SR.get_name_label(sr_ref)))

    was_running = session.xenapi.VM.get_power_state(source) == "Running"
    if was_running:
        session.xenapi.VM.clean_shutdown(source)

    copy = session.xenapi.VM.copy(source, copy_name, sr_ref)
    print("Copied VM:     %s" % session.xenapi.VM.get_uuid(copy))
    print("Copy has %d VBD(s), is_a_template = %s"
          % (len(session.xenapi.VM.get_VBDs(copy)), session.xenapi.VM.get_is_a_template(copy)))

    if was_running:
        session.xenapi.VM.start(source, False, True)

    # Tidy up: destroy the copy and its disks, leaving the source VM intact.
    destroy_vm_and_disks(session, copy)
    print("Cleaned up the copied VM (left the source intact).")
    print("OK: copy-vm")
    session.xenapi.session.logout()
# Run it:
#   copy_vm("https://xenserver", "root", password, "db-01", "Shared NFS")


def _disk_vdis(session, vm_ref):
    """The VDIs backing a VM's disk VBDs (used to clean up a full copy's independent disks)."""
    vdis = []
    for vbd in session.xenapi.VM.get_VBDs(vm_ref):
        if session.xenapi.VBD.get_type(vbd) != "Disk":
            continue
        vdi = session.xenapi.VBD.get_VDI(vbd)
        if vdi != "OpaqueRef:NULL":
            vdis.append(vdi)
    return vdis


def destroy_vm_and_disks(session, vm_ref):
    """Destroy a VM (or snapshot, or template) this example made, and the disks it owns.

    VM.destroy removes only the VM record, not its disks, so every workflow that created a VM
    (or a snapshot/checkpoint of one) and is tidying up after itself needs to destroy the backing
    VDIs too - exactly what delete-vm does by hand. A checkpoint (or a suspended VM) also owns a
    suspend image holding its memory, which no VBD points at: destroy that as well."""
    vdis = _disk_vdis(session, vm_ref)
    suspend_vdi = session.xenapi.VM.get_suspend_VDI(vm_ref)
    if suspend_vdi != "OpaqueRef:NULL":
        vdis.append(suspend_vdi)
    session.xenapi.VM.destroy(vm_ref)
    for vdi in vdis:
        session.xenapi.VDI.destroy(vdi)


# --- 14. Create a VM with a vGPU ------------------------------------------------------
def create_vm_with_vgpu(url, username, password, template_name, new_vm_name="sdk-example-vgpu-vm"):
    """Provision a VM from a template and assign it a virtual GPU (VGPU.create)."""
    session = connect(url, username, password)
    # Find a GPU group that offers a real (non-passthrough) vGPU type, plus that type.
    group_ref, vgpu_type_ref = gpu_group_with_vgpu_type(session)
    type_rec = session.xenapi.VGPU_type.get_record(vgpu_type_ref)
    print("Using vGPU type: %s (%d MB framebuffer)"
          % (type_rec["model_name"], int(type_rec["framebuffer_size"]) // (1024 * 1024)))

    # Provision a fresh VM from the template to attach the vGPU to.
    template_ref = template_by_name(session, template_name)
    vm_ref = session.xenapi.VM.clone(template_ref, new_vm_name)
    provision(session, vm_ref)

    # Assign the vGPU: device "0" is the VM's first vGPU slot, other_config is empty. This is the
    # same call XenCenter makes from the New VM wizard's GPU page and the VM Properties GPU page.
    vgpu_ref = session.xenapi.VGPU.create(vm_ref, group_ref, "0", {}, vgpu_type_ref)
    print("Created vGPU: %s" % session.xenapi.VGPU.get_uuid(vgpu_ref))

    # Read the assignment back, as XenCenter's GPU tab does.
    vgpus = session.xenapi.VM.get_VGPUs(vm_ref)
    assigned = session.xenapi.VGPU_type.get_model_name(session.xenapi.VGPU.get_type(vgpus[0]))
    print("VM now has %d vGPU(s); type = %s" % (len(vgpus), assigned))

    # Tidy up so the example is repeatable.
    session.xenapi.VGPU.destroy(vgpu_ref)
    destroy_vm_and_disks(session, vm_ref)
    print("Cleaned up the example VM and its vGPU.")
    print("OK: create-vm-with-vgpu")
    session.xenapi.session.logout()
# Run it:
#   create_vm_with_vgpu("https://xenserver", "root", password, "Rocky Linux 8")


def gpu_group_with_vgpu_type(session):
    """Find a (GPU_group, VGPU_type) pair where the group offers a non-passthrough vGPU type."""
    for group, r in session.xenapi.GPU_group.get_all_records().items():
        if not r["PGPUs"]:
            continue
        for type_ref in r["supported_VGPU_types"]:
            if session.xenapi.VGPU_type.get_model_name(type_ref) != "passthrough":
                return group, type_ref
    raise RuntimeError("no GPU group offers a vGPU type")


# --- 15. Tag and organize objects -----------------------------------------------------
def tags_and_folders(url, username, password, vm_name):
    """Tag a VM and a host, and place the VM in a folder — the data behind Objects-by-Tag/Folder."""
    session = connect(url, username, password)
    vm = vm_by_name(session, vm_name)
    host = session.xenapi.host.get_all()[0]

    # Tags work on any object type (VM, host, SR, network, …).
    session.xenapi.VM.add_tags(vm, "web")
    session.xenapi.host.add_tags(host, "gold")
    print("VM tags:   %s" % session.xenapi.VM.get_tags(vm))
    print("Host tags: %s" % session.xenapi.host.get_tags(host))

    # Folder placement lives in other_config["folder"] as a leading-slash path.
    session.xenapi.VM.add_to_other_config(vm, "folder", "/Production/Web")
    print("VM folder: %s" % session.xenapi.VM.get_other_config(vm).get("folder"))

    # Tidy up.
    session.xenapi.VM.remove_tags(vm, "web")
    session.xenapi.host.remove_tags(host, "gold")
    session.xenapi.VM.remove_from_other_config(vm, "folder")
    print("OK: tags-and-folders")
    session.xenapi.session.logout()
# Run it:
#   tags_and_folders("https://xenserver", "root", password, "web-01")


# --- 16. Configure updates (CDN) ------------------------------------------------------
def introduce_update_repositories(session, repo_url, source_url):
    """Introduce the pool's update repositories the way XenCenter does: the release's base packages
    (update=False) and its update stream (update=True, which pool.sync_updates needs - otherwise
    NO_REPOSITORY_ENABLED). A real host checks the URLs (INVALID_BASE_URL for an unknown domain), so
    these are the XenServer CDN's, e.g. https://repo.ops.xenserver.com/xs9/{base,normal}."""
    return [session.xenapi.Repository.introduce(
                "sdk-example-%s" % stage, "SDK example %s repository" % stage,
                "%s/%s" % (repo_url, stage), "%s/%s" % (source_url, stage), stage != "base", "")
            for stage in ("base", "normal")]


def configure_updates(url, username, password, repo_url, source_url):
    """Point the pool at the CDN's repositories and enable automatic update sync."""
    session = connect(url, username, password)
    repos = introduce_update_repositories(session, repo_url, source_url)
    print("Introduced repositories: %s"
          % ", ".join(session.xenapi.Repository.get_name_label(r) for r in repos))

    pool = session.xenapi.pool.get_all()[0]
    # Remember the pool's own repositories, to put them back afterwards.
    previous = session.xenapi.pool.get_repositories(pool)
    session.xenapi.pool.set_repositories(pool, repos)
    session.xenapi.pool.set_update_sync_enabled(pool, True)
    print("Pool repositories: %d; auto-sync enabled: %s"
          % (len(session.xenapi.pool.get_repositories(pool)),
             session.xenapi.pool.get_update_sync_enabled(pool)))

    # Tidy up so the example is repeatable.
    session.xenapi.pool.set_update_sync_enabled(pool, False)
    session.xenapi.pool.set_repositories(pool, previous)
    for repo in repos:
        session.xenapi.Repository.forget(repo)
    print("OK: configure-updates")
    session.xenapi.session.logout()
# Run it:
#   configure_updates("https://xenserver", "root", password, "https://repo.ops.xenserver.com/xs9",
#       "https://repo-src.ops.xenserver.com/xs9")


# --- 17. Clone a VM (fast, copy-on-write) ---------------------------------------------
def clone_vm(url, username, password, vm_name, clone_name="sdk-example-clone"):
    """Fast copy-on-write clone of a halted VM (unlike Copy, which is a full, independent copy
    onto a chosen SR). Ideal for duplicating a halted "golden" VM on the same SR."""
    session = connect(url, username, password)
    source = vm_by_name(session, vm_name)
    clone = session.xenapi.VM.clone(source, clone_name)
    print("Cloned '%s' -> %s"
          % (session.xenapi.VM.get_name_label(source), session.xenapi.VM.get_name_label(clone)))
    print("Clone has %d VBD(s)" % len(session.xenapi.VM.get_VBDs(clone)))

    # Tidy up: destroy the clone and its (owned) disks.
    destroy_vm_and_disks(session, clone)
    print("OK: clone-vm")
    session.xenapi.session.logout()
# Run it:
#   clone_vm("https://xenserver", "root", password, "db-01")


# --- 18. Delete a VM ------------------------------------------------------------------
def delete_vm(url, username, password, template_name, new_vm_name="sdk-example-delete"):
    """Make a throwaway VM, then delete it: VM.destroy removes the VM but leaves its disks, so the
    owned VDIs are destroyed explicitly afterward — exactly what XenCenter's Delete VM does."""
    session = connect(url, username, password)
    vm = session.xenapi.VM.clone(template_by_name(session, template_name), new_vm_name)
    provision(session, vm)
    uuid = session.xenapi.VM.get_uuid(vm)
    vdis = _disk_vdis(session, vm)
    print("Deleting VM %s with %d disk(s)" % (uuid, len(vdis)))

    session.xenapi.VM.destroy(vm)
    for vdi in vdis:
        session.xenapi.VDI.destroy(vdi)

    still_there = any(r["uuid"] == uuid for r in session.xenapi.VM.get_all_records().values())
    print("VM still present: %s" % still_there)
    print("OK: delete-vm")
    session.xenapi.session.logout()
# Run it:
#   delete_vm("https://xenserver", "root", password, "Rocky Linux 8")


# --- 19. Storage live-migration (move a disk to another SR) ---------------------------
def storage_migrate(url, username, password, source_vm, new_vm_name="sdk-example-storagemigrate"):
    """Relocate a running VM's disk to a different SR without stopping it (live storage migration)
    with VDI.pool_migrate.

    Moving a running VM's disk needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers),
    so this works on a throwaway copy of source_vm, a VM with a guest OS and PV drivers. (A halted
    VM's disk moves too, without the guest; what VDI.pool_migrate always needs is a VM to move the
    disk for - a VDI no VBD points at fails VDI_NEEDS_VM_FOR_MIGRATE.)"""
    session = connect(url, username, password)
    vm = copy_of_guest(session, source_vm, new_vm_name)
    session.xenapi.VM.start(vm, False, True)
    wait_for_guest_agent(session, vm)
    vdi = _disk_vdis(session, vm)[0]
    source_sr = session.xenapi.VDI.get_SR(vdi)
    print("Disk is on SR: %s" % session.xenapi.SR.get_name_label(source_sr))

    # Pick a different SR that holds disks and that the VM's host can reach (an attached PBD there).
    host = session.xenapi.VM.get_resident_on(vm)
    dest_sr = next(ref for ref, r in session.xenapi.SR.get_all_records().items()
                   if ref != source_sr and r["content_type"] != "iso" and r["type"] not in ("iso", "udev")
                   and any(session.xenapi.PBD.get_host(pbd) == host
                           and session.xenapi.PBD.get_currently_attached(pbd) for pbd in r["PBDs"]))
    # pool_migrate returns the disk's new VDI: the copy on the destination SR replaces the original.
    vdi = session.xenapi.VDI.pool_migrate(vdi, dest_sr, {})

    now_on = session.xenapi.VDI.get_SR(vdi)
    print("Disk moved to:  %s" % session.xenapi.SR.get_name_label(now_on))

    # Tidy up: the VM and the disks it now owns.
    session.xenapi.VM.hard_shutdown(vm)
    destroy_vm_and_disks(session, vm)
    print("OK: storage-migrate")
    session.xenapi.session.logout()
# Run it:
#   storage_migrate("https://xenserver", "root", password, "web-01")


# --- 20. Apply updates from the CDN ---------------------------------------------------
def apply_update(url, username, password, repo_url, source_url):
    """Sync the pool's update metadata from the CDN, then apply the synced updates to each host.

    pool.sync_updates needs at least one repository with update=True enabled
    (NO_REPOSITORY_ENABLED otherwise) - introduce and attach a throwaway one, and forget it again
    afterwards. Applying a batch whose mandatory guidance needs an evacuation fails with
    HOST_EVACUATION_IS_REQUIRED unless the host's resident VMs are moved off first; handle that
    rather than assuming an update batch never asks for one, and resolve any pending mandatory
    guidance before finishing (it would otherwise block the next apply_updates on that host with
    HOST_PENDING_MANDATORY_GUIDANCES_NOT_EMPTY)."""
    session = connect(url, username, password)
    pool = session.xenapi.pool.get_all()[0]
    repos = introduce_update_repositories(session, repo_url, source_url)
    # Remember the pool's own repositories, to put them back afterwards.
    previous = session.xenapi.pool.get_repositories(pool)
    session.xenapi.pool.set_repositories(pool, repos)
    try:
        # Sync the pool's update metadata; the returned hash identifies the synced set.
        hash_ = session.xenapi.pool.sync_updates(pool, False, "", "")
        print("Synced updates; hash length %d" % len(hash_))

        # Apply the synced updates to each host. XenCenter then reads the reboot guidance to decide
        # whether a Rolling Pool Upgrade reboot is needed.
        for host_ref, host in session.xenapi.host.get_all_records().items():
            try:
                session.xenapi.host.apply_updates(host_ref, hash_)
            except XenAPI.Failure as e:
                if e.details[0] != "HOST_EVACUATION_IS_REQUIRED":
                    raise
                print("  %s: needs evacuating first; evacuating and retrying" % host["name_label"])
                session.xenapi.host.disable(host_ref)
                session.xenapi.host.evacuate(host_ref)
                session.xenapi.host.apply_updates(host_ref, hash_)
                session.xenapi.host.enable(host_ref)
            guidance = session.xenapi.host.get_pending_guidances(host_ref)
            print("  %s: applied; pending guidance = [%s]" % (host["name_label"], ", ".join(guidance)))
            if "reboot_host" in guidance or "restart_toolstack" in guidance:
                # As in rolling-pool-update: either restart returns before it has happened, and the
                # coordinator's takes this session with it - so wait for it, reconnecting.
                key = "boot_time" if "reboot_host" in guidance else "agent_start_time"
                before = session.xenapi.host.get_other_config(host_ref).get(key)
                if key == "boot_time":
                    session.xenapi.host.reboot(host_ref)
                else:
                    session.xenapi.host.restart_agent(host_ref)
                session = _wait_for_restart(url, username, password, host["uuid"], key, before)
            # apply_updates disables the host while it works (auto_enable: a restart puts it back) - with
            # no restart to do, nothing re-enables it. Return it to service either way.
            _enable_when_booted(session.xenapi, host_ref)
    finally:
        session.xenapi.pool.set_repositories(pool, previous)
        for repo in repos:
            session.xenapi.Repository.forget(repo)
    print("OK: apply-update")
    session.xenapi.session.logout()
# Run it:
#   apply_update("https://xenserver", "root", password, "https://repo.ops.xenserver.com/xs9",
#       "https://repo-src.ops.xenserver.com/xs9")


# --- 21. Checkpoint & revert ----------------------------------------------------------
def checkpoint_vm(url, username, password, source_vm, new_vm_name="sdk-example-checkpoint"):
    """A checkpoint captures disk AND memory (unlike a plain snapshot), so the VM must be running.
    Checkpoint a throwaway copy of a VM with a guest OS, then revert it back to that checkpoint.

    Checkpointing needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers), hence a copy
    of source_vm - a VM with a guest OS and PV drivers - rather than an OS-less template clone."""
    session = connect(url, username, password)
    vm = copy_of_guest(session, source_vm, new_vm_name)
    session.xenapi.VM.start(vm, False, True)
    wait_for_guest_agent(session, vm)

    checkpoint = session.xenapi.VM.checkpoint(vm, "sdk-example-checkpoint-1")
    print("Created checkpoint: %s" % session.xenapi.VM.get_uuid(checkpoint))
    print("is_a_snapshot = %s" % session.xenapi.VM.get_is_a_snapshot(checkpoint))

    session.xenapi.VM.revert(checkpoint)
    # A checkpoint's own power_state is always Suspended (it captures memory as well as disk), and
    # VM.revert restores exactly that - so the VM is Suspended here, not Running as it was before
    # the checkpoint, with a suspend_VDI holding the checkpoint's memory image. VM.resume clears
    # that: destroying a Suspended VM directly (as a bare "if Running: hard_shutdown" check would,
    # since the VM is never Running here) leaves that suspend_VDI behind as a storage leak.
    print("Reverted the VM to the checkpoint; power state now: %s"
          % session.xenapi.VM.get_power_state(vm))
    session.xenapi.VM.resume(vm, False, True)

    # Tidy up. The checkpoint owns its own snapshot disks, separate from the VM's.
    destroy_vm_and_disks(session, checkpoint)
    session.xenapi.VM.hard_shutdown(vm)
    destroy_vm_and_disks(session, vm)
    print("OK: checkpoint-vm")
    session.xenapi.session.logout()
# Run it:
#   checkpoint_vm("https://xenserver", "root", password, "web-01")


# --- 22. Attach a new disk to a VM ----------------------------------------------------
def attach_disk(url, username, password, template_name, sr_name, new_vm_name="sdk-example-attachdisk"):
    """Provision a VM, then create a fresh VDI on the named SR and attach it as a new virtual disk."""
    GIB = 1024 * 1024 * 1024
    session = connect(url, username, password)
    vm = session.xenapi.VM.clone(template_by_name(session, template_name), new_vm_name)
    provision(session, vm)
    sr_ref = sr_by_name(session, sr_name)

    vdi = session.xenapi.VDI.create({
        "name_label": "sdk-example-data-disk",
        "SR": sr_ref,
        "virtual_size": str(8 * GIB),
        "type": "user",
        "sharable": False,
        "read_only": False,
        "other_config": {},
    })
    device = session.xenapi.VM.get_allowed_VBD_devices(vm)[0]
    session.xenapi.VBD.create({
        "VM": vm, "VDI": vdi, "userdevice": device,
        "bootable": False,
        "mode": "RW", "type": "Disk", "empty": False, "other_config": {},
        "qos_algorithm_type": "", "qos_algorithm_params": {},
    })
    print("Attached an 8 GiB disk on %s as device %s"
          % (session.xenapi.SR.get_name_label(sr_ref), device))
    print("VM now has %d VBD(s)" % len(session.xenapi.VM.get_VBDs(vm)))

    # Tidy up: destroy the VM (which removes its VBDs) and then its disks (VM.destroy leaves VDIs
    # behind), including the one just attached.
    destroy_vm_and_disks(session, vm)
    print("OK: attach-disk")
    session.xenapi.session.logout()
# Run it:
#   attach_disk("https://xenserver", "root", password, "Rocky Linux 8", "Shared NFS")


# --- 23. Drive an asynchronous task ---------------------------------------------------
def wait_for_task(url, username, password, template_name, new_vm_name="sdk-example-asynctask"):
    """Every message has an Async.* twin that returns a Task ref immediately; poll it to completion."""
    session = connect(url, username, password)
    task = session.xenapi.Async.VM.clone(template_by_name(session, template_name), new_vm_name)
    print("Started task: %s" % session.xenapi.task.get_uuid(task))

    while session.xenapi.task.get_status(task) == "pending":
        print("  progress: %.0f%%" % (session.xenapi.task.get_progress(task) * 100))
        time.sleep(0.2)
    print("Task status: %s" % session.xenapi.task.get_status(task))

    # The result of an object-creating task is <value>OpaqueRef:...</value>.
    result = session.xenapi.task.get_result(task)
    vm_ref = result.replace("<value>", "").replace("</value>", "").strip()
    print("Task produced VM: %s" % session.xenapi.VM.get_name_label(vm_ref))

    # Tidy up.
    session.xenapi.VM.destroy(vm_ref)
    session.xenapi.task.destroy(task)
    print("OK: wait-for-task")
    session.xenapi.session.logout()
# Run it:
#   wait_for_task("https://xenserver", "root", password, "Rocky Linux 8")


# --- 24. Handle an API error ----------------------------------------------------------
def error_handling(url, username, password):
    """XenAPI errors surface as a XenAPI.Failure whose details are [CODE, param1, param2, ...]."""
    session = connect(url, username, password)
    try:
        session.xenapi.host.get_by_uuid("this-uuid-does-not-exist")
        print("unexpected: no error")
    except XenAPI.Failure as f:
        print("Caught expected failure: %s" % f.details[0])
        print("Short message: %s" % f)
    print("OK: error-handling")
    session.xenapi.session.logout()
# Run it:
#   error_handling("https://xenserver", "root", password)


# --- 25. List templates ---------------------------------------------------------------
def list_templates(url, username, password):
    """List the pool's templates, flagging the built-in (default) ones."""
    session = connect(url, username, password)
    templates = sorted((v for v in session.xenapi.VM.get_all_records().values() if v["is_a_template"]),
                       key=lambda v: v["name_label"])
    print("Templates (%d):" % len(templates))
    for t in templates[:8]:
        is_default = "default_template" in t["other_config"]
        print("  - %s%s" % (t["name_label"], " [built-in]" if is_default else ""))
    print("OK: list-templates")
    session.xenapi.session.logout()
# Run it:
#   list_templates("https://xenserver", "root", password)


# --- 26. Custom fields ----------------------------------------------------------------
def custom_fields(url, username, password, vm_name):
    """XenCenter's custom fields are stored in other_config under "XenCenter.CustomFields.<name>"."""
    session = connect(url, username, password)
    vm = vm_by_name(session, vm_name)
    key = "XenCenter.CustomFields.Owner"
    session.xenapi.VM.add_to_other_config(vm, key, "Platform Team")
    print("Custom field Owner = %s" % session.xenapi.VM.get_other_config(vm)[key])

    session.xenapi.VM.remove_from_other_config(vm, key)
    print("OK: custom-fields")
    session.xenapi.session.logout()
# Run it:
#   custom_fields("https://xenserver", "root", password, "web-01")


# --- 27. GPU inventory ----------------------------------------------------------------
def gpu_inventory(url, username, password):
    """Take an inventory of the pool's GPU groups: their pGPUs and the vGPU types they support."""
    session = connect(url, username, password)
    groups = session.xenapi.GPU_group.get_all_records()
    print("GPU groups (%d):" % len(groups))
    for group in groups.values():
        types = [session.xenapi.VGPU_type.get_model_name(t) for t in group["supported_VGPU_types"]]
        print("  - %s: %d pGPU(s), vGPU types: %s"
              % (group["name_label"], len(group["PGPUs"]), ", ".join(types)))
    # How the pool spreads vGPUs across the physical GPUs in a group: depth-first packs each pGPU
    # full before using the next, breadth-first spreads them out.
    group_ref = list(groups.keys())[0]
    before = session.xenapi.GPU_group.get_allocation_algorithm(group_ref)
    session.xenapi.GPU_group.set_allocation_algorithm(group_ref, "breadth_first")
    print("Allocation:      %s -> %s"
          % (before, session.xenapi.GPU_group.get_allocation_algorithm(group_ref)))
    session.xenapi.GPU_group.set_allocation_algorithm(group_ref, before)
    print("OK: gpu-inventory")
    session.xenapi.session.logout()
# Run it:
#   gpu_inventory("https://xenserver", "root", password)


# --- 28. Read host & VM metrics -------------------------------------------------------
def read_metrics(url, username, password):
    """Read live capacity metrics off a host and a running VM (Host_metrics / VM_metrics)."""
    MIB = 1024 * 1024
    session = connect(url, username, password)
    host_ref, host = next(iter(session.xenapi.host.get_all_records().items()))
    hm = session.xenapi.host.get_metrics(host_ref)
    print("Host %s: %d MiB total, %d MiB free, live = %s"
          % (host["name_label"],
             int(session.xenapi.host_metrics.get_memory_total(hm)) // MIB,
             int(session.xenapi.host.compute_free_memory(host_ref)) // MIB,
             session.xenapi.host_metrics.get_live(hm)))

    vm = next(ref for ref, r in session.xenapi.VM.get_all_records().items()
              if not r["is_a_template"] and not r["is_control_domain"]
              and r["power_state"] == "Running")
    vmm = session.xenapi.VM.get_metrics(vm)
    print("VM %s: %s vCPU(s), %d MiB"
          % (session.xenapi.VM.get_name_label(vm),
             session.xenapi.VM_metrics.get_VCPUs_number(vmm),
             int(session.xenapi.VM_metrics.get_memory_actual(vmm)) // MIB))
    print("OK: read-metrics")
    session.xenapi.session.logout()
# Run it:
#   read_metrics("https://xenserver", "root", password)


# --- 29. Rename an object -------------------------------------------------------------
def rename_object(url, username, password, vm_name):
    """Rename the named VM, then restore its original name so the example is repeatable."""
    session = connect(url, username, password)
    vm = vm_by_name(session, vm_name)
    original = session.xenapi.VM.get_name_label(vm)
    session.xenapi.VM.set_name_label(vm, "sdk-renamed")
    print("Renamed '%s' -> '%s'" % (original, session.xenapi.VM.get_name_label(vm)))
    session.xenapi.VM.set_name_label(vm, original)  # restore so the example is repeatable
    print("OK: rename-object")
    session.xenapi.session.logout()
# Run it:
#   rename_object("https://xenserver", "root", password, "web-01")


# --- 30. VM boot configuration --------------------------------------------------------
def vm_boot_config(url, username, password, template_name, new_vm_name="sdk-example-boot"):
    """Provision a throwaway VM, then set its vCPU counts and boot order (HVM_boot_params)."""
    session = connect(url, username, password)
    vm = session.xenapi.VM.clone(template_by_name(session, template_name), new_vm_name)
    provision(session, vm)

    session.xenapi.VM.set_VCPUs_max(vm, "4")
    session.xenapi.VM.set_VCPUs_at_startup(vm, "2")
    print("vCPUs: %s/%s" %
          (session.xenapi.VM.get_VCPUs_at_startup(vm), session.xenapi.VM.get_VCPUs_max(vm)))

    # Boot mode: firmware ("bios"/"uefi") lives in HVM_boot_params; Secure Boot in
    # platform["secureboot"]. "auto" (not a hard-coded "true") is the real xe/XenCenter
    # convention: xapi resolves it against whether the pool actually holds Secure Boot
    # certificates, at VM.start time - a hard "true" would claim Secure Boot is on even on a
    # template that was never set up for it, since set_platform does no validation of its own.
    session.xenapi.VM.set_HVM_boot_params(vm, {"order": "cdn", "firmware": "uefi"})
    platform = session.xenapi.VM.get_platform(vm)
    platform["secureboot"] = "auto"
    session.xenapi.VM.set_platform(vm, platform)
    print("Boot order: %s" % session.xenapi.VM.get_HVM_boot_params(vm)["order"])
    print("Boot mode: firmware=%s, secureboot=%s (resolved against pool certificates at boot)" %
          (session.xenapi.VM.get_HVM_boot_params(vm)["firmware"],
           session.xenapi.VM.get_platform(vm)["secureboot"]))

    destroy_vm_and_disks(session, vm)
    print("OK: vm-boot-config")
    session.xenapi.session.logout()
# Run it:
#   vm_boot_config("https://xenserver", "root", password, "Rocky Linux 8")


# --- 31. Host information -------------------------------------------------------------
def host_info(url, username, password):
    """Read a host's identity: product version, edition and CPU topology."""
    session = connect(url, username, password)
    host = next(iter(session.xenapi.host.get_all_records().values()))
    sw = host["software_version"]
    cpu = host["cpu_info"]
    print("Host:     %s" % host["name_label"])
    print("Version:  %s" % sw.get("product_version", "?"))
    print("Edition:  %s" % host["edition"])
    print("CPUs:     %s across %s socket(s)"
          % (cpu.get("cpu_count", "?"), cpu.get("socket_count", "?")))

    # The physical identity, straight off the host's DMI/SMBIOS tables. The serial number is what you
    # quote to the hardware vendor, so it is the one field here that identifies this machine and not
    # just its model.
    bios = host["bios_strings"]
    print("Hardware: %s %s" % (bios.get("system-manufacturer", "?"),
                               bios.get("system-product-name", "?")))
    print("Serial:   %s" % bios.get("system-serial-number", "?"))
    print("BIOS:     %s" % bios.get("bios-version", "?"))
    print("OK: host-info")
    session.xenapi.session.logout()
# Run it:
#   host_info("https://xenserver", "root", password)


# --- 32. List roles ------------------------------------------------------------------
def list_roles(url, username, password):
    """List the RBAC roles (the one class XenCenter still bulk-downloads)."""
    session = connect(url, username, password)
    # Note the class is lowercase 'role' in the binding. Role records include every permission too; the
    # roles a user can be granted are the ones made of permissions (non-empty subroles), as xe role-list shows.
    roles = sorted({r["name_label"] for r in session.xenapi.role.get_all_records().values() if r["subroles"]})
    print("Roles (%d): %s" % (len(roles), ", ".join(roles[:8])))
    print("OK: list-roles")
    session.xenapi.session.logout()
# Run it:
#   list_roles("https://xenserver", "root", password)


# --- 33. Pool properties -------------------------------------------------------------
def pool_properties(url, username, password):
    """Read the pool's name and default SR, rename the pool, then restore the name."""
    session = connect(url, username, password)
    pool_ref = session.xenapi.pool.get_all()[0]
    original = session.xenapi.pool.get_name_label(pool_ref)
    default_sr = session.xenapi.pool.get_default_SR(pool_ref)
    print("Pool:       '%s'" % original)
    print("Default SR: %s"
          % ("(none)" if default_sr == "OpaqueRef:NULL"
             else session.xenapi.SR.get_name_label(default_sr)))

    session.xenapi.pool.set_name_label(pool_ref, "sdk-pool-renamed")
    print("Renamed to: '%s'" % session.xenapi.pool.get_name_label(pool_ref))
    session.xenapi.pool.set_name_label(pool_ref, original)  # restore
    print("OK: pool-properties")
    session.xenapi.session.logout()
# Run it:
#   pool_properties("https://xenserver", "root", password)


# --- 34. Storage repository usage ----------------------------------------------------
def sr_usage(url, username, password):
    """Report each real SR's used/total space, then rescan one to refresh its utilisation."""
    GIB = 1024 * 1024 * 1024
    session = connect(url, username, password)
    srs = sorted(session.xenapi.SR.get_all_records().values(), key=lambda s: s["name_label"])
    for sr in srs:
        if int(sr["physical_size"]) <= 0:
            continue  # skip ISO/DVD pseudo-SRs
        print("  %s: %d / %d GiB used"
              % (sr["name_label"],
                 int(sr["physical_utilisation"]) // GIB, int(sr["physical_size"]) // GIB))

    # A rescan refreshes an SR's utilisation from its backend.
    scan_me = next(ref for ref, r in session.xenapi.SR.get_all_records().items()
                   if int(r["physical_size"]) > 0)
    session.xenapi.SR.scan(scan_me)

    # Read caching keeps recently-read blocks in the host's memory. It is switched off per SR by
    # setting o_direct, which asks the storage layer to bypass the cache entirely.
    session.xenapi.SR.remove_from_other_config(scan_me, "o_direct")
    session.xenapi.SR.add_to_other_config(scan_me, "o_direct", "true")
    print("  read caching on %s: %s"
          % (session.xenapi.SR.get_name_label(scan_me),
             "off" if session.xenapi.SR.get_other_config(scan_me).get("o_direct") == "true" else "on"))
    session.xenapi.SR.remove_from_other_config(scan_me, "o_direct")
    print("OK: sr-usage")
    session.xenapi.session.logout()
# Run it:
#   sr_usage("https://xenserver", "root", password)


# --- 35. Manage a VM's network interfaces --------------------------------------------
def manage_vif(url, username, password, template_name, new_vm_name="sdk-example-vif"):
    """Provision a throwaway VM, attach a VIF to the first network, then tear it all down."""
    session = connect(url, username, password)
    vm = session.xenapi.VM.clone(template_by_name(session, template_name), new_vm_name)
    provision(session, vm)
    net_ref = session.xenapi.network.get_all()[0]
    device = session.xenapi.VM.get_allowed_VIF_devices(vm)[0]

    vif = session.xenapi.VIF.create({
        "VM": vm, "network": net_ref, "device": device, "MAC": "",
        "MTU": "1500", "other_config": {},
        "qos_algorithm_type": "", "qos_algorithm_params": {},
    })
    print("Attached a VIF on device %s; VM now has %d NIC(s)"
          % (device, len(session.xenapi.VM.get_VIFs(vm))))

    session.xenapi.VIF.destroy(vif)
    destroy_vm_and_disks(session, vm)
    print("OK: manage-vif")
    session.xenapi.session.logout()
# Run it:
#   manage_vif("https://xenserver", "root", password, "Rocky Linux 8")


# --- 36. List networks ---------------------------------------------------------------
def list_networks(url, username, password):
    """List the pool's networks with their attached PIF and VIF counts."""
    session = connect(url, username, password)
    nets = sorted(session.xenapi.network.get_all_records().values(), key=lambda n: n["name_label"])
    print("Networks (%d):" % len(nets))
    for net in nets:
        print("  - %s: %d PIF(s), %d VIF(s)"
              % (net["name_label"], len(net["PIFs"]), len(net["VIFs"])))
    print("OK: list-networks")
    session.xenapi.session.logout()
# Run it:
#   list_networks("https://xenserver", "root", password)


# --- 37. Inventory a VM's disks ------------------------------------------------------
def vbd_inventory(url, username, password, vm_name):
    """List the named VM's disk VBDs and the size of each backing VDI."""
    GIB = 1024 * 1024 * 1024
    session = connect(url, username, password)
    vm = vm_by_name(session, vm_name)
    print("Disks of '%s':" % session.xenapi.VM.get_name_label(vm))
    for vbd in session.xenapi.VM.get_VBDs(vm):
        if session.xenapi.VBD.get_type(vbd) != "Disk":
            continue
        vdi = session.xenapi.VBD.get_VDI(vbd)
        size = 0 if vdi == "OpaqueRef:NULL" else int(session.xenapi.VDI.get_virtual_size(vdi)) // GIB
        print("  - device %s: %d GiB" % (session.xenapi.VBD.get_userdevice(vbd), size))
    print("OK: vbd-inventory")
    session.xenapi.session.logout()
# Run it:
#   vbd_inventory("https://xenserver", "root", password, "db-01")


# --- 38. Tag the pool ----------------------------------------------------------------
def pool_tags(url, username, password):
    """Add a tag to the pool, read it back, then remove it so the example is repeatable."""
    session = connect(url, username, password)
    pool_ref = session.xenapi.pool.get_all()[0]
    session.xenapi.pool.add_tags(pool_ref, "sdk-managed")
    print("Pool tags: %s" % ", ".join(session.xenapi.pool.get_tags(pool_ref)))
    session.xenapi.pool.remove_tags(pool_ref, "sdk-managed")
    print("OK: pool-tags")
    session.xenapi.session.logout()
# Run it:
#   pool_tags("https://xenserver", "root", password)


# --- 39. Convert a VM to a template --------------------------------------------------
def convert_to_template(url, username, password, template_name, new_vm_name="sdk-example-totemplate"):
    """Provision a real VM, convert it into a custom template, then destroy it."""
    session = connect(url, username, password)
    vm = session.xenapi.VM.clone(template_by_name(session, template_name), new_vm_name)
    provision(session, vm)  # now a real (halted) VM
    print("is_a_template after provision: %s" % session.xenapi.VM.get_is_a_template(vm))

    # Converting a VM to a custom template is a one-way operation.
    session.xenapi.VM.set_is_a_template(vm, True)
    print("is_a_template after convert:  %s" % session.xenapi.VM.get_is_a_template(vm))

    destroy_vm_and_disks(session, vm)
    print("OK: convert-to-template")
    session.xenapi.session.logout()
# Run it:
#   convert_to_template("https://xenserver", "root", password, "Rocky Linux 8")


# --- 40. Look up an object by UUID ---------------------------------------------------
def find_by_uuid(url, username, password, vm_name):
    """Resolve a VM's UUID back to a (session-scoped) ref, as persisted identifiers do."""
    session = connect(url, username, password)
    vm = vm_by_name(session, vm_name)
    uuid = session.xenapi.VM.get_uuid(vm)
    resolved = session.xenapi.VM.get_by_uuid(uuid)
    print("UUID %s resolves to %s" % (uuid, session.xenapi.VM.get_name_label(resolved)))
    print("Same object: %s" % (resolved == vm))
    print("OK: find-by-uuid")
    session.xenapi.session.logout()
# Run it:
#   find_by_uuid("https://xenserver", "root", password, "web-01")


# --- 41. Rolling pool update ---------------------------------------------------------
def rolling_pool_update(url, username, password, repo_url, source_url):
    """Apply the CDN's updates host-by-host so the pool never goes fully offline.

    Needs an enabled update repository the same way apply-update does - introduce and attach a
    throwaway one, forget it again afterwards. Modern xapi (>=23.18.0) doesn't reboot a host for
    you: it only records pending_guidances, so only reboot (or restart the toolstack) when the
    applied batch actually asks for it."""
    session = connect(url, username, password)
    pool = session.xenapi.pool.get_all()[0]
    repos = introduce_update_repositories(session, repo_url, source_url)
    # Remember the pool's own repositories, to put them back afterwards.
    previous = session.xenapi.pool.get_repositories(pool)
    session.xenapi.pool.set_repositories(pool, repos)
    try:
        hash_ = session.xenapi.pool.sync_updates(pool, False, "", "")
        print("Synced updates; hash length %d" % len(hash_))

        # The rolling pattern behind XenCenter's automated Install Updates:
        # disable -> evacuate -> apply -> reboot (only if asked) -> re-enable, one host at a time.
        for host_ref, host in session.xenapi.host.get_all_records().items():
            print("Updating %s:" % host["name_label"])
            session.xenapi.host.disable(host_ref)               # stop new VMs landing here
            session.xenapi.host.evacuate(host_ref)              # move running guests to the rest of the pool
            session.xenapi.host.apply_updates(host_ref, hash_)  # apply the synced updates
            guidance = session.xenapi.host.get_pending_guidances(host_ref)
            print("  applied; pending guidance = [%s]" % ", ".join(guidance))
            if "reboot_host" in guidance or "restart_toolstack" in guidance:
                # Either restart returns before it has happened, and if this host is the coordinator
                # it takes this session with it - so note when the host last started, restart it, and
                # reconnect until it reports a newer start and is live again.
                key = "boot_time" if "reboot_host" in guidance else "agent_start_time"
                before = session.xenapi.host.get_other_config(host_ref).get(key)
                if key == "boot_time":
                    session.xenapi.host.reboot(host_ref)       # reboot into the updated software
                else:
                    session.xenapi.host.restart_agent(host_ref)
                session = _wait_for_restart(url, username, password, host["uuid"], key, before)
            _enable_when_booted(session.xenapi, host_ref)       # return the host to service
    finally:
        session.xenapi.pool.set_repositories(pool, previous)
        for repo in repos:
            session.xenapi.Repository.forget(repo)
    print("OK: rolling-pool-update")
    session.xenapi.session.logout()
# Run it:
#   rolling_pool_update("https://xenserver", "root", password, "https://repo.ops.xenserver.com/xs9",
#       "https://repo-src.ops.xenserver.com/xs9")


# --- 42. Cross-pool copy a VM -------------------------------------------------------
def cross_pool_copy_vm(url, username, password, dest_url, vm_name="db-01",
                       dest_username=None, dest_password=None):
    """Copy a VM from one pool to another (Storage XenMotion copy): get a receiver token from the
    destination with host.migrate_receive, then VM.migrate_send with copy=true on the source."""
    source = connect(url, username, password)
    dest = connect(dest_url, dest_username or username, dest_password or password)
    # Destination: choose a host, network and SR, then ask for a receiver token. The disks go to
    # the destination pool's default SR and the data travels over the host's management network -
    # one both pools can certainly reach (the first network listed may well not be).
    dest_pool = dest.xenapi.pool.get_all()[0]
    dest_host = dest.xenapi.pool.get_master(dest_pool)
    dest_sr = dest.xenapi.pool.get_default_SR(dest_pool)
    dest_network = next(dest.xenapi.PIF.get_network(pif) for pif in dest.xenapi.host.get_PIFs(dest_host)
                        if dest.xenapi.PIF.get_management(pif))
    receiver = dest.xenapi.host.migrate_receive(dest_host, dest_network, {})

    # Source: map every disk to the destination SR and every NIC to the destination network,
    # then send with copy=true (source VM is left intact).
    vm = vm_by_name(source, vm_name)
    vdi_map = {}
    for vbd in source.xenapi.VM.get_VBDs(vm):
        if source.xenapi.VBD.get_type(vbd) != "Disk":
            continue
        vdi = source.xenapi.VBD.get_VDI(vbd)
        if vdi != "OpaqueRef:NULL":
            vdi_map[vdi] = dest_sr
    vif_map = {vif: dest_network for vif in source.xenapi.VM.get_VIFs(vm)}

    copy = source.xenapi.VM.migrate_send(vm, receiver, False, vdi_map, vif_map, {"copy": "true"}, {})
    print("Sent '%s' to the destination pool (copy); source still present: %s"
          % (vm_name, vm_by_name(source, vm_name) == vm))
    # The result is the new VM's ref on the DESTINATION pool - use the destination session to read it.
    print("  the copy on the destination: %s (%s)"
          % (dest.xenapi.VM.get_name_label(copy), dest.xenapi.VM.get_uuid(copy)))
    print("OK: cross-pool-copy-vm")
    source.xenapi.session.logout()
    dest.xenapi.session.logout()
# Run it:
#   cross_pool_copy_vm("https://poolA", "root", password, "https://poolB")



# Maps the <workflow> argument to the matching self-contained function above, supplying the
# concrete objects each one operates on. In your own scripts you would call these functions
# directly (see the "Run it:" line under each) rather than through this dispatcher.
# --- 43. PVS Accelerator inventory ---
def pvs_accelerator(url, username, password):
    session = connect(url, username, password)
    x = session.xenapi
    sites = x.PVS_site.get_all_records()
    if not sites:
        print("No PVS Accelerator sites are configured.")
    for site in sites.values():
        print("Site: %s" % site["name_label"])
        for cs_ref in site["cache_storage"]:
            cs = x.PVS_cache_storage.get_record(cs_ref)
            host = x.host.get_record(cs["host"])
            sr = x.SR.get_record(cs["SR"])
            print("  cache:  %s  %d GiB on %s" % (host["name_label"], int(cs["size"]) // (1024 ** 3), sr["name_label"]))
        for server_ref in site["servers"]:
            server = x.PVS_server.get_record(server_ref)
            print("  server: %s  ports %s-%s" % (", ".join(server["addresses"]), server["first_port"], server["last_port"]))
        # Which VMs are accelerated: walk each proxy to its VIF to its VM.
        accelerated = {}
        for proxy_ref in site["proxies"]:
            proxy = x.PVS_proxy.get_record(proxy_ref)
            vif = x.VIF.get_record(proxy["VIF"])
            accelerated[vif["VM"]] = proxy["status"]
        guests = [(ref, v) for ref, v in x.VM.get_all_records().items()
                  if not v["is_control_domain"] and not v["is_a_template"] and not v["is_a_snapshot"]]
        count = sum(1 for ref, _ in guests if ref in accelerated)
        print("  %d of %d VM(s) accelerated" % (count, len(guests)))
    print("OK: pvs-accelerator")
    session.logout()


# --- 44. Read RRD performance metrics ---
def rrd_metrics(url, username, password):
    session = connect(url, username, password)
    # The RRD time-series isn't a XenAPI call; read the last 5 minutes over HTTP from rrd_updates.
    # Legends look like "AVERAGE:host:<uuid>:<datasource>"; values[] aligns to legend[].
    start = int(time.time()) - 300
    req = urllib.request.Request(
        "%s/rrd_updates?session_id=%s&host=true&start=%d" % (url, session._session, start),
        headers={"accept": "application/json"})
    data = json.load(urllib.request.urlopen(req, context=ssl._create_unverified_context()))
    legends = data["meta"]["legend"]

    peak = {}
    for point in data["data"]:
        for k, legend in enumerate(legends):
            parts = legend.split(":")
            if parts[1] == "host" and parts[3] == "pvsaccelerator_space_utilization":
                value = float(point["values"][k])
                if value != value:  # NaN: a gap in the series, not a real sample - never let it stick
                    continue
                if parts[2] not in peak or value > peak[parts[2]]:
                    peak[parts[2]] = value
    for host in session.xenapi.host.get_all_records().values():
        if host["uuid"] in peak:
            print("  %s: peak PVS cache utilisation %d%%" % (host["name_label"], peak[host["uuid"]]))
    print("OK: rrd-metrics")
    session.logout()


# --- 45. Reclaim freed space on a thin SR --------------------------------------------
def reclaim_space(url, username, password):
    """Reclaim space freed by deleted disks on a thin-provisioned SR ("Reclaim freed space").

    A thin SR supports the trim/do_trim host plugin. Find one via its storage manager's
    SR_TRIM feature, pick a host with a live (currently-attached) connection to it, and run
    the plugin — exactly what XenCenter's Reclaim-freed-space command does.
    """
    session = connect(url, username, password)
    # Storage-manager backends that advertise SR_TRIM in their features map are trim-capable.
    trim_types = set(sm["type"] for sm in session.xenapi.SM.get_all_records().values()
                     if "SR_TRIM" in sm["features"])
    sr = next(r for r in session.xenapi.SR.get_all_records().values()
              if r["type"] in trim_types and int(r["physical_size"]) > 0)
    # A host with a currently-attached PBD can reach the SR to run the plugin.
    host = next(pbd["host"] for pbd in
                (session.xenapi.PBD.get_record(ref) for ref in sr["PBDs"])
                if pbd["currently_attached"])
    result = session.xenapi.host.call_plugin(host, "trim", "do_trim", {"sr_uuid": sr["uuid"]})
    print("  reclaimed freed space on %s: %s" % (sr["name_label"], result))
    # Compare case-insensitively: a real host's trim plugin answers "True" (capitalised).
    assert result.strip().lower() == "true", "trim plugin returned %r" % result
    print("OK: reclaim-space")
    session.logout()


# --- 46. Get a VM's IP address -------------------------------------------------------
def vm_ip_address(url, username, password, timeout=60, interval=2):
    """Read a running VM's IP from its guest metrics (VM_guest_metrics.networks).

    A VM that has only just started may not have reported in yet (no guest_metrics at all, or an
    empty networks map) - retry for a while rather than giving up on the first look, the way
    XenRT's own IP-discovery helpers do (they retry and fall back through several strategies for
    up to several minutes before concluding a guest has no usable address)."""
    session = connect(url, username, password)
    deadline = time.time() + timeout
    while True:
        # A running guest reports its IP in networks, keyed "<vif device>/ip" (e.g. "0/ip").
        vm = next((v for v in session.xenapi.VM.get_all_records().values()
                   if v["power_state"] == "Running" and not v["is_a_template"]
                   and not v["is_control_domain"] and v["guest_metrics"] != "OpaqueRef:NULL"), None)
        ip = None
        if vm is not None:
            networks = session.xenapi.VM_guest_metrics.get_record(vm["guest_metrics"])["networks"]
            ip = networks.get("0/ip")
        if ip:
            print("  %s: %s" % (vm["name_label"], ip))
            break
        if time.time() > deadline:
            raise RuntimeError("no running guest reported an IP address within %ds" % timeout)
        time.sleep(interval)
    print("OK: vm-ip-address")
    session.logout()


# --- 47. Manage Active Directory users -----------------------------------------------
def manage_ad_users(url, username, password, domain="", admin_user="alice",
                     admin_password="Password1", new_user="alice", ldaps="false"):
    """Join AD, add a user as a subject with an RBAC role, read it back, then tidy up.

    Needs a real, reachable AD domain controller - enable_external_auth fails at the very first
    call (DNS/LDAP/Kerberos) without one, so domain/admin_user/admin_password have to identify a
    real domain to join. Before joining, every host must resolve the domain (point its DNS at a
    domain controller) and keep its clock close to the DC's (Kerberos). Current Windows DCs want
    LDAPS (ldaps="true"), which also needs the pool to trust the DC's CA certificate
    (pool.install_trusted_certificate with purpose "ldaps"). new_user is the account to grant a
    role to; its subject identity is looked up against the directory, so it has to be a real
    account there too. A pool already joined to this domain is used as it is - and left joined.
    The simulator models a single-user, domain-less fake directory (hence the empty domain
    default) - override every one of these on a real pool."""
    session = connect(url, username, password)
    pool = session.xenapi.pool.get_all()[0]
    coordinator = session.xenapi.pool.get_master(pool)
    already_joined = (domain and session.xenapi.host.get_external_auth_type(coordinator) == "AD"
                      and session.xenapi.host.get_external_auth_service_name(coordinator).lower()
                      == domain.lower())
    if already_joined:
        print("Already joined to domain: %s" % domain)
    else:
        session.xenapi.pool.enable_external_auth(
            pool, {"user": admin_user, "pass": admin_password, "ldaps": ldaps}, domain, "AD")
        print("Joined domain: %s" % (domain or "(none - simulator's fake directory)"))

    subject_name = "%s@%s" % (new_user, domain) if domain else new_user
    sid = session.xenapi.auth.get_subject_identifier(subject_name)
    info = session.xenapi.auth.get_subject_information_from_identifier(sid)
    # other_config/roles are accepted here but discarded by real xapi (it re-derives other_config
    # from AD itself, and roles isn't a settable constructor field) - subject.add_to_roles below is
    # the call that actually matters.
    subject = session.xenapi.subject.create({"subject_identifier": sid, "other_config": {}, "roles": []})
    admin_role = session.xenapi.role.get_by_name_label("pool-admin")[0]
    session.xenapi.subject.add_to_roles(subject, admin_role)
    roles = [session.xenapi.role.get_name_label(r) for r in session.xenapi.subject.get_roles(subject)]
    print("Added subject %s (%s) as %s"
          % (info["subject-displayname"], info["subject-name"], ", ".join(roles)))

    # Revoking access does not end sessions the user already has: logging the subject out is a
    # separate act, and the one that actually gets them off the pool now rather than at next login.
    print("Logged-in subjects: %d" % len(session.xenapi.session.get_all_subject_identifiers()))
    session.xenapi.session.logout_subject_identifier(sid)
    print("  logged out %s" % info["subject-name"])

    session.xenapi.subject.remove_from_roles(subject, admin_role)
    session.xenapi.subject.destroy(subject)
    if not already_joined:
        # Leave the way it was found. Passing the admin credentials also removes the pool's computer
        # accounts from the directory; with {} they stay behind in AD.
        session.xenapi.pool.disable_external_auth(pool, {"user": admin_user, "pass": admin_password})
    print("OK: manage-ad-users")
    session.logout()


# --- 48. Create an iSCSI SR ----------------------------------------------------------
def create_iscsi_sr(url, username, password, target, port=None, chap_user=None, chap_password=None,
                     target_iqn=None, sr_name="sdk-example-iscsi"):
    """Connect an SR to a LUN on the iSCSI target, discovering the IQN and the LUN the way the New
    SR wizard and XenRT do: a device-config that's missing a piece makes the backend fail on
    purpose, and the failure carries an XML fragment listing what it needs next.

    SR.create formats the chosen LUN - this is destructive, so pick carefully on a real target:
    pass target_iqn to name yours (see _choose_target_iqn)."""
    GIB = 1024 * 1024 * 1024
    session = connect(url, username, password)
    host = session.xenapi.host.get_all()[0]
    dc = {"target": target}
    if port:
        dc["port"] = str(port)
    if chap_user:
        dc["chapuser"] = chap_user
        dc["chappassword"] = chap_password

    # First failing probe: target only -> the backend lists the IQNs it offers.
    iqn_xml = ET.fromstring(_probe_for_failure(session, host, dc, "lvmoiscsi"))
    dc["targetIQN"] = _choose_target_iqn(iqn_xml, target, target_iqn)
    print("Discovered IQN: %s" % dc["targetIQN"])

    # Second failing probe: +targetIQN -> the backend lists the LUNs behind it. Real create also
    # carries LUNid, which XenRT's own LUN-preparation helper always includes when known.
    lun_xml = ET.fromstring(_probe_for_failure(session, host, dc, "lvmoiscsi"))
    luns = lun_xml.findall(".//LUN")
    lun = luns[0]
    dc["SCSIid"] = lun.find("SCSIid").text
    lun_id = lun.find("LUNid")
    dc["LUNid"] = lun_id.text if lun_id is not None else str(luns.index(lun))
    print("Discovered LUN %s (SCSIid %s)" % (dc["LUNid"], dc["SCSIid"]))

    sr = session.xenapi.SR.create(host, dc, "0", sr_name,
                                  "iSCSI SR created by the SDK example", "lvmoiscsi", "user", True, {})
    print("Created SR: %s (%d GiB)"
          % (session.xenapi.SR.get_uuid(sr), int(session.xenapi.SR.get_physical_size(sr)) // GIB))
    detach_and_forget_sr(session, sr)
    print("OK: create-iscsi-sr")
    session.logout()


# --- 49. Create an SMB SR -----------------------------------------------------------
def create_smb_sr(url, username, password, server, share, smb_username, smb_password,
                   sr_name="sdk-example-smb"):
    """Connect a shared SR to an SMB/CIFS file share (create validates + sizes from the share).

    The password travels as a Secret, not plaintext device-config - the way XenRT and XenCenter
    both do it, and the only form seen in real captured sr-create calls for this SR type."""
    GIB = 1024 * 1024 * 1024
    session = connect(url, username, password)
    host = session.xenapi.host.get_all()[0]

    secret = session.xenapi.secret.create({"value": smb_password, "other_config": {}})
    # server is the share as one UNC path, //server/share: the SMB driver has no separate serverpath.
    dc = {"server": "//%s%s" % (server, share), "username": smb_username,
          "password_secret": session.xenapi.secret.get_uuid(secret)}
    sr = session.xenapi.SR.create(host, dc, "0", sr_name,
                                  "SMB SR created by the SDK example", "smb", "user", True, {})
    print("Created SR: %s (%d GiB)"
          % (session.xenapi.SR.get_uuid(sr), int(session.xenapi.SR.get_physical_size(sr)) // GIB))
    detach_and_forget_sr(session, sr)
    session.xenapi.secret.destroy(secret)
    print("OK: create-smb-sr")
    session.logout()


# --- 50. Create an HBA SR -----------------------------------------------------------
def create_hba_sr(url, username, password, scsi_id="", sr_name="sdk-example-hba"):
    """Connect a shared SR to a fibre-channel (HBA) LUN, discovering it the way the New SR wizard
    does: probing with no SCSIid fails on purpose and lists every LUN the backend can see.

    SR.create formats the chosen LUN - this is destructive. On shared FC storage a host sees LUNs
    other hosts are using, so name the one that is yours (scsi_id); with none, the first LUN listed
    is taken, which is only right on a dedicated test target."""
    GIB = 1024 * 1024 * 1024
    session = connect(url, username, password)
    host = session.xenapi.host.get_all()[0]

    # The root element varies by backend; find BlockDevice entries by tag wherever they are.
    devlist_xml = ET.fromstring(_probe_for_failure(session, host, {}, "lvmohba"))
    device = next((d for d in devlist_xml.iter("BlockDevice")
                   if not scsi_id or d.find("SCSIid").text == scsi_id), None)
    if device is None:
        raise RuntimeError("no LUN with SCSIid %s is visible to this host" % scsi_id)
    scsi_id = device.find("SCSIid").text
    path = device.find("path").text
    print("Discovered LUN: SCSIid %s on %s" % (scsi_id, path))

    # SCSIid is all lvmohba needs - it is what XenCenter's New SR wizard sends. (The probe's <path> is
    # for display: on a real host it reads like "/dev/sde [sdc] [sdg] [sdi]", one entry per path.)
    dc = {"SCSIid": scsi_id}
    sr = session.xenapi.SR.create(host, dc, "0", sr_name,
                                  "HBA SR created by the SDK example", "lvmohba", "user", True, {})
    print("Created SR: %s (%d GiB)"
          % (session.xenapi.SR.get_uuid(sr), int(session.xenapi.SR.get_physical_size(sr)) // GIB))
    detach_and_forget_sr(session, sr)
    print("OK: create-hba-sr")
    session.logout()


# --- 51. Create an ISO library SR ---------------------------------------------------
def create_iso_sr(url, username, password, location):
    """Connect an ISO-library SR to a file share of ISO images (here an NFS export, location
    "server:/path")."""
    session = connect(url, username, password)
    host = session.xenapi.host.get_all()[0]
    dc = {"location": location, "type": "nfs_iso"}
    sr = session.xenapi.SR.create(host, dc, "0", "sdk-example-iso",
                                  "ISO library created by the SDK example", "iso", "iso", True, {})
    print("Created ISO SR: %s" % session.xenapi.SR.get_uuid(sr))
    detach_and_forget_sr(session, sr)
    print("OK: create-iso-sr")
    session.logout()


# --- 52. Configure NRPE monitoring --------------------------------------------------
def configure_nrpe(url, username, password):
    """Enable the NRPE agent on every host and allow a monitoring host, through the nrpe plugin.

    host.call_plugin is per-host - there is no pool-wide fan-out for plugin calls the way there is
    for pool.enable_ssh - so configure every host in the pool, and restore each one to disabled
    again afterwards."""
    session = connect(url, username, password)
    for host in session.xenapi.host.get_all():
        def nrpe(fn, args=None, host=host):
            return session.xenapi.host.call_plugin(host, "nrpe", fn, args or {})
        label = session.xenapi.host.get_name_label(host)
        print("%s: NRPE status before: %s" % (label, nrpe("status").strip()))
        nrpe("enable")
        nrpe("set-config", {"allowed_hosts": "127.0.0.1,::1,10.0.0.5", "debug": "0", "ssl_logging": "0x00"})
        nrpe("restart")
        print("  status after:  %s" % nrpe("status").strip())
        for line in nrpe("get-config").split("\n"):
            if line.startswith("allowed_hosts:"):
                print("  allowed hosts: %s" % line.split(":", 1)[1].strip())
        nrpe("disable")  # restore: leave it as we found it
    print("OK: configure-nrpe")
    session.logout()


# --- 53. Configure SNMP monitoring --------------------------------------------------
def configure_snmp(url, username, password, trap_destination="192.0.2.50"):
    """Enable the SNMP agent on every host with a community string and a trap destination, through
    the snmp plugin.

    nmss is the list of real trap destinations SNMP notifications go to - an empty list never
    configures where traps actually go, which is the whole point of "configure SNMP monitoring".
    Plugin calls are per-host, so configure every host, and restore each one to disabled again
    afterwards, the way XenRT's own SNMPServer.disable() does."""
    session = connect(url, username, password)
    config = {
        "common": {"enabled": "yes", "debug_log": "no"},
        "agent": {"v2c": "yes", "v3": "no", "community": "sdk-community", "user_name": "",
                  "authentication_password": "", "authentication_protocol": "",
                  "privacy_password": "", "privacy_protocol": ""},
        "nmss": [{"address": trap_destination, "port": 162, "v2c": "yes", "v3": "no",
                  "community": "sdk-community", "user_name": "", "authentication_password": "",
                  "authentication_protocol": "", "privacy_password": "", "privacy_protocol": ""}],
    }
    for host in session.xenapi.host.get_all():
        def snmp(fn, args=None, host=host):
            return json.loads(session.xenapi.host.call_plugin(host, "snmp", fn, args or {}))
        snmp("set-config", {"config": json.dumps(config)})
        status = snmp("status")["result"]
        cfg = snmp("get-config")["result"]
        label = session.xenapi.host.get_name_label(host)
        print("%s: SNMP enabled: %s / %s" % (label, status["enabled"], status["active"]))
        print("  community: %s, trap destination: %s"
              % (cfg["agent"]["community"], cfg["nmss"][0]["address"] if cfg["nmss"] else "(none)"))
        snmp("set-config", {"config": json.dumps({"common": {"enabled": "no"}})})  # restore
    print("OK: configure-snmp")
    session.logout()


# --- Manage a vApp --------------------------------------------------------------------
def manage_vapp(url, username, password, vm_name):
    """Group VMs into an appliance that starts and stops together, then remove it."""
    session = connect(url, username, password)
    x = session.xenapi
    vm = x.VM.get_by_name_label(vm_name)[0]

    vapp = x.VM_appliance.create({
        "name_label": "sdk-example-vapp",
        "name_description": "Created by the SDK example",
    })

    # `order` decides the sequence: ascending to start, descending to shut down. That ordering is the
    # reason to use a vApp at all rather than selecting several VMs.
    x.VM.set_appliance(vm, vapp)
    x.VM.set_order(vm, "0")
    x.VM.set_start_delay(vm, "5")

    x.VM_appliance.start(vapp, False)
    print(f"Started:        {x.VM.get_power_state(vm)}")

    # shutdown tries each VM's clean shutdown and falls back to a hard one. clean_shutdown alone fails
    # OPERATION_PARTIALLY_FAILED if any member can't shut down cleanly (no guest OS or PV drivers).
    x.VM_appliance.shutdown(vapp)
    print(f"Shut down:      {x.VM.get_power_state(vm)}")

    x.VM.set_appliance(vm, "OpaqueRef:NULL")
    x.VM_appliance.destroy(vapp)
    print("OK: manage-vapp")
    x.session.logout()


# Run it:
#   manage_vapp("https://xenserver", "root", password, "db-01")


# --- Attach a USB device to a VM -------------------------------------------------------
def attach_usb_device(url, username, password, vm_name):
    """Enable passthrough on a host USB device, attach it to a VM, then detach it.

    VUSB.destroy refuses a VUSB that is still attached (OPERATION_NOT_ALLOWED) - on a running VM
    it gets plugged in as soon as it's created, so unplug it first, the same unplug-before-destroy
    shape SR.forget and VBD/PBD teardown already need elsewhere in this file."""
    session = connect(url, username, password)
    x = session.xenapi
    vm = x.VM.get_by_name_label(vm_name)[0]

    pusb_ref, pusb = next(iter(x.PUSB.get_all_records().items()))
    print(f"Device:         {pusb['description']}")

    # Passthrough is off until an administrator enables it on the device: attaching one that has not
    # been released fails rather than silently doing nothing.
    x.PUSB.set_passthrough_enabled(pusb_ref, True)

    vusb = x.VUSB.create(vm, pusb["USB_group"], {})
    print(f"Attached:       {len(x.VM.get_VUSBs(vm))} device(s)")

    if x.VUSB.get_currently_attached(vusb):
        x.VUSB.unplug(vusb)
    x.VUSB.destroy(vusb)
    x.PUSB.set_passthrough_enabled(pusb_ref, False)
    print("OK: attach-usb-device")
    x.session.logout()


# Run it:
#   attach_usb_device("https://xenserver", "root", password, "web-01")


# --- Read workload-balancing recommendations -------------------------------------------
def wlb_recommendations(url, username, password, vm_name, wlb_host_port="wlb.example:8012",
                         wlb_username="wlbuser", wlb_password="wlbpass", wlb_certificate=""):
    """Connect a workload-balancing appliance and read its placement advice.

    Needs a real, reachable WLB appliance: pool.initialize_wlb makes a synchronous HTTP call to it
    and raises WLB_CONNECTION_REFUSED/WLB_CONNECTION_RESET if it can't connect - there is no way to
    fake this with a placeholder. wlb_host_port is host:port, with no URL scheme - that is the
    real wire format (xe pool-initialize-wlb wlb_url="10.x.x.x:30601" ...), not a URL.

    The pool checks the appliance's TLS certificate (pool.wlb_verify_cert), and only against the
    certificates installed with pool.certificate_install - not install_trusted_certificate's. A
    fresh appliance has a self-signed one, so pass it as wlb_certificate (a PEM file): without it
    initialize_wlb fails with INTERNAL_ERROR "Connection failed: configuration failed." and no
    hint that the certificate is the reason."""
    session = connect(url, username, password)
    x = session.xenapi
    pool = x.pool.get_all()[0]

    cert_name = ""
    if wlb_certificate:
        cert_name = "sdk-example-wlb.pem"
        with open(wlb_certificate) as f:
            x.pool.certificate_install(cert_name, f.read())   # a pool-wide call: no pool argument
    x.pool.initialize_wlb(wlb_host_port, wlb_username, wlb_password, username, password)
    try:
        # Initializing connects the pool to the appliance but leaves balancing off: every WLB call
        # after this would fail WLB_DISABLED until it's switched on.
        x.pool.set_wlb_enabled(pool, True)
        print(f"WLB: {x.pool.get_wlb_url(pool)}")

        # Read BY POSITION, and the two calls do not share a shape. The pool's recommendations are
        # keyed by VM and say where to move it: [0] "wlb", [1] the destination host's UUID (a uuid,
        # not a ref), [2] and [3] ids, [4] the reason. A freshly connected pool has none yet.
        for vm_ref, fields in x.pool.retrieve_wlb_recommendations().items():
            print(f"  move {x.VM.get_name_label(vm_ref)} -> host {fields[1]} ({fields[4]})")

        # A VM's own recommendations are keyed by host and star-rate each as a destination:
        # [0] "wlb", [1] the rating - higher is better (a real appliance rated hosts 6.1 here, so not
        # capped at XenCenter's five stars). Right after connecting, the appliance is still
        # discovering the pool: WLB_INTERNAL_ERROR 4024 ("Pool discovery has not been started"), 4025
        # ("... has not been completed"), then 4016 ("WLB does not have current metrics") - keep asking.
        vm = x.VM.get_by_name_label(vm_name)[0]
        deadline = time.time() + 600
        while True:
            try:
                ratings = x.VM.retrieve_wlb_recommendations(vm)
                break
            except XenAPI.Failure as e:
                if (e.details[0] != "WLB_INTERNAL_ERROR" or e.details[1:2] not in (["4024"], ["4025"], ["4016"])
                        or time.time() > deadline):
                    raise
                time.sleep(15)
        for host, fields in ratings.items():
            print(f"  {x.host.get_name_label(host)} rated {fields[1]}")

        # The appliance's own settings are read and written as one flat map of strings. Send a
        # nightly reporting schedule, then read the configuration back to confirm it took.
        x.pool.send_wlb_configuration({"ReportingCronString": "0 3 * * *"})
        config = x.pool.retrieve_wlb_configuration()
        print("  appliance configuration: %s"
              % ", ".join("%s=%s" % kv for kv in sorted(config.items())))
    finally:
        # Disconnect from the appliance however the above went, or the pool stays attached to it.
        x.pool.deconfigure_wlb()
        if cert_name:
            x.pool.certificate_uninstall(cert_name)
    print("OK: wlb-recommendations")
    x.session.logout()


# Run it:
#   wlb_recommendations("https://xenserver", "root", password, "web-01",
#                        wlb_host_port="10.0.0.5:30601", wlb_username="wlbuser", wlb_password="wlbpass",
#                        wlb_certificate="wlb-appliance.pem")


# --- Configure clustering (GFS2) -------------------------------------------------------
def configure_clustering(url, username, password):
    """Enable corosync clustering, watch quorum as a member leaves and rejoins."""
    session = connect(url, username, password)
    x = session.xenapi

    # Clustering is what shared block storage needs before it can be thin-provisioned with GFS2. Pick a
    # network every host can reach: corosync is latency-sensitive, and a cluster that loses quorum takes
    # its GFS2 storage offline with it.
    network = x.network.get_all()[0]

    existing = x.Cluster.get_all()
    cluster = existing[0] if existing else x.Cluster.pool_create(network, "corosync", "20000", "1000")

    record = x.Cluster.get_record(cluster)
    print(f"Stack:      {record['cluster_stack']}")
    print(f"Quorate:    {record['is_quorate']} ({record['live_hosts']}/{record['quorum']} needed)")

    # Taking a host out is what a management-interface change does; it can cost the pool quorum, which
    # is why the field is worth reading back rather than assuming.
    member = x.Cluster_host.get_all()[0]
    x.Cluster_host.disable(member)
    print(f"One member out, quorate: {x.Cluster.get_is_quorate(cluster)}")

    x.Cluster_host.enable(member)
    x.Cluster.pool_resync(cluster)
    print(f"Resynced,   quorate: {x.Cluster.get_is_quorate(cluster)}")

    print("OK: configure-clustering")
    x.session.logout()


# Run it:
#   configure_clustering("https://xenserver", "root", password)


# --- Manage pool membership ------------------------------------------------------------
def manage_pool_membership(url, username, password):
    """List the pool's hosts, promote a different coordinator, then promote the original back.

    designate_new_master runs a two-phase commit across every host and ends by restarting xapi
    pool-wide (the new coordinator becomes master, every other host becomes its slave) - so the
    session this call was made on, and the connection itself, do not survive it. Reconnect (with a
    bounded wait, since xapi is briefly unavailable while it restarts, the same way XenRT's own
    helper for this call does) before touching the pool again, rather than assuming the session
    is still good."""
    session = connect(url, username, password)
    x = session.xenapi
    pool = x.pool.get_all()[0]

    hosts = x.host.get_all_records()
    original = x.pool.get_master(pool)
    print(f"Coordinator: {hosts[original]['name_label']}")
    for ref, host in hosts.items():
        print(f"  member: {host['name_label']}" + (" (coordinator)" if ref == original else ""))

    # Promote another member. The pool database moves with the role and clients are redirected, so this
    # briefly interrupts management traffic — it does not move any VM.
    other = next(ref for ref in hosts if ref != original)
    x.pool.designate_new_master(other)
    print(f"Promoting:   {hosts[other]['name_label']} (xapi restarts pool-wide; reconnecting)")

    session = _reconnect_after_master_change(url, username, password, hosts[other]["uuid"])
    x = session.xenapi
    pool = x.pool.get_all()[0]
    print(f"Promoted:    {x.host.get_name_label(x.pool.get_master(pool))}")

    # Put it back. Ejecting a member (pool.eject) is the other half of this surface and is deliberately
    # not shown: it cannot be undone from the pool, because rejoining is initiated by the ejected host.
    x.pool.designate_new_master(original)
    print(f"Restoring:   {hosts[original]['name_label']} (reconnecting again)")

    session = _reconnect_after_master_change(url, username, password, hosts[original]["uuid"])
    x = session.xenapi
    pool = x.pool.get_all()[0]
    print(f"Restored:    {x.host.get_name_label(x.pool.get_master(pool))}")

    print("OK: manage-pool-membership")
    x.session.logout()


# Run it:
#   manage_pool_membership("https://xenserver", "root", password)


# --- Create a NIC bond -----------------------------------------------------------------
def create_bond(url, username, password):
    """Bond two spare NICs onto a new network, then dissolve the bond."""
    session = connect(url, username, password)
    x = session.xenapi
    host = x.host.get_all()[0]

    # Pick up any NIC racked since the host booted. Cheap, and without it a card added a moment ago is
    # not there to bond.
    x.PIF.scan(host)

    # Spare NICs only. A bond that includes the management interface moves the management address onto
    # the bond master — on a real host that is how you lose the connection you are working over.
    spares = [ref for ref, pif in x.PIF.get_all_records().items()
              if pif["host"] == host and not pif["management"] and pif["physical"]][:2]
    if len(spares) < 2:
        raise RuntimeError("%s has %d spare NIC(s); a bond needs two that aren't the management interface"
                           % (x.host.get_name_label(host), len(spares)))
    print("Bonding:      " + ", ".join(x.PIF.get_device(p) for p in spares))

    # The bond needs a network to sit on.
    network = x.network.create({
        "name_label": "sdk-example-bond",
        "name_description": "Created by the SDK example",
        "other_config": {},
    })

    bond = x.Bond.create(network, spares, "", "balance-slb")
    print(f"Bond master:  {x.PIF.get_device(x.Bond.get_master(bond))}")
    print(f"Mode:         {x.Bond.get_mode(bond)}")

    # Dissolving returns the NICs to standalone use (and moves management back, had it been bonded).
    x.Bond.destroy(bond)
    x.network.destroy(network)
    print(f"Bonds left:   {len(x.Bond.get_all())}")
    print("OK: create-bond")
    x.session.logout()


# Run it:
#   create_bond("https://xenserver", "root", password)


# --- Configure PVS Accelerator ---------------------------------------------------------
def configure_pvs_accelerator(url, username, password, vm_name):
    """Build a PVS Accelerator site from nothing: a site, a PVS server, a read cache on each
    host, and one accelerated VM (vm_name). Then take it all down again.

    The inventory example above reads a configuration someone else made; this one makes it."""
    session = connect(url, username, password)
    x = session.xenapi

    # Check the VM first, before creating anything: it needs a NIC for the proxy to sit on, and one
    # that no site accelerates yet (a VIF takes one proxy: PVS_PROXY_ALREADY_PRESENT). It need not be
    # running - a proxy on a halted VM just reports "stopped" until it starts.
    vm = vm_by_name(session, vm_name)
    vifs = sorted(x.VM.get_VIFs(vm), key=lambda v: int(x.VIF.get_device(v)))
    if not vifs:
        raise RuntimeError("%s has no network interface to accelerate" % vm_name)
    for proxy in x.PVS_proxy.get_all_records().values():
        if proxy["VIF"] == vifs[0]:
            raise RuntimeError("%s is already accelerated by site '%s'"
                               % (vm_name, x.PVS_site.get_name_label(proxy["site"])))

    site = x.PVS_site.introduce("sdk-example-pvs", "Created by the SDK examples", "")
    x.PVS_server.introduce(["10.62.0.90"], 6910, 6930, site)

    # The read cache must be on LOCAL storage. The point of the accelerator is to keep reads off
    # the network, so a cache on a shared SR would defeat it and xapi rejects one.
    for host in x.host.get_all():
        local = local_sr(x, host)
        if local:
            # size as a STRING: XML-RPC only carries 32-bit integers, so the Python binding passes
            # every XenAPI Int as a string. 10 GiB does not fit, and passing an int raises inside
            # xmlrpc.client rather than at the API — a confusing place to land.
            x.PVS_cache_storage.create({"host": host, "SR": local, "site": site,
                                        "size": str(10 * 1024 ** 3)})

    # A proxy may only sit on the VM's LOWEST-numbered VIF, hence sorting by device above rather than
    # taking VIFs[0] — the list comes back in creation order, which is the same thing only by luck.
    proxy = x.PVS_proxy.create(site, vifs[0])

    print("Site '%s' with %d cache(s) and %d server(s)"
          % (x.PVS_site.get_name_label(site),
             len(x.PVS_site.get_cache_storage(site)),
             len(x.PVS_site.get_servers(site))))
    # "caching" means it is actually accelerating. A site with no cache storage reports
    # "initialised", and a proxy on a VM whose VIF is unplugged reports "stopped".
    print("  %s: %s" % (x.VM.get_name_label(vm), x.PVS_proxy.get_status(proxy)))

    # Forgetting the site only cascades its cache storage - a running proxy or a server it still
    # has makes forget refuse with PVS_SITE_CONTAINS_RUNNING_PROXIES/_SERVERS, so tear those down
    # ourselves first, in the same order every real PVS teardown uses.
    x.PVS_proxy.destroy(proxy)
    for server_ref in x.PVS_site.get_servers(site):
        x.PVS_server.forget(server_ref)
    x.PVS_site.forget(site)
    print("OK: configure-pvs-accelerator")
    session.logout()


def local_sr(x, host):
    """The host's own non-ISO storage, found through its PBDs."""
    for pbd in x.host.get_PBDs(host):
        sr = x.PBD.get_SR(pbd)
        record = x.SR.get_record(sr)
        if not record["shared"] and record["content_type"] != "iso" and record["type"] != "udev":
            return sr
    return None


# Run it:
#   configure_pvs_accelerator("https://xenserver", "root", password, "db-01")


# --- Manage SSH access -----------------------------------------------------------------
def manage_ssh_access(url, username, password):
    """Turn the pool's SSH service on with an automatic cut-off, read it back, then turn it off.

    Timed access is the point: set the timeout first and the server stamps an ssh_expiry when SSH
    is enabled, so a window opened for troubleshooting closes itself. pool.set_ssh_enabled_timeout
    is itself a pool-wide fan-out call, exactly like enable_ssh/disable_ssh - no need to loop
    hosts for it either."""
    session = connect(url, username, password)
    x = session.xenapi
    pool = list(x.pool.get_all())[0]
    # Each host's SSH as we found it, to put back at the end: disabling it is not the example's to keep.
    before = {h: (r["ssh_enabled"], r["ssh_enabled_timeout"]) for h, r in x.host.get_all_records().items()}

    x.pool.set_ssh_enabled_timeout(pool, str(3600))   # one hour

    # The pool call fans out to every host, so there is no need to loop for the enable itself.
    x.pool.enable_ssh(pool)
    for host in x.host.get_all():
        record = x.host.get_record(host)
        print("%s: ssh enabled=%s, expires %s"
              % (record["name_label"], record["ssh_enabled"], record["ssh_expiry"]))

    x.pool.disable_ssh(pool)
    print("After disable: %s"
          % ", ".join("%s=%s" % (h["name_label"], h["ssh_enabled"])
                      for h in x.host.get_all_records().values()))

    for host, (enabled, timeout) in before.items():
        x.host.set_ssh_enabled_timeout(host, timeout)   # first: enabling stamps the expiry from it
        if enabled:
            x.host.enable_ssh(host)
    print("OK: manage-ssh-access")
    session.logout()


# Run it:
#   manage_ssh_access("https://xenserver", "root", password)


# --- Change control domain memory ------------------------------------------------------
def control_domain_memory(url, username, password):
    """Read and change a host's control domain (dom0) memory.

    VM.set_memory is a single-value setter: it pins the static and dynamic bounds and the
    target together, which is what dom0 needs — it does not balloon. The new size takes
    effect when the host next reboots, so in XenCenter this is offered only in maintenance
    mode; the API itself does not stop you."""
    session = connect(url, username, password)
    x = session.xenapi

    host = x.host.get_all()[0]
    dom0 = next(vm for vm in x.host.get_resident_VMs(host) if x.VM.get_is_control_domain(vm))
    original = int(x.VM.get_memory_dynamic_min(dom0))
    print("%s dom0: %.1f GiB" % (x.host.get_name_label(host), original / float(1024 ** 3)))

    x.VM.set_memory(dom0, str(original + 1024 ** 3))
    record = x.VM.get_record(dom0)
    print("  now %.1f GiB (static %s-%s, dynamic %s-%s)"
          % (int(record["memory_dynamic_min"]) / float(1024 ** 3),
             record["memory_static_min"], record["memory_static_max"],
             record["memory_dynamic_min"], record["memory_dynamic_max"]))

    x.VM.set_memory(dom0, str(original))     # leave the pool as we found it
    print("OK: control-domain-memory")
    session.logout()


# Run it:
#   control_domain_memory("https://xenserver", "root", password)


# --- Manage a vTPM ---------------------------------------------------------------------
def manage_vtpm(url, username, password):
    """Attach a virtual TPM to a halted VM, read it back, then remove it.

    A VM may have at most one, and it can only be attached while the VM is Halted — the
    device is presented at boot. XenCenter additionally only offers this for a UEFI guest,
    since that is what a vTPM is for; the API itself does not insist."""
    session = connect(url, username, password)
    x = session.xenapi

    vm = next(ref for ref, v in x.VM.get_all_records().items()
              if not v["is_a_template"] and not v["is_control_domain"]
              and not v["is_a_snapshot"] and v["power_state"] == "Halted"
              and not v["VTPMs"])
    print("Attaching a vTPM to %s" % x.VM.get_name_label(vm))

    vtpm = x.VTPM.create(vm, False)   # is_unique=False: the vTPM may be copied with the VM
    record = x.VTPM.get_record(vtpm)
    print("  persistence backend: %s" % record["persistence_backend"])
    print("  unique to this VM:   %s" % record["is_unique"])
    print("  VM now has %d vTPM(s)" % len(x.VM.get_VTPMs(vm)))

    # The VM advertises whether another can be added; once it has one, it cannot.
    print("  can add another:     %s" % ("create_vtpm" in x.VM.get_allowed_operations(vm)))

    x.VTPM.destroy(vtpm)
    print("  after removal:       %d vTPM(s)" % len(x.VM.get_VTPMs(vm)))
    print("OK: manage-vtpm")
    session.logout()


# Run it:
#   manage_vtpm("https://xenserver", "root", password)


# --- Back up with changed block tracking -----------------------------------------------
def changed_block_tracking(url, username, password):
    """Walk an incremental backup: enable CBT, snapshot twice, ask which blocks differ,
    then release the older snapshot's data while keeping the metadata.

    This is the whole point of CBT. Without it an incremental has to read the entire disk
    to find out what moved; with it the server answers directly, and data_destroy means
    the chain of snapshots you diff against costs metadata rather than disk."""
    session = connect(url, username, password)
    x = session.xenapi

    vm = next(ref for ref, v in x.VM.get_all_records().items()
              if not v["is_a_template"] and not v["is_control_domain"]
              and not v["is_a_snapshot"] and v["VBDs"])
    print("Backing up %s" % x.VM.get_name_label(vm))

    # CBT is switched on for the VM's own disk, and every snapshot taken from then on inherits it.
    # It can't be switched on for a snapshot's disk after the fact (OPERATION_NOT_ALLOWED).
    live = first_disk(x, vm)
    was_enabled = x.VDI.get_cbt_enabled(live)
    if not was_enabled:
        x.VDI.enable_cbt(live)

    first = x.VM.snapshot(vm, "cbt-backup-1")
    second = x.VM.snapshot(vm, "cbt-backup-2")
    vdi_from, vdi_to = first_disk(x, first), first_disk(x, second)

    # One bit per 64 KiB block, base64-encoded; bit N set means block N changed. A real backup
    # reads only those blocks, over NBD.
    bitmap = base64.b64decode(x.VDI.list_changed_blocks(vdi_from, vdi_to))
    changed = sum(bin(byte).count("1") for byte in bitmap)
    print("  %d blocks of %d changed (%.1f MiB to copy, not %.1f MiB)"
          % (changed, len(bitmap) * 8, changed * 64 / 1024.0,
             int(x.VDI.get_virtual_size(vdi_to)) / (1024.0 ** 2)))

    # Release the older snapshot's blocks but keep its change metadata, so the next incremental can
    # still diff against it. data_destroy refuses a disk that a VM still uses (VDI_IN_USE), so drop the
    # older snapshot's VM record first, as a backup tool does. The VDI record stays; its type changes.
    x.VM.destroy(first)
    x.VDI.data_destroy(vdi_from)
    print("  older snapshot is now type=%s, still cbt_enabled=%s"
          % (x.VDI.get_type(vdi_from), x.VDI.get_cbt_enabled(vdi_from)))

    # Tidy up: the newer snapshot and its disk, the metadata-only VDI, and CBT on the VM's own disk
    # if this example switched it on.
    destroy_vm_and_disks(session, second)
    x.VDI.destroy(vdi_from)
    if not was_enabled:
        x.VDI.disable_cbt(live)
    print("OK: changed-block-tracking")
    session.logout()


def first_disk(x, vm):
    """The VDI behind a VM's first real disk (a CD drive is a VBD too)."""
    for vbd in x.VM.get_VBDs(vm):
        if x.VBD.get_type(vbd) == "Disk":
            return x.VBD.get_VDI(vbd)
    raise Exception("no disk found")


# Run it:
#   changed_block_tracking("https://xenserver", "root", password)


# --- Export and import a VM ------------------------------------------------------------
def export_import_vm(url, username, password, vm_name):
    """Export a halted VM (vm_name) to an XVA file and import it back as a new VM.

    Export and import are not XenAPI calls: they are HTTP transfers alongside the API, and
    the session id goes in the query string. Everything else about them is ordinary HTTP -
    GET /export writes the archive, PUT /import reads one back.

    One quirk worth knowing if you write your own uploader: the server answers 200 BEFORE
    reading the body, because xapi's own clients wait for the response line before they
    start streaming. Ordinary HTTP libraries send the body first and cope with the early
    reply, so this only matters if you are working at the socket level.

    The new VM's ref is NOT in the /import response body on a real host - the only place it
    appears is the task named in the task_id query parameter, so create one, pass it, and read
    task.get_result() once the upload finishes, the same pattern backup-host-config/wait-for-task
    already use."""
    session = connect(url, username, password)
    x = session.xenapi
    session_id = session._session

    # Name the VM: an export carries every block of its disks, so which VM matters (a large one
    # takes a long time, and fills the disk). Only a halted VM can be exported: its disks must not
    # be changing underneath the copy.
    vm = vm_by_name(session, vm_name)
    if x.VM.get_power_state(vm) != "Halted":
        raise RuntimeError("%s must be halted to be exported" % vm_name)
    name = vm_name
    print("Exporting %s" % name)

    # A unique file, not a fixed name: an export is a real file on disk and two of them running at once
    # would otherwise fight over it.
    handle, path = tempfile.mkstemp(prefix="sdk-example-export-", suffix=".xva")
    os.close(handle)
    ctx = ssl._create_unverified_context()
    with urllib.request.urlopen(
            "%s/export?session_id=%s&uuid=%s" % (url, session_id, x.VM.get_uuid(vm)),
            context=ctx) as response, open(path, "wb") as out:
        exported = 0
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
            exported += len(chunk)
    print("  wrote %.1f MiB to %s" % (exported / (1024.0 ** 2), os.path.basename(path)))

    # An XVA is a tar: ova.xml describes the VM, and the disk blocks follow it in 1 MiB
    # pieces, each with its own checksum.
    with tarfile.open(path) as archive:
        names = archive.getnames()
    print("  archive holds %s and %d disk block(s)"
          % (names[0], len([n for n in names if not n.endswith(".checksum")]) - 1))

    task = x.task.create("vm_import", "importing %s back" % name)
    try:
        # Stream the file rather than reading it into memory: a real VM's export is gigabytes.
        with open(path, "rb") as f:
            request = urllib.request.Request(
                "%s/import?session_id=%s&task_id=%s" % (url, session_id, task),
                data=f, method="PUT", headers={"Content-Length": str(os.path.getsize(path))})
            urllib.request.urlopen(request, context=ctx).read()

        while x.task.get_status(task) == "pending":
            time.sleep(0.5)
        if x.task.get_status(task) != "success":
            raise RuntimeError("import failed: %s" % x.task.get_error_info(task))
        # The result lists the imported VMs (<value><array><data>OpaqueRef:...</data></array></value>
        # on a real host), so take the first reference in it.
        imported = re.search(r"OpaqueRef:[^<]+", x.task.get_result(task)).group(0)
    finally:
        x.task.destroy(task)
    print("  imported as %s" % x.VM.get_name_label(imported))

    # The import brought its own disks along; destroy those too, not just the VM record.
    destroy_vm_and_disks(session, imported)
    os.remove(path)
    print("OK: export-import-vm")
    session.logout()


# Run it:
#   export_import_vm("https://xenserver", "root", password, "db-01")


# --- Configure dynamic memory ----------------------------------------------------------
def configure_dynamic_memory(url, username, password):
    """Give a VM a dynamic memory range, so the host can reclaim memory from it under
    pressure instead of the VM holding a fixed amount.

    The four bounds must stay ordered: static_min <= dynamic_min <= dynamic_max <=
    static_max. The dynamic pair is what ballooning moves between; the static pair is the
    hard limit and can only be changed while the VM is off."""
    session = connect(url, username, password)
    x = session.xenapi

    vm = next(ref for ref, v in x.VM.get_all_records().items()
              if not v["is_a_template"] and not v["is_control_domain"]
              and not v["is_a_snapshot"] and v["power_state"] == "Halted")
    before = x.VM.get_record(vm)
    print("%s: static %s-%s, dynamic %s-%s"
          % (before["name_label"], gib(before["memory_static_min"]), gib(before["memory_static_max"]),
             gib(before["memory_dynamic_min"]), gib(before["memory_dynamic_max"])))

    # Room to balloon: let the host squeeze the VM down to a quarter of its maximum, but never
    # below the static floor, which is the least the guest can boot in.
    floor = max(int(before["memory_static_min"]), int(before["memory_static_max"]) // 4)
    ceiling = int(before["memory_static_max"])
    x.VM.set_memory_dynamic_range(vm, str(floor), str(ceiling))
    after = x.VM.get_record(vm)
    print("  dynamic range now %s-%s" % (gib(after["memory_dynamic_min"]), gib(after["memory_dynamic_max"])))

    # The ordering is enforced, not advisory: a range wider than the static bounds is
    # refused rather than quietly clamped.
    try:
        x.VM.set_memory_dynamic_range(vm, str(floor), str(ceiling * 2))
        print("  ERROR: an out-of-range maximum was accepted")
    except XenAPI.Failure as e:
        print("  refused a dynamic_max above static_max: %s" % e.details[0])

    # str() throughout: memory is a 64-bit byte count and the binding's transport cannot carry
    # an integer that large, so the API takes these as strings.
    x.VM.set_memory_dynamic_range(vm, str(before["memory_dynamic_min"]), str(before["memory_dynamic_max"]))
    print("OK: configure-dynamic-memory")
    session.logout()


def gib(value):
    return "%.1f GiB" % (int(value) / float(1024 ** 3))


# Run it:
#   configure_dynamic_memory("https://xenserver", "root", password)


# --- Manage a VM's CD drive ------------------------------------------------------------
def manage_vm_media(url, username, password):
    """Give a VM a DVD drive, put an ISO in it, then eject it.

    A CD drive is a VBD like any other, distinguished by type=CD; the media is whichever
    VDI it points at, and an empty drive points at none."""
    session = connect(url, username, password)
    x = session.xenapi

    vm = next(ref for ref, v in x.VM.get_all_records().items()
              if not v["is_a_template"] and not v["is_control_domain"]
              and not v["is_a_snapshot"] and v["power_state"] == "Halted")
    print("Adding a DVD drive to %s" % x.VM.get_name_label(vm))

    device = x.VM.get_allowed_VBD_devices(vm)[0]
    drive = x.VBD.create({
        "VM": vm, "VDI": "OpaqueRef:NULL", "userdevice": device, "bootable": False,
        "mode": "RO", "type": "CD", "empty": True, "unpluggable": True,
        "other_config": {}, "qos_algorithm_type": "", "qos_algorithm_params": {},
    })
    print("  drive %s is empty: %s" % (device, x.VBD.get_empty(drive)))

    # The ISO library is an SR of content type "iso"; its VDIs are the available images.
    iso_sr = next(ref for ref, s in x.SR.get_all_records().items()
                  if s["content_type"] == "iso" and s["type"] != "udev")
    iso = sorted(x.SR.get_VDIs(iso_sr), key=lambda v: x.VDI.get_name_label(v))[0]
    print("  inserting %s" % x.VDI.get_name_label(iso))
    x.VBD.insert(drive, iso)
    print("  drive now holds %s (empty=%s)"
          % (x.VDI.get_name_label(x.VBD.get_VDI(drive)), x.VBD.get_empty(drive)))

    x.VBD.eject(drive)
    print("  after eject, empty=%s" % x.VBD.get_empty(drive))

    x.VBD.destroy(drive)
    print("OK: manage-vm-media")
    session.logout()


# Run it:
#   manage_vm_media("https://xenserver", "root", password)


# --- Back up a host's configuration ----------------------------------------------------
def backup_host_config(url, username, password):
    """Download a host's configuration backup and offer it back, as a restore would.

    Both halves are HTTP transfers alongside the API rather than API calls, and the upload
    has a convention worth knowing: the server answers 200 as soon as it has read the
    request headers, because the client waits for that before it starts sending the file.
    The outcome therefore cannot be in the status line. It arrives on a task you create
    first, name in the URL, and poll once the upload has finished.

    Both halves are served only by whichever host physically accepted the HTTP connection - the
    handler ignores any ref= in the query string entirely, there is no forwarding to another pool
    member. So backing up/restoring a host means opening the connection to THAT host's own
    address, not to the pool's (coordinator) url - a restore sent to the wrong host's connection
    silently restores the WRONG host, not the one named by ref=. ref= is kept in the query string
    purely for log-readability (a real host ignores it; it is not what makes this correct)."""
    session = connect(url, username, password)
    x = session.xenapi
    ctx = ssl._create_unverified_context()

    hosts = x.host.get_all()
    host = hosts[0]
    host_url = _host_url(url, x.host.get_address(host))
    print("Backing up %s" % x.host.get_name_label(host))

    path = os.path.join(tempfile.gettempdir(), "sdk-example-host.backup")
    with urllib.request.urlopen(
            "%s/host_backup?session_id=%s&ref=%s" % (host_url, session._session, host),
            context=ctx, timeout=10) as response, open(path, "wb") as out:
        shutil.copyfileobj(response, out)       # hundreds of MB: stream it, don't hold it in memory
    print("  wrote %d bytes to %s" % (os.path.getsize(path), os.path.basename(path)))
    _drop_idle_connection(session)

    print("  restoring it to %s: %s"
          % (x.host.get_name_label(host), restore_host_config(session, ctx, host_url, host, path)))

    if len(hosts) > 1:
        other = hosts[1]
        other_url = _host_url(url, x.host.get_address(other))
        try:
            result = restore_host_config(session, ctx, other_url, other, path)
        except Exception as e:
            # A real pool's hosts are all reachable from a management client; this only guards an
            # environment (e.g. a simulator whose second host's address isn't actually routable
            # from here) where that isn't true, so the example still finishes cleanly.
            result = "could not connect to %s directly (%s)" % (other_url, e)
        print("  restoring it to %s: %s" % (x.host.get_name_label(other), result))

    os.remove(path)
    print("OK: backup-host-config")
    session.logout()


def _drop_idle_connection(session):
    """Close the session's HTTP connection after a long transfer; the next call opens a new one.
    The session itself is still valid - but its one keep-alive connection sat idle for as long as
    the transfer took, and a network that dropped it meanwhile leaves the next call hanging until
    the socket times out. (ServerProxy("close")() is xmlrpc.client's way to close its transport.)"""
    session("close")()


def restore_host_config(session, ctx, host_url, host, path):
    """Upload a backup to a host - over a connection opened to THAT host's own address - and
    report what the task says about it."""
    x = session.xenapi
    task = x.task.create("host_restore", "restoring a configuration backup")
    try:
        with open(path, "rb") as f:
            request = urllib.request.Request(
                "%s/host_restore?session_id=%s&ref=%s&task_id=%s" % (host_url, session._session, host, task),
                data=f, headers={"Content-Length": str(os.path.getsize(path))}, method="PUT")
            urllib.request.urlopen(request, context=ctx, timeout=10).read()
        _drop_idle_connection(session)

        while x.task.get_status(task) == "pending":
            time.sleep(0.5)
        if x.task.get_status(task) == "success":
            return "accepted"
        return "refused (%s)" % x.task.get_error_info(task)[-1]
    finally:
        x.task.destroy(task)


# Run it:
#   backup_host_config("https://xenserver", "root", password)


# --- Detach, reattach and forget storage -----------------------------------------------
def manage_sr_lifecycle(url, username, password, nfs_server="192.0.2.10", nfs_path="/export/spare"):
    """Take a storage repository offline, bring it back, then forget it.

    There is no "detach" call on an SR. A shared SR is joined to each host by one PBD -- a
    physical block device -- and detaching the SR means unplugging every one of them. That
    is why an SR can be attached on some hosts and not others, and why a repair action
    exists at all: it plugs back the PBDs that are missing."""
    session = connect(url, username, password)
    x = session.xenapi

    host = x.host.get_all()[0]
    sr = x.SR.create(host, {"server": nfs_server, "serverpath": nfs_path, "nfsversion": "3"},
                     "0", "sdk-example-lifecycle", "SR used by the SDK lifecycle example",
                     "nfs", "user", True, {})
    pbds = x.SR.get_PBDs(sr)
    print("%s: connected on %d of %d host(s)"
          % (x.SR.get_name_label(sr), attached_pbds(x, pbds), len(pbds)))

    for pbd in pbds:
        x.PBD.unplug(pbd)
    print("  detached:   connected on %d host(s)" % attached_pbds(x, pbds))

    # Plugging them back is exactly what a repair does.
    for pbd in pbds:
        x.PBD.plug(pbd)
    print("  reattached: connected on %d host(s)" % attached_pbds(x, pbds))

    x.SR.scan(sr)
    print("  rescanned:  %d disk(s)" % len(x.SR.get_VDIs(sr)))

    # Forgetting drops the pool's record of the SR but leaves the storage itself untouched,
    # so the same export can be introduced again later. Detach before forgetting: a
    # connected SR is still in use.
    for pbd in pbds:
        x.PBD.unplug(pbd)
    x.SR.forget(sr)
    print("  forgotten")
    print("OK: manage-sr-lifecycle")
    session.logout()


def attached_pbds(x, pbds):
    """How many of these connections are currently live."""
    return sum(1 for pbd in pbds if x.PBD.get_currently_attached(pbd))
# Run it:
#   manage_sr_lifecycle("https://xenserver", "root", password)


# --- Set the pool's default storage ------------------------------------------------------
def set_default_sr(url, username, password, nfs_server="192.0.2.10", nfs_path="/export/spare"):
    """Choose where the pool puts new disks, suspended VMs and crash dumps by default.

    These are three separate settings, not one. New disks land on the default SR, a
    suspended VM's memory image goes to the suspend-image SR and host crash dumps to the
    crash-dump SR -- they are usually the same storage, but they need not be."""
    session = connect(url, username, password)
    x = session.xenapi
    pool = x.pool.get_all()[0]

    # Capture all three separately. They are genuinely independent, and a pool that has
    # never suspended or crashed anything can legitimately leave the latter two unset -- so
    # restoring all three from the default would quietly invent settings that were not there.
    before = x.pool.get_default_SR(pool)
    before_suspend = x.pool.get_suspend_image_SR(pool)
    before_crash = x.pool.get_crash_dump_SR(pool)
    print("default storage:  %s" % sr_label(x, before))
    print("  suspend images: %s" % sr_label(x, before_suspend))
    print("  crash dumps:    %s" % sr_label(x, before_crash))

    # Somewhere to switch to. A pool default has to be reachable from every host, so it is
    # a shared SR; a local one would strand any VM whose disk landed on the wrong host.
    sr = x.SR.create(host_first(x), {"server": nfs_server, "serverpath": nfs_path, "nfsversion": "3"},
                     "0", "sdk-example-default", "SR used by the SDK default-storage example",
                     "nfs", "user", True, {})
    x.pool.set_default_SR(pool, sr)
    x.pool.set_suspend_image_SR(pool, sr)
    x.pool.set_crash_dump_SR(pool, sr)
    print("  switched to:    %s" % sr_label(x, x.pool.get_default_SR(pool)))

    # Restore the original choice before tidying up: an SR that is still the pool default is
    # the awkward one to remove.
    x.pool.set_default_SR(pool, before)
    x.pool.set_suspend_image_SR(pool, before_suspend)
    x.pool.set_crash_dump_SR(pool, before_crash)
    for pbd in x.SR.get_PBDs(sr):
        x.PBD.unplug(pbd)
    x.SR.forget(sr)
    print("  restored to:    %s" % sr_label(x, x.pool.get_default_SR(pool)))
    print("OK: set-default-sr")
    session.logout()


def host_first(x):
    return x.host.get_all()[0]


def sr_label(x, sr):
    """An SR's name, tolerating the null reference an unset pool field holds."""
    return x.SR.get_name_label(sr) if sr and sr != "OpaqueRef:NULL" else "(none)"
# Run it:
#   set_default_sr("https://xenserver", "root", password)


# --- Collect a server status report ------------------------------------------------------
def server_status_report(url, username, password):
    """Gather a host's diagnostic bundle -- the archive support asks for.

    The host publishes a catalogue of the sections it can report on, each with a size
    estimate and whether it may contain personal data, so a client can offer an informed
    choice rather than hard-coding the list. The bundle itself is an HTTP download
    alongside the API, and the chosen sections travel in the query string."""
    session = connect(url, username, password)
    x = session.xenapi
    ctx = ssl._create_unverified_context()

    # Report on the coordinator. Each host answers for itself, so which one you ask decides
    # whose logs you get -- support normally wants every host, one download each.
    host = x.pool.get_master(x.pool.get_all()[0])
    print("Status report for %s" % x.host.get_name_label(host))

    keys, defaults = [], []
    for capability in ET.fromstring(x.host.get_system_status_capabilities(host)):
        keys.append(capability.get("key"))
        if capability.get("default-checked") == "yes":
            defaults.append(capability.get("key"))
        print("  %-22s max %9s bytes  default=%-3s pii=%s"
              % (capability.get("key"), capability.get("max-size"),
                 capability.get("default-checked"), capability.get("pii")))

    # Take the sections the host marks default-checked, as XenCenter's dialog does: asking for every
    # section can mean gigabytes (VM memory dumps, every log) and a long wait while the host builds it.
    whole = fetch_status_report(url, session, ctx, defaults)
    print("default sections (%d of %d): %d bytes" % (len(defaults), len(keys), whole))

    # Pick a real, small section from the host's own catalogue rather than assuming a name: the
    # catalogue is server-defined (xen-bugtool's own --capabilities output), not a fixed client
    # list, and "xenserver-config" isn't one of the real keys any host actually publishes.
    subset_key = next((k for k in keys if k in ("firstboot", "network-status")), keys[0])
    subset = fetch_status_report(url, session, ctx, [subset_key])
    print("%s only:   %d bytes" % (subset_key, subset))
    if subset >= whole:
        print("  ERROR: selecting fewer sections did not produce a smaller bundle")

    print("OK: server-status-report")
    session.logout()


def fetch_status_report(url, session, ctx, entries):
    """Download the bundle for the given capability keys (a tar archive) to a file, streaming it -
    a report can be large - and return its size. This example then deletes it; you'd keep it."""
    request = "%s/system-status?session_id=%s&output=tar&entries=%s" \
              % (url, session._session, ",".join(entries))
    handle, path = tempfile.mkstemp(prefix="sdk-example-status-", suffix=".tar")
    try:
        with os.fdopen(handle, "wb") as out, urllib.request.urlopen(request, context=ctx) as response:
            shutil.copyfileobj(response, out, 1024 * 1024)
        return os.path.getsize(path)
    finally:
        os.remove(path)
# Run it:
#   server_status_report("https://xenserver", "root", password)


# --- Recover VMs after a disaster --------------------------------------------------------
def disaster_recovery(url, username, password, dr_url=None):
    """Replicate the pool's database to shared storage, then recover a VM out of it onto a second,
    standby pool.

    Disaster recovery works by writing the pool's own database out to a storage repository
    as a disk of type "metadata". That disk can be read back as a SEPARATE database --
    VDI.open_database hands you a session scoped to it -- so the ordinary calls describe
    the pool as it was replicated rather than the pool you are connected to. Recovering
    reads from that database and writes into a live pool, which is why the recover call
    is made on the metadata session and takes a live session as its destination.

    That destination has to be a DIFFERENT, standby pool: recovering a VM back into the exact
    pool it was replicated from can't actually succeed with force=False. The VM's uuid already
    exists there, so VM.recover always takes the replace-or-fail path, and nothing replicated a
    moment ago from a live database can ever be "newer" than the live object it came from - it
    fails with VM_TO_IMPORT_IS_NOT_NEWER_VERSION. The one-line "fix" of passing force=True instead
    would make it succeed by REPLACING (destroying and recreating) the live original - exactly the
    opposite of what a DR demo should show. A second pool is the only way force=False succeeds (a
    brand-new VM object, not a replace), and it's what every real DR workflow actually does.
    Track the recovered VM by uuid, never by name: a name can coincidentally collide with
    something already on the destination pool, and tidy-up must never guess by name."""
    if not dr_url:
        raise RuntimeError("disaster-recovery needs a second pool to recover into: pass "
                            "dr_url=<url of a standby pool>")
    session = connect(url, username, password)
    dr_session = connect(dr_url, username, password)
    x = session.xenapi

    # Replication needs storage every host can reach and that can hold data. The server
    # checks rather than taking your word for it, so ask before enabling.
    sr = next(ref for ref, r in x.SR.get_all_records().items()
              if r["shared"] and r["content_type"] != "iso" and r["type"] not in ("iso", "udev"))
    x.SR.assert_supports_database_replication(sr)
    print("Replicating pool metadata to %s" % x.SR.get_name_label(sr))
    x.SR.enable_database_replication(sr)

    vdi = next(v for v in x.SR.get_VDIs(sr) if x.VDI.get_type(v) == "metadata")
    print("  metadata disk: %s" % x.VDI.get_uuid(vdi))

    # A session onto the replicated database rather than the live pool. The binding keeps the
    # session id in _session, so a second Session can be pointed at the one we were handed.
    metadata = XenAPI.Session(url, ignore_ssl=True)
    metadata._session = x.VDI.open_database(vdi)

    # Only real guest VMs are recoverable - exclude templates, control domains and snapshots.
    recoverable = {ref: r for ref, r in metadata.xenapi.VM.get_all_records().items()
                   if not r["is_a_template"] and not r["is_control_domain"] and not r["is_a_snapshot"]}
    print("  the replicated database describes %d recoverable VM(s)" % len(recoverable))

    target = sorted(recoverable, key=lambda ref: recoverable[ref]["name_label"])[0]
    target_uuid = recoverable[target]["uuid"]
    name = recoverable[target]["name_label"]
    print("  recovering %s" % name)

    # Both calls run on the METADATA session; session_to says where the VM should land - the
    # STANDBY pool's session, not this one.
    dr_session_id = dr_session._session
    metadata.xenapi.VM.assert_can_be_recovered(target, dr_session_id)
    metadata.xenapi.VM.recover(target, dr_session_id, False)

    # It is a real VM on the standby pool now, not merely a call that returned - look it up by the
    # uuid full_restore preserved, not by name.
    recovered = dr_session.xenapi.VM.get_by_uuid(target_uuid)
    print("  %s is %s on the standby pool" % (name, dr_session.xenapi.VM.get_power_state(recovered)))

    # Tidy up on the standby pool only, by uuid - never touch the source pool's VMs, and never
    # guess by name (a coincidentally-same-named VM must not be destroyed).
    destroy_vm_and_disks(dr_session, recovered)
    x.SR.disable_database_replication(sr)
    print("OK: disaster-recovery")
    session.xenapi.session.logout()
    dr_session.xenapi.session.logout()
# Run it:
#   disaster_recovery("https://xenserver", "root", password, dr_url="https://standby-pool")


# --- Manage Secure Boot certificates -----------------------------------------------------
def manage_secureboot_certificates(url, username, password):
    """Check UEFI Secure Boot readiness, then flag a guest for a certificate refresh.

    A Secure Boot guest carries its own copy of the pool's UEFI certificates, taken when it
    was created. Rotating the pool's leaves the guest's stale, and the fix is applied at the
    guest's next boot rather than underneath a running VM -- so you flag it and reboot when
    convenient. Flagging and unflagging are the same call with opposite booleans.

    The precondition is the part worth being honest about: this needs a VM whose Secure Boot
    certificates are already due to refresh (secureboot_certificates_state == update_available).
    That's a deliberately-provisioned state, not one a normally-provisioned Secure Boot guest is
    ever in - so report and stop cleanly when no VM needs it, rather than failing with a bare
    lookup error."""
    session = connect(url, username, password)
    x = session.xenapi
    pool = x.pool.get_all()[0]

    # Whether the pool holds the certificates to hand out at all. "ready_no_dbx" means it has
    # the essentials but no revocation list -- usable, and not the same answer as "ready".
    print("Pool Secure Boot readiness: %s" % x.pool.get_guest_secureboot_readiness(pool))
    print("  pool holds certificates:  %s" % bool(x.pool.get_uefi_certificates(pool)))

    # A guest whose certificates have gone stale. Its state is what a client gates the
    # flag/unflag actions on, so it is the field to watch.
    vm = next((ref for ref, r in x.VM.get_all_records().items()
               if not r["is_a_template"] and not r["is_control_domain"] and not r["is_a_snapshot"]
               and r["secureboot_certificates_state"] == "update_available"), None)
    if vm is None:
        print("No guest needs a Secure Boot certificate refresh right now.")
        print("OK: manage-secureboot-certificates")
        session.logout()
        return
    print("%s: readiness %s, certificates %s"
          % (x.VM.get_name_label(vm), x.VM.get_secureboot_readiness(vm),
             x.VM.get_secureboot_certificates_state(vm)))

    x.VM.update_secureboot_certificates_on_boot(vm, True)
    print("  flagged for refresh:      %s" % x.VM.get_secureboot_certificates_state(vm))

    x.VM.update_secureboot_certificates_on_boot(vm, False)
    print("  unflagged:                %s" % x.VM.get_secureboot_certificates_state(vm))

    print("OK: manage-secureboot-certificates")
    session.logout()
# Run it:
#   manage_secureboot_certificates("https://xenserver", "root", password)


# --- Restart a host ----------------------------------------------------------------------
def restart_host(url, username, password):
    """Take a host down and bring it back, the way the host menu does.

    Rebooting a host is never just the reboot: anything running on it has to go
    somewhere first, and the host has to stop accepting new VMs while that happens.
    Disable, evacuate, reboot, re-enable. Disabling with the default auto_enable=true clears itself
    once the host's toolstack is back up; an explicit enable doesn't depend on that, or on when.
    Powering it right off and back on again is a second, separate demonstration, and only a
    meaningful one if the host actually has an out-of-band power-on mode configured: a real
    host.power_on has no retry of its own and simply fails if none is set up, leaving the host off
    with no API-level way to revive it."""
    session = connect(url, username, password)
    x = session.xenapi
    pool = x.pool.get_all()[0]

    # Not the coordinator: it is the host this session is talking to, and taking it down
    # would drop the connection underneath the rest of the example.
    coordinator = x.pool.get_master(pool)
    host = next(h for h in x.host.get_all() if h != coordinator)
    print("Restarting %s" % x.host.get_name_label(host))
    print("  enabled=%s, guests=%d" % (x.host.get_enabled(host), guest_count(x, host)))

    # Disabled means "accept no new VMs"; it does not move anything on its own.
    x.host.disable(host)
    print("  disabled:   enabled=%s" % x.host.get_enabled(host))

    # Evacuate moves the guests elsewhere in the pool. Afterwards only the control domain
    # -- the host's own management VM, which cannot move -- is left.
    x.host.evacuate(host)
    print("  evacuated:  guests=%d" % guest_count(x, host))

    x.host.reboot(host)
    # A real reboot takes minutes. Wait for the host to drop out and come back (live in its
    # host_metrics), then enable it. A host disabled the default way (auto_enable=true) re-enables
    # itself once its toolstack is up again, but only then - and one disabled with auto_enable=false
    # never does - so enable it explicitly rather than depend on either.
    _wait_for_host_live(x, host, False, timeout=600)
    _wait_for_host_live(x, host, True, timeout=1200, interval=10)
    _enable_when_booted(x, host)
    print("  rebooted, re-enabled: enabled=%s" % x.host.get_enabled(host))

    # The other ending: off, and back on out of band -- but only demonstrated if that is actually
    # configured, and waiting for each transition before starting the next.
    if x.host.get_power_on_mode(host):
        x.host.disable(host)
        x.host.shutdown(host)
        _wait_for_host_live(x, host, False)
        print("  shut down:  live=%s" % host_live(x, host))
        x.host.power_on(host)
        _wait_for_host_live(x, host, True, timeout=1200, interval=10)
        print("  powered on: live=%s" % host_live(x, host))
        _enable_when_booted(x, host)
        print("  re-enabled: enabled=%s" % x.host.get_enabled(host))
    else:
        print("  skipping shutdown/power-on: no out-of-band power-on mode is configured on this host")

    print("OK: restart-host")
    session.logout()


def guest_count(x, host):
    """Resident VMs excluding the control domain, which never moves."""
    return len([v for v in x.host.get_resident_VMs(host)
                if not x.VM.get_is_control_domain(v)])


def host_live(x, host):
    return x.host_metrics.get_live(x.host.get_metrics(host))
# Run it:
#   restart_host("https://xenserver", "root", password)


# --- Create a VM and a template from a snapshot ------------------------------------------
def vm_from_snapshot(url, username, password, vm_name="db-01"):
    """Turn a snapshot into a new VM, and into a reusable custom template.

    A snapshot is a VM record with is_a_snapshot (and is_a_template) set, and cloning it gives a
    custom template that stands on its own while the snapshot stays put. That clone already is the
    template; provisioning another clone turns it into a VM, exactly as with any template."""
    session = connect(url, username, password)
    x = session.xenapi

    vm = vm_by_name(session, vm_name)
    snapshot = x.VM.snapshot(vm, "sdk-example-source-snapshot")
    print("Snapshot of %s taken" % vm_name)

    # A clone of a snapshot is a template, not another snapshot: it stands on its own instead of
    # being filed under the original VM. Provision it to get an ordinary VM you can start.
    new_vm = x.VM.clone(snapshot, "sdk-example-vm-from-snapshot")
    provision(session, new_vm)
    print("  new VM:      %s (is_a_template=%s)"
          % (x.VM.get_name_label(new_vm), x.VM.get_is_a_template(new_vm)))

    # Another clone, left as the template it already is: a starting point to stamp more VMs from.
    template = x.VM.clone(snapshot, "sdk-example-template-from-snapshot")
    print("  new template:%s (is_a_template=%s)"
          % (x.VM.get_name_label(template), x.VM.get_is_a_template(template)))

    # Each clone made its own disks, and the snapshot has its own snapshot disks; destroy them all.
    for ref in (new_vm, template):
        destroy_vm_and_disks(session, ref)
    destroy_vm_and_disks(session, snapshot)
    print("OK: vm-from-snapshot")
    session.logout()
# Run it:
#   vm_from_snapshot("https://xenserver", "root", password, "db-01")


# --- Attach an existing disk to another VM -----------------------------------------------
def attach_existing_disk(url, username, password):
    """Move an existing disk from one VM to another by re-attaching it.

    A disk and the VM it belongs to are separate objects joined by a VBD, so moving a disk
    between VMs is removing one VBD and creating another -- no copying, and the data stays
    exactly where it is. This is how you recover a disk from a VM you are retiring."""
    GIB = 1024 * 1024 * 1024
    session = connect(url, username, password)
    x = session.xenapi

    halted = [ref for ref, r in x.VM.get_all_records().items()
              if not r["is_a_template"] and not r["is_control_domain"] and not r["is_a_snapshot"]
              and r["power_state"] == "Halted"]
    first, second = halted[0], halted[1]

    sr = next(ref for ref, r in x.SR.get_all_records().items()
              if r["shared"] and r["content_type"] != "iso" and r["type"] not in ("iso", "udev"))
    vdi = x.VDI.create({
        "name_label": "sdk-example-portable-disk",
        "SR": sr, "virtual_size": str(4 * GIB), "type": "user",
        "sharable": False, "read_only": False, "other_config": {},
    })
    print("Disk %s created on %s" % (x.VDI.get_name_label(vdi), x.SR.get_name_label(sr)))

    vbd = attach_vdi(x, first, vdi)
    print("  attached to %s" % x.VM.get_name_label(first))

    # Destroying the VBD detaches the disk; the disk itself is untouched and keeps its data.
    x.VBD.destroy(vbd)
    print("  detached:   the disk still exists (%d bytes)" % int(x.VDI.get_virtual_size(vdi)))

    attach_vdi(x, second, vdi)
    print("  attached to %s" % x.VM.get_name_label(second))
    print("  the disk is on %d VM(s)" % len(x.VDI.get_VBDs(vdi)))

    for ref in x.VDI.get_VBDs(vdi):
        x.VBD.destroy(ref)
    x.VDI.destroy(vdi)
    print("OK: attach-existing-disk")
    session.logout()


def attach_vdi(x, vm, vdi):
    """Join an existing disk to a VM on its next free device slot."""
    return x.VBD.create({
        "VM": vm, "VDI": vdi, "userdevice": x.VM.get_allowed_VBD_devices(vm)[0],
        "bootable": False,
        "mode": "RW", "type": "Disk", "empty": False, "other_config": {},
        "qos_algorithm_type": "", "qos_algorithm_params": {},
    })
# Run it:
#   attach_existing_disk("https://xenserver", "root", password)


# --- Clear a host's crash dumps ------------------------------------------------------------
def manage_crash_dumps(url, username, password):
    """Find and delete the crash dumps a host kept after a failure.

    When a host crashes it writes a dump to its local disk and keeps it. They are large, they
    are never cleaned up on their own, and on a host that has crashed more than once they add
    up -- so clearing them once support has what it needs is ordinary housekeeping."""
    session = connect(url, username, password)
    x = session.xenapi

    # Crash dumps belong to the host that wrote them, so clear them a host at a time.
    host = next((h for h in x.host.get_all() if x.host.get_crashdumps(h)), None)
    if host is None:
        print("No crash dumps in this pool -- nothing to clear.")
        print("OK: manage-crash-dumps")
        session.logout()
        return

    dumps = x.host.get_crashdumps(host)
    total = 0
    print("%s has %d crash dump(s)" % (x.host.get_name_label(host), len(dumps)))
    for ref in dumps:
        record = x.host_crashdump.get_record(ref)
        total += int(record["size"])
        print("  %s  %s" % (record["timestamp"], mib(record["size"])))
    print("  %s in total" % mib(total))

    # Deleting a dump frees the space on the host; the host itself is untouched.
    for ref in dumps:
        x.host_crashdump.destroy(ref)
    print("  cleared:  %s now has %d"
          % (x.host.get_name_label(host), len(x.host.get_crashdumps(host))))

    print("OK: manage-crash-dumps")
    session.logout()


def mib(size):
    return "%d MiB" % (int(size) // (1024 * 1024))
# Run it:
#   manage_crash_dumps("https://xenserver", "root", password)


# --- Configure pool options ----------------------------------------------------------------
def configure_pool_options(url, username, password):
    """Read and change the pool-wide options that govern how the pool behaves.

    None of these is a wizard: they are plain pool settings that a client exposes on a
    properties page, and each is a single field. Read them, change them, put them back."""
    session = connect(url, username, password)
    x = session.xenapi
    pool = x.pool.get_all()[0]

    before = {
        "live patching disabled": x.pool.get_live_patching_disabled(pool),
        "IGMP snooping":          x.pool.get_igmp_snooping_enabled(pool),
        "migration compression":  x.pool.get_migration_compression(pool),
    }
    for name, value in before.items():
        print("  %-22s %s" % (name, value))

    # Live patching applies host updates without a reboot; disabling it forces the reboot.
    x.pool.set_live_patching_disabled(pool, not before["live patching disabled"])
    # IGMP snooping keeps multicast off ports that did not ask for it.
    x.pool.set_igmp_snooping_enabled(pool, not before["IGMP snooping"])
    # Compression trades CPU for bandwidth when a VM's memory is moved between hosts.
    x.pool.set_migration_compression(pool, not before["migration compression"])

    print("after changing:")
    print("  %-22s %s" % ("live patching disabled", x.pool.get_live_patching_disabled(pool)))
    print("  %-22s %s" % ("IGMP snooping", x.pool.get_igmp_snooping_enabled(pool)))
    print("  %-22s %s" % ("migration compression", x.pool.get_migration_compression(pool)))

    x.pool.set_live_patching_disabled(pool, before["live patching disabled"])
    x.pool.set_igmp_snooping_enabled(pool, before["IGMP snooping"])
    x.pool.set_migration_compression(pool, before["migration compression"])
    print("  restored")
    print("OK: configure-pool-options")
    session.logout()
# Run it:
#   configure_pool_options("https://xenserver", "root", password)


# --- Configure console access ----------------------------------------------------------------
def configure_console_access(url, username, password):
    """Tighten how consoles and management traffic may be used.

    Idle console sessions are set at two levels -- the pool's own management consoles and the
    VM consoles it serves -- and a host can override the pool's. Requiring HTTPS refuses plain
    HTTP to the management interface altogether."""
    session = connect(url, username, password)
    x = session.xenapi
    pool = x.pool.get_all()[0]
    host = x.pool.get_master(pool)

    # NB: pool.https_only and pool.console_idle_timeout are SET below but never read back. SDK 26.14
    # generates a setter and no getter for both (unlike host.console_idle_timeout, which has both), so
    # they cannot be read through the typed bindings at all — and a sample that reached past its own
    # binding to show a value would be teaching a workaround rather than the API.
    print("  %-26s %ss" % ("VM console idle timeout", x.pool.get_vm_console_idle_timeout(pool)))
    print("  %-26s %s" % ("limit console sessions", x.pool.get_limit_console_sessions(pool)))
    print("  %-26s %ss" % ("host console idle timeout", x.host.get_console_idle_timeout(host)))

    # Ten minutes of inactivity, one console session at a time, and no plain HTTP.
    x.pool.set_console_idle_timeout(pool, "600")
    x.pool.set_vm_console_idle_timeout(pool, "600")
    x.pool.set_limit_console_sessions(pool, True)
    x.host.set_console_idle_timeout(host, "300")
    x.pool.set_https_only(pool, True)

    print("after tightening:")
    print("  %-26s %ss" % ("VM console idle timeout", x.pool.get_vm_console_idle_timeout(pool)))
    print("  %-26s %s" % ("limit console sessions", x.pool.get_limit_console_sessions(pool)))
    print("  %-26s %ss" % ("host console idle timeout", x.host.get_console_idle_timeout(host)))

    x.pool.set_https_only(pool, False)
    x.pool.set_console_idle_timeout(pool, "0")
    x.pool.set_vm_console_idle_timeout(pool, "0")
    x.pool.set_limit_console_sessions(pool, False)
    x.host.set_console_idle_timeout(host, "0")
    print("  restored")
    print("OK: configure-console-access")
    session.logout()
# Run it:
#   configure_console_access("https://xenserver", "root", password)


# --- Configure host storage --------------------------------------------------------------------
def configure_host_storage(url, username, password):
    """Set a host's iSCSI initiator name and turn on storage multipathing.

    The IQN identifies this host to iSCSI targets, so a target's access list is written
    against it -- changing it on a host with live iSCSI storage cuts it off. Multipathing uses
    every path to the storage rather than one, and on real hardware you put the host into
    maintenance mode before changing it, because the paths are rebuilt."""
    session = connect(url, username, password)
    x = session.xenapi
    host = x.pool.get_master(x.pool.get_all()[0])

    before_iqn = x.host.get_iscsi_iqn(host)
    before_multipathing = x.host.get_multipathing(host)
    print("%s: iSCSI IQN %r, multipathing %s"
          % (x.host.get_name_label(host), before_iqn, before_multipathing))

    x.host.set_iscsi_iqn(host, "iqn.2026-01.com.example:%s" % x.host.get_name_label(host))
    x.host.set_multipathing(host, True)
    print("  IQN now:      %s" % x.host.get_iscsi_iqn(host))
    print("  multipathing: %s" % x.host.get_multipathing(host))

    # set_iscsi_iqn refuses an empty string (INVALID_VALUE); only restore it if this host actually
    # had one set before - a host that has never had an IQN configured has it empty, and there is
    # no way to set it back to empty through this call.
    if before_iqn:
        x.host.set_iscsi_iqn(host, before_iqn)
    x.host.set_multipathing(host, before_multipathing)
    print("  restored")
    print("OK: configure-host-storage")
    session.logout()
# Run it:
#   configure_host_storage("https://xenserver", "root", password)


# --- Configure remote syslog ---------------------------------------------------------------
def configure_syslog(url, username, password, syslog_server="192.0.2.50"):
    """Send a host's logs to a remote syslog server.

    Two steps, and the second is the one that is easy to miss: setting the destination only
    records it, and the host keeps logging locally until the syslog daemon is reconfigured to
    pick the setting up."""
    session = connect(url, username, password)
    x = session.xenapi
    host = x.pool.get_master(x.pool.get_all()[0])

    print("%s logging: %s" % (x.host.get_name_label(host), x.host.get_logging(host) or "(local only)"))

    x.host.remove_from_logging(host, "syslog_destination")
    x.host.add_to_logging(host, "syslog_destination", syslog_server)
    x.host.syslog_reconfigure(host)
    print("  now logging to: %s" % x.host.get_logging(host)["syslog_destination"])

    x.host.remove_from_logging(host, "syslog_destination")
    x.host.syslog_reconfigure(host)
    print("  restored: %s" % (x.host.get_logging(host) or "(local only)"))
    print("OK: configure-syslog")
    session.logout()
# Run it:
#   configure_syslog("https://xenserver", "root", password)


# --- Manage driver variants ----------------------------------------------------------------
def manage_driver_variants(url, username, password):
    """Inspect a host's device drivers and choose which variant of one to use.

    A driver can ship in several variants -- a vendor build alongside the one in the
    distribution, say. One is *selected* (what the host will load) and one is *active* (what it
    has loaded); they differ until the host reboots, which is what makes selecting a variant a
    scheduled change rather than an immediate one."""
    session = connect(url, username, password)
    x = session.xenapi
    host = x.pool.get_master(x.pool.get_all()[0])

    drivers = {ref: r for ref, r in x.Host_driver.get_all_records().items() if r["host"] == host}
    print("%s has %d driver(s)" % (x.host.get_name_label(host), len(drivers)))
    for ref, driver in sorted(drivers.items(), key=lambda kv: kv[1]["name"])[:3]:
        print("  %-14s %-10s %d variant(s), active=%s"
              % (driver["name"], driver["type"], len(driver["variants"]),
                 variant_name(x, driver["active_variant"])))

    # Select a variant explicitly. It becomes the selected one immediately; whether it is also
    # active depends on whether the hardware is present and the driver already loaded.
    # Host_driver.select refuses a variant whose hardware isn't present (HOST_DRIVER_NO_HARDWARE) -
    # and a host lists drivers for plenty of devices it doesn't have - so pick a driver for hardware
    # this host actually has, and one of its variants that is usable.
    usable = [(ref, v) for ref, d in sorted(drivers.items(), key=lambda kv: kv[1]["name"])
              for v in d["variants"] if x.Driver_variant.get_hardware_present(v)]
    if not usable:
        raise RuntimeError("no driver on %s has a variant for hardware it has" % x.host.get_name_label(host))
    ref, variant = usable[0]
    x.Host_driver.select(ref, variant)
    after = x.Host_driver.get_record(ref)
    print("  %s: selected %s, active %s"
          % (after["name"], variant_name(x, after["selected_variant"]),
             variant_name(x, after["active_variant"])))

    print("OK: manage-driver-variants")
    session.logout()


def variant_name(x, ref):
    """A driver variant's name, tolerating the null reference an unloaded driver has."""
    return x.Driver_variant.get_name(ref) if ref and ref != "OpaqueRef:NULL" else "(none)"
# Run it:
#   manage_driver_variants("https://xenserver", "root", password)


# --- end of workflows ---

def _wf(fn, **defaults):
    """Wrap a workflow function with its dispatcher defaults (chosen to work against the
    simulator), letting the command line override any of them by keyword."""
    def run(url, user, pw, **overrides):
        kwargs = dict(defaults)
        kwargs.update(overrides)
        return fn(url, user, pw, **kwargs)
    return run


WORKFLOWS = {
    "connect-inventory": _wf(connect_inventory),
    "create-vm": _wf(create_vm, template_name="Rocky Linux 8"),
    "vm-lifecycle": _wf(vm_lifecycle, source_vm="web-01"),
    "manage-vm-disks": _wf(manage_vm_disks, source_vm="web-01", sr_name="Shared NFS"),
    "dismiss-alerts": _wf(dismiss_alerts),
    "host-power-on": _wf(host_power_on),
    "rotate-pool-secret": _wf(rotate_pool_secret),
    "change-root-password": _wf(change_root_password),
    "manage-certificates": _wf(manage_certificates),
    "snapshot-schedule": _wf(snapshot_schedule, vm_name="web-01"),
    "manage-vm-groups": _wf(manage_vm_groups, vm_name="web-01"),
    "snapshot-revert": _wf(snapshot_revert, vm_name="web-01"),
    "create-nfs-sr": _wf(create_nfs_sr, nfs_server="192.0.2.10", nfs_path="/export/sdk"),
    "create-network": _wf(create_network),
    "edit-vm-properties": _wf(edit_vm_properties, vm_name="web-01"),
    "events": _wf(events, vm_name="web-01"),
    "new-vm-wizard": _wf(new_vm_wizard, template_name="Rocky Linux 8"),
    "live-migrate": _wf(live_migrate, source_vm="web-01", sr_name="Shared NFS"),
    "host-maintenance": _wf(host_maintenance, source_vm="web-01", sr_name="Shared NFS"),
    "configure-ha": _wf(configure_ha, heartbeat_sr_name="Shared NFS"),
    "copy-vm": _wf(copy_vm, vm_name="db-01", sr_name="Shared NFS"),
    "create-vm-with-vgpu": _wf(create_vm_with_vgpu, template_name="Rocky Linux 8"),
    "tags-and-folders": _wf(tags_and_folders, vm_name="web-01"),
    "configure-updates": _wf(configure_updates, repo_url="https://repo.ops.xenserver.com/xs9",
                             source_url="https://repo-src.ops.xenserver.com/xs9"),
    "clone-vm": _wf(clone_vm, vm_name="db-01"),
    "delete-vm": _wf(delete_vm, template_name="Rocky Linux 8"),
    "storage-migrate": _wf(storage_migrate, source_vm="web-01"),
    "apply-update": _wf(apply_update, repo_url="https://repo.ops.xenserver.com/xs9",
                        source_url="https://repo-src.ops.xenserver.com/xs9"),
    "checkpoint-vm": _wf(checkpoint_vm, source_vm="web-01"),
    "attach-disk": _wf(attach_disk, template_name="Rocky Linux 8", sr_name="Shared NFS"),
    "wait-for-task": _wf(wait_for_task, template_name="Rocky Linux 8"),
    "error-handling": _wf(error_handling),
    "list-templates": _wf(list_templates),
    "custom-fields": _wf(custom_fields, vm_name="web-01"),
    "gpu-inventory": _wf(gpu_inventory),
    "read-metrics": _wf(read_metrics),
    "rename-object": _wf(rename_object, vm_name="web-01"),
    "vm-boot-config": _wf(vm_boot_config, template_name="Rocky Linux 8"),
    "host-info": _wf(host_info),
    "list-roles": _wf(list_roles),
    "pool-properties": _wf(pool_properties),
    "sr-usage": _wf(sr_usage),
    "manage-vif": _wf(manage_vif, template_name="Rocky Linux 8"),
    "list-networks": _wf(list_networks),
    "vbd-inventory": _wf(vbd_inventory, vm_name="db-01"),
    "pool-tags": _wf(pool_tags),
    "convert-to-template": _wf(convert_to_template, template_name="Rocky Linux 8"),
    "find-by-uuid": _wf(find_by_uuid, vm_name="web-01"),
    "rolling-pool-update": _wf(rolling_pool_update, repo_url="https://repo.ops.xenserver.com/xs9",
                               source_url="https://repo-src.ops.xenserver.com/xs9"),
    "pvs-accelerator": _wf(pvs_accelerator),
    "configure-pvs-accelerator": _wf(configure_pvs_accelerator, vm_name="db-01"),
    "manage-ssh-access": _wf(manage_ssh_access),
    "manage-vtpm": _wf(manage_vtpm),
    "configure-dynamic-memory": _wf(configure_dynamic_memory),
    "manage-vm-media": _wf(manage_vm_media),
    "backup-host-config": _wf(backup_host_config),
    "manage-sr-lifecycle": _wf(manage_sr_lifecycle),
    "set-default-sr": _wf(set_default_sr),
    "server-status-report": _wf(server_status_report),
    "disaster-recovery": _wf(disaster_recovery),
    "manage-secureboot-certificates": _wf(manage_secureboot_certificates),
    "restart-host": _wf(restart_host),
    "manage-crash-dumps": _wf(manage_crash_dumps),
    "configure-pool-options": _wf(configure_pool_options),
    "configure-console-access": _wf(configure_console_access),
    "configure-host-storage": _wf(configure_host_storage),
    "configure-syslog": _wf(configure_syslog),
    "manage-driver-variants": _wf(manage_driver_variants),
    "vm-from-snapshot": _wf(vm_from_snapshot, vm_name="db-01"),
    "attach-existing-disk": _wf(attach_existing_disk),
    "export-import-vm": _wf(export_import_vm, vm_name="db-01"),
    "changed-block-tracking": _wf(changed_block_tracking),
    "control-domain-memory": _wf(control_domain_memory),
    "rrd-metrics": _wf(rrd_metrics),
    "reclaim-space": _wf(reclaim_space),
    "vm-ip-address": _wf(vm_ip_address),
    "manage-ad-users": _wf(manage_ad_users, domain="", admin_user="alice",
                            admin_password="Password1", new_user="alice"),
    "create-iscsi-sr": _wf(create_iscsi_sr, target="192.0.2.30"),
    "create-smb-sr": _wf(create_smb_sr, server="192.0.2.40", share="/vmstore",
                          smb_username="Administrator", smb_password="Password1"),
    "create-hba-sr": _wf(create_hba_sr),
    "create-iso-sr": _wf(create_iso_sr, location="192.0.2.10:/isos"),
    "configure-nrpe": _wf(configure_nrpe),
    "configure-snmp": _wf(configure_snmp, trap_destination="192.0.2.50"),
    "configure-clustering": _wf(configure_clustering),
    "manage-pool-membership": _wf(manage_pool_membership),
    "create-bond": _wf(create_bond),
    "manage-vapp": _wf(manage_vapp, vm_name="db-01"),
    "attach-usb-device": _wf(attach_usb_device, vm_name="web-01"),
    "wlb-recommendations": _wf(wlb_recommendations, vm_name="web-01", wlb_host_port="wlb.example:8012",
                               wlb_username="wlbuser", wlb_password="wlbpass"),
}


def main():
    # cross-pool-copy-vm spans two pools, so it takes the destination pool's URL as a 5th argument,
    # then optionally that pool's credentials (if they differ from the source's) and the VM to copy.
    if len(sys.argv) >= 2 and sys.argv[1] == "cross-pool-copy-vm":
        if len(sys.argv) not in (6, 8, 9):
            print("usage: python workflows.py cross-pool-copy-vm <sourceUrl> <user> <password> <destUrl>"
                  " [<destUser> <destPassword> [<vmName>]]", file=sys.stderr)
            return 2
        dest_creds = sys.argv[6:8] if len(sys.argv) >= 8 else [None, None]
        cross_pool_copy_vm(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
                           vm_name=sys.argv[8] if len(sys.argv) == 9 else "db-01",
                           dest_username=dest_creds[0], dest_password=dest_creds[1])
        return 0

    if len(sys.argv) < 5 or sys.argv[1] not in WORKFLOWS:
        print("usage: python workflows.py <%s|cross-pool-copy-vm> <url> <user> <password> "
              "[key=value ...]" % "|".join(WORKFLOWS), file=sys.stderr)
        return 2

    workflow, url, user, password = sys.argv[1:5]
    overrides = {}
    for arg in sys.argv[5:]:
        if "=" not in arg:
            print("extra arguments must be key=value (got %r)" % arg, file=sys.stderr)
            return 2
        key, value = arg.split("=", 1)
        overrides[key] = value
    WORKFLOWS[workflow](url, user, password, **overrides)
    return 0


if __name__ == "__main__":
    sys.exit(main())
