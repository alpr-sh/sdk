import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

from alpr import (
    Alpr,
    AlprError,
    AlertTriggeredWebhookEvent,
    RecognitionCreatedWebhookEvent,
    UnknownWebhookEvent,
    TestWebhookEvent,
    WebhookVerificationError,
    verify_webhook,
    verify_webhook_signature,
)
from alpr._client import _check_base_url
from alpr.webhooks import WEBHOOK_TOLERANCE_SECONDS, _verify_webhook_at, _verify_webhook_signature_at

KEY = "alpr_live_" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# A JPEG and a PNG start with the bytes the API tells them by.
JPEG = bytes([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + b"JFIF\x00\x01"
PNG = bytes([0x89]) + b"PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR"

RECOGNIZED = '{"creditsRemaining":41,"imageHeight":720,"imageWidth":1280,"plates":[{"charConfs":"0.99,0.98,0.97,0.96,0.97,0.96,0.96","conf":97.3,"coordinateBottom":361,"coordinateLeft":120,"coordinateRight":300,"coordinateTop":301,"createdAt":"2026-10-22T12:00:00-03:00","plate":"BRA2E19","plateType":"mercosul","time":"2026-10-22T12:00:00-03:00"}],"processingTimeMs":84}'


class Seen:
    """One request the fake server received."""

    def __init__(self, method: str, target: str, headers: Any, body: bytes) -> None:
        self.method = method
        self.target = target
        self.url = urlparse(target)
        self.headers = headers
        self.body = body

    @property
    def query(self) -> dict[str, list[str]]:
        return parse_qs(self.url.query, keep_blank_values=True)


class Fake:
    """A local HTTP server that answers what ``answer`` says and keeps what it was asked."""

    def __init__(self, answer: Any) -> None:
        self.seen: list[Seen] = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def serve(self) -> None:
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                request = Seen(self.command, self.path, self.headers, body)
                fake.seen.append(request)
                status, headers, payload = answer(request)
                self.send_response(status)
                for name, value in headers.items():
                    self.send_header(name, value)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            do_GET = serve
            do_POST = serve

            def log_message(self, *args: Any) -> None:
                pass

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


def ok(text: str) -> tuple[int, dict[str, str], bytes]:
    return 200, {"Content-Type": "application/json"}, text.encode()


class Case(unittest.TestCase):
    def serve(self, answer: Any) -> tuple[Alpr, Fake]:
        fake = Fake(answer)
        self.addCleanup(fake.close)
        return Alpr(KEY, base_url=fake.url), fake


def parts_of(seen: Seen) -> dict[str, tuple[dict[str, str], bytes]]:
    """The parts of a multipart body, by field name: (headers, content)."""
    content_type = seen.headers["Content-Type"]
    assert content_type.startswith("multipart/form-data; boundary="), content_type
    boundary = content_type.split("boundary=", 1)[1].encode()
    chunks = seen.body.split(b"--" + boundary)
    assert chunks[0] == b"" and chunks[-1] == b"--\r\n", chunks
    out: dict[str, tuple[dict[str, str], bytes]] = {}
    for chunk in chunks[1:-1]:
        assert chunk.startswith(b"\r\n") and chunk.endswith(b"\r\n"), chunk
        head, _, content = chunk[2:-2].partition(b"\r\n\r\n")
        headers = {}
        for line in head.decode().split("\r\n"):
            name, _, value = line.partition(": ")
            headers[name.lower()] = value
        name = headers["content-disposition"].split('name="', 1)[1].split('"', 1)[0]
        out[name] = (headers, content)
    return out


class ClientTest(Case):
    def test_a_call_carries_the_key_and_no_idempotency_key(self) -> None:
        def answer(request: Seen) -> tuple[int, dict[str, str], bytes]:
            return ok(
                '{"data":[{"createdAt":"2026-10-01T09:00:00-03:00","enabled":true,"id":"cam_1","location":"Portaria","name":"Portão","protocol":"rtsp","readingArea":null},'
                '{"createdAt":"2026-10-01T09:00:00-03:00","enabled":false,"id":"cam_2","location":"","name":"Garagem","protocol":"rtsp",'
                '"readingArea":{"box":{"height":0.5,"width":0.5,"x":0.1,"y":0.2},"points":[[0.1,0.2],[0.6,0.2],[0.6,0.7]]}}]}'
            )

        alpr, fake = self.serve(answer)
        cameras = alpr.cameras.list()
        request = fake.seen[0]
        self.assertEqual((request.method, request.url.path), ("GET", "/api/v1/cameras"))
        self.assertEqual(request.headers["Authorization"], "Bearer " + KEY)
        self.assertTrue(request.headers["User-Agent"].startswith("alpr-python/"))
        self.assertEqual(request.headers["Accept"], "application/json")
        self.assertIsNone(request.headers.get("Idempotency-Key"))
        self.assertEqual(len(cameras), 2)
        self.assertEqual((cameras[0].id, cameras[0].enabled, cameras[0].reading_area), ("cam_1", True, None))
        area = cameras[1].reading_area
        assert area is not None and area.box is not None and area.points is not None
        self.assertEqual((area.box.x, len(area.points), area.points[1][0]), (0.1, 3, 0.6))

    def test_a_photo_goes_as_multipart(self) -> None:
        alpr, fake = self.serve(lambda request: ok(RECOGNIZED))
        result = alpr.photos.recognize({"image": JPEG, "lpr_confidence": 0.5})
        request = fake.seen[0]
        self.assertEqual((request.method, request.url.path), ("POST", "/api/v1/recognize"))
        parts = parts_of(request)
        headers, sent = parts["image"]
        self.assertEqual(sent, JPEG)
        self.assertIn('filename="photo.jpg"', headers["content-disposition"])
        self.assertEqual(headers["content-type"], "image/jpeg")
        self.assertEqual(parts["lpr_confidence"][1], b"0.5")
        self.assertNotIn("min_ocr_confidence", parts, "an option left out was sent")
        self.assertEqual(result.credits_remaining, 41)
        self.assertEqual(len(result.plates), 1)
        plate = result.plates[0]
        self.assertEqual((plate.plate, plate.conf, plate.coordinate_left, plate.char_confs[:4]), ("BRA2E19", 97.3, 120, "0.99"))
        self.assertEqual((result.image_height, result.processing_time_ms), (720, 84))

    def test_a_photo_is_named_by_its_bytes(self) -> None:
        cases = {
            "jpeg": (JPEG, "photo.jpg", "image/jpeg"),
            "png": (PNG, "photo.png", "image/png"),
            "other": (b"not an image", "photo", "application/octet-stream"),
        }
        for name, (data, filename, kind) in cases.items():
            with self.subTest(name):
                alpr, fake = self.serve(lambda request: ok('{"imageHeight":10,"imageWidth":20,"plates":[],"processingTimeMs":3}'))
                result = alpr.photos.detect({"image": data, "min_ocr_confidence": 1.0})
                headers, sent = parts_of(fake.seen[0])["image"]
                self.assertEqual(sent, data)
                self.assertIn(f'filename="{filename}"', headers["content-disposition"])
                self.assertEqual(headers["content-type"], kind)
                self.assertEqual(parts_of(fake.seen[0])["min_ocr_confidence"][1], b"1")
                self.assertEqual((result.image_width, result.plates), (20, []))

    def test_a_plate_image_is_read_by_ocr(self) -> None:
        alpr, fake = self.serve(lambda request: ok('{"confidence":0.91,"creditsRemaining":40,"detectionId":null,"latencyMs":12,"plate":"ABC1234"}'))
        result = alpr.photos.ocr({"image": PNG})
        self.assertEqual(fake.seen[0].url.path, "/api/v1/ocr")
        self.assertEqual((result.plate, result.detection_id, result.confidence), ("ABC1234", None, 0.91))
        self.assertEqual(set(parts_of(fake.seen[0])), {"image"})

    def test_a_detection_image_is_a_link(self) -> None:
        alpr, fake = self.serve(
            lambda request: ok('{"detectionId":"a/b","expiresIn":300,"imageUrl":"https://alpr.sh/api/v1/detections/a/image/file?s=x"}')
        )
        image = alpr.recognitions.image("a/b")
        self.assertEqual(fake.seen[0].url.path, "/api/v1/detections/a%2Fb/image")
        self.assertEqual((image.expires_in, image.detection_id), (300, "a/b"))
        self.assertTrue(image.image_url.startswith("https://alpr.sh/"))


def reading(identifier: str, camera: str | None = None) -> str:
    return json.dumps({"cameraId": camera, "capturedAt": "2026-10-22T12:00:00-03:00", "conf": 90, "id": identifier, "plate": "BRA2E19", "source": "api"})


class PaginationTest(Case):
    def test_iterating_walks_every_page_by_cursor(self) -> None:
        def answer(request: Seen) -> tuple[int, dict[str, str], bytes]:
            before = request.query.get("before", [""])[0]
            if before == "":
                return ok('{"data":[%s,%s],"next":"c2"}' % (reading("r3"), reading("r2")))
            if before == "c2":
                return ok('{"data":[%s],"next":null}' % reading("r1"))
            return 500, {}, b"{}"

        alpr, fake = self.serve(answer)
        ids = [item.id for item in alpr.recognitions.list_iter(plate="BRA", source="api")]
        self.assertEqual(ids, ["r3", "r2", "r1"])
        self.assertEqual(len(fake.seen), 2)
        self.assertNotIn("before", fake.seen[0].query, "the first request carries no cursor")
        self.assertEqual(fake.seen[1].query["before"], ["c2"])
        for request in fake.seen:
            self.assertEqual((request.query["plate"], request.query["source"]), (["BRA"], ["api"]))
            self.assertNotIn("camera", request.query)
        page = alpr.recognitions.list(before="c2")
        self.assertEqual((len(page.items), page.next, page.items[0].camera_id), (1, None, None))
        self.assertEqual(fake.seen[2].query["before"], ["c2"])

    def test_iterating_can_start_from_a_cursor(self) -> None:
        alpr, fake = self.serve(lambda request: ok('{"data":[%s],"next":null}' % reading("r1", "cam_1")))
        items = list(alpr.recognitions.list_iter(before="start"))
        self.assertEqual((len(items), items[0].camera_id, fake.seen[0].query["before"]), (1, "cam_1", ["start"]))

    def test_a_cursor_that_does_not_move_ends_the_walk(self) -> None:
        alpr, fake = self.serve(lambda request: ok('{"data":[%s],"next":"same"}' % reading("r1", "cam_1")))
        self.assertEqual(len(list(alpr.recognitions.list_iter())), 2)
        self.assertEqual(len(fake.seen), 2)

    def test_the_walk_ends_at_the_first_error(self) -> None:
        calls = []

        def answer(request: Seen) -> tuple[int, dict[str, str], bytes]:
            calls.append(request)
            if len(calls) == 1:
                return ok('{"data":[%s],"next":"c2"}' % reading("r1"))
            return 503, {}, b'{"error":"storage_unavailable","message":"later"}'

        alpr, _ = self.serve(answer)
        walked = []
        with self.assertRaises(AlprError) as raised:
            for item in alpr.recognitions.list_iter():
                walked.append(item.id)
        self.assertEqual((walked, raised.exception.status, raised.exception.code), (["r1"], 503, "storage_unavailable"))


class ErrorTest(Case):
    def test_a_refusal_is_a_typed_error(self) -> None:
        def answer(request: Seen) -> tuple[int, dict[str, str], bytes]:
            if request.url.path == "/api/v1/recognize":
                return 402, {}, b'{"error":"insufficient_credits","message":"This workspace has no credits left."}'
            if request.url.path == "/api/v1/ocr":
                return 502, {}, b"<html>bad gateway</html>"
            return 429, {"Retry-After": "7"}, b'{"error":"rate_limited","message":"Too many requests."}'

        alpr, _ = self.serve(answer)
        with self.assertRaises(AlprError) as raised:
            alpr.photos.recognize({"image": JPEG})
        error = raised.exception
        self.assertEqual((error.status, error.code, error.message, error.fields, error.retry_after), (402, "insufficient_credits", "This workspace has no credits left.", {}, None))
        with self.assertRaises(AlprError) as raised:
            alpr.cameras.list()
        error = raised.exception
        self.assertEqual((error.status, error.code, error.retry_after), (429, "rate_limited", 7))
        with self.assertRaises(AlprError) as raised:
            alpr.photos.ocr({"image": PNG})
        self.assertEqual((raised.exception.status, raised.exception.code, raised.exception.retry_after), (502, "", None))

    def test_a_call_can_use_another_key(self) -> None:
        alpr, fake = self.serve(lambda request: ok('{"data":[]}'))
        self.assertEqual(alpr.cameras.list(api_key="alpr_live_other"), [])
        self.assertEqual(fake.seen[0].headers["Authorization"], "Bearer alpr_live_other")
        alpr.cameras.list()
        self.assertEqual(fake.seen[1].headers["Authorization"], "Bearer " + KEY)

    def test_a_redirect_is_refused_and_the_key_never_follows_it(self) -> None:
        other = Fake(lambda request: ok("{}"))
        self.addCleanup(other.close)
        alpr, _ = self.serve(lambda request: (302, {"Location": other.url + "/steal"}, b""))
        with self.assertRaises(AlprError) as raised:
            alpr.cameras.list()
        self.assertEqual(raised.exception.status, 302)
        self.assertEqual(other.seen, [], "the redirect target was called")

    def test_a_custom_transport_sends_the_request(self) -> None:
        seen: list[tuple[str, str, dict[str, str], bytes | None, float]] = []

        def transport(method: str, url: str, headers: dict[str, str], body: bytes | None, timeout: float) -> tuple[int, dict[str, str], bytes]:
            seen.append((method, url, headers, body, timeout))
            return 200, {}, b'{"data":[]}'

        alpr = Alpr(KEY, transport=transport, timeout=5)
        self.assertEqual(alpr.cameras.list(), [])
        self.assertEqual((seen[0][0], seen[0][1], seen[0][4]), ("GET", "https://alpr.sh/api/v1/cameras", 5))

    def test_a_base_url_must_be_https_unless_it_is_loopback(self) -> None:
        accepted = {
            "https://alpr.sh": True,
            "http://localhost:8080": True,
            "http://LOCALHOST": True,
            "http://127.0.0.1:1": True,
            "http://127.255.0.3": True,
            "http://[::1]:8080": True,
            "http://alpr.sh": False,
            "http://localhost.evil.test": False,
            "http://127.0.0.1.evil.test": False,
            "http://10.0.0.1": False,
            "ftp://localhost": False,
            "alpr.sh": False,
            "": False,
            "http://[::2]": False,
        }
        for base, want in accepted.items():
            try:
                _check_base_url(base)
                got = True
            except ValueError:
                got = False
            self.assertEqual(got, want, base)
        with self.assertRaises(ValueError):
            Alpr(KEY, base_url="http://alpr.test")


# The webhook vectors every SDK checks (generator/testdata/webhook-vectors.json):
# Alpr.sh events signed under two secrets, as while one is rotated.
NEW_SECRET = "whsec_SDK-test-secret-new-0123456789"
OLD_SECRET = "whsec_SDK-test-secret-old-0123456789"
OTHER_SECRET = "whsec_SDK-test-secret-other-012345678"
SIGNED_AT = "1792670400"
NOW = 1792670400 + 120

RECOGNITION_BODY = '{"event":"recognition.created","id":"rec_1","tenant_id":"ws_1","source":"camera","camera_id":"cam_1","plate":"BRA2E19","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}'
RECOGNITION_NEW = "sha256=97deaf1c8a9348f3a7d64ce68943f4e6b4cc44590df4caea4c16d6373fa7d623"
RECOGNITION_OLD = "sha256=12b70f2a8838157260e3b9470befa2627c16c42fe5e4b1d80fb841e206f8c781"
ALERT_BODY = '{"event":"alert.triggered","id":"alt_1","tenant_id":"ws_1","rule_id":"rule_1","rule_name":"Veículo bloqueado","recognition_id":"rec_1","plate":"BRA2E19","camera_id":"cam_1","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}'
ALERT_NEW = "sha256=0b84627fa4564b006237b52feca68ca3c8dfebc54d4e271e881105f75e2a962a"
TEST_BODY = '{"event":"webhook.test","id":"evt_1","tenant_id":"ws_1","sent_at":"2026-10-22T12:00:00Z"}'
TEST_NEW = "sha256=f3064f502ba3ffe3e409d9186c89ce7e425ad1dcad34b73edbeb1ad8e0633245"
UNKNOWN_BODY = '{"event":"payout.sent","id":"po_1","tenant_id":"ws_1"}'
UNKNOWN_NEW = "sha256=cb5b4f83462c974ea9706723b97a28de5d591d2093aa62e8dc8e388997daa0d6"
PLUS_SIGNATURE = "sha256=ceef0f02180106de386c85b403f2b448142e897911c1e6075725b7e8d2912771"


def webhook_headers(delivery_id: str, stamp: str, *signatures: str) -> list[tuple[str, str]]:
    """Header lines, so that a signature may be repeated."""
    return [("x-alprsh-delivery-id", delivery_id), ("X-Alprsh-Timestamp", stamp)] + [("X-Alprsh-Signature", each) for each in signatures]


class WebhookTest(unittest.TestCase):
    def refused(self, secret: str, headers: Any, body: str, now: float = NOW) -> None:
        with self.assertRaises(WebhookVerificationError):
            _verify_webhook_signature_at(secret, headers, body, now)

    def test_the_webhook_vector_verifies(self) -> None:
        headers = webhook_headers("del_0001", SIGNED_AT, RECOGNITION_NEW)
        _verify_webhook_signature_at(NEW_SECRET, headers, RECOGNITION_BODY, NOW)
        _verify_webhook_signature_at(NEW_SECRET, headers, RECOGNITION_BODY.encode(), NOW)
        self.refused(NEW_SECRET, headers, RECOGNITION_BODY + " ")
        self.refused(NEW_SECRET, webhook_headers("del_0009", SIGNED_AT, RECOGNITION_NEW), RECOGNITION_BODY)
        self.refused(NEW_SECRET, headers, RECOGNITION_BODY, 1792670400 + 301)
        self.refused(NEW_SECRET, headers, RECOGNITION_BODY, 1792670400 - 301)
        _verify_webhook_signature_at(NEW_SECRET, headers, RECOGNITION_BODY, 1792670400 + 300)
        self.refused(OTHER_SECRET, headers, RECOGNITION_BODY)
        self.refused(NEW_SECRET, [], RECOGNITION_BODY)
        self.assertEqual(WEBHOOK_TOLERANCE_SECONDS, 300)

    def test_headers_are_found_whatever_their_case_and_container(self) -> None:
        mapping = {
            "X-ALPRSH-DELIVERY-ID": "del_0001",
            "x-alprsh-timestamp": SIGNED_AT,
            "X-Alprsh-Signature": RECOGNITION_NEW,
        }
        _verify_webhook_signature_at(NEW_SECRET, mapping, RECOGNITION_BODY, NOW)

    def test_an_empty_secret_is_a_configuration_error(self) -> None:
        headers = webhook_headers("del_0001", SIGNED_AT, RECOGNITION_NEW)
        with self.assertRaises(ValueError) as raised:
            _verify_webhook_signature_at("", headers, RECOGNITION_BODY, NOW)
        self.assertNotIsInstance(raised.exception, WebhookVerificationError)
        with self.assertRaises(ValueError) as raised:
            verify_webhook("", headers, RECOGNITION_BODY)
        self.assertNotIsInstance(raised.exception, WebhookVerificationError)

    def test_a_timestamp_that_is_not_plain_digits_is_refused(self) -> None:
        for stamp in ["+1792670400", "²", "", "1_7", " 1792670400", "1792670400 ", "١٧٩٢٦٧٠٤٠٠", "1" * 5000]:
            with self.subTest(stamp=stamp):
                self.refused(NEW_SECRET, webhook_headers("del_0001", stamp, PLUS_SIGNATURE), RECOGNITION_BODY)

    def test_more_than_one_signature_verifies_during_a_rotation(self) -> None:
        forms = {
            "one value": webhook_headers("del_0001", SIGNED_AT, RECOGNITION_OLD + "," + RECOGNITION_NEW),
            "two lines": webhook_headers("del_0001", SIGNED_AT, RECOGNITION_OLD, RECOGNITION_NEW),
            "with spaces": webhook_headers("del_0001", SIGNED_AT, RECOGNITION_OLD + ", " + RECOGNITION_NEW),
        }
        for name, headers in forms.items():
            with self.subTest(name):
                for secret in (NEW_SECRET, OLD_SECRET):
                    _verify_webhook_signature_at(secret, headers, RECOGNITION_BODY, NOW)
                self.refused(OTHER_SECRET, headers, RECOGNITION_BODY)
        bad = {
            "a malformed one beside a good one": "sha256=zz," + RECOGNITION_NEW,
            "no prefix": RECOGNITION_NEW.removeprefix("sha256="),
            "a short one": "sha256=97de",
            "too many": (RECOGNITION_OLD + ",") * 6 + RECOGNITION_NEW,
            "empty": "",
        }
        for name, signature in bad.items():
            with self.subTest(name):
                self.refused(NEW_SECRET, webhook_headers("del_0001", SIGNED_AT, signature), RECOGNITION_BODY)
        # Six entries are the most a request may list.
        six = ",".join([RECOGNITION_OLD] * 5 + [RECOGNITION_NEW])
        _verify_webhook_signature_at(NEW_SECRET, webhook_headers("del_0001", SIGNED_AT, six), RECOGNITION_BODY, NOW)

    def test_a_webhook_answers_its_typed_event(self) -> None:
        event = _verify_webhook_at(NEW_SECRET, webhook_headers("del_0001", SIGNED_AT, RECOGNITION_NEW), RECOGNITION_BODY.encode(), NOW)
        assert isinstance(event, RecognitionCreatedWebhookEvent)
        self.assertEqual(
            (event.event, event.id, event.plate, event.confidence, event.camera_id, event.source, event.tenant_id, event.captured_at),
            ("recognition.created", "rec_1", "BRA2E19", 0.97, "cam_1", "camera", "ws_1", "2026-10-22T11:59:58Z"),
        )
        event = _verify_webhook_at(NEW_SECRET, webhook_headers("del_0002", SIGNED_AT, ALERT_NEW), ALERT_BODY.encode(), NOW)
        assert isinstance(event, AlertTriggeredWebhookEvent)
        self.assertEqual((event.rule_name, event.recognition_id, event.rule_id), ("Veículo bloqueado", "rec_1", "rule_1"))
        event = _verify_webhook_at(NEW_SECRET, webhook_headers("del_0003", SIGNED_AT, TEST_NEW), TEST_BODY.encode(), NOW)
        assert isinstance(event, TestWebhookEvent)
        self.assertEqual((event.event, event.sent_at), ("webhook.test", "2026-10-22T12:00:00Z"))
        event = _verify_webhook_at(NEW_SECRET, webhook_headers("del_0004", SIGNED_AT, UNKNOWN_NEW), UNKNOWN_BODY.encode(), NOW)
        assert isinstance(event, UnknownWebhookEvent)
        self.assertEqual((event.event, event.id, event.body), ("payout.sent", "po_1", json.loads(UNKNOWN_BODY)))
        match event:
            case UnknownWebhookEvent(event="payout.sent"):
                pass
            case _:
                self.fail("the match did not reach the unknown event")
        self.refused(NEW_SECRET, webhook_headers("del_0005", SIGNED_AT, "sha256=" + "0" * 64), '{"id":"x"}')

    def test_the_clock_is_read_by_the_public_functions(self) -> None:
        # The vectors are signed for 2026-10-22; today the timestamp is outside the tolerance (or not yet
        # inside it), so the public functions refuse it like the injected clock does.
        import time

        headers = webhook_headers("del_0001", SIGNED_AT, RECOGNITION_NEW)
        if abs(time.time() - int(SIGNED_AT)) > WEBHOOK_TOLERANCE_SECONDS:
            with self.assertRaises(WebhookVerificationError):
                verify_webhook(NEW_SECRET, headers, RECOGNITION_BODY)
            with self.assertRaises(WebhookVerificationError):
                verify_webhook_signature(NEW_SECRET, headers, RECOGNITION_BODY)

    def test_a_verified_body_that_is_not_an_event_is_refused(self) -> None:
        from alpr.webhooks import _event

        for body in [b"[1]", b'{"id":"x"}', b'{"event":3}', b'{"event":""}', b"not json", b"\xff\xfe", b'{"event":"alert.triggered"}']:
            with self.subTest(body=body):
                with self.assertRaises(ValueError) as raised:
                    _event(body)
                self.assertNotIsInstance(raised.exception, WebhookVerificationError)


if __name__ == "__main__":
    unittest.main()
