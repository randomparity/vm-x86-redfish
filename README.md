# x86 VM with Redfish Management Controller

This repository creates a project-owned x86_64 libvirt/QEMU virtual machine and runs a
reference Redfish management controller for local development and testing. The VM uses the
system libvirt connection and remains powered off after creation.

## Operator workflow

Check the host, create or validate the VM and generated Redfish state, load the connection
details and credentials, and start the Redfish service:

```bash
make doctor
make create
source .state/connection.env
source "$REDFISH_CREDENTIALS_FILE"
make redfish
```

`make redfish` runs Sushy in the foreground. Leave it running and make Redfish requests from
a second terminal:

```bash
source .state/connection.env
source "$REDFISH_CREDENTIALS_FILE"
curl --cacert "$REDFISH_CA_CERT" \
  --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
  "$REDFISH_ENDPOINT/redfish/v1/Systems"
```

The generated certificate is self-signed, so clients must trust the generated CA certificate
explicitly. Clean up only after the foreground service has exited:

```bash
# Press Ctrl-C in the terminal running make redfish, then run:
make destroy
```

`make destroy` refuses while `make redfish` holds the lifecycle lock. Stop the foreground
Redfish process before destroying project-owned VM resources.

## Commands

- `make doctor`: verify host prerequisites without changing the host.
- `make create`: create or validate the project-owned VM and Redfish state.
- `make redfish`: run the loopback Redfish service in the foreground.
- `make test`: run offline tests and static checks.
- `make test-integration`: create isolated host VMs, verify authenticated Redfish power,
  virtual media, boot overrides, and COM1 serial output, then remove test resources.
- `make destroy`: owner-gated, idempotent cleanup of project VM state, media, and temp files.
- `make clean`: alias for `make destroy`.

`make test-integration` is opt-in because it mutates host libvirt state. It uses isolated,
test-owned domains, volumes, and state, and cleans those resources after the run.

## Troubleshooting

Run `make doctor` to identify missing host dependencies, unavailable libvirt resources, or a
listener already using `127.0.0.1:8000`. Lifecycle commands fail immediately when another
command holds the project lock; wait for that command to exit before retrying.

Generated configuration, credentials, certificates, logs, virtual-media metadata, and runtime
files remain in the ignored `.state/` directory. Treat `.state/` as sensitive while the
service exists, especially if virtual-media credentials were supplied. Integration-test
diagnostics remain in ignored `.artifacts/`. Do not commit generated files or credentials.

## Limitations and security boundaries

This project provides Redfish rather than IPMI and manages one local project-owned VM through
`qemu:///system`. It is intended for development and test use, not production deployment.

The Redfish service listens only on `127.0.0.1:8000`. Treat virtual-media URLs as trusted
local test inputs because authenticated users can cause the service to fetch them.
Discovery at `/redfish/v1` is intentionally unauthenticated; system resources and mutation
actions require Basic authentication.

TLS verification is enabled for virtual-media downloads. The initial contract supports
power on, forced power off, forced restart, one virtual CD device, and `Hdd`, `Cd`, and `Pxe`
boot overrides.
