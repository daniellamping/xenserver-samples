# XenAPI.py usage examples

## Workflow examples

[`workflows/`](workflows) holds all 91 workflow examples ([the full list](../README.md#workflow-examples)) in one script, `workflows.py`.
It needs Python 3 and the SDK's `XenAPI` module, either from PyPI or by copying
`XenServerPython/XenAPI.py` from the SDK next to the script:

```
cd workflows
pip install -r requirements.txt
python workflows.py connect-inventory https://xenserver root <password>
```

Each workflow is also a self-contained function you can copy into your own code; see the `Run it:` line under each.

## Overview

The following Python examples are included in this repository:

- `exportimport.py` — demonstrates how to
  - export raw disk images
  - import raw disk images
  - connect an export to an import to copy a raw disk image

-  `fixpbds.py` - reconfigures the settings used to access shared storage.

-  `install.py` - installs a Debian VM, connects it to a network, starts it up and 
    waits for it to report its IP address.

-  `permute.py` - selects a set of VMs and uses live migration to move them
    simultaneously among hosts.

-  `powercycle.py` - selects a set of VMs and power-cycles them.

-  `provision.py`: - parses/regenerates the "disk provisioning" XML contained 
    within templates

-  `shutdown.py`: - shows how to prepare and shutdown a host.

-  `vm_start_async.py` - shows how to invoke operations asynchronously.

-  `watch-all-events.py` - registers for all events and prints details
    when they occur.

## How to run the scripts

Each script requires 3 command line arguments:

```
URL       : a URL of the form https://host[:port] pointing at the server
username  : a valid user on the server (e.g. root)
password  : the user's password
```

For example:

```
./install.py https://myhost.mydomain.com root letmein
```
