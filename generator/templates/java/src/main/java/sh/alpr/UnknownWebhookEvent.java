package sh.alpr;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/** An event of a name this SDK does not know yet, its body as it was sent. */
public final class UnknownWebhookEvent extends WebhookEvent {
    private final Map<String, Object> body;
    private final String raw;

    UnknownWebhookEvent(String event, String id, Map<String, Object> body, String raw) {
        super(event, id);
        this.body = Collections.unmodifiableMap(new LinkedHashMap<>(body));
        this.raw = raw;
    }

    /** @return the whole body, as JSON reads it */
    public Map<String, Object> getBody() {
        return body;
    }

    /** @return the whole body, as the text it was sent in */
    public String getRaw() {
        return raw;
    }
}
