#!/usr/bin/env bats

load "helpers/test-helper"

setup() {
  setup_test_workspace
  export VM_X86_REDFISH_SOURCE_IMAGE_SHA256=test-source-sha256
}

write_redfish_runtime_state() {
  mkdir -p "$VM_X86_REDFISH_STATE_DIR/tmp" "$VM_X86_REDFISH_STATE_DIR/sushy"
  chmod 700 "$VM_X86_REDFISH_STATE_DIR" "$VM_X86_REDFISH_STATE_DIR/tmp" \
    "$VM_X86_REDFISH_STATE_DIR/sushy"
  printf "REDFISH_USERNAME='admin'\nREDFISH_PASSWORD='redfish-test-password'\n" \
    >"$VM_X86_REDFISH_STATE_DIR/credentials.env"
  printf 'admin:test-hash\n' >"$VM_X86_REDFISH_STATE_DIR/htpasswd"
  printf 'test-cert\n' >"$VM_X86_REDFISH_STATE_DIR/tls.crt"
  printf 'test-key\n' >"$VM_X86_REDFISH_STATE_DIR/tls.key"
  printf "REDFISH_ENDPOINT='https://127.0.0.1:8000'\n" \
    >"$VM_X86_REDFISH_STATE_DIR/connection.env"
  printf "REDFISH_CA_CERT='%s/tls.crt'\n" "$VM_X86_REDFISH_STATE_DIR" \
    >>"$VM_X86_REDFISH_STATE_DIR/connection.env"
  printf "REDFISH_CREDENTIALS_FILE='%s/credentials.env'\n" "$VM_X86_REDFISH_STATE_DIR" \
    >>"$VM_X86_REDFISH_STATE_DIR/connection.env"
  printf "SERIAL_TRANSPORT='pty'\n" >>"$VM_X86_REDFISH_STATE_DIR/connection.env"
  printf "SERIAL_ENDPOINT='libvirt-console://vm-x86-redfish/serial0'\n" \
    >>"$VM_X86_REDFISH_STATE_DIR/connection.env"
  printf 'SUSHY_EMULATOR_LISTEN_IP = "127.0.0.1"\n' \
    >"$VM_X86_REDFISH_STATE_DIR/sushy-emulator.conf.py"
  printf 'SUSHY_EMULATOR_LISTEN_PORT = int("8000")\n' \
    >>"$VM_X86_REDFISH_STATE_DIR/sushy-emulator.conf.py"
  chmod 600 "$VM_X86_REDFISH_STATE_DIR/credentials.env" \
    "$VM_X86_REDFISH_STATE_DIR/htpasswd" \
    "$VM_X86_REDFISH_STATE_DIR/tls.crt" \
    "$VM_X86_REDFISH_STATE_DIR/tls.key" \
    "$VM_X86_REDFISH_STATE_DIR/connection.env" \
    "$VM_X86_REDFISH_STATE_DIR/sushy-emulator.conf.py"
}

@test "render-config rejects unset template values without writing output" {
  template="$BATS_TEST_TMPDIR/template.in"
  mkdir -m 700 "$BATS_TEST_TMPDIR/private"
  output_path="$BATS_TEST_TMPDIR/private/rendered.conf"
  printf 'value=@ROOT_VOLUME_PATH@\n' >"$template"

  run bash -c 'source ./scripts/render-config; unset ROOT_VOLUME_PATH; render_template "$1" "$2"' \
    -- "$template" "$output_path"

  [ "$status" -ne 0 ]
  [[ "$output" == *"unset template value: @ROOT_VOLUME_PATH@"* ]]
  [ ! -e "$output_path" ]
}

@test "render-config rejects unresolved template tokens without writing output" {
  template="$BATS_TEST_TMPDIR/template.in"
  mkdir -m 700 "$BATS_TEST_TMPDIR/private"
  output_path="$BATS_TEST_TMPDIR/private/rendered.conf"
  printf 'value=@MISSING_VALUE@\n' >"$template"

  run bash -c 'source ./scripts/render-config; render_template "$1" "$2"' \
    -- "$template" "$output_path"

  [ "$status" -ne 0 ]
  [[ "$output" == *"unresolved template token: @MISSING_VALUE@"* ]]
  [ ! -e "$output_path" ]
}

@test "render-config writes domain XML with UUID and owner metadata" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf '123e4567-e89b-42d3-a456-426614174000\n' \
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
  run grep -F "<uuid>123e4567-e89b-42d3-a456-426614174000</uuid>" \
    "$BATS_TEST_TMPDIR/state/domain.xml"
  [ "$status" -eq 0 ]
}

@test "render-config creates one COM1 serial console without virtio console targets" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf '123e4567-e89b-42d3-a456-426614174000\n' \
    >"$BATS_TEST_TMPDIR/state/domain-uuid"

  VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    VM_X86_REDFISH_ROOT_VOLUME_PATH="/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
    run ./scripts/render-config domain
  [ "$status" -eq 0 ]

  run grep -Fc "<serial type='pty'>" "$BATS_TEST_TMPDIR/state/domain.xml"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -Fc "<target type='isa-serial' port='0'>" "$BATS_TEST_TMPDIR/state/domain.xml"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -Fc "<model name='isa-serial'/>" "$BATS_TEST_TMPDIR/state/domain.xml"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -Fc "<console type='pty'>" "$BATS_TEST_TMPDIR/state/domain.xml"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -Fc "<target type='serial' port='0'/>" "$BATS_TEST_TMPDIR/state/domain.xml"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run awk '/<console /,/<\/console>/' "$BATS_TEST_TMPDIR/state/domain.xml"
  [ "$status" -eq 0 ]
  [[ "$output" != *"<target type='virtio'"* ]]
}

@test "render-config preserves the default PTY serial and console pair" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf '123e4567-e89b-42d3-a456-426614174000\n' \
    >"$BATS_TEST_TMPDIR/state/domain-uuid"

  VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    VM_X86_REDFISH_ROOT_VOLUME_PATH="/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
    run ./scripts/render-config domain
  [ "$status" -eq 0 ]

  run python3 - "$BATS_TEST_TMPDIR/state/domain.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
serials = root.findall(".//serial")
consoles = root.findall(".//console")
assert len(serials) == 1
assert serials[0].attrib == {"type": "pty"}
assert serials[0].find("target").attrib == {"type": "isa-serial", "port": "0"}
assert serials[0].find("target/model").attrib == {"name": "isa-serial"}
assert len(consoles) == 1
assert consoles[0].attrib == {"type": "pty"}
assert consoles[0].find("target").attrib == {"type": "serial", "port": "0"}
PY
  [ "$status" -eq 0 ]
}

@test "render-config writes default Redfish listen values as Python literals" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf '123e4567-e89b-42d3-a456-426614174000\n' \
    >"$BATS_TEST_TMPDIR/state/domain-uuid"

  VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" run ./scripts/render-config sushy
  [ "$status" -eq 0 ]

  run python3 - "$BATS_TEST_TMPDIR/state/sushy-emulator.conf.py" <<'PY'
import runpy
import sys

config = runpy.run_path(sys.argv[1])
assert config["SUSHY_EMULATOR_LISTEN_IP"] == "127.0.0.1"
assert config["SUSHY_EMULATOR_LISTEN_PORT"] == 8000
PY
  [ "$status" -eq 0 ]
}

@test "render-config writes custom IPv4 and IPv6 Redfish listen values as Python literals" {
  local address
  local port
  for address_port in "192.0.2.10 8443" "2001:db8::10 65535"; do
    read -r address port <<<"$address_port"
    mkdir -p "$BATS_TEST_TMPDIR/state-$port"
    printf '123e4567-e89b-42d3-a456-426614174000\n' \
      >"$BATS_TEST_TMPDIR/state-$port/domain-uuid"

    VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state-$port" \
      VM_X86_REDFISH_LISTEN_IP="$address" \
      VM_X86_REDFISH_LISTEN_PORT="$port" \
      run ./scripts/render-config sushy
    [ "$status" -eq 0 ]

    run python3 - "$BATS_TEST_TMPDIR/state-$port/sushy-emulator.conf.py" "$address" "$port" <<'PY'
import runpy
import sys

config = runpy.run_path(sys.argv[1])
assert config["SUSHY_EMULATOR_LISTEN_IP"] == sys.argv[2]
assert config["SUSHY_EMULATOR_LISTEN_PORT"] == int(sys.argv[3])
PY
    [ "$status" -eq 0 ]
  done
}

@test "render-config writes TCP serial device and matching console" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf '123e4567-e89b-42d3-a456-426614174000\n' \
    >"$BATS_TEST_TMPDIR/state/domain-uuid"

  VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    VM_X86_REDFISH_ROOT_VOLUME_PATH="/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
    VM_X86_REDFISH_SERIAL_MODE=tcp \
    VM_X86_REDFISH_SERIAL_LISTEN_IP="2001:db8::20" \
    VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
    run ./scripts/render-config domain
  [ "$status" -eq 0 ]

  run python3 - "$BATS_TEST_TMPDIR/state/domain.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
serials = root.findall(".//serial")
assert len(serials) == 1
serial = serials[0]
assert serial.attrib == {"type": "tcp"}
sources = serial.findall("source")
assert len(sources) == 1
assert sources[0].attrib == {"mode": "bind", "host": "2001:db8::20", "service": "9000"}
protocols = serial.findall("protocol")
assert len(protocols) == 1
assert protocols[0].attrib == {"type": "raw"}
assert serial.find("target").attrib == {"type": "isa-serial", "port": "0"}
assert serial.find("target/model").attrib == {"name": "isa-serial"}
consoles = root.findall(".//console")
assert len(consoles) == 1
assert consoles[0].attrib == {"type": "tcp"}
console_sources = consoles[0].findall("source")
assert len(console_sources) == 1
assert console_sources[0].attrib == {"mode": "bind", "host": "2001:db8::20", "service": "9000"}
console_protocols = consoles[0].findall("protocol")
assert len(console_protocols) == 1
assert console_protocols[0].attrib == {"type": "raw"}
assert consoles[0].find("target").attrib == {"type": "serial", "port": "0"}
assert not root.findall(".//serial[@type='pty']")
PY
  [ "$status" -eq 0 ]
}

@test "render-config writes stable serial metadata for PTY and TCP serial modes" {
  local state_dir
  for mode in pty tcp; do
    state_dir="$BATS_TEST_TMPDIR/$mode-state"
    mkdir -p "$state_dir"
    printf '123e4567-e89b-42d3-a456-426614174000\n' >"$state_dir/domain-uuid"

    if [ "$mode" = tcp ]; then
      VM_X86_REDFISH_STATE_DIR="$state_dir" \
        VM_X86_REDFISH_ROOT_VOLUME_PATH="/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
        VM_X86_REDFISH_SERIAL_MODE=tcp \
        VM_X86_REDFISH_SERIAL_LISTEN_IP="192.0.2.20" \
        VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
        run ./scripts/render-config domain
    else
      VM_X86_REDFISH_STATE_DIR="$state_dir" \
        VM_X86_REDFISH_ROOT_VOLUME_PATH="/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
        run ./scripts/render-config domain
    fi
    [ "$status" -eq 0 ]

    run python3 - "$state_dir/domain.xml" "$mode" <<'PY'
import sys
import xml.etree.ElementTree as ET

namespace = "https://github.com/randomparity/vm-x86-redfish"
root = ET.parse(sys.argv[1]).getroot()
metadata = root.find(f"metadata/{{{namespace}}}vm-x86-redfish")
assert metadata is not None
actual = {child.tag.removeprefix(f"{{{namespace}}}"): child.text or "" for child in metadata}
assert actual["serial-mode"] == sys.argv[2]
if sys.argv[2] == "tcp":
    assert actual["serial-listen-ip"] == "192.0.2.20"
    assert actual["serial-listen-port"] == "9000"
else:
    assert actual["serial-listen-ip"] == ""
    assert actual["serial-listen-port"] == ""
PY
    [ "$status" -eq 0 ]
  done
}

@test "render-config rejects a missing root volume path without writing domain XML" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf '123e4567-e89b-42d3-a456-426614174000\n' \
    >"$BATS_TEST_TMPDIR/state/domain-uuid"

  run env VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" ./scripts/render-config domain

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing root volume path"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/state/domain.xml" ]
}

@test "render-config rejects a missing domain UUID without writing domain XML" {
  mkdir -p "$BATS_TEST_TMPDIR/state"

  VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    VM_X86_REDFISH_ROOT_VOLUME_PATH="/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
    run ./scripts/render-config domain

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing domain UUID file"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/state/domain.xml" ]
}

@test "render-config rejects a malformed domain UUID without writing domain XML" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf 'not-a-uuid\n' >"$BATS_TEST_TMPDIR/state/domain-uuid"

  VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    VM_X86_REDFISH_ROOT_VOLUME_PATH="/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
    run ./scripts/render-config domain

  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid domain UUID"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/state/domain.xml" ]
}

@test "render-config rejects a symlinked domain UUID without writing domain XML" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf '123e4567-e89b-42d3-a456-426614174000\n' \
    >"$BATS_TEST_TMPDIR/outside-domain-uuid"
  ln -s "$BATS_TEST_TMPDIR/outside-domain-uuid" "$BATS_TEST_TMPDIR/state/domain-uuid"

  VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    VM_X86_REDFISH_ROOT_VOLUME_PATH="/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
    run ./scripts/render-config domain

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected project state file"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/state/domain.xml" ]
}

@test "render-config rejects symlinked domain XML output before writing through it" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf '123e4567-e89b-42d3-a456-426614174000\n' \
    >"$BATS_TEST_TMPDIR/state/domain-uuid"
  printf 'outside\n' >"$BATS_TEST_TMPDIR/outside-domain.xml"
  ln -s "$BATS_TEST_TMPDIR/outside-domain.xml" "$BATS_TEST_TMPDIR/state/domain.xml"

  VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" \
    VM_X86_REDFISH_ROOT_VOLUME_PATH="/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
    run ./scripts/render-config domain

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected project state file"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/outside-domain.xml")" = "outside" ]
}

@test "render-config finds its domain template outside the repository root" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf '123e4567-e89b-42d3-a456-426614174000\n' \
    >"$BATS_TEST_TMPDIR/state/domain-uuid"

  run bash -c 'cd / && VM_X86_REDFISH_STATE_DIR="$1" \
    VM_X86_REDFISH_ROOT_VOLUME_PATH="/var/lib/libvirt/images/vm-x86-redfish.qcow2" "$2" domain' \
    -- "$BATS_TEST_TMPDIR/state" "$BATS_TEST_DIRNAME/../scripts/render-config"

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/domain.xml" ]
}

@test "render-config writes Sushy config with private runtime directories" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf '123e4567-e89b-42d3-a456-426614174000\n' \
    >"$BATS_TEST_TMPDIR/state/domain-uuid"

  VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" run ./scripts/render-config sushy

  [ "$status" -eq 0 ]
  [ "$(stat -c "%a" "$BATS_TEST_TMPDIR/state/sushy")" = "700" ]
  [ "$(stat -c "%a" "$BATS_TEST_TMPDIR/state/tmp")" = "700" ]
  run grep -F 'SUSHY_EMULATOR_ALLOWED_INSTANCES = ["123e4567-e89b-42d3-a456-426614174000"]' \
    "$BATS_TEST_TMPDIR/state/sushy-emulator.conf.py"
  [ "$status" -eq 0 ]
  run grep -F "SUSHY_EMULATOR_STATE_DIR = \"$BATS_TEST_TMPDIR/state/sushy\"" \
    "$BATS_TEST_TMPDIR/state/sushy-emulator.conf.py"
  [ "$status" -eq 0 ]
}

@test "render-config rejects symlinked Sushy config output before writing through it" {
  mkdir -p "$BATS_TEST_TMPDIR/state"
  printf '123e4567-e89b-42d3-a456-426614174000\n' \
    >"$BATS_TEST_TMPDIR/state/domain-uuid"
  printf 'outside\n' >"$BATS_TEST_TMPDIR/outside-sushy.conf.py"
  ln -s "$BATS_TEST_TMPDIR/outside-sushy.conf.py" \
    "$BATS_TEST_TMPDIR/state/sushy-emulator.conf.py"

  VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state" run ./scripts/render-config sushy

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected project state file"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/outside-sushy.conf.py")" = "outside" ]
}

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
  write_redfish_runtime_state
  install_mock_command uv \
    'case "$*" in
      "python find 3.13") command -v python3 ;;
      *) printf "TMPDIR=%s\nPYTHONPATH=%s\nCONFIG=%s\n" "$TMPDIR" "$PYTHONPATH" "$*" ;;
    esac'
  run ./scripts/run-redfish
  [ "$status" -eq 0 ]
  [[ "$output" == *"TMPDIR=$VM_X86_REDFISH_STATE_DIR/tmp"* ]]
  [[ "$output" == *"PYTHONPATH=$REPO_ROOT/python"* ]]
  [[ "$output" == *run\ --locked\ sushy-emulator\ --config\ */sushy-emulator.conf.py* ]]
  [[ "$output" == *"run: Redfish endpoint https://127.0.0.1:8000"* ]]
  [[ "$output" == *"run: serial endpoint libvirt-console://vm-x86-redfish/serial0"* ]]
  [[ "$output" != *"warning:"* ]]
}

@test "run-redfish warns and reports persisted nonloopback and TCP endpoints before exec" {
  write_redfish_runtime_state
  sed -i \
    -e "s|https://127.0.0.1:8000|https://192.0.2.20:8443|" \
    -e "s|SERIAL_TRANSPORT='pty'|SERIAL_TRANSPORT='tcp'|" \
    -e "s|libvirt-console://vm-x86-redfish/serial0|tcp://[2001:db8::20]:9000|" \
    "$VM_X86_REDFISH_STATE_DIR/connection.env"
  sed -i \
    -e 's|"127.0.0.1"|"192.0.2.20"|' \
    -e 's|"8000"|"8443"|' \
    "$VM_X86_REDFISH_STATE_DIR/sushy-emulator.conf.py"
  install_mock_command uv \
    'case "$*" in
      "python find 3.13") command -v python3 ;;
      *) printf "EXEC=%s\n" "$*" ;;
    esac'

  run ./scripts/run-redfish

  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: non-loopback Redfish listener at https://192.0.2.20:8443"* ]]
  [[ "$output" == *"plaintext TCP serial listener at tcp://[2001:db8::20]:9000"* ]]
  [[ "$output" == *"run: Redfish endpoint https://192.0.2.20:8443"* ]]
  [[ "$output" == *$'run: serial endpoint tcp://[2001:db8::20]:9000\nEXEC=run --locked'* ]]
}

@test "run-redfish rejects supplied endpoint settings that disagree with persisted state" {
  write_redfish_runtime_state
  install_mock_command uv \
    'case "$*" in
      "python find 3.13") command -v python3 ;;
      *) printf "unexpected exec\n" ;;
    esac'

  VM_X86_REDFISH_LISTEN_PORT=8443 run ./scripts/run-redfish

  [ "$status" -ne 0 ]
  [[ "$output" == *"VM_X86_REDFISH_LISTEN_PORT disagrees with persisted Redfish endpoint"* ]]
  [[ "$output" != *"unexpected exec"* ]]
}

@test "run-redfish rejects malformed connection metadata without evaluating it" {
  local sentinel="$BATS_TEST_TMPDIR/metadata-was-evaluated"
  write_redfish_runtime_state
  printf 'REDFISH_ENDPOINT=$(touch %s)\n' "$sentinel" \
    >"$VM_X86_REDFISH_STATE_DIR/connection.env"
  chmod 600 "$VM_X86_REDFISH_STATE_DIR/connection.env"
  install_mock_command uv \
    'case "$*" in
      "python find 3.13") command -v python3 ;;
      *) printf "unexpected exec\n" ;;
    esac'

  run ./scripts/run-redfish

  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed Redfish connection metadata"* ]]
  [ ! -e "$sentinel" ]
  [[ "$output" != *"unexpected exec"* ]]
}

@test "run-redfish rejects loose Redfish runtime files" {
  write_redfish_runtime_state
  chmod 644 "$VM_X86_REDFISH_STATE_DIR/tls.key"

  run ./scripts/run-redfish

  [ "$status" -ne 0 ]
  [[ "$output" == *"file must be mode 0600"* ]]
}

@test "run-redfish rejects unguarded runtime overrides" {
  run env -u VM_X86_REDFISH_INTEGRATION_TEST \
    VM_X86_REDFISH_DOMAIN_NAME=test-domain ./scripts/run-redfish
  [ "$status" -ne 0 ]
  [[ "$output" == *"test-only overrides require VM_X86_REDFISH_INTEGRATION_TEST=1"* ]]
}

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
  rmdir "$BATS_TEST_TMPDIR/state"
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
  [ "$output" = \
    "vm-x86-redfish-media-fedora-iso-11111111-2222-3333-4444-555555555555.img" ]
}

@test "write_secret_file rejects a symlinked file path" {
  mkdir -m 700 "$BATS_TEST_TMPDIR/private"
  touch "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$BATS_TEST_TMPDIR/private/secret"

  run bash -c '
    source scripts/lib/common
    write_secret_file "$BATS_TEST_TMPDIR/private/secret" "secret"
  '

  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing symlink"* ]]
}

@test "write_secret_file rejects a non-private parent directory" {
  mkdir -m 755 "$BATS_TEST_TMPDIR/loose"

  run bash -c '
    source scripts/lib/common
    write_secret_file "$BATS_TEST_TMPDIR/loose/secret" "secret"
  '

  [ "$status" -ne 0 ]
  [[ "$output" == *"directory must be mode 0700"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/loose/secret" ]
}

@test "with_lifecycle_lock rejects a symlinked file path" {
  mkdir -m 700 "$BATS_TEST_TMPDIR/private"
  touch "$BATS_TEST_TMPDIR/target"
  ln -s "$BATS_TEST_TMPDIR/target" "$BATS_TEST_TMPDIR/private/lifecycle.lock"

  run bash -c '
    source scripts/lib/common
    with_lifecycle_lock "$BATS_TEST_TMPDIR/private/lifecycle.lock" true
  '

  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing symlink"* ]]
}

@test "with_lifecycle_lock creates a missing private parent directory" {
  run bash -c '
    source scripts/lib/common
    with_lifecycle_lock "$BATS_TEST_TMPDIR/new-state/lifecycle.lock" true
    stat -c "%a %F" "$BATS_TEST_TMPDIR/new-state"
    test -f "$BATS_TEST_TMPDIR/new-state/lifecycle.lock"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "700 directory" ]
}

@test "with_lifecycle_lock normalizes an existing parent directory" {
  mkdir -m 755 "$BATS_TEST_TMPDIR/loose"

  run bash -c '
    source scripts/lib/common
    with_lifecycle_lock "$BATS_TEST_TMPDIR/loose/lifecycle.lock" true
    stat -c "%a %F" "$BATS_TEST_TMPDIR/loose"
    test -f "$BATS_TEST_TMPDIR/loose/lifecycle.lock"
  '

  [ "$status" -eq 0 ]
  [ "$output" = "700 directory" ]
}

@test "media volume name strips signed URL query before basename" {
  run bash -c '
    source scripts/lib/common
    volume_name_for_media "https://example.test/images/fedora.iso?X-Amz-Credential=a/b" \
      "11111111-2222-3333-4444-555555555555"
  '

  [ "$status" -eq 0 ]
  [ "$output" = \
    "vm-x86-redfish-media-fedora-iso-11111111-2222-3333-4444-555555555555.img" ]
}

@test "runtime configuration rejects production test overrides" {
  run env \
    -u VM_X86_REDFISH_INTEGRATION_TEST \
    -u VM_X86_REDFISH_STATE_DIR \
    -u VM_X86_REDFISH_ARTIFACTS_DIR \
    VM_X86_REDFISH_DOMAIN_NAME=test-domain \
    bash -c 'source scripts/lib/common'

  [ "$status" -ne 0 ]
  [[ "$output" == *"test-only overrides require VM_X86_REDFISH_INTEGRATION_TEST=1"* ]]
}

@test "runtime configuration permits integration test overrides" {
  run env \
    VM_X86_REDFISH_INTEGRATION_TEST=1 \
    VM_X86_REDFISH_DOMAIN_NAME=test-domain \
    bash -c 'source scripts/lib/common; printf "%s" "$DEFAULT_DOMAIN_NAME"'

  [ "$status" -eq 0 ]
  [ "$output" = "test-domain" ]
}
