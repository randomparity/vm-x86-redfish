#!/usr/bin/env bats

load "helpers/test-helper"

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
  [ "$output" = "fedora-iso-11111111-2222-3333-4444-555555555555.img" ]
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
  [ "$output" = "fedora-iso-11111111-2222-3333-4444-555555555555.img" ]
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
