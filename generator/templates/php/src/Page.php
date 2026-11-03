<?php

declare(strict_types=1);

namespace Alpr;

use Alpr\Models\Pagination;

/**
 * One page of a list, and where the list ends.
 *
 * @template T
 */
final class Page
{
    /**
     * @param list<T> $items
     */
    public function __construct(
        public readonly array $items,
        public readonly Pagination $pagination,
    ) {
    }

    /**
     * @template U
     * @param array<string, mixed> $data
     * @param callable(array<string, mixed>): U $item
     * @return Page<U>
     */
    public static function fromArray(array $data, callable $item): self
    {
        $items = [];
        foreach ($data['items'] ?? [] as $each) {
            $items[] = $item($each);
        }
        return new self($items, Pagination::fromArray($data['pagination']));
    }

    /**
     * Walks pages from $first until the last one, as Polar's SDKs do, yielding every item.
     *
     * @template U
     * @param callable(int): Page<U> $fetch
     * @return \Generator<int, U>
     */
    public static function iterate(callable $fetch, int $first = 1): \Generator
    {
        for ($page = max($first, 1); ; $page++) {
            $result = $fetch($page);
            foreach ($result->items as $item) {
                yield $item;
            }
            if ($page >= $result->pagination->maxPage) {
                return;
            }
        }
    }
}
