#!/usr/bin/env bats

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
  until state="$(virsh -c "$LIBVIRT_URI" domstate "$VM_X86_REDFISH_DOMAIN_NAME")" &&
    [ "$state" = "$expected" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

post_reset() {
  local system_url="$1"
  local reset_type="$2"
  curl --silent --show-error --fail \
    --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    --user "${REDFISH_USERNAME}:${REDFISH_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{\"ResetType\":\"${reset_type}\"}" \
    "https://127.0.0.1:8000${system_url}/Actions/ComputerSystem.Reset"
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

@test "integration harness installs cleanup helpers before live mutation" {
  run declare -F stop_tracked_children
  [ "$status" -eq 0 ]
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

  run ./scripts/destroy-vm
  [ "$status" -eq 0 ]
}

@test "authenticated Redfish controls isolated libvirt domain power" {
  run ./scripts/create-vm
  [ "$status" -eq 0 ]

  ./scripts/run-redfish >"$VM_X86_REDFISH_ARTIFACTS_DIR/sushy.log" 2>&1 &
  sushy_pid="$!"
  track_child "$sushy_pid"

  wait_for_url "https://127.0.0.1:8000/redfish/v1"
  run curl --silent --show-error --fail \
    --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    "https://127.0.0.1:8000/redfish/v1"
  [ "$status" -eq 0 ]

  run curl --silent --output /dev/null --write-out '%{http_code}' \
    --cacert "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    "https://127.0.0.1:8000/redfish/v1/Systems"
  [ "$status" -eq 0 ]
  [ "$output" = "401" ]

  # shellcheck disable=SC1091 # create-vm writes this test-specific credentials file.
  source "$VM_X86_REDFISH_STATE_DIR/credentials.env"
  systems_json="$VM_X86_REDFISH_ARTIFACTS_DIR/systems.json"
  curl --silent --show-error --fail \
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

  post_reset "$system_url" On
  wait_for_domain_state running
  post_reset "$system_url" ForceRestart
  wait_for_domain_state running
  post_reset "$system_url" ForceOff
  wait_for_domain_state "shut off"
}
