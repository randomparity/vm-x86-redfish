# x86 VM with Redfish Management Controller

This repository creates a project-owned x86_64 libvirt/QEMU virtual machine and runs a
reference Redfish management controller for development and testing. The VM uses the system
libvirt connection and remains powered off after creation. It is not a production BMC.

## Default operator workflow

Check the host, create or validate the VM and its Redfish state, load the generated discovery
details and credentials, and start the service:

```bash
make doctor
export VM_X86_REDFISH_SOURCE_IMAGE=/path/to/fedora-cloud.qcow2
export VM_X86_REDFISH_MEMORY_MIB=8192
export VM_X86_REDFISH_ROOT_DISK_GIB=80
make create
source .state/connection.env
source "$REDFISH_CREDENTIALS_FILE"
make redfish
```

The default Redfish listener is `https://127.0.0.1:8000`; serial uses libvirt's PTY console.
In a second terminal, source both files before making an authenticated request:

```bash
source .state/connection.env
source "$REDFISH_CREDENTIALS_FILE"
curl --cacert "$REDFISH_CA_CERT" \
  --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
  "$REDFISH_ENDPOINT/redfish/v1/Systems"
```

`VM_X86_REDFISH_SOURCE_IMAGE` is required and must point to a readable qcow2 image. Memory
defaults to `4096` MiB and root-disk size to `40` GiB. Creation copies the source into the
libvirt pool, resizes only that managed copy, and leaves filesystem growth to the guest image.
Use the same sizing inputs on later `make create` runs; incompatible values are rejected.

## Configuring management endpoints

All endpoint configuration is supplied to `make doctor` and `make create` through environment
variables. Addresses must be concrete IPv4 or IPv6 literals (not hostnames, unspecified,
multicast, or scoped IPv6 addresses). Ports are decimal values from 1 through 65535.

| Variable | Default | Meaning |
| --- | --- | --- |
| `VM_X86_REDFISH_LISTEN_IP` | `127.0.0.1` | Redfish bind address and TLS identity address. |
| `VM_X86_REDFISH_LISTEN_PORT` | `8000` | Redfish HTTPS port. |
| `VM_X86_REDFISH_SERIAL_MODE` | `pty` | Serial transport: `pty` or `tcp`. |
| `VM_X86_REDFISH_SERIAL_LISTEN_IP` | — | Required only when serial mode is `tcp`. |
| `VM_X86_REDFISH_SERIAL_LISTEN_PORT` | — | Required only when serial mode is `tcp`. |

PTY mode rejects the two TCP-serial variables. TCP mode requires both, and its address/port
tuple must differ from the Redfish tuple. `make doctor` checks the selected listener sockets;
`make create` performs the same Redfish check and checks a new TCP serial listener before it
defines the domain.

For an off-host test controller, select a concrete reachable host address deliberately. Replace
the documentation address below with that host address before running the example:

```bash
VM_X86_REDFISH_LISTEN_IP=192.0.2.20 \
VM_X86_REDFISH_LISTEN_PORT=8443 \
VM_X86_REDFISH_SERIAL_MODE=tcp \
VM_X86_REDFISH_SERIAL_LISTEN_IP=192.0.2.20 \
VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
make create

source .state/connection.env
source "$REDFISH_CREDENTIALS_FILE"
printf '%s\n' "$REDFISH_ENDPOINT" "$SERIAL_TRANSPORT" "$SERIAL_ENDPOINT"
```

`connection.env` is mode `0600` and supplies `REDFISH_ENDPOINT`, `REDFISH_CA_CERT`,
`REDFISH_CREDENTIALS_FILE`, `SERIAL_TRANSPORT`, and `SERIAL_ENDPOINT`. PTY discovery uses
`libvirt-console://vm-x86-redfish/serial0`; TCP discovery uses `tcp://host:port`. URI hosts
with IPv6 addresses use brackets, for example
`https://[2001:db8::20]:8443` and `tcp://[2001:db8::21]:9000`.

Creation generates a self-signed certificate whose SANs include `localhost`, `127.0.0.1`, and
the configured Redfish address (without duplicate loopback entries). On a rerun it reuses a
certificate only when that configured address is already a SAN. Changing the Redfish address
therefore requires `make destroy` followed by `make create`, which creates a certificate for
the new address; creation never silently replaces a previously trusted certificate. A changed
serial transport or TCP endpoint likewise requires destroy/recreate because the existing domain
must match its rendered serial device and metadata.

Non-loopback Redfish selection emits a warning from `make doctor` and `make create`. Every TCP
serial selection emits an `unauthenticated plaintext TCP serial` warning: anyone able to reach
that listener can read and write the guest's serial stream. The local operator owns firewall,
routing, and network-isolation policy; this project does not configure a firewall. Keep the
defaults for local development unless an isolated test network needs remote access.

## Reset and serial behavior

The verified Redfish reset actions are `On`, `ForceOff`, `ForceRestart`, and `Nmi`.
`Nmi` is passed through Sushy to libvirt's NMI injection for an active domain. The integration
fixture verifies behavior rather than HTTP status alone: it waits for `NMI_READY` on COM1,
posts `{"ResetType":"Nmi"}`, observes kernel panic output, and requires a second readiness
sentinel after the guest restarts. `GracefulShutdown` is not a verified workflow because the
fixture has no guest agent or installed operating system.

Clean up only after the foreground service exits:

```bash
# Press Ctrl-C in the terminal running make redfish, then run:
make destroy
```

`make destroy` refuses while `make redfish` holds the lifecycle lock. It removes only
project-owned VM resources and does not search for or kill arbitrary serial clients.

## Commands and integration proof

- `make doctor`: verify host prerequisites and configured endpoints without changing the host.
- `make create`: create or validate the project-owned VM and Redfish state.
- `make redfish`: run the configured Redfish service in the foreground.
- `make test`: run offline tests and static checks.
- `make test-integration`: run opt-in host-mutating integration tests and clean test resources.
- `make destroy`: owner-gated, idempotent cleanup of project VM state, media, and temp files.
- `make clean`: alias for `make destroy`.

The integration suite is opt-in because it changes isolated libvirt resources. Before the live
run, use the integration preflight:

```bash
VM_X86_REDFISH_INTEGRATION_TEST=1 make doctor
make test-integration
```

In addition to ordinary doctor prerequisites, that preflight requires `cpio`, a readable host
kernel and matching kernel configuration for `uname -r`, `CONFIG_X86_64`, `CONFIG_HAVE_NMI`,
`CONFIG_BLK_DEV_INITRD`, `CONFIG_PROC_FS`, `CONFIG_PROC_SYSCTL`, `CONFIG_BINFMT_ELF`,
`CONFIG_PRINTK`, and `CONFIG_SERIAL_8250_CONSOLE`, plus a compiler able to statically link the
init process. The live remote arms require a non-root outer user, `unshare`,
`nsenter`, `slirp4netns`, and `readlink`, working unprivileged user/network namespaces, and a
bindable non-loopback IPv4 route source. They also run a namespace/slirp smoke test before
touching libvirt.

The live proof runs a remote Redfish/NMI scenario twice: PTY serial is captured with the local
libvirt console, then TCP serial is captured by a client in the second network namespace. Both
arms prove that the namespace differs from the host namespace and cannot use host loopback,
use TLS-authenticated Redfish from that namespace, exercise the NMI restart sequence, and
clean only their exact child processes, domain, volumes, NVRAM, sockets, and state. Bind
collisions are retried with fresh endpoints only after that owned cleanup succeeds.

## Troubleshooting and security boundaries

Run `make doctor` to identify missing host dependencies, invalid endpoint input, or a listener
already using the selected address and port. Lifecycle commands fail immediately when another
command holds the project lock; wait for that command to exit before retrying.

Generated configuration, credentials, certificates, logs, virtual-media metadata, and runtime
files remain in ignored `.state/`. Treat `.state/` as sensitive while the service exists,
especially if virtual-media credentials were supplied. Integration-test diagnostics remain in
ignored `.artifacts/`. Do not commit generated files or credentials.

This project provides Redfish rather than IPMI and manages one local project-owned VM through
`qemu:///system`. Discovery at `/redfish/v1` is intentionally unauthenticated; system
resources and mutation actions require Basic authentication. Authenticated users can request
virtual-media URLs, so treat those URLs as trusted test inputs. TLS verification is enabled for
virtual-media downloads. Production hardening, a new authorization model, trusted public
certificates, firewall configuration, and encrypted or authenticated TCP serial are out of
scope.
