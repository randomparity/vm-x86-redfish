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
