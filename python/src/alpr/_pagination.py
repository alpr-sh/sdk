from __future__ import annotations

from collections.abc import Callable, Iterator
from dataclasses import dataclass
from typing import Any, Generic, TypeVar

T = TypeVar("T")


@dataclass(frozen=True)
class Page(Generic[T]):
    """One page of a list: its items, and the cursor of the next page."""

    items: list[T]
    next: str | None
    """The cursor to ask the next page with; None on the last page."""

    @classmethod
    def from_dict(cls, data: dict[str, Any], item: Callable[[dict[str, Any]], T], next_field: str) -> Page[T]:
        cursor = data.get(next_field)
        return cls(items=[item(each) for each in data.get("data") or []], next=cursor if isinstance(cursor, str) and cursor else None)


def iterate(fetch: Callable[[str | None], Page[T]], first: str | None = None) -> Iterator[T]:
    """Walks pages from the cursor ``first`` (the newest page when None) until the last one,
    yielding every item. It ends at the first error, which it raises, and when the next cursor
    is the one just used: a cursor that does not move would ask for the same page forever."""
    cursor = first
    while True:
        result = fetch(cursor)
        yield from result.items
        if not result.next or result.next == cursor:
            return
        cursor = result.next
