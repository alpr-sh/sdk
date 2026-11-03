package sh.alpr;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import org.junit.jupiter.api.Test;

class AlprTest {
    /** Answers every request with what answer says, recording what was sent. */
    private static final class Recorder implements Transport {
        final List<Request> seen = new ArrayList<>();
        private final Function<Request, Response> answer;

        Recorder(Function<Request, Response> answer) {
            this.answer = answer;
        }

        @Override
        public Response send(Request request) {
            seen.add(request);
            return answer.apply(request);
        }
    }

    private static Alpr client(Recorder recorder) {
        return Alpr.builder("prk_test_key").baseUrl("https://alpr.test/").transport(recorder).build();
    }

    private static Transport.Response json(int status, Map<String, String> headers, Object payload) {
        byte[] body = payload == null ? new byte[0] : Json.write(payload).getBytes(StandardCharsets.UTF_8);
        return new Transport.Response(status, headers, body);
    }

    private static Map<String, Object> product(String id) {
        Map<String, Object> product = new LinkedHashMap<>();
        product.put("id", id);
        product.put("name", "Curso");
        product.put("description", "");
        product.put("status", "active");
        product.put("created_at", "2026-10-17T00:00:00Z");
        return product;
    }

    private static Map<String, Object> data(Object value) {
        return Map.of("data", value);
    }

    private static Map<String, String> query(String url) {
        Map<String, String> query = new HashMap<>();
        String raw = URI.create(url).getRawQuery();
        if (raw != null) {
            for (String pair : raw.split("&")) {
                String[] parts = pair.split("=", 2);
                query.put(parts[0], parts.length > 1 ? parts[1] : "");
            }
        }
        return query;
    }

    @Test
    void aCallCarriesTheKeyAndUnwrapsTheData() {
        Recorder recorder = new Recorder(request -> json(200, Map.of(), data(product("prod_1"))));
        Product got = client(recorder).products().get("prod_1");
        assertEquals("prod_1", got.getId());
        assertEquals(Product.STATUS_ACTIVE, got.getStatus());
        Transport.Request seen = recorder.seen.get(0);
        assertEquals("GET", seen.getMethod());
        assertEquals("/api/v1/products/prod_1", URI.create(seen.getUrl()).getPath());
        assertEquals("Bearer prk_test_key", seen.getHeaders().get("Authorization"));
        assertEquals("alpr-java/" + Alpr.VERSION, seen.getHeaders().get("User-Agent"));
    }

    @Test
    void aWriteSendsItsBodyAndIdempotencyKey() {
        Recorder recorder = new Recorder(request -> json(201, Map.of(), data(product("prod_1"))));
        client(recorder).products().create(
                ProductsService.CreateParams.builder().name("Curso").build(),
                RequestOptions.builder().idempotencyKey("create-1").build());
        Transport.Request seen = recorder.seen.get(0);
        assertEquals("POST", seen.getMethod());
        assertEquals("create-1", seen.getHeaders().get("Idempotency-Key"));
        assertEquals("application/json", seen.getHeaders().get("Content-Type"));
        assertEquals(Map.of("name", "Curso"), Json.parse(new String(seen.getBody(), StandardCharsets.UTF_8)));
    }

    @Test
    void aBaseUrlMustBeHttpsUnlessItIsLoopback() {
        for (String base : List.of("https://alpr.sh", "http://localhost:8080", "http://LOCALHOST", "http://127.0.0.1:1", "http://127.255.0.3", "http://[::1]:8080")) {
            Alpr.builder("k").baseUrl(base).build();
        }
        for (String base : List.of("http://alpr.sh", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "http://10.0.0.1", "ftp://localhost", "alpr.sh", "", "http://[::2]", "http://127.0.0.300")) {
            IllegalArgumentException refused = assertThrows(IllegalArgumentException.class, () -> Alpr.builder("k").baseUrl(base).build(), base);
            assertTrue(refused.getMessage().contains("must be https"));
        }
    }

    @Test
    void aDiscountGoesThroughCreateGetListAndDelete() {
        String template = "{\"id\":\"__ID__\",\"name\":\"Black\",\"code\":null,\"type\":\"percentage\",\"basis_points\":1000,\"amount_cents\":0,\"currency\":\"BRL\",\"duration\":\"once\",\"duration_in_months\":0,\"max_redemptions\":null,\"max_redemptions_per_customer\":null,\"redemptions_count\":0,\"starts_at\":\"2026-10-17T00:00:00Z\",\"ends_at\":null,\"status\":\"active\",\"product_ids\":[\"prod_1\"],\"created_at\":\"2026-10-17T00:00:00Z\",\"modified_at\":\"2026-10-17T00:00:00Z\"}";
        Recorder recorder = new Recorder(request -> {
            if (request.getMethod().equals("POST")) {
                return json(201, Map.of(), data(Json.parse(template.replace("__ID__", "disc_1"))));
            }
            if (request.getMethod().equals("DELETE")) {
                return json(204, Map.of(), null);
            }
            if (URI.create(request.getUrl()).getPath().equals("/api/v1/discounts")) {
                String page = query(request.getUrl()).get("page");
                return json(200, Map.of(), data(Map.of(
                        "items", List.of(Json.parse(template.replace("__ID__", "disc_" + page))),
                        "pagination", Map.of("total_count", 2, "max_page", 2))));
            }
            return json(200, Map.of(), data(Json.parse(template.replace("__ID__", "disc_1"))));
        });
        Alpr alpr = client(recorder);
        Discount created = alpr.discounts().create(DiscountsService.CreateParams.builder().name("Black").type("percentage").duration("once").basisPoints(1000L).build());
        assertEquals("disc_1", created.getId());
        assertNull(created.getCode());
        assertEquals(List.of("prod_1"), created.getProductIds());
        assertEquals("Black", alpr.discounts().get("disc_1").getName());
        List<String> ids = new ArrayList<>();
        for (Discount each : alpr.discounts().listIter(DiscountsService.ListParams.builder().limit(1).build())) {
            ids.add(each.getId());
        }
        assertEquals(List.of("disc_1", "disc_2"), ids);
        alpr.discounts().delete("disc_1");
        List<String> requests = new ArrayList<>();
        for (Transport.Request each : recorder.seen) {
            requests.add(each.getMethod() + " " + URI.create(each.getUrl()).getPath());
        }
        assertEquals(List.of("POST /api/v1/discounts", "GET /api/v1/discounts/disc_1", "GET /api/v1/discounts", "GET /api/v1/discounts", "DELETE /api/v1/discounts/disc_1"), requests);
        assertEquals(Map.of("name", "Black", "type", "percentage", "duration", "once", "basis_points", 1000L), Json.parse(new String(recorder.seen.get(0).getBody(), StandardCharsets.UTF_8)));
    }

    @Test
    void aFreeFormValueDecodesNested() {
        String state = "{\"id\":\"cus_1\",\"name\":\"Ana\",\"email\":\"ana@example.com\",\"external_id\":\"\",\"status\":\"active\",\"created_at\":\"2026-10-17T00:00:00Z\",\"active_subscriptions\":[],\"granted_benefits\":[{\"id\":\"gr_1\",\"granted_at\":\"2026-10-17T00:00:00Z\",\"benefit_id\":\"ben_1\",\"benefit_type\":\"feature_flag\",\"benefit_metadata\":{\"flags\":{\"beta\":true,\"limits\":{\"seats\":5,\"tiers\":[\"a\",2,null,1.5]}}},\"properties\":{\"links\":[{\"url\":\"https://example.com\",\"expires\":null}]}}]}";
        Recorder recorder = new Recorder(request -> json(200, Map.of(), data(Json.parse(state))));
        CustomerStateBenefitGrant grant = client(recorder).customers().getState("cus_1").getGrantedBenefits().get(0);
        Map<?, ?> flags = (Map<?, ?>) grant.getBenefitMetadata().get("flags");
        Map<?, ?> limits = (Map<?, ?>) flags.get("limits");
        assertEquals(true, flags.get("beta"));
        assertEquals(5L, limits.get("seats"));
        assertEquals(java.util.Arrays.asList("a", 2L, null, 1.5), limits.get("tiers"));
        Map<?, ?> link = (Map<?, ?>) ((List<?>) grant.getProperties().get("links")).get(0);
        assertEquals("https://example.com", link.get("url"));
        assertTrue(link.containsKey("expires") && link.get("expires") == null);
    }

    @Test
    void aPostWithoutAKeyIsSentWithItsOwnAGetWithNone() {
        Recorder recorder = new Recorder(request -> json(201, Map.of(), data(product("prod_1"))));
        Alpr alpr = client(recorder);
        ProductsService.CreateParams params = ProductsService.CreateParams.builder().name("Curso").build();
        alpr.products().create(params);
        alpr.products().create(params);
        alpr.products().create(params, RequestOptions.builder().idempotencyKey("mine").build());
        alpr.products().get("prod_1");
        String uuid = "[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
        String first = recorder.seen.get(0).getHeaders().get("Idempotency-Key");
        String second = recorder.seen.get(1).getHeaders().get("Idempotency-Key");
        assertTrue(first.matches(uuid) && second.matches(uuid), first + " " + second);
        assertNotEquals(first, second);
        assertEquals("mine", recorder.seen.get(2).getHeaders().get("Idempotency-Key"));
        assertNull(recorder.seen.get(3).getHeaders().get("Idempotency-Key"));
    }

    @Test
    void iteratingWalksEveryPage() {
        Recorder recorder = new Recorder(request -> {
            String page = query(request.getUrl()).get("page");
            return json(200, Map.of(), data(Map.of(
                    "items", List.of(product("prod_" + page)),
                    "pagination", Map.of("total_count", 3, "max_page", 3))));
        });
        List<String> ids = new ArrayList<>();
        for (Product product : client(recorder).products().listIter(ProductsService.ListParams.builder().limit(1).build())) {
            ids.add(product.getId());
        }
        assertEquals(List.of("prod_1", "prod_2", "prod_3"), ids);
        assertEquals("1", query(recorder.seen.get(0).getUrl()).get("limit"));
    }

    @Test
    void aRefusalIsATypedError() {
        Recorder recorder = new Recorder(request -> URI.create(request.getUrl()).getPath().equals("/api/v1/customers")
                ? json(422, Map.of(), Map.of("error", "invalid_request", "fields", Map.of("email", List.of("send an e-mail"))))
                : json(429, Map.of("Retry-After", "7"), null));
        Alpr alpr = client(recorder);
        AlprException refused = assertThrows(AlprException.class,
                () -> alpr.customers().create(CustomersService.CreateParams.builder().name("x").email("x").build()));
        assertEquals(422, refused.getStatus());
        assertEquals("invalid_request", refused.getCode());
        assertEquals(List.of("send an e-mail"), refused.getFields().get("email"));
        AlprException limited = assertThrows(AlprException.class, () -> alpr.products().list());
        assertEquals(429, limited.getStatus());
        assertEquals(Integer.valueOf(7), limited.getRetryAfter());
    }

    // The webhook vectors every SDK checks: Standard Webhooks' own example, and
    // Alpr.sh events signed under two secrets, as while one is rotated.
    private static final String REFERENCE_SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
    private static final String OLD_SECRET = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=";
    private static final String NEW_SECRET = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=";
    private static final String ORDER_PAID = "{\"id\":\"msg_2\",\"type\":\"order.paid\",\"timestamp\":\"2026-10-22T12:00:00Z\",\"data\":{\"id\":\"ord_1\",\"customer_id\":\"cus_1\",\"product_id\":\"prod_1\",\"price_id\":\"price_1\",\"amount_cents\":12000,\"currency\":\"BRL\",\"status\":\"succeeded\",\"paid_at\":\"2026-10-22T12:00:00Z\",\"installments\":3,\"installment_interest_cents\":360}}";
    private static final String USAGE_RECORDED = "{\"id\":\"msg_3\",\"type\":\"usage_event.recorded\",\"timestamp\":\"2026-10-22T12:00:00Z\",\"data\":{\"event_id\":\"ue_1\",\"aggregate\":\"usage_event\",\"aggregate_id\":\"ue_1\",\"merchant_id\":\"mer_1\",\"environment\":\"test\"}}";
    private static final String PAYOUT_SENT = "{\"id\":\"msg_4\",\"type\":\"payout.sent\",\"timestamp\":\"2026-10-22T12:00:00Z\",\"data\":{\"payout_id\":\"po_1\",\"amount_cents\":5000}}";
    private static final long SIGNED_AT = 1792670400L;

    private static Map<String, String> webhookHeaders(String id, long at, String signature) {
        Map<String, String> headers = new HashMap<>();
        headers.put("Webhook-Id", id);
        headers.put("webhook-timestamp", Long.toString(at));
        headers.put("webhook-signature", signature);
        return headers;
    }

    @Test
    void theStandardWebhooksVectorVerifies() {
        byte[] body = "{\"test\": 2432232314}".getBytes(StandardCharsets.UTF_8);
        Map<String, String> headers = webhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 1614265330L, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=");
        Instant at = Instant.ofEpochSecond(1614265330L);
        Webhook.verifySignature(REFERENCE_SECRET, headers, body, at);
        byte[] changed = "{\"test\": 2432232314} ".getBytes(StandardCharsets.UTF_8);
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(REFERENCE_SECRET, headers, changed, at));
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(REFERENCE_SECRET, headers, body, at.plusSeconds(301)));
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(NEW_SECRET, headers, body, at));
    }

    @Test
    void aTimestampThatIsNotPlainDigitsIsRefused() {
        byte[] body = "{\"test\": 2432232314}".getBytes(StandardCharsets.UTF_8);
        String[][] cases = {{"+1614265330", "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8="}, {"\u00b2", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY="}, {"", "x"}, {"1_6", "x"}};
        for (String[] each : cases) {
            Map<String, String> headers = webhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 0L, "v1," + each[1]);
            headers.put("webhook-timestamp", each[0]);
            assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(REFERENCE_SECRET, headers, body, Instant.ofEpochSecond(1614265330L)), each[0]);
        }
    }

    @Test
    void aWebhookAnswersItsTypedEvent() {
        Instant now = Instant.ofEpochSecond(SIGNED_AT + 120);
        Map<String, String> headers = webhookHeaders("msg_2", SIGNED_AT, "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=");
        byte[] orderPaid = ORDER_PAID.getBytes(StandardCharsets.UTF_8);
        for (String secret : List.of(NEW_SECRET, OLD_SECRET)) {
            WebhookEvent event = Webhook.verify(secret, headers, orderPaid, now);
            OrderWebhookEvent order = assertInstanceOf(OrderWebhookEvent.class, event);
            assertEquals("order.paid", order.getType());
            assertEquals("ord_1", order.getData().getId());
            assertEquals(3L, order.getData().getInstallments());
            assertEquals(360L, order.getData().getInstallmentInterestCents());
        }
        assertThrows(WebhookVerificationException.class, () -> Webhook.verify(REFERENCE_SECRET, headers, orderPaid, now));
        WebhookEvent usage = Webhook.verify(NEW_SECRET, webhookHeaders("msg_3", SIGNED_AT, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="),
                USAGE_RECORDED.getBytes(StandardCharsets.UTF_8), now);
        assertEquals("mer_1", assertInstanceOf(IdentifiersWebhookEvent.class, usage).getData().get("merchant_id"));
        assertEquals("msg_3", usage.getId());
        WebhookEvent unknown = Webhook.verify(NEW_SECRET, webhookHeaders("msg_4", SIGNED_AT, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="),
                PAYOUT_SENT.getBytes(StandardCharsets.UTF_8), now);
        assertEquals("payout.sent", unknown.getType());
        assertEquals("po_1", assertInstanceOf(UnknownWebhookEvent.class, unknown).getData().get("payout_id"));
    }

    @Test
    void theRealHttpSendsAndReadsThroughTheJdkClient() throws IOException {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", exchange -> {
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            byte[] answer;
            if (!"Bearer prk_test_key".equals(exchange.getRequestHeaders().getFirst("Authorization"))) {
                exchange.getResponseHeaders().set("Retry-After", "3");
                answer = Json.write(Map.of("error", "invalid_credential")).getBytes(StandardCharsets.UTF_8);
                exchange.sendResponseHeaders(401, answer.length);
            } else {
                Map<String, Object> sent = Json.asObject(Json.parse(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8)));
                String idempotencyKey = exchange.getRequestHeaders().getFirst("Idempotency-Key");
                Map<String, Object> product = product("prod_1");
                product.put("name", sent.get("name"));
                product.put("description", idempotencyKey == null ? "" : idempotencyKey);
                product.put("created_at", exchange.getRequestMethod() + " " + exchange.getRequestURI());
                answer = Json.write(data(product)).getBytes(StandardCharsets.UTF_8);
                exchange.sendResponseHeaders(201, answer.length);
            }
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(answer);
            }
        });
        server.start();
        try {
            String base = "http://127.0.0.1:" + server.getAddress().getPort();
            Product product = Alpr.builder("prk_test_key").baseUrl(base).build().products().create(
                    ProductsService.CreateParams.builder().name("Curso").build(),
                    RequestOptions.builder().idempotencyKey("create-1").build());
            assertEquals("Curso", product.getName());
            assertEquals("create-1", product.getDescription());
            assertEquals("POST /api/v1/products", product.getCreatedAt());

            AlprException refused = assertThrows(AlprException.class,
                    () -> Alpr.builder("prk_test_other").baseUrl(base).build().products().get("prod_1"));
            assertEquals(401, refused.getStatus());
            assertEquals("invalid_credential", refused.getCode());
            assertEquals(Integer.valueOf(3), refused.getRetryAfter());
            assertFalse(refused.getMessage().isEmpty());
            assertTrue(refused.getFields().isEmpty());
        } finally {
            server.stop(0);
        }
    }
}
