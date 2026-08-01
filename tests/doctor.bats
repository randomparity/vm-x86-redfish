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

@test "doctor rejects unavailable loopback port 8000" {
  install_all_doctor_success_mocks
  VM_X86_REDFISH_PORT_CHECK_RESULT=busy run ./scripts/doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"127.0.0.1:8000 is already in use"* ]]
}

@test "doctor accepts recently closed loopback connections" {
  python_bin="$(PATH="${PATH#*:}" UV_PYTHON_DOWNLOADS=never uv python find 3.13)"
  "$python_bin" - <<'PY'
import socket

with socket.socket() as server:
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 8000))
    server.listen()
    with socket.create_connection(("127.0.0.1", 8000)) as client:
        connection, _ = server.accept()
        with connection:
            connection.shutdown(socket.SHUT_WR)
            client.recv(1)
PY
  install_all_doctor_success_mocks
  install_mock_command uv "
case \"\$*\" in
  \"python find 3.13\") printf '%s\\n' '$python_bin' ;;
  *) exit 2 ;;
esac
"

  run ./scripts/doctor
  [ "$status" -eq 0 ]
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
