#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # Bats isolates PATH changes to each test process.

load "helpers/test-helper"

setup() {
  setup_integration_workspace
  export TEST_ID="redfish-${BATS_TEST_NUMBER}-$$"
  export VM_X86_REDFISH_INTEGRATION_TEST=1
  export VM_X86_REDFISH_DOMAIN_NAME="vm-x86-redfish-${TEST_ID}"
  export VM_X86_REDFISH_ROOT_VOLUME_NAME="vm-x86-redfish-${TEST_ID}.qcow2"
  export VM_X86_REDFISH_ARTIFACTS_DIR=".artifacts/${TEST_ID}"
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
  sed "s/@SENTINEL@/${sentinel}/" tests/fixtures/grub.cfg.in \
    >"$iso_root/boot/grub/grub.cfg"
  grub2-mkrescue -o "$iso_path" "$iso_root" \
    >"$VM_X86_REDFISH_ARTIFACTS_DIR/grub2-mkrescue.log" 2>&1
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

wait_for_tmp_file() {
  local tmpdir="$1"
  local deadline=$((SECONDS + 30))
  local path
  while [ "$SECONDS" -lt "$deadline" ]; do
    while IFS= read -r -d '' path; do
      printf '%s\n' "$path"
      return 0
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

capture_volume_inventory() {
  local destination="$1"
  local inventory
  if ! inventory="$(bounded_virsh vol-list --pool "$STORAGE_POOL")"; then
    printf 'failed to capture libvirt volume inventory for pool %s\n' \
      "$STORAGE_POOL" >&2
    return 1
  fi
  printf '%s\n' "$inventory" | awk 'NR > 2 && NF { print $1 }' |
    LC_ALL=C sort >"$destination"
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
    if [[ "$volume" = *-"$domain_uuid".img ]]; then
      printf 'UUID media volume still exists: %s\n' "$volume" >&2
      return 1
    fi
  done
}

run_serial_console() {
  local python_bin
  python_bin="$(python_313)"
  "$python_bin" - "$LIBVIRT_URI" "$VM_X86_REDFISH_DOMAIN_NAME" <<'PY'
import errno
import os
import pty
import select
import signal
import sys
import time

uri, domain = sys.argv[1:]
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

deadline = time.monotonic() + 70
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
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    else:
        os.killpg(pid, signal.SIGTERM)
        time.sleep(1)
        os.killpg(pid, signal.SIGKILL)
        raise SystemExit(124)
finally:
    os.close(master_fd)
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        pass

if status is None:
    raise SystemExit(1)
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
    printf "%s %s\n" unrelated.qcow2 /var/lib/libvirt/images/unrelated.qcow2
    printf "%s %s\n" vm-x86-redfish-near-match.qcow2 /var/lib/libvirt/images/near
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

@test "authenticated Redfish controls isolated libvirt domain power" {
  run timeout --kill-after=5 120 ./scripts/create-vm
  [ "$status" -eq 0 ]

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
  start_media_server "$BATS_TEST_TMPDIR/media" sentinel-https \
    --tls-cert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    --tls-key "$VM_X86_REDFISH_STATE_DIR/tls.key"
  tls_media_port="$MEDIA_SERVER_PORT"

  start_sushy
  sushy_pid="$SUSHY_PID"

  run bounded_curl --silent --show-error --fail --insecure --output /dev/null \
    "https://127.0.0.1:${tls_media_port}/${iso_name}"
  [ "$status" -eq 0 ]
  untrusted_payload="{\"Image\":\"https://127.0.0.1:${tls_media_port}/${iso_name}\",\
\"Inserted\":true}"
  run post_virtual_media_action "$system_url" InsertMedia "$untrusted_payload"
  [ "$status" -eq 0 ]
  [ "$output" = "500" ]

  media_url="http://127.0.0.1:${media_port}/${iso_name}"
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
  post_virtual_media_action "$system_url" InsertMedia "$interrupted_payload" \
    >"$VM_X86_REDFISH_ARTIFACTS_DIR/interrupted-client.log" 2>&1 &
  insert_pid="$!"
  track_child "$insert_pid"
  interrupted_path="$(wait_for_tmp_file "$VM_X86_REDFISH_STATE_DIR/tmp")"
  [ -f "$interrupted_path" ]

  stop_tracked_child "$sushy_pid"
  insert_status=0
  wait "$insert_pid" || insert_status="$?"
  untrack_child "$insert_pid"
  [ "$insert_status" -ne 0 ]

  destroy_and_assert_virtual_media_cleanup \
    "$domain_uuid" "$interrupted_path" "$nvram_path" "$media_volume" "$inventory_dir"
}
