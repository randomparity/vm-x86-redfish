from __future__ import annotations

import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any, cast

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "python"))

import sitecustomize
from sushy_tools import error
from sushy_tools.emulator.resources import vmedia
from sushy_tools.emulator.resources.systems import libvirtdriver

sitecustomize.patch()


class Response:
    def __init__(self, headers: dict[str, str], chunks: list[bytes]) -> None:
        self.headers = headers
        self._chunks = chunks

    def iter_content(self, chunk_size: int) -> Iterator[bytes]:
        assert chunk_size == 8192
        yield from self._chunks


def test_content_disposition_filename_cannot_escape_tmpdir(tmp_path: Path) -> None:
    outside = tmp_path / "outside-vmedia"
    outside.write_text("unchanged", encoding="utf-8")
    tmp_file = tmp_path / "download"
    tmp_file.touch()
    response = Response(
        {"content-disposition": 'attachment; filename="../outside-vmedia"'},
        [b"payload"],
    )

    with (
        tmp_file.open("w+b") as handle,
        pytest.raises(error.FishyError, match="Unsafe virtual media filename"),
    ):
        vmedia._write_from_response("http://media.local/image.iso", response, handle)

    assert outside.read_text(encoding="utf-8") == "unchanged"


def test_virtual_media_download_is_size_bounded(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(sitecustomize, "VMEDIA_MAX_BYTES", 3)
    tmp_file = tmp_path / "download"
    tmp_file.touch()
    response = Response({}, [b"ab", b"cd"])

    with (
        tmp_file.open("w+b") as handle,
        pytest.raises(error.FishyError, match="Virtual media image is too large"),
    ):
        vmedia._write_from_response("http://media.local/image.iso", response, handle)


def test_virtual_media_fetch_uses_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[dict[str, object]] = []

    def fake_get(*_args: object, **kwargs: object) -> object:
        calls.append(kwargs)
        return object()

    monkeypatch.setattr(vmedia, "_VM_X86_REDFISH_PATCHED", False, raising=False)
    monkeypatch.setattr(vmedia.requests, "get", fake_get)
    sitecustomize.patch()

    vmedia.requests.get("http://media.local/image.iso", stream=True)

    assert calls == [{"stream": True, "timeout": sitecustomize.VMEDIA_REQUEST_TIMEOUT}]


def test_project_media_volume_name_has_owned_prefix() -> None:
    assert sitecustomize._project_media_volume_name(
        "/tmp/fedora netinst.iso",
        "11111111-2222-4333-8444-555555555555",
    ) == ("vm-x86-redfish-media-fedora netinst-iso-11111111-2222-4333-8444-555555555555.img")


def test_upload_image_records_manifest_before_upload_failure(tmp_path: Path) -> None:
    boot_image = tmp_path / "fedora.iso"
    boot_image.write_bytes(b"iso")
    state_dir = tmp_path / "state"
    state_dir.mkdir()

    class Domain:
        def UUIDString(self) -> str:
            return "11111111-2222-4333-8444-555555555555"

    class Pool:
        def XMLDesc(self) -> str:
            return "<pool><target><path>/var/lib/libvirt/images</path></target></pool>"

        def listAllVolumes(self) -> list[object]:
            return []

        def createXML(self, _xml: str) -> object:
            return Volume()

    class Volume:
        def upload(self, _stream: object, _offset: int, _length: int) -> None:
            return None

    class Stream:
        def sendAll(self, _reader: object, _source: object) -> None:
            raise RuntimeError("upload failed")

    class Connection:
        def storagePoolLookupByName(self, _name: str) -> Pool:
            return Pool()

        def newStream(self) -> Stream:
            return Stream()

    class Driver:
        STORAGE_POOL = "default"
        STORAGE_VOLUME_XML = "%(name)s %(path)s %(size)s"

        def __init__(self) -> None:
            self._config = {"SUSHY_EMULATOR_STATE_DIR": str(state_dir)}

    upload_image = cast(Any, libvirtdriver.LibvirtDriver._upload_image)
    with pytest.raises(RuntimeError, match="upload failed"):
        upload_image(Driver(), Domain(), Connection(), str(boot_image))

    assert (state_dir / "media-volumes").read_text(encoding="utf-8") == (
        "vm-x86-redfish-media-fedora-iso-11111111-2222-4333-8444-555555555555.img\n"
    )
