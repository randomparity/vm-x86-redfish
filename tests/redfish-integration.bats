#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Bats isolates PATH changes to each test process.
# shellcheck disable=SC2329 # Bats invokes test helpers indirectly and tests override retry hooks.

load "helpers/test-helper"

setup_file() {
  local preflight_host_ip
  if [ "${VM_X86_REDFISH_INTEGRATION_HELPER_ONLY:-}" = "1" ]; then
    return 0
  fi
  require_remote_integration_prerequisites || return
  export VM_X86_REDFISH_INTEGRATION_TEST=1
  # shellcheck disable=SC1091 # Integration preflight runs from the repository root.
  source ./scripts/lib/common
  if preflight_host_ip="$(select_routable_host_ip)"; then
    :
  else
    printf 'integration prerequisite: no bindable non-loopback IPv4 route source is available\n' \
      >&2
    return 1
  fi
  smoke_test_remote_namespace "$preflight_host_ip" || return
  ./scripts/doctor
}

setup() {
  setup_integration_workspace
  export TEST_ID="redfish-${BATS_TEST_NUMBER}-$$"
  export VM_X86_REDFISH_INTEGRATION_TEST=1
  export VM_X86_REDFISH_DOMAIN_NAME="vm-x86-redfish-${TEST_ID}"
  export VM_X86_REDFISH_ROOT_VOLUME_NAME="vm-x86-redfish-${TEST_ID}.qcow2"
  export VM_X86_REDFISH_ARTIFACTS_DIR=".artifacts/${TEST_ID}"
  export VM_X86_REDFISH_SOURCE_IMAGE="$BATS_TEST_TMPDIR/source.qcow2"
  export VM_X86_REDFISH_MEMORY_MIB=4096
  export VM_X86_REDFISH_ROOT_DISK_GIB=1
  qemu-img create -f qcow2 "$VM_X86_REDFISH_SOURCE_IMAGE" 64M >/dev/null
  # shellcheck disable=SC1091 # Integration setup runs from the repository root.
  source ./scripts/lib/common
  load_runtime_config
  [ "$LIBVIRT_URI" = "qemu:///system" ]
  [ "$STORAGE_POOL" = "default" ]
  python_313 >/dev/null
  case "$(command -v uv)" in
  "$BATS_TEST_TMPDIR"/*)
    printf 'integration harness resolved mocked uv\n' >&2
    return 1
    ;;
  esac
  mkdir -p "$VM_X86_REDFISH_ARTIFACTS_DIR"
  # shellcheck disable=SC2034 # Loaded process helpers consume this array.
  TRACKED_CHILDREN=()
}

wait_for_domain_state() {
  local expected="$1"
  local deadline=$((SECONDS + 30))
  local state
  until state="$(bounded_virsh domstate "$VM_X86_REDFISH_DOMAIN_NAME")" &&
    [ "$state" = "$expected" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

wait_for_loopback_port_free() {
  local port="$1"
  local deadline=$((SECONDS + 30))
  local python_bin
  python_bin="$(python_313)"
  until "$python_bin" - "$port" <<'PY'; do
import socket
import sys

try:
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("127.0.0.1", int(sys.argv[1])))
        sock.listen()
except OSError:
    raise SystemExit(1)
PY
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

start_media_server() {
  local directory="$1"
  local name="$2"
  local python_bin
  shift 2
  python_bin="$(python_313)"
  "$python_bin" tests/helpers/media-server.py \
    --directory "$directory" \
    --port-file "$BATS_TEST_TMPDIR/${name}.port" \
    --ready-file "$BATS_TEST_TMPDIR/${name}.ready" "$@" &
  MEDIA_SERVER_PID="$!"
  track_child "$MEDIA_SERVER_PID"
  wait_for_file "$BATS_TEST_TMPDIR/${name}.ready"
  MEDIA_SERVER_PORT="$(<"$BATS_TEST_TMPDIR/${name}.port")"
}

start_sushy() {
  ./scripts/run-redfish >"$VM_X86_REDFISH_ARTIFACTS_DIR/sushy-vmedia.log" 2>&1 &
  SUSHY_PID="$!"
  track_child "$SUSHY_PID"
  wait_for_url "https://127.0.0.1:8000/redfish/v1"
}

create_sentinel_iso() {
  local iso_path="$1"
  local sentinel="$2"
  local iso_root="$BATS_TEST_TMPDIR/iso-root"
  mkdir -p "$iso_root/boot/grub"
  sed -e 's/@DEFAULT_ENTRY@/0/' -e "s/@SENTINEL@/${sentinel}/" \
    tests/fixtures/grub.cfg.in \
    >"$iso_root/boot/grub/grub.cfg"
  grub2-mkrescue -o "$iso_path" "$iso_root" \
    >"$VM_X86_REDFISH_ARTIFACTS_DIR/grub2-mkrescue.log" 2>&1
}

matching_kernel_image() {
  local kernel_release="$1"
  local candidate
  for candidate in \
    "/usr/lib/modules/${kernel_release}/vmlinuz" \
    "/lib/modules/${kernel_release}/vmlinuz" \
    "/boot/vmlinuz-${kernel_release}"; do
    if [ -r "$candidate" ]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  printf 'matching kernel %s is not readable\n' "$kernel_release" >&2
  return 1
}

create_nmi_iso() {
  local iso_path="$1"
  local fixture_root="$BATS_TEST_TMPDIR/nmi-fixture"
  local initramfs_root="$fixture_root/initramfs"
  local iso_root="$fixture_root/iso-root"
  local init_binary="$fixture_root/nmi-init"
  local kernel_release
  local kernel_path

  kernel_release="$(uname -r)"
  kernel_path="$(matching_kernel_image "$kernel_release")" || return
  mkdir -p "$fixture_root" "$iso_root/boot/grub"
  gcc -std=c17 -static -Os -s -Wall -Wextra -Werror \
    -o "$init_binary" tests/fixtures/nmi-init.c
  build_nmi_initramfs \
    "$init_binary" "$iso_root/boot/nmi-initramfs.cpio" "$initramfs_root"
  cp "$kernel_path" "$iso_root/boot/vmlinuz"
  sed -e 's/@DEFAULT_ENTRY@/1/' -e 's/@SENTINEL@/unused/' \
    tests/fixtures/grub.cfg.in >"$iso_root/boot/grub/grub.cfg"
  grub2-mkrescue -o "$iso_path" "$iso_root" \
    >"$VM_X86_REDFISH_ARTIFACTS_DIR/grub2-mkrescue-nmi.log" 2>&1
}

select_routable_host_ip() {
  local python_bin
  python_bin="$(python_313)"
  "$python_bin" - <<'PY'
import ipaddress
import socket

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.connect(("192.0.2.1", 9))
    address = ipaddress.ip_address(sock.getsockname()[0])
if address.is_loopback or address.is_unspecified or address.is_multicast:
    raise SystemExit("no concrete non-loopback IPv4 route source is available")
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
    probe.bind((str(address), 0))
print(address)
PY
}

allocate_tcp_port() {
  local address="$1"
  local python_bin
  python_bin="$(python_313)"
  "$python_bin" - "$address" <<'PY'
import socket
import sys

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind((sys.argv[1], 0))
    print(sock.getsockname()[1])
PY
}

remote_endpoint_was_used() {
  local candidate="$1"
  local endpoint
  for endpoint in "${REMOTE_USED_ENDPOINTS[@]:-}"; do
    [ "$endpoint" != "$candidate" ] || return 0
  done
  return 1
}

allocate_fresh_tcp_port() {
  local address="$1"
  local candidate
  local endpoint
  local allocation_attempt
  for ((allocation_attempt = 1; allocation_attempt <= 32; allocation_attempt++)); do
    if candidate="$(allocate_tcp_port "$address")"; then
      endpoint="$(endpoint_address_port "$address" "$candidate")"
      if ! remote_endpoint_was_used "$endpoint"; then
        REMOTE_ALLOCATED_PORT="$candidate"
        REMOTE_USED_ENDPOINTS+=("$endpoint")
        return 0
      fi
    else
      return "$?"
    fi
  done
  printf 'failed to allocate a fresh TCP port for %s after 32 attempts\n' \
    "$address" >&2
  return 1
}

configure_remote_attempt() {
  local attempt="$2"
  local config_status
  local serial_mode="$1"
  REMOTE_ATTEMPT_DIR="${VM_X86_REDFISH_ARTIFACTS_DIR}/remote-${serial_mode}-${attempt}"
  REMOTE_ATTEMPT_PIDS=()
  mkdir -p "$REMOTE_ATTEMPT_DIR"
  if REMOTE_HOST_IP="$(select_routable_host_ip)"; then
    :
  else
    config_status="$?"
    return "$config_status"
  fi
  allocate_fresh_tcp_port "$REMOTE_HOST_IP" || return
  REMOTE_REDFISH_PORT="$REMOTE_ALLOCATED_PORT"
  export VM_X86_REDFISH_LISTEN_IP="$REMOTE_HOST_IP"
  export VM_X86_REDFISH_LISTEN_PORT="$REMOTE_REDFISH_PORT"
  export VM_X86_REDFISH_SERIAL_MODE="$serial_mode"
  if [ "$serial_mode" = "tcp" ]; then
    allocate_fresh_tcp_port "$REMOTE_HOST_IP" || return
    REMOTE_SERIAL_PORT="$REMOTE_ALLOCATED_PORT"
    export VM_X86_REDFISH_SERIAL_LISTEN_IP="$REMOTE_HOST_IP"
    export VM_X86_REDFISH_SERIAL_LISTEN_PORT="$REMOTE_SERIAL_PORT"
  else
    REMOTE_SERIAL_PORT=""
    unset VM_X86_REDFISH_SERIAL_LISTEN_IP VM_X86_REDFISH_SERIAL_LISTEN_PORT
  fi
  load_runtime_config
  printf '%s=%s/%s\n' "$attempt" \
    "$(endpoint_address_port "$REMOTE_HOST_IP" "$REMOTE_REDFISH_PORT")" \
    "${serial_mode}:$(serial_endpoint)" >>"$REMOTE_ATTEMPT_DIR/endpoints.log"
}

track_remote_child() {
  local pid="$1"
  local role="${2:-child}"
  track_child "$pid"
  REMOTE_ATTEMPT_PIDS+=("$pid")
  printf '%s=%s\n' "$role" "$pid" >>"$REMOTE_ATTEMPT_DIR/children.pids"
}

record_remote_tracked_child() {
  local pid="$1"
  local role="$2"
  REMOTE_ATTEMPT_PIDS+=("$pid")
  printf '%s=%s\n' "$role" "$pid" >>"$REMOTE_ATTEMPT_DIR/children.pids"
}

wait_for_text_count() {
  local expected_count="$3"
  local path="$1"
  local pattern="$2"
  local deadline=$((SECONDS + 60))
  local observed
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -f "$path" ]; then
      observed="$(awk -v text="$pattern" 'index($0, text) { count++ } END { print count + 0 }' \
        "$path")"
      [ "$observed" -lt "$expected_count" ] || return 0
    fi
    sleep 1
  done
  printf 'timed out waiting for %s occurrence(s) of %s in %s\n' \
    "$expected_count" "$pattern" "$path" >&2
  return 1
}

start_bind_fault() {
  local address="$1"
  local port="$2"
  local ready_path="$3"
  local python_bin
  python_bin="$(python_313)"
  "$python_bin" - "$address" "$port" "$ready_path" <<'PY' &
import pathlib
import signal
import socket
import sys

address, port, ready_path = sys.argv[1:]
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.bind((address, int(port)))
    listener.listen()
    pathlib.Path(ready_path).write_text("ready\n", encoding="utf-8")
    signal.pause()
PY
  REMOTE_FAULT_PID="$!"
  track_remote_child "$REMOTE_FAULT_PID" fault-listener
  wait_for_file "$ready_path"
}

verified_create_collision() {
  local endpoint="$1"
  local log_path="$2"
  grep -F "error: ${endpoint} is already in use" "$log_path" >/dev/null
}

attempt_create_has_bind_collision() {
  local serial_mode="$1"
  local log_path="$2"
  local redfish_endpoint_value
  local serial_endpoint_value
  redfish_endpoint_value="$(endpoint_address_port "$REMOTE_HOST_IP" "$REMOTE_REDFISH_PORT")"
  if verified_create_collision "$redfish_endpoint_value" "$log_path"; then
    return 0
  fi
  [ "$serial_mode" = "tcp" ] || return 1
  serial_endpoint_value="$(endpoint_address_port "$REMOTE_HOST_IP" "$REMOTE_SERIAL_PORT")"
  verified_create_collision "$serial_endpoint_value" "$log_path"
}

create_remote_domain() {
  local create_log="$REMOTE_ATTEMPT_DIR/create.log"
  local fault="$2"
  local serial_mode="$1"
  if [ "$fault" = "redfish" ]; then
    start_bind_fault "$REMOTE_HOST_IP" "$REMOTE_REDFISH_PORT" \
      "$REMOTE_ATTEMPT_DIR/redfish-fault.ready" || return
  elif [ "$fault" = "serial" ] && [ "$serial_mode" = "tcp" ]; then
    start_bind_fault "$REMOTE_HOST_IP" "$REMOTE_SERIAL_PORT" \
      "$REMOTE_ATTEMPT_DIR/serial-fault.ready" || return
  fi
  if timeout --kill-after=5 120 ./scripts/create-vm >"$create_log" 2>&1; then
    return 0
  fi
  if attempt_create_has_bind_collision "$serial_mode" "$create_log"; then
    return 75
  fi
  printf 'remote %s create failed; see %s\n' "$serial_mode" "$create_log" >&2
  return 1
}

start_remote_sushy() {
  local log_path="$REMOTE_ATTEMPT_DIR/sushy.log"
  local endpoint
  local deadline=$((SECONDS + 30))
  endpoint="$(redfish_endpoint)"
  ./scripts/run-redfish >"$log_path" 2>&1 &
  REMOTE_SUSHY_PID="$!"
  track_remote_child "$REMOTE_SUSHY_PID" redfish
  until bounded_curl --silent --fail --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    "${endpoint}/redfish/v1" >/dev/null; do
    if ! kill -0 "$REMOTE_SUSHY_PID" 2>/dev/null; then
      if grep -E 'Address already in use|EADDRINUSE' "$log_path" >/dev/null; then
        return 75
      fi
      printf 'Redfish process exited before readiness; see %s\n' "$log_path" >&2
      return 1
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

namespace_exec() {
  nsenter --target "$REMOTE_NAMESPACE_PID" --user --net --preserve-credentials "$@"
}

namespace_curl() {
  namespace_exec curl --connect-timeout 5 --max-time 15 "$@"
}

start_remote_namespace() {
  local host_inode
  local namespace_inode
  local ready_path="$REMOTE_ATTEMPT_DIR/slirp.ready"
  unshare --user --map-root-user --net sleep infinity \
    >"$REMOTE_ATTEMPT_DIR/namespace.log" 2>&1 &
  REMOTE_NAMESPACE_PID="$!"
  track_remote_child "$REMOTE_NAMESPACE_PID" namespace
  local namespace_deadline=$((SECONDS + 10))
  until [ -e "/proc/${REMOTE_NAMESPACE_PID}/ns/net" ]; do
    kill -0 "$REMOTE_NAMESPACE_PID" 2>/dev/null || return 1
    [ "$SECONDS" -lt "$namespace_deadline" ] || return 1
    sleep 1
  done
  host_inode="$(readlink /proc/self/ns/net)"
  namespace_inode="$(readlink "/proc/${REMOTE_NAMESPACE_PID}/ns/net")"
  printf 'host=%s\nnamespace=%s\n' "$host_inode" "$namespace_inode" \
    >"$REMOTE_ATTEMPT_DIR/namespace-inodes.log"
  [ "$host_inode" != "$namespace_inode" ] || return 1
  : >"$ready_path"
  slirp4netns --configure --mtu=65520 --disable-host-loopback \
    --ready-fd=3 "$REMOTE_NAMESPACE_PID" tap0 3>"$ready_path" \
    >"$REMOTE_ATTEMPT_DIR/slirp.log" 2>&1 &
  REMOTE_SLIRP_PID="$!"
  track_remote_child "$REMOTE_SLIRP_PID" slirp
  local deadline=$((SECONDS + 30))
  until grep -Fx '1' "$ready_path" >/dev/null; do
    kill -0 "$REMOTE_SLIRP_PID" 2>/dev/null || return 1
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

prove_host_loopback_isolation() {
  local control_dir="$BATS_TEST_TMPDIR/loopback-control"
  local control_log="$REMOTE_ATTEMPT_DIR/loopback-negative.log"
  mkdir -p "$control_dir"
  printf 'host loopback control\n' >"$control_dir/control"
  start_media_server "$control_dir" loopback-control
  record_remote_tracked_child "$MEDIA_SERVER_PID" loopback-control
  bounded_curl --silent --fail \
    "http://127.0.0.1:${MEDIA_SERVER_PORT}/control" >/dev/null || return
  if namespace_curl --silent --fail \
    "http://10.0.2.2:${MEDIA_SERVER_PORT}/control" >"$control_log" 2>&1; then
    printf 'remote namespace unexpectedly reached the host loopback control\n' >&2
    return 1
  fi
}

fetch_remote_system_url() {
  local cert_path
  local endpoint
  local python_bin
  local systems_json="$REMOTE_ATTEMPT_DIR/systems.json"
  cert_path="$(realpath -e "$VM_X86_REDFISH_STATE_DIR/tls.crt")"
  endpoint="$(redfish_endpoint)"
  namespace_curl --silent --show-error --fail \
    --cacert "$cert_path" \
    --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
    "${endpoint}/redfish/v1/Systems" >"$systems_json" || return
  python_bin="$(python_313)"
  REMOTE_SYSTEM_URL="$(
    "$python_bin" - "$systems_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as systems_file:
    members = json.load(systems_file)["Members"]
if len(members) != 1:
    raise SystemExit(f"expected one remote system, found {len(members)}")
print(members[0]["@odata.id"])
PY
  )"
  [[ "$REMOTE_SYSTEM_URL" = /redfish/v1/Systems/* ]]
}

remote_redfish_action() {
  local method="$1"
  local path="$2"
  local payload="$3"
  local cert_path
  cert_path="$(realpath -e "$VM_X86_REDFISH_STATE_DIR/tls.crt")"
  namespace_curl --silent --show-error --fail \
    --cacert "$cert_path" \
    --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
    -X "$method" -H 'Content-Type: application/json' -d "$payload" \
    "$(redfish_endpoint)${path}"
}

attach_remote_nmi_media() {
  local iso_name="nmi-${TEST_ID}.iso"
  local iso_path="$BATS_TEST_TMPDIR/media/$iso_name"
  local media_url
  local payload
  mkdir -p "$BATS_TEST_TMPDIR/media"
  create_nmi_iso "$iso_path" || return
  start_media_server "$BATS_TEST_TMPDIR/media" nmi-http
  record_remote_tracked_child "$MEDIA_SERVER_PID" nmi-media
  media_url="http://127.0.0.1:${MEDIA_SERVER_PORT}/${iso_name}"
  payload="{\"Image\":\"${media_url}\",\"Inserted\":true}"
  remote_redfish_action POST \
    "${REMOTE_SYSTEM_URL}/VirtualMedia/Cd/Actions/VirtualMedia.InsertMedia" \
    "$payload" || return
  remote_redfish_action PATCH "$REMOTE_SYSTEM_URL" \
    '{"Boot":{"BootSourceOverrideTarget":"Cd","BootSourceOverrideEnabled":"Once"}}'
}

start_remote_tcp_serial() {
  local python_bin
  local serial_log="$1"
  python_bin="$(python_313)"
  namespace_exec "$python_bin" - "$REMOTE_HOST_IP" "$REMOTE_SERIAL_PORT" <<'PY' \
    >"$serial_log" 2>&1 &
import socket
import sys
import time

address, port = sys.argv[1], int(sys.argv[2])
deadline = time.monotonic() + 60
connection = None
while time.monotonic() < deadline:
    try:
        connection = socket.create_connection((address, port), timeout=2)
        break
    except OSError:
        time.sleep(0.5)
if connection is None:
    raise SystemExit("TCP serial listener did not become reachable")

captured = bytearray()
with connection:
    connection.settimeout(1)
    while time.monotonic() < deadline:
        try:
            data = connection.recv(4096)
        except TimeoutError:
            continue
        if not data:
            break
        captured.extend(data)
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        if captured.count(b"NMI_READY") >= 2:
            raise SystemExit(0)
raise SystemExit("TCP serial did not observe the restart readiness sentinel")
PY
  REMOTE_SERIAL_CLIENT_PID="$!"
  track_remote_child "$REMOTE_SERIAL_CLIENT_PID" serial-client
}

start_remote_serial_capture() {
  local serial_log="$1"
  local serial_mode="$2"
  if [ "$serial_mode" = "tcp" ]; then
    start_remote_tcp_serial "$serial_log"
  else
    run_serial_console NMI_READY 2 >"$serial_log" 2>&1 &
    REMOTE_SERIAL_CLIENT_PID="$!"
    track_remote_child "$REMOTE_SERIAL_CLIENT_PID" serial-client
  fi
}

listener_has_bind_collision() {
  local address="$1"
  local port="$2"
  local python_bin
  python_bin="$(python_313)"
  "$python_bin" - "$address" "$port" <<'PY'
import errno
import socket
import sys

try:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind((sys.argv[1], int(sys.argv[2])))
except OSError as error:
    raise SystemExit(0 if error.errno == errno.EADDRINUSE else 1)
raise SystemExit(1)
PY
}

start_remote_domain_for_nmi() {
  local post_status
  local serial_mode="$1"
  local state
  if remote_redfish_action POST \
    "${REMOTE_SYSTEM_URL}/Actions/ComputerSystem.Reset" '{"ResetType":"On"}'; then
    wait_for_domain_state running
    return
  else
    post_status="$?"
  fi
  if [ "$serial_mode" = "tcp" ]; then
    state="$(bounded_virsh domstate "$VM_X86_REDFISH_DOMAIN_NAME" 2>/dev/null)" || state=""
    if [ "$state" != "running" ] && listener_has_bind_collision \
      "$REMOTE_HOST_IP" "$REMOTE_SERIAL_PORT"; then
      return 75
    fi
  fi
  return "$post_status"
}

prove_remote_nmi_restart() {
  local serial_log="$REMOTE_ATTEMPT_DIR/serial.log"
  local serial_mode="$1"
  start_remote_domain_for_nmi "$serial_mode" || return
  start_remote_serial_capture "$serial_log" "$serial_mode" || return
  wait_for_text_count "$serial_log" NMI_READY 1 || return
  if grep -F 'NMI_UNSUPPORTED:' "$serial_log" >/dev/null; then
    printf 'NMI guest fixture reported an unsupported operation; see %s\n' "$serial_log" >&2
    return 1
  fi
  remote_redfish_action POST \
    "${REMOTE_SYSTEM_URL}/Actions/ComputerSystem.Reset" '{"ResetType":"Nmi"}' || return
  wait_for_text_count "$serial_log" 'Kernel panic' 1 || return
  wait_for_text_count "$serial_log" NMI_READY 2 || return
  wait_for_domain_state running || return
  if wait "$REMOTE_SERIAL_CLIENT_PID"; then
    untrack_child "$REMOTE_SERIAL_CLIENT_PID"
  else
    printf 'serial capture failed; see %s\n' "$serial_log" >&2
    return 1
  fi
}

require_remote_integration_prerequisites() {
  local command_name
  local package_name
  for command_name in slirp4netns unshare nsenter readlink; do
    case "$command_name" in
    slirp4netns) package_name=slirp4netns ;;
    unshare | nsenter) package_name=util-linux-core ;;
    readlink) package_name=coreutils ;;
    esac
    if ! command -v "$command_name" >/dev/null 2>&1; then
      printf "integration prerequisite: missing command '%s': install %s\n" \
        "$command_name" "$package_name" >&2
      return 1
    fi
  done
  if [ "$(id -u)" -eq 0 ]; then
    printf 'integration prerequisite: live harness must run as a non-root outer user\n' >&2
    return 1
  fi
  if ! unshare --user --map-root-user --net true >/dev/null 2>&1; then
    printf 'integration prerequisite: unprivileged user/network namespaces are unavailable\n' \
      >&2
    return 1
  fi
}

cleanup_namespace_smoke() {
  local smoke_dir="$1"
  local cleanup_status=0
  local path
  local pid
  shift
  for pid in "$@"; do
    [ -n "$pid" ] || continue
    stop_child "$pid" || cleanup_status="$?"
    if kill -0 "$pid" 2>/dev/null; then
      printf 'namespace smoke child still exists: %s\n' "$pid" >&2
      cleanup_status=1
    fi
  done
  for path in server.port slirp.ready server.log namespace.log slirp.log; do
    if [ -e "$smoke_dir/$path" ] || [ -L "$smoke_dir/$path" ]; then
      rm -- "$smoke_dir/$path" || cleanup_status="$?"
    fi
  done
  rmdir "$smoke_dir" || cleanup_status=1
  return "$cleanup_status"
}

start_namespace_smoke_processes() {
  "$NAMESPACE_SMOKE_PYTHON" - "$NAMESPACE_SMOKE_ADDRESS" \
    "$NAMESPACE_SMOKE_DIR/server.port" <<'PY' \
    >"$NAMESPACE_SMOKE_DIR/server.log" 2>&1 &
import pathlib
import socket
import sys
address, port_path = sys.argv[1:]
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.bind((address, 0))
    listener.listen()
    listener.settimeout(15)
    pathlib.Path(port_path).write_text(
        f"{listener.getsockname()[1]}\n", encoding="utf-8"
    )
    connection, _ = listener.accept()
    with connection:
        connection.settimeout(5)
        if connection.recv(16) != b"probe\n":
            raise SystemExit("unexpected namespace smoke request")
        connection.sendall(b"ok\n")
PY
  NAMESPACE_SMOKE_SERVER_PID="$!"
  unshare --user --map-root-user --net sleep infinity \
    >"$NAMESPACE_SMOKE_DIR/namespace.log" 2>&1 &
  NAMESPACE_SMOKE_NAMESPACE_PID="$!"
}

wait_for_namespace_smoke_setup() {
  local deadline=$((SECONDS + 10))
  while [ ! -s "$NAMESPACE_SMOKE_DIR/server.port" ] ||
    [ ! -e "/proc/${NAMESPACE_SMOKE_NAMESPACE_PID}/ns/net" ]; do
    if ! kill -0 "$NAMESPACE_SMOKE_SERVER_PID" 2>/dev/null ||
      ! kill -0 "$NAMESPACE_SMOKE_NAMESPACE_PID" 2>/dev/null ||
      [ "$SECONDS" -ge "$deadline" ]; then
      return 1
    else
      sleep 0.1
    fi
  done
}

assert_distinct_smoke_namespace() {
  local host_inode
  local namespace_inode
  host_inode="$(readlink /proc/self/ns/net)" || return
  namespace_inode="$(
    readlink "/proc/${NAMESPACE_SMOKE_NAMESPACE_PID}/ns/net"
  )" || return
  [ "$host_inode" != "$namespace_inode" ]
}

start_namespace_smoke_slirp() {
  local deadline=$((SECONDS + 10))
  local slirp_status
  : >"$NAMESPACE_SMOKE_DIR/slirp.ready"
  slirp4netns --configure --mtu=65520 --disable-host-loopback \
    --ready-fd=3 "$NAMESPACE_SMOKE_NAMESPACE_PID" tap0 \
    3>"$NAMESPACE_SMOKE_DIR/slirp.ready" \
    >"$NAMESPACE_SMOKE_DIR/slirp.log" 2>&1 &
  NAMESPACE_SMOKE_SLIRP_PID="$!"
  until grep -Fx '1' "$NAMESPACE_SMOKE_DIR/slirp.ready" >/dev/null; do
    if ! kill -0 "$NAMESPACE_SMOKE_SLIRP_PID" 2>/dev/null; then
      if wait "$NAMESPACE_SMOKE_SLIRP_PID"; then slirp_status=1; else slirp_status="$?"; fi
      NAMESPACE_SMOKE_SLIRP_PID=""
      return "$slirp_status"
    fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

run_namespace_smoke_client() {
  local port
  local server_status
  port="$(<"$NAMESPACE_SMOKE_DIR/server.port")"
  if timeout --kill-after=2 15 nsenter \
    --target "$NAMESPACE_SMOKE_NAMESPACE_PID" --user --net --preserve-credentials \
    "$NAMESPACE_SMOKE_PYTHON" - "$NAMESPACE_SMOKE_ADDRESS" "$port" <<'PY'; then
import socket
import sys
with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5) as client:
    client.sendall(b"probe\n")
    if client.recv(16) != b"ok\n":
        raise SystemExit("unexpected namespace smoke response")
PY
    :
  else
    return "$?"
  fi
  if wait "$NAMESPACE_SMOKE_SERVER_PID"; then
    server_status=0
  else
    server_status="$?"
  fi
  NAMESPACE_SMOKE_SERVER_PID=""
  return "$server_status"
}

run_namespace_smoke_step() {
  [ "$NAMESPACE_SMOKE_STATUS" -eq 0 ] || return 0
  if "$@"; then
    return 0
  else
    NAMESPACE_SMOKE_STATUS="$?"
  fi
}

smoke_test_remote_namespace() {
  local cleanup_status=0
  NAMESPACE_SMOKE_ADDRESS="$1"
  NAMESPACE_SMOKE_NAMESPACE_PID=""
  NAMESPACE_SMOKE_SERVER_PID=""
  NAMESPACE_SMOKE_SLIRP_PID=""
  NAMESPACE_SMOKE_STATUS=0
  NAMESPACE_SMOKE_DIR="$(
    mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/redfish-slirp-smoke.XXXXXX"
  )" || return
  NAMESPACE_SMOKE_PYTHON="$(python_313)" || NAMESPACE_SMOKE_STATUS="$?"
  run_namespace_smoke_step start_namespace_smoke_processes
  run_namespace_smoke_step wait_for_namespace_smoke_setup
  run_namespace_smoke_step assert_distinct_smoke_namespace
  run_namespace_smoke_step start_namespace_smoke_slirp
  run_namespace_smoke_step run_namespace_smoke_client
  cleanup_namespace_smoke \
    "$NAMESPACE_SMOKE_DIR" \
    "$NAMESPACE_SMOKE_SLIRP_PID" \
    "$NAMESPACE_SMOKE_NAMESPACE_PID" \
    "$NAMESPACE_SMOKE_SERVER_PID" || cleanup_status="$?"
  [ "$NAMESPACE_SMOKE_STATUS" -ne 0 ] || NAMESPACE_SMOKE_STATUS="$cleanup_status"
  if [ "$NAMESPACE_SMOKE_STATUS" -ne 0 ]; then
    printf 'integration prerequisite: namespace/slirp networking smoke probe failed\n' >&2
  fi
  return "$NAMESPACE_SMOKE_STATUS"
}

run_remote_nmi_attempt() {
  local attempt="$2"
  local attempt_fault=none
  local attempt_status
  local fault="$3"
  local serial_mode="$1"
  [ "$attempt" -ne 1 ] || attempt_fault="$fault"
  if create_remote_domain "$serial_mode" "$attempt_fault"; then
    :
  else
    attempt_status="$?"
    return "$attempt_status"
  fi
  retain_remote_cleanup_identity || return
  # shellcheck disable=SC1091 # create-vm writes this attempt-specific credentials file.
  source "$VM_X86_REDFISH_STATE_DIR/credentials.env"
  if start_remote_sushy; then
    :
  else
    attempt_status="$?"
    return "$attempt_status"
  fi
  start_remote_namespace || return
  prove_host_loopback_isolation || return
  fetch_remote_system_url || return
  attach_remote_nmi_media || return
  prove_remote_nmi_restart "$serial_mode"
}

wait_for_address_port_free() {
  local address="$1"
  local port="$2"
  local deadline=$((SECONDS + 30))
  local python_bin
  python_bin="$(python_313)"
  until "$python_bin" - "$address" "$port" <<'PY'; do
import socket
import sys

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((sys.argv[1], int(sys.argv[2])))
    sock.listen()
PY
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

assert_remote_children_stopped() {
  local pid
  for pid in "${REMOTE_ATTEMPT_PIDS[@]:-}"; do
    if kill -0 "$pid" 2>/dev/null; then
      printf 'tracked attempt child still exists: %s\n' "$pid" >&2
      return 1
    fi
  done
}

assert_remote_resources_absent() {
  local after_prefix="$1"
  assert_domain_absent_from_inventory \
    "${after_prefix}.domains" "$VM_X86_REDFISH_DOMAIN_NAME" || return
  assert_volume_absent_from_inventory \
    "${after_prefix}.volumes" "$VM_X86_REDFISH_ROOT_VOLUME_NAME" || return
  if [ -n "${REMOTE_DOMAIN_UUID:-}" ]; then
    assert_no_uuid_media_volumes \
      "${after_prefix}.volumes" "$REMOTE_DOMAIN_UUID" || return
  fi
  if [ -n "${REMOTE_NVRAM_PATH:-}" ] &&
    { [ -e "$REMOTE_NVRAM_PATH" ] || [ -L "$REMOTE_NVRAM_PATH" ]; }; then
    printf 'test NVRAM still exists: %s\n' "$REMOTE_NVRAM_PATH" >&2
    return 1
  fi
}

prepare_remote_attempt_audit() {
  REMOTE_DOMAIN_UUID=""
  REMOTE_NVRAM_PATH=""
  snapshot_live_inventory "$REMOTE_ATTEMPT_DIR/before"
}

retain_remote_cleanup_identity() {
  local domain_xml="$REMOTE_ATTEMPT_DIR/domain-before-cleanup.xml"
  REMOTE_DOMAIN_UUID="$(read_domain_uuid)" || return
  bounded_virsh dumpxml --inactive "$VM_X86_REDFISH_DOMAIN_NAME" >"$domain_xml" || return
  REMOTE_NVRAM_PATH="$(read_nvram_path "$domain_xml")" || return
  printf 'uuid=%s\nnvram=%s\n' \
    "$REMOTE_DOMAIN_UUID" "$REMOTE_NVRAM_PATH" \
    >"$REMOTE_ATTEMPT_DIR/owned-resources.log"
}

remove_enumerated_attempt_state() {
  local entry
  local entries=()
  [ -d "$VM_X86_REDFISH_STATE_DIR" ] || return 0
  mapfile -d '' -t entries < <(
    find "$VM_X86_REDFISH_STATE_DIR" -mindepth 1 -maxdepth 1 -print0
  )
  for entry in "${entries[@]:-}"; do
    if [ "$entry" != "$VM_X86_REDFISH_STATE_DIR/lifecycle.lock" ] ||
      [ ! -f "$entry" ] || [ -L "$entry" ]; then
      printf 'unexpected state remains after remote attempt: %s\n' "$entry" >&2
      return 1
    fi
  done
  if [ -f "$VM_X86_REDFISH_STATE_DIR/lifecycle.lock" ]; then
    rm -- "$VM_X86_REDFISH_STATE_DIR/lifecycle.lock"
  fi
  rmdir "$VM_X86_REDFISH_STATE_DIR"
}

cleanup_remote_attempt() {
  local attempt="$2"
  local cleanup_log="$REMOTE_ATTEMPT_DIR/destroy-${attempt}.log"
  local serial_mode="$1"
  stop_tracked_children
  assert_remote_children_stopped || return
  if ! timeout --kill-after=5 120 ./scripts/destroy-vm >"$cleanup_log" 2>&1; then
    printf 'remote %s attempt %s cleanup failed; see %s\n' \
      "$serial_mode" "$attempt" "$cleanup_log" >&2
    return 1
  fi
  snapshot_live_inventory "$REMOTE_ATTEMPT_DIR/after" || return
  assert_remote_resources_absent "$REMOTE_ATTEMPT_DIR/after" || return
  assert_inventory_unchanged \
    "$REMOTE_ATTEMPT_DIR/before.domains" \
    "$REMOTE_ATTEMPT_DIR/after.domains" domains || return
  assert_inventory_unchanged \
    "$REMOTE_ATTEMPT_DIR/before.volumes" \
    "$REMOTE_ATTEMPT_DIR/after.volumes" volumes || return
  wait_for_address_port_free "$REMOTE_HOST_IP" "$REMOTE_REDFISH_PORT" || return
  if [ "$serial_mode" = "tcp" ]; then
    wait_for_address_port_free "$REMOTE_HOST_IP" "$REMOTE_SERIAL_PORT" || return
  fi
  remove_enumerated_attempt_state
}

post_virtual_media_action() {
  local system_url="$1"
  local action="$2"
  local payload="$3"
  bounded_curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
    -H 'Content-Type: application/json' -d "$payload" \
    "https://127.0.0.1:8000${system_url}/VirtualMedia/Cd/Actions/VirtualMedia.${action}"
}

add_virtual_media_certificate() {
  local cert_path="$2"
  local payload_path="$BATS_TEST_TMPDIR/virtual-media-cert.json"
  local python_bin system_url="$1"
  python_bin="$(python_313)"
  "$python_bin" - "$cert_path" "$payload_path" <<'PY'
import json
from pathlib import Path
import sys

cert_path, payload_path = sys.argv[1:]
payload = {
    "CertificateString": Path(cert_path).read_text(encoding="utf-8"),
    "CertificateType": "PEM",
}
Path(payload_path).write_text(json.dumps(payload), encoding="utf-8")
PY
  bounded_curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
    -H 'Content-Type: application/json' --data-binary @"$payload_path" \
    "https://127.0.0.1:8000${system_url}/VirtualMedia/Cd/Certificates"
}

patch_boot_override() {
  local system_url="$1"
  local target="$2"
  bounded_curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
    -X PATCH -H 'Content-Type: application/json' \
    -d "{\"Boot\":{\"BootSourceOverrideTarget\":\"${target}\",\
\"BootSourceOverrideEnabled\":\"Once\"}}" \
    "https://127.0.0.1:8000${system_url}"
}

assert_first_boot_target() {
  local xml_path="$1"
  local expected="$2"
  local python_bin
  python_bin="$(python_313)"
  "$python_bin" - "$xml_path" "$expected" <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_path, expected = sys.argv[1:]
root = ET.parse(xml_path).getroot()
candidates = []
for disk in root.findall("./devices/disk"):
    boot = disk.find("boot")
    if boot is not None:
        candidates.append((int(boot.get("order", "0")), disk.get("device")))
for interface in root.findall("./devices/interface"):
    boot = interface.find("boot")
    if boot is not None:
        candidates.append((int(boot.get("order", "0")), "network"))
actual = min(candidates)[1] if candidates else None
mapping = {"Cd": "cdrom", "Hdd": "disk", "Pxe": "network"}
if actual != mapping[expected]:
    raise SystemExit(f"expected first boot target {expected}, found {actual}")
PY
}

assert_cd_source() {
  local xml_path="$1"
  local expected_source="$2"
  local python_bin
  python_bin="$(python_313)"
  "$python_bin" - "$xml_path" "$expected_source" <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_path, expected = sys.argv[1:]
root = ET.parse(xml_path).getroot()
sources = []
for disk in root.findall("./devices/disk"):
    if disk.get("device") == "cdrom":
        source = disk.find("source")
        sources.append(source.get("file") if source is not None else None)
if sources != [expected]:
    raise SystemExit(f"expected CD source {expected}, found {sources}")
PY
}

assert_no_cd_device() {
  local xml_path="$1"
  local python_bin
  python_bin="$(python_313)"
  "$python_bin" - "$xml_path" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
if any(disk.get("device") == "cdrom" for disk in root.findall("./devices/disk")):
    raise SystemExit("inactive domain XML still contains a CD device")
PY
}

read_nvram_path() {
  local xml_path="$1"
  local python_bin
  python_bin="$(python_313)"
  "$python_bin" - "$xml_path" <<'PY'
import sys
import xml.etree.ElementTree as ET

nvram = ET.parse(sys.argv[1]).getroot().find("./os/nvram")
if nvram is None or not nvram.text:
    raise SystemExit("inactive domain XML has no NVRAM path")
print(nvram.text)
PY
}

snapshot_tmp_files() {
  local tmpdir="$1"
  local snapshot="$2"
  find "$tmpdir" -type f -print0 >"$snapshot"
}

path_in_tmp_snapshot() {
  local snapshot="$1"
  local candidate="$2"
  local path
  while IFS= read -r -d '' path; do
    [ "$path" != "$candidate" ] || return 0
  done <"$snapshot"
  return 1
}

wait_for_new_tmp_file() {
  local snapshot="$1"
  local tmpdir="$2"
  local deadline=$((SECONDS + 30))
  local path
  while [ "$SECONDS" -lt "$deadline" ]; do
    while IFS= read -r -d '' path; do
      if ! path_in_tmp_snapshot "$snapshot" "$path"; then
        printf '%s\n' "$path"
        return 0
      fi
    done < <(find "$tmpdir" -type f -print0)
    sleep 0.1
  done
  return 1
}

capture_domain_inventory() {
  local destination="$1"
  local inventory
  if ! inventory="$(bounded_virsh list --all --name)"; then
    printf 'failed to capture libvirt domain inventory\n' >&2
    return 1
  fi
  printf '%s\n' "$inventory" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort >"$destination"
}

volume_name_from_inventory_line() {
  local line="$1"
  local volume
  line="${line#"${line%%[![:space:]]*}"}"
  case "$line" in
  "" | Name[[:space:]]* | ---*) return 0 ;;
  esac
  if [[ "$line" =~ ^(.+)[[:space:]][[:space:]]+/.*$ ]]; then
    volume="${BASH_REMATCH[1]}"
    volume="${volume%"${volume##*[![:space:]]}"}"
    printf '%s\n' "$volume"
  else
    printf '%s\n' "$line"
  fi
}

capture_volume_inventory() {
  local destination="$1"
  local inventory
  local line
  if ! inventory="$(bounded_virsh vol-list --pool "$STORAGE_POOL")"; then
    printf 'failed to capture libvirt volume inventory for pool %s\n' \
      "$STORAGE_POOL" >&2
    return 1
  fi
  while IFS= read -r line; do
    volume_name_from_inventory_line "$line"
  done <<<"$inventory" | LC_ALL=C sort >"$destination"
}

snapshot_live_inventory() {
  local prefix="$1"
  capture_domain_inventory "${prefix}.domains" || return
  capture_volume_inventory "${prefix}.volumes"
}

assert_inventory_unchanged() {
  local before="$1"
  local after="$2"
  local resource_type="$3"
  local status
  if cmp -s -- "$before" "$after"; then
    return 0
  else
    status="$?"
  fi
  if [ "$status" -eq 1 ]; then
    printf 'libvirt %s inventory changed during the test\n' "$resource_type" >&2
  else
    printf 'failed to compare libvirt %s inventories\n' "$resource_type" >&2
  fi
  return 1
}

assert_domain_absent_from_inventory() {
  local inventory="$1"
  local domain_name="$2"
  local status
  if grep -Fxq -- "$domain_name" "$inventory"; then
    printf 'test domain still exists: %s\n' "$domain_name" >&2
    return 1
  else
    status="$?"
  fi
  if [ "$status" -ne 1 ]; then
    printf 'failed to read libvirt domain inventory\n' >&2
    return 1
  fi
}

assert_volume_absent_from_inventory() {
  local inventory="$1"
  local volume_name="$2"
  local status
  if grep -Fxq -- "$volume_name" "$inventory"; then
    printf 'test volume still exists: %s\n' "$volume_name" >&2
    return 1
  else
    status="$?"
  fi
  if [ "$status" -ne 1 ]; then
    printf 'failed to read libvirt volume inventory\n' >&2
    return 1
  fi
}

assert_no_uuid_media_volumes() {
  local inventory="$1"
  local domain_uuid="$2"
  local volume
  local volumes=()
  mapfile -t volumes <"$inventory" || return
  for volume in "${volumes[@]}"; do
    if [[ "$volume" = "$PROJECT_NAME-media-"*-"$domain_uuid".img ]]; then
      printf 'UUID media volume still exists: %s\n' "$volume" >&2
      return 1
    fi
  done
}

run_serial_console() {
  local expected_count="${2:-0}"
  local marker="${1:-}"
  local python_bin
  python_bin="$(python_313)"
  "$python_bin" - "$LIBVIRT_URI" "$VM_X86_REDFISH_DOMAIN_NAME" \
    "$marker" "$expected_count" <<'PY'
import errno
import os
import pty
import select
import signal
import sys
import time

uri, domain, marker, expected_count_text = sys.argv[1:]
expected_count = int(expected_count_text)
command = [
    "timeout",
    "60",
    "virsh",
    "-c",
    uri,
    "console",
    domain,
    "--devname",
    "serial0",
    "--force",
]
pid, master_fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)


def forward_signal(signum, _frame):
    try:
        os.killpg(pid, signum)
    except ProcessLookupError:
        pass


signal.signal(signal.SIGTERM, forward_signal)
signal.signal(signal.SIGINT, forward_signal)

deadline = time.monotonic() + 70
captured = bytearray()
marker_reached = False
status = None
try:
    while time.monotonic() < deadline:
        readable, _, _ = select.select([master_fd], [], [], 1)
        if not readable:
            continue
        try:
            data = os.read(master_fd, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not data:
            break
        captured.extend(data)
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        if marker and captured.count(marker.encode()) >= expected_count:
            marker_reached = True
            forward_signal(signal.SIGTERM, None)
            break
    else:
        forward_signal(signal.SIGTERM, None)
        time.sleep(1)
        forward_signal(signal.SIGKILL, None)
        raise SystemExit(124)
finally:
    os.close(master_fd)
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        pass

if status is None:
    raise SystemExit(1)
if marker_reached:
    raise SystemExit(0)
raise SystemExit(os.waitstatus_to_exitcode(status))
PY
}

destroy_and_assert_virtual_media_cleanup() {
  local domain_uuid="$1"
  local interrupted_path="$2"
  local nvram_path="$3"
  local media_volume="$4"
  local inventory_dir="$5"
  local before_inventory="${inventory_dir}/before"
  local after_inventory="${inventory_dir}/after"
  stop_tracked_children
  timeout --kill-after=5 120 ./scripts/destroy-vm || return
  snapshot_live_inventory "$after_inventory" || return
  [ ! -e "$interrupted_path" ] || return 1
  [ ! -e "$nvram_path" ] || return 1
  if [ -e "$VM_X86_REDFISH_STATE_DIR/tmp" ] ||
    [ -L "$VM_X86_REDFISH_STATE_DIR/tmp" ]; then
    return 1
  fi
  wait_for_loopback_port_free 8000 || return
  assert_domain_absent_from_inventory \
    "${after_inventory}.domains" "$VM_X86_REDFISH_DOMAIN_NAME" || return
  assert_volume_absent_from_inventory \
    "${after_inventory}.volumes" "$VM_X86_REDFISH_ROOT_VOLUME_NAME" || return
  assert_volume_absent_from_inventory \
    "${after_inventory}.volumes" "$media_volume" || return
  assert_no_uuid_media_volumes "${after_inventory}.volumes" "$domain_uuid" || return
  assert_inventory_unchanged \
    "${before_inventory}.domains" "${after_inventory}.domains" domains || return
  assert_inventory_unchanged \
    "${before_inventory}.volumes" "${after_inventory}.volumes" volumes
}

post_reset() {
  local system_url="$1"
  local reset_type="$2"
  bounded_curl --silent --show-error --fail \
    --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{\"ResetType\":\"${reset_type}\"}" \
    "https://127.0.0.1:8000${system_url}/Actions/ComputerSystem.Reset"
}

run_remote_nmi_with_retries() {
  local attempt
  local attempt_status
  local cleanup_status
  local configure_status
  local fault="$2"
  local serial_mode="$1"
  REMOTE_USED_ENDPOINTS=()
  for attempt in 1 2 3; do
    if configure_remote_attempt "$serial_mode" "$attempt"; then
      :
    else
      configure_status="$?"
      return "$configure_status"
    fi
    prepare_remote_attempt_audit || return
    if run_remote_nmi_attempt "$serial_mode" "$attempt" "$fault"; then
      attempt_status=0
    else
      attempt_status="$?"
    fi
    if cleanup_remote_attempt "$serial_mode" "$attempt"; then
      cleanup_status=0
    else
      cleanup_status="$?"
    fi
    [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
    [ "$attempt_status" -ne 0 ] || return 0
    [ "$attempt_status" -eq 75 ] || return "$attempt_status"
    if [ "$attempt" -eq 3 ]; then
      printf 'remote %s attempt %s exhausted bind-collision retries\n' \
        "$serial_mode" "$attempt" >&2
      return 75
    fi
    printf 'remote %s attempt %s hit a verified bind collision; retrying\n' \
      "$serial_mode" "$attempt"
  done
}

simulate_failed_teardown_audits() {
  wait_for_loopback_port_free() {
    printf 'listener audit\n' >>"$BATS_TEST_TMPDIR/teardown-order"
    return 41
  }
  timeout() {
    printf 'destroy-vm\n' >>"$BATS_TEST_TMPDIR/teardown-order"
    return 42
  }
  bounded_virsh() {
    return 43
  }
  run_teardown_cleanup
}

run_teardown_cleanup() {
  local listener_status=0
  local cleanup_status=0
  local cleanup_log="$VM_X86_REDFISH_ARTIFACTS_DIR/destroy.log"
  stop_tracked_children
  wait_for_loopback_port_free 8000 || listener_status="$?"
  timeout --kill-after=5 120 ./scripts/destroy-vm >"$cleanup_log" 2>&1 ||
    cleanup_status="$?"
  if [ "$cleanup_status" -ne 0 ]; then
    if ! bounded_virsh dumpxml "$VM_X86_REDFISH_DOMAIN_NAME" \
      >"$VM_X86_REDFISH_ARTIFACTS_DIR/domain.xml" 2>&1; then
      printf 'domain XML unavailable after cleanup failure\n' \
        >>"$VM_X86_REDFISH_ARTIFACTS_DIR/domain.xml"
    fi
    printf 'destroy-vm cleanup failed with status %s; see %s\n' \
      "$cleanup_status" "$cleanup_log" >&2
  fi
  if [ "$listener_status" -ne 0 ]; then
    printf 'listener audit failed for 127.0.0.1:8000 with status %s\n' \
      "$listener_status" >&2
  fi
  if [ "$cleanup_status" -ne 0 ]; then
    return "$cleanup_status"
  fi
  return "$listener_status"
}

teardown() {
  run_teardown_cleanup
}

@test "integration harness installs cleanup helpers before live mutation" {
  run declare -F stop_tracked_children
  [ "$status" -eq 0 ]
}

@test "remote child tracking records exact namespace and client PIDs" {
  REMOTE_ATTEMPT_DIR="$BATS_TEST_TMPDIR/remote-child-records"
  REMOTE_ATTEMPT_PIDS=()
  mkdir -p "$REMOTE_ATTEMPT_DIR"

  track_remote_child 12345 namespace
  track_remote_child 23456 serial-client

  run cat "$REMOTE_ATTEMPT_DIR/children.pids"
  [ "$status" -eq 0 ]
  [ "$output" = $'namespace=12345\nserial-client=23456' ]
  [ "${REMOTE_ATTEMPT_PIDS[*]}" = "12345 23456" ]
  # shellcheck disable=SC2034 # Loaded teardown consumes the child registry.
  TRACKED_CHILDREN=()
}

@test "exact child cleanup has a configurable bounded escalation" {
  python_bin="$(python_313)"
  "$python_bin" -c \
    'import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.pause()' &
  stubborn_pid="$!"
  track_child "$stubborn_pid"
  sleep 1
  # shellcheck disable=SC2034 # Loaded cleanup helper reads this test deadline.
  CHILD_STOP_TIMEOUT_SECONDS=1
  started_at="$SECONDS"

  stop_tracked_child "$stubborn_pid"

  [ $((SECONDS - started_at)) -lt 4 ]
  run kill -0 "$stubborn_pid"
  [ "$status" -ne 0 ]
}

@test "integration harness installs bounded client helpers before live mutation" {
  bounded_client_path="$PATH"
  install_mock_command curl 'printf "curl %s\n" "$*"'
  install_mock_command timeout 'printf "timeout %s\n" "$*"'

  run bounded_curl https://127.0.0.1:8000/redfish/v1
  [ "$status" -eq 0 ]
  [ "$output" = \
    "curl --connect-timeout 5 --max-time 15 https://127.0.0.1:8000/redfish/v1" ]

  run bounded_virsh domstate example-domain
  [ "$status" -eq 0 ]
  [ "$output" = \
    "timeout --kill-after=2 10 virsh -c qemu:///system domstate example-domain" ]
  export PATH="$bounded_client_path"
}

@test "integration preflight names the missing remote-network prerequisite" {
  empty_path="$BATS_TEST_TMPDIR/empty-path"
  mkdir -p "$empty_path"

  PATH="$empty_path" run require_remote_integration_prerequisites

  [ "$status" -ne 0 ]
  [ "$output" = \
    "integration prerequisite: missing command 'slirp4netns': install slirp4netns" ]
}

@test "integration preflight rejects a root outer user before remote setup" {
  id() {
    printf '0\n'
  }

  run require_remote_integration_prerequisites

  [ "$status" -ne 0 ]
  [ "$output" = \
    "integration prerequisite: live harness must run as a non-root outer user" ]
}

@test "remote namespace smoke probe traverses slirp and cleans exact PIDs" {
  smoke_path="$PATH"
  # shellcheck disable=SC2016 # The mock expands variables when it runs.
  install_mock_command unshare '
printf "%s\n" "$$" >"$BATS_TEST_TMPDIR/smoke-namespace.pid"
trap "exit 0" TERM INT
while :; do :; done
'
  # shellcheck disable=SC2016 # The mock expands variables when it runs.
  install_mock_command slirp4netns '
printf "%s\n" "$$" >"$BATS_TEST_TMPDIR/smoke-slirp.pid"
printf "%s\n" "$*" >"$BATS_TEST_TMPDIR/smoke-slirp.args"
printf "1\n" >&3
trap "exit 0" TERM INT
while :; do :; done
'
  # shellcheck disable=SC2016 # The mock expands variables when it runs.
  install_mock_command nsenter '
printf "%s\n" "$*" >"$BATS_TEST_TMPDIR/smoke-nsenter.args"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) shift 2 ;;
    --user | --net | --preserve-credentials) shift ;;
    *) break ;;
  esac
done
exec "$@"
'
  # shellcheck disable=SC2016 # The mock expands variables when it runs.
  install_mock_command readlink '
case "$1" in
  /proc/self/ns/net) printf "net:[100]\n" ;;
  *) printf "net:[200]\n" ;;
esac
'

  run smoke_test_remote_namespace 127.0.0.1
  export PATH="$smoke_path"

  [ "$status" -eq 0 ]
  namespace_pid="$(<"$BATS_TEST_TMPDIR/smoke-namespace.pid")"
  slirp_pid="$(<"$BATS_TEST_TMPDIR/smoke-slirp.pid")"
  run kill -0 "$namespace_pid"
  [ "$status" -ne 0 ]
  run kill -0 "$slirp_pid"
  [ "$status" -ne 0 ]
  run grep -F -- '--disable-host-loopback' "$BATS_TEST_TMPDIR/smoke-slirp.args"
  [ "$status" -eq 0 ]
  run grep -F -- "--target $namespace_pid --user --net --preserve-credentials" \
    "$BATS_TEST_TMPDIR/smoke-nsenter.args"
  [ "$status" -eq 0 ]
}

@test "remote namespace smoke probe reaps its namespace when slirp fails" {
  smoke_path="$PATH"
  # shellcheck disable=SC2016 # The mock expands variables when it runs.
  install_mock_command unshare '
printf "%s\n" "$$" >"$BATS_TEST_TMPDIR/failed-smoke-namespace.pid"
trap "exit 0" TERM INT
while :; do :; done
'
  install_mock_command slirp4netns 'exit 31'
  # shellcheck disable=SC2016 # The mock expands variables when it runs.
  install_mock_command readlink '
case "$1" in
  /proc/self/ns/net) printf "net:[100]\n" ;;
  *) printf "net:[200]\n" ;;
esac
'

  run smoke_test_remote_namespace 127.0.0.1
  export PATH="$smoke_path"

  [ "$status" -ne 0 ]
  namespace_pid="$(<"$BATS_TEST_TMPDIR/failed-smoke-namespace.pid")"
  run kill -0 "$namespace_pid"
  [ "$status" -ne 0 ]
}

@test "remote Redfish actions retain TLS authentication and the requested method" {
  printf 'test certificate\n' >"$VM_X86_REDFISH_STATE_DIR/tls.crt"
  REDFISH_USERNAME=test-user
  REDFISH_PASSWORD=test-password
  namespace_curl() {
    printf '%s\n' "$*"
  }

  run remote_redfish_action PATCH /redfish/v1/Systems/test '{}'

  [ "$status" -eq 0 ]
  [[ "$output" == *"--cacert "*"/tls.crt"* ]]
  [[ "$output" == *"--user test-user:test-password"* ]]
  [[ "$output" == *"-X PATCH"* ]]
  [[ "$output" == *"https://127.0.0.1:8000/redfish/v1/Systems/test"* ]]
}

@test "namespace clients enter the exact user and network namespaces" {
  install_mock_command nsenter 'printf "%s\n" "$*"'
  REMOTE_NAMESPACE_PID=4242

  run namespace_exec curl https://192.0.2.10:8443/redfish/v1

  [ "$status" -eq 0 ]
  expected="--target 4242 --user --net --preserve-credentials "
  expected+="curl https://192.0.2.10:8443/redfish/v1"
  [ "$output" = "$expected" ]
}

@test "bind-collision classification accepts only configured attempt endpoints" {
  REMOTE_HOST_IP=192.0.2.10
  REMOTE_REDFISH_PORT=8443
  REMOTE_SERIAL_PORT=9000
  collision_log="$BATS_TEST_TMPDIR/create-collision.log"

  printf 'error: 192.0.2.10:8443 is already in use\n' >"$collision_log"
  run attempt_create_has_bind_collision pty "$collision_log"
  [ "$status" -eq 0 ]
  printf 'error: 192.0.2.10:9000 is already in use\n' >"$collision_log"
  run attempt_create_has_bind_collision tcp "$collision_log"
  [ "$status" -eq 0 ]
  printf 'error: 192.0.2.10:9999 is already in use\n' >"$collision_log"
  run attempt_create_has_bind_collision tcp "$collision_log"
  [ "$status" -ne 0 ]
}

@test "TCP start classifies a verified serial bind collision for retry" {
  REMOTE_HOST_IP=192.0.2.10
  REMOTE_SERIAL_PORT=9000
  REMOTE_SYSTEM_URL=/redfish/v1/Systems/test
  remote_redfish_action() {
    return 22
  }
  bounded_virsh() {
    printf 'shut off\n'
  }
  listener_has_bind_collision() {
    return 0
  }

  run start_remote_domain_for_nmi tcp

  [ "$status" -eq 75 ]
}

@test "cleanup inventory snapshots require successful libvirt queries" {
  failing_inventory_path="$PATH"
  install_mock_command virsh '
case "$*" in
  *"list --all --name") exit 31 ;;
  *"vol-list --pool default") exit 32 ;;
esac
'

  run capture_domain_inventory "$BATS_TEST_TMPDIR/domains"
  domain_status="$status"
  domain_output="$output"
  run capture_volume_inventory "$BATS_TEST_TMPDIR/volumes"
  volume_status="$status"
  volume_output="$output"
  export PATH="$failing_inventory_path"

  [ "$domain_status" -ne 0 ]
  [[ "$domain_output" == *"failed to capture libvirt domain inventory"* ]]
  [ "$volume_status" -ne 0 ]
  [[ "$volume_output" == *"failed to capture libvirt volume inventory"* ]]
}

@test "cleanup inventory helpers compare exact resource names" {
  exact_inventory_path="$PATH"
  install_mock_command virsh '
case "$*" in
  *"list --all --name")
    printf "%s\n" unrelated vm-x86-redfish-near-match
    ;;
  *"vol-list --pool default")
    printf " Name   Path\n-----------------------------------\n"
    printf "%s   %s\n" unrelated.qcow2 /var/lib/libvirt/images/unrelated.qcow2
    printf "%s   %s\n" vm-x86-redfish-near-match.qcow2 /var/lib/libvirt/images/near
    ;;
esac
'

  capture_domain_inventory "$BATS_TEST_TMPDIR/domains"
  capture_volume_inventory "$BATS_TEST_TMPDIR/volumes"
  export PATH="$exact_inventory_path"

  run assert_domain_absent_from_inventory \
    "$BATS_TEST_TMPDIR/domains" vm-x86-redfish
  [ "$status" -eq 0 ]
  run assert_volume_absent_from_inventory \
    "$BATS_TEST_TMPDIR/volumes" vm-x86-redfish.qcow2
  [ "$status" -eq 0 ]
  run assert_domain_absent_from_inventory \
    "$BATS_TEST_TMPDIR/domains" unrelated
  [ "$status" -ne 0 ]
  run assert_volume_absent_from_inventory \
    "$BATS_TEST_TMPDIR/volumes" unrelated.qcow2
  [ "$status" -ne 0 ]
  run assert_inventory_unchanged \
    "$BATS_TEST_TMPDIR/domains" "$BATS_TEST_TMPDIR/domains" domains
  [ "$status" -eq 0 ]

  printf 'changed\n' >"$BATS_TEST_TMPDIR/changed-domains"
  run assert_inventory_unchanged \
    "$BATS_TEST_TMPDIR/domains" "$BATS_TEST_TMPDIR/changed-domains" domains
  [ "$status" -ne 0 ]
}

@test "remote cleanup fails closed when post-cleanup inventory capture fails" {
  REMOTE_ATTEMPT_DIR="$BATS_TEST_TMPDIR/cleanup-inventory-error"
  REMOTE_ATTEMPT_PIDS=()
  REMOTE_HOST_IP=127.0.0.1
  REMOTE_REDFISH_PORT=8443
  mkdir -p "$REMOTE_ATTEMPT_DIR"
  stop_tracked_children() { :; }
  assert_remote_children_stopped() { :; }
  timeout() { :; }
  snapshot_live_inventory() {
    printf 'snapshot %s\n' "$1" >>"$BATS_TEST_TMPDIR/cleanup.log"
    return 37
  }
  assert_remote_resources_absent() {
    printf 'absence audit unexpectedly ran\n' >>"$BATS_TEST_TMPDIR/cleanup.log"
  }
  wait_for_address_port_free() { :; }
  remove_enumerated_attempt_state() { :; }

  run cleanup_remote_attempt pty 1

  [ "$status" -eq 37 ]
  run cat "$BATS_TEST_TMPDIR/cleanup.log"
  [ "$status" -eq 0 ]
  [ "$output" = "snapshot $REMOTE_ATTEMPT_DIR/after" ]
}

@test "remote cleanup rejects every retained UUID media volume" {
  after_prefix="$BATS_TEST_TMPDIR/after-media"
  REMOTE_DOMAIN_UUID=11111111-2222-4333-8444-555555555555
  REMOTE_NVRAM_PATH=""
  printf 'unrelated\n' >"${after_prefix}.domains"
  printf '%s\n' \
    "vm-x86-redfish-media-nmi-${REMOTE_DOMAIN_UUID}.img" \
    unrelated.qcow2 >"${after_prefix}.volumes"

  run assert_remote_resources_absent "$after_prefix"

  [ "$status" -ne 0 ]
  [[ "$output" == *"UUID media volume still exists"* ]]
}

@test "remote cleanup rejects the retained NVRAM path" {
  after_prefix="$BATS_TEST_TMPDIR/after-nvram"
  REMOTE_DOMAIN_UUID=11111111-2222-4333-8444-555555555555
  REMOTE_NVRAM_PATH="$BATS_TEST_TMPDIR/test_VARS.fd"
  printf 'firmware state\n' >"$REMOTE_NVRAM_PATH"
  : >"${after_prefix}.domains"
  : >"${after_prefix}.volumes"

  run assert_remote_resources_absent "$after_prefix"

  [ "$status" -ne 0 ]
  [[ "$output" == *"test NVRAM still exists"* ]]
}

@test "remote cleanup identity retains UUID and NVRAM before state deletion" {
  REMOTE_ATTEMPT_DIR="$BATS_TEST_TMPDIR/retained-identity"
  REMOTE_DOMAIN_UUID=""
  REMOTE_NVRAM_PATH=""
  mkdir -p "$REMOTE_ATTEMPT_DIR"
  printf '%s\n' 11111111-2222-4333-8444-555555555555 \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  bounded_virsh() {
    printf '%s\n' '<domain><os><nvram>/var/lib/libvirt/qemu/nvram/test_VARS.fd</nvram></os></domain>'
  }

  run retain_remote_cleanup_identity

  [ "$status" -eq 0 ]
  run cat "$REMOTE_ATTEMPT_DIR/owned-resources.log"
  [ "$status" -eq 0 ]
  expected=$'uuid=11111111-2222-4333-8444-555555555555\n'
  expected+=$'nvram=/var/lib/libvirt/qemu/nvram/test_VARS.fd'
  [ "$output" = "$expected" ]
}

@test "integration harness stops children before destroying VM resources" {
  ready_file="$BATS_TEST_TMPDIR/lifecycle-lock-ready"
  bash -c '
    exec 9>"$1"
    flock 9
    printf "ready\n" >"$2"
    trap "exit 0" TERM
    while :; do
      :
    done
  ' -- "$LIFECYCLE_LOCK" "$ready_file" &
  child_pid="$!"
  track_child "$child_pid"

  deadline=$((SECONDS + 5))
  until [ -f "$ready_file" ]; do
    [ "$SECONDS" -lt "$deadline" ]
    sleep 1
  done
  run flock -n "$LIFECYCLE_LOCK" -c true
  [ "$status" -ne 0 ]

  stop_tracked_children
  run kill -0 "$child_pid"
  [ "$status" -ne 0 ]

  run timeout --kill-after=5 120 ./scripts/destroy-vm
  [ "$status" -eq 0 ]
}

@test "remote retry orchestration cleans collisions and stops after success" {
  configure_remote_attempt() {
    printf 'configure %s %s\n' "$1" "$2" >>"$BATS_TEST_TMPDIR/retry.log"
  }
  prepare_remote_attempt_audit() {
    printf 'prepare\n' >>"$BATS_TEST_TMPDIR/retry.log"
  }
  run_remote_nmi_attempt() {
    printf 'run %s %s %s\n' "$1" "$2" "$3" >>"$BATS_TEST_TMPDIR/retry.log"
    [ "$2" -eq 1 ] && return 75
    return 0
  }
  cleanup_remote_attempt() {
    printf 'cleanup %s %s\n' "$1" "$2" >>"$BATS_TEST_TMPDIR/retry.log"
  }

  run run_remote_nmi_with_retries pty redfish

  [ "$status" -eq 0 ]
  [ "$output" = "remote pty attempt 1 hit a verified bind collision; retrying" ]
  run cat "$BATS_TEST_TMPDIR/retry.log"
  [ "$status" -eq 0 ]
  expected=$'configure pty 1\nprepare\nrun pty 1 redfish\ncleanup pty 1\n'
  expected+=$'configure pty 2\nprepare\nrun pty 2 redfish\ncleanup pty 2'
  [ "$output" = "$expected" ]
}

@test "remote retry orchestration stops when attempt configuration fails" {
  configure_remote_attempt() {
    printf 'configure %s %s\n' "$1" "$2" >>"$BATS_TEST_TMPDIR/retry.log"
    return 42
  }
  prepare_remote_attempt_audit() {
    printf 'prepare\n' >>"$BATS_TEST_TMPDIR/retry.log"
  }
  run_remote_nmi_attempt() {
    printf 'run\n' >>"$BATS_TEST_TMPDIR/retry.log"
  }
  cleanup_remote_attempt() {
    printf 'cleanup\n' >>"$BATS_TEST_TMPDIR/retry.log"
  }

  run run_remote_nmi_with_retries pty none

  [ "$status" -eq 42 ]
  run cat "$BATS_TEST_TMPDIR/retry.log"
  [ "$status" -eq 0 ]
  [ "$output" = "configure pty 1" ]
}

@test "remote attempt configuration propagates endpoint allocation failures" {
  select_routable_host_ip() {
    printf '192.0.2.10\n'
  }
  allocate_tcp_port() {
    return 43
  }
  REMOTE_USED_ENDPOINTS=()

  run configure_remote_attempt pty 1

  [ "$status" -eq 43 ]
}

@test "remote retry orchestration stops when baseline inventory capture fails" {
  configure_remote_attempt() {
    printf 'configure\n' >>"$BATS_TEST_TMPDIR/retry.log"
  }
  prepare_remote_attempt_audit() {
    printf 'prepare\n' >>"$BATS_TEST_TMPDIR/retry.log"
    return 38
  }
  run_remote_nmi_attempt() {
    printf 'run\n' >>"$BATS_TEST_TMPDIR/retry.log"
  }
  cleanup_remote_attempt() {
    printf 'cleanup\n' >>"$BATS_TEST_TMPDIR/retry.log"
  }

  run run_remote_nmi_with_retries pty none

  [ "$status" -eq 38 ]
  run cat "$BATS_TEST_TMPDIR/retry.log"
  [ "$status" -eq 0 ]
  [ "$output" = $'configure\nprepare' ]
}

@test "remote retries replace every previously used endpoint tuple" {
  port_queue="$BATS_TEST_TMPDIR/ports"
  printf '%s\n' 8443 9000 8443 9000 8444 9001 >"$port_queue"
  select_routable_host_ip() {
    printf '192.0.2.10\n'
  }
  allocate_tcp_port() {
    local selected_port
    selected_port="$(sed -n '1p' "$port_queue")"
    sed -i '1d' "$port_queue"
    printf '%s\n' "$selected_port"
  }
  REMOTE_USED_ENDPOINTS=()

  configure_remote_attempt tcp 1
  before_tuple="${REMOTE_HOST_IP}:${REMOTE_REDFISH_PORT}/\
${REMOTE_HOST_IP}:${REMOTE_SERIAL_PORT}"
  configure_remote_attempt tcp 2
  after_tuple="${REMOTE_HOST_IP}:${REMOTE_REDFISH_PORT}/\
${REMOTE_HOST_IP}:${REMOTE_SERIAL_PORT}"

  [ "$before_tuple" = "192.0.2.10:8443/192.0.2.10:9000" ]
  [ "$after_tuple" = "192.0.2.10:8444/192.0.2.10:9001" ]
  [ "$before_tuple" != "$after_tuple" ]
}

@test "remote retry orchestration does not retry non-collision failures" {
  configure_remote_attempt() {
    printf 'configure %s %s\n' "$1" "$2" >>"$BATS_TEST_TMPDIR/retry.log"
  }
  prepare_remote_attempt_audit() {
    printf 'prepare\n' >>"$BATS_TEST_TMPDIR/retry.log"
  }
  run_remote_nmi_attempt() {
    printf 'run %s %s %s\n' "$1" "$2" "$3" >>"$BATS_TEST_TMPDIR/retry.log"
    return 64
  }
  cleanup_remote_attempt() {
    printf 'cleanup %s %s\n' "$1" "$2" >>"$BATS_TEST_TMPDIR/retry.log"
  }

  run run_remote_nmi_with_retries tcp serial

  [ "$status" -eq 64 ]
  run cat "$BATS_TEST_TMPDIR/retry.log"
  [ "$status" -eq 0 ]
  [ "$output" = $'configure tcp 1\nprepare\nrun tcp 1 serial\ncleanup tcp 1' ]
}

@test "remote retry orchestration bounds verified collisions at three attempts" {
  configure_remote_attempt() {
    printf 'configure %s %s\n' "$1" "$2" >>"$BATS_TEST_TMPDIR/retry.log"
  }
  prepare_remote_attempt_audit() {
    printf 'prepare\n' >>"$BATS_TEST_TMPDIR/retry.log"
  }
  run_remote_nmi_attempt() {
    printf 'run %s %s %s\n' "$1" "$2" "$3" >>"$BATS_TEST_TMPDIR/retry.log"
    return 75
  }
  cleanup_remote_attempt() {
    printf 'cleanup %s %s\n' "$1" "$2" >>"$BATS_TEST_TMPDIR/retry.log"
  }

  run run_remote_nmi_with_retries tcp serial

  [ "$status" -eq 75 ]
  [[ "$output" == *"remote tcp attempt 3 exhausted bind-collision retries"* ]]
  run grep -c '^cleanup tcp ' "$BATS_TEST_TMPDIR/retry.log"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "teardown destroys resources and reports every failed cleanup audit" {
  run simulate_failed_teardown_audits
  [ "$status" -eq 42 ]
  [[ "$output" == *"listener audit failed for 127.0.0.1:8000 with status 41"* ]]
  [[ "$output" == *"destroy-vm cleanup failed with status 42"* ]]

  run cat "$BATS_TEST_TMPDIR/teardown-order"
  [ "$status" -eq 0 ]
  [ "$output" = $'listener audit\ndestroy-vm' ]
}

@test "media server helper publishes selected port after binding" {
  mkdir -p "$BATS_TEST_TMPDIR/media"
  printf 'sentinel\n' >"$BATS_TEST_TMPDIR/media/sentinel.iso"
  python_bin="$(python_313)"
  "$python_bin" tests/helpers/media-server.py \
    --directory "$BATS_TEST_TMPDIR/media" \
    --port-file "$BATS_TEST_TMPDIR/media.port" \
    --ready-file "$BATS_TEST_TMPDIR/media.ready" &
  track_child "$!"
  wait_for_file "$BATS_TEST_TMPDIR/media.ready"
  media_port="$(<"$BATS_TEST_TMPDIR/media.port")"
  run curl --silent --fail "http://127.0.0.1:${media_port}/sentinel.iso"
  [ "$status" -eq 0 ]
  [ "$output" = "sentinel" ]
}

@test "temporary media wait ignores baseline files" {
  tmpdir="$BATS_TEST_TMPDIR/media-tmp"
  baseline="$BATS_TEST_TMPDIR/media-tmp-baseline"
  stale_path="$tmpdir/stale-download"
  fresh_path="$tmpdir/new-download"
  mkdir -p "$tmpdir"
  printf 'stale\n' >"$stale_path"
  snapshot_tmp_files "$tmpdir" "$baseline"

  bash -c 'sleep 0.2; printf "fresh\\n" >"$1"' -- "$fresh_path" &
  track_child "$!"

  observed_path="$(wait_for_new_tmp_file "$baseline" "$tmpdir")"
  [ "$observed_path" = "$fresh_path" ]
}

@test "authenticated Redfish controls isolated libvirt domain power" {
  run timeout --kill-after=5 120 ./scripts/create-vm
  [ "$status" -eq 0 ]

  root_info="$(bounded_virsh vol-dumpxml --pool "$STORAGE_POOL" "$ROOT_VOLUME_NAME")"
  python_bin="$(python_313)"
  "$python_bin" - "$root_info" <<'PY'
import sys
import xml.etree.ElementTree as ET

volume = ET.fromstring(sys.argv[1])
assert volume.find("capacity").text == str(1024**3)
assert volume.find("target/format").get("type") == "qcow2"
PY

  ./scripts/run-redfish >"$VM_X86_REDFISH_ARTIFACTS_DIR/sushy.log" 2>&1 &
  sushy_pid="$!"
  track_child "$sushy_pid"

  wait_for_url "https://127.0.0.1:8000/redfish/v1"
  run bounded_curl --silent --show-error --fail \
    --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    "https://127.0.0.1:8000/redfish/v1"
  [ "$status" -eq 0 ]

  run bounded_curl --silent --output /dev/null --write-out '%{http_code}' \
    --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    "https://127.0.0.1:8000/redfish/v1/Systems"
  [ "$status" -eq 0 ]
  [ "$output" = "401" ]

  # shellcheck disable=SC1091 # create-vm writes this test-specific credentials file.
  source "$VM_X86_REDFISH_STATE_DIR/credentials.env"
  systems_json="$VM_X86_REDFISH_ARTIFACTS_DIR/systems.json"
  bounded_curl --silent --show-error --fail \
    --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
    "https://127.0.0.1:8000/redfish/v1/Systems" >"$systems_json"
  python_bin="$(python_313)"
  system_url="$(
    $python_bin - "$systems_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as systems_file:
    members = json.load(systems_file)["Members"]
if len(members) != 1:
    raise SystemExit(f"expected one system, found {len(members)}")
print(members[0]["@odata.id"])
PY
  )"
  [[ "$system_url" = /redfish/v1/Systems/* ]]

  run bounded_virsh domstate "$VM_X86_REDFISH_DOMAIN_NAME"
  [ "$status" -eq 0 ]
  [ "$output" = "shut off" ]
  run bounded_curl --silent --output /dev/null --write-out '%{http_code}' \
    --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    -H 'Content-Type: application/json' \
    -d '{"ResetType":"On"}' \
    "https://127.0.0.1:8000${system_url}/Actions/ComputerSystem.Reset"
  [ "$status" -eq 0 ]
  [ "$output" = "401" ]
  run bounded_virsh domstate "$VM_X86_REDFISH_DOMAIN_NAME"
  [ "$status" -eq 0 ]
  [ "$output" = "shut off" ]

  post_reset "$system_url" On
  wait_for_domain_state running

  restart_events="$VM_X86_REDFISH_ARTIFACTS_DIR/force-restart-events.log"
  timeout --kill-after=5 20 virsh -c "$LIBVIRT_URI" event \
    --domain "$VM_X86_REDFISH_DOMAIN_NAME" --event lifecycle --loop --timeout 15 \
    >"$restart_events" 2>&1 &
  event_pid="$!"
  track_child "$event_pid"
  sleep 1
  run kill -0 "$event_pid"
  [ "$status" -eq 0 ]
  post_reset "$system_url" ForceRestart
  wait "$event_pid"
  untrack_child "$event_pid"
  run grep -E 'Stopped Destroyed$' "$restart_events"
  [ "$status" -eq 0 ]
  run grep -E 'Started Booted$' "$restart_events"
  [ "$status" -eq 0 ]
  wait_for_domain_state running
  post_reset "$system_url" ForceOff
  wait_for_domain_state "shut off"
}

@test "virtual media boots a serial sentinel and interrupted insertion is cleaned" {
  inventory_dir="$VM_X86_REDFISH_ARTIFACTS_DIR/live-inventory"
  mkdir -p "$inventory_dir"
  snapshot_live_inventory "$inventory_dir/before"
  run timeout --kill-after=5 120 ./scripts/create-vm
  [ "$status" -eq 0 ]
  # shellcheck disable=SC1091 # create-vm writes this test-specific credentials file.
  source "$VM_X86_REDFISH_STATE_DIR/credentials.env"
  domain_uuid="$(<"$VM_X86_REDFISH_STATE_DIR/domain-uuid")"
  system_url="/redfish/v1/Systems/${domain_uuid}"

  iso_name="sentinel-${TEST_ID}.iso"
  iso_path="$BATS_TEST_TMPDIR/media/$iso_name"
  sentinel="VM_X86_REDFISH_SENTINEL_${TEST_ID}"
  mkdir -p "$BATS_TEST_TMPDIR/media"
  create_sentinel_iso "$iso_path" "$sentinel"

  start_media_server "$BATS_TEST_TMPDIR/media" sentinel-http
  media_port="$MEDIA_SERVER_PORT"
  untrusted_cert="$BATS_TEST_TMPDIR/untrusted-media.crt"
  untrusted_key="$BATS_TEST_TMPDIR/untrusted-media.key"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 1 -nodes \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -keyout "$untrusted_key" \
    -out "$untrusted_cert" \
    >"$VM_X86_REDFISH_ARTIFACTS_DIR/untrusted-media-openssl.log" 2>&1
  start_media_server "$BATS_TEST_TMPDIR/media" untrusted-https \
    --tls-cert "$untrusted_cert" \
    --tls-key "$untrusted_key"
  untrusted_tls_media_port="$MEDIA_SERVER_PORT"
  start_media_server "$BATS_TEST_TMPDIR/media" trusted-https \
    --tls-cert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    --tls-key "$VM_X86_REDFISH_STATE_DIR/tls.key"
  trusted_tls_media_port="$MEDIA_SERVER_PORT"

  start_sushy
  sushy_pid="$SUSHY_PID"

  run bounded_curl --silent --show-error --fail --insecure --output /dev/null \
    "https://127.0.0.1:${untrusted_tls_media_port}/${iso_name}"
  [ "$status" -eq 0 ]
  untrusted_payload="{\"Image\":\"https://127.0.0.1:${untrusted_tls_media_port}/${iso_name}\",\
\"Inserted\":true}"
  run post_virtual_media_action "$system_url" InsertMedia "$untrusted_payload"
  [ "$status" -eq 0 ]
  [ "$output" = "500" ]

  outside_vmedia="$VM_X86_REDFISH_STATE_DIR/outside-vmedia"
  printf 'unchanged\n' >"$outside_vmedia"
  start_media_server "$BATS_TEST_TMPDIR/media" hostile-filename \
    --content-disposition 'attachment; filename="../outside-vmedia"'
  hostile_media_port="$MEDIA_SERVER_PORT"
  hostile_url="http://127.0.0.1:${hostile_media_port}/${iso_name}"
  hostile_payload="{\"Image\":\"${hostile_url}\",\"Inserted\":true}"
  run post_virtual_media_action "$system_url" InsertMedia "$hostile_payload"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
  run cat "$outside_vmedia"
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged" ]

  run add_virtual_media_certificate "$system_url" "$VM_X86_REDFISH_STATE_DIR/tls.crt"
  [ "$status" -eq 0 ]
  [ "$output" = "204" ]
  media_url="https://127.0.0.1:${trusted_tls_media_port}/${iso_name}"
  insert_payload="{\"Image\":\"${media_url}\",\"Inserted\":true}"
  run post_virtual_media_action "$system_url" InsertMedia "$insert_payload"
  [ "$status" -eq 0 ]
  [ "$output" = "204" ]
  run patch_boot_override "$system_url" Cd
  [ "$status" -eq 0 ]
  [ "$output" = "204" ]

  media_volume="$(volume_name_for_media "$media_url" "$domain_uuid")"
  media_source="$(bounded_virsh vol-path --pool "$STORAGE_POOL" "$media_volume")"
  inactive_xml="$VM_X86_REDFISH_ARTIFACTS_DIR/cd-domain.xml"
  bounded_virsh dumpxml --inactive "$VM_X86_REDFISH_DOMAIN_NAME" >"$inactive_xml"
  assert_cd_source "$inactive_xml" "$media_source"
  assert_first_boot_target "$inactive_xml" Cd
  nvram_path="$(read_nvram_path "$inactive_xml")"

  post_reset "$system_url" On
  wait_for_domain_state running
  serial_log="$VM_X86_REDFISH_ARTIFACTS_DIR/serial.log"
  run run_serial_console
  printf '%s\n' "$output" >"$serial_log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$sentinel"* ]]
  [ -f "$nvram_path" ]

  wait_for_domain_state "shut off"
  post_reset "$system_url" ForceOff
  wait_for_domain_state "shut off"
  run post_virtual_media_action "$system_url" EjectMedia '{}'
  [ "$status" -eq 0 ]
  [ "$output" = "204" ]
  inactive_xml="$VM_X86_REDFISH_ARTIFACTS_DIR/ejected-domain.xml"
  bounded_virsh dumpxml --inactive "$VM_X86_REDFISH_DOMAIN_NAME" >"$inactive_xml"
  assert_no_cd_device "$inactive_xml"

  for target in Hdd Pxe; do
    run patch_boot_override "$system_url" "$target"
    [ "$status" -eq 0 ]
    [ "$output" = "204" ]
    inactive_xml="$VM_X86_REDFISH_ARTIFACTS_DIR/${target,,}-domain.xml"
    bounded_virsh dumpxml --inactive "$VM_X86_REDFISH_DOMAIN_NAME" >"$inactive_xml"
    assert_first_boot_target "$inactive_xml" "$target"
  done

  start_media_server "$BATS_TEST_TMPDIR/media" interrupted \
    --chunk-size 1024 --chunk-delay 1
  interrupted_url="http://127.0.0.1:${MEDIA_SERVER_PORT}/${iso_name}"
  interrupted_payload="{\"Image\":\"${interrupted_url}\",\"Inserted\":true}"
  tmp_snapshot="$VM_X86_REDFISH_ARTIFACTS_DIR/interrupted-tmp-baseline"
  snapshot_tmp_files "$VM_X86_REDFISH_STATE_DIR/tmp" "$tmp_snapshot"
  post_virtual_media_action "$system_url" InsertMedia "$interrupted_payload" \
    >"$VM_X86_REDFISH_ARTIFACTS_DIR/interrupted-client.log" 2>&1 &
  insert_pid="$!"
  track_child "$insert_pid"
  interrupted_path="$(wait_for_new_tmp_file "$tmp_snapshot" "$VM_X86_REDFISH_STATE_DIR/tmp")"
  [ -f "$interrupted_path" ]

  stop_tracked_child "$sushy_pid"
  insert_status=0
  wait "$insert_pid" || insert_status="$?"
  untrack_child "$insert_pid"
  [ "$insert_status" -ne 0 ]

  destroy_and_assert_virtual_media_cleanup \
    "$domain_uuid" "$interrupted_path" "$nvram_path" "$media_volume" "$inventory_dir"
}

@test "remote PTY serial proves TLS-authenticated Redfish NMI and restart" {
  [ "${VM_X86_REDFISH_INTEGRATION_HELPER_ONLY:-}" != "1" ]
  run run_remote_nmi_with_retries pty none
  [ "$status" -eq 0 ]
}

@test "remote TCP serial proves TLS-authenticated Redfish NMI and restart" {
  [ "${VM_X86_REDFISH_INTEGRATION_HELPER_ONLY:-}" != "1" ]
  run run_remote_nmi_with_retries tcp none
  [ "$status" -eq 0 ]
}

@test "remote PTY serial retries a stolen Redfish port after exact cleanup" {
  [ "${VM_X86_REDFISH_INTEGRATION_HELPER_ONLY:-}" != "1" ]
  run run_remote_nmi_with_retries pty redfish
  [ "$status" -eq 0 ]
  [[ "$output" == *"remote pty attempt 1 hit a verified bind collision; retrying"* ]]
}

@test "remote TCP serial retries a stolen serial port after exact cleanup" {
  [ "${VM_X86_REDFISH_INTEGRATION_HELPER_ONLY:-}" != "1" ]
  run run_remote_nmi_with_retries tcp serial
  [ "$status" -eq 0 ]
  [[ "$output" == *"remote tcp attempt 1 hit a verified bind collision; retrying"* ]]
}
