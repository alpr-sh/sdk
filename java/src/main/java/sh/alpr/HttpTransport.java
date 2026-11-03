package sh.alpr;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** The JDK's HTTP client as the SDK's {@link Transport}. */
public final class HttpTransport implements Transport {
    private final HttpClient client;

    /** A transport over a new {@link HttpClient} that connects within 30 seconds and never follows a redirect. */
    public HttpTransport() {
        this(HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(30)).followRedirects(HttpClient.Redirect.NEVER).build());
    }

    /**
     * A transport over the given client, for a proxy, an executor or TLS of
     * the application's.
     *
     * @param client the client that sends the requests
     */
    public HttpTransport(HttpClient client) {
        this.client = client;
    }

    @Override
    public Response send(Request request) throws IOException, InterruptedException {
        HttpRequest.BodyPublisher body = request.getBody() == null
                ? HttpRequest.BodyPublishers.noBody()
                : HttpRequest.BodyPublishers.ofByteArray(request.getBody());
        HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(request.getUrl()))
                .timeout(request.getTimeout())
                .method(request.getMethod(), body);
        request.getHeaders().forEach(builder::header);
        HttpResponse<byte[]> response = client.send(builder.build(), HttpResponse.BodyHandlers.ofByteArray());
        Map<String, String> headers = new LinkedHashMap<>();
        for (Map.Entry<String, List<String>> header : response.headers().map().entrySet()) {
            headers.put(header.getKey(), String.join(", ", header.getValue()));
        }
        return new Response(response.statusCode(), headers, response.body());
    }
}
