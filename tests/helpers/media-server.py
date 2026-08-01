"""Serve integration-test media from a kernel-selected loopback port."""

from __future__ import annotations

import argparse
import os
import shutil
import ssl
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


class MediaHandler(SimpleHTTPRequestHandler):
    """Serve one directory, optionally throttling response bodies."""

    server_directory: Path
    chunk_size: int
    chunk_delay: float
    content_disposition: str | None

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, directory=str(self.server_directory), **kwargs)

    def copyfile(self, source: Any, outputfile: Any) -> None:
        if self.chunk_delay == 0:
            shutil.copyfileobj(source, outputfile)
            return

        while chunk := source.read(self.chunk_size):
            try:
                outputfile.write(chunk)
                outputfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            time.sleep(self.chunk_delay)

    def log_message(self, format: str, *args: Any) -> None:
        return

    def end_headers(self) -> None:
        if self.content_disposition is not None:
            self.send_header("Content-Disposition", self.content_disposition)
        super().end_headers()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--port-file", required=True, type=Path)
    parser.add_argument("--ready-file", required=True, type=Path)
    parser.add_argument("--tls-cert", type=Path)
    parser.add_argument("--tls-key", type=Path)
    parser.add_argument("--chunk-size", type=int, default=64 * 1024)
    parser.add_argument("--chunk-delay", type=float, default=0)
    parser.add_argument("--content-disposition")
    args = parser.parse_args()
    if (args.tls_cert is None) != (args.tls_key is None):
        parser.error("--tls-cert and --tls-key must be provided together")
    if args.chunk_size <= 0:
        parser.error("--chunk-size must be positive")
    if args.chunk_delay < 0:
        parser.error("--chunk-delay must not be negative")
    return args


def write_atomic(path: Path, value: str) -> None:
    temporary_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary_path.write_text(value, encoding="utf-8")
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def main() -> None:
    args = parse_args()
    MediaHandler.server_directory = args.directory.resolve(strict=True)
    MediaHandler.chunk_size = args.chunk_size
    MediaHandler.chunk_delay = args.chunk_delay
    MediaHandler.content_disposition = args.content_disposition

    with ThreadingHTTPServer(("127.0.0.1", 0), MediaHandler) as server:
        if args.tls_cert is not None:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(args.tls_cert, args.tls_key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
        write_atomic(args.port_file, f"{server.server_port}\n")
        args.ready_file.write_text("ready\n", encoding="utf-8")
        server.serve_forever()


if __name__ == "__main__":
    main()
