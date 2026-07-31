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

@test "with_lifecycle_lock rejects a non-private parent directory" {
  mkdir -m 755 "$BATS_TEST_TMPDIR/loose"

  run bash -c '
    source scripts/lib/common
    with_lifecycle_lock "$BATS_TEST_TMPDIR/loose/lifecycle.lock" true
  '

  [ "$status" -ne 0 ]
  [[ "$output" == *"directory must be mode 0700"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/loose/lifecycle.lock" ]
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
