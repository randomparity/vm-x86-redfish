# Repository Guidelines

## Project Structure & Module Organization

This repository provides an x86 libvirt/QEMU virtual machine with a reference
Redfish/IPMI management controller. Keep top-level documentation and entry-point scripts
easy to discover. Place reusable shell code in `scripts/`, machine or service configuration
in `config/`, and automated checks in `tests/`. Do not commit generated VM disks, firmware
blobs, logs, or local runtime state.

## Build, Test, and Development Commands

Use the Make targets below; commands should be non-interactive where practical, fail on
errors, and clearly report missing host dependencies such as QEMU or libvirt.

- `make doctor`: verify host prerequisites without changing the host.
- `make create`: create or validate the project-owned VM and Redfish state.
- `make redfish`: run the loopback Redfish service in the foreground.
- `make test`: run offline tests and static checks.
- `make test-integration`: run opt-in host integration tests and mutates host libvirt state.
- `make destroy`: remove only project-owned VM resources.
- `make clean`: alias for `make destroy`.

## Coding Style & Naming Conventions

Use two-space indentation in shell and YAML files, with a 100-character line limit. Shell
scripts must begin with `#!/usr/bin/env bash` and `set -euo pipefail`; format them with
`shfmt -i 2 -w <file>` and lint them with `shellcheck <file>`. Use lowercase kebab-case for
executable scripts (for example, `scripts/create-vm`) and descriptive snake_case names for
shell functions and variables. Prefer explicit, readable commands over compact pipelines.

## Testing Guidelines

Every behavior added should have an automated test, including invalid configuration,
missing dependencies, and cleanup after partial failures. Name shell tests by behavior,
such as `tests/create-vm.bats`, if Bats is introduced. Mock external boundaries rather than
internal logic. Until a framework is selected, include reproducible verification steps in
the pull request and avoid claiming coverage targets.

## Commit & Pull Request Guidelines

The history currently establishes a concise, imperative style (`Initial commit`). Keep
subjects under 72 characters and make each commit one logical change. Pull requests should
describe the resulting behavior, list commands run, link relevant issues, and call out host
requirements or configuration changes. Include terminal output for CLI behavior changes;
screenshots are only useful if a graphical interface is added.

## Security & Configuration

Never commit credentials, API tokens, private keys, or production Redfish configuration.
Use ignored local environment files for secrets and provide sanitized example configuration
when configuration is introduced.
