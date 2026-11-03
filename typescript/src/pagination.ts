/** One page of a list: its items, and the cursor of the next page (null on the last). */
export interface Page<T> {
  items: T[];
  next: string | null;
}

/**
 * Walks pages from the cursor `first` (the newest page when absent) until
 * the last one, yielding every item. A cursor that does not move ends the
 * walk, and an error ends it too.
 */
export async function* iterate<T>(fetch: (cursor: string | undefined) => Promise<Page<T>>, first?: string): AsyncGenerator<T, void, undefined> {
  let cursor = first;
  for (;;) {
    const result = await fetch(cursor);
    yield* result.items;
    if (!result.next || result.next === cursor) {
      return;
    }
    cursor = result.next;
  }
}
