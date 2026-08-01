#!/usr/bin/env bash
# shellcheck disable=SC2154 # Bats provides BATS_TEST_* variables.

install_mock_command() {
  local name="$1"
  local body="$2"
  local bash_bin
  bash_bin="$BASH"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  ln -sf "$bash_bin" "$BATS_TEST_TMPDIR/bin/bash"
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
  # shellcheck disable=SC2016 # The mock expands these variables when it runs.
  install_mock_command "$name" \
    'printf "%s %s\n" "$(basename "$0")" "$*" >>"$BATS_TEST_TMPDIR/commands.log"'
}

install_uv_python_mock() {
  local python_bin
  python_bin="$(command -v python3)"
  install_mock_command uv "
case \"\$*\" in
  \"python find 3.13\") printf '%s\\n' '$python_bin' ;;
  *) exit 2 ;;
esac
"
}

setup_test_workspace() {
  export REPO_ROOT
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cd "$REPO_ROOT" || return
  export VM_X86_REDFISH_INTEGRATION_TEST=1
  export VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export VM_X86_REDFISH_ARTIFACTS_DIR="$BATS_TEST_TMPDIR/artifacts"
  mkdir -p "$VM_X86_REDFISH_STATE_DIR" "$VM_X86_REDFISH_ARTIFACTS_DIR"
  install_uv_python_mock
}

setup_integration_workspace() {
  export REPO_ROOT
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cd "$REPO_ROOT" || return
  export VM_X86_REDFISH_INTEGRATION_TEST=1
  export VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export VM_X86_REDFISH_ARTIFACTS_DIR="$BATS_TEST_TMPDIR/artifacts"
  mkdir -p "$VM_X86_REDFISH_STATE_DIR" "$VM_X86_REDFISH_ARTIFACTS_DIR"
}

build_nmi_initramfs() {
  local init_binary="$1"
  local archive_path="$2"
  local staging_root="$3"
  (
    umask 022
    mkdir -p "$staging_root/dev" "$staging_root/proc"
    cp "$init_binary" "$staging_root/init"
    chmod 0755 "$staging_root" "$staging_root/dev" "$staging_root/proc"
    chmod 0755 "$staging_root/init"
    touch -d '@0' "$staging_root" "$staging_root/dev" \
      "$staging_root/proc" "$staging_root/init"
    cd "$staging_root" || exit 1
    printf '%s\0' dev init proc |
      cpio --null --create --format=newc --owner=0:0 --reproducible
  ) >"$archive_path"
}

bounded_curl() {
  curl --connect-timeout 5 --max-time 15 "$@"
}

bounded_virsh() {
  timeout --kill-after=2 10 virsh -c "$LIBVIRT_URI" "$@"
}

wait_for_url() {
  local url="$1"
  local deadline=$((SECONDS + 30))
  until bounded_curl --silent --fail --insecure "$url" >/dev/null; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

wait_for_file() {
  local path="$1"
  local deadline=$((SECONDS + 30))
  until [ -f "$path" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

track_child() {
  TRACKED_CHILDREN+=("$1")
}

untrack_child() {
  local target_pid="$1"
  local pid
  local remaining=()
  for pid in "${TRACKED_CHILDREN[@]:-}"; do
    [ "$pid" = "$target_pid" ] || remaining+=("$pid")
  done
  TRACKED_CHILDREN=("${remaining[@]}")
}

stop_tracked_child() {
  local pid="$1"
  stop_child "$pid"
  untrack_child "$pid"
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

setup() {
  setup_test_workspace
}
