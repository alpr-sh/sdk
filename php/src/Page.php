<?php

declare(strict_types=1);

namespace Alpr;

/**
 * One page of a list: its items, and the cursor of the next page.
 *
 * @template T
 */
final class Page
{
    /**
     * @param list<T> $items
     * @param ?string $next the cursor to ask the next page with; null on the last page
     */
    public function __construct(
        public readonly array $items,
        public readonly ?string $next,
    ) {
    }

    /**
     * @template U
     * @param array<string, mixed> $data the answer: {"data": [...], "next": cursor or null}
     * @param callable(array<string, mixed>): U $item
     * @return Page<U>
     */
    public static function fromArray(array $data, callable $item, string $nextField = 'next'): self
    {
        $items = [];
        $listed = $data['data'] ?? [];
        foreach (is_array($listed) ? $listed : [] as $each) {
            if (is_array($each)) {
                $items[] = $item($each);
            }
        }
        $next = $data[$nextField] ?? null;
        return new self($items, is_string($next) && $next !== '' ? $next : null);
    }

    /**
     * Walks pages from the cursor $first (the newest page when null) until the
     * last one, yielding every item. It stops when the next cursor is the one
     * just used, and at the first error, which the generator throws.
     *
     * @template U
     * @param callable(?string): Page<U> $fetch
     * @return \Generator<int, U>
     */
    public static function iterate(callable $fetch, ?string $first = null): \Generator
    {
        $cursor = $first === '' ? null : $first;
        while (true) {
            $result = $fetch($cursor);
            foreach ($result->items as $item) {
                yield $item;
            }
            // A cursor that does not move would ask for the same page forever.
            if ($result->next === null || $result->next === $cursor) {
                return;
            }
            $cursor = $result->next;
        }
    }
}
