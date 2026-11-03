package sh.alpr;

/** Options for one call: an idempotency key for a write, another organization's key. */
public final class RequestOptions {
    private final String idempotencyKey;
    private final String apiKey;

    private RequestOptions(Builder builder) {
        this.idempotencyKey = builder.idempotencyKey;
        this.apiKey = builder.apiKey;
    }

    /** @return a builder of options */
    public static Builder builder() {
        return new Builder();
    }

    /** @return the idempotency key, or null */
    public String getIdempotencyKey() {
        return idempotencyKey;
    }

    /** @return the API key this call is sent with, or null for the client's */
    public String getApiKey() {
        return apiKey;
    }

    /** Builds {@link RequestOptions}. */
    public static final class Builder {
        private String idempotencyKey;
        private String apiKey;

        private Builder() {
        }

        /**
         * Makes a write safe to repeat: the same key with the same body
         * answers the first response again; with another body, a 409.
         *
         * @param idempotencyKey the key
         * @return this builder
         */
        public Builder idempotencyKey(String idempotencyKey) {
            this.idempotencyKey = idempotencyKey;
            return this;
        }

        /**
         * Sends this call with another organization's key.
         *
         * @param apiKey the key
         * @return this builder
         */
        public Builder apiKey(String apiKey) {
            this.apiKey = apiKey;
            return this;
        }

        /** @return the options */
        public RequestOptions build() {
            return new RequestOptions(this);
        }
    }
}
