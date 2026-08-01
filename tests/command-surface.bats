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

run_endpoint_case() {
  local assignment
  local configuration="$1"
  local -a assignments
  local -a command=(
    env
    -u VM_X86_REDFISH_LISTEN_IP
    -u VM_X86_REDFISH_LISTEN_PORT
    -u VM_X86_REDFISH_SERIAL_MODE
    -u VM_X86_REDFISH_SERIAL_LISTEN_IP
    -u VM_X86_REDFISH_SERIAL_LISTEN_PORT
  )

  IFS=',' read -r -a assignments <<<"$configuration"
  for assignment in "${assignments[@]}"; do
    [ -z "$assignment" ] || command+=("$assignment")
  done

  command+=(
    bash
    -c
    'source "$1"
validate_runtime_endpoints
printf "%s|%s|%s|%s|%s\n" \
  "$REDFISH_LISTEN_IP" "$REDFISH_LISTEN_PORT" "$SERIAL_MODE" \
  "$SERIAL_LISTEN_IP" "$SERIAL_LISTEN_PORT"'
    _
    "$BATS_TEST_DIRNAME/../scripts/lib/common"
  )
  run "${command[@]}"
}

readonly REDFISH_LISTEN_IP_VARIABLE="VM_X86_REDFISH_LISTEN_IP"
readonly REDFISH_LISTEN_PORT_VARIABLE="VM_X86_REDFISH_LISTEN_PORT"
readonly SERIAL_MODE_VARIABLE="VM_X86_REDFISH_SERIAL_MODE"
readonly SERIAL_LISTEN_IP_VARIABLE="VM_X86_REDFISH_SERIAL_LISTEN_IP"
readonly SERIAL_LISTEN_PORT_VARIABLE="VM_X86_REDFISH_SERIAL_LISTEN_PORT"

@test "runtime endpoint configuration accepts canonical addresses and ports" {
  local configuration expected name
  local -a cases=(
    'defaults||127.0.0.1|8000|pty||'
    "IPv4 and lowest port|${REDFISH_LISTEN_IP_VARIABLE}=192.0.2.10,""\
${REDFISH_LISTEN_PORT_VARIABLE}=1|192.0.2.10|1|pty||"
    "IPv6 and highest port|${REDFISH_LISTEN_IP_VARIABLE}=2001:db8::10,""\
${REDFISH_LISTEN_PORT_VARIABLE}=65535|2001:db8::10|65535|pty||"
    "complete TCP settings|${SERIAL_MODE_VARIABLE}=tcp,""\
${SERIAL_LISTEN_IP_VARIABLE}=192.0.2.10,""\
${SERIAL_LISTEN_PORT_VARIABLE}=65535|127.0.0.1|8000|tcp|192.0.2.10|65535"
  )

  for configuration in "${cases[@]}"; do
    IFS='|' read -r name configuration expected <<<"$configuration"
    run_endpoint_case "$configuration"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
  done
}

@test "runtime endpoint configuration rejects invalid public inputs" {
  local configuration expected_variable name
  local -a cases=(
    "hostname|${REDFISH_LISTEN_IP_VARIABLE}=bmc.example.test|${REDFISH_LISTEN_IP_VARIABLE}"
    "unspecified IPv4|${REDFISH_LISTEN_IP_VARIABLE}=0.0.0.0|${REDFISH_LISTEN_IP_VARIABLE}"
    "unspecified IPv6|${REDFISH_LISTEN_IP_VARIABLE}=::|${REDFISH_LISTEN_IP_VARIABLE}"
    "multicast IPv4|${REDFISH_LISTEN_IP_VARIABLE}=224.0.0.1|${REDFISH_LISTEN_IP_VARIABLE}"
    "multicast IPv6|${REDFISH_LISTEN_IP_VARIABLE}=ff02::1|${REDFISH_LISTEN_IP_VARIABLE}"
    "zero Redfish port|${REDFISH_LISTEN_PORT_VARIABLE}=0|${REDFISH_LISTEN_PORT_VARIABLE}"
    "large Redfish port|${REDFISH_LISTEN_PORT_VARIABLE}=65536|${REDFISH_LISTEN_PORT_VARIABLE}"
    "signed Redfish port|${REDFISH_LISTEN_PORT_VARIABLE}=+8000|${REDFISH_LISTEN_PORT_VARIABLE}"
    "space-padded Redfish port|${REDFISH_LISTEN_PORT_VARIABLE}=\ 8000|""\
${REDFISH_LISTEN_PORT_VARIABLE}"
    "invalid serial mode|${SERIAL_MODE_VARIABLE}=ssh|${SERIAL_MODE_VARIABLE}"
    "serial address without TCP mode|${SERIAL_LISTEN_IP_VARIABLE}=192.0.2.10|""\
${SERIAL_LISTEN_IP_VARIABLE}"
    "serial port without TCP mode|${SERIAL_LISTEN_PORT_VARIABLE}=8001|""\
${SERIAL_LISTEN_PORT_VARIABLE}"
    "TCP mode without serial address|${SERIAL_MODE_VARIABLE}=tcp,""\
${SERIAL_LISTEN_PORT_VARIABLE}=8001|${SERIAL_LISTEN_IP_VARIABLE}"
    "TCP mode without serial port|${SERIAL_MODE_VARIABLE}=tcp,""\
${SERIAL_LISTEN_IP_VARIABLE}=192.0.2.10|${SERIAL_LISTEN_PORT_VARIABLE}"
  )

  for configuration in "${cases[@]}"; do
    IFS='|' read -r name configuration expected_variable <<<"$configuration"
    run_endpoint_case "$configuration"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$expected_variable"* ]]
  done
}

@test "runtime endpoint configuration rejects IPv6 scope IDs" {
  run_endpoint_case "${REDFISH_LISTEN_IP_VARIABLE}=fe80::1%eth0"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$REDFISH_LISTEN_IP_VARIABLE"* ]]
}

@test "runtime endpoint configuration rejects IPv4-mapped IPv6 literals" {
  local configuration expected_variable
  local -a cases=(
    "${REDFISH_LISTEN_IP_VARIABLE}=::ffff:192.0.2.10|${REDFISH_LISTEN_IP_VARIABLE}"
    "${SERIAL_MODE_VARIABLE}=tcp,${SERIAL_LISTEN_IP_VARIABLE}=::ffff:c000:20a,""\
${SERIAL_LISTEN_PORT_VARIABLE}=9000|${SERIAL_LISTEN_IP_VARIABLE}"
  )
  for configuration in "${cases[@]}"; do
    IFS='|' read -r configuration expected_variable <<<"$configuration"

    run_endpoint_case "$configuration"

    [ "$status" -ne 0 ]
    [ "$output" = \
      "error: $expected_variable must not be an IPv4-mapped IPv6 address" ]
  done
}

@test "mapped IPv6 cannot alias an IPv4 listener on the same port" {
  run env \
    VM_X86_REDFISH_LISTEN_IP=::ffff:192.0.2.10 \
    VM_X86_REDFISH_LISTEN_PORT=9000 \
    VM_X86_REDFISH_SERIAL_MODE=tcp \
    VM_X86_REDFISH_SERIAL_LISTEN_IP=192.0.2.10 \
    VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
    bash -c 'source "$1"; reject_listener_collision' \
    _ "$BATS_TEST_DIRNAME/../scripts/lib/common"

  [ "$status" -ne 0 ]
  [ "$output" = \
    "error: VM_X86_REDFISH_LISTEN_IP must not be an IPv4-mapped IPv6 address" ]
  [[ "$output" != *"same address and port"* ]]
}

@test "runtime endpoint helpers format IPv6 hosts in URIs" {
  local configuration="${REDFISH_LISTEN_IP_VARIABLE}=2001:db8::10,""\
${REDFISH_LISTEN_PORT_VARIABLE}=65535,${SERIAL_MODE_VARIABLE}=tcp,""\
${SERIAL_LISTEN_IP_VARIABLE}=2001:db8::20,${SERIAL_LISTEN_PORT_VARIABLE}=1"
  run_endpoint_case "$configuration"
  [ "$status" -eq 0 ]

  run env \
    VM_X86_REDFISH_LISTEN_IP=2001:db8::10 \
    VM_X86_REDFISH_LISTEN_PORT=65535 \
    VM_X86_REDFISH_SERIAL_MODE=tcp \
    VM_X86_REDFISH_SERIAL_LISTEN_IP=2001:db8::20 \
    VM_X86_REDFISH_SERIAL_LISTEN_PORT=1 \
    bash -c 'source "$1"; printf "%s|%s\n" "$(redfish_endpoint)" "$(serial_endpoint)"' \
    _ "$BATS_TEST_DIRNAME/../scripts/lib/common"
  [ "$status" -eq 0 ]
  [ "$output" = 'https://[2001:db8::10]:65535|tcp://[2001:db8::20]:1' ]
}

@test "network exposure warnings identify exposed services without credentials" {
  run env \
    VM_X86_REDFISH_LISTEN_IP=192.0.2.10 \
    VM_X86_REDFISH_SERIAL_MODE=tcp \
    VM_X86_REDFISH_SERIAL_LISTEN_IP=2001:db8::20 \
    VM_X86_REDFISH_SERIAL_LISTEN_PORT=8001 \
    REDFISH_PASSWORD=not-for-output \
    bash -c 'source "$1"; warn_network_exposure' \
    _ "$BATS_TEST_DIRNAME/../scripts/lib/common"
  [ "$status" -eq 0 ]
  [[ "$output" == *'non-loopback Redfish'* ]]
  [[ "$output" == *'unauthenticated plaintext TCP serial'* ]]
  [[ "$output" != *'not-for-output'* ]]
}
