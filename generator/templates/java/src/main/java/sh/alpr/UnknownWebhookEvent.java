package sh.alpr;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/** An event of a type this SDK does not know yet, its data as it was sent. */
public final class UnknownWebhookEvent extends WebhookEvent {
    private final Map<String, Object> data;

    UnknownWebhookEvent(String id, String type, String timestamp, Map<String, Object> data) {
        super(id, type, timestamp);
        this.data = Collections.unmodifiableMap(new LinkedHashMap<>(data));
    }

    /** @return the event's data, as JSON reads it */
    @Override
    public Map<String, Object> getData() {
        return data;
    }
}
