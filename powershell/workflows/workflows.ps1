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

function Invoke-DetachAndForgetSr {
    # Detach an SR from every host, then forget it: XenCenter's Detach followed by Forget. Forget refuses an
    # SR that is still attached (SR_HAS_PBD), so unplug its PBDs first. Forgetting drops the pool's record of
    # the SR but leaves the data on the storage itself.
    param([Parameter(Mandatory = $true)][string]$Ref)
    (Get-XenSR -Ref $Ref).PBDs | ForEach-Object { Get-XenPBD -Ref $_.opaque_ref } |
        Where-Object { $_.currently_attached } |
        ForEach-Object { $_ | Invoke-XenPBD -XenAction Unplug }
    Invoke-XenSR -Ref $Ref -XenAction Forget
}

function Invoke-VmProvision {
    # Invoke-XenVM -XenAction Provision, after filling in the SR for every disk the template describes. A
    # template's other_config["disks"] names each disk's SR as sr="" (empty); a real host takes that
    # literally and Provision fails with UUID_INVALID, so point the disks at the pool's default SR first -
    # exactly what `xe vm-install` does before calling VM.provision itself.
    param([Parameter(Mandatory = $true)][string]$Ref)
    $vm = Get-XenVM -Ref $Ref
    $disks = $vm.other_config["disks"]
    if ($disks -and $disks.Contains('sr=""')) {
        $srUuid = (Get-XenSR -Ref (Get-XenPool | Select-Object -First 1).default_SR.opaque_ref).uuid
        # Set-XenVM -OtherConfig replaces the whole map, so copy it and change only "disks".
        $oc = @{}
        foreach ($k in $vm.other_config.Keys) { $oc[$k] = $vm.other_config[$k] }
        $oc["disks"] = $disks.Replace('sr=""', "sr=""$srUuid""")
        $vm | Set-XenVM -OtherConfig $oc
    }
    $vm | Invoke-XenVM -XenAction Provision
}

function Remove-VmAndDisks {
    # Destroy a VM (or snapshot, or template) an example made, and the disks it owns. Remove-XenVM removes
    # only the VM record and leaves its disks behind, so collect them first (from a fresh read of the VM:
    # an object from -PassThru may predate its disks) and destroy them afterwards - exactly what
    # Invoke-DeleteVm does by hand.
    param([Parameter(Mandatory = $true)][string]$Ref)
    $vdis = (Get-XenVM -Ref $Ref).VBDs |
        ForEach-Object { Get-XenVBD -Ref $_.opaque_ref } |
        Where-Object { $_.type -eq 'Disk' -and $_.VDI.opaque_ref -ne 'OpaqueRef:NULL' } |
        ForEach-Object { $_.VDI.opaque_ref }
    # A checkpoint (or a suspended VM) also owns a suspend image holding its memory, which no VBD points
    # at: destroy that as well.
    $suspendVdi = (Get-XenVM -Ref $Ref).suspend_VDI.opaque_ref
    if ($suspendVdi -and $suspendVdi -ne 'OpaqueRef:NULL') { $vdis = @($vdis) + $suspendVdi }
    Remove-XenVM -Ref $Ref
    $vdis | ForEach-Object { Remove-XenVDI -Ref $_ }
}

function Copy-OfGuest {
    # A throwaway VM with a working guest OS: a copy of an existing VM that has one.
    #
    # Suspend, checkpoint, live migration and clean shutdown all need the guest's cooperation: on a
    # running VM with no PV drivers xapi refuses them up front with VM_LACKS_FEATURE (a VM freshly
    # cloned from a template has no OS at all). So copy a VM that does have an OS and PV drivers,
    # without disturbing it: snapshot it (fine while it runs), clone the snapshot - a clone of a
    # snapshot is a template - and provision that into an ordinary VM. The snapshot is only needed for
    # the clone, so it goes again straight away.
    param(
        [Parameter(Mandatory = $true)][string]$SourceVmName,
        [Parameter(Mandatory = $true)][string]$NewVmName
    )
    $source = Get-XenVM -Name $SourceVmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot } |
        Select-Object -First 1
    if (-not $source) { throw "No VM named '$SourceVmName' was found." }
    $snapshot = $source | Invoke-XenVM -XenAction Snapshot -NewName "$NewVmName-source" -PassThru
    $vm = $snapshot | Invoke-XenVM -XenAction Clone -NewName $NewVmName -PassThru
    Invoke-VmProvision -Ref $vm.opaque_ref
    Remove-VmAndDisks -Ref $snapshot.opaque_ref
    return Get-XenVM -Ref $vm.opaque_ref
}

# Evacuate a host over its management network. Name the network: before CA-431418 (SDK 26.21) the
# cmdlet always calls the newest host.evacuate, and with no -Network it sends an empty network, which a
# real host refuses (PIF_NOT_PRESENT) as soon as there is a VM to move.
function Invoke-Evacuate {
    param([Parameter(Mandatory = $true)]$XenHost)
    $network = (Get-XenPIF | Where-Object {
        $_.management -and $_.host.opaque_ref -eq $XenHost.opaque_ref
    } | Select-Object -First 1).network.opaque_ref
    $XenHost | Invoke-XenHost -XenAction Evacuate -Network $network
}

function Wait-GuestAgent {
    # Wait, after Start, until the guest's PV drivers have reported in.
    #
    # xapi only offers the guest-dependent operations once the guest says it can do them, and
    # allowed_operations is where it says so: wait for clean_shutdown to appear there (the same check
    # that refuses it with VM_LACKS_FEATURE beforehand). A Linux kernel offers that early in boot, before
    # the agent runs (hot-plug needs the agent, and suspend needs its emulated disk unplugged), so wait for
    # the guest metrics to report the PV drivers too. A booting OS takes a while.
    param(
        [Parameter(Mandatory = $true)][string]$Ref,
        [int]$TimeoutSeconds = 300,
        [int]$IntervalSeconds = 2
    )
    $ready = {
        $vm = Get-XenVM -Ref $Ref
        $vm.allowed_operations -contains 'clean_shutdown' -and
            $vm.guest_metrics.opaque_ref -ne 'OpaqueRef:NULL' -and
            (Get-XenVMGuestMetrics -Ref $vm.guest_metrics.opaque_ref).PV_drivers_detected
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not (& $ready)) {
        if ((Get-Date) -gt $deadline) {
            throw ("the guest's PV drivers did not report in within ${TimeoutSeconds}s; does the " +
                   "source VM have a guest OS with PV drivers (XenServer VM Tools)?")
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Invoke-ProbeForFailure {
    # Return the XML a backend sends back on its deliberately-failing discovery probe.
    #
    # The New SR wizard (and XenRT) discover iSCSI/HBA LUNs by asking with an incomplete device-config
    # on purpose: the backend can't create anything from it yet, so it fails with an
    # SR_BACKEND_FAILURE_<n> error whose params carry an XML fragment describing what it found (the
    # IQNs on offer, then the LUNs behind one of them, or - for HBA - every LUN visible at all). A probe
    # that unexpectedly *succeeds* means the device-config was already complete - not the discovery
    # prompt this helper is looking for. (Never probe by attempting SR.create instead: on real storage a
    # create that unexpectedly succeeds formats the LUN.)
    param(
        [Parameter(Mandatory = $true)][string]$XenHostRef,
        [Parameter(Mandatory = $true)][hashtable]$DeviceConfig,
        [Parameter(Mandatory = $true)][string]$SmType
    )
    $succeeded = $false
    try {
        # SR.probe is a static call: the host goes in -XenHost, and -Ref (which the cmdlet insists on) is
        # ignored. Putting the host in -Ref instead sends an empty host, which a real host refuses with
        # HOST_OFFLINE.
        Invoke-XenSR -Ref "OpaqueRef:NULL" -XenAction Probe -XenHost $XenHostRef -DeviceConfig $DeviceConfig `
            -Type $SmType -SmConfig @{} -PassThru | Out-Null
        $succeeded = $true
    }
    catch {
        $ex = $_.Exception
        while ($ex -and -not $ex.ErrorDescription) { $ex = $ex.InnerException }
        if ($ex -and $ex.ErrorDescription) {
            for ($i = $ex.ErrorDescription.Count - 1; $i -ge 0; $i--) {
                $detail = $ex.ErrorDescription[$i]
                if ($detail -and $detail.Trim().StartsWith('<')) { return $detail }
            }
        }
        throw
    }
    if ($succeeded) {
        throw "SR.probe for $SmType succeeded without asking for more information; check the target address"
    }
}

function Select-TargetIqn {
    # Pick the IQN from an iSCSI discovery probe: the caller's, if named (it must be one the target
    # offers), else the first. An array usually offers many targets - one per LUN, often belonging to
    # different users - so on shared storage always name yours: SR.create formats the LUN behind it.
    param(
        [Parameter(Mandatory = $true)][xml]$IqnXml,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$TargetIqn
    )
    $offered = @($IqnXml.SelectNodes("//TargetIQN") | ForEach-Object { $_.InnerText })
    if (-not $TargetIqn) { return $offered[0] }
    if ($offered -notcontains $TargetIqn) { throw "target $Target does not offer IQN $TargetIqn" }
    return $TargetIqn
}

function Get-SelfSignedCertPem {
    # A throwaway self-signed certificate and private key (PEM), the way XenRT provisions one for its
    # own certificate tests. PowerShell 7 runs on .NET, which has a native crypto API for this - no
    # external tool needed (unlike PowerShell 5.1, where New-SelfSignedCertificate, or an
    # `openssl req -x509` shell-out - the same tool XenRT itself uses - would be the fallback).
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        "CN=sdk-example", $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(365))
    return $cert.ExportCertificatePem(), $rsa.ExportPkcs8PrivateKeyPem()
}

function Reconnect-AfterMasterChange {
    # Wait out a pool-wide xapi restart (pool.designate_new_master) and reconnect.
    #
    # designate_new_master returns BEFORE the change: for a while the old coordinator still answers,
    # and still says it is the coordinator, until xapi restarts across the pool. So reconnecting is not
    # enough - keep reconnecting until the pool names the new coordinator (by uuid; Connect-Example
    # follows HOST_IS_SLAVE to wherever the coordinator now is). XenRT's own helper likewise waits
    # minutes before trusting the pool again.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$NewMasterUuid,
        [int]$TimeoutSeconds = 600,
        [int]$IntervalSeconds = 5
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null
    while ((Get-Date) -lt $deadline) {
        try {
            $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
            $master = (Get-XenPool | Select-Object -First 1).master
            # The new coordinator answers before the pool has settled - calls made too soon fail
            # (HANDLE_INVALID on the operation's own task) - so also wait for every host to be back,
            # live and enabled.
            $settled = (Get-XenHost -Ref $master.opaque_ref).uuid -eq $NewMasterUuid -and
                -not (Get-XenHost | Where-Object {
                    -not $_.enabled -or -not (Get-XenHostMetrics -Ref $_.metrics.opaque_ref).live
                })
            if ($settled) { return $session }
            $session | Disconnect-XenServer
            $lastError = "the pool has not settled under the new coordinator"
        }
        catch { $lastError = $_ }
        Start-Sleep -Seconds $IntervalSeconds
    }
    throw "the pool did not come back after the master change: $lastError"
}

function Enable-WhenBooted {
    # Re-enable a host that has just come back. It reports itself live before xapi on it has finished
    # starting, and until then Enable fails HOST_STILL_BOOTING - so retry that.
    param($XenHost, [int]$TimeoutSeconds = 600, [int]$IntervalSeconds = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        try { $XenHost | Invoke-XenHost -XenAction Enable; return }
        catch {
            $ex = $_.Exception
            while ($ex -and -not $ex.ErrorDescription) { $ex = $ex.InnerException }
            if (-not ($ex -and $ex.ErrorDescription -and $ex.ErrorDescription[0] -eq "HOST_STILL_BOOTING") `
                    -or (Get-Date) -gt $deadline) {
                throw
            }
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
}

function Wait-ForRestart {
    # Wait for a host to come back from a reboot (Key "boot_time") or toolstack restart
    # ("agent_start_time"): until that other_config entry differs from -Before and the host is live.
    # Reconnects every time round, because the host restarting may be the coordinator this session
    # talks to; returns the new session.
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$HostUuid,
        [Parameter(Mandatory = $true)][string]$Key,
        $Before,
        [int]$TimeoutSeconds = 1800,
        [int]$IntervalSeconds = 10
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
            $xenHost = Get-XenHost -Uuid $HostUuid
            if ($xenHost.other_config[$Key] -ne $Before -and (Get-HostLive $xenHost)) { return $session }
            $session | Disconnect-XenServer
        }
        catch {
            # down, or xapi still starting: a connection error or any XenAPI failure, keep retrying.
        }
        if ((Get-Date) -gt $deadline) { throw "host $HostUuid did not come back in time" }
        Start-Sleep -Seconds $IntervalSeconds
    }
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

    Invoke-VmProvision -Ref $vm.opaque_ref
    Write-Host "Provisioned. is_a_template = $((Get-XenVM -Ref $vm.opaque_ref).is_a_template)"

    Remove-VmAndDisks -Ref $vm.opaque_ref
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
        [Parameter(Mandatory = $true)][string]$SourceVm,
        [string]$NewVmName = "sdk-example-lifecycle"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Suspend and clean shutdown need the guest's cooperation (VM_LACKS_FEATURE without PV drivers), so
    # the copy is made from SourceVm, a VM with a guest OS and PV drivers, and the example waits for the
    # guest to report in after starting. Suspend also needs a suspend-image SR (the VM's own, else the
    # pool's, else the host's); check one is actually configured before trying.
    $vm = Copy-OfGuest -SourceVmName $SourceVm -NewVmName $NewVmName
    $ref = $vm.opaque_ref

    function State { (Get-XenVM -Ref $ref).power_state }

    Write-Host "Initial power state: $(State)"

    # Start asynchronously: -Async -PassThru emits a Task, which pipes straight into Wait-XenTask.
    # -ShowProgress surfaces the task's progress - the idiom for long-running operations where you want
    # to track progress rather than block silently.
    $vm | Invoke-XenVM -XenAction Start -Async -PassThru | Wait-XenTask -ShowProgress
    Wait-GuestAgent -Ref $ref
    Write-Host "After start:    $(State)"

    # The emulated hardware (the device model) can be restarted under a running guest without rebooting
    # it - what you reach for when the VM's virtual devices misbehave.
    $vm | Invoke-XenVM -XenAction RestartDeviceModels
    Write-Host "Device models restarted; still $(State)"

    # VM.suspend needs a suspend-image SR actually configured (the VM's own, else the pool's, else the
    # resident host's - the same fallback order xapi's choose_suspend_sr uses) - VM_NO_SUSPEND_SR
    # otherwise. Check before trying rather than assuming one is set.
    if (Test-HasSuspendSr -Vm (Get-XenVM -Ref $ref)) {
        $vm | Invoke-XenVM -XenAction Suspend
        Write-Host "After suspend:  $(State)"
        $vm | Invoke-XenVM -XenAction Resume
        Wait-GuestAgent -Ref $ref   # the PV drivers reconnect after a resume
        Write-Host "After resume:   $(State)"
    }
    else {
        Write-Host "Skipping suspend/resume: no suspend-image SR is configured for this VM/pool/host"
    }

    # A clean shutdown asks the guest OS to shut itself down, as pressing the power button would.
    $vm | Invoke-XenVM -XenAction CleanShutdown
    Write-Host "After shutdown: $(State)"

    Remove-VmAndDisks -Ref $ref
    Write-Host "OK: vm-lifecycle"
    $session | Disconnect-XenServer
}

function Test-HasSuspendSr {
    # Whether VM.suspend has a suspend-image SR to use: the VM's own, else the pool's, else the resident
    # host's - the same fallback order xapi's choose_suspend_sr uses.
    param($Vm)
    if ($Vm.suspend_SR.opaque_ref -ne 'OpaqueRef:NULL') { return $true }
    $pool = Get-XenPool | Select-Object -First 1
    if ($pool.suspend_image_SR.opaque_ref -ne 'OpaqueRef:NULL') { return $true }
    return (Get-XenHost -Ref $pool.master.opaque_ref).suspend_image_sr.opaque_ref -ne 'OpaqueRef:NULL'
}
# Run it:
#   Invoke-VmLifecycle -Url https://xenserver -UserName root -Password $password -SourceVm 'web-01'

# --- 4. Manage VM disks: Deactivate / Resize / Activate -------------------------------
function Invoke-ManageVmDisks {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$SourceVm,
        [Parameter(Mandatory = $true)][string]$SrName,
        [string]$NewVmName = "sdk-example-vm-disks"
    )
    # Not the VM's root/boot disk: a real VM's system disk is Unpluggable=false (only a template's
    # non-system disks default to unpluggable), so Unplug on it fails on a real host with
    # VBD_NOT_UNPLUGGABLE - and the VM has to be running in the first place, or unplug fails with
    # VM_BAD_POWER_STATE. Work on a data disk this example adds to its own throwaway VM instead,
    # matching XenCenter's own "deactivate" action, which only ever targets additional disks, and tidy
    # up afterwards so the example is repeatable. No shrink: real SR backends refuse one outright
    # (SR_BACKEND_FAILURE_79), so this only ever grows.
    #
    # Plugging and unplugging a disk on a running VM needs the guest's PV drivers
    # (VM_MISSING_PV_DRIVERS otherwise), so the VM is a throwaway copy of SourceVm, a VM with a guest OS
    # and PV drivers.
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $vm = Copy-OfGuest -SourceVmName $SourceVm -NewVmName $NewVmName
    $ref = $vm.opaque_ref
    $vm | Invoke-XenVM -XenAction Start
    Wait-GuestAgent -Ref $ref

    $sr = Get-XenSR -Name $SrName | Select-Object -First 1
    if (-not $sr) { throw "No SR named '$SrName' was found." }
    $vdi = New-XenVDI -NameLabel "sdk-example-data-disk" -SR $sr -VirtualSize 4GB `
        -Type user -Sharable $false -ReadOnly $false -PassThru
    $device = (Get-XenVMProperty -Ref $ref -XenProperty AllowedVBDDevices)[0]
    $vbd = New-XenVBD -VM (Get-XenVM -Ref $ref) -VDI $vdi -Userdevice $device -Bootable $false `
        -Mode RW -Type Disk -Empty $false -PassThru
    $vbd | Invoke-XenVBD -XenAction Plug
    Write-Host "Disk attached:  $((Get-XenVBD -Ref $vbd.opaque_ref).currently_attached)"

    # Deactivate = VBD.unplug. The disk stays with the VM; it is just no longer live.
    Invoke-XenVBD -Ref $vbd.opaque_ref -XenAction Unplug
    Write-Host "After unplug:   $((Get-XenVBD -Ref $vbd.opaque_ref).currently_attached)"

    $size = (Get-XenVDI -Ref $vdi.opaque_ref).virtual_size
    Invoke-XenVDI -Ref $vdi.opaque_ref -XenAction Resize -Size ([int64]$size * 2)
    Write-Host "Resized:        $size -> $((Get-XenVDI -Ref $vdi.opaque_ref).virtual_size) bytes"

    Invoke-XenVBD -Ref $vbd.opaque_ref -XenAction Plug
    Write-Host "After plug:     $((Get-XenVBD -Ref $vbd.opaque_ref).currently_attached)"

    # Growing a disk that is attached and live is a DIFFERENT action, not a flag on the same one:
    # ResizeOnline tells the storage layer the guest is using the disk while it grows. Only some
    # storage drivers can (none of a stock XenServer 9's do), and the rest refuse with
    # SR_OPERATION_NOT_SUPPORTED - so ask the SR's driver (its SM record's features) first.
    $srType = (Get-XenSR -Ref $sr.opaque_ref).type
    $features = (Get-XenSM | Where-Object { $_.type -eq $srType } | Select-Object -First 1).features
    if ($features -and $features.ContainsKey("VDI_RESIZE_ONLINE")) {
        $grown = [int64](Get-XenVDI -Ref $vdi.opaque_ref).virtual_size + 1GB
        Invoke-XenVDI -Ref $vdi.opaque_ref -XenAction ResizeOnline -Size $grown
        Write-Host "Grown online:   $((Get-XenVDI -Ref $vdi.opaque_ref).virtual_size) bytes"
    }
    else {
        Write-Host "Grown online:   not supported by $srType storage; unplug, resize, plug as above"
    }

    $vm | Invoke-XenVM -XenAction HardShutdown
    Remove-VmAndDisks -Ref $ref
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
    # "wake-on-lan" is a real, still-supported mode and needs no credentials; the legacy "iLO"/"DRAC"
    # modes were removed from the real power-on plugin (REQ-811) and fail the moment host.power_on is
    # actually called ("{mode} script has been removed").
    Invoke-XenMethod -Session $session -Method 'host.set_power_on_mode' -Params @(
        $xenHost.opaque_ref, 'wake-on-lan', @{})
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

    # xapi checks its own preconditions before rotating - HA must be disabled, every host must be live,
    # no rolling pool upgrade may be in progress, and the pool must be licensed for it - and raises a
    # clear error naming which one failed rather than silently refusing. Report that explanation instead
    # of letting an unhandled failure speak for itself.
    $explanations = @{
        "HA_IS_ENABLED"                 = "HA is enabled on this pool; disable it first."
        "CANNOT_CONTACT_HOST"           = "a host in the pool is not reachable."
        "NOT_SUPPORTED_DURING_UPGRADE"  = "a rolling pool upgrade is in progress."
        "LICENCE_RESTRICTION"           = "this edition is not licensed for pool secret rotation."
    }
    try {
        # A pool-wide operation; existing sessions survive it.
        Invoke-XenPool -Ref $pool.opaque_ref -XenAction RotateSecret
        Write-Host "Rotated. Still connected: $(@(Get-XenPool).Count -eq 1)"
    }
    catch {
        $ex = $_.Exception
        while ($ex -and -not $ex.ErrorDescription) { $ex = $ex.InnerException }
        $code = if ($ex -and $ex.ErrorDescription) { $ex.ErrorDescription[0] } else { $_.Exception.Message }
        $explanation = if ($explanations.ContainsKey($code)) { $explanations[$code] } else { "see the error for detail" }
        Write-Host "Could not rotate the pool secret: $code ($explanation)"
    }
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

    # change_password on a ROOT session ignores the old password entirely (CA-13567, confirmed in
    # xapi_session.ml) - the call succeeds regardless of what is passed as the old password, so there is
    # no "wrong old password is rejected" demonstration to show here. The real gate is who may call this
    # at all: only a session with is_local_superuser may.
    Write-Host "is_local_superuser: $($session.IsLocalSuperuser)"

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
    $pool = Get-XenPool | Select-Object -First 1
    # A real, generated self-signed certificate, not a placeholder string: xapi decodes whatever is
    # handed to InstallTrustedCertificate/InstallServerCertificate as PEM and rejects anything that
    # isn't a well-formed certificate (INVALID_VALUE) on a real host.
    $certPem, $keyPem = Get-SelfSignedCertPem
    Write-Host "Certificates:   $(@(Get-XenCertificate).Count)"

    # Ca=$true: trusted as a root to verify a chain, not pinned as one specific leaf certificate.
    # Purpose=@(): general pool trust, not the licensing/ldaps-specific uses that enum also covers.
    # InstallTrustedCertificate returns nothing, so find the new record by diffing the set.
    # InstallTrustedCertificate/UninstallTrustedCertificate are the current API; the CA-specific pair
    # this example used to call (InstallCaCertificate/UninstallCaCertificate) were deprecated in favour.
    $before = @(Get-XenCertificate | ForEach-Object { $_.opaque_ref })
    Invoke-XenPool -Ref $pool.opaque_ref -XenAction InstallTrustedCertificate -Cert $certPem -Ca $true -Purpose @()
    $certRef = @(Get-XenCertificate | ForEach-Object { $_.opaque_ref } | Where-Object { $before -notcontains $_ })[0]
    Write-Host "After CA add:   $(@(Get-XenCertificate).Count)"

    # Actually replace the host's own TLS identity with a real certificate (what this workflow's name
    # promises, beyond CA trust), then reset it back to a fresh self-signed one.
    Invoke-XenHost -Ref $xenHost.opaque_ref -XenAction InstallServerCertificate `
        -Certificate $certPem -PrivateKey $keyPem -CertificateChain ''
    Write-Host "Host certificate replaced with a real, generated certificate."

    Invoke-XenHost -Ref $xenHost.opaque_ref -XenAction ResetServerCertificate
    Write-Host "Host certificate reset (a fresh self-signed identity)."

    Invoke-XenPool -Ref $pool.opaque_ref -XenAction UninstallTrustedCertificate -Certificate $certRef
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

    # Run it three times against a retention of two: the oldest is pruned away. Compare against the
    # snapshots the VM already had, so only the schedule's own are counted (and tidied up below).
    $before = @((Get-XenVM -Ref $vm.opaque_ref).snapshots | ForEach-Object { $_.opaque_ref })
    1..3 | ForEach-Object { Invoke-XenVMSS -Ref $vmss.opaque_ref -XenAction SnapshotNow | Out-Null }
    $kept = @((Get-XenVM -Ref $vm.opaque_ref).snapshots | ForEach-Object { $_.opaque_ref } |
        Where-Object { $before -notcontains $_ })
    Write-Host "Snapshots kept:   $($kept.Count) (retention 2)"

    # Tidy up: a schedule with VMs still on it cannot be destroyed (VMSS_HAS_VM), so take the VM off it
    # first. Destroying the schedule leaves the snapshots it took, so destroy those too, with their disks.
    Set-XenVM -VM $vm -SnapshotSchedule 'OpaqueRef:NULL'
    Remove-XenVMSS -Ref $vmss.opaque_ref
    $kept | ForEach-Object { Remove-VmAndDisks -Ref $_ }
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

    # VM_group.destroy already clears the group from every member VM's groups field - no need to remove
    # membership ourselves first.
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
    $wasRunning = (Get-XenVM -Ref $vm.opaque_ref).power_state -eq 'Running'

    $snap = $vm | Invoke-XenVM -XenAction Snapshot -NewName $SnapshotName -PassThru
    Write-Host "Created snapshot: $($snap.uuid)"

    # A client shows a thumbnail of what was on screen when the snapshot was taken, captured from the
    # VM's console at that moment. It is an HTTP transfer alongside the API, not an API call, so the
    # session id travels in the query string. ref names the VM's VNC (rfb) console, as XenCenter does
    # (the VM itself works too). Only a running VM has a console to capture, and a host that can't reach
    # it answers 404 or 500 instead of an image: the picture is incidental, so carry on. Still pure
    # PowerShell: Connect-Example has already trusted the server's certificate.
    if ((Get-XenVM -Ref $vm.opaque_ref).power_state -eq 'Running') {
        $console = (Get-XenVM -Ref $vm.opaque_ref).consoles |
            ForEach-Object { Get-XenConsole -Ref $_.opaque_ref } | Where-Object { $_.protocol -eq 'rfb' } |
            Select-Object -First 1
        $thumb = Invoke-WebRequest -UseBasicParsing -SkipHttpErrorCheck `
            -Uri "$Url/vncsnapshot?session_id=$($session.opaque_ref)&ref=$($console.opaque_ref)"
        if ($thumb.StatusCode -eq 200) { Write-Host "Thumbnail:      $($thumb.Content.Length) bytes of PNG" }
        else { Write-Host "Thumbnail:      none (the host answered HTTP $($thumb.StatusCode))" }
    }
    else {
        Write-Host "Thumbnail:      none (the VM is not running, so it has no console)"
    }

    # Revert the VM to the snapshot. The native cmdlet takes the VM (piped in) and the snapshot to
    # restore via -Snapshot. Reverting to a plain snapshot always leaves the VM Halted (xapi hard-shuts-
    # down a running VM before reverting it), even if it was Running a moment ago - restart it
    # afterwards if that's how we found it, so the workflow actually restores what it changed.
    $vm | Invoke-XenVM -XenAction Revert -Snapshot $snap
    Write-Host "Reverted VM to the snapshot."

    if ($wasRunning) {
        $vm | Invoke-XenVM -XenAction Start
        Write-Host "Restarted the VM (it was running before the revert)."
    }

    # A snapshot is itself a (special) VM record, with its own snapshot disks; destroy both to clean up
    # (the source VM's disks are untouched - they are not the snapshot's).
    Remove-VmAndDisks -Ref $snap.opaque_ref
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

    Invoke-DetachAndForgetSr -Ref $sr.opaque_ref
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
        [Parameter(Mandatory = $true)][string]$SourceVm,
        [Parameter(Mandatory = $true)][string]$SrName,
        [string]$NewVmName = "sdk-example-migrate"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Live migration needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers), so this moves a
    # throwaway copy of SourceVm, a VM with a guest OS and PV drivers. Only the VM's memory moves, so the
    # destination host has to see its disks already: a disk on local storage refuses with VM_REQUIRES_SR.
    # Put the copy's disks on the shared SR SrName first.
    $sr = Get-XenSR -Name $SrName | Where-Object { $_.shared } | Select-Object -First 1
    if (-not $sr) { throw "No shared SR named '$SrName' was found." }
    $vm = Copy-OfGuest -SourceVmName $SourceVm -NewVmName $NewVmName
    $ref = $vm.opaque_ref
    Move-DisksToSr -VmRef $ref -SrRef $sr.opaque_ref
    $vm | Invoke-XenVM -XenAction Start
    Wait-GuestAgent -Ref $ref

    $sourceHostRef = (Get-XenVM -Ref $ref).resident_on.opaque_ref
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
    Remove-VmAndDisks -Ref $vm.opaque_ref
    Write-Host "OK: live-migrate"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-LiveMigrate -Url https://xenserver -UserName root -Password $password -SourceVm 'web-01' -SrName 'Shared NFS'

# --- 11. Enter & exit maintenance mode -------------------------------------------------
function Invoke-HostMaintenance {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$SourceVm,
        [Parameter(Mandatory = $true)][string]$SrName,
        [string]$NewVmName = "sdk-example-maint"
    )
    # Evacuation needs somewhere else in the pool that can actually see the VM's disk - a VM whose only
    # disk is on local (non-shared) storage can't be evacuated at all (VM_REQUIRES_SR), and a pool's
    # installation-time default SR is commonly local storage. Put the pinned VM's disk on a shared SR
    # explicitly rather than trusting whatever the pool default happens to be. Evacuation also
    # live-migrates the guest, which needs its cooperation (VM_LACKS_FEATURE without PV drivers), so
    # SourceVm must have a guest OS with PV drivers.
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Choose a host that is not the pool coordinator, so the coordinator can receive its guests.
    $masterRef = (Get-XenPool | Select-Object -First 1).master.opaque_ref
    $xenHost = Get-XenHost | Where-Object { $_.opaque_ref -ne $masterRef } | Select-Object -First 1
    Write-Host "Maintenance host: $($xenHost.name_label)"

    # Pin a running VM to that host so evacuation has something to move.
    $sr = Get-XenSR -Name $SrName | Where-Object { $_.shared } | Select-Object -First 1
    if (-not $sr) { throw "No shared SR named '$SrName' was found." }
    $vm = Copy-OfGuest -SourceVmName $SourceVm -NewVmName $NewVmName
    $ref = $vm.opaque_ref
    Move-DisksToSr -VmRef $ref -SrRef $sr.opaque_ref
    $vm | Set-XenVM -Affinity $xenHost
    $vm | Invoke-XenVM -XenAction Start
    Wait-GuestAgent -Ref $ref
    Write-Host "Guest resident on:$((Get-XenHost -Ref (Get-XenVM -Ref $ref).resident_on).name_label)"

    # Enter maintenance mode: disable the host, then evacuate its guests.
    $xenHost | Invoke-XenHost -XenAction Disable
    Write-Host "After disable:    host.enabled = $((Get-XenHost -Ref $xenHost.opaque_ref).enabled)"
    Invoke-Evacuate -XenHost $xenHost
    Write-Host "After evacuate:   guest now on $((Get-XenHost -Ref (Get-XenVM -Ref $ref).resident_on).name_label)"

    # Exit maintenance mode.
    $xenHost | Invoke-XenHost -XenAction Enable
    Write-Host "After enable:     host.enabled = $((Get-XenHost -Ref $xenHost.opaque_ref).enabled)"

    # Tidy up so the example is repeatable.
    $vm | Invoke-XenVM -XenAction HardShutdown
    Remove-VmAndDisks -Ref $vm.opaque_ref
    Write-Host "OK: host-maintenance"
    $session | Disconnect-XenServer
}

function Move-DisksToSr {
    # Relocate every one of a (not-yet-started) VM's disks onto the given SR, the same VDI PoolMigrate
    # storage-migrate already demonstrates; reused here to guarantee a VM's disk lands on a *shared* SR
    # before pinning/starting it for an evacuation demo.
    param([Parameter(Mandatory = $true)][string]$VmRef, [Parameter(Mandatory = $true)][string]$SrRef)
    (Get-XenVM -Ref $VmRef).VBDs | ForEach-Object { Get-XenVBD -Ref $_.opaque_ref } |
        Where-Object { $_.type -eq 'Disk' -and $_.VDI.opaque_ref -ne 'OpaqueRef:NULL' } |
        ForEach-Object {
            if ((Get-XenVDI -Ref $_.VDI.opaque_ref).SR.opaque_ref -ne $SrRef) {
                Invoke-XenVDI -Ref $_.VDI.opaque_ref -XenAction PoolMigrate -SR $SrRef -Options @{}
            }
        }
}
# Run it:
#   Invoke-HostMaintenance -Url https://xenserver -UserName root -Password $password -SourceVm 'web-01' -SrName 'Shared NFS'

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

    # What HA does per VM. The restart priority decides which guests come back first after a host
    # failure, and whether a VM is protected at all; "restart" is protected, an empty string is not.
    $guest = Get-XenVM | Where-Object {
        -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot
    } | Select-Object -First 1

    # How many host failures can the pool tolerate WITH the VMs you mean to protect? Plan for those
    # (as XenCenter's HA wizard does): a target computed with none protected can be too high, and
    # protecting a VM afterwards then fails HA_OPERATION_WOULD_BREAK_FAILOVER_PLAN. The configuration
    # maps VM references (XenRef objects - a ref string fails to cast) to restart priorities.
    $guestRef = [XenAPI.XenRef[XenAPI.VM]]::Create($guest.opaque_ref)
    $ntol = $pool | Invoke-XenPool -XenAction HaComputeHypotheticalMaxHostFailuresToTolerate `
        -Configuration @{ $guestRef = "restart" } -PassThru
    Write-Host "Max failures:  $ntol"
    $pool | Set-XenPool -HaHostFailuresToTolerate $ntol

    $pool | Invoke-XenPool -XenAction EnableHa -HeartbeatSrs @($sr) -Configuration @{}
    try {
        Write-Host "HA enabled:    $((Get-XenPool | Select-Object -First 1).ha_enabled)"

        $was = $guest.ha_restart_priority
        $guest | Set-XenVM -HaRestartPriority "restart"
        $nowPriority = (Get-XenVM -Ref $guest.opaque_ref).ha_restart_priority
        Write-Host "$($guest.name_label) priority: '$was' -> '$nowPriority'"
        $guest | Set-XenVM -HaRestartPriority $was

        # And a pool-wide judgement call: if a guest shuts itself down from the inside, is that a
        # failure HA should undo, or an administrator's intent it should respect?
        $internal = (Get-XenPool -Ref $pool.opaque_ref).ha_reboot_vm_on_internal_shutdown
        Write-Host "Restart on internal shutdown: $internal"
    }
    finally {
        # Turn HA back off however the above went: left on, it blocks host reboots, coordinator
        # changes and more (HA_IS_ENABLED, HA_OPERATION_WOULD_BREAK_FAILOVER_PLAN).
        $pool | Invoke-XenPool -XenAction DisableHa
    }
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

    # VM.copy (like VM.clone) only works on a Halted VM - a running source fails with
    # VM_BAD_POWER_STATE - so shut it down first if it's running, and start it back up again after the
    # copy, rather than assuming the VM is already halted.
    $wasRunning = (Get-XenVM -Ref $source.opaque_ref).power_state -eq 'Running'
    if ($wasRunning) { $source | Invoke-XenVM -XenAction CleanShutdown }

    $copy = $source | Invoke-XenVM -XenAction Copy -NewName $CopyName -SR $sr -PassThru
    Write-Host "Copied VM:     $($copy.uuid)"
    Write-Host "Copy has $(@($copy.VBDs).Count) VBD(s), is_a_template = $($copy.is_a_template)"

    if ($wasRunning) { $source | Invoke-XenVM -XenAction Start }

    # Tidy up: destroy the copy and its disks, leaving the source VM intact.
    Remove-VmAndDisks -Ref $copy.opaque_ref
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
    Invoke-VmProvision -Ref $vm.opaque_ref

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
    Remove-VmAndDisks -Ref $vm.opaque_ref
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
function New-UpdateRepositories {
    # Introduce the pool's update repositories the way XenCenter does: the release's base packages
    # (Update=$false) and its update stream (Update=$true, which pool.sync_updates needs - otherwise
    # NO_REPOSITORY_ENABLED). A real host checks the URLs (INVALID_BASE_URL for an unknown domain), so
    # these are the XenServer CDN's, e.g. https://repo.ops.xenserver.com/xs9/{base,normal}.
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$RepoUrl,
        [Parameter(Mandatory = $true)][string]$SourceUrl
    )
    return @("base", "normal") | ForEach-Object {
        $stage = $_
        # Repository.introduce is a static-style create, so pass the NULL ref for the (ignored)
        # instance param.
        Invoke-XenRepository -Ref 'OpaqueRef:NULL' -XenAction Introduce -NameLabel "sdk-example-$stage" `
            -NameDescription "SDK example $stage repository" -BinaryUrl "$RepoUrl/$stage" `
            -SourceUrl "$SourceUrl/$stage" -Update ($stage -ne "base") -GpgkeyPath '' -PassThru
    }
}

function Invoke-ConfigureUpdates {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$RepoUrl,
        [Parameter(Mandatory = $true)][string]$SourceUrl
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $repos = @(New-UpdateRepositories -Session $session -RepoUrl $RepoUrl -SourceUrl $SourceUrl)
    Write-Host "Introduced repositories: $(($repos | ForEach-Object { $_.name_label }) -join ', ')"

    $pool = Get-XenPool | Select-Object -First 1
    # Remember the pool's own repositories, to put them back afterwards.
    $previous = @((Get-XenPool -Ref $pool.opaque_ref).repositories | ForEach-Object { $_.opaque_ref })
    $pool | Set-XenPool -Repositories @($repos | ForEach-Object { $_.opaque_ref })
    $pool | Set-XenPool -UpdateSyncEnabled $true
    $p = Get-XenPool -Ref $pool.opaque_ref
    Write-Host "Pool repositories: $($p.repositories.Count); auto-sync enabled: $($p.update_sync_enabled)"

    # Tidy up so the example is repeatable.
    $pool | Set-XenPool -UpdateSyncEnabled $false
    $pool | Set-XenPool -Repositories $previous
    $repos | ForEach-Object { $_ | Invoke-XenRepository -XenAction Forget }
    Write-Host "OK: configure-updates"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigureUpdates -Url https://xenserver -UserName root -Password $password `
#       -RepoUrl https://repo.ops.xenserver.com/xs9 -SourceUrl https://repo-src.ops.xenserver.com/xs9

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

    # Tidy up: destroy the clone and its (owned) disks.
    Remove-VmAndDisks -Ref $clone.opaque_ref
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
    Invoke-VmProvision -Ref $vm.opaque_ref
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
        [Parameter(Mandatory = $true)][string]$SourceVm,
        [string]$NewVmName = "sdk-example-storagemigrate"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # Moving a running VM's disk needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers), so
    # this works on a throwaway copy of SourceVm, a VM with a guest OS and PV drivers. (A halted VM's disk
    # moves too, without the guest; what VDI PoolMigrate always needs is a VM to move the disk for - a VDI
    # no VBD points at fails VDI_NEEDS_VM_FOR_MIGRATE.)
    $vm = Copy-OfGuest -SourceVmName $SourceVm -NewVmName $NewVmName
    $ref = $vm.opaque_ref
    $vm | Invoke-XenVM -XenAction Start
    Wait-GuestAgent -Ref $ref

    $vdiRef = (Get-XenVM -Ref $ref).VBDs |
        ForEach-Object { Get-XenVBD -Ref $_.opaque_ref } |
        Where-Object { $_.type -eq 'Disk' } |
        ForEach-Object { $_.VDI.opaque_ref } |
        Select-Object -First 1
    $sourceSr = (Get-XenVDI -Ref $vdiRef).SR.opaque_ref
    Write-Host "Disk is on SR: $((Get-XenSR -Ref $sourceSr).name_label)"

    # Pick a different SR that holds disks and that the VM's host can reach (a currently-attached PBD
    # there).
    $vmHost = (Get-XenVM -Ref $ref).resident_on.opaque_ref
    $reachableSrs = @(Get-XenPBD | Where-Object { $_.host.opaque_ref -eq $vmHost -and $_.currently_attached } |
        ForEach-Object { $_.SR.opaque_ref })
    $destSr = Get-XenSR | Where-Object {
        $_.opaque_ref -ne $sourceSr -and $_.content_type -ne 'iso' -and $_.type -notin @('iso', 'udev') -and
        $reachableSrs -contains $_.opaque_ref
    } | Select-Object -First 1

    # PoolMigrate returns the disk's new VDI: the copy on the destination SR replaces the original.
    $vdiRef = (Get-XenVDI -Ref $vdiRef | Invoke-XenVDI -XenAction PoolMigrate -SR $destSr -Options @{} -PassThru).opaque_ref

    $nowOn = (Get-XenVDI -Ref $vdiRef).SR.opaque_ref
    Write-Host "Disk moved to:  $((Get-XenSR -Ref $nowOn).name_label)"

    # Tidy up: the VM and the disks it now owns.
    $vm | Invoke-XenVM -XenAction HardShutdown
    Remove-VmAndDisks -Ref $ref
    Write-Host "OK: storage-migrate"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-StorageMigrate -Url https://xenserver -UserName root -Password $password -SourceVm 'web-01'

# --- 20. Apply updates from the CDN --------------------------------------------------
function Invoke-ApplyUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$RepoUrl,
        [Parameter(Mandatory = $true)][string]$SourceUrl
    )
    # pool.sync_updates needs at least one repository with Update enabled (NO_REPOSITORY_ENABLED
    # otherwise) - introduce and attach a throwaway one, and forget it again afterwards. Applying a
    # batch whose mandatory guidance needs an evacuation fails with HOST_EVACUATION_IS_REQUIRED unless
    # the host's resident VMs are moved off first; handle that rather than assuming an update batch
    # never asks for one. Only call Reboot/RestartAgent when the *returned* pending guidance actually
    # contains "reboot_host"/"restart_toolstack" (modern xapi, >=23.18.0, never auto-reboots - it only
    # records guidance) - not unconditionally after every apply.
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1
    $repos = @(New-UpdateRepositories -Session $session -RepoUrl $RepoUrl -SourceUrl $SourceUrl)
    # Remember the pool's own repositories, to put them back afterwards.
    $previous = @((Get-XenPool -Ref $pool.opaque_ref).repositories | ForEach-Object { $_.opaque_ref })
    $pool | Set-XenPool -Repositories @($repos | ForEach-Object { $_.opaque_ref })
    try {
        # Sync the pool's update metadata; -PassThru returns the hash identifying the synced set.
        $hash = $pool | Invoke-XenPool -XenAction SyncUpdates -PassThru
        Write-Host "Synced updates; hash length $($hash.Length)"

        # Apply the synced updates to each host (the hash is the action's -Hash parameter). XenCenter
        # then reads the reboot guidance to decide whether a Rolling Pool Upgrade reboot is needed.
        foreach ($xenHost in Get-XenHost) {
            try {
                $xenHost | Invoke-XenHost -XenAction ApplyUpdates -Hash $hash
            }
            catch {
                $ex = $_.Exception
                while ($ex -and -not $ex.ErrorDescription) { $ex = $ex.InnerException }
                if (-not ($ex -and $ex.ErrorDescription -and $ex.ErrorDescription[0] -eq "HOST_EVACUATION_IS_REQUIRED")) {
                    throw
                }
                Write-Host "  $($xenHost.name_label): needs evacuating first; evacuating and retrying"
                $xenHost | Invoke-XenHost -XenAction Disable
                Invoke-Evacuate -XenHost $xenHost
                $xenHost | Invoke-XenHost -XenAction ApplyUpdates -Hash $hash
                $xenHost | Invoke-XenHost -XenAction Enable
            }
            $guidance = @((Get-XenHost -Ref $xenHost.opaque_ref).pending_guidances)
            Write-Host "  $($xenHost.name_label): applied; pending guidance = [$($guidance -join ', ')]"
            if ($guidance -contains "reboot_host" -or $guidance -contains "restart_toolstack") {
                # As in rolling-pool-update: either restart returns before it has happened, and the
                # coordinator's takes this session with it - so wait for it, reconnecting.
                $key = if ($guidance -contains "reboot_host") { "boot_time" } else { "agent_start_time" }
                $before = (Get-XenHost -Ref $xenHost.opaque_ref).other_config[$key]
                if ($key -eq "boot_time") {
                    $xenHost | Invoke-XenHost -XenAction Reboot
                }
                else {
                    $xenHost | Invoke-XenHost -XenAction RestartAgent
                }
                $session = Wait-ForRestart -Url $Url -UserName $UserName -Password $Password `
                    -HostUuid $xenHost.uuid -Key $key -Before $before
            }
            # apply_updates disables the host while it works (auto_enable: a restart puts it back) - with no
            # restart to do, nothing re-enables it. Return it to service either way.
            Enable-WhenBooted -XenHost $xenHost
        }
    }
    finally {
        $pool | Set-XenPool -Repositories $previous
        $repos | ForEach-Object { $_ | Invoke-XenRepository -XenAction Forget }
    }
    Write-Host "OK: apply-update"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ApplyUpdate -Url https://xenserver -UserName root -Password $password `
#       -RepoUrl https://repo.ops.xenserver.com/xs9 -SourceUrl https://repo-src.ops.xenserver.com/xs9

# --- 21. Checkpoint & revert ---------------------------------------------------------
function Invoke-CheckpointVm {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$SourceVm,
        [string]$NewVmName = "sdk-example-checkpoint"
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # A checkpoint captures disk AND memory (unlike a plain snapshot), so the VM must be running.
    # Checkpointing needs the guest's cooperation (VM_LACKS_FEATURE without PV drivers), hence a copy of
    # SourceVm - a VM with a guest OS and PV drivers - rather than an OS-less template clone.
    $vm = Copy-OfGuest -SourceVmName $SourceVm -NewVmName $NewVmName
    $ref = $vm.opaque_ref
    $vm | Invoke-XenVM -XenAction Start
    Wait-GuestAgent -Ref $ref

    $checkpoint = $vm | Invoke-XenVM -XenAction Checkpoint -NewName "sdk-example-checkpoint-1" -PassThru
    Write-Host "Created checkpoint: $($checkpoint.uuid)"
    Write-Host "is_a_snapshot = $($checkpoint.is_a_snapshot)"

    $vm | Invoke-XenVM -XenAction Revert -Snapshot $checkpoint
    # A checkpoint's own power_state is always Suspended (it captures memory as well as disk), and
    # Revert restores exactly that - so the VM is Suspended here, not Running as it was before the
    # checkpoint, with a suspend_VDI holding the checkpoint's memory image. Resume clears that:
    # destroying a Suspended VM directly (as a bare "if Running: HardShutdown" check would, since the
    # VM is never Running here) leaves that suspend_VDI behind as a storage leak.
    Write-Host "Reverted the VM to the checkpoint; power state now: $((Get-XenVM -Ref $ref).power_state)"
    $vm | Invoke-XenVM -XenAction Resume

    # Tidy up. The checkpoint owns its own snapshot disks, separate from the VM's.
    Remove-VmAndDisks -Ref $checkpoint.opaque_ref
    $vm | Invoke-XenVM -XenAction HardShutdown
    Remove-VmAndDisks -Ref $ref
    Write-Host "OK: checkpoint-vm"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CheckpointVm -Url https://xenserver -UserName root -Password $password -SourceVm 'web-01'

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
    Invoke-VmProvision -Ref $vm.opaque_ref
    $ref = $vm.opaque_ref
    $sr = Get-XenSR -Name $SrName | Select-Object -First 1
    if (-not $sr) { throw "No SR named '$SrName' was found." }

    # Create a fresh VDI on the SR and attach it as a new VBD (a new virtual disk).
    $vdi = New-XenVDI -NameLabel "sdk-example-data-disk" -SR $sr -VirtualSize 8GB `
        -Type user -Sharable $false -ReadOnly $false -PassThru
    $device = (Get-XenVMProperty -Ref $ref -XenProperty AllowedVBDDevices)[0]
    New-XenVBD -VM (Get-XenVM -Ref $ref) -VDI $vdi -Userdevice $device -Bootable $false `
        -Mode RW -Type Disk -Empty $false | Out-Null
    Write-Host "Attached an 8 GiB disk on $($sr.name_label) as device $device"
    Write-Host "VM now has $(@((Get-XenVM -Ref $ref).VBDs).Count) VBD(s)"

    # Tidy up: destroy the VM (which removes its VBDs) and then its disks (Remove-XenVM leaves VDIs
    # behind), including the one just attached.
    Remove-VmAndDisks -Ref $ref
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
    Invoke-VmProvision -Ref $vm.opaque_ref
    $ref = $vm.opaque_ref

    # Set the vCPU topology and switch the VM to UEFI boot: firmware ("bios"/"uefi") lives in
    # HVM_boot_params, Secure Boot in platform["secureboot"]. "auto" (not a hard-coded "true") is the
    # real xe/XenCenter convention: xapi resolves it against whether the pool actually holds Secure Boot
    # certificates, at VM.start time - a hard "true" would claim Secure Boot is on even on a template
    # that was never set up for it, since Set-XenVM does no validation of its own.
    $vm | Set-XenVM -VCPUsMax 4 -VCPUsAtStartup 2 -HVMBootParams @{ order = "cdn"; firmware = "uefi" }
    $platform = (Get-XenVM -Ref $ref).platform
    $platform["secureboot"] = "auto"
    $vm | Set-XenVM -Platform $platform

    $configured = Get-XenVM -Ref $ref
    Write-Host "vCPUs: $($configured.VCPUs_at_startup)/$($configured.VCPUs_max)"
    Write-Host "Boot order: $($configured.HVM_boot_params['order'])"
    Write-Host "Boot mode: firmware=$($configured.HVM_boot_params['firmware']), secureboot=$($configured.platform['secureboot']) (resolved against pool certificates at boot)"

    Remove-VmAndDisks -Ref $vm.opaque_ref
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
    # Role is the one class XenCenter still bulk-downloads; RBAC subjects map to these roles. Role records
    # include every permission too; the roles a user can be granted are the ones made of permissions
    # (non-empty subroles), as xe role-list shows.
    $roles = Get-XenRole | Where-Object { $_.subroles.Count -gt 0 } |
        Select-Object -ExpandProperty name_label -Unique | Sort-Object
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
    Invoke-VmProvision -Ref $vm.opaque_ref
    $ref = $vm.opaque_ref

    $net = Get-XenNetwork | Select-Object -First 1
    $device = (Get-XenVMProperty -Ref $ref -XenProperty AllowedVIFDevices)[0]

    $vif = New-XenVIF -VM (Get-XenVM -Ref $ref) -Network $net -Device $device -MAC "" -MTU 1500 -PassThru
    Write-Host "Attached a VIF on device $device; VM now has $(@((Get-XenVM -Ref $ref).VIFs).Count) NIC(s)"

    $vif | Remove-XenVIF
    Remove-VmAndDisks -Ref $vm.opaque_ref
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
    Invoke-VmProvision -Ref $vm.opaque_ref  # now a real (halted) VM
    $ref = $vm.opaque_ref
    Write-Host "is_a_template after provision: $((Get-XenVM -Ref $ref).is_a_template)"

    # Converting a VM to a custom template is a one-way operation.
    $vm | Set-XenVM -IsATemplate $true
    Write-Host "is_a_template after convert:  $((Get-XenVM -Ref $ref).is_a_template)"

    Remove-VmAndDisks -Ref $vm.opaque_ref
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
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$RepoUrl,
        [Parameter(Mandatory = $true)][string]$SourceUrl
    )
    # Needs an enabled update repository the same way apply-update does - introduce and attach a
    # throwaway one, forget it again afterwards. Modern xapi (>=23.18.0) doesn't reboot a host for you:
    # it only records pending_guidances, so only reboot (or restart the toolstack) when the applied
    # batch actually asks for it.
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1
    $repos = @(New-UpdateRepositories -Session $session -RepoUrl $RepoUrl -SourceUrl $SourceUrl)
    # Remember the pool's own repositories, to put them back afterwards.
    $previous = @((Get-XenPool -Ref $pool.opaque_ref).repositories | ForEach-Object { $_.opaque_ref })
    $pool | Set-XenPool -Repositories @($repos | ForEach-Object { $_.opaque_ref })
    try {
        $hash = $pool | Invoke-XenPool -XenAction SyncUpdates -PassThru
        Write-Host "Synced updates; hash length $($hash.Length)"

        # The rolling pattern behind XenCenter's automated Install Updates:
        # disable -> evacuate -> apply -> reboot (only if asked) -> re-enable, one host at a time.
        foreach ($xenHost in Get-XenHost) {
            Write-Host "Updating $($xenHost.name_label):"
            $xenHost | Invoke-XenHost -XenAction Disable    # stop new VMs landing here
            Invoke-Evacuate -XenHost $xenHost   # move running guests to the rest of the pool
            $xenHost | Invoke-XenHost -XenAction ApplyUpdates -Hash $hash  # apply the synced updates
            $guidance = @((Get-XenHost -Ref $xenHost.opaque_ref).pending_guidances)
            Write-Host "  applied; pending guidance = [$($guidance -join ', ')]"
            if ($guidance -contains "reboot_host" -or $guidance -contains "restart_toolstack") {
                # Either restart returns before it has happened, and if this host is the coordinator it
                # takes this session with it - so note when the host last started, restart it, and
                # reconnect until it reports a newer start and is live again.
                $key = if ($guidance -contains "reboot_host") { "boot_time" } else { "agent_start_time" }
                $before = $xenHost.other_config[$key]
                if ($key -eq "boot_time") {
                    $xenHost | Invoke-XenHost -XenAction Reboot     # reboot into the updated software
                }
                else {
                    $xenHost | Invoke-XenHost -XenAction RestartAgent
                }
                $session = Wait-ForRestart -Url $Url -UserName $UserName -Password $Password `
                    -HostUuid $xenHost.uuid -Key $key -Before $before
            }
            Enable-WhenBooted -XenHost $xenHost   # return the host to service
        }
    }
    finally {
        $pool | Set-XenPool -Repositories $previous
        $repos | ForEach-Object { $_ | Invoke-XenRepository -XenAction Forget }
    }
    Write-Host "OK: rolling-pool-update"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-RollingPoolUpdate -Url https://xenserver -UserName root -Password $password `
#       -RepoUrl https://repo.ops.xenserver.com/xs9 -SourceUrl https://repo-src.ops.xenserver.com/xs9

# --- 42. Cross-pool copy a VM -------------------------------------------------------------------------
function Invoke-CrossPoolCopyVm {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$DestUrl,
        [string]$VmName = "db-01",
        # The destination pool's credentials, if they differ from the source's.
        [string]$DestUserName = $UserName,
        [string]$DestPassword = $Password
    )
    # Two pools, so two sessions. Every cmdlet takes -SessionOpaqueRef, so we drive each pool explicitly
    # (Connect-Example sets a default session too, but being explicit keeps the two pools apart).
    $source = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $dest = Connect-Example -Url $DestUrl -UserName $DestUserName -Password $DestPassword
    $srcRef = $source.opaque_ref
    $dstRef = $dest.opaque_ref

    # Destination: choose a host, network and SR, then ask for a receiver token (a string->string map).
    # The disks go to the destination pool's default SR and the data travels over the host's management
    # network - one both pools can certainly reach (the first network listed may well not be).
    $destPool = Get-XenPool -SessionOpaqueRef $dstRef | Select-Object -First 1
    $destHost = Get-XenHost -SessionOpaqueRef $dstRef -Ref $destPool.master.opaque_ref
    $destSr = Get-XenSR -SessionOpaqueRef $dstRef -Ref $destPool.default_SR.opaque_ref
    $managementPif = Get-XenPIF -SessionOpaqueRef $dstRef |
        Where-Object { $_.management -and $_.host.opaque_ref -eq $destHost.opaque_ref } | Select-Object -First 1
    $destNet = Get-XenNetwork -SessionOpaqueRef $dstRef -Ref $managementPif.network.opaque_ref
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
#   Invoke-CrossPoolCopyVm -Url https://poolA -UserName root -Password $password -DestUrl https://poolB `
#       [-DestUserName root -DestPassword $destPassword] [-VmName db-01]

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
                # NaN: a gap in the series, not a real sample - never let it stick.
                if ([double]::IsNaN($u)) { continue }
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
    # Compare case-insensitively: a real host's trim plugin answers "True" (capitalised).
    if ($result.Trim().ToLowerInvariant() -ne "true") { throw "trim plugin returned '$result'" }
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
        [Parameter(Mandatory = $true)][string]$Password,
        [int]$TimeoutSeconds = 60,
        [int]$IntervalSeconds = 2
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # A VM that has only just started may not have reported in yet (no guest_metrics at all, or an
    # empty networks map) - retry for a while rather than giving up on the first look, the way XenRT's
    # own IP-discovery helpers do (they retry and fall back through several strategies for up to several
    # minutes before concluding a guest has no usable address).
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        # A running guest reports its IP in networks, keyed "<vif device>/ip" (e.g. "0/ip").
        $vm = Get-XenVM | Where-Object {
            $_.power_state -eq 'Running' -and -not $_.is_a_template -and -not $_.is_control_domain -and
            $_.guest_metrics.opaque_ref -ne 'OpaqueRef:NULL'
        } | Select-Object -First 1
        $ip = $null
        if ($vm) {
            $networks = (Get-XenVMGuestMetrics -Ref $vm.guest_metrics.opaque_ref).networks
            if ($networks.ContainsKey("0/ip")) { $ip = $networks["0/ip"] }
        }
        if ($ip) {
            Write-Host "  $($vm.name_label): $ip"
            break
        }
        if ((Get-Date) -gt $deadline) {
            throw "no running guest reported an IP address within ${TimeoutSeconds}s"
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
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
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$Domain = "",
        [string]$AdminUser = "alice",
        [string]$AdminPassword = "Password1",
        [string]$NewUser = "alice",
        [string]$Ldaps = "false"
    )
    # Needs a real, reachable AD domain controller - enable_external_auth fails at the very first call
    # (DNS/LDAP/Kerberos) without one, so Domain/AdminUser/AdminPassword have to identify a real domain
    # to join. Before joining, every host must resolve the domain (point its DNS at a domain controller)
    # and keep its clock close to the DC's (Kerberos). Current Windows DCs want LDAPS (Ldaps="true"),
    # which also needs the pool to trust the DC's CA certificate (pool.install_trusted_certificate with
    # purpose "ldaps"). NewUser is the account to grant a role to; its subject identity is looked up
    # against the directory, so it has to be a real account there too. A pool already joined to this
    # domain is used as it is - and left joined. The simulator models a single-user, domain-less fake
    # directory (hence the empty Domain default) - override every one of these on a real pool.
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    # The compiled module's AD cmdlets are awkward to script, so the AD calls go over JSON-RPC (the module
    # already trusts the server cert after Connect) — the same approach as the events example.
    function Rpc([string]$Method, [object[]]$P) {
        $body = @{ jsonrpc = "2.0"; id = 1; method = $Method; params = @($session.opaque_ref) + $P } | ConvertTo-Json -Depth 8
        $r = Invoke-RestMethod -Uri "$($session.Url)/jsonrpc" -Method Post -Body $body -ContentType "application/json"
        if ($r.error) { throw "$Method failed: $($r.error | ConvertTo-Json -Compress)" }
        $r.result
    }

    $pool = @(Rpc "pool.get_all" @())[0]
    $coordinator = Rpc "pool.get_master" @($pool)
    $alreadyJoined = $Domain -and (Rpc "host.get_external_auth_type" @($coordinator)) -eq "AD" `
        -and (Rpc "host.get_external_auth_service_name" @($coordinator)) -ieq $Domain
    if ($alreadyJoined) {
        Write-Host "Already joined to domain: $Domain"
    } else {
        Rpc "pool.enable_external_auth" @($pool, @{ user = $AdminUser; pass = $AdminPassword; ldaps = $Ldaps }, $Domain, "AD") | Out-Null
        Write-Host "Joined domain: $(if ($Domain) { $Domain } else { "(none - simulator's fake directory)" })"
    }

    # Add an AD user as a subject and grant it the pool-admin role (found via the Get-XenRole cmdlet,
    # simpler/more idiomatic than filtering Get-XenRole's own roles - matches what
    # `xe subject-role-add role-name=` does server-side).
    $subjectName = if ($Domain) { "$NewUser@$Domain" } else { $NewUser }
    $sid = Rpc "auth.get_subject_identifier" @($subjectName)
    $info = Rpc "auth.get_subject_information_from_identifier" @($sid)
    # other_config/roles are accepted here but discarded by real xapi (it re-derives other_config from
    # AD itself, and roles isn't a settable constructor field) - subject.add_to_roles below is the call
    # that actually matters.
    $subject = Rpc "subject.create" @(@{ subject_identifier = $sid; other_config = @{}; roles = @() })
    $adminRole = Get-XenRole -Name 'pool-admin' | Select-Object -First 1
    Rpc "subject.add_to_roles" @($subject, $adminRole.opaque_ref) | Out-Null
    Write-Host "Added subject $($info.'subject-displayname') ($($info.'subject-name')) as pool-admin"

    # Revoking access does not end sessions the user already has: logging the subject out is a separate
    # act, and the one that actually gets them off the pool now rather than at next login.
    $loggedIn = @(Rpc "session.get_all_subject_identifiers" @())
    Write-Host "Logged-in subjects: $($loggedIn.Count)"
    Rpc "session.logout_subject_identifier" @($sid) | Out-Null
    Write-Host "  logged out $($info.'subject-name')"

    # Tidy up (remove the role assignment, then the subject).
    Rpc "subject.remove_from_roles" @($subject, $adminRole.opaque_ref) | Out-Null
    Rpc "subject.destroy" @($subject) | Out-Null
    if (-not $alreadyJoined) {
        # Leave the way it was found. Passing the admin credentials also removes the pool's computer
        # accounts from the directory; with {} they stay behind in AD.
        Rpc "pool.disable_external_auth" @($pool, @{ user = $AdminUser; pass = $AdminPassword }) | Out-Null
    }
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
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$Port,
        [string]$ChapUser,
        [string]$ChapPassword,
        [string]$TargetIqn,
        [string]$SrName = "sdk-example-iscsi"
    )
    # Connect an SR to a LUN on the iSCSI target, discovering the IQN and the LUN the way the New SR
    # wizard and XenRT do: a device-config that's missing a piece makes the backend fail on purpose, and
    # the failure carries an XML fragment listing what it needs next.
    #
    # SR.create formats the chosen LUN - this is destructive, so pick carefully on a real target: pass
    # TargetIqn to name yours (see Select-TargetIqn).
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    $dc = @{ target = $Target }
    if ($Port) { $dc["port"] = $Port }
    if ($ChapUser) { $dc["chapuser"] = $ChapUser; $dc["chappassword"] = $ChapPassword }

    # First failing probe: target only -> the backend lists the IQNs it offers.
    $iqnXml = [xml](Invoke-ProbeForFailure -XenHostRef $xenHost.opaque_ref -DeviceConfig $dc -SmType lvmoiscsi)
    $dc["targetIQN"] = Select-TargetIqn -IqnXml $iqnXml -Target $Target -TargetIqn $TargetIqn
    Write-Host "Discovered IQN: $($dc['targetIQN'])"

    # Second failing probe: +targetIQN -> the backend lists the LUNs behind it. Real create also
    # carries LUNid, which XenRT's own LUN-preparation helper always includes when known.
    $lunXml = [xml](Invoke-ProbeForFailure -XenHostRef $xenHost.opaque_ref -DeviceConfig $dc -SmType lvmoiscsi)
    $luns = @($lunXml.SelectNodes("//LUN"))
    $lun = $luns[0]
    $dc["SCSIid"] = $lun.SCSIid
    $lunIdNode = $lun.SelectSingleNode("LUNid")
    $dc["LUNid"] = if ($lunIdNode) { $lunIdNode.InnerText } else { [string]([array]::IndexOf($luns, $lun)) }
    Write-Host "Discovered LUN $($dc['LUNid']) (SCSIid $($dc['SCSIid']))"

    $sr = New-XenSR -XenHost $xenHost -DeviceConfig $dc -PhysicalSize 0 `
        -NameLabel $SrName -NameDescription "iSCSI SR created by the SDK example" `
        -Type "lvmoiscsi" -ContentType "user" -Shared $true -PassThru
    Write-Host "Created SR: $($sr.uuid) ($([math]::Floor([long]($sr.physical_size) / 1GB)) GiB)"
    Invoke-DetachAndForgetSr -Ref $sr.opaque_ref
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
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$Share,
        [Parameter(Mandatory = $true)][string]$SmbUsername,
        [Parameter(Mandatory = $true)][string]$SmbPassword,
        [string]$SrName = "sdk-example-smb"
    )
    # Connect a shared SR to an SMB/CIFS file share (create validates + sizes from the share).
    #
    # The password travels as a Secret, not plaintext device-config - the way XenRT and XenCenter both
    # do it, and the only form seen in real captured sr-create calls for this SR type.
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1

    $secret = New-XenSecret -Value $SmbPassword -OtherConfig @{} -PassThru
    $deviceConfig = @{
        # server is the share as one UNC path, //server/share: the SMB driver has no separate serverpath.
        server          = "//$Server$Share"
        username        = $SmbUsername
        password_secret = $secret.uuid
    }
    $sr = New-XenSR -XenHost $xenHost -DeviceConfig $deviceConfig -PhysicalSize 0 `
        -NameLabel $SrName -NameDescription "SMB SR created by the SDK example" `
        -Type "smb" -ContentType "user" -Shared $true -PassThru
    Write-Host "Created SR: $($sr.uuid) ($([math]::Floor([long]($sr.physical_size) / 1GB)) GiB)"
    Invoke-DetachAndForgetSr -Ref $sr.opaque_ref
    Remove-XenSecret -Ref $secret.opaque_ref
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
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$ScsiId = "",
        [string]$SrName = "sdk-example-hba"
    )
    # Connect a shared SR to a fibre-channel (HBA) LUN, discovering it the way the New SR wizard does:
    # probing with no SCSIid fails on purpose and lists every LUN the backend can see.
    #
    # SR.create formats the chosen LUN - this is destructive. On shared FC storage a host sees LUNs other
    # hosts are using, so name the one that is yours (-ScsiId); with none, the first LUN listed is taken,
    # which is only right on a dedicated test target.
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1

    # The root element varies by backend; find BlockDevice entries by tag wherever they are.
    $devlistXml = [xml](Invoke-ProbeForFailure -XenHostRef $xenHost.opaque_ref -DeviceConfig @{} -SmType lvmohba)
    $device = $devlistXml.SelectNodes("//BlockDevice") |
        Where-Object { -not $ScsiId -or $_.SCSIid -eq $ScsiId } | Select-Object -First 1
    if (-not $device) { throw "no LUN with SCSIid $ScsiId is visible to this host" }
    $scsiId = $device.SCSIid
    $path = $device.path
    Write-Host "Discovered LUN: SCSIid $scsiId on $path"

    # SCSIid is all lvmohba needs - it is what XenCenter's New SR wizard sends. (The probe's <path> is
    # for display: on a real host it reads like "/dev/sde [sdc] [sdg] [sdi]", one entry per path.)
    $deviceConfig = @{ SCSIid = $scsiId }
    $sr = New-XenSR -XenHost $xenHost -DeviceConfig $deviceConfig -PhysicalSize 0 `
        -NameLabel $SrName -NameDescription "HBA SR created by the SDK example" `
        -Type "lvmohba" -ContentType "user" -Shared $true -PassThru
    Write-Host "Created SR: $($sr.uuid) ($([math]::Floor([long]($sr.physical_size) / 1GB)) GiB)"
    Invoke-DetachAndForgetSr -Ref $sr.opaque_ref
    Write-Host "OK: create-hba-sr"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CreateHbaSr -Url https://xenserver -UserName root -Password $password

# --- 51. Create an ISO library SR ----------------------------------------------------
function Invoke-CreateIsoSr {
    # Connect an ISO-library SR to a file share of ISO images (here an NFS export, Location
    # "server:/path").
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$Location
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $xenHost = Get-XenHost | Select-Object -First 1
    $deviceConfig = @{ location = $Location; type = "nfs_iso" }
    $sr = New-XenSR -XenHost $xenHost -DeviceConfig $deviceConfig -PhysicalSize 0 `
        -NameLabel "sdk-example-iso" -NameDescription "ISO library created by the SDK example" `
        -Type "iso" -ContentType "iso" -Shared $true -PassThru
    Write-Host "Created ISO SR: $($sr.uuid)"
    Invoke-DetachAndForgetSr -Ref $sr.opaque_ref
    Write-Host "OK: create-iso-sr"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-CreateIsoSr -Url https://xenserver -UserName root -Password $password

# --- 52. Configure NRPE monitoring ---------------------------------------------------
function Invoke-ConfigureNrpe {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    # host.call_plugin is per-host - there is no pool-wide fan-out for plugin calls the way there is for
    # pool.enable_ssh - so configure every host in the pool, and restore each one to disabled again
    # afterwards.
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    foreach ($xenHost in Get-XenHost) {
        function Invoke-Nrpe([string]$Fn, [hashtable]$PluginArgs = @{}) {
            $xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin nrpe -Fn $Fn -Args $PluginArgs -PassThru
        }
        Write-Host "$($xenHost.name_label): NRPE status before: $((Invoke-Nrpe 'status').Trim())"
        Invoke-Nrpe 'enable' | Out-Null
        Invoke-Nrpe 'set-config' @{ allowed_hosts = "127.0.0.1,::1,10.0.0.5"; debug = "0"; ssl_logging = "0x00" } | Out-Null
        Invoke-Nrpe 'restart' | Out-Null
        Write-Host "  status after:  $((Invoke-Nrpe 'status').Trim())"
        foreach ($line in ((Invoke-Nrpe 'get-config') -split "`n")) {
            if ($line.StartsWith('allowed_hosts:')) {
                Write-Host "  allowed hosts: $($line.Split(':', 2)[1].Trim())"
            }
        }
        Invoke-Nrpe 'disable' | Out-Null   # restore: leave it as we found it
    }
    Write-Host "OK: configure-nrpe"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigureNrpe -Url https://xenserver -UserName root -Password $password

# --- 53. Configure SNMP monitoring ---------------------------------------------------
function Invoke-ConfigureSnmp {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$TrapDestination = "192.0.2.50"
    )
    # Enable the SNMP agent on every host with a community string and a trap destination, through the
    # snmp plugin.
    #
    # nmss is the list of real trap destinations SNMP notifications go to - an empty list never
    # configures where traps actually go, which is the whole point of "configure SNMP monitoring".
    # Plugin calls are per-host, so configure every host, and restore each one to disabled again
    # afterwards, the way XenRT's own SNMPServer.disable() does.
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $config = @{
        common = @{ enabled = "yes"; debug_log = "no" }
        agent  = @{ v2c = "yes"; v3 = "no"; community = "sdk-community"; user_name = "";
                    authentication_password = ""; authentication_protocol = "";
                    privacy_password = ""; privacy_protocol = "" }
        # Each trap destination needs a uuid of its own: the plugin refuses the whole config without one.
        nmss   = @(@{ uuid = [guid]::NewGuid().ToString(); address = $TrapDestination; port = 162; v2c = "yes"; v3 = "no";
                      community = "sdk-community"; user_name = ""; authentication_password = "";
                      authentication_protocol = ""; privacy_password = ""; privacy_protocol = "" })
    }
    $configJson = [string]($config | ConvertTo-Json -Compress -Depth 5)
    foreach ($xenHost in Get-XenHost) {
        # The plugin reports a refused config in its answer, not as an API error: check it.
        $answer = ($xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin snmp -Fn set-config `
            -Args @{ config = $configJson } -PassThru) | ConvertFrom-Json
        if ($answer.code -ne 0) { throw "set-config refused the configuration: $($answer.message)" }
        $status = ($xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin snmp -Fn status -Args @{} -PassThru) | ConvertFrom-Json
        $cfg = ($xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin snmp -Fn get-config -Args @{} -PassThru) | ConvertFrom-Json
        Write-Host "$($xenHost.name_label): SNMP enabled: $($status.result.enabled) / $($status.result.active)"
        $trapAddress = if (@($cfg.result.nmss).Count -gt 0) { $cfg.result.nmss[0].address } else { "(none)" }
        Write-Host "  community: $($cfg.result.agent.community), trap destination: $trapAddress"
        $restoreJson = [string](@{ common = @{ enabled = "no" } } | ConvertTo-Json -Compress -Depth 3)
        $xenHost | Invoke-XenHost -XenAction CallPlugin -Plugin snmp -Fn set-config `
            -Args @{ config = $restoreJson } -PassThru | Out-Null   # restore
    }
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

    # Shutdown tries each VM's clean shutdown and falls back to a hard one. CleanShutdown alone fails
    # OPERATION_PARTIALLY_FAILED if any member can't shut down cleanly (no guest OS or PV drivers).
    Invoke-XenVMAppliance -VMAppliance $vapp -XenAction Shutdown
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

    # Destroy refuses a VUSB that is still attached (OPERATION_NOT_ALLOWED) - on a running VM it gets
    # plugged in as soon as it's created, so unplug it first.
    if ((Get-XenVUSB -Ref $vusb.opaque_ref).currently_attached) {
        Invoke-XenVUSB -Ref $vusb.opaque_ref -XenAction Unplug
    }
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
        [string]$VmName = "web-01",
        [string]$WlbHostPort = "wlb.example:8012",
        [string]$WlbUsername = "wlbuser",
        [string]$WlbPassword = "wlbpass",
        [string]$WlbCertificate = ""
    )
    # Needs a real, reachable WLB appliance: InitializeWlb makes a synchronous HTTP call to it and raises
    # WLB_CONNECTION_REFUSED/WLB_CONNECTION_RESET if it can't connect - there is no way to fake this with
    # a placeholder. WlbHostPort is host:port, with NO URL scheme - that is the real wire format
    # (xe pool-initialize-wlb wlb_url="10.x.x.x:30601" ...), not a URL.
    #
    # The pool checks the appliance's TLS certificate (wlb_verify_cert), and only against the
    # certificates installed with -XenAction CertificateInstall - not InstallTrustedCertificate's. A
    # fresh appliance has a self-signed one, so pass it as WlbCertificate (a PEM file): without it
    # InitializeWlb fails with INTERNAL_ERROR "Connection failed: configuration failed." and no hint
    # that the certificate is the reason.
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool | Select-Object -First 1

    $certName = ""
    if ($WlbCertificate) {
        $certName = "sdk-example-wlb.pem"
        Invoke-XenPool -Ref $pool.opaque_ref -XenAction CertificateInstall `
            -NameParam $certName -Cert (Get-Content -Raw $WlbCertificate)   # pool-wide: no -Pool/-Ref target
    }
    Invoke-XenPool -Ref $pool.opaque_ref -XenAction InitializeWlb `
        -WlbUrl $WlbHostPort -WlbUsername $WlbUsername -WlbPassword $WlbPassword `
        -XenserverUsername $UserName -XenserverPassword $Password
    try {
        # Initializing connects the pool to the appliance but leaves balancing off: every WLB call
        # after this would fail WLB_DISABLED until it's switched on.
        Set-XenPool -Pool $pool -WlbEnabled $true
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

        # A VM's own are keyed by host and star-rate each destination: [0] "wlb", [1] the rating -
        # higher is better (a real appliance rated hosts 6.1 here, so not capped at XenCenter's five
        # stars). Right after connecting, the appliance is still discovering the pool and answers
        # WLB_INTERNAL_ERROR 4024 ("Pool discovery has not been started"), 4025 ("... has not been
        # completed"), then 4016 ("WLB does not have current metrics") - keep asking for a while.
        $vm = Get-XenVM -Name $VmName
        $deadline = (Get-Date).AddMinutes(10)
        while ($true) {
            try { $vmRecs = Invoke-XenVM -Ref $vm.opaque_ref -XenAction RetrieveWlbRecommendations -PassThru; break }
            catch {
                $ex = $_.Exception
                while ($ex -and -not $ex.ErrorDescription) { $ex = $ex.InnerException }
                if (-not ($ex -and $ex.ErrorDescription -and $ex.ErrorDescription[0] -eq "WLB_INTERNAL_ERROR" `
                        -and $ex.ErrorDescription[1] -in "4024", "4025", "4016") -or (Get-Date) -gt $deadline) {
                    throw
                }
                Start-Sleep -Seconds 15
            }
        }
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
    }
    finally {
        # Disconnect from the appliance however the above went, or the pool stays attached to it.
        Invoke-XenPool -Ref $pool.opaque_ref -XenAction DeconfigureWlb
        if ($certName) { Invoke-XenPool -Ref $pool.opaque_ref -XenAction CertificateUninstall -NameParam $certName }
    }
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

    # Clustering is what shared block storage needs before GFS2 thin provisioning. Run it over a network
    # every host is on - the management network - since corosync is latency-sensitive and a cluster that
    # loses quorum takes its GFS2 storage offline with it.
    $pifs = @(Get-XenPIF)
    $network = Get-XenNetwork -Ref ($pifs | Where-Object { $_.management } | Select-Object -First 1).network.opaque_ref
    $networkPifs = @($pifs | Where-Object { $_.network.opaque_ref -eq $network.opaque_ref })

    $cluster = Get-XenCluster | Select-Object -First 1
    $created = -not $cluster
    if ($created) {
        # Corosync must not lose its network, so each host's PIF on it has to refuse unplugging first:
        # Cluster.pool_create fails PIF_ALLOWS_UNPLUG otherwise. $networkPifs keeps the old settings.
        $networkPifs | ForEach-Object { Set-XenPIF -Ref $_.opaque_ref -DisallowUnplug $true }
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

    # Tidy up a cluster this example created (one that was already there stays), and the PIF settings.
    if ($created) {
        Invoke-XenCluster -Ref $cluster.opaque_ref -XenAction PoolDestroy
        $networkPifs | ForEach-Object { Set-XenPIF -Ref $_.opaque_ref -DisallowUnplug $_.disallow_unplug }
        Write-Host "Cluster removed again."
    }

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
    $originalRef = $pool.master.opaque_ref
    $original = $hosts | Where-Object { $_.opaque_ref -eq $originalRef }
    Write-Host "Coordinator: $($original.name_label)"
    foreach ($h in $hosts) {
        $tag = if ($h.opaque_ref -eq $originalRef) { " (coordinator)" } else { "" }
        Write-Host "  member: $($h.name_label)$tag"
    }

    # Promote another member. The pool database moves with the role and clients are redirected, so this
    # briefly interrupts management traffic — it does not move any VM.
    $other = $hosts | Where-Object { $_.opaque_ref -ne $originalRef } | Select-Object -First 1
    Invoke-XenPool -Ref $pool.opaque_ref -XenAction DesignateNewMaster -XenHost $other.opaque_ref
    Write-Host "Promoting:   $($other.name_label) (xapi restarts pool-wide; reconnecting)"

    $session = Reconnect-AfterMasterChange -Url $Url -UserName $UserName -Password $Password `
        -NewMasterUuid $other.uuid
    $pool = Get-XenPool | Select-Object -First 1
    Write-Host "Promoted:    $((Get-XenHost -Ref $pool.master.opaque_ref).name_label)"

    # Put it back. Ejecting a member (Pool.eject) is the other half of this surface and is deliberately
    # not shown: it cannot be undone from the pool, because rejoining is initiated by the ejected host.
    Invoke-XenPool -Ref $pool.opaque_ref -XenAction DesignateNewMaster -XenHost $originalRef
    Write-Host "Restoring:   $($original.name_label) (reconnecting again)"

    $session = Reconnect-AfterMasterChange -Url $Url -UserName $UserName -Password $Password `
        -NewMasterUuid $original.uuid
    $pool = Get-XenPool | Select-Object -First 1
    Write-Host "Restored:    $((Get-XenHost -Ref $pool.master.opaque_ref).name_label)"

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
    if (@($spares).Count -lt 2) {
        throw "$($xenHost.name_label) has $(@($spares).Count) spare NIC(s); a bond needs two that aren't the management interface"
    }
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
        [Parameter(Mandatory = $true)][string]$Password,
        [Parameter(Mandatory = $true)][string]$VmName
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # Check the VM first, before creating anything: it needs a NIC for the proxy to sit on. It need not
    # be running - a proxy on a halted VM just reports "stopped" until it starts.
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot } |
        Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }
    # A proxy may only sit on the VM's LOWEST-numbered NIC, so sort by device rather than taking the
    # first VIF — the list comes back in creation order, which is the same thing only by luck.
    $vif = $vm.VIFs | ForEach-Object { Get-XenVIF -Ref $_.opaque_ref } |
        Sort-Object { [int]$_.device } | Select-Object -First 1
    if (-not $vif) { throw "$VmName has no network interface to accelerate" }
    # ... and one that no site accelerates yet (a VIF takes one proxy: PVS_PROXY_ALREADY_PRESENT).
    $existing = Get-XenPVSProxy | Where-Object { $_.VIF.opaque_ref -eq $vif.opaque_ref } | Select-Object -First 1
    if ($existing) {
        throw "$VmName is already accelerated by site '$((Get-XenPVSSite -Ref $existing.site.opaque_ref).name_label)'"
    }

    # PVS_site.introduce and PVS_server.introduce are CONSTRUCTORS, and every parameter set of
    # Invoke-XenPVSSite / Invoke-XenPVSServer identifies an object that ALREADY EXISTS (-PVSSite / -Ref /
    # -Uuid / -Name). Introduce is in the -XenAction enum, but there is no way to call it: name an object
    # and it goes looking for one that isn't there yet; name none and PowerShell cannot choose between
    # four sets, so it fails at binding with AmbiguousParameterSet before the call is even attempted.
    # Same shape as Cluster.pool_create in configure-clustering — so, same answer: call the method over
    # JSON-RPC. Still pure PowerShell; no [XenAPI.*]:: statics.
    $site = Invoke-XenMethod -Session $session -Method 'PVS_site.introduce' `
        -Params @('sdk-example-pvs', 'Created by the SDK examples', '')
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

    $proxy = New-XenPVSProxy -Site $site -VIF $vif.opaque_ref -PassThru

    $record = Get-XenPVSSite -Ref $site
    Write-Host "Site '$($record.name_label)' with $($record.cache_storage.Count) cache(s) and $($record.servers.Count) server(s)"
    # "caching" means it is really accelerating: a site with no cache reports "initialised", and a proxy
    # on a VM whose NIC is unplugged reports "stopped".
    Write-Host "  $($vm.name_label): $($proxy.status)"

    # Forgetting the site only cascades its cache storage - a running proxy or a server it still has
    # makes forget refuse with PVS_SITE_CONTAINS_RUNNING_PROXIES/_SERVERS, so tear those down ourselves
    # first, in the same order every real PVS teardown uses. (Cache storage doesn't need a separate
    # call - forget cascades it correctly.)
    Remove-XenPVSProxy -Ref $proxy.opaque_ref
    foreach ($serverRef in (Get-XenPVSSite -Ref $site).servers) {
        Invoke-XenPVSServer -Ref $serverRef.opaque_ref -XenAction Forget
    }
    Invoke-XenPVSSite -Ref $site -XenAction Forget
    Write-Host "OK: configure-pvs-accelerator"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ConfigurePvsAccelerator -Url https://xenserver -UserName root -Password $password -VmName 'db-01'

# --- Manage SSH access -----------------------------------------------------------------
function Invoke-ManageSshAccess {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $pool = Get-XenPool
    # Each host's SSH as we found it, to put back at the end: disabling it is not the example's to keep.
    $before = @(Get-XenHost | ForEach-Object {
        [pscustomobject]@{ Ref = $_.opaque_ref; Enabled = $_.ssh_enabled; Timeout = $_.ssh_enabled_timeout } })

    # Timed access is the point: set the timeout first and the server stamps an expiry when SSH is
    # enabled, so a window opened for troubleshooting closes itself. set_ssh_enabled_timeout is itself a
    # pool-wide fan-out call, exactly like enable_ssh/disable_ssh - no need to loop hosts for it either.
    $pool | Set-XenPool -SshEnabledTimeout 3600

    # The pool action fans out to every host, so there is no need to loop for the enable itself.
    Invoke-XenPool -Pool $pool -XenAction EnableSsh
    Get-XenHost | ForEach-Object {
        Write-Host "$($_.name_label): ssh enabled=$($_.ssh_enabled), expires $($_.ssh_expiry.ToString('yyyyMMddTHH:mm:ssZ'))"
    }

    Invoke-XenPool -Pool $pool -XenAction DisableSsh
    Write-Host ("After disable: " + ((Get-XenHost | ForEach-Object { "$($_.name_label)=$($_.ssh_enabled)" }) -join ', '))

    foreach ($h in $before) {
        # first: enabling stamps the expiry from it
        Get-XenHost -Ref $h.Ref | Set-XenHost -SshEnabledTimeout $h.Timeout
        if ($h.Enabled) { Invoke-XenHost -Ref $h.Ref -XenAction EnableSsh }
    }
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

    # CBT is switched on for the VM's own disk, and every snapshot taken from then on inherits it. It
    # can't be switched on for a snapshot's disk after the fact (OPERATION_NOT_ALLOWED).
    $live = Get-FirstDisk -Snapshot $vm
    $wasEnabled = (Get-XenVDI -Ref $live).cbt_enabled
    if (-not $wasEnabled) { Invoke-XenVDI -Ref $live -XenAction EnableCbt }

    $first = Invoke-XenVM -VM $vm -XenAction Snapshot -NewName 'cbt-backup-1' -PassThru
    $second = Invoke-XenVM -VM $vm -XenAction Snapshot -NewName 'cbt-backup-2' -PassThru
    # Re-fetch the snapshots: the object -PassThru hands back is the VM as it was when created, and its
    # disks are attached a moment later, so its VBDs list is empty.
    $vdiFrom = Get-FirstDisk -Snapshot (Get-XenVM -Ref $first.opaque_ref)
    $vdiTo = Get-FirstDisk -Snapshot (Get-XenVM -Ref $second.opaque_ref)

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
    # still diff against it. DataDestroy refuses a disk that a VM still uses (VDI_IN_USE), so remove the
    # older snapshot's VM record first, as a backup tool does. The VDI record stays; its type changes.
    Remove-XenVM -Ref $first.opaque_ref
    Invoke-XenVDI -Ref $vdiFrom -XenAction DataDestroy
    $after = Get-XenVDI -Ref $vdiFrom
    Write-Host "  older snapshot is now type=$($after.type), still cbt_enabled=$($after.cbt_enabled)"

    # Tidy up: the newer snapshot and its disk, the metadata-only VDI, and CBT on the VM's own disk if
    # this example switched it on.
    Remove-VmAndDisks -Ref $second.opaque_ref
    Remove-XenVDI -Ref $vdiFrom
    if (-not $wasEnabled) { Invoke-XenVDI -Ref $live -XenAction DisableCbt }
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
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$VmName = 'db-01'
    )
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password

    # Name the VM: an export carries every block of its disks, so which VM matters (a large one takes a
    # long time, and fills the disk). Only a halted VM can be exported: its disks must not be changing
    # underneath the copy.
    $vm = Get-XenVM -Name $VmName |
        Where-Object { -not $_.is_a_template -and -not $_.is_control_domain -and -not $_.is_a_snapshot } |
        Select-Object -First 1
    if (-not $vm) { throw "No VM named '$VmName' was found." }
    if ($vm.power_state -ne 'Halted') { throw "$VmName must be halted to be exported" }
    Write-Host "Exporting $VmName"

    # Export and import are HTTP transfers alongside the API rather than API calls, so the session id
    # travels in the query string. Still pure PowerShell: Connect-Example has already trusted the
    # server's certificate.
    # A unique file, not a fixed name: an export is a real file on disk and two of them running at
    # once would otherwise fight over it.
    $path = Join-Path ([IO.Path]::GetTempPath()) "sdk-example-export-$([guid]::NewGuid().Guid).xva"
    try {
        # Stream both directions: -OutFile/-InFile stream to and from the file rather than buffering the
        # whole transfer in memory, as a real VM's export can be gigabytes.
        Invoke-WebRequest -Uri "$Url/export?session_id=$($session.opaque_ref)&uuid=$($vm.uuid)" `
            -OutFile $path -UseBasicParsing
        Write-Host ("  wrote {0:N1} MiB to {1}" -f ((Get-Item $path).Length / 1MB), (Split-Path $path -Leaf))

        # An XVA is a tar: ova.xml describes the VM, and the disk blocks follow in 1 MiB pieces, each with
        # its own checksum.
        $names = Get-TarEntryName -Path $path
        Write-Host ("  archive holds {0} and {1} disk block(s)" -f
            $names[0], (@($names | Where-Object { -not $_.EndsWith('.checksum') }).Count - 1))

        # The imported VM's ref is NOT in the /import response body on a real host - the only place it
        # appears is the task named in the task_id query parameter, so create one, pass it, and read the
        # task's result once the upload finishes, the same pattern backup-host-config/wait-for-task use.
        $task = New-XenTask -Label 'vm_import' -Description "importing $VmName back" -PassThru
        try {
            Invoke-WebRequest -Uri "$Url/import?session_id=$($session.opaque_ref)&task_id=$($task.opaque_ref)" `
                -Method Put -InFile $path -UseBasicParsing | Out-Null
            while ((Get-XenTask -Ref $task.opaque_ref).status -eq 'pending') { Start-Sleep -Milliseconds 500 }
            $finished = Get-XenTask -Ref $task.opaque_ref
            if ($finished.status -ne 'success') { throw "import failed: $($finished.error_info -join ' ')" }
            # The result lists the imported VMs (<value><array><data>OpaqueRef:...</data></array></value>
            # on a real host), so take the first reference in it.
            $imported = [regex]::Match($finished.result, 'OpaqueRef:[^<]+').Value
        }
        finally {
            Remove-XenTask -Ref $task.opaque_ref
        }
        Write-Host "  imported as $((Get-XenVM -Ref $imported).name_label)"

        # The import brought its own disks along; destroy those too, not just the VM record.
        Remove-VmAndDisks -Ref $imported
        Write-Host "OK: export-import-vm"
    }
    finally {
        # Always clean up the file, on failure too: a real export is gigabytes, not worth leaving behind.
        Remove-Item $path -ErrorAction SilentlyContinue
    }
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-ExportImportVm -Url https://xenserver -UserName root -Password $password -VmName db-01

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
    $hostUrl = Get-HostUrl -Url $Url -Address $vmHost.address
    Write-Host "Backing up $($vmHost.name_label)"

    # Both halves are served only by whichever host physically accepted the HTTP connection - the
    # handler ignores any ref= in the query string entirely, there is no forwarding to another pool
    # member. So backing up/restoring a host means opening the connection to THAT host's own address,
    # not to the pool's (coordinator) URL - a restore sent to the wrong host's connection silently
    # restores the WRONG host, not the one named by ref=. ref= is kept in the query string purely for
    # log-readability (a real host ignores it; it is not what makes this correct). Still pure
    # PowerShell: Connect-Example has already trusted the server's certificate.
    #
    # -OutFile/-InFile below already stream straight to/from disk rather than buffering the whole file,
    # and there is no idle-connection step to take after the transfer (unlike the Python/Java ports):
    # this module's cmdlets dispatch through the C# binding's Session/JsonRpcClient, whose
    # PerformPostRequest opens a brand-new HttpClient per XenAPI call and disposes it immediately
    # afterwards - there is no kept-alive session connection that a long transfer could leave idle.
    $path = Join-Path ([IO.Path]::GetTempPath()) "sdk-example-host-$([guid]::NewGuid().Guid).backup"
    Invoke-WebRequest -UseBasicParsing -OutFile $path -TimeoutSec 10 `
        -Uri "$hostUrl/host_backup?session_id=$($session.opaque_ref)&ref=$($vmHost.opaque_ref)"
    Write-Host "  wrote $((Get-Item $path).Length) bytes to $(Split-Path $path -Leaf)"

    Write-Host ("  restoring it to {0}: {1}" -f $vmHost.name_label,
        (Restore-ExampleHostConfig -Session $session -HostUrl $hostUrl -VMHost $vmHost -Path $path))
    if ($hosts.Count -gt 1) {
        # A real pool's hosts are all reachable from a management client; guard against a topology
        # (like this project's sim fixture) where a second host's address isn't actually routable from
        # the caller, and turn that into an informative message instead of a crash.
        $other = $hosts[1]
        $otherUrl = Get-HostUrl -Url $Url -Address $other.address
        try {
            $result = Restore-ExampleHostConfig -Session $session -HostUrl $otherUrl -VMHost $other -Path $path
        }
        catch {
            $result = "could not connect to $otherUrl directly ($($_.Exception.Message))"
        }
        Write-Host ("  restoring it to {0}: {1}" -f $other.name_label, $result)
    }

    Remove-Item $path
    Write-Host "OK: backup-host-config"
    $session | Disconnect-XenServer
}
# Run it:
#   Invoke-BackupHostConfig -Url https://xenserver -UserName root -Password $password

function Get-HostUrl {
    # Build the URL for a given host's own address, keeping the scheme and port the caller originally
    # connected with (a host's management address carries no port of its own).
    param([string]$Url, [string]$Address)
    $uri = [System.Uri]$Url
    $port = if ($uri.Port -gt 0) { ":$($uri.Port)" } else { "" }
    return "$($uri.Scheme)://$Address$port"
}

function Restore-ExampleHostConfig {
    # Uploads a backup to a host - over a connection opened to THAT host's own address - and reports
    # what the task says about it.
    #
    # An upload answers 200 as soon as it has read the request headers, because the client waits for
    # that before it starts sending the file. The outcome therefore cannot be in the status line: it
    # arrives on a task you create first, name in the URL, and poll once the upload has finished.
    param($Session, [string]$HostUrl, $VMHost, [string]$Path)

    $task = New-XenTask -Label 'host_restore' -Description 'restoring a configuration backup' -PassThru
    try {
        # The timeout covers the whole transfer: a backup is hundreds of MB, so allow for a slow network.
        Invoke-WebRequest -UseBasicParsing -Method Put -InFile $Path -TimeoutSec 1800 `
            -Uri ("$HostUrl/host_restore?session_id=$($Session.opaque_ref)" +
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
    $defaults = @()
    foreach ($capability in $catalogue.'system-status-capabilities'.capability) {
        $keys += $capability.key
        if ($capability.'default-checked' -eq 'yes') { $defaults += $capability.key }
        Write-Host ("  {0,-22} max {1,9} bytes  default={2,-3} pii={3}" -f
            $capability.key, $capability.'max-size', $capability.'default-checked', $capability.pii)
    }

    # The download is an HTTP transfer alongside the API, so the session id travels in the query string.
    # Still pure PowerShell: Connect-Example has already trusted the server's certificate.
    # Take the sections the host marks default-checked, as XenCenter's dialog does: asking for every
    # section can mean gigabytes (VM memory dumps, every log) and a long wait while the host builds it.
    $whole = Get-StatusReportSize -Url $Url -Session $session -Entries $defaults
    Write-Host ("default sections ({0} of {1}): {2} bytes" -f $defaults.Count, $keys.Count, $whole)

    # Pick a real, small section from the host's own catalogue rather than assuming a name: the
    # catalogue is server-defined (xen-bugtool's own --capabilities output), not a fixed client list,
    # and "xenserver-config" isn't one of the real keys any host actually publishes.
    $subsetKey = $keys | Where-Object { $_ -in @("firstboot", "network-status") } | Select-Object -First 1
    if (-not $subsetKey) { $subsetKey = $keys[0] }
    $subset = Get-StatusReportSize -Url $Url -Session $session -Entries @($subsetKey)
    Write-Host ("{0} only:   {1} bytes" -f $subsetKey, $subset)
    if ($subset -ge $whole) {
        Write-Host "  ERROR: selecting fewer sections did not produce a smaller bundle"
    }

    Write-Host "OK: server-status-report"
    $session | Disconnect-XenServer
}

function Get-StatusReportSize {
    # Downloads the bundle for the given capability keys (a tar archive) to a temp file, streaming it - a
    # report can be large - and returns its size. This example then deletes it; you'd keep it.
    param([string]$Url, $Session, [string[]]$Entries)
    $path = Join-Path ([IO.Path]::GetTempPath()) "sdk-example-status-$([guid]::NewGuid().Guid).tar"
    try {
        Invoke-WebRequest -UseBasicParsing -OutFile $path `
            -Uri ("$Url/system-status?session_id=$($Session.opaque_ref)&output=tar" +
                  "&entries=$($Entries -join ',')")
        (Get-Item $path).Length
    }
    finally {
        Remove-Item $path -ErrorAction SilentlyContinue
    }
}
# Run it:
#   Invoke-ServerStatusReport -Url https://xenserver -UserName root -Password $password

# --- Recover VMs after a disaster --------------------------------------------------------
function Invoke-DisasterRecovery {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$DrUrl
    )
    # Disaster recovery works by writing the pool's own database out to a storage repository as a disk of
    # type "metadata". That disk can be read back as a SEPARATE database - VDI.open_database hands you a
    # session scoped to it - so the ordinary calls describe the pool as it was replicated rather than the
    # pool you are connected to. Recovering reads from that database and writes into a live pool, which
    # is why the recover call is made on the metadata session and takes a live session as its
    # destination.
    #
    # That destination has to be a DIFFERENT, standby pool: recovering a VM back into the exact pool it
    # was replicated from can't actually succeed with force=false. The VM's uuid already exists there, so
    # VM.recover always takes the replace-or-fail path, and nothing replicated a moment ago from a live
    # database can ever be "newer" than the live object it came from - it fails with
    # VM_TO_IMPORT_IS_NOT_NEWER_VERSION. The one-line "fix" of passing force=true instead would make it
    # succeed by REPLACING (destroying and recreating) the live original - exactly the opposite of what a
    # DR demo should show. A second pool is the only way force=false succeeds (a brand-new VM object, not
    # a replace), and it's what every real DR workflow actually does.
    if (-not $DrUrl) {
        throw "disaster-recovery needs a second pool to recover into: pass dr_url=<url of a standby pool>"
    }
    $session = Connect-Example -Url $Url -UserName $UserName -Password $Password
    $drSession = Connect-Example -Url $DrUrl -UserName $UserName -Password $Password

    # Replication needs shared storage the standby pool can attach too, and only block storage (iSCSI,
    # HBA) supports it - an NFS SR fails SR_OPERATION_NOT_SUPPORTED. The server checks rather than taking
    # your word for it, so ask each candidate, as XenCenter's DR wizard does.
    $sr = Get-XenSR -SessionOpaqueRef $session.opaque_ref | Where-Object {
        $_.shared -and $_.content_type -ne 'iso'
    } | Where-Object {
        try {
            $_ | Invoke-XenSR -SessionOpaqueRef $session.opaque_ref -XenAction AssertSupportsDatabaseReplication
            $true
        }
        catch { $false }
    } | Select-Object -First 1
    if (-not $sr) { throw "no shared SR here supports database replication (it needs iSCSI or HBA storage)" }
    Write-Host "Replicating pool metadata to $($sr.name_label)"
    $sr | Invoke-XenSR -SessionOpaqueRef $session.opaque_ref -XenAction EnableDatabaseReplication

    $vdi = Get-XenVDI -SessionOpaqueRef $session.opaque_ref | Where-Object { $_.type -eq 'metadata' } |
        Select-Object -First 1
    Write-Host "  metadata disk: $($vdi.uuid)"

    # Two module limits meet here, so the metadata database is driven over JSON-RPC: Invoke-XenVDI
    # -XenAction OpenDatabase does not hand back the session it opens (even with -PassThru), and
    # -SessionOpaqueRef only accepts sessions the module created itself. Same escape hatch the event API
    # needs, and still pure PowerShell.
    $metadataRef = Invoke-XenMethod -Session $session -Method 'VDI.open_database' -Params @($vdi.opaque_ref)
    $metadata = [pscustomobject]@{ opaque_ref = $metadataRef; Url = $session.Url }

    # Only real guest VMs are recoverable - exclude templates, control domains and snapshots.
    $allRecords = Invoke-XenMethod -Session $metadata -Method 'VM.get_all_records' -Params @()
    $recoverable = @($allRecords.PSObject.Properties | Where-Object {
            -not $_.Value.is_a_template -and -not $_.Value.is_control_domain -and -not $_.Value.is_a_snapshot
        } | Sort-Object { $_.Value.name_label })
    Write-Host "  the replicated database describes $($recoverable.Count) recoverable VM(s)"

    # Only a VM whose disks are all on storage the standby pool can see can be recovered there - the check
    # runs on the METADATA session, and session_to says where the VM should land: the STANDBY pool's
    # session, not this one. Take the first (by name) that passes, as the DR wizard lists them.
    $target = $recoverable | Where-Object {
        try {
            Invoke-XenMethod -Session $metadata -Method 'VM.assert_can_be_recovered' `
                -Params @($_.Name, $drSession.opaque_ref) | Out-Null
            $true
        }
        catch { $false }
    } | Select-Object -First 1
    if (-not $target) { throw "no VM in the replicated database has all its disks on storage the standby pool can see" }
    $targetUuid = $target.Value.uuid
    $name = $target.Value.name_label
    Write-Host "  recovering $name"

    # force stays false - never true (see above: that's the one-line "fix" that would actually destroy a
    # live VM if ever pointed at the source pool).
    Invoke-XenMethod -Session $metadata -Method 'VM.recover' `
        -Params @($target.Name, $drSession.opaque_ref, $false) | Out-Null

    # It is a real VM on the standby pool now, not merely a call that returned - look it up by the uuid
    # full_restore preserved, not by name, on the DESTINATION session. NO fallback to the source pool:
    # a second pool is the only correct target (see above), so this always looks up and tidies up on the
    # destination only. (The frozen simulator's VM.recover is single-process and ignores session_to, so
    # this lookup may fail against it - that's a known, expected simulator limitation, not something to
    # work around here.)
    $recovered = Get-XenVM -SessionOpaqueRef $drSession.opaque_ref -Uuid $targetUuid
    Write-Host "  $name is $($recovered.power_state) on the standby pool"

    # Tidy up on the standby pool only, by uuid - never guess by name, and never touch the source pool.
    # Destroy the VM record but NOT its disks: they are the protected pool's own disks on the shared SR,
    # not copies.
    Remove-XenVM -SessionOpaqueRef $drSession.opaque_ref -Ref $recovered.opaque_ref

    $sr | Invoke-XenSR -SessionOpaqueRef $session.opaque_ref -XenAction DisableDatabaseReplication
    Write-Host "OK: disaster-recovery"
    $session | Disconnect-XenServer
    $drSession | Disconnect-XenServer
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
    if (-not $vm) {
        # This state is deliberately seeded by this project's simulator fixture, and XenRT builds it by
        # hand with specially-aged UEFI certs - it doesn't occur on a normally-provisioned pool. Report
        # cleanly instead of letting a bare "no such element" lookup error propagate.
        Write-Host "No guest needs a Secure Boot certificate refresh right now."
        Write-Host "OK: manage-secureboot-certificates"
        $session | Disconnect-XenServer
        return
    }
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
    Invoke-Evacuate -XenHost $xenHost
    Write-Host "  evacuated:  guests=$(Measure-HostGuest $xenHost)"

    $xenHost | Invoke-XenHost -XenAction Reboot
    # A real reboot takes minutes. Wait for the host to drop out and come back (live in its
    # host_metrics), then enable it. A host disabled the default way (auto_enable=true) re-enables
    # itself once its toolstack is up again, but only then - and one disabled with auto_enable=false
    # never does - so enable it explicitly rather than depend on either.
    Wait-HostLive -XenHost $xenHost -Want $false -TimeoutSeconds 600
    Wait-HostLive -XenHost $xenHost -Want $true -TimeoutSeconds 1200 -IntervalSeconds 10
    Enable-WhenBooted -XenHost $xenHost
    Write-Host "  rebooted, re-enabled: enabled=$((Get-XenHost -Ref $xenHost.opaque_ref).enabled)"

    # The other ending: off, and back on out of band - but only demonstrated if that is actually
    # configured, and waiting for each transition before starting the next: host.power_on has no retry
    # of its own and simply fails, "The host failed to power on.", if no mechanism is configured or
    # working.
    if ((Get-XenHost -Ref $xenHost.opaque_ref).power_on_mode) {
        $xenHost | Invoke-XenHost -XenAction Disable
        $xenHost | Invoke-XenHost -XenAction Shutdown
        Wait-HostLive -XenHost $xenHost -Want $false
        Write-Host "  shut down:  live=$(Get-HostLive $xenHost)"
        $xenHost | Invoke-XenHost -XenAction PowerOn
        Wait-HostLive -XenHost $xenHost -Want $true -TimeoutSeconds 1200 -IntervalSeconds 10
        Write-Host "  powered on: live=$(Get-HostLive $xenHost)"
        Enable-WhenBooted -XenHost $xenHost
        Write-Host "  re-enabled: enabled=$((Get-XenHost -Ref $xenHost.opaque_ref).enabled)"
    }
    else {
        Write-Host "  skipping shutdown/power-on: no out-of-band power-on mode is configured on this host"
    }

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

function Wait-HostLive {
    # Poll host_metrics.live until it matches, rather than issuing the next power command immediately -
    # real out-of-band power control has no retry of its own, so a tool that doesn't wait can issue a
    # second command while the first is still in flight.
    param($XenHost, [bool]$Want, [int]$TimeoutSeconds = 60, [int]$IntervalSeconds = 2)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-HostLive $XenHost) -ne $Want) {
        if ((Get-Date) -gt $deadline) { throw "host did not reach live=$Want in time" }
        Start-Sleep -Seconds $IntervalSeconds
    }
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

    # A snapshot is a VM record with is_a_snapshot (and is_a_template) set, and cloning it gives a custom
    # template that stands on its own while the snapshot stays put.
    $vm = Get-XenVM -Name $VmName | Select-Object -First 1
    $snapshot = $vm | Invoke-XenVM -XenAction Snapshot -NewName 'sdk-example-source-snapshot' -PassThru
    Write-Host "Snapshot of $VmName taken"

    # A clone of a snapshot is a template, not another snapshot: it stands on its own instead of being
    # filed under the original VM. Provision it to get an ordinary VM you can start.
    $newVm = $snapshot | Invoke-XenVM -XenAction Clone -NewName 'sdk-example-vm-from-snapshot' -PassThru
    Invoke-VmProvision -Ref $newVm.opaque_ref
    Write-Host "  new VM:      $($newVm.name_label) (is_a_template=$((Get-XenVM -Ref $newVm.opaque_ref).is_a_template))"

    # Another clone, left as the template it already is: a starting point to stamp more VMs from.
    $template = $snapshot | Invoke-XenVM -XenAction Clone -NewName 'sdk-example-template-from-snapshot' -PassThru
    Write-Host "  new template:$($template.name_label) (is_a_template=$((Get-XenVM -Ref $template.opaque_ref).is_a_template))"

    # Each clone made its own disks, and the snapshot has its own snapshot disks; destroy them all.
    foreach ($ref in @($newVm.opaque_ref, $template.opaque_ref, $snapshot.opaque_ref)) {
        Remove-VmAndDisks -Ref $ref
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

    # set_iscsi_iqn refuses an empty string (INVALID_VALUE); only restore it if this host actually had
    # one set before - a host that has never had an IQN configured has it empty, and there is no way to
    # set it back to empty through this call.
    if ($beforeIqn) { $xenHost | Set-XenHost -IscsiIqn $beforeIqn }
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
    # depends on whether the hardware is present and the driver already loaded. Host_driver.select
    # refuses a variant whose hardware isn't present (HOST_DRIVER_NO_HARDWARE) - and a host lists
    # drivers for plenty of devices it doesn't have - so pick a driver for hardware this host actually
    # has, and one of its variants that is usable.
    $usable = @($drivers | Sort-Object name | ForEach-Object {
        $driver = $_
        $driver.variants | Where-Object { (Get-XenDriverVariant -Ref $_.opaque_ref).hardware_present } |
            ForEach-Object { [pscustomobject]@{ Driver = $driver; Variant = $_ } }
    })
    if (-not $usable) { throw "no driver on $($xenHost.name_label) has a variant for hardware it has" }
    $target = $usable[0].Driver
    $variant = $usable[0].Variant
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
# objects each one operates on, plus a default (chosen to work against the simulator) for every other
# named parameter - the equivalent of Python's _wf(fn, **defaults) wrapper. The command line accepts
# key=value arguments after the password (captured in $WorkflowArgs above), overriding that workflow's
# default for the named parameter. In your own scripts you would call these functions directly (see the
# "Run it:" line under each) rather than through this dispatcher. cross-pool-copy-vm keeps its own
# positional form: the destination pool URL, then optionally that pool's credentials (if they differ from
# the source's) and the VM to copy.
if ($Workflow -eq "cross-pool-copy-vm") {
    if (-not $WorkflowArgs -or $WorkflowArgs.Count -notin 1, 3, 4) {
        Write-Error "usage: workflows.ps1 cross-pool-copy-vm <url> <user> <password> <destUrl> [<destUser> <destPassword> [<vmName>]]"
        exit 2
    }
    $copyArgs = @{ Url = $Url; UserName = $UserName; Password = $Password; DestUrl = $WorkflowArgs[0] }
    if ($WorkflowArgs.Count -ge 3) { $copyArgs.DestUserName = $WorkflowArgs[1]; $copyArgs.DestPassword = $WorkflowArgs[2] }
    if ($WorkflowArgs.Count -eq 4) { $copyArgs.VmName = $WorkflowArgs[3] }
    Invoke-CrossPoolCopyVm @copyArgs
    exit 0
}

$WORKFLOWS = @{
    "connect-inventory"              = @{ Function = "Invoke-ConnectInventory";             Defaults = @{} }
    "create-vm"                      = @{ Function = "Invoke-CreateVm";                     Defaults = @{ TemplateName = "Rocky Linux 8" } }
    "vm-lifecycle"                   = @{ Function = "Invoke-VmLifecycle";                  Defaults = @{ SourceVm = "web-01" } }
    "manage-vm-disks"                = @{ Function = "Invoke-ManageVmDisks";                Defaults = @{ SourceVm = "web-01"; SrName = "Shared NFS" } }
    "dismiss-alerts"                 = @{ Function = "Invoke-DismissAlerts";                Defaults = @{} }
    "host-power-on"                  = @{ Function = "Invoke-HostPowerOn";                  Defaults = @{} }
    "rotate-pool-secret"             = @{ Function = "Invoke-RotatePoolSecret";             Defaults = @{} }
    "change-root-password"           = @{ Function = "Invoke-ChangeRootPassword";           Defaults = @{} }
    "manage-certificates"            = @{ Function = "Invoke-ManageCertificates";           Defaults = @{} }
    "snapshot-schedule"              = @{ Function = "Invoke-SnapshotSchedule";             Defaults = @{ VmName = "web-01" } }
    "manage-vm-groups"               = @{ Function = "Invoke-ManageVmGroups";               Defaults = @{ VmName = "web-01" } }
    "snapshot-revert"                = @{ Function = "Invoke-SnapshotRevert";               Defaults = @{ VmName = "web-01" } }
    "create-nfs-sr"                  = @{ Function = "Invoke-CreateNfsSr";                  Defaults = @{ NfsServer = "192.0.2.10"; NfsPath = "/export/sdk" } }
    "create-network"                 = @{ Function = "Invoke-CreateNetwork";                Defaults = @{} }
    "edit-vm-properties"             = @{ Function = "Invoke-EditVmProperties";             Defaults = @{ VmName = "web-01" } }
    "events"                         = @{ Function = "Invoke-Events";                       Defaults = @{ VmName = "web-01" } }
    "new-vm-wizard"                  = @{ Function = "Invoke-NewVmWizard";                  Defaults = @{ TemplateName = "Rocky Linux 8" } }
    "live-migrate"                   = @{ Function = "Invoke-LiveMigrate";                  Defaults = @{ SourceVm = "web-01"; SrName = "Shared NFS" } }
    "host-maintenance"               = @{ Function = "Invoke-HostMaintenance";              Defaults = @{ SourceVm = "web-01"; SrName = "Shared NFS" } }
    "configure-ha"                   = @{ Function = "Invoke-ConfigureHa";                  Defaults = @{ HeartbeatSrName = "Shared NFS" } }
    "copy-vm"                        = @{ Function = "Invoke-CopyVm";                       Defaults = @{ VmName = "db-01"; SrName = "Shared NFS" } }
    "create-vm-with-vgpu"            = @{ Function = "Invoke-CreateVmWithVgpu";             Defaults = @{ TemplateName = "Rocky Linux 8" } }
    "tags-and-folders"               = @{ Function = "Invoke-TagsAndFolders";               Defaults = @{ VmName = "web-01" } }
    "configure-updates"              = @{ Function = "Invoke-ConfigureUpdates";             Defaults = @{ RepoUrl = "https://repo.ops.xenserver.com/xs9"; SourceUrl = "https://repo-src.ops.xenserver.com/xs9" } }
    "clone-vm"                       = @{ Function = "Invoke-CloneVm";                      Defaults = @{ VmName = "db-01" } }
    "delete-vm"                      = @{ Function = "Invoke-DeleteVm";                     Defaults = @{ TemplateName = "Rocky Linux 8" } }
    "storage-migrate"                = @{ Function = "Invoke-StorageMigrate";               Defaults = @{ SourceVm = "web-01" } }
    "apply-update"                   = @{ Function = "Invoke-ApplyUpdate";                  Defaults = @{ RepoUrl = "https://repo.ops.xenserver.com/xs9"; SourceUrl = "https://repo-src.ops.xenserver.com/xs9" } }
    "checkpoint-vm"                  = @{ Function = "Invoke-CheckpointVm";                 Defaults = @{ SourceVm = "web-01" } }
    "attach-disk"                    = @{ Function = "Invoke-AttachDisk";                   Defaults = @{ TemplateName = "Rocky Linux 8"; SrName = "Shared NFS" } }
    "wait-for-task"                  = @{ Function = "Invoke-WaitForTask";                  Defaults = @{ TemplateName = "Rocky Linux 8" } }
    "error-handling"                 = @{ Function = "Invoke-ErrorHandling";                Defaults = @{} }
    "list-templates"                 = @{ Function = "Invoke-ListTemplates";                Defaults = @{} }
    "custom-fields"                  = @{ Function = "Invoke-CustomFields";                 Defaults = @{ VmName = "web-01" } }
    "gpu-inventory"                  = @{ Function = "Invoke-GpuInventory";                 Defaults = @{} }
    "read-metrics"                   = @{ Function = "Invoke-ReadMetrics";                  Defaults = @{} }
    "rename-object"                  = @{ Function = "Invoke-RenameObject";                 Defaults = @{ VmName = "web-01" } }
    "vm-boot-config"                 = @{ Function = "Invoke-VmBootConfig";                 Defaults = @{ TemplateName = "Rocky Linux 8" } }
    "host-info"                      = @{ Function = "Invoke-HostInfo";                     Defaults = @{} }
    "list-roles"                     = @{ Function = "Invoke-ListRoles";                    Defaults = @{} }
    "pool-properties"                = @{ Function = "Invoke-PoolProperties";               Defaults = @{} }
    "sr-usage"                       = @{ Function = "Invoke-SrUsage";                      Defaults = @{} }
    "manage-vif"                     = @{ Function = "Invoke-ManageVif";                    Defaults = @{ TemplateName = "Rocky Linux 8" } }
    "list-networks"                  = @{ Function = "Invoke-ListNetworks";                 Defaults = @{} }
    "vbd-inventory"                  = @{ Function = "Invoke-VbdInventory";                 Defaults = @{ VmName = "db-01" } }
    "pool-tags"                      = @{ Function = "Invoke-PoolTags";                     Defaults = @{} }
    "convert-to-template"            = @{ Function = "Invoke-ConvertToTemplate";            Defaults = @{ TemplateName = "Rocky Linux 8" } }
    "find-by-uuid"                   = @{ Function = "Invoke-FindByUuid";                   Defaults = @{ VmName = "web-01" } }
    "rolling-pool-update"            = @{ Function = "Invoke-RollingPoolUpdate";            Defaults = @{ RepoUrl = "https://repo.ops.xenserver.com/xs9"; SourceUrl = "https://repo-src.ops.xenserver.com/xs9" } }
    "pvs-accelerator"                = @{ Function = "Invoke-PvsAccelerator";               Defaults = @{} }
    "configure-pvs-accelerator"      = @{ Function = "Invoke-ConfigurePvsAccelerator";      Defaults = @{ VmName = "db-01" } }
    "manage-ssh-access"              = @{ Function = "Invoke-ManageSshAccess";              Defaults = @{} }
    "manage-vtpm"                    = @{ Function = "Invoke-ManageVtpm";                   Defaults = @{} }
    "configure-dynamic-memory"       = @{ Function = "Invoke-ConfigureDynamicMemory";       Defaults = @{} }
    "manage-vm-media"                = @{ Function = "Invoke-ManageVmMedia";                Defaults = @{} }
    "backup-host-config"             = @{ Function = "Invoke-BackupHostConfig";             Defaults = @{} }
    "manage-sr-lifecycle"            = @{ Function = "Invoke-ManageSrLifecycle";            Defaults = @{} }
    "set-default-sr"                 = @{ Function = "Invoke-SetDefaultSr";                 Defaults = @{} }
    "server-status-report"           = @{ Function = "Invoke-ServerStatusReport";           Defaults = @{} }
    "disaster-recovery"              = @{ Function = "Invoke-DisasterRecovery";             Defaults = @{} }
    "manage-secureboot-certificates" = @{ Function = "Invoke-ManageSecurebootCertificates"; Defaults = @{} }
    "restart-host"                   = @{ Function = "Invoke-RestartHost";                  Defaults = @{} }
    "manage-crash-dumps"             = @{ Function = "Invoke-ManageCrashDumps";             Defaults = @{} }
    "configure-pool-options"         = @{ Function = "Invoke-ConfigurePoolOptions";         Defaults = @{} }
    "configure-console-access"       = @{ Function = "Invoke-ConfigureConsoleAccess";       Defaults = @{} }
    "configure-host-storage"         = @{ Function = "Invoke-ConfigureHostStorage";         Defaults = @{} }
    "configure-syslog"               = @{ Function = "Invoke-ConfigureSyslog";              Defaults = @{} }
    "manage-driver-variants"         = @{ Function = "Invoke-ManageDriverVariants";         Defaults = @{} }
    "vm-from-snapshot"               = @{ Function = "Invoke-VmFromSnapshot";               Defaults = @{ VmName = "db-01" } }
    "attach-existing-disk"           = @{ Function = "Invoke-AttachExistingDisk";           Defaults = @{} }
    "export-import-vm"               = @{ Function = "Invoke-ExportImportVm";               Defaults = @{ VmName = "db-01" } }
    "changed-block-tracking"         = @{ Function = "Invoke-ChangedBlockTracking";         Defaults = @{} }
    "control-domain-memory"          = @{ Function = "Invoke-ControlDomainMemory";          Defaults = @{} }
    "rrd-metrics"                    = @{ Function = "Invoke-RrdMetrics";                   Defaults = @{} }
    "reclaim-space"                  = @{ Function = "Invoke-ReclaimSpace";                 Defaults = @{} }
    "vm-ip-address"                  = @{ Function = "Invoke-VmIpAddress";                  Defaults = @{} }
    "manage-ad-users"                = @{ Function = "Invoke-ManageAdUsers";                Defaults = @{ Domain = ""; AdminUser = "alice"; AdminPassword = "Password1"; NewUser = "alice"; Ldaps = "false" } }
    "create-iscsi-sr"                = @{ Function = "Invoke-CreateIscsiSr";                Defaults = @{ Target = "192.0.2.30" } }
    "create-smb-sr"                  = @{ Function = "Invoke-CreateSmbSr";                  Defaults = @{ Server = "192.0.2.40"; Share = "/vmstore"; SmbUsername = "Administrator"; SmbPassword = "Password1" } }
    "create-hba-sr"                  = @{ Function = "Invoke-CreateHbaSr";                  Defaults = @{} }
    "create-iso-sr"                  = @{ Function = "Invoke-CreateIsoSr";                  Defaults = @{ Location = "192.0.2.10:/isos" } }
    "configure-nrpe"                 = @{ Function = "Invoke-ConfigureNrpe";                Defaults = @{} }
    "configure-snmp"                 = @{ Function = "Invoke-ConfigureSnmp";                Defaults = @{ TrapDestination = "192.0.2.50" } }
    "configure-clustering"           = @{ Function = "Invoke-ConfigureClustering";          Defaults = @{} }
    "manage-pool-membership"         = @{ Function = "Invoke-ManagePoolMembership";         Defaults = @{} }
    "create-bond"                    = @{ Function = "Invoke-CreateBond";                   Defaults = @{} }
    "manage-vapp"                    = @{ Function = "Invoke-ManageVapp";                   Defaults = @{ VmName = "db-01" } }
    "attach-usb-device"              = @{ Function = "Invoke-AttachUsbDevice";              Defaults = @{ VmName = "web-01" } }
    "wlb-recommendations"            = @{ Function = "Invoke-WlbRecommendations";           Defaults = @{ VmName = "web-01"; WlbHostPort = "wlb.example:8012"; WlbUsername = "wlbuser"; WlbPassword = "wlbpass"; WlbCertificate = "" } }
}

if (-not $WORKFLOWS.ContainsKey($Workflow)) {
    Write-Error "usage: workflows.ps1 <$($WORKFLOWS.Keys -join '|')|cross-pool-copy-vm> <url> <user> <password> [key=value ...]"
    exit 2
}

$entry = $WORKFLOWS[$Workflow]
$callParams = @{ Url = $Url; UserName = $UserName; Password = $Password }
foreach ($k in $entry.Defaults.Keys) { $callParams[$k] = $entry.Defaults[$k] }
foreach ($arg in $WorkflowArgs) {
    if ($arg -notmatch '=') {
        Write-Error "extra arguments must be key=value (got '$arg')"
        exit 2
    }
    $parts = $arg -split '=', 2
    # The same key=value spelling as the other languages' samples (snake_case, e.g. source_vm=win) maps
    # onto this script's PascalCase parameters (-SourceVm); a PascalCase key works too.
    $key = (($parts[0] -split '_') | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join ''
    $callParams[$key] = $parts[1]
}

& $entry.Function @callParams
