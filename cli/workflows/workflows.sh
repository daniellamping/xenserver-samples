#!/usr/bin/env bash
# XenServer CLI (xe) - real-world workflow examples.
#
# Each example performs a common pool-management task entirely through the `xe` command line interface.
# `xe` runs the command server-side over XAPI's thin-CLI protocol, so these are exactly the commands you
# would type against a real host. Objects are addressed by UUID (captured with `--minimal`), and commands
# take `name=value` arguments (with `device-config:key=value` for nested maps).
#
# Usage:
#   ./workflows.sh <workflow> <url> <username> <password> [key=value ...]
#     <workflow>  connect-inventory | create-vm | vm-lifecycle | ... (see the dispatcher for the full list)
#     <url>       e.g. https://xenserver  (see the note on ports below)
#
# Most workflows need only the connection details and run against the dispatcher's built-in
# (simulator-friendly) defaults below. A few need environment-specific values to do anything real - an
# iSCSI target address, an AD domain, a second pool to recover into - and take them as extra key=value
# arguments after the password, overriding that workflow's default for the named parameter (e.g.
# `create-iscsi-sr <url> <user> <pw> target=10.1.2.3`, `disaster-recovery <url> <user> <pw>
# dr_url=https://standby-pool`). cross-pool-copy-vm keeps its own positional form instead
# (<src> <user> <pw> <destUrl> [<destUser> <destPassword> [<vmName>]]).
set -e

# Under Git Bash/MSYS, an argument that looks like a Unix path (e.g. serverpath=/export/vol1) gets
# rewritten to a Windows path before xe sees it. These are all *remote* paths (NFS exports, folders),
# never local files, so disable that conversion for the whole script.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

workflow="$1"; url="$2"; user="$3"; pass="$4"
if [ "$workflow" = "cross-pool-copy-vm" ]; then   # only cross-pool-copy-vm takes these
    desturl="$5"; destuser="${6:-$user}"; destpass="${7:-$pass}"; copy_vm="${8:-db-01}"; shift $#
else shift 4; fi

# Every remaining argument is a key=value override of that workflow's own defaults (chosen to work
# against the simulator), the same story the other languages' dispatchers tell. `param` reads one back,
# falling through to the caller's default when it wasn't supplied on the command line.
declare -A params
for _arg in "$@"; do
    case "$_arg" in
        *=*) params[${_arg%%=*}]=${_arg#*=} ;;
        *) echo "extra arguments must be key=value (got '$_arg')" >&2; exit 2 ;;
    esac
done
param() {
    local key=$1 default=$2
    if [ "${params[$key]+set}" ]; then echo "${params[$key]}"; else echo "$default"; fi
}

# Parse host:port from the URL with pure bash parameter-expansion (no sed): strip the scheme, then any
# trailing path, then split host from port. On Windows every sed/cut/tr/grep is a process launch, so these
# examples parse `xe --minimal` output with bash builtins - each `xe` call is unavoidable, but the string
# plumbing around it stays in-process.
_hp=${url#*://}; _hp=${_hp%%/*}   # host[:port]
host=${_hp%%:*}
# A real host serves the CLI over TLS on 443, which is xe's default, so a URL with no port (or :443) needs
# no -p. xe uses TLS only on 443, so a test endpoint on any other port serves the CLI over plain HTTP on
# the next port up.
xe_opts=()
if [ "$_hp" != "$host" ] && [ "${_hp##*:}" != 443 ]; then xe_opts=(-p $((${_hp##*:} + 1))); fi
# The Windows xe.exe asks before trusting a certificate it has not seen, such as a host's self-signed one,
# and fails when there is no console to answer; accept it, as the SDK examples do. The Linux xe does not
# ask, and does not take these options.
case "${XE_EXE:-xe}" in *.exe | *.EXE) xe_opts+=(-no-warn-new-certificates -no-warn-certificates) ;; esac

# --- connect ---
# The one place the connection details live: every example just calls `xe <command> ...`.
xe() {
    # xe reports a failure on stdout. Captured by $(...), that text would land in the variable and set -e
    # would then stop the script without saying why, so pass a failure's output on to stderr instead.
    local out rc=0
    # `command`: when XE_EXE is unset, plain "xe" would be this function calling itself, without end.
    out=$(command "${XE_EXE:-xe}" -s "$host" "${xe_opts[@]}" -u "$user" -pw "$pass" "$@") || rc=$?
    if [ $rc -ne 0 ]; then [ -z "$out" ] || printf '%s\n' "$out" >&2; return $rc; fi
    [ -z "$out" ] || printf '%s\n' "$out"
}

# A pool member refuses every command with HOST_IS_SLAVE, naming the coordinator's address; send
# everything there instead (assuming the coordinator is up), as XenCenter does when you add a member server.
_probe=$(xe pool-list --minimal 2>&1) || true
if [[ $_probe =~ (Master|Coordinator)\ IP\ address:\ ([0-9A-Fa-f.:]+) ]]; then host=${BASH_REMATCH[2]}; fi

# Bash helpers for `--minimal` (comma-separated) output, so no cut/tr/wc/grep processes are spawned:
first_csv()  { echo "${1%%,*}"; }                       # first element of a comma-separated list
count_csv()  { local IFS=,; set -- $1; echo $#; }       # number of elements (0 for empty)
each_csv()   { local IFS=,; set -- $1; printf '%s\n' "$@"; }   # one element per line, for `for`
nth_csv()    { local n=$2 IFS=,; set -- $1; shift $((n - 1)); echo "$1"; }  # Nth element, 1-based
# A set-valued FIELD (vm-param-get param-name=VBDs, allowed-VBD-devices, ...) is printed "a; b; c" - with
# or without --minimal, which only turns a LIST of objects into a comma-separated line. Convert it, so the
# helpers above work on both.
set_to_csv() { echo "${1//; /,}"; }

shared_sr() { first_csv "$(xe sr-list name-label="Shared NFS" --minimal)"; }
first_host() { first_csv "$(xe host-list --minimal)"; }
vm_uuid()  { first_csv "$(xe vm-list name-label="$1" --minimal)"; }

# Detach an SR from every host, then forget it: XenCenter's Detach followed by Forget. sr-forget refuses an
# SR that is still attached (SR_HAS_PBD), so unplug its PBDs first. Forgetting drops the pool's record of the
# SR but leaves the data on the storage itself.
detach_and_forget_sr() {
    local pbd
    for pbd in $(each_csv "$(xe pbd-list sr-uuid=$1 currently-attached=true --minimal)"); do
        xe pbd-unplug uuid=$pbd
    done
    xe sr-forget uuid=$1
}

# The text content of the first <tag>...</tag> in an XML fragment, using parameter expansion only (no
# xmllint, and no sed/grep process per tag).
xml_tag_text() {
    local xml=$1 tag=$2 rest
    rest=${xml#*<$tag>}
    [ "$rest" != "$xml" ] || return 1
    echo "${rest%%</$tag>*}"
}

# Pick the IQN from an iSCSI discovery probe's XML: the caller's, if named (it must be one the target
# offers), else the first. An array usually offers many targets - one per LUN, often belonging to different
# users - so on shared storage always name yours: sr-create formats the LUN behind it.
choose_target_iqn() {
    local rest=$1 target=$2 wanted=$3 first="" iqn
    while [[ $rest == *"<TargetIQN>"* ]]; do
        rest=${rest#*<TargetIQN>}; iqn=${rest%%</TargetIQN>*}
        [ -n "$first" ] || first=$iqn
        if [ -n "$wanted" ] && [ "$iqn" = "$wanted" ]; then echo "$iqn"; return 0; fi
    done
    if [ -n "$wanted" ]; then echo "target $target does not offer IQN $wanted" >&2; return 1; fi
    echo "$first"
}

# Return the XML a backend sends back on its deliberately-failing discovery probe (args: sm-type, then
# any sr-probe arguments such as host-uuid=/device-config:key=value). The New SR wizard (and XenRT)
# discover iSCSI/HBA LUNs by asking with an incomplete device-config on purpose: the backend can't create
# anything from it yet, so it fails with an SR_BACKEND_FAILURE_<n> whose error parameters carry an XML
# fragment describing what it found - the IQNs on offer, then the LUNs behind one of them, or - for HBA -
# every LUN visible at all. A probe that unexpectedly succeeds means the device-config was already
# complete - not the discovery prompt this helper is looking for. Never probe by attempting sr-create
# instead: on real storage a create that succeeds formats the LUN.
probe_for_failure() {
    local sm_type=$1 out line xml=""
    shift
    if out=$(xe sr-probe type="$sm_type" "$@" 2>&1); then
        echo "SR.probe for $sm_type succeeded without asking for more information;" \
             "check the target address" >&2
        return 1
    fi
    # xe prints a known error as "Error code: ..." then "Error parameters: a, b, ..." (the Windows xe.exe
    # that ships with XenCenter says "Error params:"): the XML fragment is always the last parameter xapi
    # sends back, so it runs from the first '<' on that line to the end of the output (a real host
    # pretty-prints it over many lines).
    local in_params=""
    while IFS= read -r line; do
        if [ -n "$in_params" ]; then
            xml+=$'\n'"$line"
        else
            case "$line" in
                "Error param"*":"*"<"*) xml="<${line#*<}"; in_params=1 ;;
            esac
        fi
    done <<< "$out"
    if [ -z "$xml" ]; then
        echo "$out" >&2
        return 1
    fi
    echo "$xml"
}

# A throwaway self-signed certificate and private key (PEM), the way XenRT provisions one for its own
# certificate tests. bash has no native crypto library, so shell out to openssl - the same tool XenRT
# itself uses for this.
self_signed_cert() {
    local certfile=$1 keyfile=$2
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$keyfile" -out "$certfile" \
        -days 365 -subj /CN=sdk-example 2>/dev/null
}

# Wait out a pool-wide xapi restart (pool-designate-new-master) and find the new coordinator's address,
# updating $host - xe does not follow HOST_IS_SLAVE itself (see the probe at the top of this script).
#
# pool-designate-new-master returns BEFORE the change: for a while the old coordinator still answers, and
# still says it is the coordinator, until xapi restarts across the pool. So reconnecting is not enough -
# keep reconnecting until the pool names the new coordinator (by uuid) AND every host is back, enabled and
# live. XenRT's own helper likewise waits minutes before trusting the pool again.
reconnect_after_master_change() {
    local new_master_uuid=$1 timeout=600 interval=5 probe
    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        # Called as an if-condition, so set -e does not end the script when one of its xe calls fails -
        # and while xapi restarts across the pool, any of them can.
        if probe=$(xe pool-list --minimal 2>&1) && pool_settled_under "$new_master_uuid" "$probe"; then
            return 0
        fi
        if [[ $probe =~ (Master|Coordinator)\ IP\ address:\ ([0-9A-Fa-f.:]+) ]]; then
            host=${BASH_REMATCH[2]}
        fi
        sleep "$interval"
    done
    echo "the pool did not come back after the master change" >&2
    return 1
}

# True once the pool (uuid $2) names $1 as its coordinator AND every host is back, enabled and live. The
# new coordinator answers before the pool has settled - calls made too soon fail (HANDLE_INVALID on the
# operation's own task) - hence the second half.
pool_settled_under() {
    local master h
    master=$(xe pool-param-get uuid="$(first_csv "$2")" param-name=master) || return 1
    [ "$master" = "$1" ] || return 1
    for h in $(each_csv "$(xe host-list --minimal)"); do
        [ "$(xe host-param-get uuid=$h param-name=enabled)" = "true" ] || return 1
        [ "$(host_live "$h")" = "true" ] || return 1
    done
}

# Poll host_metrics.live until it matches, rather than issuing the next power command immediately - real
# out-of-band power control has no retry of its own, so a script that doesn't wait can issue a second
# command while the first is still in flight.
wait_for_host_live() {
    local h=$1 want=$2 timeout=${3:-60} interval=${4:-2}
    local deadline=$((SECONDS + timeout))
    while [ "$(host_live "$h")" != "$want" ]; do
        if [ $SECONDS -gt $deadline ]; then
            echo "host did not reach live=$want in time" >&2
            return 1
        fi
        sleep "$interval"
    done
}

# Wait for a host to come back from a reboot (key "boot_time") or toolstack restart
# ("agent_start_time"): until that other-config entry differs from $before and the host is live. Follows
# HOST_IS_SLAVE-style coordinator redirection (updating the global $host, the same way the top-of-script
# probe and reconnect_after_master_change do) in case the host restarting is the coordinator xe is
# currently talking to.
wait_for_restart() {
    local host_uuid=$1 key=$2 before=$3 timeout=${4:-1800} interval=${5:-10} probe
    local deadline=$((SECONDS + timeout))
    while true; do
        if probe=$(xe host-param-get uuid=$host_uuid param-name=other-config param-key=$key 2>&1); then
            if [ "$probe" != "$before" ] && [ "$(host_live "$host_uuid")" = "true" ]; then
                return 0
            fi
        elif [[ $probe =~ (Master|Coordinator)\ IP\ address:\ ([0-9A-Fa-f.:]+) ]]; then
            host=${BASH_REMATCH[2]}
        fi
        if [ $SECONDS -gt $deadline ]; then
            echo "host $host_uuid did not come back in time" >&2
            return 1
        fi
        sleep "$interval"
    done
}

# Re-enable a host that has just come back. It reports itself live before xapi on it has finished
# starting, and until then host-enable fails HOST_STILL_BOOTING - so retry that.
enable_when_booted() {
    local h=$1 timeout=600 interval=10 err
    local deadline=$((SECONDS + timeout))
    while true; do
        if err=$(xe host-enable uuid=$h 2>&1); then return 0; fi
        # xe prints the error's message, not its code: HOST_STILL_BOOTING reads "The host toolstack is
        # still initialising".
        case "$err" in
            *STILL_BOOTING*|*"still initialising"*) ;;
            *) echo "$err" >&2; return 1 ;;
        esac
        if [ $SECONDS -gt $deadline ]; then echo "$err" >&2; return 1; fi
        sleep "$interval"
    done
}

# A throwaway VM with a working guest OS: a copy of an existing VM that has one. Suspend, checkpoint,
# live migration and clean shutdown all need the guest's cooperation: on a running VM with no PV drivers
# xapi refuses them up front with VM_LACKS_FEATURE (a VM freshly installed from a template has no OS at
# all). So copy a VM that does have an OS and PV drivers, without disturbing it: snapshot it (fine while
# it runs), then vm-install from the snapshot - a clone-and-provision in one step, straight onto the same
# SR as the snapshot's own disks (vm-install refuses an explicit sr-uuid/sr-name-label when installing
# from a snapshot). The snapshot is only needed for the install, so it goes again straight away.
copy_of_guest() {
    local source_vm_name=$1 new_vm_name=$2 source snapshot vm
    source=$(vm_uuid "$source_vm_name")
    snapshot=$(xe vm-snapshot uuid=$source new-name-label="${new_vm_name}-source")
    vm=$(xe vm-install template-uuid=$snapshot new-name-label="$new_vm_name")
    # Even with force=true, *-uninstall prints the items it destroys on stdout: keep that out of the
    # value this function returns.
    xe snapshot-uninstall snapshot-uuid=$snapshot force=true >/dev/null
    echo "$vm"
}

# Wait, after vm-start, until the guest's PV drivers have reported in. xapi only offers the
# guest-dependent operations once the guest says it can do them, and allowed-operations is where it says
# so: wait for clean_shutdown to appear there (the same check that refuses it with VM_LACKS_FEATURE
# beforehand). A Linux kernel offers that early in boot, before the agent runs (hot-plug needs the agent,
# and suspend needs its emulated disk unplugged), so wait for PV-drivers-detected too. A booting OS takes a
# while.
wait_for_guest_agent() {
    local vm=$1 timeout=${2:-300} interval=${3:-2}
    local deadline=$((SECONDS + timeout))
    while true; do
        case "$(xe vm-param-get uuid=$vm param-name=allowed-operations)" in
            *clean_shutdown*)
                [ "$(xe vm-param-get uuid=$vm param-name=PV-drivers-detected 2>/dev/null)" = true ] && return 0 ;;
        esac
        if [ $SECONDS -gt $deadline ]; then
            echo "the guest's PV drivers did not report in within ${timeout}s; does the source VM have" \
                 "a guest OS with PV drivers (XenServer VM Tools)?" >&2
            return 1
        fi
        sleep "$interval"
    done
}

# Relocate every one of a (not-yet-started) VM's disks onto the given SR, the same vdi-pool-migrate
# storage-migrate already demonstrates.
move_disks_to_sr() {
    local vm=$1 sr_ref=$2 vbd vdi
    for vbd in $(each_csv "$(set_to_csv "$(xe vm-param-get uuid=$vm param-name=VBDs)")"); do
        [ "$(xe vbd-param-get uuid=$vbd param-name=type)" = "Disk" ] || continue
        vdi=$(xe vbd-param-get uuid=$vbd param-name=vdi-uuid)
        if [ "$(xe vdi-param-get uuid=$vdi param-name=sr-uuid)" != "$sr_ref" ]; then
            xe vdi-pool-migrate uuid=$vdi sr-uuid=$sr_ref
        fi
    done
}

# --- 1. Connect & inventory ---
w_connect_inventory() {
    echo "Connected to pool: $(xe pool-list params=name-label --minimal)"
    echo "Hosts: $(xe host-list params=name-label --minimal)"
    echo "VMs:"
    xe vm-list is-control-domain=false params=name-label,power-state
    echo "OK: connect-inventory"
}
# Run it:
#   ./workflows.sh connect-inventory https://xenserver root "$password"

# --- 2. Create a VM from a template ---
w_create_vm() {
    local template=$(param template_name "Rocky Linux 8")
    vm=$(xe vm-install template="$template" new-name-label=xe-example-vm sr-uuid=$(shared_sr))
    echo "Created VM: $vm"
    echo "is-a-template = $(xe vm-param-get uuid=$vm param-name=is-a-template)"
    # Tidy up so the example is repeatable: vm-uninstall destroys the VM and the disks it owns (vm-destroy
    # would leave the disks behind).
    xe vm-uninstall uuid=$vm force=true
    echo "OK: create-vm"
}

# --- 3. VM power lifecycle ---
# Whether VM.suspend has a suspend-image SR to use: the VM's own, else the pool's, else the resident
# host's - the same fallback order xapi's choose_suspend_sr uses.
has_suspend_sr() {
    local vm=$1 pool host
    [ -n "$(xe vm-param-get uuid=$vm param-name=suspend-SR)" ] && return 0
    pool=$(first_csv "$(xe pool-list --minimal)")
    [ -n "$(xe pool-param-get uuid=$pool param-name=suspend-image-SR)" ] && return 0
    host=$(xe pool-param-get uuid=$pool param-name=master)
    [ -n "$(xe host-param-get uuid=$host param-name=suspend-image-sr)" ]
}

w_vm_lifecycle() {
    local source_vm=$(param source_vm "web-01")
    # Suspend and clean shutdown need the guest's cooperation (VM_LACKS_FEATURE without PV drivers), so
    # the copy is made from source_vm, a VM with a guest OS and PV drivers, and the example waits for the
    # guest to report in after starting.
    vm=$(copy_of_guest "$source_vm" "xe-example-lifecycle")
    echo "Initial: $(xe vm-param-get uuid=$vm param-name=power-state)"
    xe vm-start uuid=$vm;   echo "After start:    $(xe vm-param-get uuid=$vm param-name=power-state)"
    wait_for_guest_agent "$vm"
    # The emulated hardware can be restarted under a running guest without rebooting it.
    xe vm-restart-device-models uuid=$vm
    echo "Device models restarted; still $(xe vm-param-get uuid=$vm param-name=power-state)"
    if has_suspend_sr "$vm"; then
        xe vm-suspend uuid=$vm; echo "After suspend:  $(xe vm-param-get uuid=$vm param-name=power-state)"
        xe vm-resume uuid=$vm;  echo "After resume:   $(xe vm-param-get uuid=$vm param-name=power-state)"
        wait_for_guest_agent "$vm"   # the PV drivers reconnect after a resume
    else
        echo "Skipping suspend/resume: no suspend-image SR is configured for this VM/pool/host"
    fi
    # A clean shutdown asks the guest OS to shut itself down, as pressing the power button would - safe
    # now that the VM is a copy of a guest with PV drivers (an OS-less template clone would hang or fail
    # for real on a real host, with no public fallback to a hard shutdown).
    xe vm-shutdown uuid=$vm; echo "After shutdown: $(xe vm-param-get uuid=$vm param-name=power-state)"
    # Tidy up so the example is repeatable: vm-uninstall destroys the VM and the disks it owns (vm-destroy
    # would leave the disks behind).
    xe vm-uninstall uuid=$vm force=true
    echo "OK: vm-lifecycle"
}

# --- 4. Manage VM disks: Deactivate / Resize / Activate -------------------------------
# Not the VM's root/boot disk: a real VM's system disk is unpluggable=false (only a template's non-system
# disks default to unpluggable), so vbd-unplug on it fails on a real host with VBD_NOT_UNPLUGGABLE - and
# the VM has to be running in the first place, or unplug fails with VM_BAD_POWER_STATE. Work on a data
# disk this example adds to its own throwaway VM instead, matching XenCenter's own "deactivate" action,
# which only ever targets additional disks, and tidy up afterwards so the example is repeatable. No
# shrink: real SR backends refuse one outright (SR_BACKEND_FAILURE_79), so this only ever grows.
#
# Plugging and unplugging a disk on a running VM needs the guest's PV drivers (VM_MISSING_PV_DRIVERS
# otherwise), so the VM is a throwaway copy of source_vm, a VM with a guest OS and PV drivers.
w_manage_vm_disks() {
    local source_vm sr_name sr device sr_type sm
    source_vm=$(param source_vm "web-01")
    sr_name=$(param sr_name "Shared NFS")
    sr=$(first_csv "$(xe sr-list name-label="$sr_name" --minimal)")
    vm=$(copy_of_guest "$source_vm" "xe-example-vm-disks")
    xe vm-start uuid=$vm
    wait_for_guest_agent "$vm"

    vdi=$(xe vdi-create sr-uuid=$sr name-label=xe-example-data-disk virtual-size=4GiB type=user)
    device=$(first_csv "$(set_to_csv "$(xe vm-param-get uuid=$vm param-name=allowed-VBD-devices)")")
    vbd=$(xe vbd-create vm-uuid=$vm vdi-uuid=$vdi device=$device type=Disk mode=RW)
    xe vbd-plug uuid=$vbd
    echo "Disk attached:  $(xe vbd-param-get uuid=$vbd param-name=currently-attached)"

    # Deactivate: the disk stays with the VM, it is just no longer live.
    xe vbd-unplug uuid=$vbd
    echo "After unplug:   $(xe vbd-param-get uuid=$vbd param-name=currently-attached)"

    size=$(xe vdi-param-get uuid=$vdi param-name=virtual-size)
    xe vdi-resize uuid=$vdi disk-size=$((size * 2))
    echo "Resized:        $size -> $(xe vdi-param-get uuid=$vdi param-name=virtual-size) bytes"

    xe vbd-plug uuid=$vbd
    echo "After plug:     $(xe vbd-param-get uuid=$vbd param-name=currently-attached)"

    # Growing a disk that is attached and live is a DIFFERENT call, not a flag on the same one: online=true
    # tells the storage layer the guest is using the disk while it grows. Only some storage drivers can
    # (none of a stock XenServer 9's do), and the rest refuse with SR_OPERATION_NOT_SUPPORTED - so ask the
    # SR's driver (its SM record's features) first.
    sr_type=$(xe sr-param-get uuid=$sr param-name=type)
    sm=$(first_csv "$(xe sm-list type=$sr_type --minimal)")
    if [ -n "$sm" ] && xe sm-param-get uuid=$sm param-name=features param-key=VDI_RESIZE_ONLINE >/dev/null 2>&1; then
        grown=$(( $(xe vdi-param-get uuid=$vdi param-name=virtual-size) + 1073741824 ))
        xe vdi-resize uuid=$vdi disk-size=$grown online=true
        echo "Grown online:   $(xe vdi-param-get uuid=$vdi param-name=virtual-size) bytes"
    else
        echo "Grown online:   not supported by $sr_type storage; unplug, resize, plug as above"
    fi

    # Tidy up so the example is repeatable. vm-uninstall destroys the VM and only the disks it OWNS (VBD
    # other-config:owner, which vm-install sets) - not one attached later with a plain vbd-create, so
    # destroy the data disk too.
    xe vm-shutdown uuid=$vm force=true
    xe vm-uninstall uuid=$vm force=true
    xe vdi-destroy uuid=$vdi
    echo "OK: manage-vm-disks"
}

# --- Raise and dismiss alerts ---------------------------------------------------------
w_dismiss_alerts() {
    echo "Alerts:         $(count_csv "$(xe message-list --minimal)")"
    # Sorted, for a deterministic choice of which one to dismiss (message-list's own order is not).
    msg=$(xe message-list --minimal | tr ',' '\n' | sort | head -n 1)
    if [ -n "$msg" ]; then
        echo "Dismissing:     $(xe message-param-get uuid=$msg param-name=name)"
        xe message-destroy uuid=$msg
        echo "Alerts left:    $(count_csv "$(xe message-list --minimal)")"
    else
        echo "No alerts to dismiss."
    fi
    echo "OK: dismiss-alerts"
}

# --- Configure host power on ----------------------------------------------------------
w_host_power_on() {
    h=$(first_host)
    # Mode and config travel together: the config carries the credentials the mode needs.
    # "wake-on-lan" is a real, still-supported mode and needs no credentials; the legacy "iLO"/"DRAC"
    # modes were removed from the real power-on plugin and fail the moment host-power-on is actually
    # called ("<mode> script has been removed").
    xe host-set-power-on-mode uuid=$h power-on-mode=wake-on-lan
    echo "Power-on mode:  $(xe host-param-get uuid=$h param-name=power-on-mode)"

    xe host-set-power-on-mode uuid=$h power-on-mode=
    echo "OK: host-power-on"
}

# --- Rotate the pool secret -----------------------------------------------------------
w_rotate_pool_secret() {
    echo "Pool:           $(xe pool-list params=name-label --minimal)"
    # xapi checks its own preconditions before rotating - HA must be disabled, every host must be live, no
    # rolling pool upgrade may be in progress, and the pool must be licensed for it - and xe already prints
    # a clear explanation of whichever one failed, so report that instead of letting the raw failure abort
    # the script. A pool-wide operation; existing sessions survive it.
    if err=$(xe pool-secret-rotate 2>&1); then
        echo "Rotated. Still connected: $(count_csv "$(xe pool-list --minimal)")"
    else
        echo "Could not rotate the pool secret: $err"
    fi
    echo "OK: rotate-pool-secret"
}

# --- Change the root password ---------------------------------------------------------
w_change_root_password() {
    # xe exposes this as user-password-change. It takes the OLD password as well as the new one, even
    # though you are already authenticated - but a root session's old_pwd is never actually checked
    # (CA-13567): the only real gate is that the SESSION itself has to be a local superuser's, which this
    # one necessarily is. There is no "wrong old password is rejected" demonstration worth making here.
    original=$pass temporary=xe-example-temp-password
    xe user-password-change old="$original" new=$temporary
    echo "Password changed."
    # Unlike an SDK session, xe has no session to keep: every command logs in afresh, so from here on
    # it needs the NEW password - including the command that changes it back. And restore it however the
    # script ends (set -e exits on the first failure), or root would be left on the temporary password.
    pass=$temporary
    trap 'pass=$temporary; xe user-password-change old=$temporary new="$original" >/dev/null 2>&1' EXIT

    echo "New logins work with the new password: $(count_csv "$(xe pool-list --minimal)") pool"

    xe user-password-change old=$temporary new="$original"
    pass=$original
    trap - EXIT
    echo "Password restored."
    echo "OK: change-root-password"
}

# --- Manage TLS certificates ----------------------------------------------------------
w_manage_certificates() {
    h=$(first_host)
    echo "Certificates:   $(count_csv "$(xe certificate-list --minimal)")"

    # A real, generated self-signed certificate, not a placeholder string: xapi decodes whatever is handed
    # to pool-install-trusted-certificate/host-server-certificate-install as PEM and rejects anything that
    # isn't a well-formed certificate (INVALID_VALUE). filename=/certificate=/private-key= are local files
    # xe uploads itself, the same convention vm-export/vm-import already use in this script.
    local certfile=cli-example-cert.pem keyfile=cli-example-key.pem before after cert_uuid
    rm -f "$certfile" "$keyfile"
    self_signed_cert "$certfile" "$keyfile"

    # pool-install-trusted-certificate/pool-uninstall-trusted-certificate are the current API; the
    # deprecated pool-*-ca-certificate pair (by name, not by uuid) is superseded by this one.
    # ca=true: trusted as a root to verify a chain, not pinned as one specific leaf certificate.
    before=$(xe certificate-list --minimal)
    xe pool-install-trusted-certificate filename="$certfile" ca=true
    after=$(xe certificate-list --minimal)
    echo "After CA add:   $(count_csv "$after")"
    cert_uuid=""
    for c in $(each_csv "$after"); do
        case ",$before," in *",$c,"*) ;; *) cert_uuid=$c ;; esac
    done

    # Actually replace the host's own TLS identity with a real certificate (what this workflow's name
    # promises, beyond CA trust), then reset it back to a fresh self-signed one.
    xe host-server-certificate-install uuid=$h certificate="$certfile" private-key="$keyfile"
    echo "Host certificate replaced with a real, generated certificate."
    xe host-reset-server-certificate uuid=$h
    echo "Host certificate reset (a fresh self-signed identity)."

    xe pool-uninstall-trusted-certificate certificate-uuid=$cert_uuid
    rm -f "$certfile" "$keyfile"
    echo "After CA remove:$(count_csv "$(xe certificate-list --minimal)")"

    # Separately from which certificates exist: whether the pool actually CHECKS the ones its members
    # present to each other. There is no matching disable - a pool that could be talked out of verifying
    # would not be verifying - and the enable is idempotent, so this is safe to repeat.
    p=$(first_csv "$(xe pool-list --minimal)")
    echo "TLS verification: $(xe pool-param-get uuid=$p param-name=tls-verification-enabled)"
    xe pool-enable-tls-verification
    echo "  after enabling: $(xe pool-param-get uuid=$p param-name=tls-verification-enabled)"
    echo "OK: manage-certificates"
}

# --- Snapshot schedule ----------------------------------------------------------------
w_snapshot_schedule() {
    vm=$(vm_uuid web-01)
    # retained-snapshots is the interesting field: the schedule prunes to it every time it runs.
    vmss=$(xe vmss-create name-label=xe-example-schedule type=snapshot frequency=daily retained-snapshots=2)
    echo "Created schedule: $vmss"

    xe vm-param-set uuid=$vm snapshot-schedule=$vmss
    echo "Members:          $(count_csv "$(set_to_csv "$(xe vmss-param-get uuid=$vmss param-name=VMs)")")"

    # xe has no command to run a schedule on demand (the API's VMSS.snapshot_now has no CLI form), so it
    # takes its first snapshot when it next falls due, and from then on keeps the newest retained-snapshots.
    echo "Keeps:            $(xe vmss-param-get uuid=$vmss param-name=retained-snapshots) snapshot(s)"

    # A schedule with VMs still on it cannot be destroyed, so take the VM off it first.
    xe vm-param-set uuid=$vm snapshot-schedule=
    xe vmss-destroy uuid=$vmss
    echo "OK: snapshot-schedule"
}

# --- Manage VM groups -----------------------------------------------------------------
w_manage_vm_groups() {
    vm=$(vm_uuid web-01)
    # anti-affinity asks the pool to keep the group's members on different hosts.
    group=$(xe vm-group-create name-label=xe-example-group placement=anti-affinity)
    echo "Created group:  $group"

    # Membership is written from the VM side, and read back from the group side.
    xe vm-param-set uuid=$vm groups=$group
    echo "Group members:  $(count_csv "$(set_to_csv "$(xe vm-group-param-get uuid=$group param-name=vm-uuids)")")"

    # vm-group-destroy already clears the group from every member VM on its own - no need to remove
    # membership ourselves first.
    xe vm-group-destroy uuid=$group
    echo "OK: manage-vm-groups"
}

# --- Snapshot & revert ----------------------------------------------------------------
w_snapshot_revert() {
    vm=$(vm_uuid web-01)
    was_running=$([ "$(xe vm-param-get uuid=$vm param-name=power-state)" = "running" ] && echo true || echo false)
    snap=$(xe vm-snapshot uuid=$vm new-name-label=xe-example-snapshot)
    echo "Created snapshot: $snap"
    xe snapshot-revert snapshot-uuid=$snap
    echo "Reverted to the snapshot."
    # The other languages fetch the snapshot's console thumbnail from GET /vncsnapshot here. `xe` has no
    # command for a plain HTTP transfer that is not vm-export/host-backup, so there is nothing honest to
    # write - the thumbnail is a client-side fetch, not a CLI operation.
    # Reverting to a plain snapshot always leaves the VM Halted (xapi hard-shuts-down a running VM before
    # reverting it), even if it was Running a moment ago - restart it if that's how we found it, so the
    # example actually restores what it changed.
    [ "$was_running" = true ] && xe vm-start uuid=$vm
    # A snapshot owns its own snapshot disks; snapshot-uninstall removes them with it (the VM's disks are
    # untouched - they are not the snapshot's).
    xe snapshot-uninstall snapshot-uuid=$snap force=true
    echo "OK: snapshot-revert"
}

# --- 5. Create an NFS storage repository ---
w_create_nfs_sr() {
    local nfs_server nfs_path
    nfs_server=$(param nfs_server "192.0.2.10")
    nfs_path=$(param nfs_path "/export/sdk")
    sr=$(xe sr-create host-uuid=$(first_host) type=nfs name-label=xe-example-nfs \
        device-config:server="$nfs_server" device-config:serverpath="$nfs_path" device-config:nfsversion=3 shared=true)
    echo "Created SR: $sr"
    detach_and_forget_sr $sr
    echo "OK: create-nfs-sr"
}

# --- 6. Create a network ---
w_create_network() {
    net=$(xe network-create name-label=xe-example-net)
    echo "Created network: $net"

    # Raise the MTU to use jumbo frames. Every NIC and switch along the path has to agree, so this
    # is a property of the network rather than of any one interface on it.
    xe network-param-set uuid=$net MTU=9000
    echo "MTU now:         $(xe network-param-get uuid=$net param-name=MTU)"
    xe network-destroy uuid=$net
    echo "OK: create-network"
}

# --- 7. Edit VM properties ---
w_edit_vm_properties() {
    vm=$(vm_uuid web-01)
    original=$(xe vm-param-get uuid=$vm param-name=name-description)
    xe vm-param-set uuid=$vm name-description="Edited by the xe example"
    xe vm-param-add uuid=$vm param-name=other-config xe_example=true
    echo "New description: $(xe vm-param-get uuid=$vm param-name=name-description)"
    echo "other-config[xe_example] = $(xe vm-param-get uuid=$vm param-name=other-config param-key=xe_example)"
    xe vm-param-set uuid=$vm name-description="$original"
    xe vm-param-remove uuid=$vm param-name=other-config param-key=xe_example
    echo "OK: edit-vm-properties"
}

# --- 8. Event monitoring ---
w_events() {
    vm=$(vm_uuid web-01)
    # event-wait blocks until the object matches; here the condition already holds, so it returns at once.
    xe event-wait class=vm uuid=$vm power-state=running
    echo "web-01 reached power-state=running"
    echo "OK: events"
}

# --- 9. New VM wizard (full) ---
w_new_vm_wizard() {
    local template=$(param template_name "Rocky Linux 8")
    vm=$(xe vm-install template="$template" new-name-label=xe-wizard-vm sr-uuid=$(shared_sr))
    xe vm-param-set uuid=$vm VCPUs-max=2 VCPUs-at-startup=2
    xe vm-memory-limits-set uuid=$vm static-min=512MiB static-max=2GiB dynamic-min=2GiB dynamic-max=2GiB
    vdi=$(xe vdi-create sr-uuid=$(shared_sr) name-label="xe-wizard disk" virtual-size=24GiB type=user)
    xe vbd-create vm-uuid=$vm vdi-uuid=$vdi device=1 type=Disk mode=RW >/dev/null
    xe vif-create vm-uuid=$vm network-uuid=$(first_csv "$(xe network-list --minimal)") device=0 >/dev/null
    xe vm-start uuid=$vm
    echo "power-state: $(xe vm-param-get uuid=$vm param-name=power-state)"
    echo "vCPUs:       $(xe vm-param-get uuid=$vm param-name=VCPUs-max)"
    # Tidy up so the example is repeatable: stop the VM, then vm-uninstall destroys it and the disks it
    # owns (vm-destroy would leave the disks behind). It owns only the template's disks - vm-install marks
    # those (VBD other-config:owner) - not one added with a plain vbd-create, so destroy that one too.
    xe vm-shutdown uuid=$vm force=true
    xe vm-uninstall uuid=$vm force=true
    xe vdi-destroy uuid=$vdi
    echo "OK: new-vm-wizard"
}

# --- 10. Live migrate a VM ---
# Live migration needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers), so this moves a
# throwaway copy of source_vm, a VM with a guest OS and PV drivers. Only the VM's memory moves, so the
# destination host has to see its disks already: a disk on local storage refuses with VM_REQUIRES_SR.
# Put the copy's disks on the shared SR sr_name first.
w_live_migrate() {
    local source_vm sr_name
    source_vm=$(param source_vm "web-01")
    sr_name=$(param sr_name "Shared NFS")
    vm=$(copy_of_guest "$source_vm" "xe-example-migrate")
    move_disks_to_sr "$vm" "$(first_csv "$(xe sr-list name-label="$sr_name" shared=true --minimal)")"
    xe vm-start uuid=$vm
    wait_for_guest_agent "$vm"
    source=$(xe vm-param-get uuid=$vm param-name=resident-on)
    echo "Running on: $(xe host-param-get uuid=$source param-name=name-label)"
    hosts=$(xe host-list --minimal); dest=""
    for h in ${hosts//,/ }; do [ "$h" != "$source" ] && { dest=$h; break; }; done
    xe vm-migrate uuid=$vm host-uuid=$dest live=true
    now=$(xe vm-param-get uuid=$vm param-name=resident-on)
    echo "Migrated to: $(xe host-param-get uuid=$now param-name=name-label)"
    # Tidy up so the example is repeatable: stop the VM, then vm-uninstall destroys it and the disks it
    # owns (vm-destroy would leave the disks behind).
    xe vm-shutdown uuid=$vm force=true
    xe vm-uninstall uuid=$vm force=true
    echo "OK: live-migrate"
}

# --- 11. Enter & exit maintenance mode ---
# Pins a throwaway copy of source_vm to a host (not the coordinator, so the coordinator can receive its
# evacuated guests) so evacuation has work to do. Evacuation live-migrates the guest, which needs its
# cooperation (VM_LACKS_FEATURE without PV drivers), so source_vm must have a guest OS with PV drivers.
#
# Evacuation also needs somewhere else in the pool that can actually see the VM's disk - a VM whose only
# disk is on local (non-shared) storage can't be evacuated at all (VM_REQUIRES_SR), and a pool's
# installation-time default SR is commonly local storage. Move the pinned VM's disk onto a shared SR
# (sr_name, below) explicitly rather than trusting whatever the pool default happens to be.
w_host_maintenance() {
    local source_vm sr_name
    source_vm=$(param source_vm "web-01")
    sr_name=$(param sr_name "Shared NFS")

    # Choose a host that is not the pool coordinator, so the coordinator can receive its guests.
    master=$(xe pool-param-get uuid=$(first_csv "$(xe pool-list --minimal)") param-name=master)
    h=""
    for candidate in $(each_csv "$(xe host-list --minimal)"); do
        [ "$candidate" != "$master" ] && { h=$candidate; break; }
    done
    echo "Maintenance host: $(xe host-param-get uuid=$h param-name=name-label)"

    # Pin a copy of source_vm to that host so evacuation has something to move.
    vm=$(copy_of_guest "$source_vm" "xe-example-maint")
    move_disks_to_sr "$vm" "$(first_csv "$(xe sr-list name-label="$sr_name" shared=true --minimal)")"
    xe vm-param-set uuid=$vm affinity=$h
    xe vm-start uuid=$vm
    wait_for_guest_agent "$vm"
    echo "Guest resident on:$(xe host-param-get uuid=$(xe vm-param-get uuid=$vm param-name=resident-on) param-name=name-label)"

    # Enter maintenance mode: disable the host, then evacuate its guests.
    xe host-disable uuid=$h;  echo "After disable:  enabled=$(xe host-param-get uuid=$h param-name=enabled)"
    xe host-evacuate uuid=$h; echo "After evacuate: guest now on $(xe host-param-get uuid=$(xe vm-param-get uuid=$vm param-name=resident-on) param-name=name-label)"
    xe host-enable uuid=$h;   echo "After enable:   enabled=$(xe host-param-get uuid=$h param-name=enabled)"
    # Tidy up so the example is repeatable: stop the VM, then vm-uninstall destroys it and the disks it
    # owns (vm-destroy would leave the disks behind).
    xe vm-shutdown uuid=$vm force=true
    xe vm-uninstall uuid=$vm force=true
    echo "OK: host-maintenance"
}

# --- 12. Configure high availability ---
w_configure_ha() {
    pool=$(xe pool-list --minimal)
    xe pool-ha-enable heartbeat-sr-uuids=$(shared_sr)
    echo "HA enabled: $(xe pool-param-get uuid=$pool param-name=ha-enabled)"

    # What HA does per VM. The restart priority decides which guests come back first after a host
    # failure, and whether a VM is protected at all; "restart" is protected, an empty string is not.
    guest=$(first_csv "$(xe vm-list is-a-template=false is-control-domain=false is-a-snapshot=false --minimal)")
    was=$(xe vm-param-get uuid=$guest param-name=ha-restart-priority)
    xe vm-param-set uuid=$guest ha-restart-priority=restart
    echo "$(xe vm-param-get uuid=$guest param-name=name-label) priority: '$was' -> '$(xe vm-param-get uuid=$guest param-name=ha-restart-priority)'"
    xe vm-param-set uuid=$guest ha-restart-priority="$was"

    # And a pool-wide judgement call: if a guest shuts itself down from the inside, is that a
    # failure HA should undo, or an administrator's intent it should respect?
    echo "Restart on internal shutdown: $(xe pool-param-get uuid=$pool param-name=ha-reboot-vm-on-internal-shutdown)"

    xe pool-ha-disable
    echo "HA enabled: $(xe pool-param-get uuid=$pool param-name=ha-enabled)"
    echo "OK: configure-ha"
}

# --- 13. Copy a VM ---
w_copy_vm() {
    local vm was_running
    vm=$(vm_uuid db-01)
    # vm-copy (like vm-clone) only works on a Halted VM - a running source fails with VM_BAD_POWER_STATE -
    # so shut it down first if it's running, and start it back up again after the copy.
    was_running=$([ "$(xe vm-param-get uuid=$vm param-name=power-state)" = "running" ] && echo true || echo false)
    [ "$was_running" = true ] && xe vm-shutdown uuid=$vm
    copy=$(xe vm-copy uuid=$vm new-name-label=xe-example-copy sr-uuid=$(shared_sr))
    echo "Copied VM: $copy"
    [ "$was_running" = true ] && xe vm-start uuid=$vm
    # Tidy up: vm-uninstall destroys the copy and its disks, leaving the source VM intact.
    xe vm-uninstall uuid=$copy force=true
    echo "OK: copy-vm"
}

# --- 14. Create a VM with a vGPU ---
w_create_vm_with_vgpu() {
    # A GPU group that offers a real (non-passthrough) vGPU type, and that type. Not simply the first
    # group: a host's onboard display adapter is a GPU group too, with no vGPU types at all.
    group="" type=""
    for g in $(each_csv "$(xe gpu-group-list --minimal)"); do
        vtypes=$(set_to_csv "$(xe gpu-group-param-get uuid=$g param-name=supported-VGPU-types)")
        for t in ${vtypes//,/ }; do
            if [ "$(xe vgpu-type-param-get uuid=$t param-name=model-name)" != "passthrough" ]; then
                group=$g; type=$t; break 2
            fi
        done
    done
    [ -n "$type" ] || { echo "no GPU group offers a vGPU type (is the GPU vendor's host driver installed?)" >&2; return 1; }
    local template=$(param template_name "Rocky Linux 8")
    # No sr-uuid: the template's disks go to the pool's default SR, as VM.provision does.
    vm=$(xe vm-install template="$template" new-name-label=xe-example-vgpu)
    vgpu=$(xe vgpu-create vm-uuid=$vm gpu-group-uuid=$group vgpu-type-uuid=$type)
    echo "Created vGPU: $vgpu of type $(xe vgpu-type-param-get uuid=$type param-name=model-name)"
    # Tidy up so the example is repeatable: the vGPU, then the VM and the disks it owns.
    xe vgpu-destroy uuid=$vgpu
    xe vm-uninstall uuid=$vm force=true
    echo "OK: create-vm-with-vgpu"
}

# --- 15. Tag and organize objects ---
w_tags_and_folders() {
    vm=$(vm_uuid web-01); h=$(first_host)
    xe vm-param-add uuid=$vm param-name=tags param-key=web
    xe host-param-add uuid=$h param-name=tags param-key=gold
    echo "VM tags:   $(xe vm-param-get uuid=$vm param-name=tags)"
    echo "Host tags: $(xe host-param-get uuid=$h param-name=tags)"
    xe vm-param-set uuid=$vm other-config:folder=/Production/Web
    echo "VM folder: $(xe vm-param-get uuid=$vm param-name=other-config param-key=folder)"
    xe vm-param-remove uuid=$vm param-name=tags param-key=web
    xe host-param-remove uuid=$h param-name=tags param-key=gold
    xe vm-param-remove uuid=$vm param-name=other-config param-key=folder
    echo "OK: tags-and-folders"
}

# Introduce the pool's update repositories the way XenCenter does: the release's base packages
# (update=false) and its update stream (update=true, which pool-sync-updates needs - otherwise
# NO_REPOSITORY_ENABLED). A real host checks the URLs (INVALID_BASE_URL for an unknown domain), so these
# are the XenServer CDN's, e.g. https://repo.ops.xenserver.com/xs9/{base,normal}. Echoes both repository
# uuids, one per line.
introduce_update_repositories() {
    local repo_url=$1 source_url=$2 stage
    for stage in base normal; do
        xe repository-introduce name-label="sdk-example-$stage" \
            name-description="SDK example $stage repository" \
            binary-url="$repo_url/$stage" source-url="$source_url/$stage" \
            update=$([ "$stage" = base ] && echo false || echo true)
    done
}

# --- 16. Configure updates (CDN) ---
w_configure_updates() {
    local repo_url source_url repos repo_list names pool before
    repo_url=$(param repo_url "https://repo.ops.xenserver.com/xs9")
    source_url=$(param source_url "https://repo-src.ops.xenserver.com/xs9")
    pool=$(xe pool-list --minimal)
    repos=$(introduce_update_repositories "$repo_url" "$source_url")
    repo_list="" names=""
    for r in $repos; do
        repo_list="${repo_list:+$repo_list,}$r"
        names="${names:+$names, }$(xe repository-param-get uuid=$r param-name=name-label)"
    done
    echo "Introduced repositories: $names"

    # Remember the pool's own repositories, to put them back afterwards. A set reads back "a; b" and is
    # set as "a,b".
    before=$(xe pool-param-get uuid=$pool param-name=repositories)
    xe pool-param-set uuid=$pool repositories=$repo_list
    # The pool's update-sync-enabled is read-only to param-set; xe switches it with its own command.
    xe pool-set-update-sync-enabled value=true
    echo "Pool repositories: $(count_csv "$repo_list"); auto-sync enabled: $(xe pool-param-get uuid=$pool param-name=update-sync-enabled)"

    # Tidy up so the example is repeatable.
    xe pool-set-update-sync-enabled value=false
    xe pool-param-set uuid=$pool repositories="${before//; /,}"
    for r in $repos; do xe repository-forget uuid=$r; done
    echo "OK: configure-updates"
}

# --- 17. Clone a VM ---
w_clone_vm() {
    clone=$(xe vm-clone uuid=$(vm_uuid db-01) new-name-label=xe-example-clone)
    echo "Cloned VM: $clone"
    # Tidy up: vm-uninstall destroys the clone and the disks it owns (vm-destroy would leave them).
    xe vm-uninstall uuid=$clone force=true
    echo "OK: clone-vm"
}

# --- 18. Delete a VM ---
w_delete_vm() {
    local template=$(param template_name "Rocky Linux 8")
    vm=$(xe vm-install template="$template" new-name-label=xe-example-delete sr-uuid=$(shared_sr))
    # vm-uninstall destroys the VM and the disks it owns, what XenCenter's Delete VM does; vm-destroy
    # would remove only the VM record and leave its disks behind.
    xe vm-uninstall uuid=$vm force=true
    echo "VM still present: $([ -z "$(xe vm-list uuid=$vm --minimal)" ] && echo false || echo true)"
    echo "OK: delete-vm"
}

# --- 19. Storage live-migration (move a disk to another SR) ---
# Moving a running VM's disk needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers), so this
# works on a throwaway copy of source_vm, a VM with a guest OS and PV drivers. (A halted VM's disk moves
# too, without the guest; what vdi-pool-migrate always needs is a VM to move the disk for - a VDI no VBD
# points at fails VDI_NEEDS_VM_FOR_MIGRATE.)
w_storage_migrate() {
    local source_vm=$(param source_vm "web-01")
    vm=$(copy_of_guest "$source_vm" "xe-example-storagemigrate")
    xe vm-start uuid=$vm
    wait_for_guest_agent "$vm"
    vdi=$(first_disk_vdi "$vm")
    source=$(xe vdi-param-get uuid=$vdi param-name=sr-uuid)
    echo "Disk is on SR: $(xe sr-param-get uuid=$source param-name=name-label)"

    # Pick a different SR that holds disks (not ISO) and that the VM's host can reach (an attached PBD there).
    resident=$(xe vm-param-get uuid=$vm param-name=resident-on)
    dest=""
    for sr in $(each_csv "$(xe sr-list --minimal)"); do
        [ "$sr" = "$source" ] && continue
        [ "$(xe sr-param-get uuid=$sr param-name=content-type)" = "iso" ] && continue
        case "$(xe sr-param-get uuid=$sr param-name=type)" in iso|udev) continue ;; esac
        if [ -n "$(xe pbd-list sr-uuid=$sr host-uuid=$resident currently-attached=true --minimal)" ]; then
            dest=$sr; break
        fi
    done
    # vdi-pool-migrate moves the disk in place: the copy on the destination SR replaces the original.
    xe vdi-pool-migrate uuid=$vdi sr-uuid=$dest
    echo "Disk moved to: $(xe sr-param-get uuid=$(xe vdi-param-get uuid=$vdi param-name=sr-uuid) param-name=name-label)"

    # Tidy up so the example is repeatable: vm-uninstall destroys the VM and the disks it now owns
    # (vm-destroy would leave the disks behind).
    xe vm-shutdown uuid=$vm force=true
    xe vm-uninstall uuid=$vm force=true
    echo "OK: storage-migrate"
}

# --- 20. Apply updates from the CDN ---
# pool-sync-updates needs at least one repository with update=true enabled (NO_REPOSITORY_ENABLED
# otherwise) - introduce the base and update repositories and attach both, remembering what was there to
# put it back afterwards (the "repositories" field is DynamicRO at the API level, but xe's generic
# pool-param-set still writes it - a set reads back "a; b" and is set as "a,b"), forgetting the throwaway
# ones again afterwards. Applying a batch whose mandatory guidance needs an evacuation fails with
# HOST_EVACUATION_IS_REQUIRED unless the host's resident VMs are moved off first; handle that rather than
# assuming an update batch never asks for one.
w_apply_update() {
    local repo_url source_url repos repo_list pool before hash err guidance
    repo_url=$(param repo_url "https://repo.ops.xenserver.com/xs9")
    source_url=$(param source_url "https://repo-src.ops.xenserver.com/xs9")
    repos=$(introduce_update_repositories "$repo_url" "$source_url")
    repo_list=""
    for r in $repos; do repo_list="${repo_list:+$repo_list,}$r"; done
    pool=$(xe pool-list --minimal)
    before=$(xe pool-param-get uuid=$pool param-name=repositories)
    xe pool-param-set uuid=$pool repositories=$repo_list

    hash=$(xe pool-sync-updates)
    echo "Synced updates (hash length ${#hash})"
    for h in $(each_csv "$(xe host-list --minimal)"); do
        if ! err=$(xe host-apply-updates uuid=$h hash=$hash 2>&1); then
            case "$err" in
                *[Ee]vacuat*)
                    echo "  $(xe host-param-get uuid=$h param-name=name-label): needs evacuating first; evacuating and retrying"
                    xe host-disable uuid=$h
                    xe host-evacuate uuid=$h
                    xe host-apply-updates uuid=$h hash=$hash
                    xe host-enable uuid=$h
                    ;;
                *) echo "$err" >&2; exit 1 ;;
            esac
        fi
        guidance=$(set_to_csv "$(xe host-param-get uuid=$h param-name=pending-guidances)")
        echo "  $(xe host-param-get uuid=$h param-name=name-label): applied; pending guidance = [$guidance]"
        # Modern xapi (>=23.18.0) doesn't reboot a host for you: it only records guidance, so only act
        # when the applied batch actually asked for it. A reboot restarts the toolstack too, so
        # reboot_host (checked first) covers restart_toolstack as well; xe has no separate command to
        # restart just the toolstack, so note it rather than silently doing nothing in that rarer case.
        case ",$guidance," in
            *,reboot_host,*)
                # As in rolling-pool-update: the reboot returns before it has happened, and the
                # coordinator's takes the connection with it - so wait for a newer boot time.
                before_key=$(xe host-param-get uuid=$h param-name=other-config param-key=boot_time 2>/dev/null) || true
                xe host-reboot uuid=$h
                wait_for_restart "$h" boot_time "$before_key"
                ;;
            *,restart_toolstack,*) echo "    (restart_toolstack requested; xe has no command for that alone)" ;;
        esac
        # apply-updates disables the host while it works (auto_enable: a restart puts it back) - with no
        # restart to do, nothing re-enables it. Return it to service either way.
        enable_when_booted "$h"
    done
    xe pool-param-set uuid=$pool repositories="${before//; /,}"
    for r in $repos; do xe repository-forget uuid=$r; done
    echo "OK: apply-update"
}

# --- 21. Checkpoint & revert ---
# Checkpointing needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers), hence a copy of
# source_vm - a VM with a guest OS and PV drivers - rather than an OS-less template clone.
w_checkpoint_vm() {
    local source_vm=$(param source_vm "web-01")
    vm=$(copy_of_guest "$source_vm" "xe-example-checkpoint")
    xe vm-start uuid=$vm
    wait_for_guest_agent "$vm"
    cp=$(xe vm-checkpoint uuid=$vm new-name-label=xe-example-checkpoint-1)
    echo "Created checkpoint: $cp"
    xe snapshot-revert snapshot-uuid=$cp
    # A checkpoint's own power-state is always Suspended (it captures memory as well as disk), and
    # snapshot-revert restores exactly that - so the VM is Suspended here, not Running as it was before
    # the checkpoint, with a suspend-VDI holding the checkpoint's memory image. vm-resume clears that:
    # destroying a Suspended VM directly leaves that suspend-VDI behind as a storage leak.
    echo "Reverted to the checkpoint; power-state now: $(xe vm-param-get uuid=$vm param-name=power-state)"
    xe vm-resume uuid=$vm
    # Tidy up so the example is repeatable. The checkpoint owns its own snapshot disks (and memory
    # image), separate from the VM's; the -uninstall commands destroy them with the records.
    xe snapshot-uninstall snapshot-uuid=$cp force=true
    xe vm-shutdown uuid=$vm force=true
    xe vm-uninstall uuid=$vm force=true
    echo "OK: checkpoint-vm"
}

# --- 22. Attach a new disk to a VM ---
w_attach_disk() {
    local template=$(param template_name "Rocky Linux 8")
    vm=$(xe vm-install template="$template" new-name-label=xe-example-attachdisk sr-uuid=$(shared_sr))
    vdi=$(xe vdi-create sr-uuid=$(shared_sr) name-label=xe-example-data-disk virtual-size=8GiB type=user)
    xe vbd-create vm-uuid=$vm vdi-uuid=$vdi device=1 type=Disk mode=RW >/dev/null
    echo "Attached an 8 GiB disk; VM now has $(count_csv "$(set_to_csv "$(xe vm-param-get uuid=$vm param-name=VBDs)")") VBD(s)"
    # Tidy up: vm-uninstall destroys the VM and the disks it OWNS (VBD other-config:owner, which vm-install
    # sets on the template's disks) - not the one just attached, so destroy that too.
    xe vm-uninstall uuid=$vm force=true
    xe vdi-destroy uuid=$vdi
    echo "OK: attach-disk"
}

# --- 23. Drive an asynchronous task ---
w_wait_for_task() {
    # xe commands run synchronously (the CLI blocks until the operation completes), so there is no task
    # to poll; the API's tasks are listed here for reference.
    echo "Current tasks: $(count_csv "$(xe task-list params=uuid --minimal)")"
    echo "xe waits for each command to finish, so no async polling is needed."
    echo "OK: wait-for-task"
}

# --- 24. Handle a CLI error ---
w_error_handling() {
    if xe vm-param-get uuid=this-uuid-does-not-exist param-name=uuid 2>/dev/null; then
        echo "unexpected: no error"
    else
        echo "Caught expected failure: invalid uuid (exit code $?)"
    fi
    echo "OK: error-handling"
}

# --- 25. List templates ---
w_list_templates() {
    echo "Templates ($(count_csv "$(xe template-list --minimal)")):"
    IFS=, read -ra names <<< "$(xe template-list params=name-label --minimal)"
    printf '%s\n' "${names[@]:0:8}"
    echo "OK: list-templates"
}

# --- 26. Custom fields ---
w_custom_fields() {
    vm=$(vm_uuid web-01)
    xe vm-param-set uuid=$vm other-config:XenCenter.CustomFields.Owner="Platform Team"
    echo "Owner = $(xe vm-param-get uuid=$vm param-name=other-config param-key=XenCenter.CustomFields.Owner)"
    xe vm-param-remove uuid=$vm param-name=other-config param-key=XenCenter.CustomFields.Owner
    echo "OK: custom-fields"
}

# --- 27. GPU inventory ---
w_gpu_inventory() {
    echo "GPU groups:"
    groups=$(xe gpu-group-list --minimal)
    for g in ${groups//,/ }; do
        vtypes=$(set_to_csv "$(xe gpu-group-param-get uuid=$g param-name=supported-VGPU-types)")
        models=""
        for t in ${vtypes//,/ }; do models="$models $(xe vgpu-type-param-get uuid=$t param-name=model-name)"; done
        echo "  - $(xe gpu-group-param-get uuid=$g param-name=name-label): vGPU types:$models"
    done

    # How the pool spreads vGPUs across the physical GPUs in a group: depth-first packs each pGPU
    # full before using the next, breadth-first spreads them out.
    group=$(first_csv "$groups")
    before=$(xe gpu-group-param-get uuid=$group param-name=allocation-algorithm)
    xe gpu-group-param-set uuid=$group allocation-algorithm=breadth-first
    echo "Allocation:      $before -> $(xe gpu-group-param-get uuid=$group param-name=allocation-algorithm)"
    xe gpu-group-param-set uuid=$group allocation-algorithm=$before
    echo "OK: gpu-inventory"
}

# --- 28. Read host & VM metrics ---
w_read_metrics() {
    h=$(first_host)
    # On the CLI, a host's and a VM's metrics read as parameters of the host and VM themselves.
    echo "Host $(xe host-param-get uuid=$h param-name=name-label): free memory $(xe host-compute-free-memory uuid=$h), live=$(xe host-param-get uuid=$h param-name=host-metrics-live)"
    vm=$(vm_uuid web-01)
    echo "VM web-01: $(xe vm-param-get uuid=$vm param-name=VCPUs-number) vCPU(s)"
    echo "OK: read-metrics"
}

# --- 29. Rename an object ---
w_rename_object() {
    vm=$(vm_uuid web-01)
    original=$(xe vm-param-get uuid=$vm param-name=name-label)
    xe vm-param-set uuid=$vm name-label=xe-renamed
    echo "Renamed '$original' -> '$(xe vm-param-get uuid=$vm param-name=name-label)'"
    xe vm-param-set uuid=$vm name-label="$original"   # restore so the example is repeatable
    echo "OK: rename-object"
}

# --- 30. VM boot configuration ---
w_vm_boot_config() {
    local template=$(param template_name "Rocky Linux 8")
    vm=$(xe vm-install template="$template" new-name-label=xe-example-boot sr-uuid=$(shared_sr))
    xe vm-param-set uuid=$vm VCPUs-max=4 VCPUs-at-startup=2
    # Boot mode: firmware ("bios"/"uefi") lives in HVM-boot-params; Secure Boot in platform:secureboot.
    # "auto" (not a hard-coded "true") is the real xe/XenCenter convention: xapi resolves it against
    # whether the pool actually holds Secure Boot certificates, at vm-start time - a hard "true" would
    # claim Secure Boot is on even on a template that was never set up for it, since platform:secureboot
    # does no validation of its own.
    xe vm-param-set uuid=$vm HVM-boot-params:order=cdn HVM-boot-params:firmware=uefi
    xe vm-param-set uuid=$vm platform:secureboot=auto
    echo "vCPUs: $(xe vm-param-get uuid=$vm param-name=VCPUs-at-startup)/$(xe vm-param-get uuid=$vm param-name=VCPUs-max)"
    echo "Boot order: $(xe vm-param-get uuid=$vm param-name=HVM-boot-params param-key=order)"
    echo "Boot mode: firmware=$(xe vm-param-get uuid=$vm param-name=HVM-boot-params param-key=firmware), secureboot=$(xe vm-param-get uuid=$vm param-name=platform param-key=secureboot) (resolved against pool certificates at boot)"
    # Tidy up so the example is repeatable: vm-uninstall destroys the VM and the disks it owns (vm-destroy
    # would leave the disks behind).
    xe vm-uninstall uuid=$vm force=true
    echo "OK: vm-boot-config"
}

# --- 31. Host information ---
w_host_info() {
    h=$(first_host)
    echo "Host:    $(xe host-param-get uuid=$h param-name=name-label)"
    echo "Version: $(xe host-param-get uuid=$h param-name=software-version param-key=product_version)"
    echo "Edition: $(xe host-param-get uuid=$h param-name=edition)"
    # The physical identity, straight off the host's DMI/SMBIOS tables. The serial number is what you
    # quote to the hardware vendor, so it identifies this machine and not just its model.
    echo "Hardware: $(xe host-param-get uuid=$h param-name=bios-strings param-key=system-manufacturer) $(xe host-param-get uuid=$h param-name=bios-strings param-key=system-product-name)"
    echo "Serial:   $(xe host-param-get uuid=$h param-name=bios-strings param-key=system-serial-number)"
    echo "BIOS:     $(xe host-param-get uuid=$h param-name=bios-strings param-key=bios-version)"
    echo "OK: host-info"
}

# --- 32. List RBAC roles ---
w_list_roles() {
    # role-list shows the roles a user can be granted, not the permissions they are made of. Its field
    # is `name`: a role has no name-label, and asking for one prints nothing.
    echo "Roles: $(xe role-list params=name --minimal)"
    echo "OK: list-roles"
}

# --- 33. Pool properties ---
w_pool_properties() {
    pool=$(xe pool-list --minimal)
    original=$(xe pool-param-get uuid=$pool param-name=name-label)
    echo "Pool: '$original'"
    xe pool-param-set uuid=$pool name-label=xe-pool-renamed
    echo "Renamed to: '$(xe pool-param-get uuid=$pool param-name=name-label)'"
    xe pool-param-set uuid=$pool name-label="$original"
    echo "OK: pool-properties"
}

# --- 34. Storage repository usage ---
w_sr_usage() {
    echo "Storage:"
    xe sr-list params=name-label,physical-size,physical-utilisation
    # Scan the first SR that has any capacity (the DVD and removable-media SRs have none).
    for sr in $(each_csv "$(xe sr-list --minimal)"); do
        [ "$(xe sr-param-get uuid=$sr param-name=physical-size)" -gt 0 ] && break
    done
    xe sr-scan uuid=$sr

    # Read caching keeps recently-read blocks in the host's memory. It is switched off per SR by
    # setting o_direct, which asks the storage layer to bypass the cache entirely.
    # Clear any earlier setting first: adding a key the map already holds is an error, and so is removing
    # one it doesn't, hence the || true.
    xe sr-param-remove uuid=$sr param-name=other-config param-key=o_direct >/dev/null 2>&1 || true
    xe sr-param-add uuid=$sr param-name=other-config o_direct=true
    o_direct=$(xe sr-param-get uuid=$sr param-name=other-config param-key=o_direct)
    echo "  read caching on $(xe sr-param-get uuid=$sr param-name=name-label): $([ "$o_direct" = "true" ] && echo off || echo on)"
    xe sr-param-remove uuid=$sr param-name=other-config param-key=o_direct
    echo "OK: sr-usage"
}

# --- 35. Manage network interfaces ---
w_manage_vif() {
    local template=$(param template_name "Rocky Linux 8") device
    vm=$(xe vm-install template="$template" new-name-label=xe-example-vif sr-uuid=$(shared_sr))
    net=$(first_csv "$(xe network-list --minimal)")
    device=$(first_csv "$(set_to_csv "$(xe vm-param-get uuid=$vm param-name=allowed-VIF-devices)")")
    vif=$(xe vif-create vm-uuid=$vm network-uuid=$net device=$device)
    echo "Attached a VIF; VM now has $(count_csv "$(set_to_csv "$(xe vm-param-get uuid=$vm param-name=VIFs)")") NIC(s)"
    xe vif-destroy uuid=$vif
    # Tidy up so the example is repeatable: vm-uninstall destroys the VM and the disks it owns (vm-destroy
    # would leave the disks behind).
    xe vm-uninstall uuid=$vm force=true
    echo "OK: manage-vif"
}

# --- 36. List networks ---
w_list_networks() {
    echo "Networks:"
    xe network-list params=name-label,bridge
    echo "OK: list-networks"
}

# --- 37. Inventory a VM's disks ---
w_vbd_inventory() {
    vm=$(vm_uuid db-01)
    echo "Disks of db-01:"
    vbds=$(set_to_csv "$(xe vm-param-get uuid=$vm param-name=VBDs)")
    for vbd in ${vbds//,/ }; do
        if [ "$(xe vbd-param-get uuid=$vbd param-name=type)" = "Disk" ]; then
            vdi=$(xe vbd-param-get uuid=$vbd param-name=vdi-uuid)
            echo "  - device $(xe vbd-param-get uuid=$vbd param-name=userdevice): $(xe vdi-param-get uuid=$vdi param-name=virtual-size) bytes"
        fi
    done
    echo "OK: vbd-inventory"
}

# --- 38. Tag the pool ---
w_pool_tags() {
    pool=$(xe pool-list --minimal)
    xe pool-param-add uuid=$pool param-name=tags param-key=xe-managed
    echo "Pool tags: $(xe pool-param-get uuid=$pool param-name=tags)"
    xe pool-param-remove uuid=$pool param-name=tags param-key=xe-managed
    echo "OK: pool-tags"
}

# --- 39. Convert a VM to a template ---
w_convert_to_template() {
    local template=$(param template_name "Rocky Linux 8")
    vm=$(xe vm-install template="$template" new-name-label=xe-example-totemplate sr-uuid=$(shared_sr))
    echo "is-a-template after install: $(xe vm-param-get uuid=$vm param-name=is-a-template)"
    xe vm-param-set uuid=$vm is-a-template=true   # one-way operation
    echo "is-a-template after convert: $(xe vm-param-get uuid=$vm param-name=is-a-template)"
    # It is a template now, so template-uninstall removes it and the disks it owns.
    xe template-uninstall template-uuid=$vm force=true
    echo "OK: convert-to-template"
}

# --- 40. Look up an object by UUID ---
w_find_by_uuid() {
    vm=$(vm_uuid web-01)
    echo "UUID $vm resolves to $(xe vm-param-get uuid=$vm param-name=name-label)"
    echo "OK: find-by-uuid"
}

# --- Rolling pool update --------------------------------------------------------------
# Needs an enabled update repository the same way apply-update does - introduce the base and update
# repositories and attach both, forget them again afterwards. Modern xapi (>=23.18.0) doesn't reboot a
# host for you: it only records pending guidance, so only reboot (xe has no remote toolstack-restart
# command, see apply-update) when the applied batch actually asks for it.
w_rolling_pool_update() {
    local repo_url source_url repos repo_list pool before hash guidance before_key
    repo_url=$(param repo_url "https://repo.ops.xenserver.com/xs9")
    source_url=$(param source_url "https://repo-src.ops.xenserver.com/xs9")
    repos=$(introduce_update_repositories "$repo_url" "$source_url")
    repo_list=""
    for r in $repos; do repo_list="${repo_list:+$repo_list,}$r"; done
    # pool-sync-updates syncs the pool's ENABLED repositories, and repository-introduce doesn't enable
    # anything (NO_REPOSITORY_ENABLED otherwise). Remember what was there to put it back afterwards. A
    # set reads back "a; b" and is set as "a,b".
    pool=$(xe pool-list --minimal)
    before=$(xe pool-param-get uuid=$pool param-name=repositories)
    xe pool-param-set uuid=$pool repositories=$repo_list
    hash=$(xe pool-sync-updates)
    echo "Synced updates (hash length ${#hash})"
    # Rolling pattern: disable -> evacuate -> apply -> reboot (only if asked) -> re-enable, one host at a time.
    for h in $(each_csv "$(xe host-list --minimal)"); do
        echo "Updating $(xe host-param-get uuid=$h param-name=name-label):"
        xe host-disable uuid=$h
        xe host-evacuate uuid=$h
        xe host-apply-updates uuid=$h hash=$hash
        guidance=$(set_to_csv "$(xe host-param-get uuid=$h param-name=pending-guidances)")
        echo "  applied; pending guidance = $guidance"
        case ",$guidance," in
            *,reboot_host,*)
                # The reboot returns before it has happened, and if this host is the coordinator it takes
                # the connection with it - so note when it last booted, reboot it, and wait until it
                # reports a newer boot time and is live again before re-enabling it.
                before_key=$(xe host-param-get uuid=$h param-name=other-config param-key=boot_time 2>/dev/null) || true
                xe host-reboot uuid=$h
                wait_for_restart "$h" boot_time "$before_key"
                ;;
            *,restart_toolstack,*)
                echo "    (restart_toolstack requested; xe has no command for that alone)"
                ;;
        esac
        enable_when_booted "$h"
    done
    xe pool-param-set uuid=$pool repositories="${before//; /,}"
    for r in $repos; do xe repository-forget uuid=$r; done
    echo "OK: rolling-pool-update"
}

# --- Cross-pool copy a VM -------------------------------------------------------------
w_cross_pool_copy_vm() {
    # Copy a VM to another pool (Storage XenMotion copy). Real xe does the whole cross-pool dance
    # itself given the destination master's address + credentials; copy=true leaves the source intact.
    dest_host=${desturl#*://}; dest_host=${dest_host%%/*}; dest_host=${dest_host%%:*}
    vm=$(vm_uuid "$copy_vm")
    xe vm-migrate uuid=$vm remote-master=$dest_host remote-username=$destuser remote-password=$destpass copy=true
    still=$([ -n "$(vm_uuid "$copy_vm")" ] && echo True || echo False)
    echo "Sent '$copy_vm' to $dest_host (copy); source still present: $still"
    echo "OK: cross-pool-copy-vm"
}

# --- 43. PVS Accelerator inventory ---
w_pvs_accelerator() {
    sites=$(xe pvs-site-list --minimal)
    if [ -z "$sites" ]; then echo "No PVS Accelerator sites are configured."; echo "OK: pvs-accelerator"; return; fi
    for site in ${sites//,/ }; do
        echo "Site: $(xe pvs-site-param-get uuid=$site param-name=name-label)"
        cslist=$(xe pvs-cache-storage-list --minimal)
        for cs in ${cslist//,/ }; do
            h=$(xe pvs-cache-storage-param-get uuid=$cs param-name=host-uuid)
            sr=$(xe pvs-cache-storage-param-get uuid=$cs param-name=sr-uuid)
            size=$(xe pvs-cache-storage-param-get uuid=$cs param-name=size)
            echo "  cache:  $(xe host-param-get uuid=$h param-name=name-label)  $((size / 1024 / 1024 / 1024)) GiB on $(xe sr-param-get uuid=$sr param-name=name-label)"
        done
        srvlist=$(xe pvs-server-list --minimal)
        for srv in ${srvlist//,/ }; do
            echo "  server: $(xe pvs-server-param-get uuid=$srv param-name=addresses)  ports $(xe pvs-server-param-get uuid=$srv param-name=first-port)-$(xe pvs-server-param-get uuid=$srv param-name=last-port)"
        done
        # One proxy accelerates one VM in this pool, so proxy count = accelerated VM count.
        accelerated=$(count_csv "$(xe pvs-proxy-list --minimal)")
        total=$(count_csv "$(xe vm-list is-control-domain=false --minimal)")
        echo "  $accelerated of $total VM(s) accelerated"
    done
    echo "OK: pvs-accelerator"
}

# --- 44. Read RRD performance metrics ---
w_rrd_metrics() {
    # xe host-data-source-query reads a live data source straight from the host's RRDs.
    hosts=$(xe host-list --minimal)
    for h in ${hosts//,/ }; do
        name=$(xe host-param-get uuid=$h param-name=name-label)
        util=$(xe host-data-source-query uuid=$h data-source=pvsaccelerator_space_utilization)
        echo "  $name: current PVS cache utilisation ${util%.*}%"
    done
    echo "OK: rrd-metrics"
}

# --- 45. Reclaim freed space on a thin SR ---
w_reclaim_space() {
    # A thin-provisioned SR (local LVM here) can return space freed by deleted disks to the backend
    # via the trim plugin - XenCenter's "Reclaim freed space".
    sr=$(first_csv "$(xe sr-list type=lvm --minimal)")
    # A host with a live (plugged) connection to the SR runs the plugin.
    pbd=$(first_csv "$(set_to_csv "$(xe sr-param-get uuid=$sr param-name=PBDs)")")
    h=$(xe pbd-param-get uuid=$pbd param-name=host)
    result=$(xe host-call-plugin host-uuid=$h plugin=trim fn=do_trim args:sr_uuid=$sr)
    echo "  reclaimed freed space on $sr: $result"
    # Compare case-insensitively: a real host's trim plugin answers "True" (capitalised).
    [ "${result,,}" = "true" ] || { echo "trim failed: $result" >&2; exit 1; }
    echo "OK: reclaim-space"
}

# --- 46. Get a VM's IP address ---
w_vm_ip_address() {
    # A running guest's tools report its IPs in the VM's networks parameter, keyed "<vif device>/ip". Pick
    # one that reports an address (freshly-created VMs and guests without tools report none).
    running=$(xe vm-list power-state=running is-control-domain=false --minimal)
    vm=""; ip=""
    for u in $(each_csv "$running"); do
        ip=$(xe vm-param-get uuid=$u param-name=networks param-key=0/ip 2>/dev/null) || continue
        vm=$u; break
    done
    [ -n "$vm" ] || { vm=$(first_csv "$running"); ip="(no address reported)"; }
    echo "  $(xe vm-param-get uuid=$vm param-name=name-label): $ip"
    echo "OK: vm-ip-address"
}

# --- 47. Manage Active Directory users ---
# Needs a real, reachable AD domain controller - pool-enable-external-auth fails at the very first call
# (DNS/LDAP/Kerberos) without one, so domain/admin_user/admin_password have to identify a real domain to
# join. Before joining, every host must resolve the domain (point its DNS at a domain controller) and
# keep its clock close to the DC's (Kerberos). Current Windows DCs want LDAPS (ldaps=true), which also
# needs the pool to trust the DC's CA certificate (pool-certificate-install ... purpose=ldaps, i.e.
# install_trusted_certificate). new_user is the account to grant a role to; its subject identity is
# looked up against the directory, so it has to be a real account there too. A pool already joined to
# this domain is used as it is - and left joined. The simulator models a single-user, domain-less fake
# directory (hence the empty domain default) - override every one of these on a real pool.
w_manage_ad_users() {
    local domain admin_user admin_password new_user ldaps subject_name master auth_type auth_service already_joined=false
    domain=$(param domain "")
    admin_user=$(param admin_user "alice")
    admin_password=$(param admin_password "Password1")
    new_user=$(param new_user "alice")
    ldaps=$(param ldaps "false")
    subject_name=$new_user; [ -n "$domain" ] && subject_name="$new_user@$domain"

    pool=$(xe pool-list --minimal)
    master=$(xe pool-param-get uuid=$pool param-name=master)
    auth_type=$(xe host-param-get uuid=$master param-name=external-auth-type)
    auth_service=$(xe host-param-get uuid=$master param-name=external-auth-service-name)
    if [ -n "$domain" ] && [ "$auth_type" = "AD" ] \
        && [ "${auth_service,,}" = "${domain,,}" ]; then
        already_joined=true
        echo "Already joined to domain: $domain"
    else
        xe pool-enable-external-auth uuid=$pool auth-type=AD service-name="$domain" \
            config:user="$admin_user" config:pass="$admin_password" config:ldaps=$ldaps
        echo "Joined domain: ${domain:-(none - the simulators fake directory)}"
    fi
    subj=$(xe subject-add subject-name="$subject_name")
    xe subject-role-add uuid=$subj role-name=pool-admin
    name=$(xe subject-param-get uuid=$subj param-name=other-config param-key=subject-displayname)
    echo "Added subject $name with role pool-admin"

    # Revoking access does not end sessions the user already has: logging the subject out is a
    # separate act, and the one that actually gets them off the pool now rather than at next login.
    sid=$(xe subject-param-get uuid=$subj param-name=subject-identifier)
    xe session-subject-identifier-logout subject-identifier=$sid
    echo "  logged out $name"

    xe subject-remove subject-uuid=$subj
    if [ "$already_joined" = false ]; then
        # Leave the way it was found. Passing the admin credentials also removes the pool's computer
        # accounts from the directory; without them they stay behind in AD.
        xe pool-disable-external-auth uuid=$pool config:user="$admin_user" config:pass="$admin_password"
    fi
    echo "OK: manage-ad-users"
}

# --- 48. Create an iSCSI SR ---
# Discover the IQN and the LUN the way the New SR wizard and XenRT do, instead of a hard-coded target:
# a device-config that's missing a piece makes the backend fail on purpose, and the failure carries an
# XML fragment listing what it needs next. sr-create formats the chosen LUN - this is destructive, so
# pick carefully on a real target: pass target_iqn to name yours (see choose_target_iqn).
w_create_iscsi_sr() {
    local target port chap_user chap_password sr_name h
    local -a dc
    target=$(param target "192.0.2.30")
    target_iqn=$(param target_iqn "")
    port=$(param port "")
    chap_user=$(param chap_user "")
    chap_password=$(param chap_password "")
    sr_name=$(param sr_name "xe-example-iscsi")
    h=$(first_host)

    dc=(device-config:target="$target")
    [ -n "$port" ] && dc+=(device-config:port="$port")
    [ -n "$chap_user" ] && dc+=(device-config:chapuser="$chap_user" device-config:chappassword="$chap_password")

    # First failing probe: target only -> the backend lists the IQNs it offers.
    xml=$(probe_for_failure lvmoiscsi host-uuid="$h" "${dc[@]}")
    target_iqn=$(choose_target_iqn "$xml" "$target" "$target_iqn")
    echo "Discovered IQN: $target_iqn"
    dc+=(device-config:targetIQN="$target_iqn")

    # Second failing probe: +targetIQN -> the backend lists the LUNs behind it.
    xml=$(probe_for_failure lvmoiscsi host-uuid="$h" "${dc[@]}")
    lun=${xml#*<LUN>}; lun="<LUN>${lun%%</LUN>*}"
    scsi_id=$(xml_tag_text "$lun" SCSIid)
    lun_id=$(xml_tag_text "$lun" LUNid); lun_id=${lun_id:-0}
    echo "Discovered LUN $lun_id (SCSIid $scsi_id)"

    sr=$(xe sr-create host-uuid="$h" type=lvmoiscsi name-label="$sr_name" shared=true \
        "${dc[@]}" device-config:SCSIid="$scsi_id" device-config:LUNid="$lun_id")
    echo "Created iSCSI SR: $sr ($(( $(xe sr-param-get uuid=$sr param-name=physical-size) / 1024 / 1024 / 1024 )) GiB)"
    detach_and_forget_sr $sr
    echo "OK: create-iscsi-sr"
}

# --- 49. Create an SMB SR ---
w_create_smb_sr() {
    local server share smb_username smb_password sr_name secret sr
    server=$(param server "192.0.2.40")
    share=$(param share "/vmstore")
    smb_username=$(param smb_username "Administrator")
    smb_password=$(param smb_password "Password1")
    sr_name=$(param sr_name "xe-example-smb")

    # The password travels as a Secret, not plaintext device-config - the real/XenRT/XenCenter convention
    # (0/3 real captured sr-create calls for this type use plaintext).
    secret=$(xe secret-create value="$smb_password")
    sr=$(xe sr-create host-uuid=$(first_host) type=smb name-label="$sr_name" shared=true \
        device-config:server="//$server$share" \
        device-config:username="$smb_username" device-config:password_secret=$secret)
    echo "Created SMB SR: $sr ($(( $(xe sr-param-get uuid=$sr param-name=physical-size) / 1024 / 1024 / 1024 )) GiB)"
    detach_and_forget_sr $sr
    xe secret-destroy uuid=$secret
    echo "OK: create-smb-sr"
}

# --- 50. Create an HBA SR ---
# No required parameter: discovery needs none. Probing with no SCSIid fails on purpose and lists every LUN
# the backend can see; the root element name and SR_BACKEND_FAILURE_<n> code both vary by host/simulator
# build, so parse by tag name wherever BlockDevice occurs. sr-create formats the chosen LUN - destructive.
w_create_hba_sr() {
    local sr_name h xml block scsi_id path sr
    sr_name=$(param sr_name "xe-example-hba")
    h=$(first_host)
    xml=$(probe_for_failure lvmohba host-uuid="$h")
    # sr-create formats the LUN: on shared FC storage name yours (scsi_id=); with none, the first is taken.
    local want rest
    want=$(param scsi_id "")
    rest=$xml
    while [[ $rest == *"<BlockDevice>"* ]]; do
        block=${rest#*<BlockDevice>}; rest=${block#*</BlockDevice>}; block="<BlockDevice>${block%%</BlockDevice>*}"
        scsi_id=$(xml_tag_text "$block" SCSIid)
        [ -z "$want" ] || [ "$scsi_id" = "$want" ] && break
        scsi_id=""
    done
    [ -n "$scsi_id" ] || { echo "no LUN with SCSIid $want is visible to this host" >&2; return 1; }
    path=$(xml_tag_text "$block" path)
    echo "Discovered LUN: SCSIid $scsi_id on $path"

    # SCSIid is all lvmohba needs - it is what XenCenter's New SR wizard sends. (The probe's <path> is
    # for display: on a real host it reads like "/dev/sde [sdc] [sdg] [sdi]", one entry per path.)
    sr=$(xe sr-create host-uuid="$h" type=lvmohba name-label="$sr_name" shared=true \
        device-config:SCSIid="$scsi_id")
    echo "Created HBA SR: $sr ($(( $(xe sr-param-get uuid=$sr param-name=physical-size) / 1024 / 1024 / 1024 )) GiB)"
    detach_and_forget_sr $sr
    echo "OK: create-hba-sr"
}

# --- 51. Create an ISO library SR ---
w_create_iso_sr() {
    # Connect an ISO-library SR to a file share of ISO images (here an NFS export, location
    # "server:/path").
    local location
    location=$(param location "192.0.2.10:/isos")
    sr=$(xe sr-create host-uuid=$(first_host) type=iso name-label=xe-example-iso content-type=iso \
        device-config:location="$location" device-config:type=nfs_iso shared=true)
    echo "Created ISO SR: $sr"
    detach_and_forget_sr $sr
    echo "OK: create-iso-sr"
}

# --- 52. Configure NRPE monitoring ---
# host-call-plugin is per-host - there is no pool-wide fan-out for plugin calls, unlike pool-enable-ssh -
# so configure every host, and disable NRPE again afterwards (the original left it enabled with no
# tidy-up at all).
w_configure_nrpe() {
    for h in $(each_csv "$(xe host-list --minimal)"); do
        echo "$(xe host-param-get uuid=$h param-name=name-label): NRPE status before: $(xe host-call-plugin host-uuid=$h plugin=nrpe fn=status)"
        xe host-call-plugin host-uuid=$h plugin=nrpe fn=enable >/dev/null
        xe host-call-plugin host-uuid=$h plugin=nrpe fn=set-config \
            args:allowed_hosts=127.0.0.1,::1,10.0.0.5 args:debug=0 args:ssl_logging=0x00 >/dev/null
        xe host-call-plugin host-uuid=$h plugin=nrpe fn=restart >/dev/null
        echo "  status after:  $(xe host-call-plugin host-uuid=$h plugin=nrpe fn=status)"
        xe host-call-plugin host-uuid=$h plugin=nrpe fn=disable >/dev/null   # restore
    done
    echo "OK: configure-nrpe"
}

# --- 53. Configure SNMP monitoring ---
# trap_destination: nmss is the list of real trap destinations SNMP notifications go to - an empty list
# never configures where traps actually go, which is arguably the main point of "configure SNMP
# monitoring" (XenRT's own default test config always carries exactly one). Plugin calls are per-host, so
# configure every host, and restore each one to disabled again afterwards, the way XenRT's own
# SNMPServer.disable() does.
w_configure_snmp() {
    local trap_destination config
    trap_destination=$(param trap_destination "192.0.2.50")
    config='{"common":{"enabled":"yes","debug_log":"no"},"agent":{"v2c":"yes","v3":"no","community":"sdk-community","user_name":"","authentication_password":"","authentication_protocol":"","privacy_password":"","privacy_protocol":""},"nmss":[{"address":"'"$trap_destination"'","port":162,"v2c":"yes","v3":"no","community":"sdk-community","user_name":"","authentication_password":"","authentication_protocol":"","privacy_password":"","privacy_protocol":""}]}'
    for h in $(each_csv "$(xe host-list --minimal)"); do
        xe host-call-plugin host-uuid=$h plugin=snmp fn=set-config "args:config=$config" >/dev/null
        echo "$(xe host-param-get uuid=$h param-name=name-label): SNMP status: $(xe host-call-plugin host-uuid=$h plugin=snmp fn=status)"
        xe host-call-plugin host-uuid=$h plugin=snmp fn=set-config 'args:config={"common":{"enabled":"no"}}' >/dev/null  # restore
    done
    echo "OK: configure-snmp"
}

# --- Manage a vApp ---------------------------------------------------------------------
w_manage_vapp() {
    local vm_uuid vapp_uuid
    # A halted VM: an appliance starts only if one of its VMs is halted (OPERATION_NOT_ALLOWED otherwise).
    vm_uuid=$(xe vm-list name-label="$(param vm_name db-01)" --minimal)
    vapp_uuid=$(xe appliance-create name-label=sdk-example-vapp \
        name-description="Created by the SDK example")

    # `order` decides the sequence: ascending to start, descending to shut down. That ordering is the
    # reason to use a vApp rather than selecting several VMs.
    xe vm-param-set uuid="$vm_uuid" appliance="$vapp_uuid" order=0 start-delay=5

    xe appliance-start uuid="$vapp_uuid"
    echo "Started:        $(xe vm-list uuid="$vm_uuid" params=power-state --minimal)"

    # A plain appliance-shutdown is clean only, and fails OPERATION_PARTIALLY_FAILED if any member can't
    # shut down cleanly (no guest OS or PV drivers); force=true shuts the members down hard.
    xe appliance-shutdown uuid="$vapp_uuid" force=true
    echo "Shut down:      $(xe vm-list uuid="$vm_uuid" params=power-state --minimal)"

    xe vm-param-set uuid="$vm_uuid" appliance=
    xe appliance-destroy uuid="$vapp_uuid"
    echo "OK: manage-vapp"
}

# --- Attach a USB device to a VM ---------------------------------------------------------
w_attach_usb_device() {
    local vm_uuid pusb_uuid group_uuid vusb_uuid
    vm_uuid=$(xe vm-list name-label=web-01 --minimal)
    pusb_uuid=$(first_csv "$(xe pusb-list --minimal)")
    echo "Device:         $(xe pusb-list uuid="$pusb_uuid" params=product-desc --minimal)"

    # Passthrough is off until an administrator releases the device: attaching one that has not been
    # released fails rather than silently doing nothing.
    xe pusb-param-set uuid="$pusb_uuid" passthrough-enabled=true

    group_uuid=$(xe pusb-list uuid="$pusb_uuid" params=usb-group-uuid --minimal)
    vusb_uuid=$(xe vusb-create vm-uuid="$vm_uuid" usb-group-uuid="$group_uuid")
    echo "Attached:       $(count_csv "$(xe vusb-list vm-uuid="$vm_uuid" --minimal)") device(s)"

    # vusb-destroy refuses a VUSB that is still attached (OPERATION_NOT_ALLOWED) - on a running VM it gets
    # plugged in as soon as it's created, so unplug it first.
    if [ "$(xe vusb-param-get uuid="$vusb_uuid" param-name=currently-attached)" = "true" ]; then
        xe vusb-unplug uuid="$vusb_uuid"
    fi
    xe vusb-destroy uuid="$vusb_uuid"
    xe pusb-param-set uuid="$pusb_uuid" passthrough-enabled=false
    echo "OK: attach-usb-device"
}

# --- Read workload-balancing recommendations ----------------------------------------------
# Needs a real, reachable WLB appliance: pool-initialize-wlb makes a synchronous HTTP call to it and fails
# if it can't connect - there is no way to fake this with a placeholder. wlb_host_port is host:port, with
# NO URL scheme - that is the real wire format (confirmed from XenRT logs), not a URL; the old hard-coded
# value had an incorrect "https://" prefix. Also note: this command's own parameter names are an
# exception to xe's usual hyphenated convention - they are genuinely underscored on the wire.
#
# The pool checks the appliance's TLS certificate (wlb-verify-cert), and only against the certificates
# installed with pool-certificate-install - not pool-install-trusted-certificate's (a different store).
# A fresh appliance has a self-signed one, so pass it as wlb_certificate (a PEM file): without it
# pool-initialize-wlb fails with "Connection failed: configuration failed." and no hint that the
# certificate is the reason. pool-certificate-install is deprecated for pool-install-ca-certificate, but
# it is the same call either way (xapi_pool.ml aliases them) - and it names the certificate after the
# file's own basename rather than taking a name= parameter, so the file is copied to the name wanted
# for uninstalling it again.
w_wlb_recommendations() {
    local vm_name wlb_host_port wlb_username wlb_password wlb_certificate vm pool out deadline
    # Not local: the EXIT trap below reads it after this function has returned.
    wlb_cert_name=""
    vm_name=$(param vm_name "web-01")
    wlb_host_port=$(param wlb_host_port "wlb.example:8012")
    wlb_username=$(param wlb_username "wlbuser")
    wlb_password=$(param wlb_password "wlbpass")
    wlb_certificate=$(param wlb_certificate "")

    if [ -n "$wlb_certificate" ]; then
        wlb_cert_name=sdk-example-wlb.pem
        cp "$wlb_certificate" "$wlb_cert_name"
        xe pool-certificate-install filename="$wlb_cert_name"
        rm -f "$wlb_cert_name"
    fi
    xe pool-initialize-wlb wlb_url="$wlb_host_port" wlb_username="$wlb_username" \
        wlb_password="$wlb_password" xenserver_username="$user" xenserver_password="$pass"

    # Disconnect from the appliance however the rest of this goes, or the pool stays attached to it. This
    # script dispatches to exactly one workflow and then exits, so an EXIT trap is bash's try/finally.
    trap 'xe pool-deconfigure-wlb; [ -z "$wlb_cert_name" ] || xe pool-certificate-uninstall name="$wlb_cert_name"' EXIT

    # Initializing connects the pool to the appliance but leaves balancing off: every WLB call after this
    # would fail WLB_DISABLED until it's switched on.
    pool=$(xe pool-list --minimal)
    xe pool-param-set uuid=$pool wlb-enabled=true
    echo "WLB: $(xe pool-list params=wlb-url --minimal)"

    # One line per recommendation, keyed by VM: "wlb", the destination host UUID, two ids, the reason.
    xe pool-retrieve-wlb-recommendations

    # A VM's own recommendations are keyed by host and star-rate each as a destination - higher is better
    # (a real appliance rated hosts 6.1 here, so not capped at XenCenter's five stars). Right after
    # connecting, the appliance is still discovering the pool: WLB_INTERNAL_ERROR 4024 ("Pool discovery has
    # not been started"), 4025 ("... has not been completed"), then 4016 ("WLB does not have current
    # metrics") - keep asking for a while. xe prints the error's message, not its
    # code, so match on the text.
    vm=$(vm_uuid "$vm_name")
    deadline=$((SECONDS + 600))
    while true; do
        if out=$(xe vm-retrieve-wlb-recommendations uuid=$vm 2>&1); then break; fi
        case "$out" in
            *4024*|*4025*|*"Pool discovery has not been"*|*4016*|*"does not have current metrics"*) ;;
            *) echo "$out" >&2; exit 1 ;;
        esac
        if [ $SECONDS -gt $deadline ]; then echo "$out" >&2; exit 1; fi
        sleep 15
    done
    printf '%s\n' "$out"

    # The appliance's own settings are read and written as one flat map of strings. Send a nightly
    # reporting schedule, then read the configuration back to confirm it took.
    xe pool-send-wlb-configuration config:ReportingCronString="0 3 * * *"
    echo "  appliance configuration: $(xe pool-retrieve-wlb-configuration)"

    echo "OK: wlb-recommendations"
}

# --- Configure clustering (GFS2) ---------------------------------------------------------
w_configure_clustering() {
    local cluster member
    cluster=$(first_csv "$(xe cluster-list --minimal)")
    if [ -z "$cluster" ]; then
        cluster=$(xe cluster-pool-create network-uuid="$(first_csv "$(xe network-list --minimal)")")
    fi

    echo "Stack:      $(xe cluster-list uuid="$cluster" params=cluster-stack --minimal)"
    echo "Quorate:    $(xe cluster-list uuid="$cluster" params=is-quorate --minimal)"

    # Taking a host out is what a management-interface change does; it can cost quorum.
    member=$(first_csv "$(xe cluster-host-list --minimal)")
    xe cluster-host-disable uuid="$member"
    echo "One member out, quorate: $(xe cluster-list uuid="$cluster" params=is-quorate --minimal)"

    xe cluster-host-enable uuid="$member"
    xe cluster-pool-resync
    echo "Resynced,   quorate: $(xe cluster-list uuid="$cluster" params=is-quorate --minimal)"
    echo "OK: configure-clustering"
}

# --- Manage pool membership --------------------------------------------------------------
w_manage_pool_membership() {
    local original other
    original=$(xe pool-list params=master --minimal)
    echo "Coordinator: $(xe host-list uuid="$original" params=name-label --minimal)"
    for h in $(each_csv "$(xe host-list --minimal)"); do
        if [ "$h" = "$original" ]; then
            echo "  member: $(xe host-list uuid="$h" params=name-label --minimal) (coordinator)"
        else
            echo "  member: $(xe host-list uuid="$h" params=name-label --minimal)"
            other=$h
        fi
    done

    # Promote another member. The pool database moves with the role and clients are redirected, so this
    # briefly interrupts management traffic - it does not move any VM. pool-designate-new-master restarts
    # xapi pool-wide, so the connection this script is using does not survive it: reconnect (a bounded
    # wait/retry, the same way XenRT's own helper for this call does) before touching the pool again,
    # rather than assuming the next xe call will just work.
    # Names first: once the switch starts, the address this script talks to may already be a supporter.
    local other_name original_name
    other_name=$(xe host-list uuid="$other" params=name-label --minimal)
    original_name=$(xe host-list uuid="$original" params=name-label --minimal)
    xe pool-designate-new-master host-uuid="$other"
    echo "Promoting:   $other_name (xapi restarts pool-wide; reconnecting)"
    reconnect_after_master_change "$other"
    echo "Promoted:    $other_name"

    # Put it back. Ejecting a member (pool-eject) is the other half of this surface and is deliberately
    # not shown: it cannot be undone from the pool, because rejoining is initiated by the ejected host.
    xe pool-designate-new-master host-uuid="$original"
    echo "Restoring:   $original_name (reconnecting again)"
    reconnect_after_master_change "$original"
    echo "Restored:    $original_name"
    echo "OK: manage-pool-membership"
}

# --- Create a NIC bond ---------------------------------------------------------------------
w_create_bond() {
    # NOT `host`: that is the script-level variable the xe() wrapper passes to -s, and shadowing it
    # replaces the server address with a uuid, after which every call fails with "No hostname was
    # specified" and the cause is nowhere near the symptom.
    local host_uuid spares network bond master
    host_uuid=$(first_csv "$(xe host-list --minimal)")

    # Pick up any NIC racked since the host booted; without it a card added a moment ago is not there
    # to bond.
    xe pif-scan host-uuid=$host_uuid

    # Spare NICs only. A bond that includes the management interface moves the management address onto
    # the bond master - on a real host that is how you lose the connection you are working over.
    spares=$(xe pif-list host-uuid="$host_uuid" management=false physical=true --minimal)
    if [ "$(count_csv "$spares")" -lt 2 ]; then
        echo "$(xe host-param-get uuid=$host_uuid param-name=name-label) has $(count_csv "$spares") spare NIC(s); a bond needs two that aren't the management interface" >&2
        return 1
    fi
    spares="$(first_csv "$spares"),$(nth_csv "$spares" 2)"
    echo "Bonding:      $spares"

    network=$(xe network-create name-label=sdk-example-bond)
    bond=$(xe bond-create network-uuid="$network" pif-uuids="$spares" mode=balance-slb)
    master=$(xe bond-list uuid="$bond" params=master --minimal)
    echo "Bond master:  $(xe pif-list uuid="$master" params=device --minimal)"
    echo "Mode:         $(xe bond-list uuid="$bond" params=mode --minimal)"

    xe bond-destroy uuid="$bond"
    xe network-destroy uuid="$network"
    echo "Bonds left:   $(count_csv "$(xe bond-list --minimal)")"
    echo "OK: create-bond"
}

# --- Configure PVS Accelerator ---
w_configure_pvs_accelerator() {
    local vm_name vm vif
    vm_name=$(param vm_name "db-01")
    # Check the VM first, before creating anything: it needs a NIC for the proxy to sit on, and one that
    # no site accelerates yet (a VIF takes one proxy: PVS_PROXY_ALREADY_PRESENT). It need not be running
    # - a proxy on a halted VM just reports "stopped" until it starts.
    vm=$(vm_uuid "$vm_name")
    name=$(xe vm-param-get uuid=$vm param-name=name-label)
    vif=$(lowest_device_vif "$vm")
    if [ -z "$vif" ]; then
        echo "$vm_name has no network interface to accelerate" >&2
        return 1
    fi
    existing=$(xe pvs-proxy-list vif-uuid=$vif --minimal)
    if [ -n "$existing" ]; then
        existing_site=$(xe pvs-proxy-param-get uuid=$existing param-name=site-uuid)
        echo "$vm_name is already accelerated by site '$(xe pvs-site-param-get uuid=$existing_site param-name=name-label)'" >&2
        return 1
    fi

    site=$(xe pvs-site-introduce name-label=sdk-example-pvs name-description="Created by the SDK examples")
    xe pvs-server-introduce addresses=10.62.0.90 first-port=6910 last-port=6930 pvs-site-uuid="$site" >/dev/null

    # The read cache must be on LOCAL storage: keeping reads off the network is the point, so a cache
    # on a shared SR would defeat it and the server rejects one.
    for h in $(each_csv "$(xe host-list --minimal)"); do
        for pbd in $(each_csv "$(xe pbd-list host-uuid=$h --minimal)"); do
            sr=$(xe pbd-param-get uuid=$pbd param-name=sr-uuid)
            [ "$(xe sr-param-get uuid=$sr param-name=shared)" = "false" ] || continue
            [ "$(xe sr-param-get uuid=$sr param-name=content-type)" = "iso" ] && continue
            xe pvs-cache-storage-create uuid=$h sr-uuid=$sr pvs-site-uuid="$site" size=10737418240 >/dev/null
            break
        done
    done

    # A proxy may only sit on the VM's LOWEST-numbered NIC, hence sorting by device above rather than
    # just taking the first VIF listed — the list comes back in creation order, which is the same thing
    # only by luck.
    proxy=$(xe pvs-proxy-create pvs-site-uuid="$site" vif-uuid="$vif")

    # Scoped to THIS site: the pool may already have one, and counting pool-wide would report its
    # caches and servers as though this example had made them.
    caches=$(count_csv "$(xe pvs-cache-storage-list pvs-site-uuid="$site" --minimal)")
    servers=$(count_csv "$(xe pvs-server-list pvs-site-uuid="$site" --minimal)")
    echo "Site '$(xe pvs-site-param-get uuid=$site param-name=name-label)' with $caches cache(s) and $servers server(s)"
    # "caching" means it is really accelerating: a site with no cache reports "initialised", and a
    # proxy on a VM whose NIC is unplugged reports "stopped".
    echo "  $name: $(xe pvs-proxy-param-get uuid=$proxy param-name=status)"

    # Forgetting the site only cascades its cache storage - a running proxy or a server it still has makes
    # forget refuse with PVS_SITE_CONTAINS_RUNNING_PROXIES/_SERVERS, so tear those down first, in the same
    # order every real PVS teardown uses.
    xe pvs-proxy-destroy uuid="$proxy"
    for srv in $(each_csv "$(xe pvs-server-list pvs-site-uuid="$site" --minimal)"); do
        xe pvs-server-forget uuid="$srv"
    done
    xe pvs-site-forget uuid="$site"
    echo "OK: configure-pvs-accelerator"
}

# The VIF with the lowest device number on a VM. (vif-list --minimal prints only uuids even when params=
# names more fields, so each VIF's device is read on its own.)
lowest_device_vif() {
    local vif dev best_uuid="" best_dev=""
    for vif in $(each_csv "$(xe vif-list vm-uuid=$1 --minimal)"); do
        dev=$(xe vif-param-get uuid=$vif param-name=device)
        if [ -z "$best_dev" ] || [ "$dev" -lt "$best_dev" ]; then best_uuid=$vif; best_dev=$dev; fi
    done
    echo "$best_uuid"
}

# --- Manage SSH access ---
w_manage_ssh_access() {
    # Timed access is the point: set the timeout first and the server stamps an expiry when SSH is
    # enabled, so a window opened for troubleshooting closes itself. pool.set_ssh_enabled_timeout is
    # itself a pool-wide fan-out call (exactly like enable_ssh/disable_ssh below), but unlike those two,
    # xe has no CLI command for it at all - only the per-host field is reachable from the CLI - so the
    # host loop here is the only way to do this through xe, not a simplification the SDK languages need.
    # Each host's SSH as we found it, to put back at the end: disabling it is not the example's to keep.
    local before=""
    for h in $(each_csv "$(xe host-list --minimal)"); do
        before="$before $h:$(xe host-param-get uuid=$h param-name=ssh-enabled):$(xe host-param-get uuid=$h param-name=ssh-enabled-timeout)"
        xe host-param-set uuid=$h ssh-enabled-timeout=3600
    done

    # The pool command fans out to every host, so there is no need to loop for the enable itself.
    xe pool-enable-ssh
    for h in $(each_csv "$(xe host-list --minimal)"); do
        echo "$(xe host-param-get uuid=$h param-name=name-label): ssh enabled=$(xe host-param-get uuid=$h param-name=ssh-enabled), expires $(xe host-param-get uuid=$h param-name=ssh-expiry)"
    done

    xe pool-disable-ssh
    states=""
    for h in $(each_csv "$(xe host-list --minimal)"); do
        [ -n "$states" ] && states="$states, "
        states="$states$(xe host-param-get uuid=$h param-name=name-label)=$(xe host-param-get uuid=$h param-name=ssh-enabled)"
    done
    echo "After disable: $states"

    local entry h enabled timeout
    for entry in $before; do
        IFS=: read -r h enabled timeout <<< "$entry"
        xe host-param-set uuid=$h ssh-enabled-timeout=$timeout   # first: enabling stamps the expiry from it
        [ "$enabled" = true ] && xe host-enable-ssh uuid=$h
    done
    echo "OK: manage-ssh-access"
}

# --- Change control domain memory ---
w_control_domain_memory() {
    h=$(nth_csv "$(xe host-list --minimal)" 1)
    # dom0 is a VM like any other, and vm-list includes it: one control domain per host.
    dom0=$(first_csv "$(xe vm-list is-control-domain=true resident-on=$h --minimal)")
    [ -n "$dom0" ] || { echo "the host reports no control domain" >&2; return 1; }
    original=$(xe vm-param-get uuid=$dom0 param-name=memory-dynamic-min)
    echo "$(xe host-param-get uuid=$h param-name=name-label) dom0: $((original / 1024 / 1024 / 1024)) GiB"

    # vm-memory-set, not vm-memory-limits-set: dom0 does not balloon, so one value pins the static and
    # dynamic bounds and the target together. It takes effect at the host's next reboot.
    xe vm-memory-set uuid=$dom0 memory=$((original + 1073741824))
    echo "  now $(( $(xe vm-param-get uuid=$dom0 param-name=memory-dynamic-min) / 1024 / 1024 / 1024 )) GiB (static $(xe vm-param-get uuid=$dom0 param-name=memory-static-min)-$(xe vm-param-get uuid=$dom0 param-name=memory-static-max), dynamic $(xe vm-param-get uuid=$dom0 param-name=memory-dynamic-min)-$(xe vm-param-get uuid=$dom0 param-name=memory-dynamic-max))"

    xe vm-memory-set uuid=$dom0 memory=$original    # leave the pool as we found it
    echo "OK: control-domain-memory"
}

# --- Manage a vTPM ---
w_manage_vtpm() {
    # A halted VM with no vTPM yet. A VM may have at most one, and it can only be attached while halted
    # - the device is presented to the guest at boot.
    for v in $(each_csv "$(xe vm-list power-state=halted --minimal)"); do
        [ -z "$(xe vm-param-get uuid=$v param-name=vtpms)" ] && { vm=$v; break; }
    done
    echo "Attaching a vTPM to $(xe vm-param-get uuid=$vm param-name=name-label)"

    vtpm=$(xe vtpm-create vm-uuid=$vm is-unique=false)
    echo "  unique to this VM:   $(xe vtpm-param-get uuid=$vtpm param-name=is_unique)"
    echo "  protected:           $(xe vtpm-param-get uuid=$vtpm param-name=is_protected)"
    echo "  VM now has $(count_csv "$(set_to_csv "$(xe vm-param-get uuid=$vm param-name=vtpms)")") vTPM(s)"

    # The VM advertises whether another can be added; once it has one, it cannot.
    case "$(xe vm-param-get uuid=$vm param-name=allowed-operations)" in
        *create_vtpm*) echo "  can add another:     true" ;;
        *)             echo "  can add another:     false" ;;
    esac

    xe vtpm-destroy uuid=$vtpm --force       # xe insists: the vTPM's secrets are destroyed with it
    echo "  after removal:       $(count_csv "$(set_to_csv "$(xe vm-param-get uuid=$vm param-name=vtpms)")") vTPM(s)"
    echo "OK: manage-vtpm"
}

# --- Back up with changed block tracking ---
w_changed_block_tracking() {
    vm=$(nth_csv "$(xe vm-list is-control-domain=false --minimal)" 1)
    echo "Backing up $(xe vm-param-get uuid=$vm param-name=name-label)"

    # CBT is switched on for the VM's own disk, and every snapshot taken from then on inherits it. It
    # can't be switched on for a snapshot's disk after the fact (OPERATION_NOT_ALLOWED).
    live=$(first_disk_vdi "$vm")
    was_enabled=$(xe vdi-param-get uuid=$live param-name=cbt-enabled)
    [ "$was_enabled" = "true" ] || xe vdi-enable-cbt uuid=$live

    first=$(xe vm-snapshot uuid=$vm new-name-label=cbt-backup-1)
    second=$(xe vm-snapshot uuid=$vm new-name-label=cbt-backup-2)
    vdi_from=$(first_disk_vdi "$first")
    vdi_to=$(first_disk_vdi "$second")

    # One bit per 64 KiB block, base64-encoded; bit N set means block N changed. A real backup reads only
    # those blocks, over NBD. Counting the bits needs a decoder, which bash is not - so report the size
    # of the answer and let the language examples do the arithmetic.
    encoded=$(xe vdi-list-changed-blocks vdi-from-uuid=$vdi_from vdi-to-uuid=$vdi_to)
    size=$(xe vdi-param-get uuid=$vdi_to param-name=virtual-size)
    echo "  bitmap of ${#encoded} base64 chars covers $((size / 65536)) blocks of 64 KiB"

    # Release the older snapshot's blocks but keep its change metadata, so the next incremental can still
    # diff against it. vdi-data-destroy refuses a disk that a VM still uses (VDI_IN_USE), so drop the older
    # snapshot's VM record first (snapshot-destroy leaves its disk), as a backup tool does. The VDI record
    # stays; its type changes.
    xe snapshot-destroy uuid=$first
    xe vdi-data-destroy uuid=$vdi_from
    echo "  older snapshot is now type=$(xe vdi-param-get uuid=$vdi_from param-name=type), still cbt-enabled=$(xe vdi-param-get uuid=$vdi_from param-name=cbt-enabled)"

    # Tidy up: the newer snapshot and its disk, the metadata-only VDI, and CBT on the VM's own disk if this
    # example switched it on.
    xe snapshot-uninstall snapshot-uuid=$second force=true
    xe vdi-destroy uuid=$vdi_from
    [ "$was_enabled" = "true" ] || xe vdi-disable-cbt uuid=$live
    echo "OK: changed-block-tracking"
}

# The VDI behind a VM's first real disk. CD drives are VBDs too, hence the type filter.
first_disk_vdi() {
    local vm=$1 vbd
    for vbd in $(each_csv "$(xe vbd-list vm-uuid=$vm --minimal)"); do
        if [ "$(xe vbd-param-get uuid=$vbd param-name=type)" = "Disk" ]; then
            xe vbd-param-get uuid=$vbd param-name=vdi-uuid
            return
        fi
    done
}

# --- Export and import a VM ---
w_export_import_vm() {
    vm_name=$(param vm_name "db-01")
    # Name the VM: an export carries every block of its disks, so which VM matters (a large one takes a
    # long time, and fills the disk). Only a halted VM can be exported: its disks must not be changing
    # underneath the copy.
    vm=$(vm_uuid "$vm_name")
    [ "$(xe vm-param-get uuid=$vm param-name=power-state)" = "halted" ] ||
        { echo "$vm_name must be halted to be exported" >&2; exit 1; }
    echo "Exporting $vm_name"

    # Relative to the working directory: xe.exe and this script must agree on the path, and a Windows
    # temp directory spelled with backslashes would not survive the trip through both.
    file="cli-export.xva"
    # Always clean up the file, on failure too: a real export is gigabytes, not worth leaving behind.
    trap 'rm -f "$file"' EXIT
    # xe does the HTTP transfer itself: the server answers the command by telling the client to GET
    # /export, and xe writes the file. Nothing streams down the CLI connection.
    xe vm-export uuid=$vm filename="$file"
    size=$(stat -c %s "$file" 2>/dev/null || wc -c < "$file")
    # Check the file, not xe's exit status: Windows xe.exe reports a failed transfer ("Export failed")
    # and still exits 0.
    [ "${size:-0}" -gt 0 ] || { echo "the export produced no data" >&2; exit 1; }
    echo "  wrote $((size / 1024 / 1024)) MiB to $(basename "$file")"

    # The SDK languages have to create a task, pass its id as /import?task_id=, and poll it themselves to
    # recover the imported VM's ref - a real host's /import response body doesn't carry it. xe does all of
    # that internally and hands back the new VM's uuid directly, so there is nothing extra to do here.
    imported=$(xe vm-import filename="$file")
    echo "  imported as $(xe vm-param-get uuid=$imported param-name=name-label)"

    # The import brought its own disks along; vm-uninstall destroys those too, not just the VM record.
    xe vm-uninstall uuid=$imported force=true
    echo "OK: export-import-vm"
}

# --- Configure dynamic memory ---
w_configure_dynamic_memory() {
    vm=$(nth_csv "$(xe vm-list power-state=halted --minimal)" 1)
    static_min=$(xe vm-param-get uuid=$vm param-name=memory-static-min)
    static_max=$(xe vm-param-get uuid=$vm param-name=memory-static-max)
    dyn_min=$(xe vm-param-get uuid=$vm param-name=memory-dynamic-min)
    dyn_max=$(xe vm-param-get uuid=$vm param-name=memory-dynamic-max)
    echo "$(xe vm-param-get uuid=$vm param-name=name-label): static $(gib $static_min)-$(gib $static_max), dynamic $(gib $dyn_min)-$(gib $dyn_max)"

    # Room to balloon: let the host squeeze the VM down to a quarter of its maximum, but never below the
    # static floor, which is the least the guest can boot in.
    floor=$((static_max / 4))
    [ "$floor" -lt "$static_min" ] && floor=$static_min
    xe vm-memory-dynamic-range-set uuid=$vm min=$floor max=$static_max
    echo "  dynamic range now $(gib $(xe vm-param-get uuid=$vm param-name=memory-dynamic-min))-$(gib $(xe vm-param-get uuid=$vm param-name=memory-dynamic-max))"

    # The ordering is enforced, not advisory: a range wider than the static bounds is refused rather than
    # quietly clamped.
    # Both streams: xe prints a XenAPI failure on stdout, so 2>/dev/null alone still shows it.
    if xe vm-memory-dynamic-range-set uuid=$vm min=$floor max=$((static_max * 2)) >/dev/null 2>&1; then
        echo "  ERROR: an out-of-range maximum was accepted"
    else
        echo "  refused a dynamic_max above static_max"
    fi

    xe vm-memory-dynamic-range-set uuid=$vm min=$dyn_min max=$dyn_max
    echo "OK: configure-dynamic-memory"
}

# Bytes as GiB to one decimal place, using shell arithmetic only - there is no floating point here, so
# the fraction is worked out from the remainder.
gib() {
    local bytes=$1 whole tenths
    whole=$((bytes / 1073741824))
    tenths=$(((bytes % 1073741824) * 10 / 1073741824))
    echo "${whole}.${tenths} GiB"
}

# --- Manage a VM's CD drive ---
w_manage_vm_media() {
    vm=$(nth_csv "$(xe vm-list power-state=halted --minimal)" 1)
    echo "Adding a DVD drive to $(xe vm-param-get uuid=$vm param-name=name-label)"

    # A CD drive is a VBD like any other, distinguished by type=CD; created without a disk it arrives
    # empty, and the media is whichever VDI it is later pointed at.
    device=$(first_csv "$(set_to_csv "$(xe vm-param-get uuid=$vm param-name=allowed-VBD-devices)")")
    drive=$(xe vbd-create vm-uuid=$vm device=$device type=CD mode=RO)
    echo "  drive $device is empty: $(xe vbd-param-get uuid=$drive param-name=empty)"

    # The ISO library is an SR of content type "iso"; its VDIs are the available images.
    # type=iso as well as content-type=iso: a host's physical DVD drive is content-type iso too, but it
    # is type udev and holds whatever disc is in the tray rather than a library of images.
    iso_sr=$(nth_csv "$(xe sr-list content-type=iso type=iso --minimal)" 1)
    iso=$(nth_csv "$(xe vdi-list sr-uuid=$iso_sr --minimal)" 1)
    echo "  inserting $(xe vdi-param-get uuid=$iso param-name=name-label)"
    xe vbd-insert uuid=$drive vdi-uuid=$iso
    echo "  drive now holds $(xe vdi-param-get uuid=$(xe vbd-param-get uuid=$drive param-name=vdi-uuid) param-name=name-label) (empty=$(xe vbd-param-get uuid=$drive param-name=empty))"

    xe vbd-eject uuid=$drive
    echo "  after eject, empty=$(xe vbd-param-get uuid=$drive param-name=empty)"

    xe vbd-destroy uuid=$drive
    echo "OK: manage-vm-media"
}

# --- Back up a host's configuration ---
w_backup_host_config() {
    # Deliberately not `host`: that is the variable the xe() helper dials, and shadowing it here sent
    # every later command to a server named after the host's UUID.
    target=$(nth_csv "$(xe host-list --minimal)" 1)
    echo "Backing up $(xe host-param-get uuid=$target param-name=name-label)"

    # Relative to the working directory: xe.exe and this script must agree on the path, and a Windows
    # temp directory spelled with backslashes would not survive the trip through both.
    file="cli-host.backup"
    rm -f "$file"   # xe refuses to overwrite an existing file rather than clobbering it
    # xe does the HTTP transfer itself: the server answers the command by telling the client to GET
    # /host_backup, and xe writes the file. Nothing streams down the CLI connection.
    xe host-backup uuid=$target file-name="$file"
    size=$(stat -c %s "$file" 2>/dev/null || wc -c < "$file")
    echo "  wrote $size bytes to $file"

    xe host-restore uuid=$target file-name="$file"
    echo "  restoring it to $(xe host-param-get uuid=$target param-name=name-label): accepted"

    other=$(nth_csv "$(xe host-list --minimal)" 2)
    if [ -n "$other" ]; then
        # host-backup/host-restore are served only by whichever host physically accepted the connection -
        # xe's own uri_of_someone already dials that host's address directly by uuid, there is no
        # forwarding and no ref= to check, so this is not refused on a real pool the way a naive reading of
        # "restoring one host's config onto another" might suggest. A real pool's hosts are all reachable
        # from a management client; guard the attempt anyway with a friendly message on any transport
        # error, for topologies (like this project's test fixture) where a second host's address isn't
        # actually routable from here.
        if err=$(xe host-restore uuid=$other file-name="$file" 2>&1); then
            echo "  restoring it to $(xe host-param-get uuid=$other param-name=name-label): accepted"
        else
            echo "  restoring it to $(xe host-param-get uuid=$other param-name=name-label): could not restore ($err)"
        fi
    fi

    rm -f "$file"
    echo "OK: backup-host-config"
}

# --- Detach, reattach and forget storage ---
w_manage_sr_lifecycle() {
    sr=$(xe sr-create name-label=xe-example-lifecycle type=nfs content-type=user shared=true \
        device-config:server="$(param nfs_server 192.0.2.10)" \
        device-config:serverpath="$(param nfs_path /export/spare)" device-config:nfsversion=3)

    # There is no sr-detach: a shared SR is joined to each host by one PBD, and detaching the SR means
    # unplugging every one of them. That is why an SR can be attached on some hosts and not others.
    pbds=$(xe pbd-list sr-uuid=$sr --minimal)
    echo "$(xe sr-param-get uuid=$sr param-name=name-label): connected on $(count_attached_pbd "$pbds") of $(count_csv "$pbds") host(s)"

    for pbd in $(each_csv "$pbds"); do xe pbd-unplug uuid=$pbd; done
    echo "  detached:   connected on $(count_attached_pbd "$pbds") host(s)"

    # Plugging them back is exactly what a repair does.
    for pbd in $(each_csv "$pbds"); do xe pbd-plug uuid=$pbd; done
    echo "  reattached: connected on $(count_attached_pbd "$pbds") host(s)"

    xe sr-scan uuid=$sr
    echo "  rescanned:  $(count_csv "$(xe vdi-list sr-uuid=$sr --minimal)") disk(s)"

    # Forgetting drops the pool's record of the SR but leaves the storage itself untouched, so the same
    # export can be introduced again later. Detach before forgetting: a connected SR is still in use.
    for pbd in $(each_csv "$pbds"); do xe pbd-unplug uuid=$pbd; done
    xe sr-forget uuid=$sr
    echo "  forgotten"
    echo "OK: manage-sr-lifecycle"
}

# How many of the given PBDs are currently attached.
count_attached_pbd() {
    local n=0
    for pbd in $(each_csv "$1"); do
        if [ "$(xe pbd-param-get uuid=$pbd param-name=currently-attached)" = "true" ]; then n=$((n + 1)); fi
    done
    echo $n
}

# --- Set the pool's default storage ---
w_set_default_sr() {
    pool=$(first_csv "$(xe pool-list --minimal)")

    # Three independent settings: where new disks go, where a suspended VM's memory image is written and
    # where host crash dumps land. Capture each - a pool that has never suspended or crashed anything can
    # legitimately leave the latter two unset, so restoring all three from the default would quietly
    # invent settings that were not there. xe prints and accepts these as UUIDs.
    before=$(pool_sr_setting $pool default-SR)
    before_suspend=$(pool_sr_setting $pool suspend-image-SR)
    before_crash=$(pool_sr_setting $pool crash-dump-SR)
    echo "default storage:  $(sr_label "$before")"
    echo "  suspend images: $(sr_label "$before_suspend")"
    echo "  crash dumps:    $(sr_label "$before_crash")"

    # Somewhere to switch to. The pool default has to be reachable from every host, so it is shared
    # storage; a local SR would strand any VM whose disk landed on the wrong host.
    sr=$(xe sr-create name-label=xe-example-default type=nfs content-type=user shared=true \
        device-config:server="$(param nfs_server 192.0.2.10)" \
        device-config:serverpath="$(param nfs_path /export/spare)" device-config:nfsversion=3)
    xe pool-param-set uuid=$pool default-SR=$sr suspend-image-SR=$sr crash-dump-SR=$sr
    echo "  switched to:    $(sr_label "$(xe pool-param-get uuid=$pool param-name=default-SR)")"

    # Put the original choice back before tidying up: storage that is still the pool default is the
    # awkward thing to remove.
    xe pool-param-set uuid=$pool default-SR=$before suspend-image-SR=$before_suspend crash-dump-SR=$before_crash
    for pbd in $(each_csv "$(xe pbd-list sr-uuid=$sr --minimal)"); do xe pbd-unplug uuid=$pbd; done
    xe sr-forget uuid=$sr
    echo "  restored to:    $(sr_label "$(xe pool-param-get uuid=$pool param-name=default-SR)")"
    echo "OK: set-default-sr"
}

# The value of a named attribute in an XML element, using parameter expansion only - no xmllint, and no
# sed/grep process per attribute. Name the attribute in full: a prefix match would make `size` collect
# `min-size` as well.
xml_attr() {
    case "$1" in
        *"$2=\""*) local rest=${1#*$2=\"}; echo "${rest%%\"*}" ;;
        *) echo "" ;;
    esac
}

# An SR's name from its UUID, tolerating the empty value an unset pool setting prints.
sr_label() {
    if [ -z "$1" ]; then echo "(none)"; else xe sr-param-get uuid=$1 param-name=name-label; fi
}

# One of the pool's SR settings, as a uuid or "" when unset. xe prints an unset reference as
# "<not in database>", but setting one takes "" to mean unset - so map one to the other, or the value
# read cannot be written back.
pool_sr_setting() {
    local v
    v=$(xe pool-param-get uuid=$1 param-name=$2)
    [ "$v" = "<not in database>" ] && v=""
    echo "$v"
}

# --- Collect a server status report ---
w_server_status_report() {
    # Each host answers for itself, so which one you ask decides whose logs you get - support normally
    # wants one report per host. Here, the coordinator.
    pool=$(first_csv "$(xe pool-list --minimal)")
    target=$(xe pool-param-get uuid=$pool param-name=master)
    echo "Status report for $(xe host-param-get uuid=$target param-name=name-label)"

    # The host publishes a catalogue of the sections it can report on, each with a size estimate and
    # whether it may contain personal data, so you can decide what to collect before collecting it.
    capabilities=$(xe host-get-system-status-capabilities uuid=$target)
    keys=""
    defaults=""
    # Split the XML on '<' with bash's own field splitting rather than spawning a parser: each element
    # starts a field, and the ones we want begin `capability key="..."`.
    old_ifs=$IFS; IFS='<'
    for element in $capabilities; do
        case "$element" in
            capability\ *)
                key=$(xml_attr "$element" key)
                keys="${keys:+$keys,}$key"
                default_checked=$(xml_attr "$element" default-checked)
                [ "$default_checked" = "yes" ] && defaults="${defaults:+$defaults,}$key"
                printf '  %-22s max %9s bytes  default=%-3s pii=%s\n' \
                    "$key" "$(xml_attr "$element" max-size)" \
                    "$default_checked" "$(xml_attr "$element" pii)"
                ;;
        esac
    done
    IFS=$old_ifs

    rm -f cli-status-all.tar cli-status-config.tar
    # Take the sections the host marks default-checked, as XenCenter's dialog does: asking for every
    # section can mean gigabytes (VM memory dumps, every log) and a long wait while the host builds it.
    xe host-get-system-status uuid=$target filename=cli-status-all.tar entries="$defaults"
    whole=$(stat -c %s cli-status-all.tar)
    echo "default sections ($(count_csv "$defaults") of $(count_csv "$keys")): $whole bytes"

    # Pick a real, small section from the host's own catalogue rather than assuming a name: the catalogue
    # is server-defined (xen-bugtool's own --capabilities output), not a fixed client list, and
    # "xenserver-config" isn't one of the real keys any host actually publishes.
    subset_key=""
    for preferred in firstboot network-status; do
        case ",$keys," in *",$preferred,"*) subset_key=$preferred; break ;; esac
    done
    [ -n "$subset_key" ] || subset_key=$(first_csv "$keys")

    # Worth checking rather than assuming: a server that ignored the selection would look identical from
    # here until someone opened the archive and found the whole thing.
    xe host-get-system-status uuid=$target filename=cli-status-config.tar entries="$subset_key"
    subset=$(stat -c %s cli-status-config.tar)
    echo "$subset_key only:   $subset bytes"
    if [ "$subset" -ge "$whole" ]; then
        echo "  ERROR: selecting fewer sections did not produce a smaller bundle"
    fi

    rm -f cli-status-all.tar cli-status-config.tar
    echo "OK: server-status-report"
}

# --- Recover VMs after a disaster ---
# Disaster recovery works by writing the pool's own database out to a storage repository as a disk of
# type "metadata", then reading that back as a SEPARATE database to recover a VM out of it onto a second,
# standby pool. Recovering a VM back into the exact pool it was replicated from can't actually succeed with
# force=false (its uuid already exists there, so VM.recover always takes the replace-or-fail path and
# nothing replicated a moment ago from a live database can ever be "newer" than the live object it came
# from) - force=true would "fix" that by REPLACING (destroying and recreating) the live original, which is
# the one thing a DR demo must never do. A second pool is the only correct target, which is why this needs
# dr_url with no simulator-friendly default: pass dr_url=<url of a standby pool>. xe has no "session_to"
# argument to carry this (unlike the SDK languages' session-based VM.recover): instead, run the
# assert/recover calls on a connection opened to the standby pool itself, pointed at the metadata disk by
# uuid - the storage it lives on has to be reachable from the standby pool too, which is the whole premise
# of DR replication.
w_disaster_recovery() {
    local dr_url dr_host dr_hp dr_probe
    local -a dr_opts
    dr_url=$(param dr_url "")
    if [ -z "$dr_url" ]; then
        echo "disaster-recovery needs a second pool to recover into: pass dr_url=<url of a standby pool>" >&2
        exit 1
    fi
    dr_hp=${dr_url#*://}; dr_hp=${dr_hp%%/*}
    dr_host=${dr_hp%%:*}
    dr_opts=()
    if [ "$dr_hp" != "$dr_host" ] && [ "${dr_hp##*:}" != 443 ]; then dr_opts=(-p $((${dr_hp##*:} + 1))); fi
    case "${XE_EXE:-xe}" in *.exe | *.EXE) dr_opts+=(-no-warn-new-certificates -no-warn-certificates) ;; esac
    xe_dr() { command "${XE_EXE:-xe}" -s "$dr_host" "${dr_opts[@]}" -u "$user" -pw "$pass" "$@"; }
    # Follow HOST_IS_SLAVE on the standby pool too, the same one-time probe the main connection does.
    dr_probe=$(xe_dr pool-list --minimal 2>&1) || true
    if [[ $dr_probe =~ (Master|Coordinator)\ IP\ address:\ ([0-9A-Fa-f.:]+) ]]; then dr_host=${BASH_REMATCH[2]}; fi

    # Replication needs shared storage that can hold data.
    sr=$(shared_sr)
    echo "Replicating pool metadata to $(xe sr-param-get uuid=$sr param-name=name-label)"
    xe sr-enable-database-replication uuid=$sr

    vdi=$(first_csv "$(xe vdi-list type=metadata sr-uuid=$sr --minimal)")
    echo "  metadata disk: $vdi"

    # `database:vdi-uuid=` runs the command against the replicated database instead of the live pool, so
    # this lists the VMs as they were written out rather than the ones running now - only real guest VMs
    # are recoverable, so exclude templates, control domains and snapshots.
    recoverable=$(xe vm-list database:vdi-uuid=$vdi is-a-template=false is-control-domain=false \
        is-a-snapshot=false --minimal)
    echo "  the replicated database describes $(count_csv "$recoverable") recoverable VM(s)"

    md=$(first_csv "$recoverable")
    name=$(xe vm-list uuid=$md database:vdi-uuid=$vdi params=name-label --minimal)
    echo "  recovering $name"

    xe_dr vm-assert-can-be-recovered uuid=$md database:vdi-uuid=$vdi
    xe_dr vm-recover uuid=$md database:vdi-uuid=$vdi force=false

    # It is a real VM on the standby pool now, not merely a command that returned - look it up there, by
    # the uuid full_restore preserved, never by name (a name can coincidentally collide with something
    # already on the destination pool).
    echo "  $name is $(xe_dr vm-param-get uuid=$md param-name=power-state) on the standby pool"

    # Tidy up on the standby pool only, by uuid - never touch the source pool's VMs.
    xe_dr vm-uninstall uuid=$md force=true
    xe sr-disable-database-replication uuid=$sr
    echo "OK: disaster-recovery"
}

# --- Manage Secure Boot certificates ---
w_manage_secureboot_certificates() {
    # A Secure Boot guest carries its own copy of the pool's UEFI certificates, taken when it was created.
    # Rotating the pool's leaves the guest's stale, and the fix is applied at the guest's next boot rather
    # than underneath a running VM - so you flag it and reboot when convenient.
    #
    # "ready_no_dbx" means the pool has the essentials but no revocation list - usable, and deliberately
    # not the same answer as "ready".
    echo "Pool Secure Boot readiness: $(xe pool-get-guest-secureboot-readiness)"
    pool=$(first_csv "$(xe pool-list --minimal)")
    if [ -n "$(xe pool-param-get uuid=$pool param-name=uefi-certificates)" ]; then holds=true; else holds=false; fi
    echo "  pool holds certificates:  $holds"

    # A guest whose certificates have gone stale. The state is a plain field, so it filters like any other.
    # This is a deliberately-seeded state, not one an ordinarily-provisioned pool is ever in - report and
    # stop cleanly when no VM needs it, rather than operating on an empty uuid.
    vm=$(first_csv "$(xe vm-list secureboot-certificates-state=update_available --minimal)")
    if [ -z "$vm" ]; then
        echo "No guest needs a Secure Boot certificate refresh right now."
        echo "OK: manage-secureboot-certificates"
        return
    fi
    echo "$(xe vm-param-get uuid=$vm param-name=name-label): readiness $(xe vm-get-secureboot-readiness uuid=$vm), certificates $(xe vm-param-get uuid=$vm param-name=secureboot-certificates-state)"

    # Flagging and unflagging are the same command with opposite values of mark=.
    xe vm-update-secureboot-certificates-on-boot uuid=$vm mark=true
    echo "  flagged for refresh:      $(xe vm-param-get uuid=$vm param-name=secureboot-certificates-state)"

    xe vm-update-secureboot-certificates-on-boot uuid=$vm mark=false
    echo "  unflagged:                $(xe vm-param-get uuid=$vm param-name=secureboot-certificates-state)"
    echo "OK: manage-secureboot-certificates"
}

# --- Restart a host ---
w_restart_host() {
    # Rebooting a host is never just the reboot: anything running on it has to go somewhere first, and the
    # host has to stop accepting new VMs while that happens.
    #
    # Not the coordinator: it is the host xe is talking to, and taking it down would drop the connection
    # underneath the rest of the example.
    pool=$(first_csv "$(xe pool-list --minimal)")
    coordinator=$(xe pool-param-get uuid=$pool param-name=master)
    target=""
    for h in $(each_csv "$(xe host-list --minimal)"); do
        if [ "$h" != "$coordinator" ]; then target=$h; break; fi
    done
    echo "Restarting $(xe host-param-get uuid=$target param-name=name-label)"
    echo "  enabled=$(xe host-param-get uuid=$target param-name=enabled), guests=$(count_host_guest $target)"

    # Disabled means "accept no new VMs"; it does not move anything on its own.
    xe host-disable uuid=$target
    echo "  disabled:   enabled=$(xe host-param-get uuid=$target param-name=enabled)"

    # Evacuate moves the guests elsewhere in the pool. Afterwards only the control domain - the host's own
    # management VM, which cannot move - is left.
    xe host-evacuate uuid=$target
    echo "  evacuated:  guests=$(count_host_guest $target)"

    xe host-reboot uuid=$target
    # A real reboot takes minutes. Wait for the host to drop out and come back (live in its
    # host-metrics), then enable it. A host disabled the default way (auto_enable=true) re-enables
    # itself once its toolstack is up again, but only then - and one disabled with auto_enable=false
    # never does - so enable it explicitly rather than depend on either.
    wait_for_host_live "$target" false 600
    wait_for_host_live "$target" true 1200 10
    enable_when_booted "$target"
    echo "  rebooted, re-enabled: enabled=$(xe host-param-get uuid=$target param-name=enabled)"

    # The other ending: off, and back on out of band - but only demonstrated if that is actually
    # configured (host-power-on has no fallback and simply fails if no mechanism is configured or
    # working), and waiting for each transition before starting the next.
    if [ -n "$(xe host-param-get uuid=$target param-name=power-on-mode)" ]; then
        xe host-disable uuid=$target
        xe host-shutdown uuid=$target
        wait_for_host_live "$target" false
        echo "  shut down:  live=$(host_live $target)"
        xe host-power-on uuid=$target
        wait_for_host_live "$target" true 1200 10
        echo "  powered on: live=$(host_live $target)"
        enable_when_booted "$target"
        echo "  re-enabled: enabled=$(xe host-param-get uuid=$target param-name=enabled)"
    else
        echo "  skipping shutdown/power-on: no out-of-band power-on mode is configured on this host"
    fi
    echo "OK: restart-host"
}

# Resident VMs excluding the control domain, which never moves.
count_host_guest() {
    local n=0
    for vm in $(each_csv "$(set_to_csv "$(xe host-param-get uuid=$1 param-name=resident-VMs)")"); do
        if [ "$(xe vm-param-get uuid=$vm param-name=is-control-domain)" != "true" ]; then n=$((n + 1)); fi
    done
    echo $n
}

host_live() { xe host-param-get uuid=$1 param-name=host-metrics-live; }

# --- Create a VM and a template from a snapshot ---
w_vm_from_snapshot() {
    # A snapshot is a VM record with is-a-snapshot (and is-a-template) set, so xe can install a VM from it
    # like from any template, or clone it into a custom template that stands on its own.
    vm=$(vm_uuid db-01)
    snap=$(xe vm-snapshot uuid=$vm new-name-label=xe-example-source-snapshot)
    echo "Snapshot of db-01 taken"

    # vm-install from the snapshot gives an ordinary VM you can start, as from any template.
    newvm=$(xe vm-install template-uuid=$snap new-name-label=xe-example-vm-from-snapshot)
    echo "  new VM:      $(xe vm-param-get uuid=$newvm param-name=name-label) (is-a-template=$(xe vm-param-get uuid=$newvm param-name=is-a-template))"

    # snapshot-clone gives a template, not another snapshot: a starting point to stamp more VMs from.
    tmpl=$(xe snapshot-clone uuid=$snap new-name-label=xe-example-template-from-snapshot)
    echo "  new template:$(xe template-param-get uuid=$tmpl param-name=name-label) (is-a-template=$(xe template-param-get uuid=$tmpl param-name=is-a-template))"

    # Each made its own disks, and the snapshot has its own snapshot disks; the -uninstall commands destroy
    # them along with the records.
    xe vm-uninstall uuid=$newvm force=true
    xe template-uninstall template-uuid=$tmpl force=true
    xe snapshot-uninstall snapshot-uuid=$snap force=true
    echo "OK: vm-from-snapshot"
}

# --- Attach an existing disk to another VM ---
w_attach_existing_disk() {
    # A disk and the VM it belongs to are separate objects joined by a VBD, so moving a disk between VMs
    # is removing one VBD and creating another - no copying, and the data stays exactly where it is.
    halted=$(xe vm-list power-state=halted --minimal)
    first=$(nth_csv "$halted" 1)
    second=$(nth_csv "$halted" 2)
    sr=$(shared_sr)

    vdi=$(xe vdi-create sr-uuid=$sr name-label=xe-example-portable-disk virtual-size=4294967296 type=user)
    echo "Disk $(xe vdi-param-get uuid=$vdi param-name=name-label) created on $(xe sr-param-get uuid=$sr param-name=name-label)"

    device=$(first_csv "$(set_to_csv "$(xe vm-param-get uuid=$first param-name=allowed-VBD-devices)")")
    vbd=$(xe vbd-create vm-uuid=$first vdi-uuid=$vdi device=$device type=Disk mode=RW)
    echo "  attached to $(xe vm-param-get uuid=$first param-name=name-label)"

    # Destroying the VBD detaches the disk; the disk itself is untouched and keeps its data.
    xe vbd-destroy uuid=$vbd
    echo "  detached:   the disk still exists ($(xe vdi-param-get uuid=$vdi param-name=virtual-size) bytes)"

    device=$(first_csv "$(set_to_csv "$(xe vm-param-get uuid=$second param-name=allowed-VBD-devices)")")
    vbd2=$(xe vbd-create vm-uuid=$second vdi-uuid=$vdi device=$device type=Disk mode=RW)
    echo "  attached to $(xe vm-param-get uuid=$second param-name=name-label)"
    echo "  the disk is on $(count_csv "$(set_to_csv "$(xe vdi-param-get uuid=$vdi param-name=vbds)")") VM(s)"

    xe vbd-destroy uuid=$vbd2
    xe vdi-destroy uuid=$vdi
    echo "OK: attach-existing-disk"
}

# --- Clear a host's crash dumps ---
w_manage_crash_dumps() {
    # A host that crashes writes a dump to its local disk and keeps it. They are large and nothing cleans
    # them up, so clearing them once support has what it needs is ordinary housekeeping. They belong to
    # the host that wrote them, so clear them a host at a time.
    target=""
    for h in $(each_csv "$(xe host-list --minimal)"); do
        if [ -n "$(xe host-crashdump-list host-uuid=$h --minimal)" ]; then target=$h; break; fi
    done
    if [ -z "$target" ]; then
        echo "No crash dumps in this pool - nothing to clear."
        echo "OK: manage-crash-dumps"
        return
    fi

    dumps=$(xe host-crashdump-list host-uuid=$target --minimal)
    echo "$(xe host-param-get uuid=$target param-name=name-label) has $(count_csv "$dumps") crash dump(s)"
    total=0
    for d in $(each_csv "$dumps"); do
        size=$(xe host-crashdump-param-get uuid=$d param-name=size)
        total=$((total + size))
        echo "  $(xe host-crashdump-param-get uuid=$d param-name=timestamp)  $((size / 1048576)) MiB"
    done
    echo "  $((total / 1048576)) MiB in total"

    # Deleting a dump frees the space on the host; the host itself is untouched.
    for d in $(each_csv "$dumps"); do xe host-crashdump-destroy uuid=$d; done
    echo "  cleared:  $(xe host-param-get uuid=$target param-name=name-label) now has $(count_csv "$(xe host-crashdump-list host-uuid=$target --minimal)")"
    echo "OK: manage-crash-dumps"
}

# --- Configure pool options ---
# The opposite of a "true"/"false" string, for toggling a boolean field and restoring it.
negate() { [ "$1" = "true" ] && echo false || echo true; }

w_configure_pool_options() {
    pool=$(first_csv "$(xe pool-list --minimal)")
    live_patching=$(xe pool-param-get uuid=$pool param-name=live-patching-disabled)
    igmp=$(xe pool-param-get uuid=$pool param-name=igmp-snooping-enabled)
    migration_compression=$(xe pool-param-get uuid=$pool param-name=migration-compression)
    printf '  %-22s %s\n' "live patching disabled" "$live_patching"
    printf '  %-22s %s\n' "IGMP snooping" "$igmp"
    printf '  %-22s %s\n' "migration compression" "$migration_compression"

    # Live patching applies host updates without a reboot; disabling it forces the reboot.
    xe pool-param-set uuid=$pool live-patching-disabled=$(negate "$live_patching")
    # IGMP snooping keeps multicast off ports that did not ask for it.
    xe pool-param-set uuid=$pool igmp-snooping-enabled=$(negate "$igmp")
    # Compression trades CPU for bandwidth when a VM's memory is moved between hosts.
    xe pool-param-set uuid=$pool migration-compression=$(negate "$migration_compression")

    echo "after changing:"
    printf '  %-22s %s\n' "live patching disabled" "$(xe pool-param-get uuid=$pool param-name=live-patching-disabled)"
    printf '  %-22s %s\n' "IGMP snooping" "$(xe pool-param-get uuid=$pool param-name=igmp-snooping-enabled)"
    printf '  %-22s %s\n' "migration compression" "$(xe pool-param-get uuid=$pool param-name=migration-compression)"

    xe pool-param-set uuid=$pool live-patching-disabled=$live_patching
    xe pool-param-set uuid=$pool igmp-snooping-enabled=$igmp
    xe pool-param-set uuid=$pool migration-compression=$migration_compression
    echo "  restored"
    echo "OK: configure-pool-options"
}

# --- Configure console access ---
w_configure_console_access() {
    # NOT `host`: that is the script-level variable the xe() wrapper passes to -s.
    pool=$(first_csv "$(xe pool-list --minimal)")
    host_uuid=$(xe pool-param-get uuid=$pool param-name=master)

    # NB: https-only and the pool console-idle-timeout are set but never read back. The generated SDK
    # bindings have a setter and no getter for both, so the other languages cannot show them - and these
    # samples are meant to read the same across all seven.
    printf '  %-26s %ss\n' "VM console idle timeout" "$(xe pool-param-get uuid=$pool param-name=vm-console-idle-timeout)"
    printf '  %-26s %s\n' "limit console sessions" "$(xe pool-param-get uuid=$pool param-name=limit-console-sessions)"
    printf '  %-26s %ss\n' "host console idle timeout" "$(xe host-param-get uuid=$host_uuid param-name=console-idle-timeout)"

    # Ten minutes of inactivity, one console session at a time, and no plain HTTP.
    xe pool-param-set uuid=$pool console-idle-timeout=600
    xe pool-param-set uuid=$pool vm-console-idle-timeout=600
    xe pool-param-set uuid=$pool limit-console-sessions=true
    xe host-param-set uuid=$host_uuid console-idle-timeout=300
    xe pool-param-set uuid=$pool https-only=true

    echo "after tightening:"
    printf '  %-26s %ss\n' "VM console idle timeout" "$(xe pool-param-get uuid=$pool param-name=vm-console-idle-timeout)"
    printf '  %-26s %s\n' "limit console sessions" "$(xe pool-param-get uuid=$pool param-name=limit-console-sessions)"
    printf '  %-26s %ss\n' "host console idle timeout" "$(xe host-param-get uuid=$host_uuid param-name=console-idle-timeout)"

    xe pool-param-set uuid=$pool https-only=false
    xe pool-param-set uuid=$pool console-idle-timeout=0
    xe pool-param-set uuid=$pool vm-console-idle-timeout=0
    xe pool-param-set uuid=$pool limit-console-sessions=false
    xe host-param-set uuid=$host_uuid console-idle-timeout=0
    echo "  restored"
    echo "OK: configure-console-access"
}

# --- Configure host storage ---
w_configure_host_storage() {
    pool=$(first_csv "$(xe pool-list --minimal)")
    host_uuid=$(xe pool-param-get uuid=$pool param-name=master)
    hname=$(xe host-param-get uuid=$host_uuid param-name=name-label)

    before_iqn=$(xe host-param-get uuid=$host_uuid param-name=iscsi_iqn)
    before_multipathing=$(xe host-param-get uuid=$host_uuid param-name=multipathing)
    echo "$hname: iSCSI IQN '$before_iqn', multipathing $before_multipathing"

    xe host-param-set uuid=$host_uuid iscsi_iqn="iqn.2026-01.com.example:$hname"
    xe host-param-set uuid=$host_uuid multipathing=true
    echo "  IQN now:      $(xe host-param-get uuid=$host_uuid param-name=iscsi_iqn)"
    echo "  multipathing: $(xe host-param-get uuid=$host_uuid param-name=multipathing)"

    # host-param-set refuses an empty iscsi_iqn (INVALID_VALUE) - only restore it if this host actually had
    # one set before; a host that never had an IQN configured can't be "restored" to empty.
    [ -n "$before_iqn" ] && xe host-param-set uuid=$host_uuid iscsi_iqn="$before_iqn"
    xe host-param-set uuid=$host_uuid multipathing=$before_multipathing
    echo "  restored"
    echo "OK: configure-host-storage"
}

# --- Configure remote syslog ---
w_configure_syslog() {
    pool=$(first_csv "$(xe pool-list --minimal)")
    host_uuid=$(xe pool-param-get uuid=$pool param-name=master)
    syslog_server=192.0.2.50

    logging=$(xe host-param-get uuid=$host_uuid param-name=logging)
    echo "$(xe host-param-get uuid=$host_uuid param-name=name-label) logging: ${logging:-(local only)}"

    # Two steps, and the second is the one that is easy to miss: setting the destination only
    # records it, and the host keeps logging locally until the syslog daemon is reconfigured to
    # pick the setting up. (Removing a key that is not there is an error, hence the || true.)
    xe host-param-remove uuid=$host_uuid param-name=logging param-key=syslog_destination >/dev/null 2>&1 || true
    xe host-param-set uuid=$host_uuid logging:syslog_destination=$syslog_server
    xe host-syslog-reconfigure host-uuid=$host_uuid
    echo "  now logging to: $(xe host-param-get uuid=$host_uuid param-name=logging param-key=syslog_destination)"

    xe host-param-remove uuid=$host_uuid param-name=logging param-key=syslog_destination
    xe host-syslog-reconfigure host-uuid=$host_uuid
    logging=$(xe host-param-get uuid=$host_uuid param-name=logging)
    echo "  restored: ${logging:-(local only)}"
    echo "OK: configure-syslog"
}

# --- Manage driver variants ---
w_manage_driver_variants() {
    pool=$(first_csv "$(xe pool-list --minimal)")
    host_uuid=$(xe pool-param-get uuid=$pool param-name=master)
    hname=$(xe host-param-get uuid=$host_uuid param-name=name-label)

    drivers=$(xe hostdriver-list host-uuid=$host_uuid --minimal)
    echo "$hname has $(count_csv "$drivers") driver(s)"

    # Sort by name (one xe call per driver to read it, same as the pairs read below) so the printed
    # order and the selection below agree.
    sorted_drivers=$( (for d in $(each_csv "$drivers"); do
        printf '%s\t%s\n' "$(xe hostdriver-param-get uuid=$d param-name=name)" "$d"
    done) | sort | cut -f2)

    # hostdriver-param-get has no "variants-uuid" field (only "variants", a printable name/version
    # summary) - the actual Driver_variant records behind it are found the normal CLI way, with the
    # generic hostdriver-variant-list filtered on driver-uuid=.
    n=0
    for d in $sorted_drivers; do
        n=$((n + 1)); [ "$n" -gt 3 ] && break
        dname=$(xe hostdriver-param-get uuid=$d param-name=name)
        dtype=$(xe hostdriver-param-get uuid=$d param-name=type)
        nvariants=$(count_csv "$(xe hostdriver-variant-list driver-uuid=$d --minimal)")
        active=$(xe hostdriver-param-get uuid=$d param-name=active-variant)
        printf '  %-14s %-10s %d variant(s), active=%s\n' "$dname" "$dtype" "$nvariants" "${active:-(none)}"
    done

    # Select a variant explicitly. It becomes the selected one immediately; whether it is also active
    # depends on whether the hardware is present and the driver already loaded. hostdriver-select on a
    # no-hardware variant raises HOST_DRIVER_NO_HARDWARE - and a host lists drivers for plenty of devices
    # it doesn't have - so pick a driver for hardware this host actually has, and one of its variants
    # that is usable (field "hw-present", not "hardware-present"): the first (driver, variant) pair,
    # across all drivers sorted by name, whose variant reports present.
    driver="" variant=""
    for d in $sorted_drivers; do
        for v in $(each_csv "$(xe hostdriver-variant-list driver-uuid=$d --minimal)"); do
            if [ "$(xe hostdriver-variant-param-get uuid=$v param-name=hw-present)" = "true" ]; then
                driver=$d; variant=$v; break 2
            fi
        done
    done
    if [ -z "$driver" ]; then
        echo "no driver on $hname has a variant for hardware it has" >&2
        return 1
    fi
    dname=$(xe hostdriver-param-get uuid=$driver param-name=name)
    variant_name=$(xe hostdriver-variant-param-get uuid=$variant param-name=name)
    xe hostdriver-select uuid=$driver variant-name="$variant_name"
    selected=$(xe hostdriver-param-get uuid=$driver param-name=selected-variant)
    active=$(xe hostdriver-param-get uuid=$driver param-name=active-variant)
    echo "  $dname: selected ${selected:-(none)}, active ${active:-(none)}"
    echo "OK: manage-driver-variants"
}

# --- end of workflows ---

case "$workflow" in
    connect-inventory)    w_connect_inventory ;;
    create-vm)            w_create_vm ;;
    vm-lifecycle)         w_vm_lifecycle ;;
    manage-vm-disks)      w_manage_vm_disks ;;
    dismiss-alerts)       w_dismiss_alerts ;;
    host-power-on)        w_host_power_on ;;
    rotate-pool-secret)   w_rotate_pool_secret ;;
    change-root-password) w_change_root_password ;;
    manage-certificates)  w_manage_certificates ;;
    snapshot-schedule)    w_snapshot_schedule ;;
    manage-vm-groups)     w_manage_vm_groups ;;
    snapshot-revert)      w_snapshot_revert ;;
    create-nfs-sr)        w_create_nfs_sr ;;
    create-network)       w_create_network ;;
    edit-vm-properties)   w_edit_vm_properties ;;
    events)               w_events ;;
    new-vm-wizard)        w_new_vm_wizard ;;
    live-migrate)         w_live_migrate ;;
    host-maintenance)     w_host_maintenance ;;
    configure-ha)         w_configure_ha ;;
    copy-vm)              w_copy_vm ;;
    create-vm-with-vgpu)  w_create_vm_with_vgpu ;;
    tags-and-folders)     w_tags_and_folders ;;
    configure-updates)    w_configure_updates ;;
    clone-vm)             w_clone_vm ;;
    delete-vm)            w_delete_vm ;;
    storage-migrate)      w_storage_migrate ;;
    apply-update)         w_apply_update ;;
    checkpoint-vm)        w_checkpoint_vm ;;
    attach-disk)          w_attach_disk ;;
    wait-for-task)        w_wait_for_task ;;
    error-handling)       w_error_handling ;;
    list-templates)       w_list_templates ;;
    custom-fields)        w_custom_fields ;;
    gpu-inventory)        w_gpu_inventory ;;
    read-metrics)         w_read_metrics ;;
    rename-object)        w_rename_object ;;
    vm-boot-config)       w_vm_boot_config ;;
    host-info)            w_host_info ;;
    list-roles)           w_list_roles ;;
    pool-properties)      w_pool_properties ;;
    sr-usage)             w_sr_usage ;;
    manage-vif)           w_manage_vif ;;
    list-networks)        w_list_networks ;;
    vbd-inventory)        w_vbd_inventory ;;
    pool-tags)            w_pool_tags ;;
    convert-to-template)  w_convert_to_template ;;
    find-by-uuid)         w_find_by_uuid ;;
    rolling-pool-update)  w_rolling_pool_update ;;
    cross-pool-copy-vm)   w_cross_pool_copy_vm ;;
    pvs-accelerator)      w_pvs_accelerator ;;
    configure-pvs-accelerator) w_configure_pvs_accelerator ;;
    manage-ssh-access)    w_manage_ssh_access ;;
    manage-vtpm)          w_manage_vtpm ;;
    export-import-vm)     w_export_import_vm ;;
    configure-dynamic-memory) w_configure_dynamic_memory ;;
    manage-vm-media)      w_manage_vm_media ;;
    backup-host-config)   w_backup_host_config ;;
    manage-sr-lifecycle)  w_manage_sr_lifecycle ;;
    set-default-sr)       w_set_default_sr ;;
    server-status-report) w_server_status_report ;;
    disaster-recovery)    w_disaster_recovery ;;
    manage-secureboot-certificates) w_manage_secureboot_certificates ;;
    restart-host)         w_restart_host ;;
    manage-crash-dumps)   w_manage_crash_dumps ;;
    vm-from-snapshot)     w_vm_from_snapshot ;;
    attach-existing-disk) w_attach_existing_disk ;;
    changed-block-tracking) w_changed_block_tracking ;;
    control-domain-memory) w_control_domain_memory ;;
    rrd-metrics)          w_rrd_metrics ;;
    reclaim-space)        w_reclaim_space ;;
    vm-ip-address)        w_vm_ip_address ;;
    manage-ad-users)      w_manage_ad_users ;;
    create-iscsi-sr)      w_create_iscsi_sr ;;
    create-smb-sr)        w_create_smb_sr ;;
    create-hba-sr)        w_create_hba_sr ;;
    create-iso-sr)        w_create_iso_sr ;;
    configure-nrpe)       w_configure_nrpe ;;
    configure-snmp)       w_configure_snmp ;;
    configure-clustering) w_configure_clustering ;;
    manage-pool-membership) w_manage_pool_membership ;;
    create-bond) w_create_bond ;;
    manage-vapp)          w_manage_vapp ;;
    attach-usb-device)    w_attach_usb_device ;;
    wlb-recommendations)  w_wlb_recommendations ;;
    configure-pool-options)    w_configure_pool_options ;;
    configure-console-access)  w_configure_console_access ;;
    configure-host-storage)    w_configure_host_storage ;;
    configure-syslog)          w_configure_syslog ;;
    manage-driver-variants)    w_manage_driver_variants ;;
    *) echo "unknown workflow: $workflow" >&2; exit 2 ;;
esac
