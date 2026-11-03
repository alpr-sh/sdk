import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

from alpr import (
    IdentifiersWebhookEvent,
    OrderWebhookEvent,
    Alpr,
    AlprError,
    UnknownWebhookEvent,
    WebhookVerificationError,
    verify_webhook,
    verify_webhook_signature,
)

# The webhook vectors every SDK checks: Standard Webhooks' own example, and
# Alpr.sh events signed under two secrets, as while one is rotated.
REFERENCE_SECRET = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
OLD_SECRET = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM="
NEW_SECRET = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM="
ORDER_PAID = b'{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}'
USAGE_RECORDED = b'{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}'
PAYOUT_SENT = b'{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}'
SIGNED_AT = 1792670400


def webhook_headers(webhook_id, at, signature):
    return {"Webhook-Id": webhook_id, "webhook-timestamp": str(at), "webhook-signature": signature}


def product(identifier):
    return {"id": identifier, "name": "Curso", "description": "", "status": "active", "created_at": "2026-10-17T00:00:00Z"}


class Recorder:
    def __init__(self, answer):
        self.answer = answer
        self.seen = []

    def __call__(self, method, url, headers, body, timeout):
        request = {"method": method, "url": urlparse(url), "headers": headers, "body": body}
        self.seen.append(request)
        status, payload, extra = self.answer(request)
        return status, extra, b"" if payload is None else json.dumps(payload).encode()


def client(answer):
    recorder = Recorder(answer)
    return Alpr("prk_test_key", base_url="https://alpr.test/", transport=recorder), recorder


class AlprTest(unittest.TestCase):
    def test_a_call_carries_the_key_and_unwraps_the_data(self):
        alpr, recorder = client(lambda request: (200, {"data": product("prod_1")}, {}))
        got = alpr.products.get("prod_1")
        self.assertEqual(got.id, "prod_1")
        self.assertEqual(got.status, "active")
        seen = recorder.seen[0]
        self.assertEqual(seen["method"], "GET")
        self.assertEqual(seen["url"].path, "/api/v1/products/prod_1")
        self.assertEqual(seen["headers"]["Authorization"], "Bearer prk_test_key")

    def test_a_write_sends_its_body_and_idempotency_key(self):
        alpr, recorder = client(lambda request: (201, {"data": product("prod_1")}, {}))
        alpr.products.create({"name": "Curso"}, idempotency_key="create-1")
        seen = recorder.seen[0]
        self.assertEqual(seen["method"], "POST")
        self.assertEqual(seen["headers"]["Idempotency-Key"], "create-1")
        self.assertEqual(json.loads(seen["body"]), {"name": "Curso"})

    def test_a_base_url_must_be_https_unless_it_is_loopback(self):
        for base_url in ["https://alpr.sh", "http://localhost:8080", "http://LOCALHOST", "http://127.0.0.1:1", "http://127.255.0.3", "http://[::1]:8080"]:
            Alpr("k", base_url=base_url)
        for base_url in ["http://alpr.sh", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "http://10.0.0.1", "ftp://localhost", "alpr.sh", "", "http://[::2]"]:
            with self.assertRaisesRegex(ValueError, "must be https", msg=base_url):
                Alpr("k", base_url=base_url)

    def test_a_discount_goes_through_create_get_list_and_delete(self):
        def discount(identifier):
            return json.loads("{\"id\":\"__ID__\",\"name\":\"Black\",\"code\":null,\"type\":\"percentage\",\"basis_points\":1000,\"amount_cents\":0,\"currency\":\"BRL\",\"duration\":\"once\",\"duration_in_months\":0,\"max_redemptions\":null,\"max_redemptions_per_customer\":null,\"redemptions_count\":0,\"starts_at\":\"2026-10-17T00:00:00Z\",\"ends_at\":null,\"status\":\"active\",\"product_ids\":[\"prod_1\"],\"created_at\":\"2026-10-17T00:00:00Z\",\"modified_at\":\"2026-10-17T00:00:00Z\"}".replace("__ID__", identifier))

        def answer(request):
            if request["method"] == "POST":
                return 201, {"data": discount("disc_1")}, {}
            if request["method"] == "DELETE":
                return 204, None, {}
            if request["url"].path == "/api/v1/discounts":
                page = parse_qs(request["url"].query)["page"][0]
                return 200, {"data": {"items": [discount(f"disc_{page}")], "pagination": {"total_count": 2, "max_page": 2}}}, {}
            return 200, {"data": discount("disc_1")}, {}

        alpr, recorder = client(answer)
        created = alpr.discounts.create({"name": "Black", "type": "percentage", "duration": "once", "basis_points": 1000})
        self.assertEqual((created.id, created.code, created.product_ids), ("disc_1", None, ["prod_1"]))
        self.assertEqual(alpr.discounts.get("disc_1").name, "Black")
        self.assertEqual([each.id for each in alpr.discounts.list_iter(limit=1)], ["disc_1", "disc_2"])
        self.assertIsNone(alpr.discounts.delete("disc_1"))
        self.assertEqual(
            [(seen["method"], seen["url"].path) for seen in recorder.seen],
            [("POST", "/api/v1/discounts"), ("GET", "/api/v1/discounts/disc_1"), ("GET", "/api/v1/discounts"), ("GET", "/api/v1/discounts"), ("DELETE", "/api/v1/discounts/disc_1")],
        )
        self.assertEqual(json.loads(recorder.seen[0]["body"]), {"name": "Black", "type": "percentage", "duration": "once", "basis_points": 1000})

    def test_a_free_form_value_decodes_nested(self):
        state = {"id": "cus_1", "name": "Ana", "email": "ana@example.com", "external_id": "", "status": "active", "created_at": "2026-10-17T00:00:00Z", "active_subscriptions": [], "granted_benefits": [{"id": "gr_1", "granted_at": "2026-10-17T00:00:00Z", "benefit_id": "ben_1", "benefit_type": "feature_flag", "benefit_metadata": {"flags": {"beta": True, "limits": {"seats": 5, "tiers": ["a", 2, None, 1.5]}}}, "properties": {"links": [{"url": "https://example.com", "expires": None}]}}]}
        alpr, _ = client(lambda request: (200, {"data": state}, {}))
        grant = alpr.customers.get_state("cus_1").granted_benefits[0]
        self.assertEqual(grant.benefit_metadata, {"flags": {"beta": True, "limits": {"seats": 5, "tiers": ["a", 2, None, 1.5]}}})
        self.assertEqual(grant.properties, {"links": [{"url": "https://example.com", "expires": None}]})

    def test_a_post_without_a_key_is_sent_with_its_own_a_get_with_none(self):
        alpr, recorder = client(lambda request: (201, {"data": product("prod_1")}, {}))
        alpr.products.create({"name": "Curso"})
        alpr.products.create({"name": "Curso"})
        alpr.products.create({"name": "Curso"}, idempotency_key="mine")
        alpr.products.get("prod_1")
        keys = [seen["headers"].get("Idempotency-Key") for seen in recorder.seen]
        uuid = r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        self.assertRegex(keys[0], uuid)
        self.assertRegex(keys[1], uuid)
        self.assertNotEqual(keys[0], keys[1])
        self.assertEqual(keys[2:], ["mine", None])

    def test_iterating_walks_every_page(self):
        def answer(request):
            page = parse_qs(request["url"].query)["page"][0]
            return 200, {"data": {"items": [product(f"prod_{page}")], "pagination": {"total_count": 3, "max_page": 3}}}, {}

        alpr, recorder = client(answer)
        self.assertEqual([item.id for item in alpr.products.list_iter(limit=1)], ["prod_1", "prod_2", "prod_3"])
        self.assertEqual(parse_qs(recorder.seen[0]["url"].query)["limit"], ["1"])

    def test_a_refusal_is_a_typed_error(self):
        def answer(request):
            if request["url"].path == "/api/v1/customers":
                return 422, {"error": "invalid_request", "fields": {"email": ["send an e-mail"]}}, {}
            return 429, None, {"retry-after": "7"}

        alpr, _ = client(answer)
        with self.assertRaises(AlprError) as refused:
            alpr.customers.create({"name": "x", "email": "x"})
        self.assertEqual((refused.exception.status, refused.exception.code), (422, "invalid_request"))
        self.assertEqual(refused.exception.fields["email"], ["send an e-mail"])
        with self.assertRaises(AlprError) as limited:
            alpr.products.list()
        self.assertEqual((limited.exception.status, limited.exception.retry_after), (429, 7))

    def test_a_redirect_is_refused_and_the_key_never_follows_it(self):
        elsewhere = []

        class Other(BaseHTTPRequestHandler):
            def do_GET(self):
                elsewhere.append(self.headers.get("Authorization"))
                self.send_response(200)
                self.end_headers()

            def log_message(self, *args):
                pass

        other = HTTPServer(("127.0.0.1", 0), Other)

        class First(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{other.server_port}/steal")
                self.end_headers()

            def log_message(self, *args):
                pass

        first = HTTPServer(("127.0.0.1", 0), First)
        for server in (first, other):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            alpr = Alpr("prk_test_key", base_url=f"http://127.0.0.1:{first.server_port}")
            with self.assertRaises(AlprError) as refused:
                alpr.products.get("prod_1")
            self.assertEqual((refused.exception.status, refused.exception.code), (302, "redirect_refused"))
            self.assertEqual(elsewhere, [])
        finally:
            for server in (first, other):
                server.shutdown()
                server.server_close()

    def test_the_standard_webhooks_vector_verifies(self):
        body = b'{"test": 2432232314}'
        headers = webhook_headers("msg_p5jXN8AQM9LWM0D4loKWxJek", 1614265330, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
        verify_webhook_signature(REFERENCE_SECRET, headers, body, now=1614265330)
        for secret, payload, now in [
            (REFERENCE_SECRET, body + b" ", 1614265330),
            (REFERENCE_SECRET, body, 1614265330 + 301),
            (NEW_SECRET, body, 1614265330),
        ]:
            with self.assertRaises(WebhookVerificationError):
                verify_webhook_signature(secret, headers, payload, now=now)

    def test_a_timestamp_that_is_not_plain_digits_is_refused(self):
        body = b'{"test": 2432232314}'
        for stamp, signature in [("+1614265330", "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8="), ("²", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY="), ("", "x"), ("1_6", "x")]:
            headers = {"Webhook-Id": "msg_p5jXN8AQM9LWM0D4loKWxJek", "webhook-timestamp": stamp, "webhook-signature": "v1," + signature}
            with self.assertRaises(WebhookVerificationError, msg=stamp):
                verify_webhook_signature(REFERENCE_SECRET, headers, body, now=1614265330)

    def test_a_webhook_answers_its_typed_event(self):
        now = SIGNED_AT + 120
        headers = webhook_headers("msg_2", SIGNED_AT, "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=")
        for secret in (NEW_SECRET, OLD_SECRET):
            event = verify_webhook(secret, headers, ORDER_PAID, now=now)
            self.assertIsInstance(event, OrderWebhookEvent)
            assert isinstance(event, OrderWebhookEvent)
            self.assertEqual((event.type, event.data.id, event.data.installments, event.data.installment_interest_cents), ("order.paid", "ord_1", 3, 360))
        with self.assertRaises(WebhookVerificationError):
            verify_webhook(REFERENCE_SECRET, headers, ORDER_PAID, now=now)
        usage = verify_webhook(NEW_SECRET, webhook_headers("msg_3", SIGNED_AT, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="), USAGE_RECORDED, now=now)
        self.assertIsInstance(usage, IdentifiersWebhookEvent)
        self.assertEqual((usage.id, usage.data["merchant_id"]), ("msg_3", "mer_1"))
        unknown = verify_webhook(NEW_SECRET, webhook_headers("msg_4", SIGNED_AT, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="), PAYOUT_SENT.decode(), now=now)
        self.assertIsInstance(unknown, UnknownWebhookEvent)
        self.assertEqual((unknown.type, unknown.data), ("payout.sent", {"payout_id": "po_1", "amount_cents": 5000}))


if __name__ == "__main__":
    unittest.main()
