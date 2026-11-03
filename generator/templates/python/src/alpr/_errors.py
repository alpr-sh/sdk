from __future__ import annotations

import json
from collections.abc import Mapping
from typing import Any


class AlprError(Exception):
    """A request the API refused.

    ``code`` is the API's: invalid_credential, forbidden, not_found,
    invalid_request, conflict, idempotency_conflict, body_too_large or
    unavailable. ``fields`` says, for invalid_request, what is wrong with each
    field. ``retry_after`` is how many seconds to wait on a 429.
    """

    def __init__(self, status: int, code: str, message: str = "", fields: dict[str, list[str]] | None = None, retry_after: int | None = None) -> None:
        super().__init__(f"alpr: {status} {code}: {message}" if message else f"alpr: {status} {code}")
        self.status = status
        self.code = code
        self.message = message
        self.fields = fields or {}
        self.retry_after = retry_after

    @classmethod
    def from_response(cls, status: int, headers: Mapping[str, str], body: bytes) -> AlprError:
        data: dict[str, Any] = {}
        try:
            loaded = json.loads(body or b"{}")
            if isinstance(loaded, dict):
                data = loaded
        except ValueError:
            pass  # A refusal without a JSON body is still a refusal.
        retry_after = headers.get("retry-after", "")
        return cls(status, data.get("error", ""), data.get("message", ""), data.get("fields") or {}, int(retry_after) if retry_after.isdigit() else None)
