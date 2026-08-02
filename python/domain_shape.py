"""Validate the hardware shape of a project-owned libvirt domain."""

import sys
import xml.etree.ElementTree as ET
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path


class Mismatch(Exception):
    """The domain hardware differs from the expected project shape."""


class SerialMismatch(Mismatch):
    """The domain serial transport differs from the configured endpoint."""


@dataclass(frozen=True)
class DomainExpectation:
    root: ET.Element
    domain_name: str
    root_path: str
    serial_mode: str
    serial_listen_ip: str
    serial_listen_port: str


def require(condition: bool) -> None:
    if not condition:
        raise Mismatch


def serial_require(condition: bool) -> None:
    if not condition:
        raise SerialMismatch


def one(elements: list[ET.Element]) -> ET.Element:
    require(len(elements) == 1)
    return elements[0]


def serial_one(elements: list[ET.Element]) -> ET.Element:
    serial_require(len(elements) == 1)
    return elements[0]


def child(parent: ET.Element, name: str) -> ET.Element:
    element = parent.find(name)
    if element is None:
        raise Mismatch
    return element


def text(parent: ET.Element, name: str) -> str:
    return child(parent, name).text or ""


def serial_children_match(
    parent: ET.Element, expected: dict[str, int], *, allow_alias: bool = False
) -> None:
    alias_count = 0
    actual = {name: 0 for name in expected}
    for element in parent:
        if element.tag == "alias":
            serial_require(allow_alias)
            alias_count += 1
            serial_require(alias_count == 1)
            serial_require(element.attrib == {"name": "serial0"})
            serial_require(not list(element))
            continue
        serial_require(element.tag in actual)
        actual[element.tag] += 1
    serial_require(actual == expected)


def serial_child(parent: ET.Element, name: str, attributes: dict[str, str]) -> ET.Element:
    element = serial_one(parent.findall(name))
    serial_require(element.attrib == attributes)
    return element


def serial_leaf(parent: ET.Element, name: str, attributes: dict[str, str]) -> ET.Element:
    element = serial_child(parent, name, attributes)
    serial_require(not list(element))
    return element


def validate_serial_transport(
    expected: DomainExpectation, serial: ET.Element, console: ET.Element
) -> None:
    if expected.serial_mode == "pty":
        serial_require(serial.attrib == {"type": "pty"})
        serial_require(console.attrib == {"type": "pty"})
        serial_children_match(serial, {"target": 1}, allow_alias=True)
        serial_children_match(console, {"target": 1}, allow_alias=True)
        return

    serial_require(expected.serial_mode == "tcp")
    serial_require(serial.attrib == {"type": "tcp"})
    serial_require(console.attrib == {"type": "tcp"})
    expected_source = {
        "mode": "bind",
        "host": expected.serial_listen_ip,
        "service": expected.serial_listen_port,
    }
    for device in (serial, console):
        serial_children_match(device, {"source": 1, "protocol": 1, "target": 1}, allow_alias=True)
        serial_leaf(device, "source", expected_source)
        serial_leaf(device, "protocol", {"type": "raw"})


def validate_serial_targets(serial: ET.Element, console: ET.Element) -> None:
    serial_target = serial_child(serial, "target", {"type": "isa-serial", "port": "0"})
    console_target = serial_child(console, "target", {"type": "serial", "port": "0"})
    serial_children_match(serial_target, {"model": 1})
    serial_children_match(console_target, {})
    serial_leaf(serial_target, "model", {"name": "isa-serial"})


def validate_serial_metadata(expected: DomainExpectation) -> None:
    namespace = "https://github.com/randomparity/vm-x86-redfish"
    metadata = serial_one(expected.root.findall("metadata"))
    container = serial_one(metadata.findall(f"{{{namespace}}}vm-x86-redfish"))
    serial_require(container.attrib == {})

    values = {
        "serial-mode": expected.serial_mode,
        "serial-listen-ip": expected.serial_listen_ip,
        "serial-listen-port": expected.serial_listen_port,
    }
    for name, value in values.items():
        tag = f"{{{namespace}}}{name}"
        serial_require(not metadata.findall(tag))
        element = serial_one(container.findall(tag))
        serial_require(element.attrib == {})
        serial_require(not list(element))
        serial_require((element.text or "") == value)


def validate_serial(expected: DomainExpectation, devices: ET.Element) -> None:
    serial = serial_one(devices.findall("serial"))
    console = serial_one(devices.findall("console"))
    validate_serial_transport(expected, serial, console)
    validate_serial_targets(serial, console)
    validate_serial_metadata(expected)


def validate_domain(expected: DomainExpectation) -> None:
    root = expected.root
    require(root.tag == "domain")
    require(root.get("type") == "kvm")
    require(text(root, "name") == expected.domain_name)
    os_element = child(root, "os")
    boot_entries = os_element.findall("boot")
    require(len(boot_entries) == 1)
    require(boot_entries[0].get("dev") == "hd")
    devices = child(root, "devices")
    require(not any(True for _ in devices.iter("hostdev")))
    require(not any(True for _ in devices.iter("boot")))
    disk = one(devices.findall("disk"))
    require(disk.get("type") == "file")
    require(disk.get("device") == "disk")
    driver = child(disk, "driver")
    require(driver.get("name") == "qemu")
    require(driver.get("type") == "qcow2")
    require(driver.get("discard") == "unmap")
    require(child(disk, "source").get("file") == expected.root_path)
    target = child(disk, "target")
    require(target.get("dev") == "vda")
    require(target.get("bus") == "virtio")
    interface = one(devices.findall("interface"))
    require(interface.get("type") == "network")
    require(child(interface, "source").get("network") == "default")
    require(child(interface, "model").get("type") == "virtio")
    validate_serial(expected, devices)
    channel = one(devices.findall("channel"))
    channel_target = child(channel, "target")
    require(channel.get("type") == "unix")
    require(channel_target.get("type") == "virtio")
    require(channel_target.get("name") == "org.qemu.guest_agent.0")
    graphics = one(devices.findall("graphics"))
    require(graphics.get("type") == "vnc")
    listen = graphics.get("listen")
    listen_element = graphics.find("listen")
    if listen is None and listen_element is not None:
        listen = listen_element.get("address")
    require(listen == "127.0.0.1")
    video_model = child(one(devices.findall("video")), "model")
    require(video_model.get("type") == "virtio")
    require(text(devices, "emulator") == "/usr/bin/qemu-system-x86_64")


def expectation_from_args(args: Sequence[str]) -> DomainExpectation:
    xml_path, domain_name, root_path, serial_mode, serial_listen_ip, serial_listen_port = args
    root = ET.parse(Path(xml_path)).getroot()
    return DomainExpectation(
        root,
        domain_name,
        root_path,
        serial_mode,
        serial_listen_ip,
        serial_listen_port,
    )


def main(args: Sequence[str]) -> int:
    try:
        validate_domain(expectation_from_args(args))
    except ET.ParseError:
        return 1
    except SerialMismatch:
        return 2
    except Mismatch:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
