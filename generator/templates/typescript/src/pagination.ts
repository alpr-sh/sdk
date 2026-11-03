import type { Pagination } from "./models.ts";

/** One page of a list, and where the list ends. */
export interface Page<T> {
  items: T[];
  pagination: Pagination;
}

/**
 * Walks pages from `first` until the last one, as Polar's SDKs do, yielding
 * every item. An error ends the walk.
 */
export async function* iterate<T>(fetch: (page: number) => Promise<Page<T>>, first = 1): AsyncGenerator<T, void, undefined> {
  for (let page = Math.max(first, 1); ; page++) {
    const result = await fetch(page);
    yield* result.items;
    if (page >= result.pagination.max_page) {
      return;
    }
  }
}
