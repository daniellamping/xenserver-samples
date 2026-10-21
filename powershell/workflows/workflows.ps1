<#
    XenServer PowerShell SDK - real-world workflow examples.

    Each example mirrors a task you would perform in XenCenter, driven through the XenServer
    PowerShell module (which wraps the XenAPI .NET binding and speaks JSON-RPC).

    Written in idiomatic PowerShell: the module's cmdlets take their object from the pipeline, so an
    example reads as a pipeline of verbs - fetch an object with Get-Xen*, then pipe it straight into the
    cmdlet that acts on it (Invoke-Xen* for actions, Set-Xen*/Add-Xen*/Remove-Xen*Property for edits,
    Remove-Xen* to delete). Long-running actions use the -Async -PassThru | Wait-XenTask -ShowProgress
    idiom, and a second pool is driven through the same cmdlets with -SessionOpaqueRef. Everything goes
    through the module's cmdlets - there are no raw XenAPI .NET static method calls. The one thing the
    module ships no cmdlet for is the event API, so the events example calls its JSON-RPC endpoint with
    Invoke-RestMethod (still pure PowerShell - Connect-Example has already established trust for the
    server's certificate).

    The examples are deliberately self-contained: every function takes the connection details (and any
    object it operates on) as parameters, opens its own session, does its work and disconnects. Nothing
    is hard-coded inside a function, so you can copy one out and run it on its own - see the "Run it:"
    line under each. The dispatcher at the bottom is only what lets this one file run any of them from
    the command line.

    Usage:
        powershell -File workflows.ps1 <workflow> <url> <username> <password>

        <workflow>  any workflow id from the dispatcher at the bottom (see also README.md)
#>
param(
    [Parameter(Mandatory = $true)][string]$Workflow,
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$UserName,
    [Parameter(Mandatory = $true)][string]$Password,
    # Anything a particular workflow needs beyond the connection. Only cross-pool-copy-vm uses it (for
    # the second pool's URL) and it reads it from the dispatcher at the bottom, so nothing up here has to
    # know about it.
    [Parameter(ValueFromRemainingArguments)][string[]]$WorkflowArgs
)

$ErrorActionPreference = "Stop"

# The SDK's compiled PowerShell module: copy XenServerPowerShell/PowerShell_51/XenServerPSModule (or
# PowerShell_7 for PowerShell 7) from the SDK into a folder on $env:PSModulePath.
Import-Module XenServerPSModule

# Connecting to XenServer is a little more involved than Connect-XenServer on its own:
#   * a server presents a self-signed certificate on first contact, so you accept it
#     (-NoWarnCertificates / -NoWarnNewCertificates), and -SetDefaultSession lets the other
#     Get-Xen*/Invoke-Xen* cmdlets use the session implicitly; and
#   * if you point it at a pool *member* rather than the coordinator, the login is rejected with
#     HOST_IS_SLAVE naming the coordinator - so you reconnect to that address (exactly what XenCenter
#     does for you when you add a member server). Connect-Example wraps both concerns:
#
#     $session = Connect-Example -Url https://xenserver -UserName root -Password $password
#     <# ... call cmdlets ... #>
#     $session | Disconnect-XenServer

# --- connect ---
function Connect-Example {
    # A thin, reusable wrapper around the connect handshake described above, so each example can stay
    # focused on the task. Follows the pool-member -> coordinator redirect (HOST_IS_SLAVE).
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    # Accepting the certificate in Connect-XenServer covers the module's cmdlets, and on Windows PowerShell
    # 5.1 Invoke-RestMethod/Invoke-WebRequest as well. PowerShell 7's web cmdlets keep their own trust, so
    # extend the same acceptance to them for the examples that talk to the host over plain HTTP(S).
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $global:PSDefaultParameterValues['Invoke-RestMethod:SkipCertificateCheck'] = $true
        $global:PSDefaultParameterValues['Invoke-WebRequest:SkipCertificateCheck'] = $true
    }
    try {
        return Connect-XenServer -Url $Url -UserName $UserName -Password $Password `
            -NoWarnCertificates -NoWarnNewCertificates -SetDefaultSession -PassThru
    }
    catch {
        # A pool member reports the coordinator's address in the HOST_IS_SLAVE error; reconnect there
        # (assuming the coordinator is up, as XenCenter does when you add a member server).
        $desc = $_.Exception.ErrorDescription
        if ($desc[0] -ne "HOST_IS_SLAVE") { throw }
        return Connect-XenServer -Url "https://$($desc[1])" -UserName $UserName -Password $Password `
            -NoWarnCertificates -NoWarnNewCertificates -SetDefaultSession -PassThru
    }
}

function Invoke-XenMethod {
    # A thin JSON-RPC caller for the handful of XenAPI methods the module ships no cmdlet for (see
    # Get-XenEventBatch above for the same pattern). Pure PowerShell — Connect-Example has already trusted
    # the server's certificate, so no extra TLS setup is needed.
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$Method,
        # Optional: plenty of methods take nothing but the session (VM.get_all_records, for one), and a
        # mandatory array rejects @() rather than treating it as "no further arguments".
        [object[]]$Params = @()
    )
    $body = @{ jsonrpc = "2.0"; id = 1; method = $Method; params = @($Session.opaque_ref) + $Params } |
        ConvertTo-Json -Depth 6
    $resp = Invoke-RestMethod -Uri "$($Session.Url)/jsonrpc" -Method Post -Body $body -ContentType "application/json"
    if ($resp.error) { throw "$Method failed: $($resp.error | ConvertTo-Json -Compress)" }
    return $resp.result
}

function Get-XenEventBatch {
    # The XenServer PowerShell module ships no event cmdlet, so this thin wrapper calls the JSON-RPC
    # event.from method directly with Invoke-RestMethod (Connect-Example has already trusted the server's
    # certificate, so no extra TLS setup is needed). An empty token returns the current
    # snapshot plus a token to watch from; passing that token back long-polls for changes.
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string[]]$Classes,
        [string]$Token = "",
        [double]$Timeout = 5.0
    )
    $body = @{
        jsonrpc = "2.0"; id = 1; method = "event.from"
        params  = @($Session.opaque_ref, $Classes, $Token, $Timeout)
    } | ConvertTo-Json -Depth 6
    $resp = Invoke-RestMethod -Uri "$($Session.Url)/jsonrpc" -Method Post -Body $body -ContentType "application/json"
    if ($resp.error) { throw "event.from failed: $($resp.error | ConvertTo-Json -Compress)" }
    return $resp.result
}

# --- 1. Connect & inventory ------------------------------------------------------------
function Invoke-ConnectInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1
    Write-Host "Connected to pool: $($pool.name_label)"

    $hosts = Get-XenHost
    Write-Host "Hosts ($($hosts.Count)):"
    Get-XenHost | ForEach-Object { Write-Host "  - $($_.name_label) ($($_.address))" }

    $vms = Get-XenVM | Where-Object { -not $_.is_a_template -and -not $_.is_control_domain }
    Write-Host "VMs ($($vms.Count)):"
    $vms | ForEach-Object { Write-Host "  - $($_.name_label) [$($_.power_state)]" }

    Write-Host "OK: connect-inventory"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConnectInventory -Url https://xenserver -UserName root -Password $password

# --- 2. Create a VM from a template ----------------------------------------------------
function Invoke-CreateVm {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-vm"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    Write-Host "Using template: $($template.name_label)"

    # Pipe the template straight into the Clone action; -PassThru returns the new VM object.
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    Write-Host "Cloned new VM: $($vm.uuid)"

    $vm | Invoke-XenVM -XenAction Provision
    Write-Host "Provisioned. is_a_template = $((Get-XenVM -Ref $vm.opaque_ref).is_a_template)"

    $vm | Remove-XenVM
    Write-Host "Cleaned up the example VM."

    Write-Host "OK: create-vm"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CreateVm -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 3. VM power lifecycle -------------------------------------------------------------
function Invoke-VmLifecycle {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-lifecycle"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Power operations are destructive, so this example works on a throwaway VM it clones from the
    # template (rather than a VM you care about) and deletes again at the end.
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $vm | Invoke-XenVM -XenAction Provision
    $ref = $vm.opaque_ref

    function State { (Get-XenVM -Ref $ref).power_state }

    Write-Host "Initial power state: $(State)"

    # Start asynchronously: -Async -PassThru emits a Task, which pipes straight into Wait-XenTask.
    # -ShowProgress surfaces the task's progress - the idiom for long-running operations where you want
    # to track progress rather than block silently.
    $vm | Invoke-XenVM -XenAction Start -Async -PassThru | Wait-XenTask -ShowProgress
    Write-Host "After start:    $(State)"

    # The emulated hardware (the device model) can be restarted under a running guest without rebooting
    # it - what you reach for when the VM's virtual devices misbehave.
    $vm | Invoke-XenVM -XenAction RestartDeviceModels
    Write-Host "Device models restarted; still $(State)"

    # The synchronous actions read as a pipeline too - pipe the VM into each verb.
    $vm | Invoke-XenVM -XenAction Suspend
    Write-Host "After suspend:  $(State)"
    $vm | Invoke-XenVM -XenAction Resume
    Write-Host "After resume:   $(State)"
    $vm | Invoke-XenVM -XenAction CleanShutdown
    Write-Host "After shutdown: $(State)"

    $vm | Remove-XenVM
    Write-Host "OK: vm-lifecycle"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-VmLifecycle -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 4. Manage VM disks: Deactivate / Resize / Activate -------------------------------
function Invoke-ManageVmDisks {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot } |
        Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }

    # The VM's first real disk (a CD drive is a VBD too, hence the type filter).
    $vbd = $vm.VBDs | ForEach-Object { Get-XenVBD -Ref $_ } | Where-Object { $_.type -eq 'Disk' } | Select-Object -First 1
    Write-Host "Disk attached:  $($vbd.currently_attached)"

    # Deactivate = VBD.unplug. The disk stays with the VM; it is just no longer live.
    Invoke-XenVBD -Ref $vbd.opaque_ref -XenAction Unplug
    Write-Host "After unplug:   $((Get-XenVBD -Ref $vbd.opaque_ref).currently_attached)"

    $vdi = Get-XenVDI -Ref $vbd.VDI
    Invoke-XenVDI -Ref $vdi.opaque_ref -XenAction Resize -Size ([int64]$vdi.virtual_size * 2)
    Write-Host "Resized:        $($vdi.virtual_size) -> $((Get-XenVDI -Ref $vdi.opaque_ref).virtual_size) bytes"

    Invoke-XenVBD -Ref $vbd.opaque_ref -XenAction Plug
    Write-Host "After plug:     $((Get-XenVBD -Ref $vbd.opaque_ref).currently_attached)"

    # Growing a disk that is attached and live is a DIFFERENT action, not a flag on the same one:
    # ResizeOnline tells the storage layer the guest is using the disk while it grows.
    $grown = [int64](Get-XenVDI -Ref $vdi.opaque_ref).virtual_size + 1GB
    Invoke-XenVDI -Ref $vdi.opaque_ref -XenAction ResizeOnline -Size $grown
    Write-Host "Grown online:   $((Get-XenVDI -Ref $vdi.opaque_ref).virtual_size) bytes"
    Write-Host "OK: manage-vm-disks"
    Disconnect-XenServer -Session $session
}

# --- Raise and dismiss alerts ---------------------------------------------------------
function Invoke-DismissAlerts {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $messages = @(Get-XenMessage)
    Write-Host "Alerts:         $($messages.Count)"

    if ($messages.Count -eq 0) {
        Write-Host "No alerts to dismiss."
    } else {
        $first = $messages[0]
        Write-Host "Dismissing:     $($first.name) (priority $($first.priority))"
        Remove-XenMessage -Ref $first.opaque_ref
        Write-Host "Alerts left:    $(@(Get-XenMessage).Count)"
    }
    Write-Host "OK: dismiss-alerts"
    Disconnect-XenServer -Session $session
}

# --- Configure host power on ----------------------------------------------------------
function Invoke-HostPowerOn {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1

    # Mode and config travel together — host.set_power_on_mode takes both in one call, because the
    # config carries the out-of-band credentials the mode needs. The module exposes only
    # Set-XenHost -PowerOnMode (no -PowerOnConfig), so this calls the method directly over JSON-RPC,
    # the same way the events example does for the missing event cmdlet. Still pure PowerShell: no
    # [XenAPI.*]:: statics, and Connect has already trusted the server's certificate.
    Invoke-XenMethod -Session $session -Method 'host.set_power_on_mode' -Params @(
        $xenHost.opaque_ref, 'iLO', @{ power_on_ip = '192.0.2.9'; power_on_user = 'poweradmin' })
    $updated = Get-XenHost -Ref $xenHost.opaque_ref
    Write-Host "Power-on mode:  $($updated.power_on_mode)"
    foreach ($k in ($updated.power_on_config.Keys | Sort-Object)) {
        Write-Host "  $k = $($updated.power_on_config[$k])"
    }

    Invoke-XenMethod -Session $session -Method 'host.set_power_on_mode' -Params @($xenHost.opaque_ref, '', @{})
    Write-Host "OK: host-power-on"
    Disconnect-XenServer -Session $session
}

# --- Rotate the pool secret -----------------------------------------------------------
function Invoke-RotatePoolSecret {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1
    Write-Host "Pool:           $($pool.name_label)"

    # A pool-wide operation; existing sessions survive it.
    Invoke-XenPool -Ref $pool.opaque_ref -XenAction RotateSecret
    Write-Host "Rotated. Still connected: $(@(Get-XenPool).Count -eq 1)"
    Write-Host "OK: rotate-pool-secret"
    Disconnect-XenServer -Session $session
}

# --- Change the root password ---------------------------------------------------------
function Invoke-ChangeRootPassword {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $temporary = 'sdk-example-temp-password'

    # The module ships no cmdlet for session.change_password, so this is the one place these examples
    # call the binding directly. The session Connect-XenServer hands back IS a XenAPI.Session, which is
    # exactly what the static wants. Note it takes the OLD password as well as the new one, even though
    # you are already authenticated.
    [XenAPI.Session]::change_password($session, $Password, $temporary)
    Write-Host "Password changed."

    # The existing session stays valid afterwards - only NEW connections need the new password, so a
    # script can carry on without reconnecting.
    Write-Host "Session still usable: $(@(Get-XenPool).Count -eq 1)"

    # Supplying the wrong current password is the failure worth handling.
    try {
        [XenAPI.Session]::change_password($session, 'definitely-not-it', 'irrelevant')
        Write-Host "unexpected: the wrong old password was accepted"
    } catch {
        Write-Host "Wrong old password rejected: $($_.Exception.Message.Split([char]10)[0])"
    }

    [XenAPI.Session]::change_password($session, $temporary, $Password)
    Write-Host "Password restored."
    Write-Host "OK: change-root-password"
    Disconnect-XenServer -Session $session
}

# --- Manage TLS certificates ----------------------------------------------------------
function Invoke-ManageCertificates {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    Write-Host "Certificates:   $(@(Get-XenCertificate).Count)"

    # A CA certificate is pool-wide; a server certificate belongs to one host.
    $pool = Get-XenPool | Select-Object -First 1
    Invoke-XenPool -Ref $pool.opaque_ref -XenAction InstallCaCertificate -Name 'sdk-example-ca' `
        -Cert '-----BEGIN CERTIFICATE-----sdk-example-----END CERTIFICATE-----'
    Write-Host "After CA add:   $(@(Get-XenCertificate).Count)"

    Invoke-XenHost -Ref $xenHost.opaque_ref -XenAction ResetServerCertificate
    Write-Host "Host certificate reset (a fresh self-signed identity)."

    Invoke-XenPool -Ref $pool.opaque_ref -XenAction UninstallCaCertificate -Name 'sdk-example-ca' -Force $false
    Write-Host "After CA remove:$(@(Get-XenCertificate).Count)"

    # Separately from which certificates exist: whether the pool actually CHECKS the ones its members
    # present to each other. Turning it on is a one-way door from here - there is no matching disable,
    # because a pool that could be talked out of verifying would not be verifying - so the call is
    # idempotent and safe to repeat.
    Write-Host "TLS verification: $(Get-XenPoolProperty -Ref $pool.opaque_ref -XenProperty TlsVerificationEnabled)"
    Invoke-XenPool -Ref $pool.opaque_ref -XenAction EnableTlsVerification
    Write-Host "  after enabling: $(Get-XenPoolProperty -Ref $pool.opaque_ref -XenProperty TlsVerificationEnabled)"
    Write-Host "OK: manage-certificates"
    Disconnect-XenServer -Session $session
}

# --- Snapshot schedule ----------------------------------------------------------------
function Invoke-SnapshotSchedule {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName,
        [string]$ScheduleName = "sdk-example-schedule"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot } |
        Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }

    # RetainedSnapshots is the interesting field: the schedule prunes to it every time it runs.
    $vmss = New-XenVMSS -NameLabel $ScheduleName `
        -NameDescription 'Scheduled snapshots created by the SDK example' `
        -Enabled $true -Type snapshot -Frequency daily -RetainedSnapshots 2 `
        -Schedule @{ hour = '2'; min = '0' } -PassThru
    Write-Host "Created schedule: $($vmss.uuid)"

    Set-XenVM -VM $vm -SnapshotSchedule $vmss.opaque_ref
    Write-Host "Members:          $((Get-XenVMSS -Ref $vmss.opaque_ref).VMs.Count)"

    # Run it three times against a retention of two: the oldest is pruned away.
    1..3 | ForEach-Object { Invoke-XenVMSS -Ref $vmss.opaque_ref -XenAction SnapshotNow | Out-Null }
    Write-Host "Snapshots kept:   $((Get-XenVM -Ref $vm.opaque_ref).snapshots.Count) (retention 2)"

    Remove-XenVMSS -Ref $vmss.opaque_ref
    Write-Host "OK: snapshot-schedule"
    Disconnect-XenServer -Session $session
}

# --- Manage VM groups -----------------------------------------------------------------
function Invoke-ManageVmGroups {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName,
        [string]$GroupName = "sdk-example-group"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot } |
        Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }

    # anti_affinity asks the pool to keep the group's members on different hosts.
    $group = New-XenVMGroup -NameLabel $GroupName `
        -NameDescription 'Anti-affinity group created by the SDK example' `
        -Placement anti_affinity -PassThru
    Write-Host "Created group:  $($group.uuid)"

    # Membership is written from the VM side...
    Set-XenVM -VM $vm -Groups @($group.opaque_ref)

    # ...and read back from the group side, which is the half that is easy to get wrong.
    $members = (Get-XenVMGroup -Ref $group.opaque_ref).VMs
    Write-Host "Group members:  $($members.Count)"
    foreach ($m in $members) { Write-Host "  $((Get-XenVM -Ref $m).name_label)" }

    Set-XenVM -VM $vm -Groups @()
    Write-Host "After removal:  $((Get-XenVMGroup -Ref $group.opaque_ref).VMs.Count) member(s)"

    Remove-XenVMGroup -Ref $group.opaque_ref
    Write-Host "OK: manage-vm-groups"
    Disconnect-XenServer -Session $session
}

# --- Snapshot & revert ----------------------------------------------------------------
function Invoke-SnapshotRevert {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName,
        [string]$SnapshotName = "sdk-example-snapshot"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot } |
        Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }
    Write-Host "Snapshotting VM: $($vm.name_label)"

    $snap = $vm | Invoke-XenVM -XenAction Snapshot -NewName $SnapshotName -PassThru
    Write-Host "Created snapshot: $($snap.uuid)"

    # Revert the VM to the snapshot. The native cmdlet takes the VM (piped in) and the snapshot to
    # restore via -Snapshot.
    $vm | Invoke-XenVM -XenAction Revert -Snapshot $snap
    Write-Host "Reverted VM to the snapshot."

    # A client shows a thumbnail of what was on screen when the snapshot was taken. It is an HTTP
    # transfer alongside the API, not an API call, so the session id travels in the query string. Still
    # pure PowerShell: Connect-Example has already trusted the server's certificate.
    $thumb = Invoke-WebRequest -UseBasicParsing `
        -Uri "$Url/vncsnapshot?session_id=$($session.opaque_ref)&ref=$($snap.opaque_ref)"
    Write-Host "Thumbnail:      $($thumb.Content.Length) bytes of PNG"

    $snap | Remove-XenVM
    Write-Host "OK: snapshot-revert"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-SnapshotRevert -Url https://xenserver -UserName root -Password $password -VmName 'web-01'

# --- 5. Create an NFS storage repository -----------------------------------------------
function Invoke-CreateNfsSr {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$NfsServer,
        [Parameter(Mandatory = $true)][string]$NfsPath,
        [string]$SrName = "sdk-example-nfs"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    $deviceConfig = @{ server = $NfsServer; serverpath = $NfsPath; nfsversion = "3" }

    $sr = New-XenSR -XenHost $xenHost -DeviceConfig $deviceConfig -PhysicalSize 0 `
        -NameLabel $SrName -NameDescription "NFS SR created by the SDK example" `
        -Type "nfs" -ContentType "user" -Shared $true -PassThru
    Write-Host "Created SR: $($sr.uuid)"

    $sr | Invoke-XenSR -XenAction Forget
    Write-Host "OK: create-nfs-sr"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CreateNfsSr -Url https://xenserver -UserName root -Password $password -NfsServer 192.0.2.10 -NfsPath /export/sdk

# --- 6. Create a network ---------------------------------------------------------------
function Invoke-CreateNetwork {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$NetworkName = "sdk-example-net"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $net = New-XenNetwork -NameLabel $NetworkName `
        -NameDescription "Internal network created by the SDK example" -MTU 1500 -PassThru
    Write-Host "Created network: $($net.uuid)"

    # Raise the MTU to use jumbo frames. Every NIC and switch along the path has to agree, so this is a
    # property of the network rather than of any one interface on it.
    $net | Set-XenNetwork -MTU 9000
    Write-Host "MTU now:         $((Get-XenNetwork -Ref $net.opaque_ref).MTU)"

    $net | Remove-XenNetwork
    Write-Host "OK: create-network"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CreateNetwork -Url https://xenserver -UserName root -Password $password -NetworkName 'sdk-example-net'

# --- 7. Edit VM properties -------------------------------------------------------------
function Invoke-EditVmProperties {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain } | Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }
    $originalDesc = $vm.name_description

    # Set-XenVM -OtherConfig replaces the whole map, so copy the current one, add our entry and write it
    # back (leaving the VM's existing keys intact).
    $current = $vm.other_config
    $oc = @{}
    foreach ($k in $current.Keys) { $oc[$k] = $current[$k] }
    $oc["sdk_example"] = "true"
    $vm | Set-XenVM -NameDescription "Edited by the SDK example"
    $vm | Set-XenVM -OtherConfig $oc

    $edited = Get-XenVM -Ref $vm.opaque_ref
    Write-Host "New description: $($edited.name_description)"
    Write-Host "other_config[sdk_example] = $($edited.other_config['sdk_example'])"

    # Put it back so the example is repeatable: restore the description and drop the key we added.
    $vm | Set-XenVM -NameDescription $originalDesc
    $vm | Remove-XenVMProperty -OtherConfig "sdk_example"
    Write-Host "OK: edit-vm-properties"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-EditVmProperties -Url https://xenserver -UserName root -Password $password -VmName 'web-01'

# --- 8. Event monitoring ---------------------------------------------------------------
function Invoke-Events {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # An empty token returns the current snapshot and a token; passing that token back long-polls
    # until something changes. (Get-XenEventBatch is our thin wrapper - see the top of the file.)
    $batch = Get-XenEventBatch -Session $session -Classes VM -Token "" -Timeout 1.0
    $token = $batch.token
    Write-Host "Established event token after initial snapshot."

    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain } | Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }
    $original = $vm.name_description
    $vm | Set-XenVM -NameDescription "changed-to-trigger-event"

    $batch = Get-XenEventBatch -Session $session -Classes VM -Token $token -Timeout 5.0
    Write-Host "Received $(@($batch.events).Count) event(s) after the change."
    $batch.events | Select-Object -First 3 | ForEach-Object { Write-Host "  - $($_.operation) $($_.class)" }

    $vm | Set-XenVM -NameDescription $original   # put it back
    Write-Host "OK: events"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-Events -Url https://xenserver -UserName root -Password $password -VmName 'web-01'

# --- 9. New VM wizard (full) -----------------------------------------------------------
function Invoke-NewVmWizard {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "wizard-vm"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Page 1 - Template.
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    Write-Host "Template:      $($template.name_label)"

    # Page 2 - Name and description.
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $ref = $vm.opaque_ref
    $vm | Set-XenVM -NameDescription "Created by the full New VM wizard example"
    $vm | Set-XenVM -IsATemplate $false
    Write-Host "Created VM:    $((Get-XenVM -Ref $ref).uuid)"

    # Page 3 - Installation media (a network install repository). Set replaces other_config wholesale,
    # so merge our key into a copy of the current map.
    $current = (Get-XenVM -Ref $ref).other_config
    $oc = @{}
    foreach ($k in $current.Keys) { $oc[$k] = $current[$k] }
    $oc["install-repository"] = "http://mirror.example.com/rocky/9/os/x86_64"
    $vm | Set-XenVM -OtherConfig $oc
    Write-Host "Install media: network repository"

    # Page 4 - Home server (affinity).
    $xenHost = Get-XenHost | Select-Object -First 1
    $vm | Set-XenVM -Affinity $xenHost
    Write-Host "Home server:   $($xenHost.name_label)"

    # Page 5 - CPU & Memory. -MemoryLimits takes [static_min, static_max, dynamic_min, dynamic_max].
    $vm | Set-XenVM -VCPUsMax 2 -VCPUsAtStartup 2
    $vm | Set-XenVM -MemoryLimits (512MB, 2GB, 2GB, 2GB)
    Write-Host "CPU/memory:    2 vCPUs, 2 GiB"

    # Page 6 - Storage: add a disk on a (non-ISO) SR.
    $sr = Get-XenSR | Where-Object { $_.content_type -ne 'iso' -and $_.type -notin @('iso', 'udev') } | Select-Object -First 1
    $vbdDevice = (Get-XenVMProperty -Ref $ref -XenProperty AllowedVBDDevices)[0]
    $vdi = New-XenVDI -NameLabel "$NewVmName disk 0" -NameDescription "System disk created by the wizard example" `
        -SR $sr -VirtualSize 24GB -Type system -Sharable $false -ReadOnly $false -PassThru
    New-XenVBD -VM (Get-XenVM -Ref $ref) -VDI $vdi -Userdevice $vbdDevice -Bootable $true `
        -Mode RW -Type Disk -Empty $false | Out-Null
    Write-Host "Storage:       24 GiB disk on $($sr.name_label)"

    # Page 7 - Networking: attach a VIF to a network.
    $net = Get-XenNetwork | Select-Object -First 1
    $vifDevice = (Get-XenVMProperty -Ref $ref -XenProperty AllowedVIFDevices)[0]
    New-XenVIF -VM (Get-XenVM -Ref $ref) -Network $net -Device $vifDevice -MAC "" -MTU 1500 | Out-Null
    Write-Host "Networking:    NIC on $($net.name_label)"

    # Page 8 - Finish: start the VM.
    $vm | Invoke-XenVM -XenAction Start

    $started = Get-XenVM -Ref $ref
    Write-Host "--- Result ---"
    Write-Host "power state:   $($started.power_state)"
    Write-Host "vCPUs:         $($started.VCPUs_max)"
    Write-Host "disks:         $(@($started.VBDs).Count), NICs: $(@($started.VIFs).Count)"

    # Tidy up so the example is repeatable.
    $vm | Invoke-XenVM -XenAction HardShutdown
    $vm | Remove-XenVM
    $vdi | Remove-XenVDI
    Write-Host "OK: new-vm-wizard"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-NewVmWizard -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 10. Live migrate a VM -------------------------------------------------------------
function Invoke-LiveMigrate {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-migrate"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Start a throwaway VM so there is something running to migrate.
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $vm | Invoke-XenVM -XenAction Provision
    $ref = $vm.opaque_ref
    $vm | Invoke-XenVM -XenAction Start

    $sourceHostRef = (Get-XenVM -Ref $ref).resident_on
    Write-Host "VM is running on: $((Get-XenHost -Ref $sourceHostRef).name_label)"

    # Pick a different host in the pool to receive the VM.
    $destHost = Get-XenHost | Where-Object { $_.opaque_ref -ne $sourceHostRef } | Select-Object -First 1

    # Check the destination can boot it, then live-migrate. Both are native cmdlet actions: the
    # destination host is passed as -XenHost and the (empty) options map as -Options.
    $vm | Invoke-XenVM -XenAction AssertCanBootHere -XenHost $destHost
    $vm | Invoke-XenVM -XenAction PoolMigrate -XenHost $destHost -Options @{}  # @{} = default live migration

    Write-Host "Migrated to:      $((Get-XenHost -Ref (Get-XenVM -Ref $ref).resident_on).name_label)"
    Write-Host "Still running:    $((Get-XenVM -Ref $ref).power_state)"

    # Tidy up so the example is repeatable.
    $vm | Invoke-XenVM -XenAction HardShutdown
    $vm | Remove-XenVM
    Write-Host "OK: live-migrate"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-LiveMigrate -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 11. Enter & exit maintenance mode -------------------------------------------------
function Invoke-HostMaintenance {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-maint"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Choose a host that is not the pool coordinator, so the coordinator can receive its guests.
    $masterRef = (Get-XenPool | Select-Object -First 1).master.opaque_ref
    $xenHost = Get-XenHost | Where-Object { $_.opaque_ref -ne $masterRef } | Select-Object -First 1
    Write-Host "Maintenance host: $($xenHost.name_label)"

    # Pin a running VM to that host so evacuation has something to move.
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $vm | Invoke-XenVM -XenAction Provision
    $ref = $vm.opaque_ref
    $vm | Set-XenVM -Affinity $xenHost
    $vm | Invoke-XenVM -XenAction Start
    Write-Host "Guest resident on:$((Get-XenHost -Ref (Get-XenVM -Ref $ref).resident_on).name_label)"

    # Enter maintenance mode: disable the host, then evacuate its guests.
    $xenHost | Invoke-XenHost -XenAction Disable
    Write-Host "After disable:    host.enabled = $((Get-XenHost -Ref $xenHost.opaque_ref).enabled)"
    $xenHost | Invoke-XenHost -XenAction Evacuate
    Write-Host "After evacuate:   guest now on $((Get-XenHost -Ref (Get-XenVM -Ref $ref).resident_on).name_label)"

    # Exit maintenance mode.
    $xenHost | Invoke-XenHost -XenAction Enable
    Write-Host "After enable:     host.enabled = $((Get-XenHost -Ref $xenHost.opaque_ref).enabled)"

    # Tidy up so the example is repeatable.
    $vm | Invoke-XenVM -XenAction HardShutdown
    $vm | Remove-XenVM
    Write-Host "OK: host-maintenance"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-HostMaintenance -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 12. Configure high availability ---------------------------------------------------
function Invoke-ConfigureHa {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$HeartbeatSrName
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1

    # The HA heartbeat statefile needs a shared SR. Confirm the chosen SR can host it.
    $sr = Get-XenSR -Name $HeartbeatSrName | Where-Object { $_.shared } | Select-Object -First 1
    if (-not $sr) { throw "No shared SR named '$HeartbeatSrName' was found." }
    Write-Host "Heartbeat SR:  $($sr.name_label)"
    $sr | Invoke-XenSR -XenAction AssertCanHostHaStatefile

    # How many host failures can the pool tolerate? Set that as the target and enable HA.
    # (An empty hashtable = no per-VM restart-priority overrides.)
    $ntol = $pool | Invoke-XenPool -XenAction HaComputeHypotheticalMaxHostFailuresToTolerate -Configuration @{} -PassThru
    Write-Host "Max failures:  $ntol"
    $pool | Set-XenPool -HaHostFailuresToTolerate $ntol

    $pool | Invoke-XenPool -XenAction EnableHa -HeartbeatSrs @($sr) -Configuration @{}
    Write-Host "HA enabled:    $((Get-XenPool | Select-Object -First 1).ha_enabled)"

    # What HA does per VM. The restart priority decides which guests come back first after a host
    # failure, and whether a VM is protected at all; "restart" is protected, an empty string is not.
    $guest = Get-XenVM | Where-Object {
        -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot
    } | Select-Object -First 1
    $was = $guest.ha_restart_priority
    $guest | Set-XenVM -HaRestartPriority "restart"
    $nowPriority = (Get-XenVM -Ref $guest.opaque_ref).ha_restart_priority
    Write-Host "$($guest.name_label) priority: '$was' -> '$nowPriority'"
    $guest | Set-XenVM -HaRestartPriority $was

    # And a pool-wide judgement call: if a guest shuts itself down from the inside, is that a failure
    # HA should undo, or an administrator's intent it should respect?
    $internal = (Get-XenPool -Ref $pool.opaque_ref).ha_reboot_vm_on_internal_shutdown
    Write-Host "Restart on internal shutdown: $internal"

    # Turn HA back off so the example is repeatable.
    $pool | Invoke-XenPool -XenAction DisableHa
    Write-Host "HA enabled:    $((Get-XenPool | Select-Object -First 1).ha_enabled)"
    Write-Host "OK: configure-ha"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigureHa -Url https://xenserver -UserName root -Password $password -HeartbeatSrName 'Shared NFS'

# --- 13. Copy a VM ---------------------------------------------------------------------
function Invoke-CopyVm {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $true)][string]$SrName,
        [string]$CopyName = "sdk-example-copy"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # A full copy needs a halted source; copy places an independent set of disks on the chosen SR.
    $source = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain } | Select-Object -First 1
    if (-not $source) { throw "No VM named '$VmName' was found." }
    $sr = Get-XenSR -Name $SrName | Select-Object -First 1
    if (-not $sr) { throw "No SR named '$SrName' was found." }
    Write-Host "Copying '$($source.name_label)' to SR: $($sr.name_label)"

    $copy = $source | Invoke-XenVM -XenAction Copy -NewName $CopyName -SR $sr -PassThru
    Write-Host "Copied VM:     $($copy.uuid)"
    Write-Host "Copy has $(@($copy.VBDs).Count) VBD(s), is_a_template = $($copy.is_a_template)"

    # Tidy up: gather the copy's owned disks, destroy the copy (which leaves VDIs behind), then destroy
    # those disks - leaving the source VM intact.
    $copyVdis = (Get-XenVM -Ref $copy.opaque_ref).VBDs |
        ForEach-Object { Get-XenVBD -Ref $_.opaque_ref } |
        Where-Object { $_.type -eq 'Disk' } |
        ForEach-Object { $_.VDI.opaque_ref }
    $copy | Remove-XenVM
    $copyVdis | ForEach-Object { Remove-XenVDI -Ref $_ }
    Write-Host "Cleaned up the copied VM (left the source intact)."
    Write-Host "OK: copy-vm"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CopyVm -Url https://xenserver -UserName root -Password $password -VmName 'db-01' -SrName 'Shared NFS'


# --- 14. Create a VM with a vGPU ------------------------------------------------------
function Invoke-CreateVmWithVgpu {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-vgpu-vm"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Find a GPU group that offers a real (non-passthrough) vGPU type, plus that type.
    $group = $null; $vgpuType = $null
    foreach ($g in Get-XenGPUGroup) {
        if (-not $g.PGPUs) { continue }
        foreach ($tRef in $g.supported_VGPU_types) {
            $t = Get-XenVGPUType -Ref $tRef
            if ($t.model_name -ne 'passthrough') { $group = $g; $vgpuType = $t; break }
        }
        if ($vgpuType) { break }
    }
    if (-not $vgpuType) { throw "No GPU group offers a vGPU type." }
    Write-Host "Using vGPU type: $($vgpuType.model_name) ($([int]($vgpuType.framebuffer_size / 1MB)) MB framebuffer)"

    # Provision a fresh VM from the template to attach the vGPU to.
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $vm | Invoke-XenVM -XenAction Provision

    # Assign the vGPU: device "0" is the VM's first vGPU slot, other_config is empty. Same call as
    # XenCenter's New VM wizard GPU page and the VM Properties GPU page.
    $vgpu = New-XenVGPU -VM $vm.opaque_ref -GPUGroup $group.opaque_ref -Device "0" -OtherConfig @{} -Type $vgpuType.opaque_ref -PassThru
    Write-Host "Created vGPU: $($vgpu.uuid)"

    # Read the assignment back, as XenCenter's GPU tab does.
    $assignedVm = Get-XenVM -Ref $vm.opaque_ref
    $assigned = (Get-XenVGPUType -Ref (Get-XenVGPU -Ref $assignedVm.VGPUs[0]).type).model_name
    Write-Host "VM now has $($assignedVm.VGPUs.Count) vGPU(s); type = $assigned"

    # Tidy up so the example is repeatable.
    $vgpu | Remove-XenVGPU
    $vm | Remove-XenVM
    Write-Host "Cleaned up the example VM and its vGPU."

    Write-Host "OK: create-vm-with-vgpu"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CreateVmWithVgpu -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 15. Tag and organize objects -----------------------------------------------------
function Invoke-TagsAndFolders {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain } | Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }
    $vmHost = Get-XenHost | Select-Object -First 1

    # Tags work on any object type (VM, host, SR, network, …): Add-Xen* appends a tag, the matching
    # Remove-Xen*Property drops it.
    $vm | Add-XenVM -Tags "web"
    $vmHost | Add-XenHost -Tags "gold"
    Write-Host "VM tags:   $((Get-XenVM -Ref $vm.opaque_ref).tags -join ', ')"
    Write-Host "Host tags: $((Get-XenHost -Ref $vmHost.opaque_ref).tags -join ', ')"

    # Folder placement lives in other_config["folder"] as a leading-slash path; merge it into the map.
    $current = $vm.other_config
    $oc = @{}
    foreach ($k in $current.Keys) { $oc[$k] = $current[$k] }
    $oc["folder"] = "/Production/Web"
    $vm | Set-XenVM -OtherConfig $oc
    Write-Host "VM folder: $((Get-XenVM -Ref $vm.opaque_ref).other_config['folder'])"

    # Tidy up.
    $vm | Remove-XenVMProperty -Tags "web"
    $vmHost | Remove-XenHostProperty -Tags "gold"
    $vm | Remove-XenVMProperty -OtherConfig "folder"
    Write-Host "OK: tags-and-folders"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-TagsAndFolders -Url https://xenserver -UserName root -Password $password -VmName 'web-01'

# --- 16. Configure updates (CDN) ------------------------------------------------------
function Invoke-ConfigureUpdates {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Repository.introduce is a static-style create, so pass the NULL ref for the (ignored) instance param.
    $repo = Invoke-XenRepository -Ref 'OpaqueRef:NULL' -XenAction Introduce -NameLabel 'sdk-cdn' `
        -NameDescription 'SDK example repository' -BinaryUrl 'https://cdn.example/base' `
        -SourceUrl 'https://cdn.example/source' -Update $false -GpgkeyPath '' -PassThru
    Write-Host "Introduced repository: $($repo.name_label)"

    $pool = Get-XenPool | Select-Object -First 1
    $pool | Set-XenPool -Repositories @($repo.opaque_ref)
    $pool | Set-XenPool -UpdateSyncEnabled $true
    $p = Get-XenPool -Ref $pool.opaque_ref
    Write-Host "Pool repositories: $($p.repositories.Count); auto-sync enabled: $($p.update_sync_enabled)"

    # Tidy up so the example is repeatable.
    $pool | Set-XenPool -UpdateSyncEnabled $false
    $pool | Set-XenPool -Repositories @()
    $repo | Invoke-XenRepository -XenAction Forget
    Write-Host "OK: configure-updates"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigureUpdates -Url https://xenserver -UserName root -Password $password

# --- 17. Clone a VM (fast, copy-on-write) ---------------------------------------------
function Invoke-CloneVm {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName,
        [string]$CloneName = "sdk-example-clone"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Unlike Copy (a full, independent copy onto a chosen SR), Clone is a fast copy-on-write
    # duplicate on the same SR - ideal for a halted "golden" VM.
    $source = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot } |
        Select-Object -First 1
    if (-not $source) { throw "No VM named '$VmName' was found." }

    $clone = $source | Invoke-XenVM -XenAction Clone -NewName $CloneName -PassThru
    Write-Host "Cloned '$($source.name_label)' -> $($clone.name_label)"
    Write-Host "Clone has $(@($clone.VBDs).Count) VBD(s)"

    # Tidy up: gather the clone's owned disks, destroy the clone, then destroy the disks.
    $cloneVdis = (Get-XenVM -Ref $clone.opaque_ref).VBDs |
        ForEach-Object { Get-XenVBD -Ref $_.opaque_ref } |
        Where-Object { $_.type -eq 'Disk' } |
        ForEach-Object { $_.VDI.opaque_ref }
    $clone | Remove-XenVM
    $cloneVdis | ForEach-Object { Remove-XenVDI -Ref $_ }
    Write-Host "OK: clone-vm"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CloneVm -Url https://xenserver -UserName root -Password $password -VmName 'db-01'

# --- 18. Delete a VM ------------------------------------------------------------------
function Invoke-DeleteVm {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-delete"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Make a throwaway VM to delete. Remove-XenVM removes the VM but leaves its disks, so the owned
    # VDIs are destroyed explicitly afterward - exactly what XenCenter's Delete VM does.
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $vm | Invoke-XenVM -XenAction Provision
    $uuid = (Get-XenVM -Ref $vm.opaque_ref).uuid

    $vdis = (Get-XenVM -Ref $vm.opaque_ref).VBDs |
        ForEach-Object { Get-XenVBD -Ref $_.opaque_ref } |
        Where-Object { $_.type -eq 'Disk' } |
        ForEach-Object { $_.VDI.opaque_ref }
    Write-Host "Deleting VM $uuid with $(@($vdis).Count) disk(s)"

    $vm | Remove-XenVM
    $vdis | ForEach-Object { Remove-XenVDI -Ref $_ }

    $stillThere = [bool](Get-XenVM | Where-Object { $_.uuid -eq $uuid })
    Write-Host "VM still present: $stillThere"
    Write-Host "OK: delete-vm"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-DeleteVm -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 19. Storage live-migration (move a disk to another SR) ---------------------------
function Invoke-StorageMigrate {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-storagemigrate"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Provision a VM so it has a disk to relocate, note the disk's current SR.
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $vm | Invoke-XenVM -XenAction Provision
    $ref = $vm.opaque_ref

    $vdiRef = (Get-XenVM -Ref $ref).VBDs |
        ForEach-Object { Get-XenVBD -Ref $_.opaque_ref } |
        Where-Object { $_.type -eq 'Disk' } |
        ForEach-Object { $_.VDI.opaque_ref } |
        Select-Object -First 1
    $sourceSr = (Get-XenVDI -Ref $vdiRef).SR.opaque_ref
    Write-Host "Disk is on SR: $((Get-XenSR -Ref $sourceSr).name_label)"

    # Pick a different SR that can hold a VDI and move the disk there (live storage migration).
    $destSr = Get-XenSR |
        Where-Object { $_.opaque_ref -ne $sourceSr -and $_.type -notin @('iso', 'udev') } |
        Select-Object -First 1

    # Move the disk to the other SR (live storage migration). The target SR and options are action-
    # specific parameters of Invoke-XenVDI -XenAction PoolMigrate.
    Get-XenVDI -Ref $vdiRef | Invoke-XenVDI -XenAction PoolMigrate -SR $destSr -Options @{}

    $nowOn = (Get-XenVDI -Ref $vdiRef).SR.opaque_ref
    Write-Host "Disk moved to:  $((Get-XenSR -Ref $nowOn).name_label)"

    # Tidy up.
    $vm | Remove-XenVM
    Remove-XenVDI -Ref $vdiRef
    Write-Host "OK: storage-migrate"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-StorageMigrate -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 20. Apply updates from the CDN --------------------------------------------------
function Invoke-ApplyUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Sync the pool's update metadata from the CDN; -PassThru returns the hash identifying the synced set.
    $pool = Get-XenPool | Select-Object -First 1
    $hash = $pool | Invoke-XenPool -XenAction SyncUpdates -PassThru
    Write-Host "Synced updates; hash length $($hash.Length)"

    # Apply the synced updates to each host (the hash is the action's -Hash parameter). XenCenter then
    # reads the reboot guidance to decide whether a Rolling Pool Upgrade reboot is needed.
    foreach ($xenHost in Get-XenHost) {
        $xenHost | Invoke-XenHost -XenAction ApplyUpdates -Hash $hash
        $guidance = (Get-XenHost -Ref $xenHost.opaque_ref).pending_guidances -join ", "
        Write-Host "  $($xenHost.name_label): applied; pending guidance = [$guidance]"
    }
    Write-Host "OK: apply-update"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ApplyUpdate -Url https://xenserver -UserName root -Password $password

# --- 21. Checkpoint & revert ---------------------------------------------------------
function Invoke-CheckpointVm {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-checkpoint"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # A checkpoint captures disk AND memory (unlike a plain snapshot), so the VM must be running.
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $vm | Invoke-XenVM -XenAction Provision
    $ref = $vm.opaque_ref
    $vm | Invoke-XenVM -XenAction Start

    $checkpoint = $vm | Invoke-XenVM -XenAction Checkpoint -NewName "sdk-example-checkpoint-1" -PassThru
    Write-Host "Created checkpoint: $($checkpoint.uuid)"
    Write-Host "is_a_snapshot = $($checkpoint.is_a_snapshot)"

    $vm | Invoke-XenVM -XenAction Revert -Snapshot $checkpoint
    Write-Host "Reverted the VM to the checkpoint."

    # Tidy up.
    $checkpoint | Remove-XenVM
    if ((Get-XenVM -Ref $ref).power_state -eq 'Running') { $vm | Invoke-XenVM -XenAction HardShutdown }
    $vm | Remove-XenVM
    Write-Host "OK: checkpoint-vm"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CheckpointVm -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 22. Attach a new disk to a VM ---------------------------------------------------
function Invoke-AttachDisk {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [Parameter(Mandatory = $true)][string]$SrName,
        [string]$NewVmName = "sdk-example-attachdisk"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $vm | Invoke-XenVM -XenAction Provision
    $ref = $vm.opaque_ref
    $sr = Get-XenSR -Name $SrName | Select-Object -First 1
    if (-not $sr) { throw "No SR named '$SrName' was found." }

    # Create a fresh VDI on the SR and attach it as a new VBD (a new virtual disk).
    $vdi = New-XenVDI -NameLabel "sdk-example-data-disk" -SR $sr -VirtualSize 8GB `
        -Type user -Sharable $false -ReadOnly $false -PassThru
    $device = (Get-XenVMProperty -Ref $ref -XenProperty AllowedVBDDevices)[0]
    New-XenVBD -VM (Get-XenVM -Ref $ref) -VDI $vdi -Userdevice $device `
        -Mode RW -Type Disk -Empty $false | Out-Null
    Write-Host "Attached an 8 GiB disk on $($sr.name_label) as device $device"
    Write-Host "VM now has $(@((Get-XenVM -Ref $ref).VBDs).Count) VBD(s)"

    # Tidy up: gather the owned disks first, then destroy the VM (which removes its VBDs), then
    # destroy the disks (Remove-XenVM leaves VDIs behind).
    $owned = (Get-XenVM -Ref $ref).VBDs |
        ForEach-Object { Get-XenVBD -Ref $_.opaque_ref } |
        Where-Object { $_.type -eq 'Disk' } |
        ForEach-Object { $_.VDI.opaque_ref }
    $vm | Remove-XenVM
    $owned | ForEach-Object { Remove-XenVDI -Ref $_ }
    Write-Host "OK: attach-disk"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-AttachDisk -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8' -SrName 'Shared NFS'

# --- 23. Drive an asynchronous task --------------------------------------------------
function Invoke-WaitForTask {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-asynctask"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Every action has an -Async twin that returns a Task ref immediately; here we poll it by hand to
    # read the progress percentage (Wait-XenTask -ShowProgress, as vm-lifecycle uses, does this for you).
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $task = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -Async -PassThru
    $taskRef = $task.opaque_ref
    Write-Host "Started task: $((Get-XenTask -Ref $taskRef).uuid)"

    while ((Get-XenTask -Ref $taskRef).status -eq 'Pending') {
        Write-Host "  progress: $([int]((Get-XenTask -Ref $taskRef).progress * 100))%"
        Start-Sleep -Milliseconds 200
    }
    Write-Host "Task status: $((Get-XenTask -Ref $taskRef).status)"

    # The result of an object-creating task is <value>OpaqueRef:...</value>.
    $result = (Get-XenTask -Ref $taskRef).result
    $vmRef = $result.Replace("<value>", "").Replace("</value>", "").Trim()
    Write-Host "Task produced VM: $((Get-XenVM -Ref $vmRef).name_label)"

    # Tidy up.
    Get-XenVM -Ref $vmRef | Remove-XenVM
    Get-XenTask -Ref $taskRef | Remove-XenTask
    Write-Host "OK: wait-for-task"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-WaitForTask -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 24. Handle an API error ---------------------------------------------------------
function Invoke-ErrorHandling {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # XenAPI errors surface as a failure whose ErrorDescription is [CODE, param1, param2, ...]. Any
    # cmdlet that reaches the server can raise one - here we deliberately act on a VM UUID that doesn't
    # exist. The module may wrap the failure, so walk the InnerException chain to the ErrorDescription.
    try {
        Set-XenVM -Uuid (New-Guid).Guid -NameLabel "will-not-apply"
        Write-Host "unexpected: no error"
    }
    catch {
        $ex = $_.Exception
        while ($ex -and -not $ex.ErrorDescription) { $ex = $ex.InnerException }
        if ($ex -and $ex.ErrorDescription) { Write-Host "Caught expected failure: $($ex.ErrorDescription[0])" }
        else { Write-Host "Caught expected failure: $($_.Exception.Message)" }
    }
    Write-Host "OK: error-handling"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ErrorHandling -Url https://xenserver -UserName root -Password $password

# --- 25. List templates --------------------------------------------------------------
function Invoke-ListTemplates {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $templates = Get-XenVM | Where-Object { $_.is_a_template } | Sort-Object name_label
    Write-Host "Templates ($(@($templates).Count)):"
    $templates | Select-Object -First 8 | ForEach-Object {
        $suffix = if ($_.other_config.ContainsKey("default_template")) { " [built-in]" } else { "" }
        Write-Host "  - $($_.name_label)$suffix"
    }
    Write-Host "OK: list-templates"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ListTemplates -Url https://xenserver -UserName root -Password $password

# --- 26. Custom fields ---------------------------------------------------------------
function Invoke-CustomFields {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # XenCenter's custom fields are stored in other_config under "XenCenter.CustomFields.<name>".
    # Set-XenVM -OtherConfig replaces the whole map, so merge the field into a copy; Remove-XenVMProperty
    # -OtherConfig then drops it again by key.
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain } | Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }
    $key = "XenCenter.CustomFields.Owner"

    $current = $vm.other_config
    $oc = @{}
    foreach ($k in $current.Keys) { $oc[$k] = $current[$k] }
    $oc[$key] = "Platform Team"
    $vm | Set-XenVM -OtherConfig $oc
    Write-Host "Custom field Owner = $((Get-XenVM -Ref $vm.opaque_ref).other_config[$key])"

    $vm | Remove-XenVMProperty -OtherConfig $key
    Write-Host "OK: custom-fields"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CustomFields -Url https://xenserver -UserName root -Password $password -VmName 'web-01'

# --- 27. GPU inventory ---------------------------------------------------------------
function Invoke-GpuInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $groups = Get-XenGPUGroup
    Write-Host "GPU groups ($(@($groups).Count)):"
    foreach ($group in $groups) {
        $types = $group.supported_VGPU_types | ForEach-Object { (Get-XenVGPUType -Ref $_).model_name }
        Write-Host "  - $($group.name_label): $(@($group.PGPUs).Count) pGPU(s), vGPU types: $($types -join ', ')"
    }
    # How the pool spreads vGPUs across the physical GPUs in a group: depth-first packs each pGPU full
    # before using the next, breadth-first spreads them out.
    $group = $groups | Select-Object -First 1
    $before = $group.allocation_algorithm
    $group | Set-XenGPUGroup -AllocationAlgorithm breadth_first
    $after = (Get-XenGPUGroup -Ref $group.opaque_ref).allocation_algorithm
    Write-Host "Allocation:      $before -> $after"
    $group | Set-XenGPUGroup -AllocationAlgorithm $before
    Write-Host "OK: gpu-inventory"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-GpuInventory -Url https://xenserver -UserName root -Password $password

# --- 28. Read host & VM metrics ------------------------------------------------------
function Invoke-ReadMetrics {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    $hm = Get-XenHostMetrics -Ref $xenHost.metrics.opaque_ref
    Write-Host ("Host $($xenHost.name_label): " +
        "$([long]($hm.memory_total / 1MB)) MiB total, " +
        "$([long](($xenHost | Invoke-XenHost -XenAction ComputeFreeMemory -PassThru) / 1MB)) MiB free, " +
        "live = $($hm.live)")

    $vm = Get-XenVM |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and $_.power_state -eq 'Running' } |
        Select-Object -First 1
    $vmm = Get-XenVMMetrics -Ref $vm.metrics.opaque_ref
    Write-Host ("VM $($vm.name_label): " +
        "$($vmm.VCPUs_number) vCPU(s), $([long]($vmm.memory_actual / 1MB)) MiB")
    Write-Host "OK: read-metrics"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ReadMetrics -Url https://xenserver -UserName root -Password $password

# --- 29. Rename an object ------------------------------------------------------------
function Invoke-RenameObject {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot } |
        Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }
    $original = $vm.name_label

    $vm | Set-XenVM -NameLabel "sdk-renamed"
    Write-Host "Renamed '$original' -> '$((Get-XenVM -Ref $vm.opaque_ref).name_label)'"

    $vm | Set-XenVM -NameLabel $original  # restore so the example is repeatable
    Write-Host "OK: rename-object"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-RenameObject -Url https://xenserver -UserName root -Password $password -VmName 'web-01'

# --- 30. VM boot configuration -------------------------------------------------------
function Invoke-VmBootConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-boot"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $vm | Invoke-XenVM -XenAction Provision
    $ref = $vm.opaque_ref

    # Set the vCPU topology and switch the VM to UEFI Secure Boot: firmware ("bios"/"uefi") lives in
    # HVM_boot_params, Secure Boot in platform["secureboot"] (what the New VM wizard sets for a
    # UEFI-capable template).
    $vm | Set-XenVM -VCPUsMax 4 -VCPUsAtStartup 2 -HVMBootParams @{ order = "cdn"; firmware = "uefi" }
    $platform = (Get-XenVM -Ref $ref).platform
    $platform["secureboot"] = "true"
    $vm | Set-XenVM -Platform $platform

    $configured = Get-XenVM -Ref $ref
    Write-Host "vCPUs: $($configured.VCPUs_at_startup)/$($configured.VCPUs_max)"
    Write-Host "Boot order: $($configured.HVM_boot_params['order'])"
    Write-Host "Boot mode: firmware=$($configured.HVM_boot_params['firmware']), secureboot=$($configured.platform['secureboot'])"

    $vm | Remove-XenVM
    Write-Host "OK: vm-boot-config"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-VmBootConfig -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 31. Host information ------------------------------------------------------------
function Invoke-HostInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    $sw = $xenHost.software_version
    $cpu = $xenHost.cpu_info
    $pv = if ($sw.ContainsKey("product_version")) { $sw["product_version"] } else { "?" }
    $cc = if ($cpu.ContainsKey("cpu_count")) { $cpu["cpu_count"] } else { "?" }
    $sc = if ($cpu.ContainsKey("socket_count")) { $cpu["socket_count"] } else { "?" }
    Write-Host "Host:     $($xenHost.name_label)"
    Write-Host "Version:  $pv"
    Write-Host "Edition:  $($xenHost.edition)"
    Write-Host "CPUs:     $cc across $sc socket(s)"
    # The physical identity, straight off the host's DMI/SMBIOS tables. The serial number is what you
    # quote to the hardware vendor, so it identifies this machine and not just its model.
    $bios = $xenHost.bios_strings
    Write-Host "Hardware: $($bios['system-manufacturer']) $($bios['system-product-name'])"
    Write-Host "Serial:   $($bios['system-serial-number'])"
    Write-Host "BIOS:     $($bios['bios-version'])"
    Write-Host "OK: host-info"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-HostInfo -Url https://xenserver -UserName root -Password $password

# --- 32. List roles -----------------------------------------------------------------
function Invoke-ListRoles {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Role is the one class XenCenter still bulk-downloads; RBAC subjects map to these roles.
    $roles = Get-XenRole | Select-Object -ExpandProperty name_label -Unique | Sort-Object
    Write-Host "Roles ($(@($roles).Count)): $(($roles | Select-Object -First 8) -join ', ')"
    Write-Host "OK: list-roles"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ListRoles -Url https://xenserver -UserName root -Password $password

# --- 33. Pool properties ------------------------------------------------------------
function Invoke-PoolProperties {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1
    $original = $pool.name_label
    $defaultSr = $pool.default_SR.opaque_ref
    $srName = if ($defaultSr -eq "OpaqueRef:NULL") { "(none)" } else { (Get-XenSR -Ref $defaultSr).name_label }
    Write-Host "Pool:       '$original'"
    Write-Host "Default SR: $srName"

    $pool | Set-XenPool -NameLabel "sdk-pool-renamed"
    Write-Host "Renamed to: '$((Get-XenPool -Ref $pool.opaque_ref).name_label)'"

    $pool | Set-XenPool -NameLabel $original  # restore
    Write-Host "OK: pool-properties"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-PoolProperties -Url https://xenserver -UserName root -Password $password

# --- 34. Storage repository usage ---------------------------------------------------
function Invoke-SrUsage {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    Get-XenSR | Sort-Object name_label | Where-Object { $_.physical_size -gt 0 } | ForEach-Object {
        $used = [long]($_.physical_utilisation / 1GB)
        $total = [long]($_.physical_size / 1GB)
        Write-Host "  $($_.name_label): $used / $total GiB used"
    }
    # A rescan refreshes an SR's utilisation from its backend.
    $scanMe = Get-XenSR | Where-Object { $_.physical_size -gt 0 } | Select-Object -First 1
    $scanMe | Invoke-XenSR -XenAction Scan

    # Read caching keeps recently-read blocks in the host's memory. It is switched off per SR by
    # setting o_direct, which asks the storage layer to bypass the cache entirely. Add-XenSR appends
    # one other_config entry as a KeyValuePair; Remove-XenSRProperty drops it again by key.
    $scanMe | Remove-XenSRProperty -OtherConfig "o_direct"
    $scanMe | Add-XenSR -OtherConfig ([System.Collections.Generic.KeyValuePair[string, string]]::new("o_direct", "true"))
    $cachingOff = (Get-XenSR -Ref $scanMe.opaque_ref).other_config["o_direct"] -eq "true"
    Write-Host "  read caching on $($scanMe.name_label): $(if ($cachingOff) { 'off' } else { 'on' })"
    $scanMe | Remove-XenSRProperty -OtherConfig "o_direct"
    Write-Host "OK: sr-usage"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-SrUsage -Url https://xenserver -UserName root -Password $password

# --- 35. Manage a VM's network interfaces -------------------------------------------
function Invoke-ManageVif {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-vif"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $vm | Invoke-XenVM -XenAction Provision
    $ref = $vm.opaque_ref

    $net = Get-XenNetwork | Select-Object -First 1
    $device = (Get-XenVMProperty -Ref $ref -XenProperty AllowedVIFDevices)[0]

    $vif = New-XenVIF -VM (Get-XenVM -Ref $ref) -Network $net -Device $device -MAC "" -MTU 1500 -PassThru
    Write-Host "Attached a VIF on device $device; VM now has $(@((Get-XenVM -Ref $ref).VIFs).Count) NIC(s)"

    $vif | Remove-XenVIF
    $vm | Remove-XenVM
    Write-Host "OK: manage-vif"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ManageVif -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 36. List networks --------------------------------------------------------------
function Invoke-ListNetworks {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $nets = Get-XenNetwork | Sort-Object name_label
    Write-Host "Networks ($(@($nets).Count)):"
    $nets | ForEach-Object {
        Write-Host "  - $($_.name_label): $(@($_.PIFs).Count) PIF(s), $(@($_.VIFs).Count) VIF(s)"
    }
    Write-Host "OK: list-networks"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ListNetworks -Url https://xenserver -UserName root -Password $password

# --- 37. Inventory a VM's disks -----------------------------------------------------
function Invoke-VbdInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot } |
        Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }
    Write-Host "Disks of '$($vm.name_label)':"
    (Get-XenVM -Ref $vm.opaque_ref).VBDs |
        ForEach-Object { Get-XenVBD -Ref $_.opaque_ref } |
        Where-Object { $_.type -eq 'Disk' } |
        ForEach-Object {
            $vdiRef = $_.VDI.opaque_ref
            $size = if ($vdiRef -eq 'OpaqueRef:NULL') { 0 } else { [long]((Get-XenVDI -Ref $vdiRef).virtual_size / 1GB) }
            Write-Host "  - device $($_.userdevice): $size GiB"
        }
    Write-Host "OK: vbd-inventory"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-VbdInventory -Url https://xenserver -UserName root -Password $password -VmName 'db-01'

# --- 38. Tag the pool ---------------------------------------------------------------
function Invoke-PoolTags {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Add-XenPool -Tags appends a tag; the pool's current tags are just its .tags property; and
    # Remove-XenPoolProperty -Tags drops one again.
    $pool = Get-XenPool | Select-Object -First 1
    $pool | Add-XenPool -Tags "sdk-managed"
    Write-Host "Pool tags: $((Get-XenPool -Ref $pool.opaque_ref).tags -join ', ')"
    $pool | Remove-XenPoolProperty -Tags "sdk-managed"
    Write-Host "OK: pool-tags"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-PoolTags -Url https://xenserver -UserName root -Password $password

# --- 39. Convert a VM to a template -------------------------------------------------
function Invoke-ConvertToTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [string]$NewVmName = "sdk-example-totemplate"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $template = Get-XenVM -Name $TemplateName | Where-Object { $_.is_a_template } | Select-Object -First 1
    if (-not $template) { throw "No template named '$TemplateName' was found." }
    $vm = $template | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    $vm | Invoke-XenVM -XenAction Provision  # now a real (halted) VM
    $ref = $vm.opaque_ref
    Write-Host "is_a_template after provision: $((Get-XenVM -Ref $ref).is_a_template)"

    # Converting a VM to a custom template is a one-way operation.
    $vm | Set-XenVM -IsATemplate $true
    Write-Host "is_a_template after convert:  $((Get-XenVM -Ref $ref).is_a_template)"

    $vm | Remove-XenVM
    Write-Host "OK: convert-to-template"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConvertToTemplate -Url https://xenserver -UserName root -Password $password -TemplateName 'Rocky Linux 8'

# --- 40. Look up an object by UUID --------------------------------------------------
function Invoke-FindByUuid {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # UUIDs are stable identifiers you can persist and resolve back to a (session-scoped) ref.
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot } |
        Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }
    $uuid = $vm.uuid

    $resolved = Get-XenVM -Uuid $uuid
    Write-Host "UUID $uuid resolves to $($resolved.name_label)"
    Write-Host "Same object: $($resolved.opaque_ref -eq $vm.opaque_ref)"
    Write-Host "OK: find-by-uuid"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-FindByUuid -Url https://xenserver -UserName root -Password $password -VmName 'web-01'

# --- 41. Rolling pool update --------------------------------------------------------------------------
function Invoke-RollingPoolUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1
    $hash = $pool | Invoke-XenPool -XenAction SyncUpdates -PassThru
    Write-Host "Synced updates; hash length $($hash.Length)"

    # The rolling pattern behind XenCenter's automated Install Updates:
    # disable -> evacuate -> apply -> reboot -> re-enable, one host at a time.
    foreach ($xenHost in Get-XenHost) {
        Write-Host "Updating $($xenHost.name_label):"
        $xenHost | Invoke-XenHost -XenAction Disable    # stop new VMs landing here
        $xenHost | Invoke-XenHost -XenAction Evacuate   # move running guests to the rest of the pool
        $xenHost | Invoke-XenHost -XenAction ApplyUpdates -Hash $hash
        $guidance = (Get-XenHost -Ref $xenHost.opaque_ref).pending_guidances -join ", "
        Write-Host "  applied; pending guidance = [$guidance]"
        $xenHost | Invoke-XenHost -XenAction Reboot     # reboot into the updated software
        $xenHost | Invoke-XenHost -XenAction Enable     # return the host to service
    }
    Write-Host "OK: rolling-pool-update"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-RollingPoolUpdate -Url https://xenserver -UserName root -Password $password

# --- 42. Cross-pool copy a VM -------------------------------------------------------------------------
function Invoke-CrossPoolCopyVm {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$DestUrl,
        [string]$VmName = "db-01"
    )
    # Two pools, so two sessions. Every cmdlet takes -SessionOpaqueRef, so we drive each pool explicitly
    # (Connect-Example sets a default session too, but being explicit keeps the two pools apart).
    $source = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $dest = Connect-Example -Url $DestUrl -UserName $UserName -Password $Password
    $srcRef = $source.opaque_ref
    $dstRef = $dest.opaque_ref

    # Destination: choose a host, network and SR, then ask for a receiver token (a string->string map).
    $destHost = Get-XenHost -SessionOpaqueRef $dstRef | Select-Object -First 1
    $destNet = Get-XenNetwork -SessionOpaqueRef $dstRef | Select-Object -First 1
    $destSr = Get-XenSR -SessionOpaqueRef $dstRef -Name "Shared NFS" | Select-Object -First 1
    $receiver = $destHost | Invoke-XenHost -SessionOpaqueRef $dstRef -XenAction MigrateReceive `
        -Network $destNet -Options @{} -PassThru

    # Source: find the VM, then map every disk to the destination SR and every NIC to the destination
    # network. migrate_send's maps are strongly-typed (source XenRef -> destination XenRef) dictionaries,
    # so build them as such; ConvertTo-XenRef turns each destination object into the typed ref the values
    # need (the source refs come straight off the VM's .VBDs/.VIFs).
    $vm = Get-XenVM -SessionOpaqueRef $srcRef -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain } | Select-Object -First 1

    $vdiMap = New-Object 'System.Collections.Generic.Dictionary[XenAPI.XenRef[XenAPI.VDI], XenAPI.XenRef[XenAPI.SR]]'
    foreach ($vbdRef in $vm.VBDs) {
        $vbd = Get-XenVBD -SessionOpaqueRef $srcRef -Ref $vbdRef.opaque_ref
        if ($vbd.type -eq 'Disk' -and $vbd.VDI.opaque_ref -ne 'OpaqueRef:NULL') {
            $vdiMap[$vbd.VDI] = ConvertTo-XenRef -XenObject $destSr
        }
    }
    $vifMap = New-Object 'System.Collections.Generic.Dictionary[XenAPI.XenRef[XenAPI.VIF], XenAPI.XenRef[XenAPI.Network]]'
    foreach ($vifRef in $vm.VIFs) { $vifMap[$vifRef] = ConvertTo-XenRef -XenObject $destNet }

    # Send with copy=true (the source VM is left intact). Dest/VdiMap/VifMap/VgpuMap are the migrate_send
    # action's parameters.
    $vm | Invoke-XenVM -SessionOpaqueRef $srcRef -XenAction MigrateSend -Dest $receiver -Live $false `
        -VdiMap $vdiMap -VifMap $vifMap -Options @{ copy = "true" } -VgpuMap @{}

    $stillThere = [bool](Get-XenVM -SessionOpaqueRef $srcRef -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain })
    Write-Host "Sent '$VmName' to the destination pool (copy); source still present: $stillThere"
    Write-Host "OK: cross-pool-copy-vm"
    $source | Disconnect-XenServer
    $dest | Disconnect-XenServer
}
# Run it:
#   Invoke-CrossPoolCopyVm -Url https://poolA -UserName root -Password $password -DestUrl https://poolB

# --- 43. PVS Accelerator inventory ------------------------------------------------------------------
function Invoke-PvsAccelerator {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $sites = @(Get-XenPVSSite)
    if ($sites.Count -eq 0) { Write-Host "No PVS Accelerator sites are configured." }
    foreach ($site in $sites) {
        Write-Host "Site: $($site.name_label)"
        foreach ($csRef in $site.cache_storage) {
            $cs = Get-XenPVSCacheStorage -Ref $csRef.opaque_ref
            $cacheHost = Get-XenHost -Ref $cs.host.opaque_ref
            $sr = Get-XenSR -Ref $cs.SR.opaque_ref
            Write-Host ("  cache:  $($cacheHost.name_label)  $([long]($cs.size / 1GB)) GiB on $($sr.name_label)")
        }
        foreach ($serverRef in $site.servers) {
            $server = Get-XenPVSServer -Ref $serverRef.opaque_ref
            Write-Host ("  server: $($server.addresses -join ', ')  ports $($server.first_port)-$($server.last_port)")
        }
        # Which VMs are accelerated: walk each proxy to its VIF to its VM.
        $accelerated = @{}
        foreach ($proxyRef in $site.proxies) {
            $proxy = Get-XenPVSProxy -Ref $proxyRef.opaque_ref
            $vif = Get-XenVIF -Ref $proxy.VIF.opaque_ref
            $accelerated[$vif.VM.opaque_ref] = $proxy.status
        }
        $guests = Get-XenVM | Where-Object { -not $_.is_control_domain -and -not $_.is_a_template -and -not $_.is_a_snapshot }
        $count = @($guests | Where-Object { $accelerated.ContainsKey($_.opaque_ref) }).Count
        Write-Host "  $count of $(@($guests).Count) VM(s) accelerated"
    }
    Write-Host "OK: pvs-accelerator"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-PvsAccelerator -Url https://xenserver -UserName root -Password $password

# --- 44. Read RRD performance metrics ---------------------------------------------------------------
function Invoke-RrdMetrics {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # The module ships no RRD cmdlet, so read the last 5 minutes of samples from the rrd_updates HTTP API
    # (the module already trusts the server cert). Legends look like "AVERAGE:host:<uuid>:<datasource>".
    $start = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 300
    $resp = Invoke-RestMethod -Uri "$($session.Url)/rrd_updates?session_id=$($session.opaque_ref)&host=true&start=$start" `
        -Headers @{ accept = 'application/json' }
    $legends = @($resp.meta.legend)

    $peak = @{}
    foreach ($point in $resp.data) {
        for ($k = 0; $k -lt $legends.Count; $k++) {
            $parts = $legends[$k] -split ':'
            if ($parts[1] -eq 'host' -and $parts[3] -eq 'pvsaccelerator_space_utilization') {
                $u = [double]$point.values[$k]
                if (-not $peak.ContainsKey($parts[2]) -or $u -gt $peak[$parts[2]]) { $peak[$parts[2]] = $u }
            }
        }
    }
    foreach ($xenHost in Get-XenHost) {
        if ($peak.ContainsKey($xenHost.uuid)) {
            Write-Host ("  {0}: peak PVS cache utilisation {1:N0}%" -f $xenHost.name_label, $peak[$xenHost.uuid])
        }
    }
    Write-Host "OK: rrd-metrics"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-RrdMetrics -Url https://xenserver -UserName root -Password $password

# --- 45. Reclaim freed space on a thin SR -------------------------------------------
function Invoke-ReclaimSpace {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Storage-manager backends that advertise SR_TRIM in their features map are trim-capable.
    $trimTypes = @(Get-XenSM | Where-Object { $_.features.ContainsKey("SR_TRIM") } | ForEach-Object { $_.type })
    $sr = Get-XenSR | Where-Object { $_.physical_size -gt 0 -and $trimTypes -contains $_.type } | Select-Object -First 1
    # A host with a currently-attached PBD can reach the SR to run the plugin.
    $pbd = $sr.PBDs | ForEach-Object { Get-XenPBD -Ref $_ } | Where-Object { $_.currently_attached } | Select-Object -First 1
    $xenHost = Get-XenHost -Ref $pbd.host
    $result = $xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin "trim" -Fn "do_trim" -Args @{ sr_uuid = $sr.uuid } -PassThru
    Write-Host "  reclaimed freed space on $($sr.name_label): $result"
    if ($result -ne "true") { throw "trim plugin returned '$result'" }
    Write-Host "OK: reclaim-space"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ReclaimSpace -Url https://xenserver -UserName root -Password $password

# --- 46. Get a VM's IP address -------------------------------------------------------
function Invoke-VmIpAddress {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # A running guest reports its IP in VM_guest_metrics.networks, keyed "<vif device>/ip".
    $vm = Get-XenVM | Where-Object { $_.power_state -eq 'Running' -and -not $_.is_a_template -and -not $_.is_control_domain -and $_.guest_metrics.opaque_ref -ne 'OpaqueRef:NULL' } | Select-Object -First 1
    $networks = (Get-XenVMGuestMetrics -Ref $vm.guest_metrics).networks
    $ip = if ($networks.ContainsKey("0/ip")) { $networks["0/ip"] } else { "(no address reported)" }
    Write-Host "  $($vm.name_label): $ip"
    Write-Host "OK: vm-ip-address"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-VmIpAddress -Url https://xenserver -UserName root -Password $password

# --- 47. Manage Active Directory users -----------------------------------------------
function Invoke-ManageAdUsers {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # The compiled module's AD cmdlets are awkward to script, so the AD calls go over JSON-RPC (the module
    # already trusts the server cert after Connect) — the same approach as the events example.
    function Rpc([string]$Method, [object[]]$P) {
        $body = @{ jsonrpc = "2.0"; id = 1; method = $Method; params = @($session.opaque_ref) + $P } | ConvertTo-Json -Depth 8
        $r = Invoke-RestMethod -Uri "$($session.Url)/jsonrpc" -Method Post -Body $body -ContentType "application/json"
        if ($r.error) { throw "$Method failed: $($r.error | ConvertTo-Json -Compress)" }
        $r.result
    }

    $pool = (Rpc "pool.get_all" @())[0]
    Rpc "pool.enable_external_auth" @($pool, @{ user = "administrator"; pass = "secret"; ldaps = "false" }, "citrix.local", "AD") | Out-Null
    Write-Host "Joined domain: citrix.local"

    # Add an AD user as a subject and grant it the pool-admin role (found via the Get-XenRole cmdlet).
    $sid = Rpc "auth.get_subject_identifier" @("alice@citrix.local")
    $info = Rpc "auth.get_subject_information_from_identifier" @($sid)
    $subject = Rpc "subject.create" @(@{ subject_identifier = $sid; other_config = $info })
    $role = Get-XenRole | Where-Object { $_.name_label -eq 'pool-admin' -and $_.subroles.Count -gt 0 } | Select-Object -First 1
    Rpc "subject.add_to_roles" @($subject, $role.opaque_ref) | Out-Null
    Write-Host "Added subject $($info.'subject-displayname') ($($info.'subject-name')) as pool-admin"

    # Revoking access does not end sessions the user already has: logging the subject out is a separate
    # act, and the one that actually gets them off the pool now rather than at next login.
    $loggedIn = @(Rpc "session.get_all_subject_identifiers" @())
    Write-Host "Logged-in subjects: $($loggedIn.Count)"
    Rpc "session.logout_subject_identifier" @($sid) | Out-Null
    Write-Host "  logged out $($info.'subject-name')"

    # Tidy up (destroying the subject removes its role assignments).
    Rpc "subject.destroy" @($subject) | Out-Null
    Rpc "pool.disable_external_auth" @($pool, @{}) | Out-Null
    Write-Host "OK: manage-ad-users"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ManageAdUsers -Url https://xenserver -UserName root -Password $password

# --- 48. Create an iSCSI SR ----------------------------------------------------------
function Invoke-CreateIscsiSr {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    # Connect an SR to a LUN on the iSCSI target; create validates + sizes it from the backend LUN.
    $deviceConfig = @{
        target    = "192.0.2.30"
        targetIQN = "iqn.2009-01.com.xenpretender:target-0"
        SCSIid    = "360a980004265656d5f4a2d63764e5734"
    }
    $sr = New-XenSR -XenHost $xenHost -DeviceConfig $deviceConfig -PhysicalSize 0 `
        -NameLabel "sdk-iscsi-sr" -NameDescription "iSCSI SR created by the SDK example" `
        -Type "lvmoiscsi" -ContentType "user" -Shared $true -PassThru
    Write-Host "Created SR: $($sr.uuid) ($([long]($sr.physical_size) / 1GB) GiB)"
    $sr | Invoke-XenSR -XenAction Forget
    Write-Host "OK: create-iscsi-sr"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CreateIscsiSr -Url https://xenserver -UserName root -Password $password

# --- 49. Create an SMB SR ------------------------------------------------------------
function Invoke-CreateSmbSr {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    # Connect a shared SR to an SMB/CIFS file share; create validates + sizes it from the share.
    $deviceConfig = @{
        server     = "192.0.2.40"
        serverpath = "/vmstore"
        username   = "Administrator"
        password   = "Password1"
    }
    $sr = New-XenSR -XenHost $xenHost -DeviceConfig $deviceConfig -PhysicalSize 0 `
        -NameLabel "sdk-smb-sr" -NameDescription "SMB SR created by the SDK example" `
        -Type "smb" -ContentType "user" -Shared $true -PassThru
    Write-Host "Created SR: $($sr.uuid) ($([long]($sr.physical_size) / 1GB) GiB)"
    $sr | Invoke-XenSR -XenAction Forget
    Write-Host "OK: create-smb-sr"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CreateSmbSr -Url https://xenserver -UserName root -Password $password

# --- 50. Create an HBA SR ------------------------------------------------------------
function Invoke-CreateHbaSr {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    # Connect a shared SR to a fibre-channel (HBA) LUN by its SCSI ID.
    $deviceConfig = @{ SCSIid = "360a980004265656d5f4a2d63764e5736" }
    $sr = New-XenSR -XenHost $xenHost -DeviceConfig $deviceConfig -PhysicalSize 0 `
        -NameLabel "sdk-hba-sr" -NameDescription "HBA SR created by the SDK example" `
        -Type "lvmohba" -ContentType "user" -Shared $true -PassThru
    Write-Host "Created SR: $($sr.uuid) ($([long]($sr.physical_size) / 1GB) GiB)"
    $sr | Invoke-XenSR -XenAction Forget
    Write-Host "OK: create-hba-sr"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CreateHbaSr -Url https://xenserver -UserName root -Password $password

# --- 51. Create a GFS2 SR ------------------------------------------------------------
function Invoke-CreateGfs2Sr {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    # Create a shared, thin-provisioned GFS2 SR on a block LUN (here an iSCSI LUN).
    $deviceConfig = @{
        provider  = "iscsi"
        target    = "192.0.2.30"
        targetIQN = "iqn.2009-01.com.xenpretender:target-0"
        SCSIid    = "360a980004265656d5f4a2d63764e5735"
    }
    $sr = New-XenSR -XenHost $xenHost -DeviceConfig $deviceConfig -PhysicalSize 0 `
        -NameLabel "sdk-gfs2-sr" -NameDescription "GFS2 SR created by the SDK example" `
        -Type "gfs2" -ContentType "user" -Shared $true -PassThru
    Write-Host "Created SR: $($sr.uuid) ($([long]($sr.physical_size) / 1GB) GiB)"
    $sr | Invoke-XenSR -XenAction Forget
    Write-Host "OK: create-gfs2-sr"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CreateGfs2Sr -Url https://xenserver -UserName root -Password $password

# --- 52. Create an ISO library SR ----------------------------------------------------
function Invoke-CreateIsoSr {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    # Connect an ISO-library SR to a file share of ISO images (here an NFS export).
    $deviceConfig = @{ location = "192.0.2.10:/isos"; type = "nfs_iso" }
    $sr = New-XenSR -XenHost $xenHost -DeviceConfig $deviceConfig -PhysicalSize 0 `
        -NameLabel "sdk-iso-sr" -NameDescription "ISO library created by the SDK example" `
        -Type "iso" -ContentType "iso" -Shared $true -PassThru
    Write-Host "Created ISO SR: $($sr.uuid)"
    $sr | Invoke-XenSR -XenAction Forget
    Write-Host "OK: create-iso-sr"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CreateIsoSr -Url https://xenserver -UserName root -Password $password

# --- 53. Configure NRPE monitoring ---------------------------------------------------
function Invoke-ConfigureNrpe {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    # Enable the NRPE agent and allow a monitoring host, through the nrpe plugin.
    $before = $xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin nrpe -Fn status -Args @{} -PassThru
    Write-Host "NRPE status before: $($before.Trim())"
    $xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin nrpe -Fn enable -Args @{} -PassThru | Out-Null
    $xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin nrpe -Fn set-config `
        -Args @{ allowed_hosts = "127.0.0.1,::1,10.0.0.5"; debug = "0"; ssl_logging = "0x00" } -PassThru | Out-Null
    $xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin nrpe -Fn restart -Args @{} -PassThru | Out-Null
    $after = $xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin nrpe -Fn status -Args @{} -PassThru
    Write-Host "NRPE status after:  $($after.Trim())"
    Write-Host "OK: configure-nrpe"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigureNrpe -Url https://xenserver -UserName root -Password $password

# --- 54. Configure SNMP monitoring ---------------------------------------------------
function Invoke-ConfigureSnmp {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    # Enable the SNMP agent with a community string, through the snmp plugin.
    $config = @{
        common = @{ enabled = "yes"; debug_log = "no" }
        agent  = @{ v2c = "yes"; v3 = "no"; community = "sdk-community"; user_name = "";
                    authentication_password = ""; authentication_protocol = "";
                    privacy_password = ""; privacy_protocol = "" }
        nmss   = @()
    }
    $configJson = [string]($config | ConvertTo-Json -Compress -Depth 5)
    $xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin snmp -Fn set-config `
        -Args @{ config = $configJson } -PassThru | Out-Null
    $status = ($xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin snmp -Fn status -Args @{} -PassThru) | ConvertFrom-Json
    $cfg = ($xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin snmp -Fn get-config -Args @{} -PassThru) | ConvertFrom-Json
    Write-Host "SNMP enabled: $($status.result.enabled) / $($status.result.active)"
    Write-Host "Community: $($cfg.result.agent.community)"
    Write-Host "OK: configure-snmp"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigureSnmp -Url https://xenserver -UserName root -Password $password

# --- Manage a vApp ---------------------------------------------------------------------
function Invoke-ManageVapp {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$VmName = "web-01"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $vm = Get-XenVM -Name $VmName

    $vapp = New-XenVMAppliance -NameLabel "sdk-example-vapp" `
        -NameDescription "Created by the SDK example" -PassThru

    # `order` decides the sequence: ascending to start, descending to shut down. That ordering is the
    # reason to use a vApp rather than selecting several VMs.
    Set-XenVM -VM $vm -Appliance $vapp.opaque_ref
    Set-XenVM -VM $vm -Order 0 -StartDelay 5

    Invoke-XenVMAppliance -VMAppliance $vapp -XenAction Start -Paused $false
    Write-Host "Started:        $((Get-XenVM -Name $VmName).power_state)"

    Invoke-XenVMAppliance -VMAppliance $vapp -XenAction CleanShutdown
    Write-Host "Shut down:      $((Get-XenVM -Name $VmName).power_state)"

    Set-XenVM -VM (Get-XenVM -Name $VmName) -Appliance "OpaqueRef:NULL"
    Remove-XenVMAppliance -VMAppliance $vapp
    Write-Host "OK: manage-vapp"
    $session | Disconnect-XenServer
}

# --- Attach a USB device to a VM ---------------------------------------------------------
function Invoke-AttachUsbDevice {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$VmName = "web-01"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $vm = Get-XenVM -Name $VmName

    $pusb = Get-XenPUSB | Select-Object -First 1
    Write-Host "Device:         $($pusb.description)"

    # Passthrough is off until an administrator releases the device: attaching one that has not been
    # released fails rather than silently doing nothing.
    Set-XenPUSB -PUSB $pusb -PassthroughEnabled $true

    $vusb = New-XenVUSB -VM $vm -USBGroup $pusb.USB_group -PassThru
    Write-Host "Attached:       $(@((Get-XenVM -Name $VmName).VUSBs).Count) device(s)"

    Remove-XenVUSB -VUSB $vusb
    Set-XenPUSB -PUSB (Get-XenPUSB | Select-Object -First 1) -PassthroughEnabled $false
    Write-Host "OK: attach-usb-device"
    $session | Disconnect-XenServer
}

# --- Read workload-balancing recommendations ----------------------------------------------
function Invoke-WlbRecommendations {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$VmName = "web-01"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1

    Invoke-XenPool -Ref $pool.opaque_ref -XenAction InitializeWlb `
        -WlbUrl "https://wlb.example:8012" -WlbUsername "wlbuser" -WlbPassword "wlbpass" `
        -XenserverUsername $UserName -XenserverPassword $Password
    Write-Host "WLB: $((Get-XenPool | Select-Object -First 1).wlb_url)"

    # Read BY POSITION, and the two calls do not share a shape. The pool's are keyed by VM and say
    # where to move it: [0] "wlb", [1] the destination host's UUID (a uuid, not a ref), [2] and [3]
    # ids, [4] the reason.
    # -PassThru: without it Invoke-Xen* runs the action and emits nothing, so a value-returning
    # action looks like it returned null.
    $poolRecs = Invoke-XenPool -Ref $pool.opaque_ref -XenAction RetrieveWlbRecommendations -PassThru
    foreach ($entry in $poolRecs.GetEnumerator()) {
        $fields = @($entry.Value)
        $name = (Get-XenVM -Ref $entry.Key).name_label
        Write-Host "  move $name -> host $($fields[1]) ($($fields[4]))"
    }

    # A VM's own are keyed by host and star-rate each destination: [0] "wlb", [1] the rating.
    $vm = Get-XenVM -Name $VmName
    $vmRecs = Invoke-XenVM -Ref $vm.opaque_ref -XenAction RetrieveWlbRecommendations -PassThru
    foreach ($entry in $vmRecs.GetEnumerator()) {
        $fields = @($entry.Value)
        Write-Host "  $((Get-XenHost -Ref $entry.Key).name_label) rated $($fields[1])"
    }

    # The appliance's own settings are read and written as one flat map of strings. Send a nightly
    # reporting schedule, then read the configuration back to confirm it took.
    Invoke-XenPool -Ref $pool.opaque_ref -XenAction SendWlbConfiguration -Config @{ ReportingCronString = "0 3 * * *" }
    $config = Invoke-XenPool -Ref $pool.opaque_ref -XenAction RetrieveWlbConfiguration -PassThru
    $pairs = $config.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }
    Write-Host "  appliance configuration: $($pairs -join ', ')"

    Invoke-XenPool -Ref $pool.opaque_ref -XenAction DeconfigureWlb
    Write-Host "OK: wlb-recommendations"
    $session | Disconnect-XenServer
}

# --- Configure clustering (GFS2) ---------------------------------------------------------
function Invoke-ConfigureClustering {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # Clustering is what shared block storage needs before GFS2 thin provisioning. Pick a network every
    # host can reach: corosync is latency-sensitive, and a cluster that loses quorum takes its GFS2
    # storage offline with it.
    $network = Get-XenNetwork | Select-Object -First 1

    $cluster = Get-XenCluster | Select-Object -First 1
    if (-not $cluster) {
        # Invoke-XenCluster's parameter sets are XenObject / Ref / Uuid -- every one of them identifies an
        # EXISTING cluster -- so the module cannot express pool_create, which is a constructor. Same
        # situation as the event API: call it over JSON-RPC (see Invoke-XenMethod above).
        $ref = Invoke-XenMethod -Session $session -Method 'Cluster.pool_create' `
            -Params @($network.opaque_ref, 'corosync', 20000, 1000)
        $cluster = Get-XenCluster -Ref $ref
    }

    Write-Host "Stack:      $($cluster.cluster_stack)"
    Write-Host "Quorate:    $($cluster.is_quorate) ($($cluster.live_hosts)/$($cluster.quorum) needed)"

    # Taking a host out is what a management-interface change does; it can cost quorum.
    $member = Get-XenClusterHost | Select-Object -First 1
    Invoke-XenClusterHost -Ref $member.opaque_ref -XenAction Disable
    Write-Host "One member out, quorate: $((Get-XenCluster | Select-Object -First 1).is_quorate)"

    Invoke-XenClusterHost -Ref $member.opaque_ref -XenAction Enable
    Invoke-XenCluster -Ref $cluster.opaque_ref -XenAction PoolResync
    Write-Host "Resynced,   quorate: $((Get-XenCluster | Select-Object -First 1).is_quorate)"

    Write-Host "OK: configure-clustering"
    $session | Disconnect-XenServer
}

# --- Manage pool membership --------------------------------------------------------------
function Invoke-ManagePoolMembership {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1

    $hosts = Get-XenHost
    $original = $hosts | Where-Object { $_.opaque_ref -eq $pool.master }
    Write-Host "Coordinator: $($original.name_label)"
    foreach ($h in $hosts) {
        $tag = if ($h.opaque_ref -eq $pool.master) { " (coordinator)" } else { "" }
        Write-Host "  member: $($h.name_label)$tag"
    }

    # Promote another member. The pool database moves with the role and clients are redirected, so this
    # briefly interrupts management traffic — it does not move any VM.
    $other = $hosts | Where-Object { $_.opaque_ref -ne $pool.master } | Select-Object -First 1
    Invoke-XenPool -Ref $pool.opaque_ref -XenAction DesignateNewMaster -XenHost $other.opaque_ref
    Write-Host "Promoted:    $($other.name_label)"

    # Put it back. Ejecting a member is the other half of this surface and is deliberately not shown:
    # it cannot be undone from the pool, because rejoining is initiated by the ejected host.
    Invoke-XenPool -Ref $pool.opaque_ref -XenAction DesignateNewMaster -XenHost $original.opaque_ref
    Write-Host "Restored:    $($original.name_label)"

    Write-Host "OK: manage-pool-membership"
    $session | Disconnect-XenServer
}

# --- Create a NIC bond ---------------------------------------------------------------------
function Invoke-CreateBond {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1

    # Pick up any NIC racked since the host booted. Cheap, and without it a card added a moment ago is
    # not there to bond. PIF.scan takes a HOST, so Invoke-XenPIF cannot bind it - its parameter sets all
    # name a PIF - and the call goes over JSON-RPC instead. Same escape hatch the event API needs.
    Invoke-XenMethod -Session $session -Method 'PIF.scan' -Params @($xenHost.opaque_ref)

    # Spare NICs only. A bond that includes the management interface moves the management address onto
    # the bond master — on a real host that is how you lose the connection you are working over.
    $spares = Get-XenPIF | Where-Object { $_.host -eq $xenHost.opaque_ref -and -not $_.management -and $_.physical } |
        Select-Object -First 2
    Write-Host "Bonding:      $(($spares | ForEach-Object { $_.device }) -join ', ')"

    # The bond needs a network to sit on.
    $network = New-XenNetwork -NameLabel 'sdk-example-bond' -NameDescription 'Created by the SDK example' -PassThru

    $bond = New-XenBond -Network $network.opaque_ref -Members $spares.opaque_ref -MAC '' -Mode balance_slb -PassThru
    $master = Get-XenPIF -Ref $bond.master
    Write-Host "Bond master:  $($master.device)"
    Write-Host "Mode:         $($bond.mode)"

    Remove-XenBond -Ref $bond.opaque_ref
    Remove-XenNetwork -Ref $network.opaque_ref
    Write-Host "Bonds left:   $(@(Get-XenBond).Count)"
    Write-Host "OK: create-bond"
    $session | Disconnect-XenServer
}

# --- Configure PVS Accelerator ---------------------------------------------------------
function Invoke-ConfigurePvsAccelerator {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # PVS_site.introduce and PVS_server.introduce are CONSTRUCTORS, and every parameter set of
    # Invoke-XenPVSSite / Invoke-XenPVSServer identifies an object that ALREADY EXISTS (-PVSSite / -Ref /
    # -Uuid / -Name). Introduce is in the -XenAction enum, but there is no way to call it: name an object
    # and it goes looking for one that isn't there yet; name none and PowerShell cannot choose between
    # four sets, so it fails at binding with AmbiguousParameterSet before the call is even attempted.
    # Same shape as Cluster.pool_create in the GFS2 example — so, same answer: call the method over
    # JSON-RPC. Still pure PowerShell; no [XenAPI.*]:: statics.
    $site = Invoke-XenMethod -Session $session -Method 'PVS_site.introduce' `
        -Params @('sdk-pvs-farm', 'Created by the SDK examples', '')
    Invoke-XenMethod -Session $session -Method 'PVS_server.introduce' `
        -Params @(@('10.62.0.90'), 6910, 6930, $site) | Out-Null

    # The read cache must be on LOCAL storage: keeping reads off the network is the point, so a cache on
    # a shared SR would defeat it and the server rejects one. New-XenPVSCacheStorage is a real cmdlet.
    foreach ($xenHost in Get-XenHost) {
        $local = Get-XenPBD | Where-Object { $_.host.opaque_ref -eq $xenHost.opaque_ref } |
            ForEach-Object { Get-XenSR -Ref $_.SR.opaque_ref } |
            Where-Object { -not $_.shared -and $_.content_type -ne 'iso' -and $_.type -ne 'udev' } |
            Select-Object -First 1
        if (-not $local) { continue }
        New-XenPVSCacheStorage -XenHost $xenHost.opaque_ref -SR $local.opaque_ref -Site $site `
            -Size 10GB | Out-Null
    }

    # A proxy may only sit on the VM's LOWEST-numbered NIC, so sort by device rather than taking the
    # first VIF — the list comes back in creation order, which is the same thing only by luck.
    $accelerated = @(Get-XenPVSProxy | ForEach-Object { (Get-XenVIF -Ref $_.VIF.opaque_ref).VM.opaque_ref })
    $vm = Get-XenVM | Where-Object {
        -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot -and
        $_.power_state -eq 'Running' -and $_.VIFs.Count -gt 0 -and $accelerated -notcontains $_.opaque_ref
    } | Select-Object -First 1
    $vif = $vm.VIFs | ForEach-Object { Get-XenVIF -Ref $_.opaque_ref } |
        Sort-Object { [int]$_.device } | Select-Object -First 1
    $proxy = New-XenPVSProxy -Site $site -VIF $vif.opaque_ref -PassThru

    $record = Get-XenPVSSite -Ref $site
    Write-Host "Site '$($record.name_label)' with $($record.cache_storage.Count) cache(s) and $($record.servers.Count) server(s)"
    # "caching" means it is really accelerating: a site with no cache reports "initialised", and a proxy
    # on a VM whose NIC is unplugged reports "stopped".
    Write-Host "  $($vm.name_label): $($proxy.status)"

    # Forgetting the site takes its servers, caches and proxies with it. Forget DOES identify an existing
    # object, so unlike introduce it is reachable through the cmdlet.
    Invoke-XenPVSSite -Ref $site -XenAction Forget
    Write-Host "OK: configure-pvs-accelerator"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigurePvsAccelerator -Url https://xenserver -UserName root -Password $password

# --- Manage SSH access -----------------------------------------------------------------
function Invoke-ManageSshAccess {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool

    # Timed access is the point: set the timeout first and the server stamps an expiry when SSH is
    # enabled, so a window opened for troubleshooting closes itself.
    Get-XenHost | Set-XenHost -SshEnabledTimeout 3600

    # The pool action fans out to every host, so there is no need to loop for the enable itself.
    Invoke-XenPool -Pool $pool -XenAction EnableSsh
    Get-XenHost | ForEach-Object {
        Write-Host "$($_.name_label): ssh enabled=$($_.ssh_enabled), expires $($_.ssh_expiry.ToString('yyyyMMddTHH:mm:ssZ'))"
    }

    Invoke-XenPool -Pool $pool -XenAction DisableSsh
    Write-Host ("After disable: " + ((Get-XenHost | ForEach-Object { "$($_.name_label)=$($_.ssh_enabled)" }) -join ', '))
    Write-Host "OK: manage-ssh-access"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ManageSshAccess -Url https://xenserver -UserName root -Password $password

# --- Change control domain memory ------------------------------------------------------
function Invoke-ControlDomainMemory {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    $xenHost = Get-XenHost | Select-Object -First 1
    # dom0 is a VM like any other, found among the host's resident VMs.
    $dom0 = $xenHost.resident_VMs | ForEach-Object { Get-XenVM -Ref $_.opaque_ref } |
        Where-Object { $_.is_control_domain } | Select-Object -First 1
    $original = [long]$dom0.memory_dynamic_min
    Write-Host ("$($xenHost.name_label) dom0: {0:N1} GiB" -f ($original / 1GB))

    # -Memory, not -MemoryDynamicRange: dom0 does not balloon, so this one setter pins the static and
    # dynamic bounds and the target together. The new size takes effect at the next reboot, which is why XenCenter offers
    # this only in maintenance mode — the API itself does not stop you.
    Set-XenVM -VM $dom0 -Memory ($original + 1GB)
    $updated = Get-XenVM -Ref $dom0.opaque_ref
    Write-Host ("  now {0:N1} GiB (static {1}-{2}, dynamic {3}-{4})" -f
        ($updated.memory_dynamic_min / 1GB), $updated.memory_static_min, $updated.memory_static_max,
        $updated.memory_dynamic_min, $updated.memory_dynamic_max)

    Set-XenVM -VM $dom0 -Memory $original   # leave the pool as we found it
    Write-Host "OK: control-domain-memory"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ControlDomainMemory -Url https://xenserver -UserName root -Password $password

# --- Manage a vTPM ---------------------------------------------------------------------
function Invoke-ManageVtpm {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    $vm = Get-XenVM | Where-Object {
        -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot -and
        $_.power_state -eq 'Halted' -and $_.VTPMs.Count -eq 0
    } | Select-Object -First 1
    Write-Host "Attaching a vTPM to $($vm.name_label)"

    # IsUnique false: the vTPM may be copied along with the VM. A VM may have at most one, and it can
    # only be attached while Halted — the device is presented at boot.
    $vtpm = New-XenVTPM -VM $vm.opaque_ref -IsUnique $false -PassThru
    Write-Host "  persistence backend: $($vtpm.persistence_backend)"
    Write-Host "  unique to this VM:   $($vtpm.is_unique)"
    Write-Host "  VM now has $(@((Get-XenVM -Ref $vm.opaque_ref).VTPMs).Count) vTPM(s)"

    # The VM advertises whether another can be added; once it has one, it cannot.
    Write-Host "  can add another:     $((Get-XenVM -Ref $vm.opaque_ref).allowed_operations -contains 'create_vtpm')"

    Remove-XenVTPM -Ref $vtpm.opaque_ref
    Write-Host "  after removal:       $(@((Get-XenVM -Ref $vm.opaque_ref).VTPMs).Count) vTPM(s)"
    Write-Host "OK: manage-vtpm"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ManageVtpm -Url https://xenserver -UserName root -Password $password

# --- Back up with changed block tracking -----------------------------------------------
function Invoke-ChangedBlockTracking {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    $vm = Get-XenVM | Where-Object {
        -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot -and
        $_.VBDs.Count -gt 0
    } | Select-Object -First 1
    Write-Host "Backing up $($vm.name_label)"

    $first = Invoke-XenVM -VM $vm -XenAction Snapshot -NewName 'cbt-backup-1' -PassThru
    $second = Invoke-XenVM -VM $vm -XenAction Snapshot -NewName 'cbt-backup-2' -PassThru
    # Re-fetch the snapshots: the object -PassThru hands back is the VM as it was when created, and its
    # disks are attached a moment later, so its VBDs list is empty.
    $vdiFrom = Get-FirstDisk -Snapshot (Get-XenVM -Ref $first.opaque_ref)
    $vdiTo = Get-FirstDisk -Snapshot (Get-XenVM -Ref $second.opaque_ref)
    Invoke-XenVDI -Ref $vdiFrom -XenAction EnableCbt
    Invoke-XenVDI -Ref $vdiTo -XenAction EnableCbt

    # One bit per 64 KiB block, base64-encoded; bit N set means block N changed. A real backup reads
    # only those blocks, over NBD.
    # BOTH disks go in the dynamic parameters. -Ref only names the object the confirmation prompt talks
    # about; the call itself is made from -VdiFrom and -VdiTo, so passing only one sends a null for the
    # other and the server answers HANDLE_INVALID with an empty reference. (Dynamic parameters are keyed
    # on -XenAction, which is why they never show in (Get-Command).Parameters.)
    $encoded = Invoke-XenVDI -Ref $vdiFrom -XenAction ListChangedBlocks `
        -VdiFrom (Get-XenVDI -Ref $vdiFrom | ConvertTo-XenRef) `
        -VdiTo (Get-XenVDI -Ref $vdiTo | ConvertTo-XenRef) -PassThru
    $bitmap = [Convert]::FromBase64String($encoded)
    $changed = 0
    foreach ($byte in $bitmap) {
        $b = $byte
        while ($b) { $changed += $b -band 1; $b = $b -shr 1 }
    }
    $size = (Get-XenVDI -Ref $vdiTo).virtual_size
    Write-Host ("  {0} blocks of {1} changed ({2:N1} MiB to copy, not {3:N1} MiB)" -f
        $changed, ($bitmap.Length * 8), ($changed * 64 / 1024), ($size / 1MB))

    # Release the older snapshot's blocks but keep its change metadata, so the next incremental can
    # still diff against it. The VDI record stays; its type changes.
    Invoke-XenVDI -Ref $vdiFrom -XenAction DataDestroy
    $after = Get-XenVDI -Ref $vdiFrom
    Write-Host "  older snapshot is now type=$($after.type), still cbt_enabled=$($after.cbt_enabled)"

    Remove-XenVM -Ref $first.opaque_ref
    Remove-XenVM -Ref $second.opaque_ref
    Write-Host "OK: changed-block-tracking"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ChangedBlockTracking -Url https://xenserver -UserName root -Password $password

function Get-FirstDisk {
    # The VDI behind a snapshot's first real disk (a CD drive is a VBD too).
    param([Parameter(Mandatory = $true)]$Snapshot)
    foreach ($vbdRef in $Snapshot.VBDs) {
        $vbd = Get-XenVBD -Ref $vbdRef.opaque_ref
        if ($vbd.type -eq 'Disk') { return $vbd.VDI.opaque_ref }
    }
    throw "no disk found"
}

# --- Export and import a VM ------------------------------------------------------------
function Invoke-ExportImportVm {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # Only a halted VM can be exported: its disks must not be changing underneath the copy.
    $vm = Get-XenVM | Where-Object {
        -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot -and
        $_.power_state -eq 'Halted'
    } | Select-Object -First 1
    Write-Host "Exporting $($vm.name_label)"

    # Export and import are HTTP transfers alongside the API rather than API calls, so the session id
    # travels in the query string. Still pure PowerShell: Connect-Example has already trusted the
    # server's certificate.
    # A unique file, not a fixed name: an export is a real file on disk and two of them running at
    # once would otherwise fight over it.
    $path = Join-Path ([IO.Path]::GetTempPath()) "sdk-example-export-$([guid]::NewGuid().Guid).xva"
    Invoke-WebRequest -Uri "$Url/export?session_id=$($session.opaque_ref)&uuid=$($vm.uuid)" `
        -OutFile $path -UseBasicParsing
    Write-Host ("  wrote {0:N1} MiB to {1}" -f ((Get-Item $path).Length / 1MB), (Split-Path $path -Leaf))

    # An XVA is a tar: ova.xml describes the VM, and the disk blocks follow in 1 MiB pieces, each with
    # its own checksum.
    $names = Get-TarEntryName -Path $path
    Write-Host ("  archive holds {0} and {1} disk block(s)" -f
        $names[0], (@($names | Where-Object { -not $_.EndsWith('.checksum') }).Count - 1))

    $imported = (Invoke-WebRequest -Uri "$Url/import?session_id=$($session.opaque_ref)" -Method Put `
        -InFile $path -UseBasicParsing).Content.Trim()
    Write-Host "  imported as $((Get-XenVM -Ref $imported).name_label)"

    Remove-XenVM -Ref $imported
    Remove-Item $path
    Write-Host "OK: export-import-vm"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ExportImportVm -Url https://xenserver -UserName root -Password $password

function Get-TarEntryName {
    # A tar's entry names, read from the format itself: the name is the first 100 bytes of each 512-byte
    # header and the size is octal at offset 124, with every file padded to the next 512-byte boundary.
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $names = @()
        $header = New-Object byte[] 512
        while ($stream.Read($header, 0, 512) -eq 512) {
            $name = ([Text.Encoding]::ASCII.GetString($header, 0, 100) -replace "`0.*$", '').Trim()
            if (-not $name) { break }        # the end-of-archive marker
            $names += $name
            $octal = ([Text.Encoding]::ASCII.GetString($header, 124, 12) -replace "`0.*$", '').Trim()
            $size = if ($octal) { [Convert]::ToInt64($octal, 8) } else { 0 }
            $stream.Seek([math]::Ceiling($size / 512) * 512, [IO.SeekOrigin]::Current) | Out-Null
        }
        return $names
    }
    finally { $stream.Dispose() }
}

# --- Configure dynamic memory ----------------------------------------------------------
function Invoke-ConfigureDynamicMemory {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    $vm = Get-XenVM | Where-Object {
        -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot -and
        $_.power_state -eq 'Halted'
    } | Select-Object -First 1
    Write-Host ("{0}: static {1}-{2}, dynamic {3}-{4}" -f $vm.name_label,
        (Format-Gib $vm.memory_static_min), (Format-Gib $vm.memory_static_max),
        (Format-Gib $vm.memory_dynamic_min), (Format-Gib $vm.memory_dynamic_max))

    # Room to balloon: let the host squeeze the VM down to a quarter of its maximum, but never below the
    # static floor, which is the least the guest can boot in.
    $floor = [Math]::Max($vm.memory_static_min, [long]($vm.memory_static_max / 4))
    $ceiling = $vm.memory_static_max
    # MemoryDynamicRange takes the pair as one array argument, so the two bounds are set together and
    # cannot momentarily cross each other.
    Set-XenVM -Ref $vm.opaque_ref -MemoryDynamicRange @($floor, $ceiling)
    $after = Get-XenVM -Ref $vm.opaque_ref
    Write-Host ("  dynamic range now {0}-{1}" -f
        (Format-Gib $after.memory_dynamic_min), (Format-Gib $after.memory_dynamic_max))

    # The ordering is enforced, not advisory: a range wider than the static bounds is refused rather
    # than quietly clamped.
    try {
        # Parentheses are load-bearing: PowerShell's comma operator binds TIGHTER than multiplication, so
        # @($floor, $ceiling * 2) is @($floor, $ceiling) repeated twice - a four-element array whose first
        # two values are the range we already set. The call then succeeds and proves nothing.
        Set-XenVM -Ref $vm.opaque_ref -MemoryDynamicRange @($floor, ($ceiling * 2)) -ErrorAction Stop
        Write-Host "  ERROR: an out-of-range maximum was accepted"
    }
    catch {
        Write-Host "  refused a dynamic_max above static_max: $($_.Exception.Message)"
    }

    Set-XenVM -Ref $vm.opaque_ref -MemoryDynamicRange @($vm.memory_dynamic_min, $vm.memory_dynamic_max)
    Write-Host "OK: configure-dynamic-memory"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigureDynamicMemory -Url https://xenserver -UserName root -Password $password

function Format-Gib {
    param([long]$Bytes)
    "{0:N1} GiB" -f ($Bytes / 1GB)
}

# --- Manage a VM's CD drive ------------------------------------------------------------
function Invoke-ManageVmMedia {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    $vm = Get-XenVM | Where-Object {
        -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot -and
        $_.power_state -eq 'Halted'
    } | Select-Object -First 1
    Write-Host "Adding a DVD drive to $($vm.name_label)"

    # A CD drive is a VBD like any other, distinguished by Type CD; the media is whichever VDI it points
    # at, and an empty drive points at none.
    $device = @(Get-XenVMProperty -Ref $vm.opaque_ref -XenProperty AllowedVBDDevices)[0]
    $drive = New-XenVBD -VM $vm -Userdevice $device -Bootable $false -Mode RO -Type CD `
        -Empty $true -Unpluggable $true -OtherConfig @{} -QosAlgorithmType '' `
        -QosAlgorithmParams @{} -PassThru
    Write-Host "  drive $device is empty: $((Get-XenVBD -Ref $drive.opaque_ref).empty)"

    # The ISO library is an SR of content type "iso"; its VDIs are the available images.
    $isoSr = Get-XenSR | Where-Object { $_.content_type -eq 'iso' -and $_.type -ne 'udev' } |
        Select-Object -First 1
    $iso = $isoSr.VDIs | ForEach-Object { Get-XenVDI -Ref $_.opaque_ref } |
        Sort-Object name_label | Select-Object -First 1
    Write-Host "  inserting $($iso.name_label)"
    Invoke-XenVBD -Ref $drive.opaque_ref -XenAction Insert -Vdi $iso

    $loaded = Get-XenVBD -Ref $drive.opaque_ref
    Write-Host ("  drive now holds {0} (empty={1})" -f
        (Get-XenVDI -Ref $loaded.VDI.opaque_ref).name_label, $loaded.empty)

    Invoke-XenVBD -Ref $drive.opaque_ref -XenAction Eject
    Write-Host "  after eject, empty=$((Get-XenVBD -Ref $drive.opaque_ref).empty)"

    Remove-XenVBD -Ref $drive.opaque_ref
    Write-Host "OK: manage-vm-media"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ManageVmMedia -Url https://xenserver -UserName root -Password $password

# --- Back up a host's configuration ----------------------------------------------------
function Invoke-BackupHostConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    $hosts = @(Get-XenHost)
    $vmHost = $hosts[0]
    Write-Host "Backing up $($vmHost.name_label)"

    # Backup and restore are HTTP transfers alongside the API rather than API calls, so the session id
    # travels in the query string. Still pure PowerShell: Connect-Example has already trusted the
    # server's certificate.
    $path = Join-Path ([IO.Path]::GetTempPath()) "sdk-example-host-$([guid]::NewGuid().Guid).backup"
    Invoke-WebRequest -UseBasicParsing -OutFile $path `
        -Uri "$Url/host_backup?session_id=$($session.opaque_ref)&ref=$($vmHost.opaque_ref)"
    Write-Host "  wrote $((Get-Item $path).Length) bytes to $(Split-Path $path -Leaf)"

    Write-Host ("  restoring it to {0}: {1}" -f $vmHost.name_label,
        (Restore-ExampleHostConfig -Session $session -Url $Url -VMHost $vmHost -Path $path))
    if ($hosts.Count -gt 1) {
        # The refusal is the half worth rehearsing: restoring one host's configuration onto another is
        # destructive and unrecoverable, so the pool checks rather than trusting the caller.
        Write-Host ("  restoring it to {0}: {1}" -f $hosts[1].name_label,
            (Restore-ExampleHostConfig -Session $session -Url $Url -VMHost $hosts[1] -Path $path))
    }

    Remove-Item $path
    Write-Host "OK: backup-host-config"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-BackupHostConfig -Url https://xenserver -UserName root -Password $password

function Restore-ExampleHostConfig {
    # Uploads a backup to a host and reports what the task says about it.
    #
    # An upload answers 200 as soon as it has read the request headers, because the client waits for
    # that before it starts sending the file. The outcome therefore cannot be in the status line: it
    # arrives on a task you create first, name in the URL, and poll once the upload has finished.
    param($Session, [string]$Url, $VMHost, [string]$Path)

    $task = New-XenTask -Label 'host_restore' -Description 'restoring a configuration backup' -PassThru
    try {
        Invoke-WebRequest -UseBasicParsing -Method Put -InFile $Path `
            -Uri ("$Url/host_restore?session_id=$($Session.opaque_ref)" +
                  "&ref=$($VMHost.opaque_ref)&task_id=$($task.opaque_ref)") | Out-Null

        while ((Get-XenTask -Ref $task.opaque_ref).status -eq 'pending') { Start-Sleep -Milliseconds 500 }
        $finished = Get-XenTask -Ref $task.opaque_ref
        if ($finished.status -eq 'success') { return 'accepted' }
        return "refused ($($finished.error_info[-1]))"
    }
    finally {
        Remove-XenTask -Ref $task.opaque_ref
    }
}

# --- Detach, reattach and forget storage -----------------------------------------------
function Invoke-ManageSrLifecycle {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$NfsServer = "192.0.2.10",
        [string]$NfsPath = "/export/spare"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # There is no "detach" call on an SR. A shared SR is joined to each host by one PBD - a physical
    # block device - and detaching the SR means unplugging every one of them. That is why an SR can be
    # attached on some hosts and not others, and why a repair action exists at all: it plugs back the
    # PBDs that are missing.
    $xenHost = Get-XenHost | Select-Object -First 1
    $sr = New-XenSR -XenHost $xenHost -PhysicalSize 0 `
        -DeviceConfig @{ server = $NfsServer; serverpath = $NfsPath; nfsversion = "3" } `
        -NameLabel "sdk-example-lifecycle" -NameDescription "SR used by the SDK lifecycle example" `
        -Type "nfs" -ContentType "user" -Shared $true -PassThru

    $pbds = @($sr.PBDs | ForEach-Object { Get-XenPBD -Ref $_.opaque_ref })
    Write-Host ("{0}: connected on {1} of {2} host(s)" -f
        $sr.name_label, (Measure-AttachedPbd $pbds), $pbds.Count)

    $pbds | Invoke-XenPBD -XenAction Unplug
    Write-Host ("  detached:   connected on {0} host(s)" -f (Measure-AttachedPbd $pbds))

    # Plugging them back is exactly what a repair does.
    $pbds | Invoke-XenPBD -XenAction Plug
    Write-Host ("  reattached: connected on {0} host(s)" -f (Measure-AttachedPbd $pbds))

    $sr | Invoke-XenSR -XenAction Scan
    Write-Host ("  rescanned:  {0} disk(s)" -f (Get-XenSR -Ref $sr.opaque_ref).VDIs.Count)

    # Forgetting drops the pool's record of the SR but leaves the storage itself untouched, so the same
    # export can be introduced again later. Detach before forgetting: a connected SR is still in use.
    $pbds | Invoke-XenPBD -XenAction Unplug
    $sr | Invoke-XenSR -XenAction Forget
    Write-Host "  forgotten"
    Write-Host "OK: manage-sr-lifecycle"
    $session | Disconnect-XenServer
}

function Measure-AttachedPbd {
    # How many of these connections are currently live. Re-read each one: the cached records were
    # fetched before the plug state changed.
    param($Pbds)
    @($Pbds | Where-Object { (Get-XenPBD -Ref $_.opaque_ref).currently_attached }).Count
}
# Run it:
#   Invoke-ManageSrLifecycle -Url https://xenserver -UserName root -Password $password

# --- Set the pool's default storage ------------------------------------------------------
function Invoke-SetDefaultSr {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$NfsServer = "192.0.2.10",
        [string]$NfsPath = "/export/spare"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1

    # Capture all three separately. New disks land on the default SR, a suspended VM's memory image goes
    # to the suspend-image SR and host crash dumps to the crash-dump SR. They are usually the same
    # storage but need not be, and a pool that has never suspended or crashed anything can legitimately
    # leave the latter two unset - so restoring all three from the default would quietly invent settings
    # that were not there. The record already holds each as a reference, so it can be handed straight
    # back to Set-XenPool later.
    $before = $pool.default_SR
    $beforeSuspend = $pool.suspend_image_SR
    $beforeCrash = $pool.crash_dump_SR
    Write-Host ("default storage:  {0}" -f (Get-SrLabel $before))
    Write-Host ("  suspend images: {0}" -f (Get-SrLabel $beforeSuspend))
    Write-Host ("  crash dumps:    {0}" -f (Get-SrLabel $beforeCrash))

    # Somewhere to switch to. A pool default has to be reachable from every host, so it is a shared SR;
    # a local one would strand any VM whose disk landed on the wrong host.
    $sr = New-XenSR -XenHost (Get-XenHost | Select-Object -First 1) -PhysicalSize 0 `
        -DeviceConfig @{ server = $NfsServer; serverpath = $NfsPath; nfsversion = "3" } `
        -NameLabel "sdk-example-default" -NameDescription "SR used by the SDK default-storage example" `
        -Type "nfs" -ContentType "user" -Shared $true -PassThru

    $srRef = $sr | ConvertTo-XenRef
    $pool | Set-XenPool -DefaultSR $srRef -SuspendImageSR $srRef -CrashDumpSR $srRef
    Write-Host ("  switched to:    {0}" -f (Get-SrLabel (Get-XenPool -Ref $pool.opaque_ref).default_SR))

    # Restore the original choice before tidying up: an SR that is still the pool default is the awkward
    # one to remove.
    $pool | Set-XenPool -DefaultSR $before -SuspendImageSR $beforeSuspend -CrashDumpSR $beforeCrash
    @($sr.PBDs | ForEach-Object { Get-XenPBD -Ref $_.opaque_ref }) | Invoke-XenPBD -XenAction Unplug
    $sr | Invoke-XenSR -XenAction Forget
    Write-Host ("  restored to:    {0}" -f (Get-SrLabel (Get-XenPool -Ref $pool.opaque_ref).default_SR))
    Write-Host "OK: set-default-sr"
    $session | Disconnect-XenServer
}

function Get-SrLabel {
    # An SR's name, tolerating the null reference an unset pool field holds.
    param($SrRef)
    if (-not $SrRef -or $SrRef.opaque_ref -eq "OpaqueRef:NULL") { return "(none)" }
    (Get-XenSR -Ref $SrRef.opaque_ref).name_label
}
# Run it:
#   Invoke-SetDefaultSr -Url https://xenserver -UserName root -Password $password

# --- Collect a server status report ------------------------------------------------------
function Invoke-ServerStatusReport {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # Report on the coordinator. Each host answers for itself, so which one you ask decides whose logs
    # you get - support normally wants every host, one download each.
    $pool = Get-XenPool | Select-Object -First 1
    $xenHost = Get-XenHost -Ref $pool.master.opaque_ref
    Write-Host "Status report for $($xenHost.name_label)"

    # The host publishes a catalogue of the sections it can report on, each with a size estimate and
    # whether it may contain personal data, so a client can offer an informed choice rather than
    # hard-coding the list.
    # A read, so it is a property rather than an action: Invoke-XenHost's -XenAction set covers the
    # host's verbs, and this is not one of them.
    $catalogue = [xml](Get-XenHostProperty -XenHost $xenHost -XenProperty SystemStatusCapabilities)
    $keys = @()
    foreach ($capability in $catalogue.'system-status-capabilities'.capability) {
        $keys += $capability.key
        Write-Host ("  {0,-22} max {1,9} bytes  default={2,-3} pii={3}" -f
            $capability.key, $capability.'max-size', $capability.'default-checked', $capability.pii)
    }

    # The download is an HTTP transfer alongside the API, so the session id travels in the query string.
    # Still pure PowerShell: Connect-Example has already trusted the server's certificate.
    $whole = Get-StatusReportSize -Url $Url -Session $session -Entries $keys
    Write-Host ("everything ({0} sections): {1} bytes" -f $keys.Count, $whole)

    # Worth checking rather than assuming: a server that ignored the selection would look identical from
    # here until someone opened the archive and found the whole thing.
    $subset = Get-StatusReportSize -Url $Url -Session $session -Entries @("xenserver-config")
    Write-Host ("xenserver-config only:   {0} bytes" -f $subset)
    if ($subset -ge $whole) {
        Write-Host "  ERROR: selecting fewer sections did not produce a smaller bundle"
    }

    Write-Host "OK: server-status-report"
    $session | Disconnect-XenServer
}

function Get-StatusReportSize {
    # Downloads the bundle for the given capability keys (a tar archive) and reports its size.
    param([string]$Url, $Session, [string[]]$Entries)
    $response = Invoke-WebRequest -UseBasicParsing `
        -Uri ("$Url/system-status?session_id=$($Session.opaque_ref)&output=tar" +
              "&entries=$($Entries -join ',')")
    $response.Content.Length
}
# Run it:
#   Invoke-ServerStatusReport -Url https://xenserver -UserName root -Password $password

# --- Recover VMs after a disaster --------------------------------------------------------
function Invoke-DisasterRecovery {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # Disaster recovery works by writing the pool's own database out to a storage repository as a disk of
    # type "metadata". That disk can be read back as a SEPARATE database, so the ordinary calls describe
    # the pool as it was replicated rather than the pool you are connected to.
    #
    # Replication needs storage every host can reach and that can hold data. The server checks rather than
    # taking your word for it, so ask before enabling.
    $sr = Get-XenSR | Where-Object {
        $_.shared -and $_.content_type -ne 'iso' -and $_.type -notin @('iso', 'udev')
    } | Select-Object -First 1
    $sr | Invoke-XenSR -XenAction AssertSupportsDatabaseReplication
    Write-Host "Replicating pool metadata to $($sr.name_label)"
    $sr | Invoke-XenSR -XenAction EnableDatabaseReplication

    $vdi = Get-XenVDI | Where-Object { $_.type -eq 'metadata' } | Select-Object -First 1
    Write-Host "  metadata disk: $($vdi.uuid)"

    # Two module limits meet here, so the metadata database is driven over JSON-RPC: Invoke-XenVDI
    # -XenAction OpenDatabase does not hand back the session it opens (even with -PassThru), and
    # -SessionOpaqueRef only accepts sessions the module created itself. Same escape hatch the event API
    # needs, and still pure PowerShell.
    $metadataRef = Invoke-XenMethod -Session $session -Method 'VDI.open_database' -Params @($vdi.opaque_ref)
    $metadata = [pscustomobject]@{ opaque_ref = $metadataRef; Url = $session.Url }

    $recoverable = Invoke-XenMethod -Session $metadata -Method 'VM.get_all_records' -Params @()
    $entries = @($recoverable.PSObject.Properties | Sort-Object { $_.Value.name_label })
    Write-Host "  the replicated database describes $($entries.Count) recoverable VM(s)"

    $target = $entries[0]
    $name = $target.Value.name_label
    Write-Host "  recovering $name"

    # Both calls run on the METADATA session; the live one says where the VM should land.
    Invoke-XenMethod -Session $metadata -Method 'VM.assert_can_be_recovered' `
        -Params @($target.Name, $session.opaque_ref) | Out-Null
    Invoke-XenMethod -Session $metadata -Method 'VM.recover' `
        -Params @($target.Name, $session.opaque_ref, $false) | Out-Null

    # It is a real VM in the live pool now, not merely a call that returned.
    $live = @(Get-XenVM | Where-Object { $_.name_label -eq $name })
    Write-Host "  $name is $($live[0].power_state) in the live pool"

    $live | Remove-XenVM
    $sr | Invoke-XenSR -XenAction DisableDatabaseReplication
    Write-Host "OK: disaster-recovery"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-DisasterRecovery -Url https://xenserver -UserName root -Password $password

# --- Manage Secure Boot certificates -----------------------------------------------------
function Invoke-ManageSecurebootCertificates {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1

    # A Secure Boot guest carries its own copy of the pool's UEFI certificates, taken when it was created.
    # Rotating the pool's leaves the guest's stale, and the fix is applied at the guest's next boot rather
    # than underneath a running VM - so you flag it and reboot when convenient.
    #
    # First, whether the pool holds the certificates to hand out at all. "ready_no_dbx" means it has the
    # essentials but no revocation list - usable, and not the same answer as "ready".
    Write-Host "Pool Secure Boot readiness: $(Get-XenPoolProperty -Ref $pool.opaque_ref -XenProperty GuestSecurebootReadiness)"
    Write-Host "  pool holds certificates:  $([bool]$pool.uefi_certificates)"

    # A guest whose certificates have gone stale. Its state is what a client gates the flag/unflag actions
    # on, so it is the field to watch.
    $vm = Get-XenVM | Where-Object {
        -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot -and
        $_.secureboot_certificates_state -eq 'update_available'
    } | Select-Object -First 1
    Write-Host ("{0}: readiness {1}, certificates {2}" -f $vm.name_label,
        (Get-XenVMProperty -Ref $vm.opaque_ref -XenProperty SecurebootReadiness),
        (Get-XenVMProperty -Ref $vm.opaque_ref -XenProperty SecurebootCertificatesState))

    # Flagging and unflagging are the same action with opposite values of -Mark.
    $vm | Invoke-XenVM -XenAction UpdateSecurebootCertificatesOnBoot -Mark $true
    Write-Host "  flagged for refresh:      $((Get-XenVM -Ref $vm.opaque_ref).secureboot_certificates_state)"

    $vm | Invoke-XenVM -XenAction UpdateSecurebootCertificatesOnBoot -Mark $false
    Write-Host "  unflagged:                $((Get-XenVM -Ref $vm.opaque_ref).secureboot_certificates_state)"

    Write-Host "OK: manage-secureboot-certificates"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ManageSecurebootCertificates -Url https://xenserver -UserName root -Password $password

# --- Restart a host ----------------------------------------------------------------------
function Invoke-RestartHost {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # Rebooting a host is never just the reboot: anything running on it has to go somewhere first, and the
    # host has to stop accepting new VMs while that happens.
    #
    # Not the coordinator: it is the host this session is talking to, and taking it down would drop the
    # connection underneath the rest of the example.
    $pool = Get-XenPool | Select-Object -First 1
    $xenHost = Get-XenHost | Where-Object { $_.opaque_ref -ne $pool.master.opaque_ref } | Select-Object -First 1
    Write-Host "Restarting $($xenHost.name_label)"
    Write-Host "  enabled=$($xenHost.enabled), guests=$(Measure-HostGuest $xenHost)"

    # Disabled means "accept no new VMs"; it does not move anything on its own.
    $xenHost | Invoke-XenHost -XenAction Disable
    Write-Host "  disabled:   enabled=$((Get-XenHost -Ref $xenHost.opaque_ref).enabled)"

    # Evacuate moves the guests elsewhere in the pool. Afterwards only the control domain - the host's own
    # management VM, which cannot move - is left.
    $xenHost | Invoke-XenHost -XenAction Evacuate
    Write-Host "  evacuated:  guests=$(Measure-HostGuest $xenHost)"

    $xenHost | Invoke-XenHost -XenAction Reboot
    Write-Host "  rebooted:   enabled=$((Get-XenHost -Ref $xenHost.opaque_ref).enabled)"

    # The other ending: off, and back on out of band.
    $xenHost | Invoke-XenHost -XenAction Shutdown
    Write-Host "  shut down:  live=$(Get-HostLive $xenHost)"
    $xenHost | Invoke-XenHost -XenAction PowerOn
    Write-Host "  powered on: live=$(Get-HostLive $xenHost)"

    Write-Host "OK: restart-host"
    $session | Disconnect-XenServer
}

function Measure-HostGuest {
    # Resident VMs excluding the control domain, which never moves.
    param($XenHost)
    @((Get-XenHost -Ref $XenHost.opaque_ref).resident_VMs |
        Where-Object { -not (Get-XenVM -Ref $_.opaque_ref).is_control_domain }).Count
}

function Get-HostLive {
    param($XenHost)
    (Get-XenHostMetrics -Ref (Get-XenHost -Ref $XenHost.opaque_ref).metrics.opaque_ref).live
}
# Run it:
#   Invoke-RestartHost -Url https://xenserver -UserName root -Password $password

# --- Create a VM and a template from a snapshot ------------------------------------------
function Invoke-VmFromSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$VmName = 'db-01'
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # A snapshot is a VM record with is_a_snapshot set, so both of these are clones of it - the difference
    # is only what you mark the result as.
    $vm = Get-XenVM -Name $VmName | Select-Object -First 1
    $snapshot = $vm | Invoke-XenVM -XenAction Snapshot -NewName 'sdk-example-source-snapshot' -PassThru
    Write-Host "Snapshot of $VmName taken"

    # A clone of a snapshot is an ordinary VM. Worth reading back rather than assuming: a result still
    # flagged as a snapshot would be filed under the original VM instead of standing on its own, and would
    # not appear in a VM listing at all.
    $newVm = $snapshot | Invoke-XenVM -XenAction Clone -NewName 'sdk-example-vm-from-snapshot' -PassThru
    Write-Host "  new VM:      $($newVm.name_label) (is_a_snapshot=$($newVm.is_a_snapshot))"

    # The same clone, marked as a template instead: a starting point to stamp more VMs from.
    $template = $snapshot | Invoke-XenVM -XenAction Clone -NewName 'sdk-example-template-from-snapshot' -PassThru
    Set-XenVM -Ref $template.opaque_ref -IsATemplate $true
    Write-Host "  new template:$($template.name_label) (is_a_template=$((Get-XenVM -Ref $template.opaque_ref).is_a_template))"

    foreach ($ref in @($newVm.opaque_ref, $template.opaque_ref, $snapshot.opaque_ref)) {
        Remove-XenVM -Ref $ref
    }
    Write-Host "OK: vm-from-snapshot"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-VmFromSnapshot -Url https://xenserver -UserName root -Password $password

# --- Attach an existing disk to another VM -----------------------------------------------
function Invoke-AttachExistingDisk {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # A disk and the VM it belongs to are separate objects joined by a VBD, so moving a disk between VMs
    # is removing one VBD and creating another - no copying, and the data stays exactly where it is.
    $halted = @(Get-XenVM | Where-Object {
        -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot -and
        $_.power_state -eq 'Halted'
    })
    $sr = Get-XenSR | Where-Object {
        $_.shared -and $_.content_type -ne 'iso' -and $_.type -notin @('iso', 'udev')
    } | Select-Object -First 1

    $vdi = New-XenVDI -SR $sr -NameLabel 'sdk-example-portable-disk' -VirtualSize 4GB `
        -Type User -Sharable $false -ReadOnly $false -PassThru
    Write-Host "Disk $($vdi.name_label) created on $($sr.name_label)"

    $vbd = Add-ExampleDisk -VM $halted[0] -Vdi $vdi
    Write-Host "  attached to $($halted[0].name_label)"

    # Destroying the VBD detaches the disk; the disk itself is untouched and keeps its data.
    Remove-XenVBD -Ref $vbd.opaque_ref
    Write-Host "  detached:   the disk still exists ($((Get-XenVDI -Ref $vdi.opaque_ref).virtual_size) bytes)"

    Add-ExampleDisk -VM $halted[1] -Vdi $vdi | Out-Null
    Write-Host "  attached to $($halted[1].name_label)"
    $vbds = @((Get-XenVDI -Ref $vdi.opaque_ref).VBDs)
    Write-Host "  the disk is on $($vbds.Count) VM(s)"

    foreach ($b in $vbds) { Remove-XenVBD -Ref $b.opaque_ref }
    Remove-XenVDI -Ref $vdi.opaque_ref
    Write-Host "OK: attach-existing-disk"
    $session | Disconnect-XenServer
}

function Add-ExampleDisk {
    # Join an existing disk to a VM on its next free device slot.
    param($VM, $Vdi)
    New-XenVBD -VM $VM -VDI $Vdi -Userdevice (Get-XenVMProperty -Ref $VM.opaque_ref -XenProperty AllowedVBDDevices)[0] `
        -Mode RW -Type Disk -Bootable $false -Empty $false -PassThru
}
# Run it:
#   Invoke-AttachExistingDisk -Url https://xenserver -UserName root -Password $password

# --- Clear a host's crash dumps ------------------------------------------------------------
function Invoke-ManageCrashDumps {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # When a host crashes it writes a dump to its local disk and keeps it. They are large, nothing cleans
    # them up, and a host that has crashed more than once accumulates them - so clearing them once support
    # has what it needs is ordinary housekeeping. They belong to the host that wrote them, so clear them a
    # host at a time.
    $xenHost = Get-XenHost | Where-Object { $_.crashdumps.Count -gt 0 } | Select-Object -First 1
    if (-not $xenHost) {
        Write-Host "No crash dumps in this pool - nothing to clear."
        Write-Host "OK: manage-crash-dumps"
        $session | Disconnect-XenServer
        return
    }

    $dumps = @($xenHost.crashdumps | ForEach-Object { Get-XenHostCrashdump -Ref $_.opaque_ref })
    Write-Host "$($xenHost.name_label) has $($dumps.Count) crash dump(s)"
    $total = 0
    foreach ($dump in $dumps) {
        $total += $dump.size
        Write-Host ("  {0:yyyyMMdd'T'HH:mm:ss'Z'}  {1}" -f $dump.timestamp, (Format-Mib $dump.size))
    }
    Write-Host "  $(Format-Mib $total) in total"

    # Deleting a dump frees the space on the host; the host itself is untouched.
    $dumps | Remove-XenHostCrashdump
    Write-Host "  cleared:  $($xenHost.name_label) now has $((Get-XenHost -Ref $xenHost.opaque_ref).crashdumps.Count)"

    Write-Host "OK: manage-crash-dumps"
    $session | Disconnect-XenServer
}

function Format-Mib {
    param([long]$Size)
    "{0} MiB" -f [math]::Floor($Size / 1MB)
}
# Run it:
#   Invoke-ManageCrashDumps -Url https://xenserver -UserName root -Password $password

# --- Configure pool options ----------------------------------------------------------------
function Invoke-ConfigurePoolOptions {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1

    # None of these is a wizard: they are plain pool settings that a client exposes on a properties
    # page, and each is a single field. Read them, change them, put them back.
    $before = [ordered]@{
        "live patching disabled" = $pool.live_patching_disabled
        "IGMP snooping"          = $pool.igmp_snooping_enabled
        "migration compression"  = $pool.migration_compression
    }
    foreach ($k in $before.Keys) { Write-Host ("  {0,-22} {1}" -f $k, $before[$k]) }

    # Live patching applies host updates without a reboot; disabling it forces the reboot.
    $pool | Set-XenPool -LivePatchingDisabled (-not $before["live patching disabled"])
    # IGMP snooping keeps multicast off ports that did not ask for it.
    $pool | Set-XenPool -IgmpSnoopingEnabled (-not $before["IGMP snooping"])
    # Compression trades CPU for bandwidth when a VM's memory is moved between hosts.
    $pool | Set-XenPool -MigrationCompression (-not $before["migration compression"])

    $after = Get-XenPool -Ref $pool.opaque_ref
    Write-Host "after changing:"
    Write-Host ("  {0,-22} {1}" -f "live patching disabled", $after.live_patching_disabled)
    Write-Host ("  {0,-22} {1}" -f "IGMP snooping", $after.igmp_snooping_enabled)
    Write-Host ("  {0,-22} {1}" -f "migration compression", $after.migration_compression)

    $pool | Set-XenPool -LivePatchingDisabled $before["live patching disabled"]
    $pool | Set-XenPool -IgmpSnoopingEnabled $before["IGMP snooping"]
    $pool | Set-XenPool -MigrationCompression $before["migration compression"]
    Write-Host "  restored"
    Write-Host "OK: configure-pool-options"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigurePoolOptions -Url https://xenserver -UserName root -Password $password

# --- Configure console access ----------------------------------------------------------------
function Invoke-ConfigureConsoleAccess {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1
    $xenHost = Get-XenHost -Ref $pool.master.opaque_ref

    # NB: pool.https_only and pool.console_idle_timeout are SET below but never read back. SDK 26.14
    # generates a setter and no getter for both (unlike host.console_idle_timeout, which has both), so
    # they cannot be read through the typed bindings at all - and a sample that reached past its own
    # binding to show a value would be teaching a workaround rather than the API.
    Write-Host ("  {0,-26} {1}s" -f "VM console idle timeout", $pool.vm_console_idle_timeout)
    Write-Host ("  {0,-26} {1}" -f "limit console sessions", $pool.limit_console_sessions)
    Write-Host ("  {0,-26} {1}s" -f "host console idle timeout", $xenHost.console_idle_timeout)

    # Ten minutes of inactivity, one console session at a time, and no plain HTTP.
    $pool | Set-XenPool -ConsoleIdleTimeout 600
    $pool | Set-XenPool -VmConsoleIdleTimeout 600
    $pool | Set-XenPool -LimitConsoleSessions $true
    $xenHost | Set-XenHost -ConsoleIdleTimeout 300
    $pool | Set-XenPool -HttpsOnly $true

    Write-Host "after tightening:"
    Write-Host ("  {0,-26} {1}s" -f "VM console idle timeout", (Get-XenPool -Ref $pool.opaque_ref).vm_console_idle_timeout)
    Write-Host ("  {0,-26} {1}" -f "limit console sessions", (Get-XenPool -Ref $pool.opaque_ref).limit_console_sessions)
    Write-Host ("  {0,-26} {1}s" -f "host console idle timeout", (Get-XenHost -Ref $xenHost.opaque_ref).console_idle_timeout)

    $pool | Set-XenPool -HttpsOnly $false
    $pool | Set-XenPool -ConsoleIdleTimeout 0
    $pool | Set-XenPool -VmConsoleIdleTimeout 0
    $pool | Set-XenPool -LimitConsoleSessions $false
    $xenHost | Set-XenHost -ConsoleIdleTimeout 0
    Write-Host "  restored"
    Write-Host "OK: configure-console-access"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigureConsoleAccess -Url https://xenserver -UserName root -Password $password

# --- Configure host storage --------------------------------------------------------------------
function Invoke-ConfigureHostStorage {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost -Ref (Get-XenPool | Select-Object -First 1).master.opaque_ref

    # The IQN identifies this host to iSCSI targets, so a target's access list is written against it -
    # changing it on a host with live iSCSI storage cuts it off. Multipathing uses every path to the
    # storage rather than one, and on real hardware you put the host into maintenance mode before
    # changing it, because the paths are rebuilt.
    $beforeIqn = $xenHost.iscsi_iqn
    $beforeMultipathing = $xenHost.multipathing
    Write-Host "$($xenHost.name_label): iSCSI IQN '$beforeIqn', multipathing $beforeMultipathing"

    $xenHost | Set-XenHost -IscsiIqn "iqn.2026-01.com.example:$($xenHost.name_label)"
    $xenHost | Set-XenHost -Multipathing $true
    $updated = Get-XenHost -Ref $xenHost.opaque_ref
    Write-Host "  IQN now:      $($updated.iscsi_iqn)"
    Write-Host "  multipathing: $($updated.multipathing)"

    $xenHost | Set-XenHost -IscsiIqn $beforeIqn
    $xenHost | Set-XenHost -Multipathing $beforeMultipathing
    Write-Host "  restored"
    Write-Host "OK: configure-host-storage"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigureHostStorage -Url https://xenserver -UserName root -Password $password

# --- Configure remote syslog ---------------------------------------------------------------
function Invoke-ConfigureSyslog {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$SyslogServer = "192.0.2.50"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost -Ref (Get-XenPool | Select-Object -First 1).master.opaque_ref

    Write-Host "$($xenHost.name_label) logging: $(Format-Logging $xenHost.logging)"

    # Two steps, and the second is the one that is easy to miss: setting the destination only records
    # it, and the host keeps logging locally until the syslog daemon is reconfigured to pick the
    # setting up. Add-XenHost appends one logging entry as a KeyValuePair; Remove-XenHostProperty drops
    # it again by key.
    $xenHost | Remove-XenHostProperty -Logging "syslog_destination"
    $xenHost | Add-XenHost -Logging ([System.Collections.Generic.KeyValuePair[string, string]]::new("syslog_destination", $SyslogServer))
    $xenHost | Invoke-XenHost -XenAction SyslogReconfigure
    Write-Host "  now logging to: $((Get-XenHost -Ref $xenHost.opaque_ref).logging['syslog_destination'])"

    $xenHost | Remove-XenHostProperty -Logging "syslog_destination"
    $xenHost | Invoke-XenHost -XenAction SyslogReconfigure
    Write-Host "  restored: $(Format-Logging (Get-XenHost -Ref $xenHost.opaque_ref).logging)"
    Write-Host "OK: configure-syslog"
    $session | Disconnect-XenServer
}

function Format-Logging {
    # The host's logging map, tolerating the empty map a host with no remote destination has.
    param($Logging)
    if (-not $Logging -or $Logging.Count -eq 0) { return "(local only)" }
    ($Logging.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
}
# Run it:
#   Invoke-ConfigureSyslog -Url https://xenserver -UserName root -Password $password

# --- Manage driver variants ----------------------------------------------------------------
function Invoke-ManageDriverVariants {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost -Ref (Get-XenPool | Select-Object -First 1).master.opaque_ref

    # A driver can ship in several variants - a vendor build alongside the one in the distribution, say.
    # One is SELECTED (what the host will load) and one is ACTIVE (what it has loaded); they differ
    # until the host reboots, which is what makes selecting a variant a scheduled change rather than an
    # immediate one.
    $drivers = @(Get-XenHostDriver | Where-Object { $_.host -eq $xenHost.opaque_ref })
    Write-Host "$($xenHost.name_label) has $($drivers.Count) driver(s)"
    $drivers | Sort-Object name | Select-Object -First 3 | ForEach-Object {
        Write-Host ("  {0,-14} {1,-10} {2} variant(s), active={3}" -f
            $_.name, $_.type, $_.variants.Count, (Get-DriverVariantName $_.active_variant))
    }

    # Select a variant explicitly. It becomes the selected one immediately; whether it is also active
    # depends on whether the hardware is present and the driver already loaded.
    $target = $drivers | Sort-Object name | Select-Object -First 1
    $variant = $target.variants[0]
    Invoke-XenHostDriver -Ref $target.opaque_ref -XenAction Select -Variant $variant
    $after = Get-XenHostDriver -Ref $target.opaque_ref
    Write-Host "  $($after.name): selected $(Get-DriverVariantName $after.selected_variant), active $(Get-DriverVariantName $after.active_variant)"

    Write-Host "OK: manage-driver-variants"
    $session | Disconnect-XenServer
}

function Get-DriverVariantName {
    # A driver variant's name, tolerating the null reference an unloaded driver has.
    param($VariantRef)
    if (-not $VariantRef -or $VariantRef.opaque_ref -eq "OpaqueRef:NULL") { return "(none)" }
    (Get-XenDriverVariant -Ref $VariantRef.opaque_ref).name
}
# Run it:
#   Invoke-ManageDriverVariants -Url https://xenserver -UserName root -Password $password

# --- end of workflows ---

# --- entry point -----------------------------------------------------------------------
# Maps the <workflow> argument to the matching self-contained function above, supplying the concrete
# objects each one operates on. In your own scripts you would call these functions directly (see the
# "Run it:" line under each) rather than through this dispatcher.
switch ($Workflow) {
    "connect-inventory"  { Invoke-ConnectInventory  -Url $Url -UserName $UserName -Password $Password }
    "create-vm"          { Invoke-CreateVm          -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "vm-lifecycle"       { Invoke-VmLifecycle       -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "manage-vm-disks"    { Invoke-ManageVmDisks    -Url $Url -UserName $UserName -Password $Password -VmName "web-01" }
    "dismiss-alerts"     { Invoke-DismissAlerts     -Url $Url -UserName $UserName -Password $Password }
    "host-power-on"      { Invoke-HostPowerOn       -Url $Url -UserName $UserName -Password $Password }
    "rotate-pool-secret" { Invoke-RotatePoolSecret  -Url $Url -UserName $UserName -Password $Password }
    "change-root-password" { Invoke-ChangeRootPassword -Url $Url -UserName $UserName -Password $Password }
    "manage-certificates" { Invoke-ManageCertificates -Url $Url -UserName $UserName -Password $Password }
    "snapshot-schedule"  { Invoke-SnapshotSchedule  -Url $Url -UserName $UserName -Password $Password -VmName "web-01" }
    "manage-vm-groups"   { Invoke-ManageVmGroups    -Url $Url -UserName $UserName -Password $Password -VmName "web-01" }
    "snapshot-revert"    { Invoke-SnapshotRevert    -Url $Url -UserName $UserName -Password $Password -VmName "web-01" }
    "create-nfs-sr"      { Invoke-CreateNfsSr       -Url $Url -UserName $UserName -Password $Password -NfsServer "192.0.2.10" -NfsPath "/export/sdk" }
    "create-network"     { Invoke-CreateNetwork     -Url $Url -UserName $UserName -Password $Password }
    "edit-vm-properties" { Invoke-EditVmProperties  -Url $Url -UserName $UserName -Password $Password -VmName "web-01" }
    "events"             { Invoke-Events            -Url $Url -UserName $UserName -Password $Password -VmName "web-01" }
    "new-vm-wizard"      { Invoke-NewVmWizard       -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "live-migrate"       { Invoke-LiveMigrate       -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "host-maintenance"   { Invoke-HostMaintenance   -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "configure-ha"       { Invoke-ConfigureHa       -Url $Url -UserName $UserName -Password $Password -HeartbeatSrName "Shared NFS" }
    "copy-vm"            { Invoke-CopyVm            -Url $Url -UserName $UserName -Password $Password -VmName "db-01" -SrName "Shared NFS" }
    "create-vm-with-vgpu" { Invoke-CreateVmWithVgpu -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "tags-and-folders"   { Invoke-TagsAndFolders   -Url $Url -UserName $UserName -Password $Password -VmName "web-01" }
    "configure-updates"  { Invoke-ConfigureUpdates -Url $Url -UserName $UserName -Password $Password }
    "clone-vm"           { Invoke-CloneVm          -Url $Url -UserName $UserName -Password $Password -VmName "db-01" }
    "delete-vm"          { Invoke-DeleteVm         -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "storage-migrate"    { Invoke-StorageMigrate   -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "apply-update"       { Invoke-ApplyUpdate      -Url $Url -UserName $UserName -Password $Password }
    "checkpoint-vm"      { Invoke-CheckpointVm     -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "attach-disk"        { Invoke-AttachDisk       -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" -SrName "Shared NFS" }
    "wait-for-task"      { Invoke-WaitForTask      -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "error-handling"     { Invoke-ErrorHandling    -Url $Url -UserName $UserName -Password $Password }
    "list-templates"     { Invoke-ListTemplates    -Url $Url -UserName $UserName -Password $Password }
    "custom-fields"      { Invoke-CustomFields     -Url $Url -UserName $UserName -Password $Password -VmName "web-01" }
    "gpu-inventory"      { Invoke-GpuInventory     -Url $Url -UserName $UserName -Password $Password }
    "read-metrics"       { Invoke-ReadMetrics      -Url $Url -UserName $UserName -Password $Password }
    "rename-object"      { Invoke-RenameObject     -Url $Url -UserName $UserName -Password $Password -VmName "web-01" }
    "vm-boot-config"     { Invoke-VmBootConfig     -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "host-info"          { Invoke-HostInfo         -Url $Url -UserName $UserName -Password $Password }
    "list-roles"         { Invoke-ListRoles        -Url $Url -UserName $UserName -Password $Password }
    "pool-properties"    { Invoke-PoolProperties   -Url $Url -UserName $UserName -Password $Password }
    "sr-usage"           { Invoke-SrUsage          -Url $Url -UserName $UserName -Password $Password }
    "manage-vif"         { Invoke-ManageVif        -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "list-networks"      { Invoke-ListNetworks     -Url $Url -UserName $UserName -Password $Password }
    "vbd-inventory"      { Invoke-VbdInventory     -Url $Url -UserName $UserName -Password $Password -VmName "db-01" }
    "pool-tags"          { Invoke-PoolTags         -Url $Url -UserName $UserName -Password $Password }
    "convert-to-template" { Invoke-ConvertToTemplate -Url $Url -UserName $UserName -Password $Password -TemplateName "Rocky Linux 8" }
    "find-by-uuid"       { Invoke-FindByUuid       -Url $Url -UserName $UserName -Password $Password -VmName "web-01" }
    "rolling-pool-update" { Invoke-RollingPoolUpdate -Url $Url -UserName $UserName -Password $Password }
    "cross-pool-copy-vm" { Invoke-CrossPoolCopyVm -Url $Url -UserName $UserName -Password $Password -DestUrl $WorkflowArgs[0] }
    "pvs-accelerator"    { Invoke-PvsAccelerator  -Url $Url -UserName $UserName -Password $Password }
    "configure-pvs-accelerator" { Invoke-ConfigurePvsAccelerator -Url $Url -UserName $UserName -Password $Password }
    "manage-ssh-access"  { Invoke-ManageSshAccess    -Url $Url -UserName $UserName -Password $Password }
    "manage-vtpm"        { Invoke-ManageVtpm         -Url $Url -UserName $UserName -Password $Password }
    "export-import-vm"   { Invoke-ExportImportVm    -Url $Url -UserName $UserName -Password $Password }
    "configure-dynamic-memory" { Invoke-ConfigureDynamicMemory -Url $Url -UserName $UserName -Password $Password }
    "manage-vm-media"    { Invoke-ManageVmMedia       -Url $Url -UserName $UserName -Password $Password }
    "backup-host-config" { Invoke-BackupHostConfig    -Url $Url -UserName $UserName -Password $Password }
    "manage-sr-lifecycle" { Invoke-ManageSrLifecycle  -Url $Url -UserName $UserName -Password $Password }
    "set-default-sr"     { Invoke-SetDefaultSr        -Url $Url -UserName $UserName -Password $Password }
    "server-status-report" { Invoke-ServerStatusReport -Url $Url -UserName $UserName -Password $Password }
    "disaster-recovery"  { Invoke-DisasterRecovery     -Url $Url -UserName $UserName -Password $Password }
    "manage-secureboot-certificates" { Invoke-ManageSecurebootCertificates -Url $Url -UserName $UserName -Password $Password }
    "restart-host"       { Invoke-RestartHost         -Url $Url -UserName $UserName -Password $Password }
    "manage-crash-dumps" { Invoke-ManageCrashDumps     -Url $Url -UserName $UserName -Password $Password }
    "vm-from-snapshot"   { Invoke-VmFromSnapshot      -Url $Url -UserName $UserName -Password $Password }
    "attach-existing-disk" { Invoke-AttachExistingDisk -Url $Url -UserName $UserName -Password $Password }
    "changed-block-tracking" { Invoke-ChangedBlockTracking -Url $Url -UserName $UserName -Password $Password }
    "control-domain-memory" { Invoke-ControlDomainMemory -Url $Url -UserName $UserName -Password $Password }
    "rrd-metrics"        { Invoke-RrdMetrics      -Url $Url -UserName $UserName -Password $Password }
    "reclaim-space"      { Invoke-ReclaimSpace    -Url $Url -UserName $UserName -Password $Password }
    "vm-ip-address"      { Invoke-VmIpAddress     -Url $Url -UserName $UserName -Password $Password }
    "manage-ad-users"    { Invoke-ManageAdUsers   -Url $Url -UserName $UserName -Password $Password }
    "create-iscsi-sr"    { Invoke-CreateIscsiSr   -Url $Url -UserName $UserName -Password $Password }
    "create-smb-sr"      { Invoke-CreateSmbSr     -Url $Url -UserName $UserName -Password $Password }
    "create-hba-sr"      { Invoke-CreateHbaSr     -Url $Url -UserName $UserName -Password $Password }
    "create-gfs2-sr"     { Invoke-CreateGfs2Sr    -Url $Url -UserName $UserName -Password $Password }
    "create-iso-sr"      { Invoke-CreateIsoSr     -Url $Url -UserName $UserName -Password $Password }
    "configure-nrpe"     { Invoke-ConfigureNrpe   -Url $Url -UserName $UserName -Password $Password }
    "configure-snmp"     { Invoke-ConfigureSnmp   -Url $Url -UserName $UserName -Password $Password }
    "configure-clustering" { Invoke-ConfigureClustering -Url $Url -UserName $UserName -Password $Password }
    "manage-pool-membership" { Invoke-ManagePoolMembership -Url $Url -UserName $UserName -Password $Password }
    "create-bond" { Invoke-CreateBond -Url $Url -UserName $UserName -Password $Password }
    "manage-vapp"         { Invoke-ManageVapp        -Url $Url -UserName $UserName -Password $Password }
    "attach-usb-device"   { Invoke-AttachUsbDevice   -Url $Url -UserName $UserName -Password $Password }
    "wlb-recommendations" { Invoke-WlbRecommendations -Url $Url -UserName $UserName -Password $Password }
    "configure-pool-options" { Invoke-ConfigurePoolOptions -Url $Url -UserName $UserName -Password $Password }
    "configure-console-access" { Invoke-ConfigureConsoleAccess -Url $Url -UserName $UserName -Password $Password }
    "configure-host-storage" { Invoke-ConfigureHostStorage -Url $Url -UserName $UserName -Password $Password }
    "configure-syslog"   { Invoke-ConfigureSyslog -Url $Url -UserName $UserName -Password $Password }
    "manage-driver-variants" { Invoke-ManageDriverVariants -Url $Url -UserName $UserName -Password $Password }
    default { Write-Error "unknown workflow: $Workflow"; exit 2 }
}
