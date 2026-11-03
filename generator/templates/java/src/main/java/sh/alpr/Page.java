package sh.alpr;

import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.function.Function;
import java.util.function.IntFunction;

/**
 * One page of a list, and where the list ends.
 *
 * @param <T> the resource listed
 */
public final class Page<T> {
    private final List<T> items;
    private final Pagination pagination;

    /**
     * A page.
     *
     * @param items the page's items
     * @param pagination how many items and pages the list has
     */
    public Page(List<T> items, Pagination pagination) {
        this.items = Collections.unmodifiableList(items);
        this.pagination = pagination;
    }

    /** @return the page's items */
    public List<T> getItems() {
        return items;
    }

    /** @return how many items and pages the list has */
    public Pagination getPagination() {
        return pagination;
    }

    static <T> Page<T> fromJson(Object value, Function<Object, T> item) {
        Map<String, Object> data = Json.asObject(value);
        List<T> items = Json.optional(data, "items", Json.list(item));
        return new Page<>(items == null ? Collections.emptyList() : items, Json.required(data, "pagination", Json.model(Pagination::fromJson)));
    }

    /**
     * Walks pages from first (1 when less) until the last one, as Polar's
     * SDKs do, fetching each page only when the previous one is used up.
     */
    static <T> Iterable<T> iterate(IntFunction<Page<T>> fetch, Integer first) {
        int start = first == null || first < 1 ? 1 : first;
        return () -> new Iterator<T>() {
            private int page = start - 1;
            private Iterator<T> items = Collections.emptyIterator();
            private boolean last;

            @Override
            public boolean hasNext() {
                while (!items.hasNext()) {
                    if (last) {
                        return false;
                    }
                    page++;
                    Page<T> result = fetch.apply(page);
                    items = result.getItems().iterator();
                    last = page >= result.getPagination().getMaxPage();
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
