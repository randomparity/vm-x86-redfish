from __future__ import annotations

import os
from email.message import Message
from typing import Any
from urllib import parse as urlparse

VMEDIA_MAX_BYTES = 16 * 1024 * 1024 * 1024
VMEDIA_REQUEST_TIMEOUT = (5, 300)


def _filename_from_content_disposition(value: str) -> str | None:
    message = Message()
    message["content-disposition"] = value
    filename = message.get_param("filename", header="content-disposition")
    return str(filename) if filename else None


def _require_safe_leaf_filename(filename: str, error_type: Any) -> str:
    if filename in {"", ".", ".."}:
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


def patch() -> None:
    try:
        from sushy_tools import error
        from sushy_tools.emulator.resources import vmedia
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

    # B010: this is a deliberate dependency monkeypatch; direct assignment fails ty.
    setattr(vmedia.requests, "get", bounded_get)  # noqa: B010
    setattr(vmedia, "_write_from_response", write_from_response)  # noqa: B010
    setattr(vmedia, "_VM_X86_REDFISH_PATCHED", True)  # noqa: B010


patch()
