package sh.alpr;

/** Options for one call: another workspace's API key. */
public final class RequestOptions {
    private final String apiKey;

    private RequestOptions(Builder builder) {
        this.apiKey = builder.apiKey;
    }

    /** @return a builder of options */
    public static Builder builder() {
        return new Builder();
    }

    /** @return the API key this call is sent with, or null for the client's */
    public String getApiKey() {
        return apiKey;
    }

    /** Builds {@link RequestOptions}. */
    public static final class Builder {
        private String apiKey;

        private Builder() {
        }

        /**
         * Sends this call with another workspace's key.
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
