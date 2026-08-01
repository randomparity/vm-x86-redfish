#!/usr/bin/env bats

load "helpers/test-helper"

setup() {
  setup_test_workspace
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
  local extra_devices root_path root_volume_name target_path
  target_path="$1"
  root_volume_name="${2:-vm-x86-redfish.qcow2}"
  root_path="${3:-/var/lib/libvirt/images/vm-x86-redfish.qcow2}"
  extra_devices="${4:-}"
  cat >"$target_path" <<XML
<domain type="kvm" xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
  <name>vm-x86-redfish</name>
  <uuid>11111111-2222-3333-8444-555555555555</uuid>
  <metadata>
    <rp:project>vm-x86-redfish</rp:project>
    <rp:root-volume>${root_volume_name}</rp:root-volume>
  </metadata>
  <os firmware="efi">
    <type arch="x86_64" machine="q35">hvm</type>
    <firmware><feature enabled="no" name="secure-boot"/></firmware>
    <boot dev="hd"/>
  </os>
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
${extra_devices}
  </devices>
</domain>
XML
}

install_existing_domain_mocks() {
  printf '11111111-2222-3333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  write_existing_domain_xml "$BATS_TEST_TMPDIR/existing-domain.xml"
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

@test "create-vm repairs missing Redfish state for valid existing domain" {
  install_existing_domain_mocks

  run ./scripts/create-vm

  [ "$status" -eq 0 ]
  [ -f "$VM_X86_REDFISH_STATE_DIR/credentials.env" ]
  [ -f "$VM_X86_REDFISH_STATE_DIR/sushy-emulator.conf.py" ]
}

@test "create-vm writes uuid once and defines new owned domain" {
  install_mock_command virsh '
printf "virsh %s\\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2") exit 1 ;;
  *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2") exit 0 ;;
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
    <owned:project>vm-x86-redfish</owned:project>
    <owned:root-volume>vm-x86-redfish&amp;owned.qcow2</owned:root-volume>
  </metadata>
  <os firmware="efi">
    <type arch="x86_64" machine="q35">hvm</type>
    <firmware><feature enabled="no" name="secure-boot"/></firmware>
    <boot dev="hd"/>
  </os>
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

@test "create-vm deletes newly created disk when domain rendering fails" {
  mkdir "$VM_X86_REDFISH_STATE_DIR/domain.xml"
  install_mock_command virsh '
printf "virsh %s\\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dominfo vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2") exit 1 ;;
  *"vol-create-as default vm-x86-redfish.qcow2 40G --format qcow2") exit 0 ;;
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
