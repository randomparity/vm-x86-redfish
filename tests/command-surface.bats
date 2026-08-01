#!/usr/bin/env bats

@test "Makefile exposes required public targets" {
  run make -n doctor create redfish destroy test test-integration clean
  [ "$status" -eq 0 ]
}

@test "generated runtime state is ignored" {
  for path in .state/domain-uuid .artifacts/example/log.txt .venv/bin/python; do
    run git check-ignore --quiet -- "$path"
    [ "$status" -eq 0 ]
  done
}

@test "make test succeeds before optional scripts exist" {
  run make -C "$BATS_TEST_TMPDIR" -f "$BATS_TEST_DIRNAME/../Makefile" test
  [ "$status" -eq 0 ]
}
