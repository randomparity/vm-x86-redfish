#!/usr/bin/env bats

load "helpers/test-helper"

setup() {
  setup_test_workspace
  export VM_X86_REDFISH_SOURCE_IMAGE="$BATS_TEST_TMPDIR/source.qcow2"
  printf 'test qcow2 image\n' >"$VM_X86_REDFISH_SOURCE_IMAGE"
  export VM_X86_REDFISH_TEST_SOURCE_SHA256
  VM_X86_REDFISH_TEST_SOURCE_SHA256="$(sha256sum "$VM_X86_REDFISH_SOURCE_IMAGE")"
  VM_X86_REDFISH_TEST_SOURCE_SHA256="${VM_X86_REDFISH_TEST_SOURCE_SHA256%% *}"
  export VM_X86_REDFISH_SOURCE_IMAGE_SHA256="$VM_X86_REDFISH_TEST_SOURCE_SHA256"
  install_mock_command qemu-img '
case "$*" in
  "info --output=json "*) printf '\''{"format":"qcow2","virtual-size":8589934592}\n'\'' ;;
  *) exit 2 ;;
esac
'
  install_mock_command uuidgen \
    'printf "uuidgen\\n" >>"$BATS_TEST_TMPDIR/commands.log"
printf "11111111-2222-3333-8444-555555555555\\n"'
  install_redfish_state_mocks
}

install_redfish_state_mocks() {
  install_mock_command openssl '
printf "openssl %s\\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  "rand -base64 30")
    printf "redfish-test-password\\n"
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
    printf "test-key\\n" >"$key"
    printf "test-cert\\n" >"$cert"
    ;;
  x509*)
    exit "${VM_X86_REDFISH_OPENSSL_CHECKIP_STATUS:-0}"
    ;;
  *)
    exit 2
    ;;
esac
'
  install_mock_command htpasswd '
printf "htpasswd %s\\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
[ "$1" = "-iB" ]
[ "$2" = "-c" ]
read -r password
[ "$password" = "redfish-test-password" ]
printf "admin:test-hash\\n" >"$3"
'
}

install_create_success_mocks() {
  install_mock_command virsh '
printf "virsh %s\\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2")
    exit 1
    ;;
  *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2")
    exit 0
    ;;
  *"vol-upload "*|*"pool-refresh "*|*"vol-resize "*)
    exit 0
    ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\\n"
    ;;
  *"define "*"/domain.xml")
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
'
}

write_existing_domain_xml() {
  local extra_devices root_path root_volume_name serial_devices serial_listen_ip
  local serial_listen_port serial_metadata serial_mode target_path
  target_path="$1"
  root_volume_name="${2:-vm-x86-redfish.qcow2}"
  root_path="${3:-/var/lib/libvirt/images/vm-x86-redfish.qcow2}"
  extra_devices="${4:-}"
  serial_mode="${5:-pty}"
  serial_listen_ip="${6:-}"
  serial_listen_port="${7:-}"
  case "$serial_mode" in
  pty)
    serial_devices='<serial type="pty">
      <target type="isa-serial" port="0"><model name="isa-serial"/></target>
    </serial>
    <console type="pty">
      <target type="serial" port="0"/>
    </console>'
    ;;
  tcp)
    serial_devices="<serial type=\"tcp\">
      <source mode=\"bind\" host=\"${serial_listen_ip}\" service=\"${serial_listen_port}\"/>
      <protocol type=\"raw\"/>
      <target type=\"isa-serial\" port=\"0\"><model name=\"isa-serial\"/></target>
    </serial>
    <console type=\"tcp\">
      <source mode=\"bind\" host=\"${serial_listen_ip}\" service=\"${serial_listen_port}\"/>
      <protocol type=\"raw\"/>
      <target type=\"serial\" port=\"0\"/>
    </console>"
    ;;
  *)
    return 1
    ;;
  esac
  serial_metadata="      <rp:serial-mode>${serial_mode}</rp:serial-mode>
      <rp:serial-listen-ip>${serial_listen_ip}</rp:serial-listen-ip>
      <rp:serial-listen-port>${serial_listen_port}</rp:serial-listen-port>"
  cat >"$target_path" <<XML
<domain type="kvm" xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
  <name>vm-x86-redfish</name>
  <uuid>11111111-2222-3333-8444-555555555555</uuid>
  <metadata>
    <rp:vm-x86-redfish>
      <rp:project>vm-x86-redfish</rp:project>
      <rp:root-volume>${root_volume_name}</rp:root-volume>
      <rp:memory-mib>4096</rp:memory-mib>
      <rp:root-disk-gib>40</rp:root-disk-gib>
      <rp:source-image-sha256>${VM_X86_REDFISH_TEST_SOURCE_SHA256}</rp:source-image-sha256>
${serial_metadata}
    </rp:vm-x86-redfish>
  </metadata>
  <memory unit="MiB">4096</memory>
  <vcpu placement="static">2</vcpu>
  <os firmware="efi">
    <type arch="x86_64" machine="q35">hvm</type>
    <firmware><feature enabled="no" name="secure-boot"/></firmware>
    <boot dev="hd"/>
  </os>
  <cpu mode="host-passthrough" check="none"/>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2" discard="unmap"/>
      <source file="${root_path}"/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <interface type="network">
      <source network="default"/>
      <model type="virtio"/>
    </interface>
${serial_devices}
    <channel type="unix">
      <target type="virtio" name="org.qemu.guest_agent.0"/>
    </channel>
    <graphics type="vnc" listen="127.0.0.1"/>
    <video><model type="virtio"/></video>
${extra_devices}
  </devices>
</domain>
XML
}

install_existing_domain_mocks() {
  local serial_listen_ip="${2:-}"
  local serial_listen_port="${3:-}"
  local serial_mode="${1:-pty}"
  printf '11111111-2222-3333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  write_existing_domain_xml "$BATS_TEST_TMPDIR/existing-domain.xml" "" "" "" \
    "$serial_mode" "$serial_listen_ip" "$serial_listen_port"
  install_mock_command virsh '
printf "virsh %s\\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish")
    exit 0
    ;;
  *"dumpxml vm-x86-redfish"*)
    cat "$BATS_TEST_TMPDIR/existing-domain.xml"
    ;;
  *"vol-info --pool default vm-x86-redfish.qcow2")
    exit 0
    ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\\n"
    ;;
  *)
    exit 0
    ;;
esac
'
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

@test "create-vm generates TLS SANs for canonical Redfish listener addresses" {
  local address expected_san
  local case_name
  for case_name in loopback ipv4 ipv6; do
    case "$case_name" in
    loopback)
      address="127.0.0.1"
      expected_san="DNS:localhost,IP:127.0.0.1"
      ;;
    ipv4)
      address="192.0.2.20"
      expected_san="DNS:localhost,IP:127.0.0.1,IP:192.0.2.20"
      ;;
    ipv6)
      address="2001:db8::20"
      expected_san="DNS:localhost,IP:127.0.0.1,IP:2001:db8::20"
      ;;
    esac
    install_create_success_mocks
    : >"$BATS_TEST_TMPDIR/commands.log"

    VM_X86_REDFISH_LISTEN_IP="$address" run ./scripts/create-vm

    [ "$status" -eq 0 ]
    run grep -F "subjectAltName=${expected_san}" "$BATS_TEST_TMPDIR/commands.log"
    [ "$status" -eq 0 ]
    [ "$(grep -o 'IP:127.0.0.1' "$BATS_TEST_TMPDIR/commands.log" | wc -l)" -eq 1 ]
    unlink "$VM_X86_REDFISH_STATE_DIR/tls.crt"
    unlink "$VM_X86_REDFISH_STATE_DIR/tls.key"
  done
}

@test "create-vm reuses TLS SAN identity matching the configured listener" {
  install_existing_domain_mocks
  printf 'test-cert\n' >"$VM_X86_REDFISH_STATE_DIR/tls.crt"
  printf 'test-key\n' >"$VM_X86_REDFISH_STATE_DIR/tls.key"
  chmod 600 "$VM_X86_REDFISH_STATE_DIR/tls.crt" "$VM_X86_REDFISH_STATE_DIR/tls.key"

  VM_X86_REDFISH_LISTEN_IP=192.0.2.20 run ./scripts/create-vm

  [ "$status" -eq 0 ]
  run grep -F "x509 -checkip 192.0.2.20 -noout" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -eq 0 ]
  run grep -F "openssl req" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
}

@test "create-vm rejects mismatched TLS SAN identity without replacing it" {
  local cert_before domain_uuid_before key_before state_path
  install_existing_domain_mocks
  printf 'test-cert\n' >"$VM_X86_REDFISH_STATE_DIR/tls.crt"
  printf 'test-key\n' >"$VM_X86_REDFISH_STATE_DIR/tls.key"
  chmod 600 "$VM_X86_REDFISH_STATE_DIR/tls.crt" "$VM_X86_REDFISH_STATE_DIR/tls.key"
  cert_before="$(<"$VM_X86_REDFISH_STATE_DIR/tls.crt")"
  domain_uuid_before="$(<"$VM_X86_REDFISH_STATE_DIR/domain-uuid")"
  key_before="$(<"$VM_X86_REDFISH_STATE_DIR/tls.key")"

  VM_X86_REDFISH_OPENSSL_CHECKIP_STATUS=1 \
    VM_X86_REDFISH_LISTEN_IP=192.0.2.20 \
    run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"does not cover configured Redfish listener 192.0.2.20"* ]]
  [[ "$output" == *"destroy and recreate"* ]]
  [ "$(<"$VM_X86_REDFISH_STATE_DIR/tls.crt")" = "$cert_before" ]
  [ "$(<"$VM_X86_REDFISH_STATE_DIR/tls.key")" = "$key_before" ]
  [ "$(<"$VM_X86_REDFISH_STATE_DIR/domain-uuid")" = "$domain_uuid_before" ]
  for state_path in credentials.env htpasswd connection.env sushy-emulator.conf.py; do
    [ ! -e "$VM_X86_REDFISH_STATE_DIR/$state_path" ]
  done
}

@test "create-vm reports TLS SAN verification errors" {
  install_existing_domain_mocks
  printf 'test-cert\n' >"$VM_X86_REDFISH_STATE_DIR/tls.crt"
  printf 'test-key\n' >"$VM_X86_REDFISH_STATE_DIR/tls.key"
  chmod 600 "$VM_X86_REDFISH_STATE_DIR/tls.crt" "$VM_X86_REDFISH_STATE_DIR/tls.key"

  VM_X86_REDFISH_OPENSSL_CHECKIP_STATUS=2 run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to verify Redfish TLS certificate"* ]]
}

@test "create-vm rolls back a TLS SAN identity when publishing its key fails" {
  local tmp_tls
  install_existing_domain_mocks
  install_mock_command mv '
destination="${!#}"
if [ "$destination" = "$VM_X86_REDFISH_STATE_DIR/tls.key" ]; then
  exit 1
fi
/usr/bin/mv "$@"
'

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/tls.crt" ]
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/tls.key" ]
  shopt -s nullglob
  tmp_tls=("$VM_X86_REDFISH_STATE_DIR"/.tls.*)
  [ "${#tmp_tls[@]}" -eq 0 ]
}

@test "create-vm writes source-safe default connection metadata" {
  local connection_path expected_ca expected_credentials
  export VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/state'quoted"
  mkdir -p "$VM_X86_REDFISH_STATE_DIR"
  install_create_success_mocks

  run ./scripts/create-vm

  [ "$status" -eq 0 ]
  connection_path="$VM_X86_REDFISH_STATE_DIR/connection.env"
  expected_ca="$VM_X86_REDFISH_STATE_DIR/tls.crt"
  expected_credentials="$VM_X86_REDFISH_STATE_DIR/credentials.env"
  [ "$(stat -c '%a' "$connection_path")" = "600" ]
  run bash -c '
set -euo pipefail
source "$1"
printf "%s|%s|%s|%s|%s\\n" \
  "$REDFISH_ENDPOINT" "$REDFISH_CA_CERT" "$REDFISH_CREDENTIALS_FILE" \
  "$SERIAL_TRANSPORT" "$SERIAL_ENDPOINT"
' bash "$connection_path"
  [ "$status" -eq 0 ]
  [ "$output" = "https://127.0.0.1:8000|${expected_ca}|${expected_credentials}|pty|libvirt-console://vm-x86-redfish/serial0" ]
}

@test "create-vm writes TCP IPv6 connection metadata" {
  local connection_path
  install_create_success_mocks

  VM_X86_REDFISH_LISTEN_IP=2001:db8::20 \
    VM_X86_REDFISH_LISTEN_PORT=8443 \
    VM_X86_REDFISH_SERIAL_MODE=tcp \
    VM_X86_REDFISH_SERIAL_LISTEN_IP=2001:db8::21 \
    VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
    run ./scripts/create-vm

  [ "$status" -eq 0 ]
  connection_path="$VM_X86_REDFISH_STATE_DIR/connection.env"
  run bash -c '
set -euo pipefail
source "$1"
printf "%s|%s|%s\\n" "$REDFISH_ENDPOINT" "$SERIAL_TRANSPORT" "$SERIAL_ENDPOINT"
' bash "$connection_path"
  [ "$status" -eq 0 ]
  [ "$output" = "https://[2001:db8::20]:8443|tcp|tcp://[2001:db8::21]:9000" ]
}

@test "create-vm repairs missing Redfish state for valid existing domain" {
  install_existing_domain_mocks

  run ./scripts/create-vm

  [ "$status" -eq 0 ]
  [ -f "$VM_X86_REDFISH_STATE_DIR/credentials.env" ]
  [ -f "$VM_X86_REDFISH_STATE_DIR/sushy-emulator.conf.py" ]
}

@test "create-vm accepts a matching TCP serial transport on rerun" {
  install_existing_domain_mocks tcp 192.0.2.20 9000

  VM_X86_REDFISH_SERIAL_MODE=tcp \
    VM_X86_REDFISH_SERIAL_LISTEN_IP=192.0.2.20 \
    VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
    run ./scripts/create-vm

  [ "$status" -eq 0 ]
}

@test "create-vm rejects incompatible serial transports before rewriting runtime state" {
  local case_name
  local duplicate_serial
  for case_name in mode address port protocol source-mode duplicate-serial missing-console \
    metadata-device-disagreement; do
    install_existing_domain_mocks tcp 192.0.2.20 9000
    case "$case_name" in
    mode)
      sed -i 's/type="tcp"/type="pty"/' "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    address)
      sed -i 's/host="192.0.2.20"/host="192.0.2.21"/g' \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    port)
      sed -i 's/service="9000"/service="9001"/g' \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    protocol)
      sed -i '0,/protocol type="raw"/s//protocol type="telnet"/' \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    source-mode)
      sed -i '0,/source mode="bind"/s//source mode="connect"/' \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    duplicate-serial)
      duplicate_serial='<serial type="pty"><target type="isa-serial" port="1"/></serial>'
      sed -i "/<channel type=\"unix\">/i\\    ${duplicate_serial}" \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    missing-console)
      sed -i '/    <console type="tcp">/,/    <\/console>/d' \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    metadata-device-disagreement)
      sed -i 's/<rp:serial-listen-ip>192.0.2.20/<rp:serial-listen-ip>192.0.2.21/' \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    esac

    : >"$BATS_TEST_TMPDIR/commands.log"
    VM_X86_REDFISH_SERIAL_MODE=tcp \
      VM_X86_REDFISH_SERIAL_LISTEN_IP=192.0.2.20 \
      VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
      run ./scripts/create-vm

    [ "$status" -ne 0 ]
    [[ "$output" == *"configured tcp serial transport"* ]]
    [[ "$output" == *"destroy and recreate"* ]]
    run grep -F "htpasswd -iB -c" "$BATS_TEST_TMPDIR/commands.log"
    [ "$status" -ne 0 ]
  done
}

@test "create-vm rejects noncanonical serial and console children and attributes" {
  local case_name
  local console_target
  local serial_model
  local serial_target
  for case_name in serial-child console-child serial-attribute console-attribute \
    serial-target-attribute console-target-attribute serial-model-attribute; do
    install_existing_domain_mocks tcp 192.0.2.20 9000
    case "$case_name" in
    serial-child)
      sed -i '/    <\/serial>/i\      <log file="/tmp/serial.log"/>' \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    console-child)
      sed -i '/    <\/console>/i\      <log file="/tmp/console.log"/>' \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    serial-attribute)
      sed -i '0,/<serial type="tcp"/s//<serial type="tcp" unexpected="value"/' \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    console-attribute)
      sed -i '0,/<console type="tcp"/s//<console type="tcp" unexpected="value"/' \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    serial-target-attribute)
      serial_target='target type="isa-serial" port="0"'
      sed -i "0,/${serial_target}/s//${serial_target} unexpected=\"value\"/" \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    console-target-attribute)
      console_target='target type="serial" port="0"'
      sed -i "0,/${console_target}/s//${console_target} unexpected=\"value\"/" \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    serial-model-attribute)
      serial_model='model name="isa-serial"'
      sed -i "0,/${serial_model}/s//${serial_model} unexpected=\"value\"/" \
        "$BATS_TEST_TMPDIR/existing-domain.xml"
      ;;
    esac

    VM_X86_REDFISH_SERIAL_MODE=tcp \
      VM_X86_REDFISH_SERIAL_LISTEN_IP=192.0.2.20 \
      VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
      run ./scripts/create-vm

    [ "$status" -ne 0 ]
    [[ "$output" == *"configured tcp serial transport"* ]]
  done
}

@test "create-vm rejects direct serial metadata outside the project container" {
  install_existing_domain_mocks tcp 192.0.2.20 9000
  sed -i '/<rp:serial-/d' "$BATS_TEST_TMPDIR/existing-domain.xml"
  sed -i '/^[[:space:]]*<\/metadata>/i\    <rp:serial-mode>tcp</rp:serial-mode>' \
    "$BATS_TEST_TMPDIR/existing-domain.xml"
  sed -i '/^[[:space:]]*<\/metadata>/i\    <rp:serial-listen-ip>192.0.2.20</rp:serial-listen-ip>' \
    "$BATS_TEST_TMPDIR/existing-domain.xml"
  sed -i '/^[[:space:]]*<\/metadata>/i\    <rp:serial-listen-port>9000</rp:serial-listen-port>' \
    "$BATS_TEST_TMPDIR/existing-domain.xml"

  VM_X86_REDFISH_SERIAL_MODE=tcp \
    VM_X86_REDFISH_SERIAL_LISTEN_IP=192.0.2.20 \
    VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
    run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"configured tcp serial transport"* ]]
}

@test "create-vm accepts inactive libvirt serial aliases" {
  install_existing_domain_mocks tcp 192.0.2.20 9000
  sed -i '/    <\/serial>/i\      <alias name="serial0"/>' \
    "$BATS_TEST_TMPDIR/existing-domain.xml"
  sed -i '/    <\/console>/i\      <alias name="serial0"/>' \
    "$BATS_TEST_TMPDIR/existing-domain.xml"

  VM_X86_REDFISH_SERIAL_MODE=tcp \
    VM_X86_REDFISH_SERIAL_LISTEN_IP=192.0.2.20 \
    VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
    run ./scripts/create-vm

  [ "$status" -eq 0 ]
}

@test "create-vm writes uuid once and defines new owned domain" {
  install_mock_command virsh '
printf "virsh %s\\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2") exit 1 ;;
  *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2") exit 0 ;;
  *"vol-upload "*|*"pool-refresh "*|*"vol-resize "*) exit 0 ;;
  *"define "*"/domain.xml") exit 0 ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\\n" ;;
  *) exit 2 ;;
esac
'
  run ./scripts/create-vm
  [ "$status" -eq 0 ]
  [ "$(cat "$VM_X86_REDFISH_STATE_DIR/domain-uuid")" = "11111111-2222-3333-8444-555555555555" ]
  run grep -F "vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2" \
    "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -eq 0 ]
  credentials="$(cat "$VM_X86_REDFISH_STATE_DIR/credentials.env")"

  : >"$BATS_TEST_TMPDIR/commands.log"
  install_mock_command virsh '
printf "virsh %s\\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish") exit 0 ;;
  *"dumpxml vm-x86-redfish"*) cat "$VM_X86_REDFISH_STATE_DIR/domain.xml" ;;
  *"vol-info --pool default vm-x86-redfish.qcow2") exit 0 ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\\n" ;;
  *) exit 2 ;;
esac
'
  run ./scripts/create-vm
  [ "$status" -eq 0 ]
  [ "$(cat "$VM_X86_REDFISH_STATE_DIR/domain-uuid")" = "11111111-2222-3333-8444-555555555555" ]
  run grep -F "uuidgen" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
  run grep -F "define " "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
  [ "$(cat "$VM_X86_REDFISH_STATE_DIR/credentials.env")" = "$credentials" ]
  run grep -F "openssl rand -base64 30" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
  run grep -F "openssl req" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
  run grep -F "htpasswd -iB -c" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -eq 0 ]
}

@test "create-vm rejects malformed existing Redfish credentials without sourcing them" {
  install_existing_domain_mocks
  printf "REDFISH_USERNAME='admin'\ntouch '%s'\nREDFISH_PASSWORD='redfish-test-password'\n" \
    "$BATS_TEST_TMPDIR/sourced" >"$VM_X86_REDFISH_STATE_DIR/credentials.env"
  chmod 600 "$VM_X86_REDFISH_STATE_DIR/credentials.env"

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed Redfish credentials file"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/sourced" ]
  run grep -F "htpasswd" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
}

@test "create-vm rejects Redfish state output symlinks before writing through them" {
  install_existing_domain_mocks
  printf "REDFISH_USERNAME='admin'\nREDFISH_PASSWORD='redfish-test-password'\n" \
    >"$VM_X86_REDFISH_STATE_DIR/credentials.env"
  chmod 600 "$VM_X86_REDFISH_STATE_DIR/credentials.env"
  printf 'outside\n' >"$BATS_TEST_TMPDIR/outside-htpasswd"
  ln -s "$BATS_TEST_TMPDIR/outside-htpasswd" "$VM_X86_REDFISH_STATE_DIR/htpasswd"

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected project state file"* ]]
  run cat "$BATS_TEST_TMPDIR/outside-htpasswd"
  [ "$status" -eq 0 ]
  [ "$output" = "outside" ]
}

@test "create-vm rejects symlinked domain UUID before creating root volume" {
  printf '11111111-2222-3333-8444-555555555555\n' \
    >"$BATS_TEST_TMPDIR/outside-domain-uuid"
  ln -s "$BATS_TEST_TMPDIR/outside-domain-uuid" \
    "$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2") exit 1 ;;
  *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2") exit 0 ;;
  *) exit 2 ;;
esac
'

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected project state file"* ]]
  run grep -F "vol-create-as" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
}

@test "create-vm rejects existing-domain dump symlinks before writing through them" {
  install_existing_domain_mocks
  printf 'outside\n' >"$BATS_TEST_TMPDIR/outside-existing-domain.xml"
  ln -s "$BATS_TEST_TMPDIR/outside-existing-domain.xml" \
    "$VM_X86_REDFISH_STATE_DIR/existing-domain.xml"

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected project state file"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/outside-existing-domain.xml")" = "outside" ]
}

@test "create-vm rejects incomplete Redfish TLS state" {
  install_existing_domain_mocks
  touch "$VM_X86_REDFISH_STATE_DIR/tls.crt"

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"incomplete Redfish TLS state"* ]]
  run grep -F "openssl req" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
}

@test "create-vm rejects loose existing Redfish credentials" {
  install_existing_domain_mocks
  printf "REDFISH_USERNAME='admin'\nREDFISH_PASSWORD='redfish-test-password'\n" \
    >"$VM_X86_REDFISH_STATE_DIR/credentials.env"
  chmod 644 "$VM_X86_REDFISH_STATE_DIR/credentials.env"

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"file must be mode 0600"* ]]
  run grep -F "htpasswd" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
}

@test "create-vm rejects loose existing TLS key" {
  install_existing_domain_mocks
  printf "REDFISH_USERNAME='admin'\nREDFISH_PASSWORD='redfish-test-password'\n" \
    >"$VM_X86_REDFISH_STATE_DIR/credentials.env"
  printf 'test-cert\n' >"$VM_X86_REDFISH_STATE_DIR/tls.crt"
  printf 'test-key\n' >"$VM_X86_REDFISH_STATE_DIR/tls.key"
  chmod 600 "$VM_X86_REDFISH_STATE_DIR/credentials.env" "$VM_X86_REDFISH_STATE_DIR/tls.crt"
  chmod 644 "$VM_X86_REDFISH_STATE_DIR/tls.key"

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"file must be mode 0600"* ]]
  run grep -F "openssl req" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
}

@test "create-vm refuses existing domain without project metadata" {
  install_mock_command virsh '
case "$*" in
  *"dominfo vm-x86-redfish") exit 0 ;;
  *"dumpxml vm-x86-redfish"*) printf "<domain><name>vm-x86-redfish</name></domain>\\n" ;;
  *) exit 2 ;;
esac
'
  run ./scripts/create-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"existing domain vm-x86-redfish is not owned by this project"* ]]
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
}

@test "create-vm accepts owned domain with alternate metadata prefix and escaped text" {
  printf '11111111-2222-3333-8444-555555555555\n' >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
case "$*" in
  *"dominfo vm-x86-redfish") exit 0 ;;
  *"dumpxml vm-x86-redfish"*) cat <<XML
<domain type="kvm" xmlns:owned="https://github.com/randomparity/vm-x86-redfish">
  <name>vm-x86-redfish</name>
  <uuid>11111111-2222-3333-8444-555555555555</uuid>
  <metadata>
    <owned:vm-x86-redfish>
      <owned:project>vm-x86-redfish</owned:project>
      <owned:root-volume>vm-x86-redfish&amp;owned.qcow2</owned:root-volume>
      <owned:memory-mib>4096</owned:memory-mib>
      <owned:root-disk-gib>40</owned:root-disk-gib>
      <owned:source-image-sha256>${VM_X86_REDFISH_TEST_SOURCE_SHA256}</owned:source-image-sha256>
      <owned:serial-mode>pty</owned:serial-mode>
      <owned:serial-listen-ip></owned:serial-listen-ip>
      <owned:serial-listen-port></owned:serial-listen-port>
    </owned:vm-x86-redfish>
  </metadata>
  <memory unit="MiB">4096</memory>
  <vcpu placement="static">2</vcpu>
  <os firmware="efi">
    <type arch="x86_64" machine="q35">hvm</type>
    <firmware><feature enabled="no" name="secure-boot"/></firmware>
    <boot dev="hd"/>
  </os>
  <cpu mode="host-passthrough" check="none"/>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2" discard="unmap"/>
      <source file="/var/lib/libvirt/images/vm-x86-redfish&amp;owned.qcow2"/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <interface type="network">
      <source network="default"/>
      <model type="virtio"/>
    </interface>
    <serial type="pty">
      <target type="isa-serial" port="0"><model name="isa-serial"/></target>
    </serial>
    <console type="pty">
      <target type="serial" port="0"/>
    </console>
    <channel type="unix">
      <target type="virtio" name="org.qemu.guest_agent.0"/>
    </channel>
    <graphics type="vnc" listen="127.0.0.1"/>
    <video><model type="virtio"/></video>
  </devices>
</domain>
XML
    ;;
  *"vol-info --pool default vm-x86-redfish&owned.qcow2") exit 0 ;;
  *"vol-path --pool default vm-x86-redfish&owned.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish&owned.qcow2\\n" ;;
  *) exit 2 ;;
esac
'
  VM_X86_REDFISH_ROOT_VOLUME_NAME="vm-x86-redfish&owned.qcow2" run ./scripts/create-vm
  [ "$status" -eq 0 ]
}

@test "create-vm rejects ownership metadata outside domain metadata" {
  printf '11111111-2222-3333-8444-555555555555\n' >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
case "$*" in
  *"dominfo vm-x86-redfish") exit 0 ;;
  *"dumpxml vm-x86-redfish"*) cat <<XML
<domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
  <uuid>11111111-2222-3333-8444-555555555555</uuid>
  <devices>
    <rp:project>vm-x86-redfish</rp:project>
    <rp:root-volume>vm-x86-redfish.qcow2</rp:root-volume>
    <disk type="file" device="disk"><source file="/var/lib/libvirt/images/vm-x86-redfish.qcow2"/>
    </disk>
  </devices>
</domain>
XML
    ;;
  *"vol-info --pool default vm-x86-redfish.qcow2") exit 0 ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\\n" ;;
  *) exit 2 ;;
esac
'
  run ./scripts/create-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"existing domain vm-x86-redfish is not owned by this project"* ]]
}

@test "create-vm refuses owned existing domain when root volume is missing" {
  printf '11111111-2222-3333-8444-555555555555\n' >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
case "$*" in
  *"dominfo vm-x86-redfish") exit 0 ;;
  *"dumpxml vm-x86-redfish"*) cat <<XML
<domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
  <uuid>11111111-2222-3333-8444-555555555555</uuid>
  <metadata><rp:project>vm-x86-redfish</rp:project>
    <rp:root-volume>vm-x86-redfish.qcow2</rp:root-volume></metadata>
</domain>
XML
    ;;
  *"vol-info --pool default vm-x86-redfish.qcow2") exit 1 ;;
  *) exit 2 ;;
esac
'
  run ./scripts/create-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"root volume vm-x86-redfish.qcow2 is missing"* ]]
}

@test "create-vm refuses owned existing domain with wrong disk source" {
  printf '11111111-2222-3333-8444-555555555555\n' >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
case "$*" in
  *"dominfo vm-x86-redfish") exit 0 ;;
  *"dumpxml vm-x86-redfish"*) cat <<XML
<domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
  <uuid>11111111-2222-3333-8444-555555555555</uuid>
  <metadata><rp:project>vm-x86-redfish</rp:project>
    <rp:root-volume>vm-x86-redfish.qcow2</rp:root-volume></metadata>
  <devices><disk type="file" device="disk"><source file="/var/lib/libvirt/images/other.qcow2"/>
  </disk></devices>
</domain>
XML
    ;;
  *"vol-info --pool default vm-x86-redfish.qcow2") exit 0 ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\\n" ;;
  *) exit 2 ;;
esac
'
  run ./scripts/create-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not use root volume path"* ]]
}

@test "create-vm refuses owned existing domain with an extra disk" {
  local extra_disk
  extra_disk='    <disk type="file" device="disk">
      <source file="/var/lib/libvirt/images/extra.qcow2"/>
      <target dev="vdb" bus="virtio"/>
    </disk>'
  install_existing_domain_mocks
  write_existing_domain_xml "$BATS_TEST_TMPDIR/existing-domain.xml" \
    "vm-x86-redfish.qcow2" \
    "/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
    "$extra_disk"

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"hardware does not match expected project shape"* ]]
}

@test "create-vm refuses owned existing domain with a host device" {
  local host_device
  host_device='    <hostdev mode="subsystem" type="usb" managed="yes"/>'
  install_existing_domain_mocks
  write_existing_domain_xml "$BATS_TEST_TMPDIR/existing-domain.xml" \
    "vm-x86-redfish.qcow2" \
    "/var/lib/libvirt/images/vm-x86-redfish.qcow2" \
    "$host_device"

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"hardware does not match expected project shape"* ]]
}

@test "create-vm deletes newly created disk when vol-path fails" {
  install_mock_command virsh '
printf "virsh %s\\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2") exit 1 ;;
  *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2") exit 0 ;;
  *"vol-upload "*|*"pool-refresh "*|*"vol-resize "*) exit 0 ;;
  *"vol-path --pool default vm-x86-redfish.qcow2") exit 1 ;;
  *"vol-delete --pool default vm-x86-redfish.qcow2") exit 0 ;;
  *) exit 2 ;;
esac
'
  run ./scripts/create-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to resolve root volume path"* ]]
  grep -F "vol-delete --pool default vm-x86-redfish.qcow2" "$BATS_TEST_TMPDIR/commands.log"
}

@test "create-vm deletes newly created disk when image import fails" {
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2") exit 1 ;;
  *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2") exit 0 ;;
  *"vol-upload "*) exit 1 ;;
  *"vol-delete --pool default vm-x86-redfish.qcow2") exit 0 ;;
  *) exit 2 ;;
esac
'

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to import source image"* ]]
  grep -F "vol-delete --pool default vm-x86-redfish.qcow2" \
    "$BATS_TEST_TMPDIR/commands.log"
}

@test "create-vm deletes newly created disk when domain rendering fails" {
  mkdir "$VM_X86_REDFISH_STATE_DIR/domain.xml"
  install_mock_command virsh '
printf "virsh %s\\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2") exit 1 ;;
  *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2") exit 0 ;;
  *"vol-upload "*|*"pool-refresh "*|*"vol-resize "*) exit 0 ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\\n" ;;
  *"vol-delete --pool default vm-x86-redfish.qcow2") exit 0 ;;
  *) exit 2 ;;
esac
'
  run ./scripts/create-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to render domain XML"* ]]
  grep -F "vol-delete --pool default vm-x86-redfish.qcow2" "$BATS_TEST_TMPDIR/commands.log"
}

@test "create-vm deletes newly created disk when domain definition fails" {
  install_mock_command virsh '
printf "virsh %s\\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2") exit 1 ;;
  *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2") exit 0 ;;
  *"vol-upload "*|*"pool-refresh "*|*"vol-resize "*) exit 0 ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\\n" ;;
  *"define "*"/domain.xml") exit 1 ;;
  *"vol-delete --pool default vm-x86-redfish.qcow2") exit 0 ;;
  *) exit 2 ;;
esac
'
  run ./scripts/create-vm
  [ "$status" -ne 0 ]
  run grep -F "vol-delete --pool default vm-x86-redfish.qcow2" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -eq 0 ]
}

@test "create-vm refuses existing root volume without a validated owned domain" {
  install_mock_command virsh '
case "$*" in
  *"dominfo vm-x86-redfish") exit 1 ;;
  *"vol-info --pool default vm-x86-redfish.qcow2") exit 0 ;;
  *) exit 2 ;;
esac
'
  run ./scripts/create-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"existing root volume vm-x86-redfish.qcow2 is not adopted"* ]]
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
}

@test "create-vm honors test-only overrides with integration guard" {
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo test-domain"|*"vol-info --pool default test-volume.qcow2") exit 1 ;;
  *"vol-create-as default test-volume.qcow2 40G --format qcow2") exit 0 ;;
  *"vol-upload "*|*"pool-refresh "*|*"vol-resize "*) exit 0 ;;
  *"vol-path --pool default test-volume.qcow2")
    printf "/var/lib/libvirt/images/test-volume.qcow2\n" ;;
  *"define "*"/domain.xml") exit 0 ;;
  *) exit 2 ;;
esac
'
  VM_X86_REDFISH_DOMAIN_NAME=test-domain \
    VM_X86_REDFISH_ROOT_VOLUME_NAME=test-volume.qcow2 \
    run ./scripts/create-vm
  [ "$status" -eq 0 ]
  [ -f "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
  run grep -F "dominfo test-domain" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -eq 0 ]
}

@test "create-vm rejects test-only domain override without integration guard" {
  run env -u VM_X86_REDFISH_INTEGRATION_TEST -u VM_X86_REDFISH_STATE_DIR \
    VM_X86_REDFISH_DOMAIN_NAME=other ./scripts/create-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"error: test-only overrides require VM_X86_REDFISH_INTEGRATION_TEST=1"* ]]
}

@test "create-vm rejects test-only root volume override without integration guard" {
  run env -u VM_X86_REDFISH_INTEGRATION_TEST -u VM_X86_REDFISH_STATE_DIR \
    VM_X86_REDFISH_ROOT_VOLUME_NAME=other.qcow2 ./scripts/create-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"error: test-only overrides require VM_X86_REDFISH_INTEGRATION_TEST=1"* ]]
}

@test "create-vm rejects test-only state override without integration guard" {
  run env -u VM_X86_REDFISH_INTEGRATION_TEST VM_X86_REDFISH_STATE_DIR="$BATS_TEST_TMPDIR/other" \
    ./scripts/create-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"error: test-only overrides require VM_X86_REDFISH_INTEGRATION_TEST=1"* ]]
}

@test "create-vm requires a source qcow2 before libvirt mutation" {
  install_create_success_mocks

  run env -u VM_X86_REDFISH_SOURCE_IMAGE ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"VM_X86_REDFISH_SOURCE_IMAGE must name a readable qcow2 file"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/commands.log" ]
}

@test "create-vm imports and sizes a configured source image" {
  source_image="$BATS_TEST_TMPDIR/source.qcow2"
  printf 'qcow2 source\n' >"$source_image"
  install_mock_command qemu-img '
case "$*" in
  "info --output=json "*) printf '\''{"format":"qcow2","virtual-size":8589934592}\n'\'' ;;
  *) exit 2 ;;
esac
'
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2") exit 1 ;;
  *"vol-create-as default vm-x86-redfish.qcow2 64G --format qcow2") exit 0 ;;
  *"vol-upload --pool default vm-x86-redfish.qcow2 "*" --sparse") exit 0 ;;
  *"pool-refresh default") exit 0 ;;
  *"vol-resize --pool default vm-x86-redfish.qcow2 64G") exit 0 ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\n" ;;
  *"define "*"/domain.xml") exit 0 ;;
  *) exit 2 ;;
esac
'

  VM_X86_REDFISH_SOURCE_IMAGE="$source_image" \
    VM_X86_REDFISH_MEMORY_MIB=8192 \
    VM_X86_REDFISH_ROOT_DISK_GIB=64 \
    run ./scripts/create-vm

  [ "$status" -eq 0 ]
  grep -F "vol-upload --pool default vm-x86-redfish.qcow2 $source_image --sparse" \
    "$BATS_TEST_TMPDIR/commands.log"
  grep -F "vol-resize --pool default vm-x86-redfish.qcow2 64G" \
    "$BATS_TEST_TMPDIR/commands.log"
  grep -F "<memory unit='MiB'>8192</memory>" "$VM_X86_REDFISH_STATE_DIR/domain.xml"
  grep -F '<rp:root-disk-gib>64</rp:root-disk-gib>' \
    "$VM_X86_REDFISH_STATE_DIR/domain.xml"
  source_sha256="$(sha256sum "$source_image")"
  source_sha256="${source_sha256%% *}"
  grep -F "<rp:source-image-sha256>$source_sha256</rp:source-image-sha256>" \
    "$VM_X86_REDFISH_STATE_DIR/domain.xml"
  grep -F "<cpu mode='host-passthrough' check='none'/>" \
    "$VM_X86_REDFISH_STATE_DIR/domain.xml"
  grep -F "<model type='virtio'/>" "$VM_X86_REDFISH_STATE_DIR/domain.xml"
}

@test "create-vm rejects invalid sizing before libvirt mutation" {
  VM_X86_REDFISH_MEMORY_MIB=4G run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"VM_X86_REDFISH_MEMORY_MIB must be a positive integer"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/commands.log" ]
}

@test "create-vm rejects a source image larger than the target disk" {
  install_mock_command qemu-img '
case "$*" in
  "info --output=json "*) printf '\''{"format":"qcow2","virtual-size":68719476736}\n'\'' ;;
  *) exit 2 ;;
esac
'

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"source image must be qcow2 and fit within 40 GiB"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/commands.log" ]
}

@test "create-vm rejects a rerun with different configured memory" {
  source_image="$BATS_TEST_TMPDIR/source.qcow2"
  printf 'qcow2 source\n' >"$source_image"
  export VM_X86_REDFISH_SOURCE_IMAGE="$source_image"
  export VM_X86_REDFISH_MEMORY_MIB=8192
  export VM_X86_REDFISH_ROOT_DISK_GIB=40
  install_mock_command qemu-img '
case "$*" in
  "info --output=json "*) printf '\''{"format":"qcow2","virtual-size":8589934592}\n'\'' ;;
  *) exit 2 ;;
esac
'
  install_existing_domain_mocks

  run ./scripts/create-vm

  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match configured VM memory"* ]]
  run grep -E 'vol-create|vol-upload|vol-resize|define' "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
}

@test "create-vm accepts equivalent libvirt memory units on rerun" {
  install_existing_domain_mocks
  sed -i 's/<memory unit="MiB">4096<\//<memory unit="KiB">4194304<\//' \
    "$BATS_TEST_TMPDIR/existing-domain.xml"

  run ./scripts/create-vm

  [ "$status" -eq 0 ]
}
