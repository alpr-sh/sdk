package sh.alpr;

import java.io.IOException;
import java.time.Duration;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Sends one request and answers the response. The SDK's own is
 * {@link HttpTransport}, the JDK's {@code java.net.http.HttpClient}; a test or
 * an application with its own HTTP stack passes another to
 * {@link Alpr.Builder#transport(Transport)}.
 */
@FunctionalInterface
public interface Transport {
    /**
     * Sends the request.
     *
     * @param request what to send
     * @return the response, whatever its status
     * @throws IOException when the request could not be sent or read
     * @throws InterruptedException when the thread was interrupted waiting
     */
    Response send(Request request) throws IOException, InterruptedException;

    /** One request: method, absolute URL, headers, body and how long to wait. */
    final class Request {
        private final String method;
        private final String url;
        private final Map<String, String> headers;
        private final byte[] body;
        private final Duration timeout;

        /**
         * A request.
         *
         * @param method the HTTP method
         * @param url the absolute URL, with its query
         * @param headers the headers to send
         * @param body the body, or null
         * @param timeout how long to wait for the response
         */
        public Request(String method, String url, Map<String, String> headers, byte[] body, Duration timeout) {
            this.method = method;
            this.url = url;
            this.headers = Collections.unmodifiableMap(new LinkedHashMap<>(headers));
            this.body = body == null ? null : body.clone();
            this.timeout = timeout;
        }

        /** @return the HTTP method */
        public String getMethod() {
            return method;
        }

        /** @return the absolute URL, with its query */
        public String getUrl() {
            return url;
        }

        /** @return the headers to send */
        public Map<String, String> getHeaders() {
            return headers;
        }

        /** @return the body, or null */
        public byte[] getBody() {
            return body == null ? null : body.clone();
        }

        /** @return how long to wait for the response */
        public Duration getTimeout() {
            return timeout;
        }
    }

    /** One response: status, headers by lower-case name, and body. */
    final class Response {
        private final int status;
        private final Map<String, String> headers;
        private final byte[] body;

        /**
         * A response.
         *
         * @param status the HTTP status
         * @param headers the headers; their names are read in lower case
         * @param body the body, empty when there is none
         */
        public Response(int status, Map<String, String> headers, byte[] body) {
            this.status = status;
            Map<String, String> lower = new LinkedHashMap<>();
            headers.forEach((name, value) -> lower.put(name.toLowerCase(Locale.ROOT), value));
            this.headers = Collections.unmodifiableMap(lower);
            this.body = body == null ? new byte[0] : body.clone();
        }

        /** @return the HTTP status */
        public int getStatus() {
            return status;
        }

        /** @return the headers by lower-case name */
        public Map<String, String> getHeaders() {
            return headers;
        }

        /** @return the body, empty when there is none */
        public byte[] getBody() {
            return body.clone();
        }
    }
}
