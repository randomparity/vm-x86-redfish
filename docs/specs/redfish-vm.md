# Redfish-Controlled x86 VM Specification

Status: Accepted

## Purpose

Build an x86_64 virtual machine that behaves like a bare-metal server managed through Redfish.
A developer or test automation client must be able to discover the server, inspect and change
its power state, select its next boot device, attach installation media, and consume diagnostic
serial output without using `virsh` directly for management actions.

The first release targets Fedora 44 hosts and `qemu:///system`. It is a development and test
tool, not a production BMC.

## Goals

- Define one project-owned libvirt domain backed by KVM and QEMU.
- Serve a TLS-enabled Redfish endpoint on an explicitly configured address and authenticate
  protected resources.
- Expose only the project-owned domain through Redfish.
- Support `On`, `ForceOff`, `ForceRestart`, and `Nmi` reset actions.
- Support `Hdd`, `Cd`, and `Pxe` boot overrides.
- Insert and eject HTTP- or HTTPS-hosted virtual CD media.
- Make creation, verification, and removal idempotent and safe around unrelated libvirt
  resources.
- Provide offline unit tests and opt-in integration tests against the real host boundary.

## Non-goals

- IPMI support; VirtualBMC is a follow-up after this specification is working end to end.
- Multiple managed VMs, alternate hypervisors, or remote libvirt hosts.
- PXE infrastructure, operating-system installation automation, or guest SSH setup.
- Graceful shutdown verification before a guest operating system is installed.
- Redfish schema extensions, production deployment, or a new authorization model.
- Secure Boot control, firmware updates, sensors, RAID emulation, or a web interface.

## Architecture

```text
Redfish client
    |
    | HTTPS on configured concrete IP and port; Basic authentication on protected resources
    v
Sushy Emulator 2.2.0 (Python 3.13, vmedia feature set)
    |
    | libvirt API
    v
qemu:///system -> QEMU/KVM x86_64 domain
```

Sushy Emulator is the sole Redfish implementation. The repository supplies lifecycle
scripts and configuration but does not wrap or reimplement its API.

## Repository Layout

```text
Makefile
config/
  domain.xml
  sushy-emulator.conf.py.in
scripts/
  doctor
  create-vm
  destroy-vm
  render-config
  run-redfish
tests/
  create-vm.bats
  redfish-integration.bats
  fixtures/grub.cfg.in
docs/specs/
  redfish-vm.md
```

Generated configuration, credentials, certificates, identifiers, logs, and downloaded test
media belong in ignored `.state/`. Retained integration-test diagnostics belong in ignored
`.artifacts/<test-id>/`. Python dependencies use a repository-local `uv` project and lock
file. The pins are `sushy-tools==2.2.0` and `libvirt-python==12.0.0`; all resolved transitive
dependencies must be committed in `uv.lock`.

## Host Contract

`scripts/doctor` performs read-only checks and reports exact installation commands for
missing dependencies. It must not install packages or alter host configuration. It checks:

- x86_64, KVM access, and a usable `qemu:///system` connection;
- QEMU, libvirt 12.0.x, `virsh`, `qemu-img`, and UEFI firmware;
- active `default` network and storage pool;
- Python 3.13 through `uv`, plus `curl`, `openssl`, `htpasswd`, Bats, ShellCheck,
  shfmt, `grub2-mkrescue`, and `xorriso`;
- availability of the configured Redfish listener and, in TCP serial mode, the configured
  serial listener.

Other libvirt versions are unsupported until their matching Python binding and integration
suite have been verified and this specification and lock file have been updated. The scripts
must fail with actionable diagnostics rather than changing libvirt networks, pools,
permissions, SELinux policy, or packages. On Fedora 44, `htpasswd` is supplied by
`httpd-tools`; the doctor reports package names but never installs them.

When `VM_X86_REDFISH_INTEGRATION_TEST=1` is set, doctor also requires `cpio`, a readable
kernel image and kernel configuration matching `uname -r`, `CONFIG_X86_64`, `CONFIG_HAVE_NMI`,
`CONFIG_BLK_DEV_INITRD`, `CONFIG_PROC_FS`, `CONFIG_PROC_SYSCTL`, `CONFIG_BINFMT_ELF`,
`CONFIG_PRINTK`, and `CONFIG_SERIAL_8250_CONSOLE`, plus a compiler that can statically link a
PID 1. These are prerequisites for the NMI initramfs fixture, not ordinary create/doctor use.

### Endpoint configuration

The create-time endpoint inputs are:

- `VM_X86_REDFISH_LISTEN_IP`, default `127.0.0.1`;
- `VM_X86_REDFISH_LISTEN_PORT`, default `8000`;
- `VM_X86_REDFISH_SERIAL_MODE`, `pty` by default and otherwise `tcp`;
- `VM_X86_REDFISH_SERIAL_LISTEN_IP`, required only for `tcp`; and
- `VM_X86_REDFISH_SERIAL_LISTEN_PORT`, required only for `tcp`.

Each address is parsed as a concrete IPv4 or IPv6 literal. Hostnames, unspecified addresses,
multicast addresses, and scoped IPv6 addresses are rejected. Each port is a decimal integer
from 1 through 65535. PTY mode rejects the TCP-only variables; TCP mode requires both. A TCP
serial address/port tuple cannot equal the Redfish tuple. Values are canonicalized before they
are used in configuration, XML, certificates, diagnostics, or shell metadata. IPv6 hosts in
published URIs are bracketed.

The defaults retain a loopback Redfish listener and a libvirt PTY console. Selecting a
non-loopback Redfish address emits `warning: non-loopback Redfish listener at <endpoint>` from
doctor and create. Selecting TCP serial always emits
`warning: unauthenticated plaintext TCP serial listener at <endpoint>`. The project does not
configure routing or firewall rules: the local operator owns the exposure decision and network
policy. TCP serial has no authentication or encryption and is appropriate only for isolated
test networks.

## VM Definition

The fixed domain name is `vm-x86-redfish`. Its definition contains:

- `type='kvm'`, x86_64 `q35`, two vCPUs, configurable RAM (4 GiB by default), and host CPU
  passthrough;
- libvirt UEFI firmware auto-selection with Secure Boot disabled;
- one managed qcow2 volume in the `default` pool, copied from an operator-selected qcow2
  image and resized to a configurable capacity (40 GiB by default);
- one virtio NIC attached to the active `default` network;
- exactly one emulated 16550A serial device at COM1 and one matching console target named
  `serial0`; no virtio console. PTY mode renders `serial type='pty'` and `console type='pty'`.
  TCP mode renders both as `type='tcp'`, each with `source mode='bind' host='<configured IP>'`
  and `service='<configured port>'`, `protocol type='raw'`, and the same COM1/`serial0`
  targets;
- no permanently attached CD-ROM; Sushy adds and removes virtual media;
- namespaced libvirt metadata identifying project ownership and the exact root-volume name,
  configured memory, disk size, source-image digest, serial mode, serial listen IP, and serial
  listen port. PTY serial address and port metadata are empty; TCP metadata repeats the
  canonical TCP endpoint.

The create-time inputs are `VM_X86_REDFISH_SOURCE_IMAGE`,
`VM_X86_REDFISH_MEMORY_MIB`, and `VM_X86_REDFISH_ROOT_DISK_GIB`. The source image is
required; memory and disk size use the defaults above. The target disk must be at least as
large as the source image's virtual size. Creation never modifies the source file, and guest
filesystem expansion remains the responsibility of cloud-init or the image's normal
first-boot behavior.

Creation generates a UUID once and records it in `.state/domain-uuid`. If a resource with
the fixed name already exists without matching ownership metadata and UUID, creation fails.
Re-running creation validates the existing definition and repairs only missing project-owned
runtime files; it does not overwrite divergent VM hardware. Namespaced metadata records the
configured memory, disk size, source-image digest, and serial contract so incompatible reruns
fail. A serial-mode, serial-address, serial-port, or serial-device mismatch tells the operator
to destroy and recreate the project-owned domain.

If domain definition fails after creating the disk, creation deletes that exact new volume.
It never modifies the existing `ubuntu25.10` domain or any host network or pool.

### Integration-test isolation

The integration suite never uses `vm-x86-redfish`, its disk, or `.state/`. Each run creates a
random test identifier and derives a private domain name, disk name, UUID, and temporary state
directory from it. Test-only environment overrides pass those values to the lifecycle scripts
only when the harness sets an internal integration-test guard. They are not a supported
multi-VM user interface.

Before its first mutation, the suite proves that its intended domain and volume names do not
exist. A collision aborts the run; it is never adopted or removed. Cleanup requires the test
ownership marker and exact UUID recorded by that run. Temporary state is removed by enumerating
known files and removing an empty directory, not by recursively deleting an unchecked path.
The test-specific state directory has its own lifecycle lock, so test commands cannot race
with one another.

## Redfish Service

`make redfish` runs Sushy in the foreground so process ownership and logs remain visible. It
holds an exclusive lock on `.state/lifecycle.lock` for the complete process lifetime. Every
mutating lifecycle command acquires that same lock without waiting and holds it through its
complete transaction. Consequently, `make create` and `make destroy` refuse while Redfish is
running, a second service invocation fails immediately, and service startup cannot race with
creation or destruction. The generated Sushy configuration must set:

- `SUSHY_EMULATOR_LIBVIRT_URI = "qemu:///system"`;
- `SUSHY_EMULATOR_LISTEN_IP` and `SUSHY_EMULATOR_LISTEN_PORT` from the canonical configured
  Redfish endpoint;
- `SUSHY_EMULATOR_FEATURE_SET = "vmedia"`;
- `SUSHY_EMULATOR_ALLOWED_INSTANCES` to the generated domain UUID only;
- `SUSHY_EMULATOR_VMEDIA_DEVICES` to a single `Cd` device;
- `SUSHY_EMULATOR_STORAGE_POOL = "default"`;
- a private persistent state directory, TLS certificate and key, and htpasswd file.

Creation generates a self-signed certificate with SANs for `localhost`, `127.0.0.1`, and the
configured Redfish IP address, deduplicating the loopback address. On reuse, it verifies the
configured address with `openssl x509 -checkip`; if the SAN is absent, creation fails with
destroy/recreate remediation rather than silently replacing a trusted identity. A fixed local
username `admin` and random password are written as shell-escaped `REDFISH_USERNAME` and
`REDFISH_PASSWORD` assignments in
`.state/credentials.env`, then derives `.state/htpasswd` from that file. Secret-bearing files
use mode `0600`; state directories use `0700`. The password is not printed or committed.
`.state/connection.env` is mode `0600` and contains shell-quoted `REDFISH_ENDPOINT`,
`REDFISH_CA_CERT`, `REDFISH_CREDENTIALS_FILE`, `SERIAL_TRANSPORT`, and `SERIAL_ENDPOINT` so
clients can source it without duplicating secrets. `SERIAL_ENDPOINT` is
`libvirt-console://<domain>/serial0` in PTY mode and `tcp://host:port` in TCP mode; IPv6 URI
hosts are bracketed. The standard domain uses `libvirt-console://vm-x86-redfish/serial0`.

`make redfish` sets `TMPDIR` to the canonical `.state/tmp` directory before starting Sushy.
This contains downloaded virtual media and crash leftovers inside project-owned state. The
directory must exist, be mode `0700`, be owned by the invoking user, and not be a symbolic
link. Creation and destruction validate those properties before touching its contents.
`scripts/run-redfish` retains the lock file descriptor and replaces itself with Sushy using
`exec`, giving callers one exact process to signal and wait for. `make redfish` delegates to
that script; integration tests invoke the script directly when they need its PID.

Sushy intentionally permits unauthenticated discovery of `/redfish/v1`. Basic authentication
is required for `/redfish/v1/Systems`, individual systems, virtual media, and mutation actions.
Tests verify both behaviors rather than claiming that every endpoint is protected.

The Redfish system identifier is the libvirt UUID returned by authenticated
`GET /redfish/v1/Systems`. Requests using the domain-name alias may redirect; tests and
documentation discover the UUID from the Systems collection and use it for system-specific
requests.

Boot-device and virtual-media changes apply to inactive domain XML. Sushy may accept these
requests while the VM is running, but they do not affect the current process. The supported
client sequence is force off, change media or boot configuration, then power on. Tests follow
that sequence and do not require Sushy to reject changes submitted while the VM is active.

The verified reset actions are `On`, `ForceOff`, `ForceRestart`, and `Nmi`. The pinned Sushy
2.2.0 boundary is tested to advertise `Nmi`, forward it through the reset handler, and invoke
libvirt `injectNMI()` for an active domain (with no NMI injection for an inactive domain).
`GracefulShutdown` remains unverified because the blank-disk fixture has no guest agent or
installed operating system.

## Virtual Media Storage

On insertion, Sushy downloads the requested image and uploads a copy into the `default`
libvirt pool as `vm-x86-redfish-media-<media-basename-with-dots-replaced>-<UUID>.img`.
Each upload records that exact volume name in private Sushy state before stream upload
starts. Sushy removes the temporary download after eject but does not remove the pool
volume. Because its process `TMPDIR` is `.state/tmp`, an interrupted insertion leaves
temporary data only beneath that validated directory.

`scripts/destroy-vm` therefore removes only exact media volume names recorded in private
project state and matching the current project prefix plus recorded UUID, in addition to
the owned root disk. The matcher operates on each libvirt volume name as a string without
shell glob expansion. Destruction refuses to continue if domain metadata, the recorded UUID,
and the live UUID disagree. Interrupted insertion and repeated insertion with different
filenames are covered by cleanup tests. Once the lifecycle lock is held, destruction removes
enumerated temporary-media files beneath the canonical, non-symlink `.state/tmp` and removes
the directory only when it is empty. It never uses an unchecked recursive deletion.

Authenticated Redfish users can cause server-side URL fetches. Virtual-media TLS verification
is enabled, but remote Redfish exposure is an explicit local-operator decision. Media URLs are
trusted test inputs, and supplied media credentials may persist in the private Sushy state
directory.

## Commands

- `make doctor`: run non-mutating host and configuration checks.
- `make create`: acquire the lifecycle lock, then create or validate the domain, disk,
  credentials, TLS files, and generated Sushy configuration. The domain remains powered off.
- `make redfish`: acquire the lifecycle lock and start the foreground Redfish service with its
  private temporary directory.
- `make test`: run offline Bats tests, ShellCheck, shfmt verification, and configuration
  validation.
- `make test-integration`: exercise isolated, test-owned libvirt resources, both serial
  transports, remote Redfish reachability, and NMI behavior; disabled unless explicitly
  invoked.
- `make destroy`: acquire the lifecycle lock without waiting and refuse if Redfish is running;
  otherwise hold the lock through cleanup, undefine only the owned domain, remove its NVRAM
  and UUID-scoped volumes, and retain logs needed to diagnose cleanup failures. It never
  searches for or kills a process.

## Verification

Offline tests mock only command boundaries and cover missing tools, malformed endpoint input,
listener collisions, TLS SAN reuse, sourceable connection metadata, PTY/TCP XML shape and
metadata, ownership, reruns, NMI dependency mapping, and failures between disk creation and
domain definition. Every handled error path has a test.

`make test-integration` requires the integration doctor checks above, a non-root outer user,
`unshare`, `nsenter`, `slirp4netns`, and `readlink`, working unprivileged user/network
namespaces, and a bindable non-loopback IPv4 route source. Before it mutates libvirt, the
harness creates a rootless user/network namespace, proves its network-namespace inode differs
from the host's, starts slirp with host-loopback disabled, and requires a networking smoke
probe to traverse that context. A missing prerequisite is an explicit preflight failure.

The integration suite uses only the random test resources described above. It retains the
exact PIDs of Sushy, media servers, namespaces, slirp processes, and serial clients. A trap
applies bounded termination and wait operations to only those children before resource cleanup.
The standard arm creates and validates the powered-off domain, proves TLS/authentication and
the existing `On`, `ForceRestart`, and `ForceOff` behavior, exercises virtual media and boot
overrides, captures a COM1 serial sentinel, and checks interruption cleanup.

The remote NMI arm runs once with PTY serial and once with TCP serial. For each transport it:

1. Allocates fresh ports on a concrete non-loopback host IPv4 address and creates the isolated
   domain. TCP adds a raw bind-mode serial listener; PTY retains the libvirt console.
2. Starts Sushy, creates the second network context, proves that it cannot reach a host-loopback
   control listener, and fetches the Systems collection through TLS-authenticated Redfish from
   that context.
3. Builds the matching-kernel/initramfs NMI fixture, inserts it through Redfish, selects CD
   boot, powers on, and captures `NMI_READY` from `virsh console` for PTY or from a raw TCP
   serial client in the second network context for TCP.
4. Posts `{"ResetType":"Nmi"}` through remote Redfish, then requires `Kernel panic`, a second
   `NMI_READY`, and the restarted running domain. HTTP success alone is insufficient.
5. Stops and waits for exact children, destroys only verified owned resources, verifies removal
   of the domain, root volume, UUID-scoped media volumes, NVRAM, listeners, and test state, and
   confirms unrelated libvirt inventory is unchanged.

A proven Redfish bind collision retries either arm with fresh endpoints up to three attempts;
a proven TCP-serial bind collision retries the TCP arm the same way. Non-collision failures do
not retry. All polling and child-process termination have explicit timeouts. Test failures
retain diagnostics in `.artifacts/<test-id>/`; a failure to prove ownership leaves the resource
in place and reports the exact manual inspection command.
