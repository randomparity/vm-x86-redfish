# Redfish-Controlled x86 VM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development
> (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox
> (`- [ ]`) syntax for tracking.

**Goal:** Build the first repository deliverable: an x86_64 libvirt/QEMU VM managed through
a loopback-only, TLS-enabled Sushy Emulator Redfish endpoint.

**Architecture:** Bash lifecycle scripts own host orchestration, libvirt XML rendering,
locking, generated state, and cleanup. Sushy Emulator remains the only Redfish
implementation; this repo supplies pinned dependencies, configuration, tests, and documented
operator workflows rather than wrapping Redfish itself.

**Tech Stack:** Bash, Make, Bats, ShellCheck, shfmt, uv, Python 3.13,
`sushy-tools==2.2.0`, `libvirt-python==12.0.0`, libvirt 12.0.x, QEMU/KVM.

## Global Constraints

- Source spec: `docs/specs/redfish-vm.md` with `Status: Accepted`.
- Work branch: `feat/redfish-vm-plan`; `BASE_BRANCH=main`.
- GitHub repo: `randomparity/vm-x86-redfish`; tracking issue: #1.
- The first release targets Fedora 44 hosts and `qemu:///system`.
- The fixed developer domain name is `vm-x86-redfish`.
- Generated configuration, credentials, certificates, identifiers, logs, downloaded media,
  VM disks, firmware state, and retained diagnostics must stay out of git under `.state/`
  and `.artifacts/`.
- Shell scripts must start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Use two-space indentation in shell and YAML files, with a 100-character line limit.
- Format changed shell files with `shfmt -i 2 -w path...` and lint them with `shellcheck`.
- Python runtime is 3.13 through `uv`; use exact pins in `pyproject.toml` and `uv.lock`.
- Use `ruff check`, `ruff format`, `ty check`, and `pytest -q` for Python only if Python
  project code or Python tests are added beyond Sushy configuration validation.
- GitHub Actions must pin actions by full commit SHA with a version comment and use
  `persist-credentials: false`.
- Available pre-implementation guardrail: `git diff --check`.
- Planned guardrail after Task 1: `make test`.
- Planned host preflight check: `make doctor`.
- Planned integration proof: `make test-integration`, opt-in only.
- ADR coupling verdict: not coupled; no `docs/adr/` index or ADR gate exists in this repo.
- Security model: Redfish listens only on `127.0.0.1:8000`; discovery root is public; all
  system, virtual-media, and action resources require Basic authentication.

---

## File Structure

- `.gitignore` records generated state, artifacts, virtual disks, local virtualenvs, Python
  caches, and coverage output that must never be committed.
- `Makefile` is the public command surface: `doctor`, `create`, `redfish`, `destroy`,
  `test`, `test-integration`, and `clean`.
- `pyproject.toml` and `uv.lock` pin Sushy Emulator and libvirt bindings for the configured
  Fedora 44 host contract.
- `.github/workflows/ci.yml` runs the non-mutating local guardrail command.
- `.github/dependabot.yml` groups weekly GitHub Actions and uv updates with a 7-day cooldown.
- `config/domain.xml` is a libvirt domain XML template with explicit replacement tokens.
- `config/sushy-emulator.conf.py.in` is a Python config template rendered into `.state/`.
- `scripts/lib/common` provides shared constants, path canonicalization, lock handling,
  safe state-directory checks, ownership checks, and command wrappers used by lifecycle
  scripts.
- `scripts/doctor` performs read-only host checks and prints package-level remediation.
- `scripts/render-config` renders project templates into `.state/`.
- `scripts/create-vm` creates or validates the project-owned VM, credentials, TLS material,
  state directories, and generated Sushy config.
- `scripts/run-redfish` validates runtime state, holds the lifecycle lock, and `exec`s Sushy
  in the foreground.
- `scripts/destroy-vm` validates ownership and removes only project-owned libvirt resources
  and checked state files.
- `tests/helpers/test-helper.bash` creates per-test temporary workspaces and command mocks.
- `tests/doctor.bats` covers read-only host checks and missing-dependency diagnostics.
- `tests/render-config.bats` covers deterministic template rendering and secret file modes.
- `tests/create-vm.bats` covers create idempotency, ownership rejection, and rollback.
- `tests/destroy-vm.bats` covers owner-gated cleanup and media-volume matching.
- `tests/redfish-integration.bats` is opt-in and exercises the real libvirt/Sushy boundary.
- `tests/fixtures/grub.cfg.in` prints a run-specific serial sentinel and halts.

## Task 1: Project Guardrails and Command Surface

**Files:**
- Create: `.gitignore`
- Create: `Makefile`
- Create: `pyproject.toml`
- Create: `.github/workflows/ci.yml`
- Create: `.github/dependabot.yml`
- Modify: `AGENTS.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: Accepted spec and repository standards.
- Produces: Public commands `make doctor`, `make create`, `make redfish`, `make destroy`,
  `make test`, `make test-integration`, and `make clean`.

- [ ] **Step 1: Write the failing command-surface check**

  Create `tests/command-surface.bats` with:

  ```bash
  #!/usr/bin/env bats

  @test "Makefile exposes required public targets" {
    run make -n doctor create redfish destroy test test-integration clean
    [ "$status" -eq 0 ]
  }

  @test "generated runtime state is ignored" {
    run git check-ignore .state/domain-uuid .artifacts/example/log.txt .venv/bin/python
    [ "$status" -eq 0 ]
  }
  ```

- [ ] **Step 2: Run the command-surface check and verify it fails**

  Run:

  ```bash
  bats tests/command-surface.bats
  ```

  Expected: FAIL because `Makefile` and `.gitignore` do not exist yet.

- [ ] **Step 3: Add generated-state ignores**

  Create `.gitignore` with:

  ```gitignore
  .artifacts/
  .coverage
  .pytest_cache/
  .state/
  .venv/
  __pycache__/
  *.qcow2
  *.raw
  ```

- [ ] **Step 4: Add the public Make targets**

  Create `Makefile` with:

  ```makefile
  SHELL := bash
  .SHELLFLAGS := -euo pipefail -c
  .RECIPEPREFIX := >

  .PHONY: doctor create redfish destroy test test-integration clean

  doctor:
  >./scripts/doctor

  create:
  >./scripts/create-vm

  redfish:
  >./scripts/run-redfish

  destroy:
  >./scripts/destroy-vm

  OFFLINE_BATS_TESTS := $(wildcard tests/command-surface.bats tests/doctor.bats)
  OFFLINE_BATS_TESTS += $(wildcard tests/render-config.bats tests/create-vm.bats)
  OFFLINE_BATS_TESTS += $(wildcard tests/destroy-vm.bats)
  SHELL_SCRIPTS := $(wildcard scripts/doctor scripts/create-vm scripts/destroy-vm)
  SHELL_SCRIPTS += $(wildcard scripts/render-config scripts/run-redfish scripts/lib/common)
  EXECUTABLE_SCRIPTS := $(filter-out scripts/lib/common,$(SHELL_SCRIPTS))
  PYTHON_313 := $(shell UV_PYTHON_DOWNLOADS=never uv python find 3.13 2>/dev/null)
  SHFMT_PATHS := $(wildcard scripts tests)

  test:
  >@if [ -n "$(OFFLINE_BATS_TESTS)" ]; then bats $(OFFLINE_BATS_TESTS); fi
  >@if [ -n "$(SHELL_SCRIPTS)" ]; then shellcheck $(SHELL_SCRIPTS); fi
  >@for script in $(EXECUTABLE_SCRIPTS); do test -x "$$script"; done
  >@if [ -n "$(SHFMT_PATHS)" ]; then shfmt -i 2 -d $(SHFMT_PATHS); fi
  >@if [ -f uv.lock ]; then uv lock --check; fi
  >@if [ -f config/sushy-emulator.conf.py.in ]; then \
  >  test -n "$(PYTHON_313)"; \
  >  "$(PYTHON_313)" -m py_compile config/sushy-emulator.conf.py.in; \
  >fi

  test-integration:
  >bats tests/redfish-integration.bats

  clean:
  >./scripts/destroy-vm
  ```

- [ ] **Step 5: Add the pinned uv project**

  Create `pyproject.toml` with:

  ```toml
  [project]
  name = "vm-x86-redfish"
  version = "0.1.0"
  requires-python = "==3.13.*"
  dependencies = [
    "libvirt-python==12.0.0",
    "sushy-tools==2.2.0",
  ]

  [dependency-groups]
  dev = [
    "pip-audit==2.10.1",
    "pytest==9.1.1",
    "ruff==0.16.1",
    "ty==0.0.65",
  ]

  [tool.ruff]
  line-length = 100
  target-version = "py313"

  [tool.ty.rules]
  unresolved-import = "error"
  ```

  Run:

  ```bash
  uv lock
  ```

  Expected: `uv.lock` is created with exact transitive dependency resolution.

- [ ] **Step 6: Add CI and dependency update configuration**

  Create `.github/workflows/ci.yml` with actions pinned to full SHAs looked up on
  2026-07-31:

  ```yaml
  name: ci

  on:
    pull_request:
    push:
      branches: [main]

  permissions:
    contents: read

  jobs:
    test:
      runs-on: ubuntu-latest
      steps:
        - name: Check out repository
          uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
          with:
            persist-credentials: false
        - name: Install uv
          uses: astral-sh/setup-uv@c771a70e6277c0a99b617c7a806ffedaca235ff9 # v9.0.0
        - name: Install Python 3.13
          run: uv python install 3.13
        - name: Install host test tools
          run: sudo apt-get update && sudo apt-get install -y bats shellcheck shfmt
        - name: Run offline guardrails
          run: make test
  ```

  Re-run these lookup commands during implementation before committing. If either tag has a
  newer stable release, update the pinned SHA and version comment in this same task:

  ```bash
  git ls-remote --tags https://github.com/actions/checkout.git 'refs/tags/v*'
  git ls-remote --tags https://github.com/astral-sh/setup-uv.git 'refs/tags/*'
  ```

  Create `.github/dependabot.yml` with:

  ```yaml
  version: 2
  updates:
    - package-ecosystem: github-actions
      directory: /
      schedule:
        interval: weekly
      groups:
        github-actions:
          patterns: ["*"]
      cooldown:
        default-days: 7
    - package-ecosystem: uv
      directory: /
      schedule:
        interval: weekly
      groups:
        python-dependencies:
          patterns: ["*"]
      cooldown:
        default-days: 7
  ```

- [ ] **Step 7: Document the command surface**

  Update `README.md` so it includes:

  ```markdown
  ## Commands

  - `make doctor`: verify host prerequisites without changing the host.
  - `make create`: create or validate the project-owned VM and Redfish state.
  - `make redfish`: run the loopback Redfish service in the foreground.
  - `make test`: run offline tests and static checks.
  - `make test-integration`: run opt-in host integration tests.
  - `make destroy`: remove only project-owned VM resources.
  - `make clean`: alias for `make destroy`.
  ```

  Update `AGENTS.md` "Build, Test, and Development Commands" with the same targets and
  note that `make test-integration` mutates host libvirt state.

- [ ] **Step 8: Run guardrails and commit**

  Run:

  ```bash
  bats tests/command-surface.bats
  make test
  zizmor .github/workflows/
  git diff --check
  ```

  Expected: all commands exit 0. Commit:

  ```bash
  git add .gitignore Makefile pyproject.toml uv.lock .github README.md AGENTS.md tests
  git commit -m "chore: add project guardrails"
  ```

## Task 2: Shared Shell Test Harness and Lifecycle Primitives

**Files:**
- Create: `scripts/lib/common`
- Create: `tests/helpers/test-helper.bash`
- Test: `tests/render-config.bats`

**Interfaces:**
- Produces shell constants: `PROJECT_NAME`, `DEFAULT_DOMAIN_NAME`, `LIBVIRT_URI`,
  `STATE_DIR`, `ARTIFACTS_DIR`, `ROOT_VOLUME_NAME`, `DOMAIN_UUID_FILE`, and
  `LIFECYCLE_LOCK`.
- Produces functions: `repo_root`, `fail`, `need_command`, `canonical_dir`,
  `ensure_private_dir`, `require_private_dir`, `reject_symlink`, `with_lifecycle_lock`,
  `read_domain_uuid`, `write_secret_file`, `volume_name_for_media`, and
  `load_runtime_config`.
- Rejects test-only override variables from every lifecycle entry point unless
  `VM_X86_REDFISH_INTEGRATION_TEST=1`.

- [ ] **Step 1: Write tests for private state validation and media volume names**

  Add to `tests/render-config.bats`:

  ```bash
  #!/usr/bin/env bats

  load "helpers/test-helper"

  @test "ensure_private_dir creates mode 0700 directory" {
    run bash -c '
      source scripts/lib/common
      STATE_DIR="$BATS_TEST_TMPDIR/state"
      ensure_private_dir "$STATE_DIR"
      stat -c "%a %F" "$STATE_DIR"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "700 directory" ]
  }

  @test "ensure_private_dir rejects symlinks" {
    mkdir -p "$BATS_TEST_TMPDIR/real"
    ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/state"
    run bash -c '
      source scripts/lib/common
      ensure_private_dir "$BATS_TEST_TMPDIR/state"
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing symlink"* ]]
  }

  @test "require_private_dir rejects missing or loose tmp directories" {
    run bash -c '
      source scripts/lib/common
      require_private_dir "$BATS_TEST_TMPDIR/missing"
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing private directory"* ]]

    mkdir -p "$BATS_TEST_TMPDIR/tmp"
    chmod 755 "$BATS_TEST_TMPDIR/tmp"
    run bash -c '
      source scripts/lib/common
      require_private_dir "$BATS_TEST_TMPDIR/tmp"
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"directory must be mode 0700"* ]]
  }

  @test "media volume name replaces dots and appends domain uuid" {
    run bash -c '
      source scripts/lib/common
      volume_name_for_media "https://example.test/images/fedora.iso" \
        "11111111-2222-3333-4444-555555555555"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "fedora-iso-11111111-2222-3333-4444-555555555555.img" ]
  }
  ```

- [ ] **Step 2: Run tests and verify they fail**

  Run:

  ```bash
  bats tests/render-config.bats
  ```

  Expected: FAIL because `scripts/lib/common` does not exist.

- [ ] **Step 3: Implement shared lifecycle primitives**

  Create `scripts/lib/common` with:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  PROJECT_NAME="vm-x86-redfish"
  DEFAULT_DOMAIN_NAME="vm-x86-redfish"
  LIBVIRT_URI="qemu:///system"
  STORAGE_POOL="default"
  STATE_DIR=".state"
  ARTIFACTS_DIR=".artifacts"
  ROOT_VOLUME_NAME="vm-x86-redfish.qcow2"
  DOMAIN_UUID_FILE="${STATE_DIR}/domain-uuid"
  LIFECYCLE_LOCK="${STATE_DIR}/lifecycle.lock"

  fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
  }

  repo_root() {
    git rev-parse --show-toplevel 2>/dev/null || pwd
  }

  need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "missing command '$1': install $2"
  }

  python_313() {
    UV_PYTHON_DOWNLOADS=never uv python find 3.13 2>/dev/null ||
      fail "uv must find Python 3.13 without downloading"
  }

  integration_override_enabled() {
    [ "${VM_X86_REDFISH_INTEGRATION_TEST:-}" = "1" ]
  }

  reject_unguarded_override() {
    local name="$1"
    if [ -n "${!name:-}" ] && ! integration_override_enabled; then
      fail "test-only overrides require VM_X86_REDFISH_INTEGRATION_TEST=1"
    fi
  }

  load_runtime_config() {
    reject_unguarded_override VM_X86_REDFISH_DOMAIN_NAME
    reject_unguarded_override VM_X86_REDFISH_LIBVIRT_URI
    reject_unguarded_override VM_X86_REDFISH_STORAGE_POOL
    reject_unguarded_override VM_X86_REDFISH_ROOT_VOLUME_NAME
    reject_unguarded_override VM_X86_REDFISH_STATE_DIR
    reject_unguarded_override VM_X86_REDFISH_ARTIFACTS_DIR
    DEFAULT_DOMAIN_NAME="${VM_X86_REDFISH_DOMAIN_NAME:-vm-x86-redfish}"
    LIBVIRT_URI="${VM_X86_REDFISH_LIBVIRT_URI:-qemu:///system}"
    STORAGE_POOL="${VM_X86_REDFISH_STORAGE_POOL:-default}"
    STATE_DIR="${VM_X86_REDFISH_STATE_DIR:-.state}"
    ARTIFACTS_DIR="${VM_X86_REDFISH_ARTIFACTS_DIR:-.artifacts}"
    ROOT_VOLUME_NAME="${VM_X86_REDFISH_ROOT_VOLUME_NAME:-${DEFAULT_DOMAIN_NAME}.qcow2}"
    DOMAIN_UUID_FILE="${STATE_DIR}/domain-uuid"
    LIFECYCLE_LOCK="${STATE_DIR}/lifecycle.lock"
  }

  load_runtime_config

  reject_symlink() {
    local path="$1"
    [ ! -L "$path" ] || fail "refusing symlink: $path"
  }

  ensure_private_dir() {
    local path="$1"
    reject_symlink "$path"
    mkdir -p "$path"
    chmod 700 "$path"
    [ -d "$path" ] || fail "not a directory: $path"
    [ "$(stat -c '%a' "$path")" = "700" ] || fail "directory must be mode 0700: $path"
  }

  require_private_dir() {
    local path="$1"
    reject_symlink "$path"
    [ -d "$path" ] || fail "missing private directory: $path"
    [ "$(stat -c '%u' "$path")" = "$(id -u)" ] ||
      fail "directory must be owned by the current user: $path"
    [ "$(stat -c '%a' "$path")" = "700" ] || fail "directory must be mode 0700: $path"
  }

  canonical_dir() {
    local path="$1"
    reject_symlink "$path"
    [ -d "$path" ] || fail "missing directory: $path"
    realpath -e "$path"
  }

  write_secret_file() {
    local path="$1"
    local content="$2"
    umask 077
    printf '%s\n' "$content" >"$path"
    chmod 600 "$path"
  }

  read_domain_uuid() {
    [ -f "$DOMAIN_UUID_FILE" ] || fail "missing domain UUID file: $DOMAIN_UUID_FILE"
    tr -d '\n' <"$DOMAIN_UUID_FILE"
  }

  with_lifecycle_lock() {
    local lock_path="$1"
    shift
    ensure_private_dir "$(dirname "$lock_path")"
    exec 9>"$lock_path"
    flock -n 9 || fail "lifecycle lock is held: $lock_path"
    "$@"
  }

  volume_name_for_media() {
    local image_url="$1"
    local domain_uuid="$2"
    local base
    base="${image_url##*/}"
    base="${base%%\?*}"
    base="${base//./-}"
    printf '%s-%s.img\n' "$base" "$domain_uuid"
  }
  ```

- [ ] **Step 4: Add test helper cleanup**

  Create `tests/helpers/test-helper.bash` with:

  ```bash
  install_mock_command() {
    local name="$1"
    local body="$2"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/$name" <<SH
  #!/usr/bin/env bash
  set -euo pipefail
  $body
  SH
    chmod +x "$BATS_TEST_TMPDIR/bin/$name"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  }

  install_recording_noop() {
    local name="$1"
    install_mock_command "$name" \
      'printf "%s %s\n" "$(basename "$0")" "$*" >>"$BATS_TEST_TMPDIR/commands.log"'
  }

  install_uv_python_mock() {
    local python_bin
    python_bin="$(command -v python3)"
    install_mock_command uv "
  case \"\$*\" in
    \"python find 3.13\") printf '%s\n' '$python_bin' ;;
    *) exit 2 ;;
  esac
  "
  }

  setup_test_workspace() {
    export REPO_ROOT
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    cd "$REPO_ROOT"
    export VM_X86_REDFISH_INTEGRATION_TEST=1
    export VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export VM_X86_REDFISH_ARTIFACTS_DIR="$BATS_TEST_TMPDIR/artifacts"
    mkdir -p "$VM_X86_REDFISH_STATE_DIR" "$VM_X86_REDFISH_ARTIFACTS_DIR"
    install_uv_python_mock
  }

  setup() {
    setup_test_workspace
  }
  ```

- [ ] **Step 5: Run tests and commit**

  Run:

  ```bash
  shfmt -i 2 -w scripts/lib/common tests/helpers/test-helper.bash tests/render-config.bats
  shellcheck scripts/lib/common tests/helpers/test-helper.bash
  bats tests/render-config.bats
  make test
  ```

  Expected: all commands exit 0. Commit:

  ```bash
  git add scripts/lib/common tests/helpers/test-helper.bash tests/render-config.bats
  git commit -m "test: add lifecycle shell primitives"
  ```

## Task 3: Read-Only Host Doctor

**Files:**
- Create: `scripts/doctor`
- Create: `tests/doctor.bats`
- Modify: `README.md`

**Interfaces:**
- Consumes `need_command`, `LIBVIRT_URI`, and `STORAGE_POOL` from `scripts/lib/common`.
- Produces `scripts/doctor`, a read-only prerequisite checker used by `make doctor` and
  documented as non-mutating.

- [ ] **Step 1: Write missing-command diagnostics tests**

  Create `tests/doctor.bats` with:

  ```bash
  #!/usr/bin/env bats

  load "helpers/test-helper"

  @test "doctor reports missing qemu-img with Fedora package hint" {
    bash_bin="$(command -v bash)"
    install_mock_command uname 'printf "x86_64\n"'
    install_mock_command virsh 'exit 0'
    install_mock_command qemu-system-x86_64 'exit 0'
    PATH="$BATS_TEST_TMPDIR/bin" run "$bash_bin" ./scripts/doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing command 'qemu-img': install qemu-img"* ]]
  }

  @test "doctor rejects non-x86_64 hosts" {
    install_mock_command uname 'printf "aarch64\n"'
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run ./scripts/doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported architecture aarch64; expected x86_64"* ]]
  }
  ```

- [ ] **Step 2: Run tests and verify they fail**

  Run:

  ```bash
  bats tests/doctor.bats
  ```

  Expected: FAIL because `scripts/doctor` does not exist.

- [ ] **Step 3: Implement read-only command and host checks**

  Create `scripts/doctor` with:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  script_dir="${BASH_SOURCE[0]%/*}"
  source "${script_dir}/lib/common"

  check_architecture() {
    local arch
    arch="$(uname -m)"
    [ "$arch" = "x86_64" ] || fail "unsupported architecture $arch; expected x86_64"
  }

  check_commands() {
    need_command virsh "libvirt-client"
    need_command qemu-system-x86_64 "qemu-system-x86-core"
    need_command qemu-img "qemu-img"
    need_command uuidgen "util-linux-core"
    need_command uv "uv"
    need_command curl "curl"
    need_command openssl "openssl"
    need_command htpasswd "httpd-tools"
    need_command bats "bats"
    need_command shellcheck "ShellCheck"
    need_command shfmt "shfmt"
    need_command grub2-mkrescue "grub2-tools-extra"
    need_command xorriso "xorriso"
  }

  check_libvirt() {
    local version
    virsh -c "$LIBVIRT_URI" uri >/dev/null ||
      fail "cannot connect to $LIBVIRT_URI: enable libvirtd and grant access"
    version="$(virsh -c "$LIBVIRT_URI" version)"
    printf '%s\n' "$version" | grep -F "Using library: libvirt 12.0." >/dev/null ||
      fail "unsupported libvirt version: expected 12.0.x"
    require_active_network
    require_running_pool
  }

  require_active_network() {
    local info
    info="$(virsh -c "$LIBVIRT_URI" net-info default)" ||
      fail "libvirt default network is unavailable: define it before running create"
    printf '%s\n' "$info" | grep -E '^Active:[[:space:]]+yes$' >/dev/null ||
      fail "libvirt default network is inactive: start it with virsh net-start default"
  }

  require_running_pool() {
    local info
    info="$(virsh -c "$LIBVIRT_URI" pool-info "$STORAGE_POOL")" ||
      fail "libvirt storage pool '$STORAGE_POOL' is unavailable"
    printf '%s\n' "$info" | grep -E '^State:[[:space:]]+running$' >/dev/null ||
      fail "libvirt storage pool '$STORAGE_POOL' is not running"
  }

  kvm_device_path() {
    if integration_override_enabled && [ -n "${VM_X86_REDFISH_DEV_KVM:-}" ]; then
      printf '%s\n' "$VM_X86_REDFISH_DEV_KVM"
    else
      printf '/dev/kvm\n'
    fi
  }

  ovmf_dir_path() {
    if integration_override_enabled && [ -n "${VM_X86_REDFISH_OVMF_DIR:-}" ]; then
      printf '%s\n' "$VM_X86_REDFISH_OVMF_DIR"
    elif [ -d /usr/share/edk2/ovmf ]; then
      printf '/usr/share/edk2/ovmf\n'
    else
      printf '/usr/share/OVMF\n'
    fi
  }

  check_kvm() {
    local kvm_path
    kvm_path="$(kvm_device_path)"
    [ -e "$kvm_path" ] || fail "missing $kvm_path: enable KVM virtualization"
    [ -r "$kvm_path" ] && [ -w "$kvm_path" ] ||
      fail "cannot read and write $kvm_path: add the user to the kvm group"
  }

  check_uefi_firmware() {
    local ovmf_dir
    ovmf_dir="$(ovmf_dir_path)"
    [ -d "$ovmf_dir" ] || fail "missing UEFI firmware: install edk2-ovmf"
  }

  check_uv_python() {
    local python_bin
    python_bin="$(python_313)"
    "$python_bin" - <<'PY' || fail "uv must provide Python 3.13"
  import sys
  raise SystemExit(0 if sys.version_info[:2] == (3, 13) else 1)
  PY
  }

  check_loopback_port() {
    local python_bin
    if integration_override_enabled &&
      [ "${VM_X86_REDFISH_PORT_CHECK_RESULT:-}" = "busy" ]; then
      fail "127.0.0.1:8000 is already in use"
    fi
    python_bin="$(python_313)"
    "$python_bin" - <<'PY' || fail "127.0.0.1:8000 is already in use"
  import socket
  with socket.socket() as sock:
      sock.bind(("127.0.0.1", 8000))
  PY
  }

  check_architecture
  check_commands
  check_kvm
  check_uefi_firmware
  check_uv_python
  check_loopback_port
  check_libvirt
  printf 'doctor: host prerequisites are available\n'
  ```

- [ ] **Step 4: Add full Host Contract mock-boundary tests**

  Extend `tests/doctor.bats` with:

  ```bash
  @test "doctor checks KVM, Python 3.13, port 8000, libvirt, network, and pool" {
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    "-c qemu:///system uri")
      exit 0
      ;;
    "-c qemu:///system net-info default")
      printf "Active: yes\n"
      exit 0
      ;;
    "-c qemu:///system pool-info default")
      printf "State: running\n"
      exit 0
      ;;
    "-c qemu:///system version")
      printf "Using library: libvirt 12.0.0\n"
      ;;
    *)
      exit 2
      ;;
  esac
  '
    install_mock_command python313 'exit 0'
    install_mock_command uv '
  printf "uv %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    "python find 3.13")
      printf "%s/python313\n" "$BATS_TEST_TMPDIR/bin"
      ;;
    *)
      exit 2
      ;;
  esac
  '
    for command in qemu-system-x86_64 qemu-img uuidgen curl openssl htpasswd bats shellcheck shfmt \
      grub2-mkrescue xorriso; do
      install_recording_noop "$command"
    done
    mkdir -p "$BATS_TEST_TMPDIR/dev" "$BATS_TEST_TMPDIR/usr/share/edk2/ovmf"
    touch "$BATS_TEST_TMPDIR/dev/kvm"
    VM_X86_REDFISH_DEV_KVM="$BATS_TEST_TMPDIR/dev/kvm" \
      VM_X86_REDFISH_OVMF_DIR="$BATS_TEST_TMPDIR/usr/share/edk2/ovmf" \
      run ./scripts/doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"doctor: host prerequisites are available"* ]]
    run grep -F "virsh -c qemu:///system version" "$BATS_TEST_TMPDIR/commands.log"
    [ "$status" -eq 0 ]
  }

  @test "doctor rejects unavailable loopback port 8000" {
    install_all_doctor_success_mocks
    VM_X86_REDFISH_PORT_CHECK_RESULT=busy run ./scripts/doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"127.0.0.1:8000 is already in use"* ]]
  }

  @test "doctor reports missing uuidgen with Fedora package hint" {
    install_all_doctor_success_mocks
    rm "$BATS_TEST_TMPDIR/bin/uuidgen"
    run ./scripts/doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing command 'uuidgen': install util-linux-core"* ]]
  }

  @test "doctor rejects inactive default network" {
    install_all_doctor_success_mocks
    install_mock_command virsh '
  case "$*" in
    *"version") printf "Using library: libvirt 12.0.0\n" ;;
    *"net-info default") printf "Active: no\n" ;;
    *"pool-info default") printf "State: running\n" ;;
    *) exit 0 ;;
  esac
  '
    run ./scripts/doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"libvirt default network is inactive"* ]]
  }

  @test "doctor rejects inactive default storage pool" {
    install_all_doctor_success_mocks
    install_mock_command virsh '
  case "$*" in
    *"version") printf "Using library: libvirt 12.0.0\n" ;;
    *"net-info default") printf "Active: yes\n" ;;
    *"pool-info default") printf "State: inactive\n" ;;
    *) exit 0 ;;
  esac
  '
    run ./scripts/doctor
    [ "$status" -ne 0 ]
    [[ "$output" == *"libvirt storage pool 'default' is not running"* ]]
  }
  ```

  Add this helper to `tests/doctor.bats` before the unavailable-port test:

  ```bash
  install_all_doctor_success_mocks() {
    install_mock_command virsh '
  case "$*" in
    *"version") printf "Using library: libvirt 12.0.0\n" ;;
    *"net-info default") printf "Active: yes\n" ;;
    *"pool-info default") printf "State: running\n" ;;
    *) exit 0 ;;
  esac
  '
    install_mock_command python313 'exit 0'
    install_mock_command uv '
  case "$*" in
    "python find 3.13") printf "%s/python313\n" "$BATS_TEST_TMPDIR/bin" ;;
    *) exit 2 ;;
  esac
  '
    for command in uname qemu-system-x86_64 qemu-img uuidgen curl openssl htpasswd bats \
      shellcheck shfmt grub2-mkrescue xorriso; do
      install_recording_noop "$command"
    done
    install_mock_command uname 'printf "x86_64\n"'
    mkdir -p "$BATS_TEST_TMPDIR/dev" "$BATS_TEST_TMPDIR/usr/share/edk2/ovmf"
    touch "$BATS_TEST_TMPDIR/dev/kvm"
    export VM_X86_REDFISH_DEV_KVM="$BATS_TEST_TMPDIR/dev/kvm"
    export VM_X86_REDFISH_OVMF_DIR="$BATS_TEST_TMPDIR/usr/share/edk2/ovmf"
  }
  ```

  Add one more test to prove the read-only contract:

  ```bash
  @test "doctor does not create uv project state" {
    install_all_doctor_success_mocks
    before="$(git status --short uv.lock .venv)"
    run ./scripts/doctor
    [ "$status" -eq 0 ]
    after="$(git status --short uv.lock .venv)"
    [ "$after" = "$before" ]
    [ ! -e .venv ]
  }
  ```

- [ ] **Step 5: Run doctor tests and commit**

  Run:

  ```bash
  chmod +x scripts/doctor
  shfmt -i 2 -w scripts/doctor tests/doctor.bats
  shellcheck scripts/doctor
  bats tests/doctor.bats
  make test
  ```

  Expected: all commands exit 0. Commit:

  ```bash
  git add scripts/doctor tests/doctor.bats README.md
  git commit -m "feat: add host doctor"
  ```

## Task 4: Domain XML Rendering and Ownership Metadata

**Files:**
- Create: `config/domain.xml`
- Create: `scripts/render-config`
- Modify: `tests/render-config.bats`

**Interfaces:**
- Consumes `DEFAULT_DOMAIN_NAME`, `LIBVIRT_URI`, `ROOT_VOLUME_NAME`, `STATE_DIR`, and
  `read_domain_uuid`.
- Produces `.state/domain.xml` with the domain UUID, disk path, and project metadata.
- Produces `.state/domain-uuid` only when the caller has already decided creation owns this
  state directory.

- [ ] **Step 1: Write domain rendering tests**

  Add to `tests/render-config.bats`:

  ```bash
  @test "render-config writes domain XML with UUID and owner metadata" {
    mkdir -p "$BATS_TEST_TMPDIR/state"
    printf '11111111-2222-3333-4444-555555555555\n' \
      >"$BATS_TEST_TMPDIR/state/domain-uuid"
    VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" \
      VM_X86_REDFISH_ROOT_VOLUME_PATH="/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
      run ./scripts/render-config domain
    [ "$status" -eq 0 ]
    run grep -F "<name>vm-x86-redfish</name>" "$BATS_TEST_TMPDIR/state/domain.xml"
    [ "$status" -eq 0 ]
    run grep -F "<rp:project>vm-x86-redfish</rp:project>" \
      "$BATS_TEST_TMPDIR/state/domain.xml"
    [ "$status" -eq 0 ]
    run grep -F "<uuid>11111111-2222-3333-4444-555555555555</uuid>" \
      "$BATS_TEST_TMPDIR/state/domain.xml"
    [ "$status" -eq 0 ]
  }
  ```

- [ ] **Step 2: Run rendering tests and verify they fail**

  Run:

  ```bash
  bats tests/render-config.bats
  ```

  Expected: FAIL because `scripts/render-config` and `config/domain.xml` do not exist.

- [ ] **Step 3: Add the domain XML template**

  Create `config/domain.xml` with the fixed hardware contract:

  ```xml
  <domain type='kvm' xmlns:rp='https://github.com/randomparity/vm-x86-redfish'>
    <name>@DOMAIN_NAME@</name>
    <uuid>@DOMAIN_UUID@</uuid>
    <metadata>
      <rp:vm-x86-redfish>
        <rp:project>vm-x86-redfish</rp:project>
        <rp:root-volume>@ROOT_VOLUME_NAME@</rp:root-volume>
      </rp:vm-x86-redfish>
    </metadata>
    <memory unit='MiB'>4096</memory>
    <vcpu placement='static'>2</vcpu>
    <os firmware='efi'>
      <type arch='x86_64' machine='q35'>hvm</type>
      <firmware>
        <feature enabled='no' name='secure-boot'/>
      </firmware>
      <boot dev='hd'/>
    </os>
    <features>
      <acpi/>
      <apic/>
    </features>
    <cpu mode='host-passthrough' check='none'/>
    <clock offset='utc'/>
    <on_poweroff>destroy</on_poweroff>
    <on_reboot>restart</on_reboot>
    <on_crash>destroy</on_crash>
    <devices>
      <emulator>/usr/bin/qemu-system-x86_64</emulator>
      <disk type='file' device='disk'>
        <driver name='qemu' type='qcow2' discard='unmap'/>
        <source file='@ROOT_VOLUME_PATH@'/>
        <target dev='vda' bus='virtio'/>
      </disk>
      <interface type='network'>
        <source network='default'/>
        <model type='virtio'/>
      </interface>
      <serial type='pty'>
        <target type='isa-serial' port='0'>
          <model name='isa-serial'/>
        </target>
      </serial>
      <console type='pty'>
        <target type='serial' port='0'/>
      </console>
      <channel type='unix'>
        <target type='virtio' name='org.qemu.guest_agent.0'/>
      </channel>
      <graphics type='vnc' listen='127.0.0.1'/>
      <video>
        <model type='virtio'/>
      </video>
    </devices>
  </domain>
  ```

  If libvirt rejects the guest-agent channel in integration because no guest agent is
  installed, remove the `<channel>` block and update this plan before continuing. Do not add
  a virtio console; the spec requires COM1 serial only.

- [ ] **Step 4: Implement template rendering without ad hoc shell globbing**

  Create `scripts/render-config` with:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  script_dir="${BASH_SOURCE[0]%/*}"
  source "${script_dir}/lib/common"

  render_template() {
    local input="$1"
    local output="$2"
    local python_bin
    python_bin="$(python_313)"
    "$python_bin" - "$input" "$output" <<'PY'
  import os
  import pathlib
  import sys

  source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
  replacements = {
      "@DOMAIN_NAME@": os.environ["DOMAIN_NAME"],
      "@DOMAIN_UUID@": os.environ["DOMAIN_UUID"],
      "@ROOT_VOLUME_NAME@": os.environ["ROOT_VOLUME_NAME"],
      "@ROOT_VOLUME_PATH@": os.environ["ROOT_VOLUME_PATH"],
      "@STATE_DIR@": os.environ["STATE_DIR"],
  }
  rendered = source
  for key, value in replacements.items():
      rendered = rendered.replace(key, value)
  pathlib.Path(sys.argv[2]).write_text(rendered, encoding="utf-8")
  PY
  }

  render_domain() {
    ensure_private_dir "$STATE_DIR"
    export DOMAIN_NAME="$DEFAULT_DOMAIN_NAME"
    export DOMAIN_UUID
    export ROOT_VOLUME_NAME
    export ROOT_VOLUME_PATH="${VM_X86_REDFISH_ROOT_VOLUME_PATH:?missing root volume path}"
    export STATE_DIR
    DOMAIN_UUID="$(read_domain_uuid)"
    render_template config/domain.xml "${STATE_DIR}/domain.xml"
  }

  case "${1:-}" in
    domain) render_domain ;;
    *) fail "usage: scripts/render-config domain|sushy" ;;
  esac
  ```

- [ ] **Step 5: Run rendering guardrails and commit**

  Run:

  ```bash
  chmod +x scripts/render-config
  shfmt -i 2 -w scripts/render-config
  shellcheck scripts/render-config
  bats tests/render-config.bats
  make test
  ```

  Expected: all commands exit 0. Commit:

  ```bash
  git add config/domain.xml scripts/render-config tests/render-config.bats
  git commit -m "feat: render domain XML"
  ```

## Task 5: VM Creation, Idempotency, and Rollback

**Files:**
- Create: `scripts/create-vm`
- Create: `tests/create-vm.bats`
- Modify: `scripts/lib/common`
- Modify: `scripts/render-config`

**Interfaces:**
- Consumes `.state/domain-uuid`, `config/domain.xml`, and `scripts/render-config domain`.
- Produces project-owned libvirt domain and root volume.
- Exposes internal integration-test overrides only when
  `VM_X86_REDFISH_INTEGRATION_TEST=1`.

- [ ] **Step 1: Write create rollback and idempotency tests**

  Create `tests/create-vm.bats` with:

  ```bash
  #!/usr/bin/env bats

  load "helpers/test-helper"

  setup() {
    setup_test_workspace
    install_mock_command uuidgen \
      'printf "11111111-2222-3333-4444-555555555555\n"'
  }

  @test "create-vm writes uuid once and defines new owned domain" {
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2")
      exit 1
      ;;
    *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2")
      exit 0
      ;;
    *"define "*"/domain.xml")
      exit 0
      ;;
    *"vol-path --pool default vm-x86-redfish.qcow2")
      printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\n"
      ;;
    *)
      exit 2
      ;;
  esac
  '
    run ./scripts/create-vm
    [ "$status" -eq 0 ]
    [ "$(cat "$VM_X86_REDFISH_STATE_DIR/domain-uuid")" = \
      "11111111-2222-3333-4444-555555555555" ]
    run grep -F "vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2" \
      "$BATS_TEST_TMPDIR/commands.log"
    [ "$status" -eq 0 ]
  }

  @test "create-vm refuses existing domain without project metadata" {
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    *"dominfo vm-x86-redfish")
      exit 0
      ;;
    *"dumpxml vm-x86-redfish")
      printf "<domain><name>vm-x86-redfish</name></domain>\n"
      ;;
    *)
      exit 2
      ;;
  esac
  '
    run ./scripts/create-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"existing domain vm-x86-redfish is not owned by this project"* ]]
  }

  @test "create-vm accepts owned domain with alternate metadata prefix and escaped text" {
    printf '11111111-2222-3333-4444-555555555555\n' \
      >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    *"dominfo vm-x86-redfish")
      exit 0
      ;;
    *"dumpxml vm-x86-redfish")
      cat <<XML
  <domain xmlns:owned="https://github.com/randomparity/vm-x86-redfish">
    <uuid>11111111-2222-3333-4444-555555555555</uuid>
    <metadata>
      <owned:project>vm-x86-redfish</owned:project>
      <owned:root-volume>vm-x86-redfish&amp;owned.qcow2</owned:root-volume>
    </metadata>
    <devices>
      <disk type="file" device="disk">
        <source file="/var/lib/libvirt/images/vm-x86-redfish&amp;owned.qcow2"/>
      </disk>
    </devices>
  </domain>
  XML
      ;;
    *"vol-info --pool default vm-x86-redfish&owned.qcow2")
      exit 0
      ;;
    *"vol-path --pool default vm-x86-redfish&owned.qcow2")
      printf "/var/lib/libvirt/images/vm-x86-redfish&owned.qcow2\n"
      ;;
    *)
      exit 2
      ;;
  esac
  '
    VM_X86_REDFISH_ROOT_VOLUME_NAME="vm-x86-redfish&owned.qcow2" \
      run ./scripts/create-vm
    [ "$status" -eq 0 ]
  }

  @test "create-vm refuses owned existing domain when root volume is missing" {
    printf '11111111-2222-3333-4444-555555555555\n' \
      >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
    install_mock_command virsh '
  case "$*" in
    *"dominfo vm-x86-redfish")
      exit 0
      ;;
    *"dumpxml vm-x86-redfish")
      cat <<XML
  <domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
    <uuid>11111111-2222-3333-4444-555555555555</uuid>
    <metadata>
      <rp:project>vm-x86-redfish</rp:project>
      <rp:root-volume>vm-x86-redfish.qcow2</rp:root-volume>
    </metadata>
  </domain>
  XML
      ;;
    *"vol-info --pool default vm-x86-redfish.qcow2")
      exit 1
      ;;
    *)
      exit 2
      ;;
  esac
  '
    run ./scripts/create-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"root volume vm-x86-redfish.qcow2 is missing"* ]]
  }

  @test "create-vm refuses owned existing domain with wrong disk source" {
    printf '11111111-2222-3333-4444-555555555555\n' \
      >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
    install_mock_command virsh '
  case "$*" in
    *"dominfo vm-x86-redfish")
      exit 0
      ;;
    *"dumpxml vm-x86-redfish")
      cat <<XML
  <domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
    <uuid>11111111-2222-3333-4444-555555555555</uuid>
    <metadata>
      <rp:project>vm-x86-redfish</rp:project>
      <rp:root-volume>vm-x86-redfish.qcow2</rp:root-volume>
    </metadata>
    <devices>
      <disk type="file" device="disk">
        <source file="/var/lib/libvirt/images/other.qcow2"/>
      </disk>
    </devices>
  </domain>
  XML
      ;;
    *"vol-info --pool default vm-x86-redfish.qcow2")
      exit 0
      ;;
    *"vol-path --pool default vm-x86-redfish.qcow2")
      printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\n"
      ;;
    *)
      exit 2
      ;;
  esac
  '
    run ./scripts/create-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not use root volume path"* ]]
  }

  @test "create-vm deletes newly created disk when vol-path fails" {
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2")
      exit 1
      ;;
    *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2")
      exit 0
      ;;
    *"vol-path --pool default vm-x86-redfish.qcow2")
      exit 1
      ;;
    *"vol-delete --pool default vm-x86-redfish.qcow2")
      exit 0
      ;;
    *)
      exit 2
      ;;
  esac
  '
    run ./scripts/create-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to resolve root volume path"* ]]
    grep -F "vol-delete --pool default vm-x86-redfish.qcow2" \
      "$BATS_TEST_TMPDIR/commands.log"
  }

  @test "create-vm deletes newly created disk when domain rendering fails" {
    mkdir "$VM_X86_REDFISH_STATE_DIR/domain.xml"
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2")
      exit 1
      ;;
    *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2")
      exit 0
      ;;
    *"vol-path --pool default vm-x86-redfish.qcow2")
      printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\n"
      ;;
    *"vol-delete --pool default vm-x86-redfish.qcow2")
      exit 0
      ;;
    *)
      exit 2
      ;;
  esac
  '
    run ./scripts/create-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to render domain XML"* ]]
    grep -F "vol-delete --pool default vm-x86-redfish.qcow2" \
      "$BATS_TEST_TMPDIR/commands.log"
  }

  @test "create-vm deletes newly created disk when domain definition fails" {
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2")
      exit 1
      ;;
    *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2")
      exit 0
      ;;
    *"vol-path --pool default vm-x86-redfish.qcow2")
      printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\n"
      ;;
    *"define "*"/domain.xml")
      exit 1
      ;;
    *"vol-delete --pool default vm-x86-redfish.qcow2")
      exit 0
      ;;
    *)
      exit 2
      ;;
  esac
  '
    run ./scripts/create-vm
    [ "$status" -ne 0 ]
    run grep -F "vol-delete --pool default vm-x86-redfish.qcow2" \
      "$BATS_TEST_TMPDIR/commands.log"
    [ "$status" -eq 0 ]
  }

  @test "create-vm refuses existing root volume without a validated owned domain" {
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    *"dominfo vm-x86-redfish")
      exit 1
      ;;
    *"vol-info --pool default vm-x86-redfish.qcow2")
      exit 0
      ;;
    *)
      exit 2
      ;;
  esac
  '
    run ./scripts/create-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"existing root volume vm-x86-redfish.qcow2 is not adopted"* ]]
  }

  ```

- [ ] **Step 2: Run create tests and verify they fail**

  Run:

  ```bash
  bats tests/create-vm.bats
  ```

  Expected: FAIL because `scripts/create-vm` does not exist.

- [ ] **Step 3: Add ownership validation helpers**

  Extend `scripts/lib/common` with:

  ```bash
  xml_text_equals() {
    local xml="$1"
    local namespace="$2"
    local name="$3"
    local expected="$4"
    local python_bin
    python_bin="$(python_313)"
    "$python_bin" - "$xml" "$namespace" "$name" "$expected" <<'PY'
  import sys
  import xml.etree.ElementTree as ET

  xml_path, namespace, name, expected = sys.argv[1:]
  target = f"{{{namespace}}}{name}" if namespace else name
  root = ET.parse(xml_path).getroot()
  for elem in root.iter(target):
      if (elem.text or "") == expected:
          raise SystemExit(0)
  raise SystemExit(1)
  PY
  }

  xml_disk_source_equals() {
    local xml="$1"
    local expected="$2"
    local python_bin
    python_bin="$(python_313)"
    "$python_bin" - "$xml" "$expected" <<'PY'
  import sys
  import xml.etree.ElementTree as ET

  xml_path, expected = sys.argv[1:]
  root = ET.parse(xml_path).getroot()
  for disk in root.findall(".//disk"):
      if disk.get("device") != "disk":
          continue
      source = disk.find("source")
      if source is not None and source.get("file") == expected:
          raise SystemExit(0)
  raise SystemExit(1)
  PY
  }

  domain_is_project_owned() {
    local xml="$1"
    xml_text_equals "$xml" "https://github.com/randomparity/vm-x86-redfish" \
      "project" "vm-x86-redfish"
  }

  domain_uuid_matches_state() {
    local xml="$1"
    local uuid
    uuid="$(read_domain_uuid)"
    xml_text_equals "$xml" "" "uuid" "$uuid"
  }

  domain_root_volume_matches_state() {
    local xml="$1"
    xml_text_equals "$xml" "https://github.com/randomparity/vm-x86-redfish" \
      "root-volume" "$ROOT_VOLUME_NAME"
  }

  domain_disk_source_matches() {
    local xml="$1"
    local root_path="$2"
    xml_disk_source_equals "$xml" "$root_path"
  }

  ```

- [ ] **Step 4: Implement create-vm transaction**

  Create `scripts/create-vm` with functions:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  script_dir="${BASH_SOURCE[0]%/*}"
  source "${script_dir}/lib/common"

  create_domain_uuid_once() {
    ensure_private_dir "$STATE_DIR"
    if [ ! -f "$DOMAIN_UUID_FILE" ]; then
      write_secret_file "$DOMAIN_UUID_FILE" "$(uuidgen)"
    fi
  }

  validate_or_reject_existing_domain() {
    local xml_path="${STATE_DIR}/existing-domain.xml"
    local root_path
    if virsh -c "$LIBVIRT_URI" dominfo "$DEFAULT_DOMAIN_NAME" >/dev/null 2>&1; then
      virsh -c "$LIBVIRT_URI" dumpxml "$DEFAULT_DOMAIN_NAME" >"$xml_path"
      domain_is_project_owned "$xml_path" ||
        fail "existing domain $DEFAULT_DOMAIN_NAME is not owned by this project"
      domain_uuid_matches_state "$xml_path" ||
        fail "existing domain $DEFAULT_DOMAIN_NAME UUID does not match $DOMAIN_UUID_FILE"
      domain_root_volume_matches_state "$xml_path" ||
        fail "existing domain $DEFAULT_DOMAIN_NAME does not reference $ROOT_VOLUME_NAME"
      if ! virsh -c "$LIBVIRT_URI" vol-info --pool "$STORAGE_POOL" "$ROOT_VOLUME_NAME" \
        >/dev/null 2>&1; then
        fail "existing domain $DEFAULT_DOMAIN_NAME root volume $ROOT_VOLUME_NAME is missing"
      fi
      root_path="$(virsh -c "$LIBVIRT_URI" vol-path --pool "$STORAGE_POOL" "$ROOT_VOLUME_NAME")"
      domain_disk_source_matches "$xml_path" "$root_path" ||
        fail "existing domain $DEFAULT_DOMAIN_NAME does not use root volume path $root_path"
      return 0
    fi
    return 1
  }

  reject_root_volume_collision() {
    if virsh -c "$LIBVIRT_URI" vol-info --pool "$STORAGE_POOL" "$ROOT_VOLUME_NAME" \
      >/dev/null 2>&1; then
      fail "existing root volume $ROOT_VOLUME_NAME is not adopted without matching domain"
    fi
  }

  create_root_volume() {
    reject_root_volume_collision
    virsh -c "$LIBVIRT_URI" vol-create-as "$STORAGE_POOL" "$ROOT_VOLUME_NAME" 40G \
      --format qcow2
  }

  create_redfish_runtime_state() {
    :
  }

  rollback_new_root_volume() {
    virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$ROOT_VOLUME_NAME"
  }

  create_new_domain() {
    local root_path
    create_root_volume
    if ! root_path="$(virsh -c "$LIBVIRT_URI" vol-path --pool "$STORAGE_POOL" \
      "$ROOT_VOLUME_NAME")"; then
      rollback_new_root_volume
      fail "failed to resolve root volume path for $ROOT_VOLUME_NAME"
    fi
    if ! VM_X86_REDFISH_ROOT_VOLUME_PATH="$root_path" ./scripts/render-config domain; then
      rollback_new_root_volume
      fail "failed to render domain XML for $DEFAULT_DOMAIN_NAME"
    fi
    if ! virsh -c "$LIBVIRT_URI" define "${STATE_DIR}/domain.xml"; then
      rollback_new_root_volume
      fail "failed to define libvirt domain $DEFAULT_DOMAIN_NAME"
    fi
  }

  create_vm_transaction() {
    create_domain_uuid_once
    if ! validate_or_reject_existing_domain; then
      create_new_domain
    fi
    create_redfish_runtime_state
  }

  with_lifecycle_lock "$LIFECYCLE_LOCK" create_vm_transaction
  ```

- [ ] **Step 5: Add integration-test override guard tests**

  Extend `tests/create-vm.bats` to assert that `VM_X86_REDFISH_DOMAIN_NAME`,
  `VM_X86_REDFISH_ROOT_VOLUME_NAME`, and `VM_X86_REDFISH_STATE_DIR` are honored only when
  `VM_X86_REDFISH_INTEGRATION_TEST=1`. Without the guard, `scripts/create-vm` must fail with:

  ```text
  error: test-only overrides require VM_X86_REDFISH_INTEGRATION_TEST=1
  ```

  Add matching tests to `tests/destroy-vm.bats` in Task 8 and `tests/render-config.bats` in
  Task 7 so `scripts/destroy-vm` and `scripts/run-redfish` fail with the same message when
  any of these variables is set without the guard:

  ```text
  VM_X86_REDFISH_DOMAIN_NAME
  VM_X86_REDFISH_LIBVIRT_URI
  VM_X86_REDFISH_STORAGE_POOL
  VM_X86_REDFISH_ROOT_VOLUME_NAME
  VM_X86_REDFISH_STATE_DIR
  VM_X86_REDFISH_ARTIFACTS_DIR
  ```

  The implementation belongs in `scripts/lib/common` from Task 2, not in
  `scripts/create-vm`, so every entry point gets the same boundary by sourcing the
  library. Because `setup_test_workspace` sets `VM_X86_REDFISH_INTEGRATION_TEST=1` for
  ordinary tests, these guard tests must invoke the target through
  `env -u VM_X86_REDFISH_INTEGRATION_TEST`.

- [ ] **Step 6: Run create guardrails and commit**

  Run:

  ```bash
  chmod +x scripts/create-vm
  shfmt -i 2 -w scripts/create-vm scripts/lib/common tests/create-vm.bats
  shellcheck scripts/create-vm scripts/lib/common
  bats tests/create-vm.bats
  make test
  ```

  Expected: all commands exit 0. Commit:

  ```bash
  git add scripts/create-vm scripts/lib/common tests/create-vm.bats
  git commit -m "feat: create managed libvirt VM"
  ```

## Task 6: Credentials, TLS, Sushy Configuration, and Lifecycle Lock

**Files:**
- Create: `config/sushy-emulator.conf.py.in`
- Modify: `scripts/create-vm`
- Modify: `scripts/render-config`
- Modify: `scripts/lib/common`
- Modify: `tests/render-config.bats`
- Modify: `tests/create-vm.bats`

**Interfaces:**
- Produces `.state/credentials.env`, `.state/htpasswd`, `.state/tls.crt`,
  `.state/tls.key`, `.state/connection.env`, `.state/tmp/`, and
  `.state/sushy-emulator.conf.py`.
- Consumes Sushy config values from the spec, including allowed instance UUID and single
  `Cd` virtual media device.

- [ ] **Step 1: Write tests for secret-bearing file modes and connection metadata**

  Add tests asserting:

  ```bash
  install_redfish_state_mocks() {
    install_mock_command openssl '
  printf "openssl %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    "rand -base64 30")
      printf "redfish-test-password\n"
      ;;
    req*)
      key=""
      cert=""
      while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
          -keyout)
            key="$1"
            shift
            ;;
          -out)
            cert="$1"
            shift
            ;;
        esac
      done
      printf "test-key\n" >"$key"
      printf "test-cert\n" >"$cert"
      ;;
    *)
      exit 2
      ;;
  esac
  '
    install_mock_command htpasswd '
  printf "htpasswd %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  [ "$1" = "-iB" ]
  [ "$2" = "-c" ]
  read -r password
  [ "$password" = "redfish-test-password" ]
  printf "admin:test-hash\n" >"$3"
  '
  }

  install_create_success_mocks() {
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2")
      exit 1
      ;;
    *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2")
      exit 0
      ;;
    *"vol-path --pool default vm-x86-redfish.qcow2")
      printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\n"
      ;;
    *"define "*"/domain.xml")
      exit 0
      ;;
    *)
      exit 2
      ;;
  esac
  '
    install_redfish_state_mocks
  }

  @test "create-vm writes private Redfish credentials and connection metadata" {
    install_create_success_mocks
    run ./scripts/create-vm
    [ "$status" -eq 0 ]
    [ "$(stat -c "%a" "$VM_X86_REDFISH_STATE_DIR/credentials.env")" = "600" ]
    [ "$(stat -c "%a" "$VM_X86_REDFISH_STATE_DIR/htpasswd")" = "600" ]
    [ "$(stat -c "%a" "$VM_X86_REDFISH_STATE_DIR/tls.key")" = "600" ]
    grep -F "REDFISH_ENDPOINT='https://127.0.0.1:8000'" \
      "$VM_X86_REDFISH_STATE_DIR/connection.env"
    grep -F "REDFISH_CREDENTIALS_FILE='$VM_X86_REDFISH_STATE_DIR/credentials.env'" \
      "$VM_X86_REDFISH_STATE_DIR/connection.env"
    python_bin="$(UV_PYTHON_DOWNLOADS=never uv python find 3.13)"
    "$python_bin" - "$VM_X86_REDFISH_STATE_DIR/sushy-emulator.conf.py" <<'PY'
  import runpy
  import sys

  cfg = runpy.run_path(sys.argv[1])
  assert cfg["SUSHY_EMULATOR_VMEDIA_DEVICES"] == {
      "Cd": {
          "Name": "Virtual CD",
          "MediaTypes": ["CD", "DVD"],
          "Verify": True,
      }
  }
  assert cfg["SUSHY_EMULATOR_VMEDIA_VERIFY_SSL"] is True
  PY
    run grep -F "redfish-test-password" "$BATS_TEST_TMPDIR/commands.log"
    [ "$status" -ne 0 ]
  }

  @test "create-vm repairs missing Redfish state for valid existing domain" {
    printf '11111111-2222-3333-4444-555555555555\n' \
      >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
    install_redfish_state_mocks
    install_mock_command virsh '
  case "$*" in
    *"dominfo vm-x86-redfish")
      exit 0
      ;;
    *"dumpxml vm-x86-redfish")
      cat <<XML
  <domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
    <uuid>11111111-2222-3333-4444-555555555555</uuid>
    <metadata>
      <rp:project>vm-x86-redfish</rp:project>
      <rp:root-volume>vm-x86-redfish.qcow2</rp:root-volume>
    </metadata>
    <devices>
      <disk type="file" device="disk">
        <source file="/var/lib/libvirt/images/vm-x86-redfish.qcow2"/>
      </disk>
    </devices>
  </domain>
  XML
      ;;
    *"vol-info --pool default vm-x86-redfish.qcow2")
      exit 0
      ;;
    *"vol-path --pool default vm-x86-redfish.qcow2")
      printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\n"
      ;;
    *)
      exit 0
      ;;
  esac
  '
    run ./scripts/create-vm
    [ "$status" -eq 0 ]
    [ -f "$VM_X86_REDFISH_STATE_DIR/credentials.env" ]
    [ -f "$VM_X86_REDFISH_STATE_DIR/sushy-emulator.conf.py" ]
  }
  ```

- [ ] **Step 2: Run tests and verify they fail**

  Run:

  ```bash
  bats tests/create-vm.bats tests/render-config.bats
  ```

  Expected: FAIL because credentials and Sushy config rendering are not implemented.

- [ ] **Step 3: Add Sushy configuration template**

  Create `config/sushy-emulator.conf.py.in` with:

  ```python
  SUSHY_EMULATOR_LISTEN_IP = "127.0.0.1"
  SUSHY_EMULATOR_LISTEN_PORT = 8000
  SUSHY_EMULATOR_LIBVIRT_URI = "qemu:///system"
  SUSHY_EMULATOR_FEATURE_SET = "vmedia"
  SUSHY_EMULATOR_ALLOWED_INSTANCES = ["@DOMAIN_UUID@"]
  SUSHY_EMULATOR_VMEDIA_DEVICES = {
      "Cd": {
          "Name": "Virtual CD",
          "MediaTypes": ["CD", "DVD"],
          "Verify": True,
      }
  }
  SUSHY_EMULATOR_VMEDIA_VERIFY_SSL = True
  SUSHY_EMULATOR_STORAGE_POOL = "default"
  SUSHY_EMULATOR_STATE_DIR = "@STATE_DIR@/sushy"
  SUSHY_EMULATOR_SSL_CERT = "@STATE_DIR@/tls.crt"
  SUSHY_EMULATOR_SSL_KEY = "@STATE_DIR@/tls.key"
  SUSHY_EMULATOR_AUTH_FILE = "@STATE_DIR@/htpasswd"
  ```

  This matches the `sushy-tools==2.2.0` static virtual-media schema: device identifiers key
  `SUSHY_EMULATOR_VMEDIA_DEVICES`, and `SUSHY_EMULATOR_VMEDIA_VERIFY_SSL` is the global
  fallback when a device does not carry a `Verify` value.

- [ ] **Step 4: Replace the runtime-state hook with credentials and TLS generation**

  Replace Task 5's no-op `create_redfish_runtime_state` in `scripts/create-vm` with:

  ```bash
  create_redfish_runtime_state() {
    create_redfish_credentials_once
    create_tls_once
    write_connection_metadata
    ./scripts/render-config sushy
  }

  create_redfish_credentials_once() {
    local password
    if [ ! -f "${STATE_DIR}/credentials.env" ]; then
      password="$(openssl rand -base64 30)"
      write_secret_file "${STATE_DIR}/credentials.env" \
        "REDFISH_USERNAME='admin'
  REDFISH_PASSWORD='${password}'"
    fi
    # shellcheck disable=SC1091
    source "${STATE_DIR}/credentials.env"
    printf '%s\n' "$REDFISH_PASSWORD" |
      htpasswd -iB -c "${STATE_DIR}/htpasswd" "$REDFISH_USERNAME" >/dev/null
    chmod 600 "${STATE_DIR}/htpasswd"
  }

  create_tls_once() {
    if [ ! -f "${STATE_DIR}/tls.crt" ] || [ ! -f "${STATE_DIR}/tls.key" ]; then
      openssl req -x509 -newkey rsa:3072 -sha256 -days 365 -nodes \
        -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        -keyout "${STATE_DIR}/tls.key" \
        -out "${STATE_DIR}/tls.crt"
      chmod 600 "${STATE_DIR}/tls.key" "${STATE_DIR}/tls.crt"
    fi
  }

  write_connection_metadata() {
    write_secret_file "${STATE_DIR}/connection.env" \
      "REDFISH_ENDPOINT='https://127.0.0.1:8000'
  REDFISH_CA_CERT='${STATE_DIR}/tls.crt'
  REDFISH_CREDENTIALS_FILE='${STATE_DIR}/credentials.env'"
  }
  ```

- [ ] **Step 5: Render Sushy config and private tmp directory**

  Extend `scripts/render-config` with `sushy)` handling. It must read the domain UUID,
  ensure `.state/sushy` and `.state/tmp` are private directories, replace `@DOMAIN_UUID@`
  and `@STATE_DIR@`, and write `.state/sushy-emulator.conf.py`.

- [ ] **Step 6: Run config guardrails and commit**

  Run:

  ```bash
  shfmt -i 2 -w scripts/create-vm scripts/render-config scripts/lib/common \
    tests/create-vm.bats tests/render-config.bats
  shellcheck scripts/create-vm scripts/render-config scripts/lib/common
  python_bin="$(UV_PYTHON_DOWNLOADS=never uv python find 3.13)"
  "$python_bin" -m py_compile config/sushy-emulator.conf.py.in
  bats tests/create-vm.bats tests/render-config.bats
  make test
  ```

  Expected: all commands exit 0. Commit:

  ```bash
  git add config/sushy-emulator.conf.py.in scripts tests
  git commit -m "feat: generate Redfish service state"
  ```

## Task 7: Foreground Redfish Service Wrapper

**Files:**
- Create: `scripts/run-redfish`
- Modify: `tests/render-config.bats`

**Interfaces:**
- Consumes `.state/sushy-emulator.conf.py`, `.state/tmp`, and lifecycle lock.
- Produces a foreground Sushy Emulator process with `TMPDIR` set to canonical `.state/tmp`.

- [ ] **Step 1: Write run-redfish lock and exec tests**

  Add tests asserting:

  ```bash
  @test "run-redfish refuses when lifecycle lock is held" {
    mkdir -p "$VM_X86_REDFISH_STATE_DIR"
    exec 8>"$VM_X86_REDFISH_STATE_DIR/lifecycle.lock"
    flock -n 8
    run ./scripts/run-redfish
    [ "$status" -ne 0 ]
    [[ "$output" == *"lifecycle lock is held"* ]]
  }

  @test "run-redfish rejects missing private tmp directory" {
    touch "$VM_X86_REDFISH_STATE_DIR/sushy-emulator.conf.py"
    run ./scripts/run-redfish
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing private directory"* ]]
  }

  @test "run-redfish rejects loose private tmp directory" {
    mkdir -p "$VM_X86_REDFISH_STATE_DIR/tmp"
    chmod 755 "$VM_X86_REDFISH_STATE_DIR/tmp"
    touch "$VM_X86_REDFISH_STATE_DIR/sushy-emulator.conf.py"
    run ./scripts/run-redfish
    [ "$status" -ne 0 ]
    [[ "$output" == *"directory must be mode 0700"* ]]
  }

  @test "run-redfish sets TMPDIR and execs sushy-emulator" {
    mkdir -p "$VM_X86_REDFISH_STATE_DIR/tmp"
    touch "$VM_X86_REDFISH_STATE_DIR/sushy-emulator.conf.py"
    chmod 700 "$VM_X86_REDFISH_STATE_DIR" "$VM_X86_REDFISH_STATE_DIR/tmp"
    install_mock_command uv 'printf "TMPDIR=%s\nCONFIG=%s\n" "$TMPDIR" "$*"'
    run ./scripts/run-redfish
    [ "$status" -eq 0 ]
    [[ "$output" == *"TMPDIR=$VM_X86_REDFISH_STATE_DIR/tmp"* ]]
    [[ "$output" == *"run sushy-emulator --config "*"/sushy-emulator.conf.py"* ]]
  }
  ```

- [ ] **Step 2: Run tests and verify they fail**

  Run:

  ```bash
  bats tests/render-config.bats
  ```

  Expected: FAIL because `scripts/run-redfish` is missing.

- [ ] **Step 3: Implement run-redfish**

  Create `scripts/run-redfish` with:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  script_dir="${BASH_SOURCE[0]%/*}"
  source "${script_dir}/lib/common"

  run_redfish() {
    local tmpdir
    [ -f "${STATE_DIR}/sushy-emulator.conf.py" ] ||
      fail "missing ${STATE_DIR}/sushy-emulator.conf.py: run make create first"
    require_private_dir "${STATE_DIR}/tmp"
    tmpdir="$(canonical_dir "${STATE_DIR}/tmp")"
    export TMPDIR="$tmpdir"
    exec uv run --locked sushy-emulator --config "${STATE_DIR}/sushy-emulator.conf.py"
  }

  with_lifecycle_lock "$LIFECYCLE_LOCK" run_redfish
  ```

- [ ] **Step 4: Run service wrapper guardrails and commit**

  Run:

  ```bash
  chmod +x scripts/run-redfish
  shfmt -i 2 -w scripts/run-redfish tests/render-config.bats
  shellcheck scripts/run-redfish
  bats tests/render-config.bats
  make test
  ```

  Expected: all commands exit 0. Commit:

  ```bash
  git add scripts/run-redfish tests/render-config.bats
  git commit -m "feat: run Redfish service"
  ```

## Task 8: Owner-Gated Destruction and Media Cleanup

**Files:**
- Create: `scripts/destroy-vm`
- Create: `tests/destroy-vm.bats`
- Modify: `scripts/lib/common`
- Modify: `README.md`

**Interfaces:**
- Consumes project metadata, recorded UUID, root volume name, and lifecycle lock.
- Removes only matching project-owned domain, NVRAM, root volume, UUID-scoped media volumes,
  and validated `.state/tmp` temporary files.

- [ ] **Step 1: Write destruction safety tests**

  Create `tests/destroy-vm.bats` with:

  ```bash
  #!/usr/bin/env bats

  load "helpers/test-helper"

  setup() {
    setup_test_workspace
  }

  @test "destroy-vm is a no-op before create" {
    run ./scripts/destroy-vm
    [ "$status" -eq 0 ]
    [[ "$output" == *"destroy: no project state found"* ]]
  }

  @test "destroy-vm is a no-op after prior cleanup removed state" {
    [ ! -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
    run ./scripts/destroy-vm
    [ "$status" -eq 0 ]
    [[ "$output" == *"destroy: no project state found"* ]]
  }

  @test "destroy-vm refuses domain with mismatched ownership" {
    printf '11111111-2222-3333-4444-555555555555\n' \
      >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    *"dumpxml vm-x86-redfish")
      printf "<domain><name>vm-x86-redfish</name></domain>\n"
      ;;
    *)
      exit 0
      ;;
  esac
  '
    run ./scripts/destroy-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to destroy unowned domain vm-x86-redfish"* ]]
  }

  @test "destroy-vm deletes only root and anchored uuid media volumes" {
    printf '11111111-2222-3333-4444-555555555555\n' \
      >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    *"dumpxml vm-x86-redfish")
      cat <<XML
  <domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
    <uuid>11111111-2222-3333-4444-555555555555</uuid>
    <metadata>
      <rp:project>vm-x86-redfish</rp:project>
      <rp:root-volume>vm-x86-redfish.qcow2</rp:root-volume>
    </metadata>
  </domain>
  XML
      ;;
    *"domstate vm-x86-redfish")
      printf "shut off\n"
      ;;
    *"vol-info --pool default vm-x86-redfish.qcow2")
      exit 0
      ;;
    *"vol-list --pool default --name")
      printf "vm-x86-redfish.qcow2\n"
      printf "fedora-iso-11111111-2222-3333-4444-555555555555.img\n"
      printf "unrelated-22222222-2222-3333-4444-555555555555.img\n"
      ;;
    *)
      exit 0
      ;;
  esac
  '
    run ./scripts/destroy-vm
    [ "$status" -eq 0 ]
    grep -F "vol-delete --pool default vm-x86-redfish.qcow2" "$BATS_TEST_TMPDIR/commands.log"
    grep -F "vol-delete --pool default fedora-iso-11111111-2222-3333-4444-555555555555.img" \
      "$BATS_TEST_TMPDIR/commands.log"
    run grep -F "unrelated-22222222" "$BATS_TEST_TMPDIR/commands.log"
    [ "$status" -ne 0 ]
    [ ! -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
  }

  @test "destroy-vm refuses root volume metadata mismatch" {
    printf '11111111-2222-3333-4444-555555555555\n' \
      >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
    install_mock_command virsh '
  case "$*" in
    *"dumpxml vm-x86-redfish")
      cat <<XML
  <domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
    <uuid>11111111-2222-3333-4444-555555555555</uuid>
    <metadata>
      <rp:project>vm-x86-redfish</rp:project>
      <rp:root-volume>different.qcow2</rp:root-volume>
    </metadata>
  </domain>
  XML
      ;;
    *)
      exit 0
      ;;
  esac
  '
    run ./scripts/destroy-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not reference vm-x86-redfish.qcow2"* ]]
  }

  @test "destroy-vm removes uuid media volumes when domain and root are absent" {
    printf '11111111-2222-3333-4444-555555555555\n' \
      >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
    mkdir -p "$VM_X86_REDFISH_STATE_DIR/tmp"
    chmod 700 "$VM_X86_REDFISH_STATE_DIR/tmp"
    touch "$VM_X86_REDFISH_STATE_DIR/tmp/interrupted-download"
    install_mock_command virsh '
  printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
  case "$*" in
    *"dumpxml vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2")
      exit 1
      ;;
    *"vol-list --pool default --name")
      printf "partial-11111111-2222-3333-4444-555555555555.img\n"
      ;;
    *)
      exit 0
      ;;
  esac
  '
    run ./scripts/destroy-vm
    [ "$status" -eq 0 ]
    grep -F "vol-delete --pool default partial-11111111-2222-3333-4444-555555555555.img" \
      "$BATS_TEST_TMPDIR/commands.log"
    [ ! -e "$VM_X86_REDFISH_STATE_DIR/tmp" ]
    [ ! -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
  }

  @test "destroy-vm preserves state when media volume listing fails" {
    printf '11111111-2222-3333-4444-555555555555\n' \
      >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
    mkdir -p "$VM_X86_REDFISH_STATE_DIR/tmp"
    chmod 700 "$VM_X86_REDFISH_STATE_DIR/tmp"
    touch "$VM_X86_REDFISH_STATE_DIR/tmp/interrupted-download"
    install_mock_command virsh '
  case "$*" in
    *"dumpxml vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2")
      exit 1
      ;;
    *"vol-list --pool default --name")
      exit 1
      ;;
    *)
      exit 0
      ;;
  esac
  '
    run ./scripts/destroy-vm
    [ "$status" -ne 0 ]
    [[ "$output" == *"failed to list volumes in libvirt pool default"* ]]
    [ -e "$VM_X86_REDFISH_STATE_DIR/tmp/interrupted-download" ]
    [ -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
  }
  ```

- [ ] **Step 2: Run destruction tests and verify they fail**

  Run:

  ```bash
  bats tests/destroy-vm.bats
  ```

  Expected: FAIL because `scripts/destroy-vm` is missing.

- [ ] **Step 3: Implement owner-gated destruction**

  Create `scripts/destroy-vm` with functions:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail

  script_dir="${BASH_SOURCE[0]%/*}"
  source "${script_dir}/lib/common"

  media_volume_matches_uuid() {
    local name="$1"
    local uuid="$2"
    [[ "$name" =~ ^[^/]+-"$uuid"\\.img$ ]]
  }

  cleanup_project_state_files() {
    local file
    for file in domain.xml destroy-domain.xml existing-domain.xml domain-uuid \
      credentials.env htpasswd tls.crt tls.key connection.env sushy-emulator.conf.py; do
      [ -e "${STATE_DIR}/${file}" ] && rm -- "${STATE_DIR}/${file}"
    done
  }

  delete_uuid_media_volumes() {
    local uuid="$1"
    local volume
    local volumes
    if ! volumes="$(virsh -c "$LIBVIRT_URI" vol-list --pool "$STORAGE_POOL" --name)"; then
      fail "failed to list volumes in libvirt pool $STORAGE_POOL"
    fi
    while IFS= read -r volume; do
      [ -n "$volume" ] || continue
      if media_volume_matches_uuid "$volume" "$uuid"; then
        virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$volume"
      fi
    done <<<"$volumes"
  }

  destroy_transaction() {
    local uuid xml_path
    if [ ! -f "$DOMAIN_UUID_FILE" ]; then
      printf 'destroy: no project state found\n'
      return 0
    fi
    uuid="$(read_domain_uuid)"
    xml_path="${STATE_DIR}/destroy-domain.xml"
    if ! virsh -c "$LIBVIRT_URI" dumpxml "$DEFAULT_DOMAIN_NAME" >"$xml_path"; then
      if virsh -c "$LIBVIRT_URI" vol-info --pool "$STORAGE_POOL" "$ROOT_VOLUME_NAME" \
        >/dev/null 2>&1; then
        fail "cannot prove ownership of $ROOT_VOLUME_NAME without domain metadata"
      fi
      delete_uuid_media_volumes "$uuid"
      printf 'destroy: domain %s is already absent\n' "$DEFAULT_DOMAIN_NAME"
      cleanup_project_state_files
      return 0
    fi
    domain_is_project_owned "$xml_path" ||
      fail "refusing to destroy unowned domain $DEFAULT_DOMAIN_NAME"
    domain_uuid_matches_state "$xml_path" ||
      fail "refusing to destroy $DEFAULT_DOMAIN_NAME with mismatched UUID"
    domain_root_volume_matches_state "$xml_path" ||
      fail "existing domain $DEFAULT_DOMAIN_NAME does not reference $ROOT_VOLUME_NAME"

    if virsh -c "$LIBVIRT_URI" domstate "$DEFAULT_DOMAIN_NAME" | grep -F running >/dev/null; then
      virsh -c "$LIBVIRT_URI" destroy "$DEFAULT_DOMAIN_NAME"
    fi
    virsh -c "$LIBVIRT_URI" undefine "$DEFAULT_DOMAIN_NAME" --nvram
    if virsh -c "$LIBVIRT_URI" vol-info --pool "$STORAGE_POOL" "$ROOT_VOLUME_NAME" \
      >/dev/null 2>&1; then
      virsh -c "$LIBVIRT_URI" vol-delete --pool "$STORAGE_POOL" "$ROOT_VOLUME_NAME"
    fi
    delete_uuid_media_volumes "$uuid"
    cleanup_project_state_files
  }

  with_lifecycle_lock "$LIFECYCLE_LOCK" destroy_transaction
  ```

- [ ] **Step 4: Add checked `.state/tmp` cleanup**

  Extend destruction to validate `.state/tmp` with `require_private_dir`, remove every
  regular file directly under that project-owned private directory, fail on unexpected
  non-file entries, then remove the directory only if empty. This intentionally does not
  rely on Sushy temporary filenames containing the domain UUID, because the integration
  test observes and records the actual interrupted-download path before destruction:

  ```bash
  cleanup_tmpdir() {
    local entry tmpdir
    [ -e "${STATE_DIR}/tmp" ] || return 0
    require_private_dir "${STATE_DIR}/tmp"
    tmpdir="$(canonical_dir "${STATE_DIR}/tmp")"
    while IFS= read -r -d '' entry; do
      if [ -f "$entry" ]; then
        rm -- "$entry"
      else
        fail "unexpected entry in temporary directory: $entry"
      fi
    done < <(find "$tmpdir" -mindepth 1 -maxdepth 1 -print0)
    if ! rmdir "$tmpdir" 2>/dev/null; then
      [ -d "$tmpdir" ] || fail "temporary directory disappeared during cleanup: $tmpdir"
    fi
  }
  ```

  Update every successful cleanup branch in `destroy_transaction` so temporary media is
  removed before state files. The domain-absent branch becomes:

  ```bash
      delete_uuid_media_volumes "$uuid"
      cleanup_tmpdir
      printf 'destroy: domain %s is already absent\n' "$DEFAULT_DOMAIN_NAME"
      cleanup_project_state_files
      return 0
  ```

  The normal tail becomes:

  ```bash
    cleanup_tmpdir
    cleanup_project_state_files
  ```

- [ ] **Step 5: Run destruction guardrails and commit**

  Run:

  ```bash
  chmod +x scripts/destroy-vm
  shfmt -i 2 -w scripts/destroy-vm scripts/lib/common tests/destroy-vm.bats
  shellcheck scripts/destroy-vm scripts/lib/common
  bats tests/destroy-vm.bats
  make test
  ```

  Expected: all commands exit 0. Commit:

  ```bash
  git add scripts/destroy-vm scripts/lib/common tests/destroy-vm.bats README.md
  git commit -m "feat: destroy managed libvirt VM"
  ```

## Task 9: Redfish Power-Control Integration Proof

**Files:**
- Create: `tests/redfish-integration.bats`
- Modify: `scripts/create-vm`
- Modify: `scripts/destroy-vm`
- Modify: `README.md`

**Interfaces:**
- Consumes integration-test overrides guarded by `VM_X86_REDFISH_INTEGRATION_TEST=1`.
- Produces isolated test domain, disk, UUID, state directory, and bounded child-process
  cleanup for Sushy and Redfish clients.

- [ ] **Step 1: Write the integration harness skeleton**

  Create `tests/redfish-integration.bats` with:

  ```bash
  #!/usr/bin/env bats

  load "helpers/test-helper"

  setup() {
    setup_test_workspace
    export TEST_ID="redfish-${BATS_TEST_NUMBER}-$$"
    export VM_X86_REDFISH_INTEGRATION_TEST=1
    export VM_X86_REDFISH_DOMAIN_NAME="vm-x86-redfish-${TEST_ID}"
    export VM_X86_REDFISH_ROOT_VOLUME_NAME="vm-x86-redfish-${TEST_ID}.qcow2"
    export VM_X86_REDFISH_ARTIFACTS_DIR=".artifacts/${TEST_ID}"
    mkdir -p "$VM_X86_REDFISH_ARTIFACTS_DIR"
    TRACKED_CHILDREN=()
  }

  teardown() {
    stop_tracked_children
    cleanup_log="$VM_X86_REDFISH_ARTIFACTS_DIR/destroy.log"
    cleanup_status=0
    ./scripts/destroy-vm >"$cleanup_log" 2>&1 || cleanup_status="$?"
    if [ "$cleanup_status" -ne 0 ]; then
      if ! virsh -c "$LIBVIRT_URI" dumpxml "$VM_X86_REDFISH_DOMAIN_NAME" \
        >"$VM_X86_REDFISH_ARTIFACTS_DIR/domain.xml" 2>&1; then
        printf 'domain XML unavailable after cleanup failure\n' \
          >>"$VM_X86_REDFISH_ARTIFACTS_DIR/domain.xml"
      fi
      printf 'destroy-vm cleanup failed with status %s; see %s\n' \
        "$cleanup_status" "$cleanup_log" >&2
      return "$cleanup_status"
    fi
  }

  @test "Redfish discovery is public and Systems requires credentials" {
    ./scripts/create-vm
    ./scripts/run-redfish >"$BATS_TEST_TMPDIR/sushy.log" 2>&1 &
    sushy_pid="$!"
    track_child "$sushy_pid"
    wait_for_url "https://127.0.0.1:8000/redfish/v1"
    run curl --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
      https://127.0.0.1:8000/redfish/v1
    [ "$status" -eq 0 ]
    run curl --silent --output /dev/null --write-out "%{http_code}" \
      --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
      https://127.0.0.1:8000/redfish/v1/Systems
    [ "$status" -eq 0 ]
    [ "$output" = "401" ]
    stop_tracked_children
  }
  ```

- [ ] **Step 2: Run integration test and verify it fails until host prerequisites pass**

  Run:

  ```bash
  make doctor
  make test-integration
  ```

  Expected before implementation: `make doctor` either reports missing Fedora 44 host
  prerequisites or exits 0; `make test-integration` fails because polling helpers and
  authenticated Redfish operations are incomplete.

- [ ] **Step 3: Implement bounded process helpers**

  Add to `tests/helpers/test-helper.bash`:

  ```bash
  wait_for_url() {
    local url="$1"
    local deadline=$((SECONDS + 30))
    until curl --silent --fail --insecure "$url" >/dev/null; do
      [ "$SECONDS" -lt "$deadline" ] || return 1
      sleep 1
    done
  }

  track_child() {
    TRACKED_CHILDREN+=("$1")
  }

  stop_tracked_children() {
    local pid
    for pid in "${TRACKED_CHILDREN[@]:-}"; do
      stop_child "$pid"
    done
    TRACKED_CHILDREN=()
  }

  stop_child() {
    local pid="$1"
    if ! kill "$pid" 2>/dev/null; then
      return 0
    fi
    local deadline=$((SECONDS + 10))
    while kill -0 "$pid" 2>/dev/null; do
      [ "$SECONDS" -lt "$deadline" ] || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid"
    fi
    if wait "$pid" 2>/dev/null; then
      return 0
    fi
    return 0
  }
  ```

  Add a harness regression test that proves cleanup order. Start a long-running mock command,
  `track_child` its PID, hold a mock lifecycle lock, call `stop_tracked_children`, and assert
  the process is gone before invoking `scripts/destroy-vm`. This test lives in
  `tests/redfish-integration.bats` and runs only under `make test-integration`.

- [ ] **Step 4: Add authenticated Systems and power reset checks**

  Extend the test to source `$VM_X86_REDFISH_STATE_DIR/credentials.env`, query
  `/redfish/v1/Systems`, use the returned UUID URL, and POST reset actions:

  ```bash
  curl --fail --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d '{"ResetType":"On"}' \
    "https://127.0.0.1:8000/redfish/v1/Systems/${domain_uuid}/Actions/ComputerSystem.Reset"
  ```

  Verify `On`, `ForceRestart`, and `ForceOff` by polling `virsh domstate` for the expected
  state after each operation.

- [ ] **Step 5: Run integration checkpoint and commit**

  Run on a Fedora 44 x86_64 host with libvirt access:

  ```bash
  make doctor
  make test
  make test-integration
  ```

  Expected: all commands exit 0. Commit:

  ```bash
  git add tests/redfish-integration.bats tests/helpers/test-helper.bash scripts README.md
  git commit -m "test: verify Redfish power control"
  ```

## Task 10: UEFI Serial Sentinel, Boot Overrides, and Virtual Media

**Files:**
- Create: `tests/fixtures/grub.cfg.in`
- Modify: `tests/redfish-integration.bats`
- Modify: `scripts/destroy-vm`
- Modify: `README.md`

**Interfaces:**
- Consumes Sushy virtual media device `Cd`, libvirt COM1 `serial0`, and integration harness
  child PID tracking.
- Produces the first implementation checkpoint proof required by the spec.

- [ ] **Step 1: Add the GRUB serial sentinel fixture**

  Create `tests/fixtures/grub.cfg.in` with:

  ```cfg
  serial --unit=0 --speed=115200
  terminal_output serial
  set timeout=10

  menuentry 'vm-x86-redfish sentinel' {
    echo '@SENTINEL@'
    halt
  }
  ```

- [ ] **Step 2: Add ISO build and loopback media-server helpers**

  Extend `tests/redfish-integration.bats` with helpers that render the sentinel, run
  `grub2-mkrescue -o "$iso_path" "$iso_root"`, resolve `python_bin="$(python_313)"`,
  start `"$python_bin" -m http.server 0 --bind 127.0.0.1`, start a separate local HTTPS
  media server with a self-signed certificate, and record the exact media-server PIDs for
  teardown.

- [ ] **Step 3: Insert media and select Cd boot override**

  First POST an untrusted local HTTPS image URL and assert Sushy rejects it, proving
  `SUSHY_EMULATOR_VMEDIA_VERIFY_SSL = True` is active for downloads. Then POST the HTTP
  sentinel ISO URL for the positive boot path:

  ```json
  {"Image":"http://127.0.0.1:${media_port}/${iso_name}","Inserted":true}
  ```

  to:

  ```text
  /redfish/v1/Systems/${domain_uuid}/VirtualMedia/Cd/Actions/VirtualMedia.InsertMedia
  ```

  PATCH the system boot override to:

  ```json
  {"Boot":{"BootSourceOverrideTarget":"Cd","BootSourceOverrideEnabled":"Once"}}
  ```

  Assert inactive domain XML contains the CD device and that its first boot device is CD.

- [ ] **Step 4: Boot and prove serial sentinel output**

  Power on through Redfish, poll until `virsh domstate` reports `running`, then run:

  ```bash
  timeout 60 virsh -c "$LIBVIRT_URI" console "$VM_X86_REDFISH_DOMAIN_NAME" \
    --devname serial0 --force
  ```

  Capture output to `.artifacts/${TEST_ID}/serial.log` on failure. The test passes only
  when the exact rendered sentinel appears in the captured output.

- [ ] **Step 5: Eject media and exercise Hdd/Pxe boot overrides**

  Force off the VM, POST EjectMedia for `Cd`, assert the CD device is absent from inactive
  XML, then PATCH `Hdd` and `Pxe` boot overrides and verify inactive XML boot order for each.

- [ ] **Step 6: Simulate interrupted insertion cleanup**

  Start a throttled HTTP response, begin an InsertMedia request asynchronously, record the
  client PID, wait for a file to appear beneath the test `TMPDIR`, terminate only the Sushy
  child, record the observed temporary file path, wait boundedly for the client, run
  `scripts/destroy-vm`, and prove the observed temporary file plus every anchored
  `-${domain_uuid}.img` volume is absent.

- [ ] **Step 7: Stop if the serial-sentinel checkpoint fails**

  If `make test-integration` cannot prove the sentinel with Sushy 2.2.0, system libvirt
  pool upload, Fedora 44 q35/UEFI, and enforcing SELinux, stop implementation. Do not add a
  second backend. Revise `docs/specs/redfish-vm.md` to select either session libvirt or a
  dedicated service identity before continuing.

- [ ] **Step 8: Run integration checkpoint and commit**

  Run:

  ```bash
  make doctor
  make test
  make test-integration
  ```

  Expected: all commands exit 0 on the target host. Commit:

  ```bash
  git add tests/redfish-integration.bats tests/fixtures/grub.cfg.in scripts README.md
  git commit -m "test: prove virtual media boot"
  ```

## Task 11: Final Documentation and Operator Workflow

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/specs/redfish-vm.md`

**Interfaces:**
- Consumes behavior verified by Tasks 1-10.
- Produces user-facing setup, operation, troubleshooting, and limitation docs that describe
  only implemented commands.

- [ ] **Step 1: Write README verification examples**

  Document the exact operator workflow:

  ```bash
  make doctor
  make create
  source .state/connection.env
  source "$REDFISH_CREDENTIALS_FILE"
  make redfish
  ```

  Document Redfish requests from a second terminal while `make redfish` remains in the
  foreground:

  ```bash
  source .state/connection.env
  source "$REDFISH_CREDENTIALS_FILE"
  curl --cacert "$REDFISH_CA_CERT" \
    --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
    "$REDFISH_ENDPOINT/redfish/v1/Systems"
  ```

  Document cleanup only after the operator stops the foreground service and waits for it to
  exit:

  ```bash
  # Press Ctrl-C in the terminal running make redfish, then run:
  make destroy
  ```

  Include the lock behavior:

  ```markdown
  `make destroy` refuses while `make redfish` holds the lifecycle lock. Stop the foreground
  Redfish process before destroying project-owned VM resources.
  ```

- [ ] **Step 2: Document limitations and security boundaries**

  Include:

  ```markdown
  The Redfish service listens only on `127.0.0.1:8000`. Treat virtual-media URLs as trusted
  local test inputs because authenticated users can cause the service to fetch them.
  Discovery at `/redfish/v1` is intentionally unauthenticated; system resources and mutation
  actions require Basic authentication.
  ```

- [ ] **Step 3: Reconcile spec with proven implementation**

  Re-read `docs/specs/redfish-vm.md` against the final diff. If integration proved a changed
  libvirt setting, Sushy setting name, or host requirement, update the spec in the same commit
  with the verified value and no unimplemented claims.

- [ ] **Step 4: Run final guardrails and commit**

  Run:

  ```bash
  make doctor
  make test
  make test-integration
  git diff --check
  ```

  Expected: all commands exit 0 on the target host. Commit:

  ```bash
  git add README.md AGENTS.md docs/specs/redfish-vm.md
  git commit -m "docs: document Redfish VM workflow"
  ```

## Self-Review

- Spec coverage: Tasks 1-2 establish the command surface, generated-state exclusions, and
  shared lifecycle controls. Tasks 3-8 cover host checks, VM definition, ownership,
  credentials, TLS, Sushy configuration, locking, and safe cleanup. Tasks 9-10 cover the
  opt-in live Redfish proof, power actions, serial sentinel, boot overrides, virtual media,
  and interrupted-insertion cleanup. Task 11 covers README and spec reconciliation.
- Replacement-token scan: The plan uses concrete CI SHAs and dependency pins looked up on
  2026-07-31. It also tells implementers to re-run the lookup commands immediately before
  committing dependency or CI changes, which satisfies the repo rule for current versions.
- Type and interface consistency: Shared shell functions are named once in Task 2 and reused
  by later tasks. Public command names match the Make targets and accepted spec.
- Tracking status: GitHub issue #1 exists, carries `status:in-progress`, and has a complete
  `WORK:SCOPE` annotation for this branch.
