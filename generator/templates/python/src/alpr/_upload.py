from __future__ import annotations

import secrets


def image_type(data: bytes) -> tuple[str, str]:
    """The content type and file name of a photo: JPEG and PNG are what the API reads,
    and anything else goes as bytes for the API to refuse."""
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg", "photo.jpg"
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png", "photo.png"
    return "application/octet-stream", "photo"


def field_text(value: str | int | float | bool) -> str:
    """A value as the text of a multipart field: floats in the shortest decimal form (0.5, 1)."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        text = repr(value)
        return text[:-2] if text.endswith(".0") else text
    return str(value)


def _escape(name: str) -> str:
    return name.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "%0D").replace("\n", "%0A")


class Form:
    """A multipart/form-data body: one file and the text fields beside it."""

    def __init__(self) -> None:
        self._parts: list[tuple[str, bytes | None, str]] = []

    def text(self, name: str, value: str | int | float | bool) -> None:
        """Adds a text field."""
        self._parts.append((name, None, field_text(value)))

    def file(self, name: str, data: bytes) -> None:
        """Adds the photo, named and typed by what its first bytes say it is."""
        self._parts.append((name, bytes(data), ""))

    def encode(self) -> tuple[bytes, str]:
        """The body and its Content-Type, boundary included."""
        boundary = secrets.token_hex(24)
        out = bytearray()
        for name, data, value in self._parts:
            out += f"--{boundary}\r\n".encode()
            if data is None:
                out += f'Content-Disposition: form-data; name="{_escape(name)}"\r\n\r\n'.encode() + value.encode() + b"\r\n"
                continue
            kind, filename = image_type(data)
            out += f'Content-Disposition: form-data; name="{_escape(name)}"; filename="{filename}"\r\nContent-Type: {kind}\r\n\r\n'.encode()
            out += data + b"\r\n"
        out += f"--{boundary}--\r\n".encode()
        return bytes(out), f"multipart/form-data; boundary={boundary}"
