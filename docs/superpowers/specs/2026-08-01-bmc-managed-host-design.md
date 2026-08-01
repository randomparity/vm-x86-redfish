# BMC-managed host endpoint design

Issue: [#6](https://github.com/randomparity/vm-x86-redfish/issues/6)  
Decision: [ADR 0001](../../adr/0001-configure-management-endpoints.md)

## Scope authority

- Interaction: interactive.
- Scope identity: issue 6 plus `scope-6-20260801-a1`.
- Outcome: an off-host control plane can reach and drive the VM, deliver an NMI, and consume
  serial output while current safe defaults remain unchanged.
- Criteria source: issue 6's expected outcome, proposed approach, and test-design note.
- Exclusions: production hardening, a new authorization model, and optional graceful reset
  coverage.
- Surface: configuration templates, lifecycle and diagnostic scripts, domain XML,
  connection state, offline and integration tests, and user/spec documentation.
- Ambiguities: none.

## Approaches considered

The selected approach extends the existing environment-driven create entry point and renders
both endpoint choices into project-owned state. It keeps one lifecycle and makes reruns
checkable. A second approach would accept flags on several scripts, but that would duplicate
configuration across `doctor`, `create`, and `redfish`. A third would leave templates fixed
and ask operators to edit generated state, but it would create unvalidated, non-idempotent
runtime drift. ADR 0001 records the endpoint decision.

## Configuration contract

`scripts/lib/common` loads and validates these public inputs:

- `VM_X86_REDFISH_LISTEN_IP`, default `127.0.0.1`;
- `VM_X86_REDFISH_LISTEN_PORT`, default `8000`;
- `VM_X86_REDFISH_SERIAL_MODE`, either `pty` (default) or `tcp`;
- `VM_X86_REDFISH_SERIAL_LISTEN_IP`, required for `tcp` and otherwise rejected;
- `VM_X86_REDFISH_SERIAL_LISTEN_PORT`, required for `tcp` and otherwise rejected.

Addresses must be concrete IPv4 or IPv6 literals, not unspecified or multicast addresses.
Ports are decimal integers from 1 through 65535. Requiring concrete addresses makes the same
value usable for binding, certificate verification, diagnostics, and client discovery.
Loopback remains valid for either endpoint. Non-loopback Redfish and every TCP serial
configuration emit explicit exposure warnings during `make doctor` and `make create`.

The Sushy template receives listen IP and port tokens. The domain renderer selects exactly
one serial fragment: today's PTY/console pair, or a raw TCP server serial device with a
matching serial console target. TCP uses libvirt's `source mode='bind'` and `protocol
type='raw'`. Domain metadata records the serial mode and, for TCP, its address and port.
Existing-domain validation compares those values and the device shape, so changing transport
requires `make destroy` followed by `make create`.

## TLS and connection discovery

Creation generates a self-signed certificate with `DNS:localhost`, `IP:127.0.0.1`, and the
configured Redfish IP address (deduplicated). If a certificate/key pair already exists,
creation verifies that its SAN contains the configured address. A mismatch fails with an
instruction to destroy and recreate project-owned runtime state; creation never replaces a
previously trusted identity silently.

`.state/connection.env` continues to contain Redfish endpoint, CA, and credential paths. It
also contains `SERIAL_TRANSPORT` and `SERIAL_ENDPOINT`. The endpoint is a documented
`libvirt-console://.../serial0` discovery URI for PTY mode and a `tcp://host:port` URI for TCP
mode. IPv6 URI hosts use brackets. Values remain single-quoted and contain only validated or
project-controlled data.

`make doctor` probes the configured Redfish socket instead of fixed loopback port 8000. In
TCP mode it separately probes the serial bind socket and rejects an endpoint collision. It
prints the effective endpoints after prerequisite checks.

## NMI verification

The integration fixture builds a tiny initramfs around a static C init process, boots it with
the host's matching readable kernel, and uses kernel arguments `unknown_nmi_panic=1`,
`panic=1`, and `console=ttyS0`. The init process prints a readiness sentinel and waits. The
test captures serial before posting `ResetType: Nmi`, then requires the kernel's panic output
and an observable restart; HTTP success alone is insufficient. `make doctor` checks the
kernel, static compiler support, and `cpio` needed to assemble this fixture. Existing `On`,
`ForceRestart`, and `ForceOff` coverage remains.

The integration test runs its serial-sentinel scenario once with PTY and once with TCP. PTY
uses `virsh console`; TCP uses a bounded client connection to the run-specific loopback
listener. Test-only overrides continue to randomize names, paths, and ports. Each run owns and
cleans only its domain, volumes, child processes, sockets, and state.

## Failure behavior

Invalid addresses, ports, mode combinations, endpoint collisions, mismatched existing domain
metadata, and mismatched TLS SANs fail before mutation where possible with the variable or
state file and remediation in the message. Partial certificate generation retains neither
half. TCP serial bind failures leave libvirt definition/start errors visible and flow through
existing rollback and diagnostic retention. Cleanup does not connect to or kill arbitrary
serial clients.

## Threat model

### Boundaries and actors

- Widened Redfish boundary: a remote network client can reach Sushy when a local operator
  selects a non-loopback address. Anonymous clients can discover the service root;
  authenticated clients can control power and trigger server-side virtual-media fetches.
- Added serial boundary: any client able to reach the selected TCP address can read and write
  the guest serial stream. There is no serial authentication.
- Existing local-operator boundary: environment inputs control rendered Python, XML,
  certificate extensions, and shell-sourceable connection metadata.

The trusted actor is the local test-host operator choosing addresses and firewall policy.
Remote clients and other network peers are untrusted even when they possess Redfish Basic
credentials.

### Controls

- Address and port parsing is structural and rejects text that could become Python, XML,
  OpenSSL, URI, or shell syntax. Rendering substitutes only validated canonical values.
- Redfish retains existing TLS and Basic authentication behavior. Non-loopback selection
  emits an exposure warning; no claim is made that discovery is authenticated.
- TCP serial remains opt-in, emits a plaintext/unauthenticated warning, and binds only the
  exact operator-selected address. Connection metadata stays mode 0600.
- Existing lifecycle ownership, UUID checks, locks, private state permissions, and bounded
  integration cleanup remain in force.

### Out of scope

Firewall configuration, trusted public certificates, Redfish authorization beyond existing
Basic authentication, serial encryption/authentication, and hostile co-tenants on the test
host are not addressed. The service remains a development/test BMC stand-in, not a
production BMC.

## Acceptance tests

Offline Bats tests cover defaults, valid IPv4/IPv6 rendering, invalid and incompatible input,
safe Python/XML/shell rendering, certificate SAN generation and mismatch, endpoint metadata,
doctor endpoint probes and warnings, exact PTY/TCP domain shapes, and rerun rejection.
Integration coverage proves Redfish discovery through the configured endpoint, all existing
reset actions, NMI-induced guest panic and restart observed over serial, and the sentinel over
both PTY and TCP transports. `make test` remains the CI guardrail; `make test-integration` is
the host-mutating proof.

## Durable workflow state

- Branch: `feat/bmc-managed-host-6`
- Base branch: `main`
- CI and local guardrail: `make test`
- Opt-in live proof: `make test-integration`
