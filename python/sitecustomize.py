from __future__ import annotations

import os
import xml.etree.ElementTree as ET
from email.message import Message
from typing import Any
from urllib import parse as urlparse

VMEDIA_MAX_BYTES = 16 * 1024 * 1024 * 1024
VMEDIA_REQUEST_TIMEOUT = (5, 300)
PROJECT_MEDIA_VOLUME_PREFIX = "vm-x86-redfish-media-"


def _filename_from_content_disposition(value: str) -> str | None:
    message = Message()
    message["content-disposition"] = value
    filename = message.get_param("filename", header="content-disposition")
    return str(filename) if filename else None


def _require_safe_leaf_filename(filename: str, error_type: Any) -> str:
    if filename in {"", ".", ".."}:
        raise error_type("Unsafe virtual media filename", code=400)
    if any(ord(character) < 32 or ord(character) == 127 for character in filename):
        raise error_type("Unsafe virtual media filename", code=400)
    if os.path.isabs(filename) or "/" in filename or "\\" in filename:
        raise error_type("Unsafe virtual media filename", code=400)
    if os.path.basename(filename) != filename:
        raise error_type("Unsafe virtual media filename", code=400)
    return filename


def _response_filename(image_url: str, rsp: Any, error_type: Any) -> str:
    content_disposition = rsp.headers.get("content-disposition")
    if content_disposition:
        filename = _filename_from_content_disposition(content_disposition)
        if filename:
            return _require_safe_leaf_filename(filename, error_type)

    parsed_url = urlparse.urlparse(image_url)
    filename = os.path.basename(parsed_url.path) or "image.iso"
    return _require_safe_leaf_filename(filename, error_type)


def _project_media_volume_name(boot_image: str, identity: str) -> str:
    base = os.path.basename(boot_image).replace(".", "-")
    return f"{PROJECT_MEDIA_VOLUME_PREFIX}{base}-{identity}.img"


def _media_volume_manifest_path(config: Any, error_type: Any) -> str:
    state_dir = config.get("SUSHY_EMULATOR_STATE_DIR")
    if not state_dir:
        raise error_type("Missing Sushy state directory for virtual media cleanup")
    return os.path.join(state_dir, "media-volumes")


def _recorded_media_volumes(config: Any, error_type: Any) -> set[str]:
    manifest_path = _media_volume_manifest_path(config, error_type)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(manifest_path, flags)
    except FileNotFoundError:
        return set()
    with os.fdopen(fd, encoding="utf-8") as manifest:
        return {line.rstrip("\n") for line in manifest if line.rstrip("\n")}


def _record_media_volume(config: Any, image_name: str, error_type: Any) -> None:
    manifest_path = _media_volume_manifest_path(config, error_type)
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW

    fd = os.open(manifest_path, flags, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as manifest:
        manifest.write(f"{image_name}\n")


def patch() -> None:
    try:
        from sushy_tools import error
        from sushy_tools.emulator.resources import vmedia
        from sushy_tools.emulator.resources.systems import libvirtdriver
    except ImportError:
        return

    if getattr(vmedia, "_VM_X86_REDFISH_PATCHED", False):
        return

    original_get = vmedia.requests.get

    def bounded_get(*args: Any, **kwargs: Any) -> Any:
        kwargs.setdefault("timeout", VMEDIA_REQUEST_TIMEOUT)
        return original_get(*args, **kwargs)

    def write_from_response(image_url: str, rsp: Any, tmp_file: Any) -> str:
        local_file = _response_filename(image_url, rsp, error.FishyError)
        total_bytes = 0

        with open(tmp_file.name, "wb") as destination:
            for chunk in rsp.iter_content(chunk_size=8192):
                if not chunk:
                    continue
                total_bytes += len(chunk)
                if total_bytes > VMEDIA_MAX_BYTES:
                    raise error.FishyError("Virtual media image is too large", code=413)
                destination.write(chunk)

        return local_file

    def upload_image(driver: Any, domain: Any, conn: Any, boot_image: str) -> str:
        pool = conn.storagePoolLookupByName(driver.STORAGE_POOL)
        pool_tree = ET.fromstring(pool.XMLDesc())
        pool_path_element = pool_tree.find("target/path")
        if pool_path_element is None or pool_path_element.text is None:
            msg = f'Missing "target/path" tag in the libvirt storage pool "{driver.STORAGE_POOL}"'
            raise error.FishyError(msg)

        image_name = _project_media_volume_name(boot_image, domain.UUIDString())
        image_path = os.path.join(pool_path_element.text, image_name)
        image_size = os.stat(boot_image).st_size

        volume_names = [volume.name() for volume in pool.listAllVolumes()]
        recorded_volumes = _recorded_media_volumes(driver._config, error.FishyError)
        if image_name in volume_names and image_name not in recorded_volumes:
            msg = f"Refusing to replace unrecorded virtual media volume {image_name}"
            raise error.FishyError(msg)
        if image_name not in recorded_volumes:
            _record_media_volume(driver._config, image_name, error.FishyError)

        if image_name in volume_names:
            volume = pool.storageVolLookupByName(image_name)
            volume.delete()

        volume = pool.createXML(
            driver.STORAGE_VOLUME_XML
            % {
                "name": image_name,
                "path": image_path,
                "size": image_size,
            }
        )

        stream = conn.newStream()
        volume.upload(stream, 0, image_size)

        def read_file(_stream: Any, nbytes: int, source: Any) -> bytes:
            return source.read(nbytes)

        with open(boot_image, "rb") as source:
            stream.sendAll(read_file, source)
        stream.finish()

        return image_path

    # B010: this is a deliberate dependency monkeypatch; direct assignment fails ty.
    setattr(vmedia.requests, "get", bounded_get)  # noqa: B010
    setattr(vmedia, "_write_from_response", write_from_response)  # noqa: B010
    setattr(libvirtdriver.LibvirtDriver, "_upload_image", upload_image)  # noqa: B010
    setattr(vmedia, "_VM_X86_REDFISH_PATCHED", True)  # noqa: B010


patch()
