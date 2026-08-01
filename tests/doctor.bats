#!/usr/bin/env bats
# shellcheck disable=SC2016 # Mock bodies expand when the installed scripts run.

load "helpers/test-helper"

@test "doctor reports missing qemu-img with Fedora package hint" {
  bash_bin="$(command -v bash)"
  install_mock_command uname 'printf "x86_64\n"'
  install_mock_command virsh 'exit 0'
  install_mock_command qemu-system-x86_64 'exit 0'
  PATH="$BATS_TEST_TMPDIR/bin" run "$bash_bin" ./scripts/doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing command 'qemu-img': install qemu-img"* ]]
}

@test "doctor rejects non-x86_64 hosts" {
  install_mock_command uname 'printf "aarch64\n"'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run ./scripts/doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported architecture aarch64; expected x86_64"* ]]
}

@test "doctor checks KVM, Python 3.13, port 8000, libvirt, network, and pool" {
  install_mock_command virsh '
printf "virsh %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  "-c qemu:///system uri")
    exit 0
    ;;
  "-c qemu:///system net-info default")
    printf "Active: yes\n"
    exit 0
    ;;
  "-c qemu:///system pool-info default")
    printf "State: running\n"
    exit 0
    ;;
  "-c qemu:///system version")
    printf "Using library: libvirt 12.0.0\n"
    ;;
  *)
    exit 2
    ;;
esac
'
  install_mock_command python313 'exit 0'
  install_mock_command uv '
printf "uv %s\n" "$*" >>"$BATS_TEST_TMPDIR/commands.log"
case "$*" in
  "python find 3.13")
    printf "%s/python313\n" "$BATS_TEST_TMPDIR/bin"
    ;;
  *)
    exit 2
    ;;
esac
'
  install_mock_command pkg-config 'exit 0'
  for command in qemu-system-x86_64 qemu-img uuidgen curl timeout openssl htpasswd gcc \
    bats shellcheck shfmt grub2-mkrescue xorriso; do
    install_recording_noop "$command"
  done
  mkdir -p "$BATS_TEST_TMPDIR/dev" "$BATS_TEST_TMPDIR/usr/share/edk2/ovmf"
  touch "$BATS_TEST_TMPDIR/dev/kvm"
  VM_X86_REDFISH_INTEGRATION_TEST=1 \
    VM_X86_REDFISH_DEV_KVM="$BATS_TEST_TMPDIR/dev/kvm" \
    VM_X86_REDFISH_OVMF_DIR="$BATS_TEST_TMPDIR/usr/share/edk2/ovmf" \
    run ./scripts/doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"doctor: host prerequisites are available"* ]]
  run grep -F "virsh -c qemu:///system version" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -eq 0 ]
}

install_all_doctor_success_mocks() {
  install_mock_command virsh '
case "$*" in
  *"version") printf "Using library: libvirt 12.0.0\n" ;;
  *"net-info default") printf "Active: yes\n" ;;
  *"pool-info default") printf "State: running\n" ;;
  *) exit 0 ;;
esac
'
  install_mock_command python313 'exit 0'
  install_mock_command uv '
case "$*" in
  "python find 3.13") printf "%s/python313\n" "$BATS_TEST_TMPDIR/bin" ;;
  *) exit 2 ;;
esac
'
  install_mock_command pkg-config 'exit 0'
  for command in uname qemu-system-x86_64 qemu-img uuidgen curl timeout openssl htpasswd \
    bats gcc shellcheck shfmt grub2-mkrescue xorriso; do
    install_recording_noop "$command"
  done
  install_mock_command uname 'printf "x86_64\n"'
  mkdir -p "$BATS_TEST_TMPDIR/dev" "$BATS_TEST_TMPDIR/usr/share/edk2/ovmf"
  touch "$BATS_TEST_TMPDIR/dev/kvm"
  export VM_X86_REDFISH_INTEGRATION_TEST=1
  export VM_X86_REDFISH_DEV_KVM="$BATS_TEST_TMPDIR/dev/kvm"
  export VM_X86_REDFISH_OVMF_DIR="$BATS_TEST_TMPDIR/usr/share/edk2/ovmf"
}

install_endpoint_probe_python_mock() {
  install_mock_command python313 '
program="$(cat)"
if [ "$#" -eq 3 ]; then
  printf "probe %s %s\\n" "$2" "$3" >>"$BATS_TEST_TMPDIR/commands.log"
  exit 0
fi
if [[ "$program" == *"is_loopback"* ]]; then
  case "$2" in
    127.*|::1) exit 0 ;;
    *) exit 1 ;;
  esac
fi
if [ "$#" -eq 2 ]; then
  printf "%s\\n" "$2"
fi
'
}

@test "doctor rejects unavailable loopback port 8000" {
  install_all_doctor_success_mocks
  install_endpoint_probe_python_mock
  VM_X86_REDFISH_PORT_CHECK_RESULT=busy run ./scripts/doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"127.0.0.1:8000 is already in use"* ]]
}

@test "doctor honors an integration-only loopback port override" {
  python_bin="$(PATH="${PATH#*:}" UV_PYTHON_DOWNLOADS=never uv python find 3.13)"
  port_file="$BATS_TEST_TMPDIR/listener.port"
  "$python_bin" - "$port_file" <<'PY' &
import pathlib
import signal
import socket
import sys

with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    server.listen()
    pathlib.Path(sys.argv[1]).write_text(str(server.getsockname()[1]))
    signal.pause()
PY
  listener_pid="$!"
  wait_for_file "$port_file"
  test_port="$(<"$port_file")"
  install_all_doctor_success_mocks
  install_mock_command uv "
case \"\$*\" in
  \"python find 3.13\") printf '%s\\n' '$python_bin' ;;
  *) exit 2 ;;
esac
"

  VM_X86_REDFISH_PORT_CHECK_PORT="$test_port" run ./scripts/doctor
  doctor_status="$status"
  doctor_output="$output"
  kill "$listener_pid"
  wait "$listener_pid" || :

  [ "$doctor_status" -ne 0 ]
  [[ "$doctor_output" == *"127.0.0.1:${test_port} is already in use"* ]]
}

@test "doctor reports a non-bindable configured endpoint without a traceback" {
  local python_bin
  python_bin="$(PATH="${PATH#*:}" UV_PYTHON_DOWNLOADS=never uv python find 3.13)"
  install_all_doctor_success_mocks
  install_mock_command uv "
case \"\$*\" in
  \"python find 3.13\") printf '%s\\n' '$python_bin' ;;
  *) exit 2 ;;
esac
"

  VM_X86_REDFISH_LISTEN_IP=192.0.2.20 \
    VM_X86_REDFISH_LISTEN_PORT=8443 \
    run ./scripts/doctor

  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot bind 192.0.2.20:8443: Cannot assign requested address"* ]]
  [[ "$output" != *"already in use"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "doctor accepts recently closed loopback connections" {
  python_bin="$(PATH="${PATH#*:}" UV_PYTHON_DOWNLOADS=never uv python find 3.13)"
  test_port="$(
    "$python_bin" - <<'PY'
import socket

with socket.socket() as server:
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen()
    port = server.getsockname()[1]
    with socket.create_connection(("127.0.0.1", port)) as client:
        connection, _ = server.accept()
        with connection:
            connection.shutdown(socket.SHUT_WR)
            client.recv(1)
    print(port)
PY
  )"
  install_all_doctor_success_mocks
  install_mock_command uv "
case \"\$*\" in
  \"python find 3.13\") printf '%s\\n' '$python_bin' ;;
  *) exit 2 ;;
esac
"

  VM_X86_REDFISH_PORT_CHECK_PORT="$test_port" run ./scripts/doctor
  [ "$status" -eq 0 ]
}

@test "doctor probes configured endpoint addresses for IPv4 Redfish and IPv6 TCP serial" {
  local doctor_output
  install_all_doctor_success_mocks
  install_endpoint_probe_python_mock

  VM_X86_REDFISH_LISTEN_IP=192.0.2.20 \
    VM_X86_REDFISH_LISTEN_PORT=8443 \
    VM_X86_REDFISH_SERIAL_MODE=tcp \
    VM_X86_REDFISH_SERIAL_LISTEN_IP=2001:db8::20 \
    VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
    run ./scripts/doctor

  [ "$status" -eq 0 ]
  doctor_output="$output"
  run grep -F "probe 192.0.2.20 8443" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -eq 0 ]
  run grep -F "probe 2001:db8::20 9000" "$BATS_TEST_TMPDIR/commands.log"
  [ "$status" -eq 0 ]
  [[ "$doctor_output" == *"doctor: Redfish endpoint https://192.0.2.20:8443"* ]]
  [[ "$doctor_output" == *"doctor: serial endpoint tcp://[2001:db8::20]:9000"* ]]
}

@test "doctor prints default endpoints without exposure warnings" {
  install_all_doctor_success_mocks
  install_endpoint_probe_python_mock

  run ./scripts/doctor

  [ "$status" -eq 0 ]
  [[ "$output" == *"doctor: Redfish endpoint https://127.0.0.1:8000"* ]]
  [[ "$output" == *"doctor: serial endpoint libvirt-console://vm-x86-redfish/serial0"* ]]
  [[ "$output" != *"warning:"* ]]
}

@test "doctor warns about configured endpoint exposure" {
  install_all_doctor_success_mocks
  install_endpoint_probe_python_mock

  VM_X86_REDFISH_LISTEN_IP=192.0.2.20 \
    VM_X86_REDFISH_SERIAL_MODE=tcp \
    VM_X86_REDFISH_SERIAL_LISTEN_IP=2001:db8::20 \
    VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
    run ./scripts/doctor

  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: non-loopback Redfish listener at https://192.0.2.20:8000"* ]]
  [[ "$output" == *"unauthenticated plaintext TCP serial listener at tcp://[2001:db8::20]:9000"* ]]
}

@test "doctor rejects colliding configured listener tuples" {
  install_all_doctor_success_mocks
  install_endpoint_probe_python_mock

  VM_X86_REDFISH_LISTEN_IP=192.0.2.20 \
    VM_X86_REDFISH_LISTEN_PORT=9000 \
    VM_X86_REDFISH_SERIAL_MODE=tcp \
    VM_X86_REDFISH_SERIAL_LISTEN_IP=192.0.2.20 \
    VM_X86_REDFISH_SERIAL_LISTEN_PORT=9000 \
    run ./scripts/doctor

  [ "$status" -ne 0 ]
  [[ "$output" == *"Redfish and TCP serial listeners cannot use the same address and port"* ]]
}

@test "doctor reports missing uuidgen with Fedora package hint" {
  install_all_doctor_success_mocks
  rm "$BATS_TEST_TMPDIR/bin/uuidgen"
  PATH="$BATS_TEST_TMPDIR/bin" run ./scripts/doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing command 'uuidgen': install util-linux-core"* ]]
}

@test "doctor reports missing timeout with Fedora package hint" {
  install_all_doctor_success_mocks
  rm "$BATS_TEST_TMPDIR/bin/timeout"
  PATH="$BATS_TEST_TMPDIR/bin" run ./scripts/doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing command 'timeout': install coreutils"* ]]
}

@test "doctor reports missing libvirt development headers" {
  install_all_doctor_success_mocks
  install_mock_command pkg-config 'exit 1'
  run ./scripts/doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing libvirt development headers"* ]]
}

@test "doctor rejects inactive default network" {
  install_all_doctor_success_mocks
  install_mock_command virsh '
case "$*" in
  *"version") printf "Using library: libvirt 12.0.0\n" ;;
  *"net-info default") printf "Active: no\n" ;;
  *"pool-info default") printf "State: running\n" ;;
  *) exit 0 ;;
esac
'
  run ./scripts/doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"libvirt default network is inactive"* ]]
}

@test "doctor rejects inactive default storage pool" {
  install_all_doctor_success_mocks
  install_mock_command virsh '
case "$*" in
  *"version") printf "Using library: libvirt 12.0.0\n" ;;
  *"net-info default") printf "Active: yes\n" ;;
  *"pool-info default") printf "State: inactive\n" ;;
  *) exit 0 ;;
esac
'
  run ./scripts/doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"libvirt storage pool 'default' is not running"* ]]
}

@test "doctor does not create VM runtime state" {
  install_all_doctor_success_mocks
  doctor_workdir="$BATS_TEST_TMPDIR/doctor-workdir"
  mkdir -p "$doctor_workdir"
  cd "$doctor_workdir"
  unset VM_X86_REDFISH_STATE_DIR VM_X86_REDFISH_ARTIFACTS_DIR

  run "$REPO_ROOT/scripts/doctor"
  [ "$status" -eq 0 ]
  [ ! -e .state ]
  [ ! -e .artifacts ]
  [ ! -e .venv ]
}
