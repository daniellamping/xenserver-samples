#!/usr/bin/env bash
# XenServer CLI (xe) - real-world workflow examples.
#
# Each example performs a common pool-management task entirely through the `xe` command line interface.
# `xe` runs the command server-side over XAPI's thin-CLI protocol, so these are exactly the commands you
# would type against a real host. Objects are addressed by UUID (captured with `--minimal`), and commands
# take `name=value` arguments (with `device-config:key=value` for nested maps).
#
# Usage:
#   ./workflows.sh <workflow> <url> <username> <password>
#     <workflow>  connect-inventory | create-vm | vm-lifecycle | ... (see the dispatcher for the full list)
#     <url>       e.g. https://xenserver  (see the note on ports below)
set -e

# Under Git Bash/MSYS, an argument that looks like a Unix path (e.g. serverpath=/export/vol1) gets
# rewritten to a Windows path before xe sees it. These are all *remote* paths (NFS exports, folders),
# never local files, so disable that conversion for the whole script.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

workflow="$1"; url="$2"; user="$3"; pass="$4"; desturl="$5"   # desturl: only cross-pool-copy-vm uses it
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
xe() { "${XE_EXE:-xe}" -s "$host" "${xe_opts[@]}" -u "$user" -pw "$pass" "$@"; }

# A pool member refuses every command with HOST_IS_SLAVE, naming the coordinator's address; send
# everything there instead (assuming the coordinator is up), as XenCenter does when you add a member server.
_probe=$(xe pool-list --minimal 2>&1) || true
if [[ $_probe =~ (Master|Coordinator)\ IP\ address:\ ([0-9A-Fa-f.:]+) ]]; then host=${BASH_REMATCH[2]}; fi

# Bash helpers for `--minimal` (comma-separated) output, so no cut/tr/wc/grep processes are spawned:
first_csv()  { echo "${1%%,*}"; }                       # first element of a comma-separated list
count_csv()  { local IFS=,; set -- $1; echo $#; }       # number of elements (0 for empty)
each_csv()   { local IFS=,; set -- $1; printf '%s\n' "$@"; }   # one element per line, for `for`
nth_csv()    { local n=$2 IFS=,; set -- $1; shift $((n - 1)); echo "$1"; }  # Nth element, 1-based

shared_sr() { first_csv "$(xe sr-list name-label="Shared NFS" --minimal)"; }
first_host() { first_csv "$(xe host-list --minimal)"; }
vm_uuid()  { first_csv "$(xe vm-list name-label="$1" --minimal)"; }

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
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-vm)
    echo "Created VM: $vm"
    echo "is-a-template = $(xe vm-param-get uuid=$vm param-name=is-a-template)"
    echo "OK: create-vm"
}

# --- 3. VM power lifecycle ---
w_vm_lifecycle() {
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-lifecycle)
    echo "Initial: $(xe vm-param-get uuid=$vm param-name=power-state)"
    xe vm-start uuid=$vm;   echo "After start:    $(xe vm-param-get uuid=$vm param-name=power-state)"
    # The emulated hardware can be restarted under a running guest without rebooting it.
    xe vm-restart-device-models uuid=$vm
    echo "Device models restarted; still $(xe vm-param-get uuid=$vm param-name=power-state)"
    xe vm-suspend uuid=$vm; echo "After suspend:  $(xe vm-param-get uuid=$vm param-name=power-state)"
    xe vm-resume uuid=$vm;  echo "After resume:   $(xe vm-param-get uuid=$vm param-name=power-state)"
    xe vm-shutdown uuid=$vm; echo "After shutdown: $(xe vm-param-get uuid=$vm param-name=power-state)"
    echo "OK: vm-lifecycle"
}

# --- 4. Manage VM disks: Deactivate / Resize / Activate -------------------------------
w_manage_vm_disks() {
    vm=$(vm_uuid web-01)
    # Walk the VM's VBDs rather than filtering vbd-list: the generic list does not filter on ref-typed
    # fields, and a CD drive is a VBD too, hence the type check. Same idiom as w_attach_disk.
    vbd=""
    vbds=$(xe vm-param-get uuid=$vm param-name=VBDs)
    for b in ${vbds//,/ }; do
        if [ "$(xe vbd-param-get uuid=$b param-name=type)" = "Disk" ]; then vbd=$b; break; fi
    done
    vdi=$(xe vbd-param-get uuid=$vbd param-name=VDI)
    echo "Disk attached:  $(xe vbd-param-get uuid=$vbd param-name=currently-attached)"

    # Deactivate: the disk stays with the VM, it is just no longer live.
    xe vbd-unplug uuid=$vbd
    echo "After unplug:   $(xe vbd-param-get uuid=$vbd param-name=currently-attached)"

    size=$(xe vdi-param-get uuid=$vdi param-name=virtual-size)
    xe vdi-resize uuid=$vdi disk-size=$((size * 2))
    echo "Resized:        $size -> $(xe vdi-param-get uuid=$vdi param-name=virtual-size) bytes"

    xe vbd-plug uuid=$vbd
    echo "After plug:     $(xe vbd-param-get uuid=$vbd param-name=currently-attached)"

    # Growing a disk that is attached and live is a DIFFERENT call, not a flag on the same one:
    # online=true tells the storage layer the guest is using the disk while it grows.
    grown=$(( $(xe vdi-param-get uuid=$vdi param-name=virtual-size) + 1073741824 ))
    xe vdi-resize uuid=$vdi disk-size=$grown online=true
    echo "Grown online:   $(xe vdi-param-get uuid=$vdi param-name=virtual-size) bytes"
    echo "OK: manage-vm-disks"
}

# --- Raise and dismiss alerts ---------------------------------------------------------
w_dismiss_alerts() {
    echo "Alerts:         $(count_csv "$(xe message-list --minimal)")"
    msg=$(first_csv "$(xe message-list --minimal)")
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
    xe host-set-power-on-mode uuid=$h power-on-mode=iLO power-on-config=power_on_ip=192.0.2.9
    echo "Power-on mode:  $(xe host-param-get uuid=$h param-name=power-on-mode)"

    xe host-set-power-on-mode uuid=$h power-on-mode=
    echo "OK: host-power-on"
}

# --- Rotate the pool secret -----------------------------------------------------------
w_rotate_pool_secret() {
    echo "Pool:           $(xe pool-list params=name-label --minimal)"
    # A pool-wide operation; existing sessions survive it.
    xe pool-rotate-secret
    echo "Rotated. Still connected: $(count_csv "$(xe pool-list --minimal)")"
    echo "OK: rotate-pool-secret"
}

# --- Change the root password ---------------------------------------------------------
w_change_root_password() {
    # xe exposes this as user-password-change. It takes the OLD password as well as the new one, even
    # though you are already authenticated.
    xe user-password-change old="$pass" new=xe-example-temp-password
    echo "Password changed."

    # The existing session stays valid; only new connections need the new password.
    echo "Session still usable: $(count_csv "$(xe pool-list --minimal)")"

    xe user-password-change old=xe-example-temp-password new="$pass"
    echo "Password restored."
    echo "OK: change-root-password"
}

# --- Manage TLS certificates ----------------------------------------------------------
w_manage_certificates() {
    h=$(first_host)
    echo "Certificates:   $(count_csv "$(xe certificate-list --minimal)")"

    # A CA certificate is pool-wide; a server certificate belongs to one host.
    xe pool-install-ca-certificate name=xe-example-ca
    echo "After CA add:   $(count_csv "$(xe certificate-list --minimal)")"

    xe host-reset-server-certificate uuid=$h
    echo "Host certificate reset (a fresh self-signed identity)."

    xe pool-uninstall-ca-certificate name=xe-example-ca
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
    echo "Members:          $(count_csv "$(xe vmss-param-get uuid=$vmss param-name=VMs)")"

    # Run it three times against a retention of two: the oldest is pruned away.
    xe vmss-snapshot-now uuid=$vmss > /dev/null
    xe vmss-snapshot-now uuid=$vmss > /dev/null
    xe vmss-snapshot-now uuid=$vmss > /dev/null
    echo "Snapshots kept:   $(count_csv "$(xe vm-param-get uuid=$vm param-name=snapshots)") (retention 2)"

    xe vmss-destroy uuid=$vmss
    echo "OK: snapshot-schedule"
}

# --- Manage VM groups -----------------------------------------------------------------
w_manage_vm_groups() {
    vm=$(vm_uuid web-01)
    # anti_affinity asks the pool to keep the group's members on different hosts.
    group=$(xe vm-group-create name-label=xe-example-group placement=anti_affinity)
    echo "Created group:  $group"

    # Membership is written from the VM side, and read back from the group side.
    xe vm-param-set uuid=$vm groups=$group
    echo "Group members:  $(count_csv "$(xe vm-group-param-get uuid=$group param-name=VMs)")"

    xe vm-param-set uuid=$vm groups=
    echo "After removal:  $(count_csv "$(xe vm-group-param-get uuid=$group param-name=VMs)")"

    xe vm-group-destroy uuid=$group
    echo "OK: manage-vm-groups"
}

# --- Snapshot & revert ----------------------------------------------------------------
w_snapshot_revert() {
    vm=$(vm_uuid web-01)
    snap=$(xe vm-snapshot uuid=$vm new-name-label=xe-example-snapshot)
    echo "Created snapshot: $snap"
    xe snapshot-revert snapshot-uuid=$snap
    echo "Reverted to the snapshot."
    # The other languages fetch the snapshot's console thumbnail from GET /vncsnapshot here. `xe` has no
    # command for a plain HTTP transfer that is not vm-export/host-backup, so there is nothing honest to
    # write - the thumbnail is a client-side fetch, not a CLI operation.
    echo "OK: snapshot-revert"
}

# --- 5. Create an NFS storage repository ---
w_create_nfs_sr() {
    sr=$(xe sr-create host-uuid=$(first_host) type=nfs name-label=xe-example-nfs \
        device-config:server=192.0.2.10 device-config:serverpath=/export/sdk device-config:nfsversion=3 shared=true)
    echo "Created SR: $sr"
    xe sr-forget uuid=$sr
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
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-wizard-vm)
    xe vm-param-set uuid=$vm VCPUs-max=2 VCPUs-at-startup=2
    xe vm-memory-limits-set uuid=$vm static-min=512MiB static-max=2GiB dynamic-min=2GiB dynamic-max=2GiB
    vdi=$(xe vdi-create sr-uuid=$(shared_sr) name-label="xe-wizard disk" virtual-size=24GiB type=user)
    xe vbd-create vm-uuid=$vm vdi-uuid=$vdi device=1 type=Disk mode=RW >/dev/null
    xe vif-create vm-uuid=$vm network-uuid=$(first_csv "$(xe network-list --minimal)") device=0 >/dev/null
    xe vm-start uuid=$vm
    echo "power-state: $(xe vm-param-get uuid=$vm param-name=power-state)"
    echo "vCPUs:       $(xe vm-param-get uuid=$vm param-name=VCPUs-max)"
    echo "OK: new-vm-wizard"
}

# --- 10. Live migrate a VM ---
w_live_migrate() {
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-migrate)
    xe vm-start uuid=$vm
    source=$(xe vm-param-get uuid=$vm param-name=resident-on)
    echo "Running on: $(xe host-param-get uuid=$source param-name=name-label)"
    hosts=$(xe host-list --minimal); dest=""
    for h in ${hosts//,/ }; do [ "$h" != "$source" ] && { dest=$h; break; }; done
    xe vm-migrate uuid=$vm host-uuid=$dest live=true
    now=$(xe vm-param-get uuid=$vm param-name=resident-on)
    echo "Migrated to: $(xe host-param-get uuid=$now param-name=name-label)"
    echo "OK: live-migrate"
}

# --- 11. Enter & exit maintenance mode ---
w_host_maintenance() {
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-maint)
    xe vm-start uuid=$vm
    h=$(xe vm-param-get uuid=$vm param-name=resident-on)
    echo "Maintenance host: $(xe host-param-get uuid=$h param-name=name-label)"
    xe host-disable uuid=$h;  echo "After disable:  enabled=$(xe host-param-get uuid=$h param-name=enabled)"
    xe host-evacuate uuid=$h; echo "After evacuate: guest now on $(xe host-param-get uuid=$(xe vm-param-get uuid=$vm param-name=resident-on) param-name=name-label)"
    xe host-enable uuid=$h;   echo "After enable:   enabled=$(xe host-param-get uuid=$h param-name=enabled)"
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
    copy=$(xe vm-copy uuid=$(vm_uuid db-01) new-name-label=xe-example-copy sr-uuid=$(shared_sr))
    echo "Copied VM: $copy"
    echo "OK: copy-vm"
}

# --- 14. Create a VM with a vGPU ---
w_create_vm_with_vgpu() {
    group=$(first_csv "$(xe gpu-group-list --minimal)")
    type=""
    vtypes=$(xe gpu-group-param-get uuid=$group param-name=supported-VGPU-types --minimal)
    for t in ${vtypes//,/ }; do
        if [ "$(xe vgpu-type-param-get uuid=$t param-name=model-name)" != "passthrough" ]; then type=$t; break; fi
    done
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-vgpu)
    vgpu=$(xe vgpu-create vm-uuid=$vm gpu-group-uuid=$group vgpu-type-uuid=$type)
    echo "Created vGPU: $vgpu of type $(xe vgpu-type-param-get uuid=$type param-name=model-name)"
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
    echo "OK: tags-and-folders"
}

# --- 16. Configure updates (CDN) ---
w_configure_updates() {
    pool=$(xe pool-list --minimal)
    repo=$(xe repository-introduce name-label=xe-cdn binary-url=https://cdn.example/base source-url=https://cdn.example/source)
    echo "Introduced repository: $(xe repository-param-get uuid=$repo param-name=name-label)"
    xe pool-param-set uuid=$pool update-sync-enabled=true
    echo "Auto-sync enabled: $(xe pool-param-get uuid=$pool param-name=update-sync-enabled)"
    xe pool-param-set uuid=$pool update-sync-enabled=false
    xe repository-forget uuid=$repo
    echo "OK: configure-updates"
}

# --- 17. Clone a VM ---
w_clone_vm() {
    clone=$(xe vm-clone uuid=$(vm_uuid db-01) new-name-label=xe-example-clone)
    echo "Cloned VM: $clone"
    echo "OK: clone-vm"
}

# --- 18. Delete a VM ---
w_delete_vm() {
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-delete)
    xe vm-destroy uuid=$vm
    echo "VM still present: $([ -z "$(xe vm-list uuid=$vm --minimal)" ] && echo false || echo true)"
    echo "OK: delete-vm"
}

# --- 19. Storage live-migration (move a disk to another SR) ---
w_storage_migrate() {
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-storagemigrate)
    vdi=""; vbds=$(xe vm-param-get uuid=$vm param-name=VBDs --minimal)
    for vbd in ${vbds//,/ }; do
        if [ "$(xe vbd-param-get uuid=$vbd param-name=type)" = "Disk" ]; then vdi=$(xe vbd-param-get uuid=$vbd param-name=VDI); break; fi
    done
    source=$(xe vdi-param-get uuid=$vdi param-name=SR)
    echo "Disk is on SR: $(xe sr-param-get uuid=$source param-name=name-label)"
    srs=$(xe sr-list type=lvm --minimal); dest=""
    for s in ${srs//,/ }; do [ "$s" != "$source" ] && { dest=$s; break; }; done
    xe vdi-pool-migrate uuid=$vdi sr-uuid=$dest
    echo "Disk moved to: $(xe sr-param-get uuid=$(xe vdi-param-get uuid=$vdi param-name=SR) param-name=name-label)"
    echo "OK: storage-migrate"
}

# --- 20. Apply updates from the CDN ---
w_apply_update() {
    hash=$(xe pool-sync-updates)
    echo "Synced updates (hash length ${#hash})"
    hosts=$(xe host-list --minimal)
    for h in ${hosts//,/ }; do
        xe host-apply-updates uuid=$h hash=$hash
        echo "  $(xe host-param-get uuid=$h param-name=name-label): pending guidance = $(xe host-param-get uuid=$h param-name=pending-guidances)"
    done
    echo "OK: apply-update"
}

# --- 21. Checkpoint & revert ---
w_checkpoint_vm() {
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-checkpoint)
    xe vm-start uuid=$vm
    cp=$(xe vm-checkpoint uuid=$vm new-name-label=xe-example-checkpoint-1)
    echo "Created checkpoint: $cp"
    xe snapshot-revert snapshot-uuid=$cp
    echo "Reverted to the checkpoint."
    echo "OK: checkpoint-vm"
}

# --- 22. Attach a new disk to a VM ---
w_attach_disk() {
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-attachdisk)
    vdi=$(xe vdi-create sr-uuid=$(shared_sr) name-label=xe-example-data-disk virtual-size=8GiB type=user)
    xe vbd-create vm-uuid=$vm vdi-uuid=$vdi device=1 type=Disk mode=RW >/dev/null
    echo "Attached an 8 GiB disk; VM now has $(count_csv "$(xe vm-param-get uuid=$vm param-name=VBDs --minimal)") VBD(s)"
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
        vtypes=$(xe gpu-group-param-get uuid=$g param-name=supported-VGPU-types --minimal)
        models=""
        for t in ${vtypes//,/ }; do models="$models $(xe vgpu-type-param-get uuid=$t param-name=model-name)"; done
        echo "  - $(xe gpu-group-param-get uuid=$g param-name=name-label): vGPU types:$models"
    done

    # How the pool spreads vGPUs across the physical GPUs in a group: depth-first packs each pGPU
    # full before using the next, breadth-first spreads them out.
    group=$(first_csv "$groups")
    before=$(xe gpu-group-param-get uuid=$group param-name=allocation-algorithm)
    xe gpu-group-param-set uuid=$group allocation-algorithm=breadth_first
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
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-boot)
    xe vm-param-set uuid=$vm VCPUs-max=4 VCPUs-at-startup=2
    # Boot mode: firmware ("bios"/"uefi") lives in HVM-boot-params; Secure Boot in platform:secureboot.
    # Switch to UEFI Secure Boot (as the New VM wizard does for a UEFI-capable template).
    xe vm-param-set uuid=$vm HVM-boot-params:order=cdn HVM-boot-params:firmware=uefi
    xe vm-param-set uuid=$vm platform:secureboot=true
    echo "vCPUs: $(xe vm-param-get uuid=$vm param-name=VCPUs-at-startup)/$(xe vm-param-get uuid=$vm param-name=VCPUs-max)"
    echo "Boot order: $(xe vm-param-get uuid=$vm param-name=HVM-boot-params param-key=order)"
    echo "Boot mode: firmware=$(xe vm-param-get uuid=$vm param-name=HVM-boot-params param-key=firmware), secureboot=$(xe vm-param-get uuid=$vm param-name=platform param-key=secureboot)"
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
    echo "Roles: $(xe role-list params=name-label --minimal)"
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
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-vif)
    net=$(first_csv "$(xe network-list --minimal)")
    vif=$(xe vif-create vm-uuid=$vm network-uuid=$net device=0)
    echo "Attached a VIF; VM now has $(count_csv "$(xe vm-param-get uuid=$vm param-name=VIFs --minimal)") NIC(s)"
    xe vif-destroy uuid=$vif
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
    vbds=$(xe vm-param-get uuid=$vm param-name=VBDs --minimal)
    for vbd in ${vbds//,/ }; do
        if [ "$(xe vbd-param-get uuid=$vbd param-name=type)" = "Disk" ]; then
            vdi=$(xe vbd-param-get uuid=$vbd param-name=VDI)
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
    vm=$(xe vm-install template="Rocky Linux 8" new-name-label=xe-example-totemplate)
    echo "is-a-template after install: $(xe vm-param-get uuid=$vm param-name=is-a-template)"
    xe vm-param-set uuid=$vm is-a-template=true   # one-way operation
    echo "is-a-template after convert: $(xe vm-param-get uuid=$vm param-name=is-a-template)"
    echo "OK: convert-to-template"
}

# --- 40. Look up an object by UUID ---
w_find_by_uuid() {
    vm=$(vm_uuid web-01)
    echo "UUID $vm resolves to $(xe vm-param-get uuid=$vm param-name=name-label)"
    echo "OK: find-by-uuid"
}

# --- Rolling pool update --------------------------------------------------------------
w_rolling_pool_update() {
    hash=$(xe pool-sync-updates)
    echo "Synced updates (hash length ${#hash})"
    # Rolling: disable -> evacuate -> apply -> reboot -> re-enable, one host at a time.
    hosts=$(xe host-list --minimal)
    for h in ${hosts//,/ }; do
        echo "Updating $(xe host-param-get uuid=$h param-name=name-label):"
        xe host-disable uuid=$h
        xe host-evacuate uuid=$h
        xe host-apply-updates uuid=$h hash=$hash
        echo "  applied; pending guidance = $(xe host-param-get uuid=$h param-name=pending-guidances)"
        xe host-reboot uuid=$h
        xe host-enable uuid=$h
    done
    echo "OK: rolling-pool-update"
}

# --- Cross-pool copy a VM -------------------------------------------------------------
w_cross_pool_copy_vm() {
    # Copy a VM to another pool (Storage XenMotion copy). Real xe does the whole cross-pool dance
    # itself given the destination master's address + credentials; copy=true leaves the source intact.
    dest_host=${desturl#*://}; dest_host=${dest_host%%/*}; dest_host=${dest_host%%:*}
    vm=$(vm_uuid db-01)
    xe vm-migrate uuid=$vm remote-master=$dest_host remote-username=$user remote-password=$pass copy=true
    still=$([ -n "$(vm_uuid db-01)" ] && echo True || echo False)
    echo "Sent 'db-01' to $dest_host (copy); source still present: $still"
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
            h=$(xe pvs-cache-storage-param-get uuid=$cs param-name=host)
            sr=$(xe pvs-cache-storage-param-get uuid=$cs param-name=SR)
            size=$(xe pvs-cache-storage-param-get uuid=$cs param-name=size)
            echo "  cache:  $(xe host-param-get uuid=$h param-name=name-label)  $((size / 1024 / 1024 / 1024)) GiB on $(xe sr-param-get uuid=$sr param-name=name-label)"
        done
        srvlist=$(xe pvs-server-list --minimal)
        for srv in ${srvlist//,/ }; do
            echo "  server: $(xe pvs-server-param-get uuid=$srv param-name=addresses)  ports $(xe pvs-server-param-get uuid=$srv param-name=first-port)-$(xe pvs-server-param-get uuid=$srv param-name=last-port)"
        done
        # One proxy accelerates one VM in this pool, so proxy count = accelerated VM count.
        accelerated=$(count_csv "$(xe pvs-proxy-list --minimal)")
        total=$(count_csv "$(xe vm-list --minimal)")
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
    pbd=$(first_csv "$(xe sr-param-get uuid=$sr param-name=PBDs)")
    h=$(xe pbd-param-get uuid=$pbd param-name=host)
    result=$(xe host-call-plugin host-uuid=$h plugin=trim fn=do_trim args:sr_uuid=$sr)
    echo "  reclaimed freed space on $sr: $result"
    [ "$result" = "true" ] || { echo "trim failed: $result" >&2; exit 1; }
    echo "OK: reclaim-space"
}

# --- 46. Get a VM's IP address ---
w_vm_ip_address() {
    # A running guest reports its IP in vm-guest-metrics networks, keyed "<vif device>/ip". Pick a running
    # guest that actually has guest-metrics (skips freshly-created VMs left running by earlier workflows).
    vm=""; gm=""
    local IFS=,
    for u in $(xe vm-list power-state=running is-control-domain=false params=uuid --minimal); do
        g=$(xe vm-param-get uuid=$u param-name=guest-metrics)
        case "$g" in ""|"<not in database>"|"OpaqueRef:NULL") continue;; esac
        vm=$u; gm=$g; break
    done
    ip=$(xe vm-guest-metrics-param-get uuid=$gm param-name=networks param-key=0/ip)
    [ -n "$ip" ] || ip="(no address reported)"
    echo "  $(xe vm-param-get uuid=$vm param-name=name-label): $ip"
    echo "OK: vm-ip-address"
}

# --- 47. Manage Active Directory users ---
w_manage_ad_users() {
    pool=$(xe pool-list --minimal)
    xe pool-enable-external-auth uuid=$pool auth-type=AD service-name=citrix.local \
        config:user=administrator config:pass=secret config:ldaps=false
    echo "Joined domain: citrix.local"
    subj=$(xe subject-add subject-name=alice@citrix.local)
    xe subject-role-add uuid=$subj role-name=pool-admin
    name=$(xe subject-param-get uuid=$subj param-name=other-config param-key=subject-displayname)
    echo "Added subject $name with role pool-admin"

    # Revoking access does not end sessions the user already has: logging the subject out is a
    # separate act, and the one that actually gets them off the pool now rather than at next login.
    sid=$(xe subject-param-get uuid=$subj param-name=subject-identifier)
    xe session-subject-identifier-logout subject-identifier=$sid
    echo "  logged out $name"

    xe subject-remove uuid=$subj
    xe pool-disable-external-auth uuid=$pool
    echo "OK: manage-ad-users"
}

# --- 48. Create an iSCSI SR ---
w_create_iscsi_sr() {
    # Connect an SR to a LUN on the iSCSI target; sr-create validates + sizes it from the backend LUN.
    sr=$(xe sr-create host-uuid=$(first_host) type=lvmoiscsi name-label=xe-example-iscsi \
        device-config:target=192.0.2.30 device-config:targetIQN=iqn.2009-01.com.xenpretender:target-0 \
        device-config:SCSIid=360a980004265656d5f4a2d63764e5734 shared=true)
    echo "Created iSCSI SR: $sr ($(( $(xe sr-param-get uuid=$sr param-name=physical-size) / 1024 / 1024 / 1024 )) GiB)"
    xe sr-forget uuid=$sr
    echo "OK: create-iscsi-sr"
}

# --- 49. Create an SMB SR ---
w_create_smb_sr() {
    # Connect a shared SR to an SMB/CIFS file share; sr-create validates + sizes it from the share.
    sr=$(xe sr-create host-uuid=$(first_host) type=smb name-label=xe-example-smb \
        device-config:server=192.0.2.40 device-config:serverpath=/vmstore \
        device-config:username=Administrator device-config:password=Password1 shared=true)
    echo "Created SMB SR: $sr ($(( $(xe sr-param-get uuid=$sr param-name=physical-size) / 1024 / 1024 / 1024 )) GiB)"
    xe sr-forget uuid=$sr
    echo "OK: create-smb-sr"
}

# --- 50. Create an HBA SR ---
w_create_hba_sr() {
    # Connect a shared SR to a fibre-channel (HBA) LUN by its SCSI ID.
    sr=$(xe sr-create host-uuid=$(first_host) type=lvmohba name-label=xe-example-hba \
        device-config:SCSIid=360a980004265656d5f4a2d63764e5736 shared=true)
    echo "Created HBA SR: $sr ($(( $(xe sr-param-get uuid=$sr param-name=physical-size) / 1024 / 1024 / 1024 )) GiB)"
    xe sr-forget uuid=$sr
    echo "OK: create-hba-sr"
}

# --- 51. Create a GFS2 SR ---
w_create_gfs2_sr() {
    # Create a shared, thin-provisioned GFS2 SR on a block LUN (here an iSCSI LUN).
    sr=$(xe sr-create host-uuid=$(first_host) type=gfs2 name-label=xe-example-gfs2 \
        device-config:provider=iscsi device-config:target=192.0.2.30 \
        device-config:targetIQN=iqn.2009-01.com.xenpretender:target-0 \
        device-config:SCSIid=360a980004265656d5f4a2d63764e5735 shared=true)
    echo "Created GFS2 SR: $sr ($(( $(xe sr-param-get uuid=$sr param-name=physical-size) / 1024 / 1024 / 1024 )) GiB)"
    xe sr-forget uuid=$sr
    echo "OK: create-gfs2-sr"
}

# --- 52. Create an ISO library SR ---
w_create_iso_sr() {
    # Connect an ISO-library SR to a file share of ISO images (here an NFS export).
    sr=$(xe sr-create host-uuid=$(first_host) type=iso name-label=xe-example-iso content-type=iso \
        device-config:location=192.0.2.10:/isos device-config:type=nfs_iso shared=true)
    echo "Created ISO SR: $sr"
    xe sr-forget uuid=$sr
    echo "OK: create-iso-sr"
}

# --- 53. Configure NRPE monitoring ---
w_configure_nrpe() {
    h=$(first_host)
    # Enable the NRPE agent and allow a monitoring host, through the nrpe plugin.
    echo "NRPE status before: $(xe host-call-plugin host-uuid=$h plugin=nrpe fn=status)"
    xe host-call-plugin host-uuid=$h plugin=nrpe fn=enable >/dev/null
    xe host-call-plugin host-uuid=$h plugin=nrpe fn=set-config \
        args:allowed_hosts=127.0.0.1,::1,10.0.0.5 args:debug=0 args:ssl_logging=0x00 >/dev/null
    xe host-call-plugin host-uuid=$h plugin=nrpe fn=restart >/dev/null
    echo "NRPE status after:  $(xe host-call-plugin host-uuid=$h plugin=nrpe fn=status)"
    echo "OK: configure-nrpe"
}

# --- 54. Configure SNMP monitoring ---
w_configure_snmp() {
    h=$(first_host)
    # Enable the SNMP agent with a community string, through the snmp plugin. The whole configuration is
    # passed as a JSON string under the "config" arg (single-quoted so the shell leaves it intact).
    config='{"common":{"enabled":"yes","debug_log":"no"},"agent":{"v2c":"yes","v3":"no","community":"sdk-community","user_name":"","authentication_password":"","authentication_protocol":"","privacy_password":"","privacy_protocol":""},"nmss":[]}'
    xe host-call-plugin host-uuid=$h plugin=snmp fn=set-config "args:config=$config" >/dev/null
    echo "SNMP status: $(xe host-call-plugin host-uuid=$h plugin=snmp fn=status)"
    echo "OK: configure-snmp"
}

# --- Manage a vApp ---------------------------------------------------------------------
w_manage_vapp() {
    local vm_uuid vapp_uuid
    vm_uuid=$(xe vm-list name-label=web-01 --minimal)
    vapp_uuid=$(xe vm-appliance-create name-label=sdk-example-vapp \
        name-description="Created by the SDK example")

    # `order` decides the sequence: ascending to start, descending to shut down. That ordering is the
    # reason to use a vApp rather than selecting several VMs.
    xe vm-param-set uuid="$vm_uuid" appliance="$vapp_uuid" order=0 start-delay=5

    xe vm-appliance-start uuid="$vapp_uuid"
    echo "Started:        $(xe vm-list uuid="$vm_uuid" params=power-state --minimal)"

    xe vm-appliance-shutdown uuid="$vapp_uuid"
    echo "Shut down:      $(xe vm-list uuid="$vm_uuid" params=power-state --minimal)"

    xe vm-param-set uuid="$vm_uuid" appliance=OpaqueRef:NULL
    xe vm-appliance-destroy uuid="$vapp_uuid"
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

    # USB-group, not usb-group: xe turns underscores into hyphens but keeps the wire field's
    # case, and the field is USB_group.
    group_uuid=$(xe pusb-list uuid="$pusb_uuid" params=USB-group --minimal)
    vusb_uuid=$(xe vusb-create vm-uuid="$vm_uuid" usb-group-uuid="$group_uuid")
    echo "Attached:       $(count_csv "$(xe vusb-list vm="$vm_uuid" --minimal)") device(s)"

    xe vusb-destroy uuid="$vusb_uuid"
    xe pusb-param-set uuid="$pusb_uuid" passthrough-enabled=false
    echo "OK: attach-usb-device"
}

# --- Read workload-balancing recommendations ----------------------------------------------
w_wlb_recommendations() {
    xe pool-initialize-wlb wlb-url=https://wlb.example:8012 wlb-username=wlbuser \
        wlb-password=wlbpass xenserver-username="$XE_USER" xenserver-password="$XE_PASSWORD"
    echo "WLB: $(xe pool-list params=wlb-url --minimal)"

    # One line per recommendation, keyed by VM: "wlb", the destination host UUID, two ids, the reason.
    xe pool-retrieve-wlb-recommendations

    # The appliance's own settings are read and written as one flat map of strings. Send a nightly
    # reporting schedule, then read the configuration back to confirm it took.
    xe pool-send-wlb-configuration config:ReportingCronString="0 3 * * *"
    echo "  appliance configuration: $(xe pool-retrieve-wlb-configuration)"

    xe pool-deconfigure-wlb
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
    # briefly interrupts management traffic - it does not move any VM.
    xe pool-designate-new-master host-uuid="$other"
    echo "Promoted:    $(xe host-list uuid="$other" params=name-label --minimal)"

    # Put it back. Ejecting a member (pool-eject) is the other half of this surface and is deliberately
    # not shown: it cannot be undone from the pool, because rejoining is initiated by the ejected host.
    xe pool-designate-new-master host-uuid="$original"
    echo "Restored:    $(xe host-list uuid="$original" params=name-label --minimal)"
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
    site=$(xe pvs-site-introduce name-label=sdk-pvs-farm name-description="Created by the SDK examples")
    xe pvs-server-introduce addresses=10.62.0.90 first-port=6910 last-port=6930 pvs-site-uuid="$site" >/dev/null

    # The read cache must be on LOCAL storage: keeping reads off the network is the point, so a cache
    # on a shared SR would defeat it and the server rejects one.
    for h in $(each_csv "$(xe host-list --minimal)"); do
        for pbd in $(each_csv "$(xe pbd-list host-uuid=$h --minimal)"); do
            sr=$(xe pbd-param-get uuid=$pbd param-name=SR)
            [ "$(xe sr-param-get uuid=$sr param-name=shared)" = "false" ] || continue
            [ "$(xe sr-param-get uuid=$sr param-name=content-type)" = "iso" ] && continue
            xe pvs-cache-storage-create host-uuid=$h sr-uuid=$sr pvs-site-uuid="$site" size=10737418240 >/dev/null
            break
        done
    done

    # A proxy may only sit on the VM's LOWEST-numbered NIC, and only one proxy may sit on a NIC — so
    # skip VMs the pool already accelerates and sort what is left by device.
    taken=""
    for proxy in $(each_csv "$(xe pvs-proxy-list --minimal)"); do
        vif=$(xe pvs-proxy-param-get uuid=$proxy param-name=VIF)
        taken="$taken $(xe vif-param-get uuid=$vif param-name=vm-uuid)"
    done
    for vm in $(each_csv "$(xe vm-list power-state=running --minimal)"); do
        case "$taken" in *"$vm"*) continue ;; esac
        vif=$(xe vif-list vm-uuid=$vm params=uuid,device --minimal | sort_by_device)
        [ -n "$vif" ] || continue
        proxy=$(xe pvs-proxy-create pvs-site-uuid="$site" vif-uuid="$vif")
        name=$(xe vm-param-get uuid=$vm param-name=name-label)
        break
    done

    # Scoped to THIS site: the pool may already have one, and counting pool-wide would report its
    # caches and servers as though this example had made them.
    caches=$(count_csv "$(xe pvs-cache-storage-list site-uuid="$site" --minimal)")
    servers=$(count_csv "$(xe pvs-server-list site-uuid="$site" --minimal)")
    echo "Site '$(xe pvs-site-param-get uuid=$site param-name=name-label)' with $caches cache(s) and $servers server(s)"
    # "caching" means it is really accelerating: a site with no cache reports "initialised", and a
    # proxy on a VM whose NIC is unplugged reports "stopped".
    echo "  $name: $(xe pvs-proxy-param-get uuid=$proxy param-name=status)"

    # Forgetting the site takes its servers, caches and proxies with it.
    xe pvs-site-forget uuid="$site"
    echo "OK: configure-pvs-accelerator"
}

# Read "uuid,device,uuid,device,..." pairs on stdin and echo the uuid with the lowest device. Bash
# builtins only: on Windows every pipe stage is a process launch, and this runs once per VM.
sort_by_device() {
    local pairs best_uuid="" best_dev=""
    read -r pairs
    local IFS=,; set -- $pairs
    while [ $# -ge 2 ]; do
        if [ -z "$best_dev" ] || [ "$2" -lt "$best_dev" ]; then best_uuid=$1; best_dev=$2; fi
        shift 2
    done
    echo "$best_uuid"
}

# --- Manage SSH access ---
w_manage_ssh_access() {
    # Timed access is the point: set the timeout first and the server stamps an expiry when SSH is
    # enabled, so a window opened for troubleshooting closes itself.
    for h in $(each_csv "$(xe host-list --minimal)"); do
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
    echo "OK: manage-ssh-access"
}

# --- Change control domain memory ---
w_control_domain_memory() {
    h=$(nth_csv "$(xe host-list --minimal)" 1)
    # dom0 is a VM like any other, but vm-list deliberately hides control domains — so walk the host's
    # resident VMs instead and ask each one.
    dom0=""
    for v in $(each_csv "$(xe host-param-get uuid=$h param-name=resident-VMs --minimal)"); do
        [ "$(xe vm-param-get uuid=$v param-name=is-control-domain)" = "true" ] && { dom0=$v; break; }
    done
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
        [ -z "$(xe vm-param-get uuid=$v param-name=VTPMs)" ] && { vm=$v; break; }
    done
    echo "Attaching a vTPM to $(xe vm-param-get uuid=$vm param-name=name-label)"

    vtpm=$(xe vtpm-create vm-uuid=$vm is-unique=false)
    echo "  persistence backend: $(xe vtpm-param-get uuid=$vtpm param-name=persistence-backend)"
    echo "  unique to this VM:   $(xe vtpm-param-get uuid=$vtpm param-name=is-unique)"
    echo "  VM now has $(count_csv "$(xe vm-param-get uuid=$vm param-name=VTPMs --minimal)") vTPM(s)"

    # The VM advertises whether another can be added; once it has one, it cannot.
    case "$(xe vm-param-get uuid=$vm param-name=allowed-operations)" in
        *create_vtpm*) echo "  can add another:     true" ;;
        *)             echo "  can add another:     false" ;;
    esac

    xe vtpm-destroy uuid=$vtpm
    echo "  after removal:       $(count_csv "$(xe vm-param-get uuid=$vm param-name=VTPMs --minimal)") vTPM(s)"
    echo "OK: manage-vtpm"
}

# --- Back up with changed block tracking ---
w_changed_block_tracking() {
    vm=$(nth_csv "$(xe vm-list --minimal)" 1)
    echo "Backing up $(xe vm-param-get uuid=$vm param-name=name-label)"

    first=$(xe vm-snapshot uuid=$vm new-name-label=cbt-backup-1)
    second=$(xe vm-snapshot uuid=$vm new-name-label=cbt-backup-2)
    vdi_from=$(first_disk_vdi "$first")
    vdi_to=$(first_disk_vdi "$second")
    xe vdi-enable-cbt uuid=$vdi_from
    xe vdi-enable-cbt uuid=$vdi_to

    # One bit per 64 KiB block, base64-encoded; bit N set means block N changed. A real backup reads only
    # those blocks, over NBD. Counting the bits needs a decoder, which bash is not - so report the size
    # of the answer and let the language examples do the arithmetic.
    encoded=$(xe vdi-list-changed-blocks uuid=$vdi_from vdi-to-uuid=$vdi_to)
    size=$(xe vdi-param-get uuid=$vdi_to param-name=virtual-size)
    echo "  bitmap of ${#encoded} base64 chars covers $((size / 65536)) blocks of 64 KiB"

    # Release the older snapshot's blocks but keep its change metadata, so the next incremental can still
    # diff against it. The VDI record stays; its type changes.
    xe vdi-data-destroy uuid=$vdi_from
    echo "  older snapshot is now type=$(xe vdi-param-get uuid=$vdi_from param-name=type), still cbt-enabled=$(xe vdi-param-get uuid=$vdi_from param-name=cbt-enabled)"

    xe snapshot-destroy uuid=$first
    xe snapshot-destroy uuid=$second
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
    # Only a halted VM can be exported: its disks must not be changing underneath the copy.
    vm=$(nth_csv "$(xe vm-list power-state=halted --minimal)" 1)
    echo "Exporting $(xe vm-param-get uuid=$vm param-name=name-label)"

    # Relative to the working directory: xe.exe and this script must agree on the path, and a Windows
    # temp directory spelled with backslashes would not survive the trip through both.
    file="cli-export.xva"
    # xe does the HTTP transfer itself: the server answers the command by telling the client to GET
    # /export, and xe writes the file. Nothing streams down the CLI connection.
    xe vm-export uuid=$vm filename="$file"
    size=$(stat -c %s "$file" 2>/dev/null || wc -c < "$file")
    echo "  wrote $((size / 1024 / 1024)) MiB to $(basename "$file")"

    imported=$(xe vm-import filename="$file")
    echo "  imported as $(xe vm-param-get uuid=$imported param-name=name-label)"

    xe vm-destroy uuid=$imported
    rm -f "$file"
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
    # --minimal, because without it xe prints a list as "1; 2; 3" and nth_csv would hand back the lot.
    device=$(nth_csv "$(xe vm-param-get uuid=$vm param-name=allowed-VBD-devices --minimal)" 1)
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
        # The refusal is the half worth rehearsing: restoring one host's configuration onto another is
        # destructive and unrecoverable, so the pool checks rather than trusting the caller.
        if xe host-restore uuid=$other file-name="$file" >/dev/null 2>&1; then
            echo "  ERROR: another host's backup was accepted"
        else
            echo "  restoring it to $(xe host-param-get uuid=$other param-name=name-label): refused"
        fi
    fi

    rm -f "$file"
    echo "OK: backup-host-config"
}

# --- Detach, reattach and forget storage ---
w_manage_sr_lifecycle() {
    sr=$(xe sr-create name-label=cli-example-lifecycle type=nfs content-type=user shared=true \
        device-config:server=192.0.2.10 device-config:serverpath=/export/spare device-config:nfsversion=3)

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
    before=$(xe pool-param-get uuid=$pool param-name=default-SR)
    before_suspend=$(xe pool-param-get uuid=$pool param-name=suspend-image-SR)
    before_crash=$(xe pool-param-get uuid=$pool param-name=crash-dump-SR)
    echo "default storage:  $(sr_label "$before")"
    echo "  suspend images: $(sr_label "$before_suspend")"
    echo "  crash dumps:    $(sr_label "$before_crash")"

    # Somewhere to switch to. The pool default has to be reachable from every host, so it is shared
    # storage; a local SR would strand any VM whose disk landed on the wrong host.
    sr=$(xe sr-create name-label=cli-example-default type=nfs content-type=user shared=true \
        device-config:server=192.0.2.10 device-config:serverpath=/export/spare device-config:nfsversion=3)
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
    # Split the XML on '<' with bash's own field splitting rather than spawning a parser: each element
    # starts a field, and the ones we want begin `capability key="..."`.
    old_ifs=$IFS; IFS='<'
    for element in $capabilities; do
        case "$element" in
            capability\ *)
                key=$(xml_attr "$element" key)
                keys="${keys:+$keys,}$key"
                printf '  %-22s max %9s bytes  default=%-3s pii=%s\n' \
                    "$key" "$(xml_attr "$element" max-size)" \
                    "$(xml_attr "$element" default-checked)" "$(xml_attr "$element" pii)"
                ;;
        esac
    done
    IFS=$old_ifs

    rm -f cli-status-all.tar cli-status-config.tar
    xe host-get-system-status uuid=$target filename=cli-status-all.tar entries="$keys"
    whole=$(stat -c %s cli-status-all.tar)
    echo "everything ($(count_csv "$keys") sections): $whole bytes"

    # Worth checking rather than assuming: a server that ignored the selection would look identical from
    # here until someone opened the archive and found the whole thing.
    xe host-get-system-status uuid=$target filename=cli-status-config.tar entries=xenserver-config
    subset=$(stat -c %s cli-status-config.tar)
    echo "xenserver-config only:   $subset bytes"
    if [ "$subset" -ge "$whole" ]; then
        echo "  ERROR: selecting fewer sections did not produce a smaller bundle"
    fi

    rm -f cli-status-all.tar cli-status-config.tar
    echo "OK: server-status-report"
}

# --- Recover VMs after a disaster ---
w_disaster_recovery() {
    # Disaster recovery works by writing the pool's own database out to a storage repository as a disk of
    # type "metadata". Replication needs shared storage that can hold data.
    sr=$(shared_sr)
    echo "Replicating pool metadata to $(xe sr-param-get uuid=$sr param-name=name-label)"
    xe sr-enable-database-replication uuid=$sr

    vdi=$(first_csv "$(xe vdi-list type=metadata sr-uuid=$sr --minimal)")
    echo "  metadata disk: $vdi"

    # `database:vdi-uuid=` runs the command against the replicated database instead of the live pool, so
    # this lists the VMs as they were written out rather than the ones running now. It works on vm-list,
    # param-list and param-get alike.
    recoverable=$(xe vm-list database:vdi-uuid=$vdi --minimal)
    echo "  the replicated database describes $(count_csv "$recoverable") recoverable VM(s)"

    md=$(first_csv "$recoverable")
    name=$(xe vm-list uuid=$md database:vdi-uuid=$vdi params=name-label --minimal)
    echo "  recovering $name"

    # xe opens the database itself and issues both calls on the resulting session, with the live one as
    # the destination — recovery reads from the replicated database and writes into the live pool.
    xe vm-assert-can-be-recovered uuid=$md database:vdi-uuid=$vdi
    xe vm-recover uuid=$md database:vdi-uuid=$vdi

    # It is a real VM in the live pool now, not merely a command that returned.
    echo "  $name is $(xe vm-param-get uuid=$md param-name=power-state) in the live pool"

    xe vm-destroy uuid=$md
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
    vm=$(first_csv "$(xe vm-list secureboot-certificates-state=update_available --minimal)")
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
    echo "  rebooted:   enabled=$(xe host-param-get uuid=$target param-name=enabled)"

    # The other ending: off, and back on out of band.
    xe host-shutdown uuid=$target
    echo "  shut down:  live=$(host_live $target)"
    xe host-power-on uuid=$target
    echo "  powered on: live=$(host_live $target)"
    echo "OK: restart-host"
}

# Resident VMs excluding the control domain, which never moves.
count_host_guest() {
    local n=0
    for vm in $(each_csv "$(xe host-param-get uuid=$1 param-name=resident-VMs)"); do
        if [ "$(xe vm-param-get uuid=$vm param-name=is-control-domain)" != "true" ]; then n=$((n + 1)); fi
    done
    echo $n
}

host_live() { xe host-metrics-param-get uuid=$(xe host-param-get uuid=$1 param-name=metrics) param-name=live; }

# --- Create a VM and a template from a snapshot ---
w_vm_from_snapshot() {
    # A snapshot is a VM record with is_a_snapshot set, so both of these are clones of it - the difference
    # is only what you mark the result as.
    vm=$(vm_uuid db-01)
    snap=$(xe vm-snapshot uuid=$vm new-name-label=xe-example-source-snapshot)
    echo "Snapshot of db-01 taken"

    # snapshot-clone gives an ordinary VM, not another snapshot: it stands on its own, and vm-list (which
    # filters snapshots out) shows it.
    newvm=$(xe snapshot-clone uuid=$snap new-name-label=xe-example-vm-from-snapshot)
    echo "  new VM:      $(xe vm-param-get uuid=$newvm param-name=name-label) (is-a-snapshot=$(xe vm-param-get uuid=$newvm param-name=is-a-snapshot))"

    # The same clone, marked as a template instead: a starting point to stamp more VMs from.
    tmpl=$(xe snapshot-clone uuid=$snap new-name-label=xe-example-template-from-snapshot)
    xe vm-param-set uuid=$tmpl is-a-template=true
    echo "  new template:$(xe template-param-get uuid=$tmpl param-name=name-label) (is-a-template=$(xe template-param-get uuid=$tmpl param-name=is-a-template))"

    xe vm-destroy uuid=$newvm
    xe vm-destroy uuid=$tmpl
    xe vm-destroy uuid=$snap
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

    vbd=$(xe vbd-create vm-uuid=$first vdi-uuid=$vdi device=3 type=Disk mode=RW)
    echo "  attached to $(xe vm-param-get uuid=$first param-name=name-label)"

    # Destroying the VBD detaches the disk; the disk itself is untouched and keeps its data.
    xe vbd-destroy uuid=$vbd
    echo "  detached:   the disk still exists ($(xe vdi-param-get uuid=$vdi param-name=virtual-size) bytes)"

    vbd2=$(xe vbd-create vm-uuid=$second vdi-uuid=$vdi device=3 type=Disk mode=RW)
    echo "  attached to $(xe vm-param-get uuid=$second param-name=name-label)"
    echo "  the disk is on $(count_csv "$(xe vdi-param-get uuid=$vdi param-name=vbds)") VM(s)"

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
        if [ -n "$(xe host-param-get uuid=$h param-name=crashdumps --minimal)" ]; then target=$h; break; fi
    done
    if [ -z "$target" ]; then
        echo "No crash dumps in this pool - nothing to clear."
        echo "OK: manage-crash-dumps"
        return
    fi

    dumps=$(xe host-param-get uuid=$target param-name=crashdumps --minimal)
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
    echo "  cleared:  $(xe host-param-get uuid=$target param-name=name-label) now has $(count_csv "$(xe host-param-get uuid=$target param-name=crashdumps --minimal)")"
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

    before_iqn=$(xe host-param-get uuid=$host_uuid param-name=iscsi-iqn)
    before_multipathing=$(xe host-param-get uuid=$host_uuid param-name=multipathing)
    echo "$hname: iSCSI IQN '$before_iqn', multipathing $before_multipathing"

    xe host-param-set uuid=$host_uuid iscsi-iqn="iqn.2026-01.com.example:$hname"
    xe host-param-set uuid=$host_uuid multipathing=true
    echo "  IQN now:      $(xe host-param-get uuid=$host_uuid param-name=iscsi-iqn)"
    echo "  multipathing: $(xe host-param-get uuid=$host_uuid param-name=multipathing)"

    xe host-param-set uuid=$host_uuid iscsi-iqn="$before_iqn"
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
    # pick the setting up.
    xe host-param-remove uuid=$host_uuid param-name=logging param-key=syslog_destination
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

    n=0
    for d in $(each_csv "$drivers"); do
        n=$((n + 1)); [ "$n" -gt 3 ] && break
        dname=$(xe hostdriver-param-get uuid=$d param-name=name)
        dtype=$(xe hostdriver-param-get uuid=$d param-name=type)
        variants=$(xe hostdriver-param-get uuid=$d param-name=variants --minimal)
        active=$(xe hostdriver-param-get uuid=$d param-name=active-variant)
        printf '  %-14s %-10s %d variant(s), active=%s\n' "$dname" "$dtype" "$(count_csv "$variants")" "${active:-(none)}"
    done

    # Select a variant explicitly. It becomes the selected one immediately; whether it is also
    # active depends on whether the hardware is present and the driver already loaded.
    driver=$(first_csv "$drivers")
    dname=$(xe hostdriver-param-get uuid=$driver param-name=name)
    variant=$(first_csv "$(xe hostdriver-param-get uuid=$driver param-name=variants --minimal)")
    variant_name=$(xe driver-variant-param-get uuid=$variant param-name=name)
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
    create-gfs2-sr)       w_create_gfs2_sr ;;
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
