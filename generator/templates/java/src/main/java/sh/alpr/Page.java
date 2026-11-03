package sh.alpr;

import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.function.Function;

/**
 * One page of a list: its items, and the cursor of the next page.
 *
 * @param <T> the resource listed
 */
public final class Page<T> {
    private final List<T> items;
    private final String next;

    /**
     * A page.
     *
     * @param items the page's items
     * @param next the cursor of the next page, or null on the last
     */
    public Page(List<T> items, String next) {
        this.items = Collections.unmodifiableList(items);
        this.next = next == null || next.isEmpty() ? null : next;
    }

    /** @return the page's items */
    public List<T> getItems() {
        return items;
    }

    /** @return the cursor to ask the next page with, or null on the last page */
    public String getNext() {
        return next;
    }

    /** @return whether there is a page after this one */
    public boolean hasNext() {
        return next != null;
    }

    static <T> Page<T> fromJson(Object value, String nextName, Function<Object, T> item) {
        Map<String, Object> data = Json.asObject(value);
        List<T> items = Json.optional(data, "data", Json.list(item));
        return new Page<>(items == null ? Collections.emptyList() : items, Json.optional(data, nextName, Json::asString));
    }

    /**
     * Walks pages from the cursor first (the newest page when null or empty)
     * until the last one, fetching each page only when the previous one is
     * used up. A cursor that does not move would ask for the same page
     * forever, so it ends the walk; so does the first error, which the
     * iterator throws.
     */
    static <T> Iterable<T> iterate(Function<String, Page<T>> fetch, String first) {
        String start = first == null || first.isEmpty() ? null : first;
        return () -> new Iterator<T>() {
            private String cursor = start;
            private Iterator<T> items = Collections.emptyIterator();
            private boolean done;

            @Override
            public boolean hasNext() {
                while (!items.hasNext()) {
                    if (done) {
                        return false;
                    }
                    String used = cursor;
                    // Set before the fetch: if it throws, the walk is over.
                    done = true;
                    Page<T> result = fetch.apply(used);
                    items = result.getItems().iterator();
                    if (result.getNext() != null && !result.getNext().equals(used)) {
                        cursor = result.getNext();
                        done = false;
                    }
                }
                return true;
            }

            @Override
            public T next() {
                if (!hasNext()) {
                    throw new NoSuchElementException();
                }
                return items.next();
            }
        };
    }
}
