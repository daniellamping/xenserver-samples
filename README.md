# XenServer SDK usage examples

This repository contains sample code for interacting with [XenServer](https://www.xenserver.com/)
using the XenServer SDK. The examples are provided as complete applications
or scripts that you can run on your server.

Apart from the ready-to-run code, this repository contains also a number of tips
or walk-throughs that you may find useful when developing products for XenServer.

The content of this repository can be used as a companion to the
[XenServer SDK Guide](https://docs.xenserver.com/en-us/xenserver/8/developer/sdk-guide).

## Workflow examples

The `workflows` folder in each language holds the same **90 real-world
workflows**, each implemented in every language: the five SDK bindings (C#, Java, PowerShell, Python
and Go) plus the `xe` command line interface. Pick the language you work in and you will find every
task there, written the same way.

**[Browse them in the docs](docs/workflows/README.md)**: a page per workflow with its code in every
language and the output of running it, grouped by area. New to the API? Start with the
[short guide](docs/README.md).

Each workflow is a self-contained function that takes the connection details (and any object it acts
on, looked up by name) as parameters, opens its own session, cleans up after itself, and prints
`OK: <workflow>` on success. Copy one out and run it as-is; each carries a `Run it:` line showing the
call. The shared connect helper accepts a host's self-signed certificate and follows the pool-member to
coordinator redirect (`HOST_IS_SLAVE`), the way XenCenter does when you add a member server.

Every language's file can also run any workflow from the command line:

```
<program> <workflow> <url> <username> <password> [key=value ...]
```

The `key=value` arguments override the objects and addresses a workflow uses (for example
`source_vm=my-vm`, `sr_name=my-shared-sr`, `nfs_server=… nfs_path=…`); each workflow's defaults are in
its language's dispatcher. `cross-pool-copy-vm` instead takes the destination pool's URL as an extra
argument after the password. See each language's README for how to set up and run it, and
[workflows.json](workflows.json) for the full list.

> **Run these against a test pool, not production.** Several workflows change pool-wide state
> (for example `restart-host`, `rotate-pool-secret`, `manage-pool-membership`, `disaster-recovery`,
> `configure-ha`, `apply-update`). By default the workflows act on some named objects: a VM `web-01`
> that has a guest OS and the XenServer VM Tools (the guest-cooperative workflows, such as suspend,
> checkpoint and live migration, work on a copy of it: `source_vm`), a halted VM `db-01`, a shared SR
> named `Shared NFS` and the `Rocky Linux 8` template. The storage workflows point at placeholder servers
> in the `192.0.2.0/24` documentation range, and the ones that create an SR on a LUN format it. Override
> these to match your pool.

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
