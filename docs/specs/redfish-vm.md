# Redfish-Controlled x86 VM Specification

Status: Accepted

## Purpose

Build a local x86_64 virtual machine that behaves like a bare-metal server managed through
Redfish. A developer or automation client must be able to discover the server, inspect and
change its power state, select its next boot device, and attach installation media without
using `virsh` directly.

The first release targets Fedora 44 hosts and `qemu:///system`. It is a development and test
tool, not a production BMC.

## Goals

- Define one project-owned libvirt domain backed by KVM and QEMU.
- Serve a TLS-enabled Redfish endpoint on loopback and authenticate protected resources.
- Expose only the project-owned domain through Redfish.
- Support power on, forced power off, and forced restart.
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
- Redfish schema extensions, production deployment, or externally reachable management.
- Secure Boot control, firmware updates, sensors, RAID emulation, or a web interface.

## Architecture

```text
Redfish client
    |
    | HTTPS on 127.0.0.1:8000; Basic authentication on protected resources
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
- availability of TCP port 8000 on loopback.

Other libvirt versions are unsupported until their matching Python binding and integration
suite have been verified and this specification and lock file have been updated. The scripts
must fail with actionable diagnostics rather than changing libvirt networks, pools,
permissions, SELinux policy, or packages. On Fedora 44, `htpasswd` is supplied by
`httpd-tools`; the doctor reports package names but never installs them.

## VM Definition

The fixed domain name is `vm-x86-redfish`. Its definition contains:

- `type='kvm'`, x86_64 `q35`, two vCPUs, and 4 GiB RAM;
- libvirt UEFI firmware auto-selection with Secure Boot disabled;
- one sparse 40 GiB qcow2 volume in the `default` pool;
- one virtio NIC attached to the active `default` network;
- one emulated 16550A serial device at COM1 with a matching libvirt console target named
  `serial0`; no virtio console;
- no permanently attached CD-ROM; Sushy adds and removes virtual media;
- namespaced libvirt metadata identifying project ownership and the exact root-volume name.

Creation generates a UUID once and records it in `.state/domain-uuid`. If a resource with
the fixed name already exists without matching ownership metadata and UUID, creation fails.
Re-running creation validates the existing definition and repairs only missing project-owned
runtime files; it does not overwrite divergent VM hardware.

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
- `SUSHY_EMULATOR_LISTEN_IP = "127.0.0.1"` and port `8000`;
- `SUSHY_EMULATOR_FEATURE_SET = "vmedia"`;
- `SUSHY_EMULATOR_ALLOWED_INSTANCES` to the generated domain UUID only;
- `SUSHY_EMULATOR_VMEDIA_DEVICES` to a single `Cd` device;
- `SUSHY_EMULATOR_STORAGE_POOL = "default"`;
- a private persistent state directory, TLS certificate and key, and htpasswd file.

Creation generates a self-signed certificate valid for `localhost` and `127.0.0.1`, plus a
fixed local username `admin` and a random password. It writes the recoverable values as
shell-escaped `REDFISH_USERNAME` and `REDFISH_PASSWORD` assignments in
`.state/credentials.env`, then derives `.state/htpasswd` from that file. Secret-bearing files
use mode `0600`; state directories use `0700`. The password is not printed or committed.
`.state/connection.env` contains the endpoint, certificate path, and credentials-file path so
clients and agents can locate, but need not duplicate, the secret.

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

The verified reset actions are `On`, `ForceOff`, and `ForceRestart`. Sushy may advertise
additional reset types, but they are outside the initial acceptance contract. In particular,
`GracefulShutdown` cannot be verified against the blank disk because no guest agent or
operating system is present.

## Virtual Media Storage

On insertion, Sushy downloads the requested image and uploads a copy into the `default`
libvirt pool as `<media-basename-with-dots-replaced>-<UUID>.img`. Sushy removes the temporary
download after eject but does not remove the pool volume. Because its process `TMPDIR` is
`.state/tmp`, an interrupted insertion leaves temporary data only beneath that validated
directory.

`scripts/destroy-vm` therefore enumerates pool volumes and removes only media volumes whose
names match the anchored form `^[^/]+-<UUID>\.img$`, in addition to the owned root disk. The
matcher operates on each libvirt volume name as a string without shell glob expansion.
Destruction refuses to continue if domain metadata, the recorded UUID, and the live UUID
disagree. Interrupted
insertion and repeated insertion with different filenames are covered by cleanup tests. Once
the lifecycle lock is held, destruction removes enumerated temporary-media files beneath the
canonical, non-symlink `.state/tmp` and removes the directory only when it is empty. It never
uses an unchecked recursive deletion.

Because authenticated Redfish users can cause server-side URL fetches, the endpoint remains
loopback-only. Virtual-media TLS verification is enabled. The documentation warns that media
URLs are trusted local test inputs and that supplied media credentials may persist in the
private Sushy state directory.

## Commands

- `make doctor`: run non-mutating host and configuration checks.
- `make create`: acquire the lifecycle lock, then create or validate the domain, disk,
  credentials, TLS files, and generated Sushy configuration. The domain remains powered off.
- `make redfish`: acquire the lifecycle lock and start the foreground Redfish service with its
  private temporary directory.
- `make test`: run offline Bats tests, ShellCheck, shfmt verification, and configuration
  validation.
- `make test-integration`: exercise isolated, test-owned libvirt and Redfish resources;
  disabled unless explicitly invoked.
- `make destroy`: acquire the lifecycle lock without waiting and refuse if Redfish is running;
  otherwise hold the lock through cleanup, undefine only the owned domain, remove its NVRAM
  and UUID-scoped volumes, and retain logs needed to diagnose cleanup failures. It never
  searches for or kills a process.

## Verification

Offline tests mock only command boundaries and cover missing tools, malformed state, name
collisions, mismatched ownership, reruns, and failures between disk creation and domain
definition. Every handled error path has a test.

The integration suite uses only the random test resources described above. It retains the
exact PIDs of the Sushy, media-server, and asynchronous Redfish-client children it starts. A
trap applies bounded termination and wait operations to only those children before attempting
resource cleanup. It:

1. Creates the powered-off domain twice and proves the second run makes no changes.
2. Starts Sushy, verifies the self-signed TLS certificate, confirms that the service root is
   public, and confirms that `/Systems` rejects missing credentials.
3. Authenticates and confirms the Systems collection contains exactly the recorded UUID.
4. Exercises `On`, `ForceRestart`, and `ForceOff` through `ComputerSystem.Reset`, polling
   boundedly for each expected state.
5. Renders `tests/fixtures/grub.cfg.in` with a run-specific sentinel. The GRUB configuration
   selects serial unit 0 at 115200 baud, waits ten seconds for console attachment, prints the
   sentinel, and halts. `grub2-mkrescue` and `xorriso` build a temporary UEFI-bootable ISO
   containing that configuration. The domain XML and preflight checks confirm that serial unit
   0 is the COM1 `serial0` console, not a virtio console.
6. Starts a test-owned HTTP server on a kernel-selected loopback port, inserts its ISO through
   Redfish, selects `Cd`, and verifies the copied pool volume and first boot order in inactive
   domain XML.
7. Powers on through Redfish, polls until libvirt reports the domain running, then immediately
   attaches `virsh console --devname serial0 --force` under a 60-second timeout. The test
   requires the exact sentinel in captured serial output; timeout or VM exit without it fails
   the test.
8. Forces the VM off, ejects the media, and verifies that the CD device disappears from domain
   XML. It then exercises `Hdd` and `Pxe` overrides and verifies their inactive XML.
9. Starts a second insertion request asynchronously and records its exact PID while the media
   server returns a throttled response. After a file appears beneath the test `TMPDIR`, it
   terminates only its Sushy child to simulate interruption. It waits boundedly for the client
   to fail; if the client remains alive, it terminates and waits for that exact PID.
10. Terminates and waits for its remaining exact child PIDs, runs locked destruction, and
    proves the domain, root disk, NVRAM, partial temporary download, every volume matching the
    anchored `-<UUID>.img` suffix, and temporary state are absent while the developer domain
    and unrelated libvirt resources remain unchanged.

All polling and child-process termination have explicit timeouts. A test failure copies
diagnostic logs to `.artifacts/<test-id>/`, then performs best-effort cleanup of resources that
pass the test-run ownership checks. Failure to prove ownership leaves the resource in place
and reports the exact manual inspection command.

## Delivery Sequence

1. Add `.gitignore`, the pinned `uv` project, Make targets, static checks, and failing Bats
   tests.
2. Implement `doctor`, domain rendering, ownership metadata, test isolation, creation, and
   rollback.
3. Generate private TLS, recoverable authentication, Sushy configuration and temporary state,
   and the lifecycle lock.
4. Add authenticated Redfish discovery and power-control integration tests.
5. Add the UEFI serial-sentinel fixture, boot overrides, virtual media, media-volume cleanup,
   and destruction tests.
6. Update `README.md` with the verified workflow and limitations.

The first implementation checkpoint is the serial-sentinel integration test proving that
Sushy 2.2.0 can upload virtual media to the system libvirt pool and boot the Fedora 44
q35/UEFI domain under enforcing SELinux. Failure at that checkpoint stops implementation; it
does not introduce a second backend. The specification must then be revised to select either
a session libvirt domain or a dedicated service identity.
