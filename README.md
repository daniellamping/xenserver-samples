# XenServer SDK usage examples

This repository contains sample code for interacting with [XenServer](https://www.xenserver.com/)
using the XenServer SDK. The examples are provided as complete applications
or scripts that you can run on your server.

Apart from the ready-to-run code, this repository contains also a number of tips
or walk-throughs that you may find useful when developing products for XenServer.

The content of this repository can be used as a companion to the
[XenServer SDK Guide](https://docs.xenserver.com/en-us/xenserver/8/developer/sdk-guide).

## Workflow examples

The `workflows` folder in each language holds the same **91 real-world
workflows**, each implemented in every language: the five SDK bindings (C#, Java, PowerShell, Python
and Go) plus the `xe` command line interface. Pick the language you work in and you will find every
task there, written the same way.

Each workflow is a self-contained function that takes the connection details (and any object it acts
on, looked up by name) as parameters, opens its own session, cleans up after itself, and prints
`OK: <workflow>` on success. Copy one out and run it as-is; each carries a `Run it:` line showing the
call. The shared connect helper accepts a host's self-signed certificate and follows the pool-member to
coordinator redirect (`HOST_IS_SLAVE`), the way XenCenter does when you add a member server.

Every language's file can also run any workflow from the command line:

```
<program> <workflow> <url> <username> <password>
```

See each language's README for how to set up and run it.

| Area | Workflows |
|------|-----------|
| **Basics** | `connect-inventory`, `host-info`, `find-by-uuid`, `rename-object`, `error-handling`, `wait-for-task`, `events` |
| **VM lifecycle** | `create-vm`, `new-vm-wizard`, `vm-lifecycle`, `clone-vm`, `copy-vm`, `delete-vm`, `convert-to-template`, `list-templates`, `vm-boot-config`, `vm-ip-address`, `edit-vm-properties`, `configure-dynamic-memory`, `manage-vm-disks`, `manage-vm-media`, `manage-vtpm`, `manage-vapp`, `manage-vm-groups`, `attach-usb-device`, `export-import-vm` |
| **Snapshots, backup & migration** | `snapshot-revert`, `checkpoint-vm`, `snapshot-schedule`, `vm-from-snapshot`, `changed-block-tracking`, `live-migrate`, `storage-migrate`, `cross-pool-copy-vm`, `disaster-recovery` |
| **Storage** | `create-nfs-sr`, `create-smb-sr`, `create-iscsi-sr`, `create-hba-sr`, `create-gfs2-sr`, `create-iso-sr`, `manage-sr-lifecycle`, `set-default-sr`, `attach-disk`, `attach-existing-disk`, `vbd-inventory`, `sr-usage`, `reclaim-space`, `configure-host-storage` |
| **Networking** | `create-network`, `list-networks`, `manage-vif`, `create-bond` |
| **Hosts & pools** | `host-maintenance`, `restart-host`, `host-power-on`, `configure-ha`, `configure-clustering`, `manage-pool-membership`, `pool-properties`, `pool-tags`, `configure-pool-options`, `control-domain-memory`, `manage-driver-variants`, `manage-crash-dumps`, `backup-host-config`, `server-status-report`, `wlb-recommendations` |
| **Monitoring** | `read-metrics`, `rrd-metrics`, `dismiss-alerts`, `configure-syslog`, `configure-nrpe`, `configure-snmp` |
| **GPU** | `gpu-inventory`, `create-vm-with-vgpu` |
| **Updates** | `configure-updates`, `apply-update`, `rolling-pool-update` |
| **Security & access** | `list-roles`, `manage-ad-users`, `change-root-password`, `rotate-pool-secret`, `manage-certificates`, `manage-secureboot-certificates`, `manage-ssh-access`, `configure-console-access` |
| **Organisation** | `tags-and-folders`, `custom-fields` |
| **PVS Accelerator** | `pvs-accelerator`, `configure-pvs-accelerator` |

`cross-pool-copy-vm` takes the destination pool's URL as an extra, fifth argument.

> **Run these against a test pool, not production.** Several workflows change pool-wide state
> (for example `restart-host`, `rotate-pool-secret`, `manage-pool-membership`, `disaster-recovery`,
> `configure-ha`, `apply-update`). The workflows also expect some named objects to exist: running VMs
> called `web-01`, a halted VM `db-01`, a shared SR named `Shared NFS` and the `Rocky Linux 8`
> template. The storage workflows point at placeholder servers in the `192.0.2.0/24` documentation
> range. Change these to match your pool.

## Available languages

- [C#](csharp)
- [Java](java)
- [PowerShell](powershell)
- [Python](python)
- [Go](go)
- [xe CLI](cli)
- [C](c)

The older samples alongside the `workflows` folder in each language predate the workflow
examples and are not the same across languages.

## Development tips

- An example of how to retrieve and use [XenServer Operational Metrics](misc/using_rrd.md)

## Contributions

The preferable way to contribute patches is to fork the repository and
then submit a pull request. Questions related to these samples can be posted on
the repo's [issues](https://github.com/xenserver/xenserver-samples/issues) page.
See also [CONTRIBUTING](CONTRIBUTING.md).

## License

This code is licensed under the BSD 2-Clause license. Please see the
[LICENSE](LICENSE) file for more information.
