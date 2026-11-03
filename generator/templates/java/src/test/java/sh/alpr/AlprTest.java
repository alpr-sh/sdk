package sh.alpr;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNotNull;
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
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.junit.jupiter.api.Test;

class AlprTest {
    private static final String KEY = "alpr_live_" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    // jpeg and png start with the bytes the API tells them by.
    private static final byte[] JPEG = {(byte) 0xFF, (byte) 0xD8, (byte) 0xFF, (byte) 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00, 0x01};
    private static final byte[] PNG = {(byte) 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 'I', 'H', 'D', 'R'};

    private static final String RECOGNIZED = "{\"creditsRemaining\":41,\"imageHeight\":720,\"imageWidth\":1280,\"plates\":[{\"charConfs\":\"0.99,0.98,0.97,0.96,0.97,0.96,0.96\",\"conf\":97.3,\"coordinateBottom\":361,\"coordinateLeft\":120,\"coordinateRight\":300,\"coordinateTop\":301,\"createdAt\":\"2026-10-22T12:00:00-03:00\",\"plate\":\"BRA2E19\",\"plateType\":\"mercosul\",\"time\":\"2026-10-22T12:00:00-03:00\"}],\"processingTimeMs\":84}";

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
        return Alpr.builder(KEY).baseUrl("https://alpr.test/").transport(recorder).build();
    }

    private static Transport.Response answer(int status, Map<String, String> headers, String body) {
        return new Transport.Response(status, headers, body.getBytes(StandardCharsets.UTF_8));
    }

    private static Transport.Response ok(String body) {
        return answer(200, Map.of(), body);
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

    /** One part of a multipart body. */
    private static final class Part {
        final String name;
        final String filename;
        final String type;
        final byte[] data;

        Part(String name, String filename, String type, byte[] data) {
            this.name = name;
            this.filename = filename;
            this.type = type;
            this.data = data;
        }
    }

    private static List<Part> parts(String contentType, byte[] body) {
        assertTrue(contentType.startsWith("multipart/form-data; boundary="), contentType);
        String boundary = contentType.substring("multipart/form-data; boundary=".length());
        String text = "\r\n" + new String(body, StandardCharsets.ISO_8859_1);
        String[] chunks = text.split(Pattern.quote("\r\n--" + boundary), -1);
        assertEquals("", chunks[0]);
        assertEquals("--\r\n", chunks[chunks.length - 1], "the body is closed");
        List<Part> out = new ArrayList<>();
        for (int i = 1; i < chunks.length - 1; i++) {
            String chunk = chunks[i];
            assertTrue(chunk.startsWith("\r\n"));
            int end = chunk.indexOf("\r\n\r\n");
            String head = chunk.substring(2, end);
            Matcher name = Pattern.compile("name=\"([^\"]*)\"").matcher(head);
            assertTrue(name.find());
            Matcher filename = Pattern.compile("filename=\"([^\"]*)\"").matcher(head);
            Matcher type = Pattern.compile("(?im)^Content-Type: (.*)$").matcher(head);
            out.add(new Part(name.group(1), filename.find() ? filename.group(1) : null, type.find() ? type.group(1) : null,
                    chunk.substring(end + 4).getBytes(StandardCharsets.ISO_8859_1)));
        }
        return out;
    }

    private static Part part(List<Part> parts, String name) {
        return parts.stream().filter(each -> each.name.equals(name)).findFirst().orElse(null);
    }

    @Test
    void aCallCarriesTheKeyAndNoIdempotencyKey() {
        Recorder recorder = new Recorder(request -> ok("{\"data\":[{\"createdAt\":\"2026-10-01T09:00:00-03:00\",\"enabled\":true,\"id\":\"cam_1\",\"location\":\"Portaria\",\"name\":\"Portão\",\"protocol\":\"rtsp\",\"readingArea\":null},{\"createdAt\":\"2026-10-01T09:00:00-03:00\",\"enabled\":false,\"id\":\"cam_2\",\"location\":\"\",\"name\":\"Garagem\",\"protocol\":\"rtsp\",\"readingArea\":{\"box\":{\"height\":0.5,\"width\":0.5,\"x\":0.1,\"y\":0.2},\"points\":[[0.1,0.2],[0.6,0.2],[0.6,0.7]]}}]}"));
        List<Camera> cameras = client(recorder).cameras().list();
        Transport.Request seen = recorder.seen.get(0);
        assertEquals("GET", seen.getMethod());
        assertEquals("/api/v1/cameras", URI.create(seen.getUrl()).getPath());
        assertEquals("Bearer " + KEY, seen.getHeaders().get("Authorization"));
        assertEquals("application/json", seen.getHeaders().get("Accept"));
        assertEquals("alpr-java/" + Alpr.VERSION, seen.getHeaders().get("User-Agent"));
        assertTrue(seen.getHeaders().keySet().stream().noneMatch(name -> name.equalsIgnoreCase("Idempotency-Key")));
        assertEquals(2, cameras.size());
        assertEquals("cam_1", cameras.get(0).getId());
        assertTrue(cameras.get(0).getEnabled());
        assertNull(cameras.get(0).getReadingArea());
        ReadingArea area = cameras.get(1).getReadingArea();
        assertNotNull(area);
        assertEquals(0.1, area.getBox().getX());
        assertEquals(3, area.getPoints().size());
        assertEquals(0.6, area.getPoints().get(1).get(0));
    }

    @Test
    void aPhotoGoesAsMultipart() {
        Recorder recorder = new Recorder(request -> ok(RECOGNIZED));
        PhotoRecognition result = client(recorder).photos().recognize(
                PhotosService.RecognizeParams.builder().image(JPEG).lprConfidence(0.5).build());
        Transport.Request seen = recorder.seen.get(0);
        assertEquals("POST", seen.getMethod());
        assertEquals("/api/v1/recognize", URI.create(seen.getUrl()).getPath());
        List<Part> sent = parts(seen.getHeaders().get("Content-Type"), seen.getBody());
        Part image = part(sent, "image");
        assertArrayEquals(JPEG, image.data);
        assertEquals("photo.jpg", image.filename);
        assertEquals("image/jpeg", image.type);
        assertEquals("0.5", new String(part(sent, "lpr_confidence").data, StandardCharsets.UTF_8));
        assertNull(part(sent, "min_ocr_confidence"), "an option left out was sent");
        assertEquals(41L, result.getCreditsRemaining());
        assertEquals(1, result.getPlates().size());
        assertEquals("BRA2E19", result.getPlates().get(0).getPlate());
        assertEquals(97.3, result.getPlates().get(0).getConf());
        assertEquals(120L, result.getPlates().get(0).getCoordinateLeft());
    }

    @Test
    void aPhotoIsNamedByItsBytes() {
        Object[][] cases = {
            {JPEG, "photo.jpg", "image/jpeg"},
            {PNG, "photo.png", "image/png"},
            {"not an image".getBytes(StandardCharsets.UTF_8), "photo", "application/octet-stream"},
            {new byte[0], "photo", "application/octet-stream"},
        };
        for (Object[] each : cases) {
            Recorder recorder = new Recorder(request -> ok("{\"imageHeight\":10,\"imageWidth\":20,\"plates\":[],\"processingTimeMs\":3}"));
            PhotoDetection result = client(recorder).photos().detect(PhotosService.DetectParams.builder().image((byte[]) each[0]).build());
            Transport.Request seen = recorder.seen.get(0);
            Part image = part(parts(seen.getHeaders().get("Content-Type"), seen.getBody()), "image");
            assertEquals(each[1], image.filename);
            assertEquals(each[2], image.type);
            assertArrayEquals((byte[]) each[0], image.data);
            assertEquals(20L, result.getImageWidth());
            assertTrue(result.getPlates().isEmpty());
        }
    }

    @Test
    void aPhotoIsRequiredAndNumbersAreWrittenShort() {
        assertThrows(IllegalStateException.class, () -> PhotosService.RecognizeParams.builder().build());
        Recorder recorder = new Recorder(request -> ok(RECOGNIZED));
        client(recorder).photos().recognize(PhotosService.RecognizeParams.builder().image(JPEG).lprConfidence(1.0).minOcrConfidence(0.0001).build());
        Transport.Request seen = recorder.seen.get(0);
        List<Part> sent = parts(seen.getHeaders().get("Content-Type"), seen.getBody());
        assertEquals("1", new String(part(sent, "lpr_confidence").data, StandardCharsets.UTF_8));
        assertEquals("0.0001", new String(part(sent, "min_ocr_confidence").data, StandardCharsets.UTF_8));
    }

    @Test
    void aPlateImageIsReadByOcr() {
        Recorder recorder = new Recorder(request -> ok("{\"confidence\":0.91,\"creditsRemaining\":40,\"detectionId\":null,\"latencyMs\":12,\"plate\":\"ABC1234\"}"));
        PlateReading result = client(recorder).photos().ocr(PhotosService.OcrParams.builder().image(PNG).build());
        assertEquals("/api/v1/ocr", URI.create(recorder.seen.get(0).getUrl()).getPath());
        assertEquals("ABC1234", result.getPlate());
        assertNull(result.getDetectionId());
        assertEquals(0.91, result.getConfidence());
    }

    @Test
    void aDetectionImageIsALink() {
        Recorder recorder = new Recorder(request -> ok("{\"detectionId\":\"a/b\",\"expiresIn\":300,\"imageUrl\":\"https://alpr.sh/api/v1/detections/a/image/file?s=x\"}"));
        DetectionImageLink image = client(recorder).recognitions().image("a/b");
        assertEquals("https://alpr.test/api/v1/detections/a%2Fb/image", recorder.seen.get(0).getUrl());
        assertEquals(300L, image.getExpiresIn());
        assertEquals("a/b", image.getDetectionId());
        assertTrue(image.getImageUrl().startsWith("https://alpr.sh/"));
    }

    private static String reading(String id) {
        return "{\"cameraId\":null,\"capturedAt\":\"2026-10-22T12:00:00-03:00\",\"conf\":90,\"id\":\"" + id + "\",\"plate\":\"BRA2E19\",\"source\":\"api\"}";
    }

    @Test
    void iteratingWalksEveryPageByCursor() {
        Recorder recorder = new Recorder(request -> {
            String before = query(request.getUrl()).get("before");
            if (before == null) {
                return ok("{\"data\":[" + reading("r3") + "," + reading("r2") + "],\"next\":\"c2\"}");
            }
            assertEquals("c2", before);
            return ok("{\"data\":[" + reading("r1") + "],\"next\":null}");
        });
        Alpr alpr = client(recorder);
        List<String> ids = new ArrayList<>();
        for (Recognition each : alpr.recognitions().listIter(RecognitionsService.ListParams.builder().plate("BRA").source("api").build())) {
            ids.add(each.getId());
        }
        assertEquals(List.of("r3", "r2", "r1"), ids);
        assertEquals(2, recorder.seen.size());
        for (Transport.Request each : recorder.seen) {
            assertEquals("/api/v1/recognitions", URI.create(each.getUrl()).getPath());
            assertEquals("BRA", query(each.getUrl()).get("plate"));
            assertEquals("api", query(each.getUrl()).get("source"));
            assertFalse(query(each.getUrl()).containsKey("camera"));
        }
        assertFalse(query(recorder.seen.get(0).getUrl()).containsKey("before"), "the first request carries no cursor");
        assertEquals("c2", query(recorder.seen.get(1).getUrl()).get("before"));

        Page<Recognition> page = alpr.recognitions().list(RecognitionsService.ListParams.builder().before("c2").build());
        assertEquals(1, page.getItems().size());
        assertNull(page.getNext());
        assertFalse(page.hasNext());
        assertNull(page.getItems().get(0).getCameraId());
        assertEquals("c2", query(recorder.seen.get(2).getUrl()).get("before"));
    }

    @Test
    void aCursorThatDoesNotMoveEndsTheWalk() {
        Recorder recorder = new Recorder(request -> ok("{\"data\":[{\"cameraId\":\"cam_1\",\"capturedAt\":\"2026-10-22T12:00:00-03:00\",\"conf\":90,\"id\":\"r1\",\"plate\":\"ABC1234\",\"source\":\"camera\"}],\"next\":\"same\"}"));
        int items = 0;
        for (Recognition each : client(recorder).recognitions().listIter()) {
            assertEquals("cam_1", each.getCameraId());
            items++;
        }
        assertEquals(2, items);
        assertEquals(2, recorder.seen.size());
    }

    @Test
    void theWalkEndsAtTheFirstError() {
        AtomicInteger calls = new AtomicInteger();
        Recorder recorder = new Recorder(request -> {
            if (calls.incrementAndGet() == 1) {
                return ok("{\"data\":[" + reading("r1") + "],\"next\":\"c2\"}");
            }
            return answer(503, Map.of(), "{\"error\":\"engine_unavailable\",\"message\":\"Try again.\"}");
        });
        java.util.Iterator<Recognition> walk = client(recorder).recognitions().listIter().iterator();
        assertEquals("r1", walk.next().getId());
        AlprException refused = assertThrows(AlprException.class, walk::hasNext);
        assertEquals("engine_unavailable", refused.getCode());
        assertFalse(walk.hasNext());
        assertEquals(2, calls.get());
    }

    @Test
    void aRefusalIsATypedError() {
        Recorder recorder = new Recorder(request -> URI.create(request.getUrl()).getPath().equals("/api/v1/recognize")
                ? answer(402, Map.of(), "{\"error\":\"insufficient_credits\",\"message\":\"This workspace has no credits left.\"}")
                : answer(429, Map.of("Retry-After", "7"), "{\"error\":\"rate_limited\",\"message\":\"Too many requests.\"}"));
        Alpr alpr = client(recorder);
        AlprException refused = assertThrows(AlprException.class,
                () -> alpr.photos().recognize(PhotosService.RecognizeParams.builder().image(JPEG).build()));
        assertEquals(402, refused.getStatus());
        assertEquals("insufficient_credits", refused.getCode());
        assertEquals("This workspace has no credits left.", refused.getApiMessage());
        assertTrue(refused.getFields().isEmpty());
        assertNull(refused.getRetryAfter());
        AlprException limited = assertThrows(AlprException.class, () -> alpr.cameras().list());
        assertEquals(429, limited.getStatus());
        assertEquals("rate_limited", limited.getCode());
        assertEquals(Integer.valueOf(7), limited.getRetryAfter());
    }

    @Test
    void anErrorBodyThatIsNotJsonIsStillAnError() {
        Recorder recorder = new Recorder(request -> answer(502, Map.of(), "<html>Bad gateway</html>"));
        AlprException refused = assertThrows(AlprException.class, () -> client(recorder).cameras().list());
        assertEquals(502, refused.getStatus());
        assertEquals("", refused.getCode());
    }

    @Test
    void aCallCanUseAnotherKey() {
        Recorder recorder = new Recorder(request -> ok("{\"data\":[]}"));
        client(recorder).cameras().list(RequestOptions.builder().apiKey("alpr_live_other").build());
        assertEquals("Bearer alpr_live_other", recorder.seen.get(0).getHeaders().get("Authorization"));
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
    void theRealHttpSendsAMultipartPhotoAndNeverFollowsARedirect() throws IOException {
        AtomicInteger elsewhere = new AtomicInteger();
        HttpServer other = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        other.createContext("/", exchange -> {
            elsewhere.incrementAndGet();
            exchange.sendResponseHeaders(200, -1);
            exchange.close();
        });
        other.start();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", exchange -> {
            byte[] answer;
            int status = 200;
            if (exchange.getRequestURI().getPath().equals("/api/v1/cameras")) {
                exchange.getResponseHeaders().set("Location", "http://127.0.0.1:" + other.getAddress().getPort() + "/steal");
                exchange.sendResponseHeaders(302, -1);
                exchange.close();
                return;
            }
            List<Part> sent = parts(exchange.getRequestHeaders().getFirst("Content-Type"), exchange.getRequestBody().readAllBytes());
            if (!("Bearer " + KEY).equals(exchange.getRequestHeaders().getFirst("Authorization")) || !"photo.png".equals(part(sent, "image").filename)) {
                status = 400;
                answer = "{\"error\":\"invalid_image\",\"message\":\"The photo is not what was sent.\"}".getBytes(StandardCharsets.UTF_8);
            } else {
                answer = RECOGNIZED.getBytes(StandardCharsets.UTF_8);
            }
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(status, answer.length);
            try (OutputStream out = exchange.getResponseBody()) {
                out.write(answer);
            }
        });
        server.start();
        try {
            Alpr alpr = Alpr.builder(KEY).baseUrl("http://127.0.0.1:" + server.getAddress().getPort()).build();
            PhotoRecognition result = alpr.photos().recognize(PhotosService.RecognizeParams.builder().image(PNG).build());
            assertEquals("BRA2E19", result.getPlates().get(0).getPlate());
            AlprException redirected = assertThrows(AlprException.class, () -> alpr.cameras().list());
            assertEquals(302, redirected.getStatus());
            assertEquals(0, elsewhere.get(), "the redirect target was called");
        } finally {
            server.stop(0);
            other.stop(0);
        }
    }

    // The webhook vectors every SDK checks (generator/testdata/webhook-vectors.json):
    // Alpr.sh events signed under two secrets, as while one is rotated.
    private static final String NEW_SECRET = "whsec_SDK-test-secret-new-0123456789";
    private static final String OLD_SECRET = "whsec_SDK-test-secret-old-0123456789";
    private static final String OTHER_SECRET = "whsec_SDK-test-secret-other-012345678";
    private static final long SIGNED_AT = 1792670400L;
    private static final String SIGNED = Long.toString(SIGNED_AT);

    private static final String RECOGNITION_BODY = "{\"event\":\"recognition.created\",\"id\":\"rec_1\",\"tenant_id\":\"ws_1\",\"source\":\"camera\",\"camera_id\":\"cam_1\",\"plate\":\"BRA2E19\",\"confidence\":0.97,\"captured_at\":\"2026-10-22T11:59:58Z\"}";
    private static final String RECOGNITION_NEW = "sha256=97deaf1c8a9348f3a7d64ce68943f4e6b4cc44590df4caea4c16d6373fa7d623";
    private static final String RECOGNITION_OLD = "sha256=12b70f2a8838157260e3b9470befa2627c16c42fe5e4b1d80fb841e206f8c781";
    private static final String ALERT_BODY = "{\"event\":\"alert.triggered\",\"id\":\"alt_1\",\"tenant_id\":\"ws_1\",\"rule_id\":\"rule_1\",\"rule_name\":\"Veículo bloqueado\",\"recognition_id\":\"rec_1\",\"plate\":\"BRA2E19\",\"camera_id\":\"cam_1\",\"confidence\":0.97,\"captured_at\":\"2026-10-22T11:59:58Z\"}";
    private static final String ALERT_NEW = "sha256=0b84627fa4564b006237b52feca68ca3c8dfebc54d4e271e881105f75e2a962a";
    private static final String TEST_BODY = "{\"event\":\"webhook.test\",\"id\":\"evt_1\",\"tenant_id\":\"ws_1\",\"sent_at\":\"2026-10-22T12:00:00Z\"}";
    private static final String TEST_NEW = "sha256=f3064f502ba3ffe3e409d9186c89ce7e425ad1dcad34b73edbeb1ad8e0633245";
    private static final String UNKNOWN_BODY = "{\"event\":\"payout.sent\",\"id\":\"po_1\",\"tenant_id\":\"ws_1\"}";
    private static final String UNKNOWN_NEW = "sha256=cb5b4f83462c974ea9706723b97a28de5d591d2093aa62e8dc8e388997daa0d6";
    private static final String PLUS_SIGNATURE = "sha256=ceef0f02180106de386c85b403f2b448142e897911c1e6075725b7e8d2912771";

    private static final Instant NOW = Instant.ofEpochSecond(SIGNED_AT + 120);

    private static byte[] bytes(String text) {
        return text.getBytes(StandardCharsets.UTF_8);
    }

    private static Map<String, Object> webhookHeaders(String id, String stamp, String... signatures) {
        Map<String, Object> headers = new HashMap<>();
        headers.put("x-alprsh-delivery-id", id);
        headers.put("X-Alprsh-Timestamp", stamp);
        headers.put("X-ALPRSH-SIGNATURE", signatures.length == 1 ? signatures[0] : List.of(signatures));
        return headers;
    }

    @Test
    void theWebhookVectorVerifies() {
        byte[] body = bytes(RECOGNITION_BODY);
        Map<String, Object> headers = webhookHeaders("del_0001", SIGNED, RECOGNITION_NEW);
        Webhook.verifySignature(NEW_SECRET, headers, body, NOW);
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(NEW_SECRET, headers, bytes(RECOGNITION_BODY + " "), NOW), "a changed body verified");
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(NEW_SECRET, webhookHeaders("del_0009", SIGNED, RECOGNITION_NEW), body, NOW), "another delivery id verified");
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(NEW_SECRET, headers, body, Instant.ofEpochSecond(SIGNED_AT + 301)), "a stale webhook verified");
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(NEW_SECRET, headers, body, Instant.ofEpochSecond(SIGNED_AT - 301)), "a webhook from the future verified");
        Webhook.verifySignature(NEW_SECRET, headers, body, Instant.ofEpochSecond(SIGNED_AT + 300));
        Webhook.verifySignature(NEW_SECRET, headers, body, Instant.ofEpochSecond(SIGNED_AT - 300));
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(OTHER_SECRET, headers, body, NOW), "another secret verified");
        assertThrows(IllegalArgumentException.class, () -> Webhook.verifySignature("", headers, body, NOW), "an empty secret must be a configuration error");
        assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(NEW_SECRET, Map.of(), body, NOW), "a request with no headers verified");
        assertEquals(300L, Webhook.TOLERANCE.getSeconds());
    }

    @Test
    void aTimestampThatIsNotPlainDigitsIsRefused() {
        byte[] body = bytes(RECOGNITION_BODY);
        for (String stamp : List.of("+1792670400", "²", "", "1_7", " 1792670400", "1792670400 ")) {
            assertThrows(WebhookVerificationException.class,
                    () -> Webhook.verifySignature(NEW_SECRET, webhookHeaders("del_0001", stamp, PLUS_SIGNATURE), body, NOW), stamp);
        }
    }

    @Test
    void moreThanOneSignatureVerifiesDuringARotation() {
        byte[] body = bytes(RECOGNITION_BODY);
        Map<String, Map<String, Object>> rotations = new LinkedHashMap<>();
        rotations.put("one value", webhookHeaders("del_0001", SIGNED, RECOGNITION_OLD + "," + RECOGNITION_NEW));
        rotations.put("two lines", webhookHeaders("del_0001", SIGNED, RECOGNITION_OLD, RECOGNITION_NEW));
        rotations.put("with spaces", webhookHeaders("del_0001", SIGNED, RECOGNITION_OLD + ", " + RECOGNITION_NEW));
        for (Map.Entry<String, Map<String, Object>> each : rotations.entrySet()) {
            for (String secret : List.of(NEW_SECRET, OLD_SECRET)) {
                Webhook.verifySignature(secret, each.getValue(), body, NOW);
            }
            assertThrows(WebhookVerificationException.class, () -> Webhook.verifySignature(OTHER_SECRET, each.getValue(), body, NOW),
                    each.getKey() + ": a secret that signed nothing verified");
        }
        Map<String, String> refused = new LinkedHashMap<>();
        refused.put("a malformed one beside a good one", "sha256=zz," + RECOGNITION_NEW);
        refused.put("no prefix", RECOGNITION_NEW.substring("sha256=".length()));
        refused.put("a short one", "sha256=97de");
        refused.put("too many", (RECOGNITION_OLD + ",").repeat(6) + RECOGNITION_NEW);
        for (Map.Entry<String, String> each : refused.entrySet()) {
            assertThrows(WebhookVerificationException.class,
                    () -> Webhook.verifySignature(NEW_SECRET, webhookHeaders("del_0001", SIGNED, each.getValue()), body, NOW), each.getKey());
        }
        // Six entries are still accepted.
        Webhook.verifySignature(NEW_SECRET, webhookHeaders("del_0001", SIGNED, (RECOGNITION_OLD + ",").repeat(5) + RECOGNITION_NEW), body, NOW);
    }

    @Test
    void aWebhookAnswersItsTypedEvent() {
        WebhookEvent event = Webhook.verify(NEW_SECRET, webhookHeaders("del_0001", SIGNED, RECOGNITION_NEW), bytes(RECOGNITION_BODY), NOW);
        RecognitionCreatedWebhookEvent read = assertInstanceOf(RecognitionCreatedWebhookEvent.class, event);
        assertEquals("recognition.created", read.getEvent());
        assertEquals("rec_1", read.getId());
        assertEquals("BRA2E19", read.getPlate());
        assertEquals(0.97, read.getConfidence());
        assertEquals("cam_1", read.getCameraId());
        assertEquals("camera", read.getSource());
        assertEquals("ws_1", read.getTenantId());
        assertEquals("2026-10-22T11:59:58Z", read.getCapturedAt());

        AlertTriggeredWebhookEvent alert = assertInstanceOf(AlertTriggeredWebhookEvent.class,
                Webhook.verify(NEW_SECRET, webhookHeaders("del_0002", SIGNED, ALERT_NEW), bytes(ALERT_BODY), NOW));
        assertEquals("Veículo bloqueado", alert.getRuleName());
        assertEquals("rec_1", alert.getRecognitionId());
        assertEquals("rule_1", alert.getRuleId());

        TestWebhookEvent test = assertInstanceOf(TestWebhookEvent.class,
                Webhook.verify(NEW_SECRET, webhookHeaders("del_0003", SIGNED, TEST_NEW), bytes(TEST_BODY), NOW));
        assertEquals("webhook.test", test.getEvent());
        assertEquals("2026-10-22T12:00:00Z", test.getSentAt());

        UnknownWebhookEvent unknown = assertInstanceOf(UnknownWebhookEvent.class,
                Webhook.verify(NEW_SECRET, webhookHeaders("del_0004", SIGNED, UNKNOWN_NEW), bytes(UNKNOWN_BODY), NOW));
        assertEquals("payout.sent", unknown.getEvent());
        assertEquals("po_1", unknown.getId());
        assertEquals("ws_1", unknown.getBody().get("tenant_id"));
        assertEquals(UNKNOWN_BODY, unknown.getRaw());

        assertThrows(WebhookVerificationException.class,
                () -> Webhook.verify(NEW_SECRET, webhookHeaders("del_0005", SIGNED, "sha256=" + "0".repeat(64)), bytes("{\"id\":\"x\"}"), NOW));
    }

    @Test
    void aVerifiedBodyThatIsNotAnEventIsRefused() {
        assertThrows(IllegalArgumentException.class, () -> Webhook.event(bytes("[1]")), "a list is not an event");
        assertThrows(IllegalArgumentException.class, () -> Webhook.event(bytes("{\"id\":\"x\"}")), "a body with no event is not an event");
        assertThrows(IllegalArgumentException.class, () -> Webhook.event(bytes("{\"event\":3}")), "a body with a number as its event is not an event");
        assertThrows(IllegalArgumentException.class, () -> Webhook.event(bytes("not json")));
        assertEquals("x", ((UnknownWebhookEvent) Webhook.event(bytes("{\"event\":\"a.b\",\"id\":\"x\"}"))).getId());
        assertEquals("", ((UnknownWebhookEvent) Webhook.event(bytes("{\"event\":\"a.b\"}"))).getId());
    }
}
