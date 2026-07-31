X86 VM with Redfish/IPMI Management Controller
==============================================
This repo includes build and install scripts for a libvirt/qemu based
virtual machine (VM) that includes a reference IPMI/Redfish-compatabile
BMC to simulate a bare-metal system for development/test purposes. It is
similar to exsting repos such as https://github.com:randomparity/vm-ppc64le
which create non-x86 architecture VMs for testing.

## Commands

- `make doctor`: verify host prerequisites without changing the host.
- `make create`: create or validate the project-owned VM and Redfish state.
- `make redfish`: run the loopback Redfish service in the foreground.
- `make test`: run offline tests and static checks.
- `make test-integration`: run opt-in host integration tests.
- `make destroy`: remove only project-owned VM resources.
- `make clean`: alias for `make destroy`.
