# XenServer CLI (xe) usage examples

## Workflow examples

[`workflows/`](workflows) holds all 91 workflow examples ([the full list](../README.md#workflow-examples)) in one bash script,
`workflows.sh`, written entirely with `xe` commands. These are the same commands you would type
at a host's console.

You need bash and an `xe` client. On Windows, use Git Bash and the `xe.exe` that ships with
XenCenter. Point `XE_EXE` at `xe` if it is not on your `PATH`:

```
cd workflows
export XE_EXE="/c/Program Files (x86)/XenServer/XenCenter/xe.exe"
./workflows.sh connect-inventory https://xenserver root <password>
```

The script talks to the host on port 443 over TLS, the `xe` default. If the URL names any other port,
it reaches the CLI over plain HTTP on the next port up, which is how test endpoints usually serve it.

Each workflow is a shell function you can copy into your own scripts; the `xe()` wrapper near the top
of the file is where the connection details go.
