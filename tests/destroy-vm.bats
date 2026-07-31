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

@test "destroy-vm rejects a domain UUID directory before libvirt commands" {
  mkdir "$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
'
  run ./scripts/destroy-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected regular project state file"* ]]
  [ -d "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
  [ ! -e "$BATS_TEST_TMPDIR/commands.log" ]
}

@test "destroy-vm rejects a dangling domain UUID symlink before libvirt commands" {
  ln -s "$BATS_TEST_TMPDIR/missing-domain-uuid" \
    "$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
'
  run ./scripts/destroy-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected regular project state file"* ]]
  [ -L "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
  [ ! -e "$BATS_TEST_TMPDIR/commands.log" ]
}

@test "destroy-vm rejects a domain UUID symlink to a file before libvirt commands" {
  printf '11111111-2222-4333-8444-555555555555\n' >"$BATS_TEST_TMPDIR/domain-uuid"
  ln -s "$BATS_TEST_TMPDIR/domain-uuid" "$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
'
  run ./scripts/destroy-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected regular project state file"* ]]
  [ -L "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
  [ -f "$BATS_TEST_TMPDIR/domain-uuid" ]
  [ ! -e "$BATS_TEST_TMPDIR/commands.log" ]
}

@test "destroy-vm rejects a dangling tmp symlink before libvirt commands" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  ln -s "$BATS_TEST_TMPDIR/missing-tmp" "$VM_X86_REDFISH_STATE_DIR/tmp"
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
'
  run ./scripts/destroy-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing symlink"* ]]
  [ -f "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
  [ -L "$VM_X86_REDFISH_STATE_DIR/tmp" ]
  [ ! -e "$BATS_TEST_TMPDIR/commands.log" ]
}

@test "destroy-vm refuses domain with mismatched ownership" {
  printf '11111111-2222-4333-8444-555555555555\n' \
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
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dumpxml vm-x86-redfish")
    cat <<XML
<domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
  <uuid>11111111-2222-4333-8444-555555555555</uuid>
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
  *"domstate vm-x86-redfish")
    printf "shut off\n"
    ;;
  *"vol-info --pool default vm-x86-redfish.qcow2")
    exit 0
    ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\n"
    ;;
  *"vol-list --pool default")
    printf "vm-x86-redfish.qcow2 /var/lib/libvirt/images/vm-x86-redfish.qcow2\n"
    printf "fedora-iso-11111111-2222-4333-8444-555555555555.img /var/lib/libvirt/images/fedora\n"
    printf "unrelated-22222222-2222-4333-8444-555555555555.img /var/lib/libvirt/images/other\n"
    ;;
  *)
    exit 0
    ;;
esac
'
  run ./scripts/destroy-vm
  [ "$status" -eq 0 ]
  grep -F "vol-delete --pool default vm-x86-redfish.qcow2" \
    "$BATS_TEST_TMPDIR/commands.log"
  grep -F "vol-delete --pool default fedora-iso-11111111-2222-4333-8444-555555555555.img" \
    "$BATS_TEST_TMPDIR/commands.log"
  run grep -F "unrelated-22222222" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
}

@test "destroy-vm refuses root volume metadata mismatch" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
case "$*" in
  *"dumpxml vm-x86-redfish")
    cat <<XML
<domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
  <uuid>11111111-2222-4333-8444-555555555555</uuid>
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

@test "destroy-vm refuses owned domain with wrong disk source" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
case "$*" in
  *"dumpxml vm-x86-redfish")
    cat <<XML
<domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
  <uuid>11111111-2222-4333-8444-555555555555</uuid>
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
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\n"
    ;;
  *)
    exit 0
    ;;
esac
'
  run ./scripts/destroy-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected disk source"* ]]
}

@test "destroy-vm retries after undefine succeeds and root delete fails" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dumpxml vm-x86-redfish")
    if [ -f "$BATS_TEST_TMPDIR/domain-absent" ]; then
      exit 1
    fi
    cat <<XML
<domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
  <uuid>11111111-2222-4333-8444-555555555555</uuid>
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
  *"domstate vm-x86-redfish")
    printf "shut off\n"
    ;;
  *"undefine vm-x86-redfish --nvram")
    touch "$BATS_TEST_TMPDIR/domain-absent"
    ;;
  *"vol-info --pool default vm-x86-redfish.qcow2")
    exit 0
    ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\n"
    ;;
  *"vol-delete --pool default vm-x86-redfish.qcow2")
    if [ ! -f "$BATS_TEST_TMPDIR/root-delete-failed" ]; then
      touch "$BATS_TEST_TMPDIR/root-delete-failed"
      exit 1
    fi
    touch "$BATS_TEST_TMPDIR/root-delete-complete"
    ;;
  *"vol-list --pool default")
    if [ ! -f "$BATS_TEST_TMPDIR/root-delete-complete" ]; then
      printf "vm-x86-redfish.qcow2\n"
    fi
    ;;
  *)
    exit 0
    ;;
esac
'
  run ./scripts/destroy-vm
  [ "$status" -ne 0 ]
  [ -e "$VM_X86_REDFISH_STATE_DIR/destroy-domain.xml" ]
  [ -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
  run ./scripts/destroy-vm
  [ "$status" -eq 0 ]
  grep -F "vol-delete --pool default vm-x86-redfish.qcow2" \
    "$BATS_TEST_TMPDIR/commands.log"
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
}

@test "destroy-vm refuses an unsafe current domain probe without changing its target" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  printf 'outside state\n' >"$BATS_TEST_TMPDIR/outside-state"
  ln -s "$BATS_TEST_TMPDIR/outside-state" \
    "$VM_X86_REDFISH_STATE_DIR/destroy-domain.current.xml"
  install_mock_command virsh '
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
  [[ "$output" == *"unexpected project state file"* ]]
  run cat "$BATS_TEST_TMPDIR/outside-state"
  [ "$status" -eq 0 ]
  [ "$output" = "outside state" ]
  [ -L "$VM_X86_REDFISH_STATE_DIR/destroy-domain.current.xml" ]
  [ -f "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
}

@test "destroy-vm preserves state when dumpxml fails for a listed domain" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dumpxml vm-x86-redfish")
    exit 1
    ;;
  *"list --all --name")
    printf "vm-x86-redfish\n"
    ;;
  *)
    exit 0
    ;;
esac
'
  run ./scripts/destroy-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"domain vm-x86-redfish is still present"* ]]
  [ -f "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
  run grep -F "vol-delete" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -ne 0 ]
}

@test "destroy-vm preserves state when domain inventory fails" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
case "$*" in
  *"dumpxml vm-x86-redfish"|*"list --all --name")
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
'
  run ./scripts/destroy-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to list libvirt domains"* ]]
  [ -f "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
}

@test "destroy-vm force destroys active non-running domain states" {
  for state in paused crashed; do
    : >"$BATS_TEST_TMPDIR/commands.log"
    printf '11111111-2222-4333-8444-555555555555\n' \
      >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
    printf '%s\n' "$state" >"$BATS_TEST_TMPDIR/domstate"
    install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  *"dumpxml vm-x86-redfish")
    cat <<XML
<domain xmlns:rp="https://github.com/randomparity/vm-x86-redfish">
  <uuid>11111111-2222-4333-8444-555555555555</uuid>
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
  *"domstate vm-x86-redfish")
    cat "$BATS_TEST_TMPDIR/domstate"
    ;;
  *"vol-info --pool default vm-x86-redfish.qcow2")
    exit 0
    ;;
  *"vol-path --pool default vm-x86-redfish.qcow2")
    printf "/var/lib/libvirt/images/vm-x86-redfish.qcow2\n"
    ;;
  *"vol-list --pool default")
    ;;
  *)
    exit 0
    ;;
esac
'
    run ./scripts/destroy-vm
    [ "$status" -eq 0 ]
    grep -F "destroy vm-x86-redfish" "$BATS_TEST_TMPDIR/commands.log"
  done
}

@test "destroy-vm removes uuid media volumes when domain and root are absent" {
  printf '11111111-2222-4333-8444-555555555555\n' \
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
  *"vol-list --pool default")
    printf "partial-11111111-2222-4333-8444-555555555555.img\n"
    ;;
  *)
    exit 0
    ;;
esac
'
  run ./scripts/destroy-vm
  [ "$status" -eq 0 ]
  grep -F "vol-delete --pool default partial-11111111-2222-4333-8444-555555555555.img" \
    "$BATS_TEST_TMPDIR/commands.log"
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/tmp" ]
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
}

@test "destroy-vm removes empty Sushy tmp child directory after eject" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  mkdir -p "$VM_X86_REDFISH_STATE_DIR/tmp/sushy-download"
  chmod 700 "$VM_X86_REDFISH_STATE_DIR/tmp"
  install_mock_command virsh '
case "$*" in
  *"dumpxml vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2")
    exit 1
    ;;
  *"vol-list --pool default")
    ;;
  *)
    exit 0
    ;;
esac
'
  run ./scripts/destroy-vm
  [ "$status" -eq 0 ]
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/tmp" ]
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
}

@test "destroy-vm removes interrupted Sushy tmp child file" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  mkdir -p "$VM_X86_REDFISH_STATE_DIR/tmp/sushy-download"
  chmod 700 "$VM_X86_REDFISH_STATE_DIR/tmp"
  touch "$VM_X86_REDFISH_STATE_DIR/tmp/sushy-download/red.iso"
  install_mock_command virsh '
case "$*" in
  *"dumpxml vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2")
    exit 1
    ;;
  *"vol-list --pool default")
    ;;
  *)
    exit 0
    ;;
esac
'
  run ./scripts/destroy-vm
  [ "$status" -eq 0 ]
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/tmp" ]
  [ ! -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
}

@test "destroy-vm preserves state when media volume listing fails" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  mkdir -p "$VM_X86_REDFISH_STATE_DIR/tmp"
  chmod 700 "$VM_X86_REDFISH_STATE_DIR/tmp"
  touch "$VM_X86_REDFISH_STATE_DIR/tmp/interrupted-download"
  install_mock_command virsh '
case "$*" in
  *"dumpxml vm-x86-redfish")
    exit 1
    ;;
  *"vol-list --pool default")
    if [ -f "$BATS_TEST_TMPDIR/root-inventory-complete" ]; then
      exit 1
    fi
    touch "$BATS_TEST_TMPDIR/root-inventory-complete"
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

@test "destroy-vm preserves state when root volume inventory fails" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  install_mock_command virsh '
case "$*" in
  *"dumpxml vm-x86-redfish")
    exit 1
    ;;
  *"list --all --name")
    ;;
  *"vol-list --pool default")
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
  [ -f "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
}

@test "destroy-vm validates all state paths before deleting the domain UUID" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  mkdir "$VM_X86_REDFISH_STATE_DIR/credentials.env"
  install_mock_command virsh '
case "$*" in
  *"dumpxml vm-x86-redfish")
    exit 1
    ;;
  *"list --all --name"|*"vol-list --pool default")
    ;;
  *)
    exit 0
    ;;
esac
'
  run ./scripts/destroy-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected project state file"* ]]
  [ -f "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
  [ -d "$VM_X86_REDFISH_STATE_DIR/credentials.env" ]
}

@test "destroy-vm refuses to delete a symlink at an allowlisted state path" {
  printf '11111111-2222-4333-8444-555555555555\n' \
    >"$VM_X86_REDFISH_STATE_DIR/domain-uuid"
  touch "$BATS_TEST_TMPDIR/outside-state"
  ln -s "$BATS_TEST_TMPDIR/outside-state" "$VM_X86_REDFISH_STATE_DIR/domain.xml"
  install_mock_command virsh '
case "$*" in
  *"dumpxml vm-x86-redfish"|*"vol-info --pool default vm-x86-redfish.qcow2")
    exit 1
    ;;
  *"vol-list --pool default")
    ;;
  *)
    exit 0
    ;;
esac
'
  run ./scripts/destroy-vm
  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected project state file"* ]]
  [ -L "$VM_X86_REDFISH_STATE_DIR/domain.xml" ]
  [ -e "$BATS_TEST_TMPDIR/outside-state" ]
  [ -e "$VM_X86_REDFISH_STATE_DIR/domain-uuid" ]
}
