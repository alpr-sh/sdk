from __future__ import annotations

from collections.abc import Callable, Iterator
from dataclasses import dataclass
from typing import Any, Generic, TypeVar

from .models import Pagination

T = TypeVar("T")


@dataclass(frozen=True)
class Page(Generic[T]):
    """One page of a list, and where the list ends."""

    items: list[T]
    pagination: Pagination

    @classmethod
    def from_dict(cls, data: dict[str, Any], item: Callable[[dict[str, Any]], T]) -> Page[T]:
        return cls(items=[item(each) for each in data.get("items") or []], pagination=Pagination.from_dict(data["pagination"]))


def iterate(fetch: Callable[[int], Page[T]], first: int | None = None) -> Iterator[T]:
    """Walks pages from ``first`` until the last one, as Polar's SDKs do, yielding every item."""
    page = max(first or 1, 1)
    while True:
        result = fetch(page)
        yield from result.items
        if page >= result.pagination.max_page:
            return
        page += 1
