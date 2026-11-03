package sh.alpr;

/** A request Alpr.sh did not sign, or signed too long ago. */
public final class WebhookVerificationException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    /** The refusal of a webhook. */
    public WebhookVerificationException() {
        super("alpr: webhook signature does not verify");
    }
}
