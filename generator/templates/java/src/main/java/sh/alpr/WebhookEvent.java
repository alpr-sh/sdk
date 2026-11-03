package sh.alpr;

/**
 * A webhook Alpr.sh sent, verified: one subclass a payload
 * ({@link RecognitionCreatedWebhookEvent} carries the fields of a
 * {@link WebhookRecognitionCreated}…), or {@link UnknownWebhookEvent} for an event
 * this SDK does not know yet. The body is flat: {@link #getEvent()} names
 * what happened and {@link #getId()} is the id of the read or alert, not of
 * the delivery. Deduplicate deliveries by the {@code X-Alprsh-Delivery-Id}
 * header.
 */
public abstract class WebhookEvent {
    private final String event;
    private final String id;

    WebhookEvent(String event, String id) {
        this.event = event;
        this.id = id;
    }

    /** @return the event's name: recognition.created… */
    public String getEvent() {
        return event;
    }

    /** @return the id the body carries (of the read or alert, not of the delivery); empty when the body has none */
    public String getId() {
        return id;
    }

    @Override
    public String toString() {
        return getClass().getSimpleName() + "{event=" + event + ", id=" + id + "}";
    }
}
