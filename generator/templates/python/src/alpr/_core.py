from __future__ import annotations

from typing import Any, Protocol
from urllib.parse import quote


class Requester(Protocol):
    """What a service calls the API through."""

    def request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, Any] | None = None,
        body: Any = None,
        idempotency_key: str | None = None,
        api_key: str | None = None,
    ) -> Any: ...


def segment(value: str) -> str:
    """A path parameter, escaped."""
    return quote(value, safe="")

