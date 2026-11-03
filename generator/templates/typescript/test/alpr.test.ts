import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { test } from "node:test";

import { Alpr, AlprError, verifyWebhook, verifyWebhookSignature, WebhookVerificationError } from "../src/index.ts";

interface Seen {
  method: string;
  url: URL;
  headers: Headers;
  body: string | undefined;
}

function client(answer: (seen: Seen) => Response): { alpr: Alpr; seen: Seen[] } {
  const seen: Seen[] = [];
  const fake: typeof fetch = async (input, init) => {
    const request = { method: init?.method ?? "GET", url: new URL(String(input)), headers: new Headers(init?.headers), body: init?.body as string | undefined };
    seen.push(request);
    return answer(request);
  };
  return { alpr: new Alpr({ apiKey: "prk_test_key", baseUrl: "https://alpr.test/", fetch: fake }), seen };
}

const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

const product = (id: string) => ({ id, name: "Curso", description: "", status: "active", created_at: "2026-10-17T00:00:00Z" });

test("a call carries the key and unwraps the data", async () => {
  const { alpr, seen } = client(() => json(200, { data: product("prod_1") }));
  const got = await alpr.products.get("prod_1");
  assert.equal(got.id, "prod_1");
  assert.equal(got.status, "active");
  assert.equal(seen[0]?.method, "GET");
  assert.equal(seen[0]?.url.pathname, "/api/v1/products/prod_1");
  assert.equal(seen[0]?.headers.get("authorization"), "Bearer prk_test_key");
});

test("a write sends its body and idempotency key", async () => {
  const { alpr, seen } = client(() => json(201, { data: product("prod_1") }));
  await alpr.products.create({ name: "Curso" }, { idempotencyKey: "create-1" });
  assert.equal(seen[0]?.method, "POST");
  assert.equal(seen[0]?.headers.get("idempotency-key"), "create-1");
  assert.deepEqual(JSON.parse(seen[0]?.body ?? ""), { name: "Curso" });
});

test("a base URL must be https unless it is loopback", () => {
  for (const baseUrl of ["https://alpr.sh", "http://localhost:8080", "http://LOCALHOST", "http://127.0.0.1:1", "http://127.255.0.3", "http://[::1]:8080"]) {
    assert.doesNotThrow(() => new Alpr({ apiKey: "k", baseUrl }), baseUrl);
  }
  for (const baseUrl of ["http://alpr.sh", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "http://10.0.0.1", "ftp://localhost", "alpr.sh", "", "http://[::2]"]) {
    assert.throws(() => new Alpr({ apiKey: "k", baseUrl }), /must be https/, baseUrl);
  }
});

const discount = (id: string) => JSON.parse("{\"id\":\"__ID__\",\"name\":\"Black\",\"code\":null,\"type\":\"percentage\",\"basis_points\":1000,\"amount_cents\":0,\"currency\":\"BRL\",\"duration\":\"once\",\"duration_in_months\":0,\"max_redemptions\":null,\"max_redemptions_per_customer\":null,\"redemptions_count\":0,\"starts_at\":\"2026-10-17T00:00:00Z\",\"ends_at\":null,\"status\":\"active\",\"product_ids\":[\"prod_1\"],\"created_at\":\"2026-10-17T00:00:00Z\",\"modified_at\":\"2026-10-17T00:00:00Z\"}".replace("__ID__", id));

test("a discount goes through create, get, list and delete", async () => {
  const { alpr, seen } = client(({ method, url }) => {
    if (method === "POST") {
      return json(201, { data: discount("disc_1") });
    }
    if (method === "DELETE") {
      return new Response(null, { status: 204 });
    }
    if (url.pathname === "/api/v1/discounts") {
      const page = url.searchParams.get("page");
      return json(200, { data: { items: [discount(`disc_${page}`)], pagination: { total_count: 2, max_page: 2 } } });
    }
    return json(200, { data: discount("disc_1") });
  });
  const created = await alpr.discounts.create({ name: "Black", type: "percentage", duration: "once", basis_points: 1000 });
  assert.equal(created.id, "disc_1");
  assert.equal(created.code, null);
  assert.deepEqual(created.product_ids, ["prod_1"]);
  assert.equal((await alpr.discounts.get("disc_1")).name, "Black");
  const ids: string[] = [];
  for await (const each of alpr.discounts.listIter({ limit: 1 })) {
    ids.push(each.id);
  }
  assert.deepEqual(ids, ["disc_1", "disc_2"]);
  assert.equal(await alpr.discounts.delete("disc_1"), undefined);
  assert.deepEqual(
    seen.map((each) => `${each.method} ${each.url.pathname}`),
    ["POST /api/v1/discounts", "GET /api/v1/discounts/disc_1", "GET /api/v1/discounts", "GET /api/v1/discounts", "DELETE /api/v1/discounts/disc_1"],
  );
  assert.deepEqual(JSON.parse(seen[0]?.body ?? ""), { name: "Black", type: "percentage", duration: "once", basis_points: 1000 });
});

test("a free-form value decodes nested", async () => {
  const state = {"id": "cus_1", "name": "Ana", "email": "ana@example.com", "external_id": "", "status": "active", "created_at": "2026-10-17T00:00:00Z", "active_subscriptions": [], "granted_benefits": [{"id": "gr_1", "granted_at": "2026-10-17T00:00:00Z", "benefit_id": "ben_1", "benefit_type": "feature_flag", "benefit_metadata": {"flags": {"beta": true, "limits": {"seats": 5, "tiers": ["a", 2, null, 1.5]}}}, "properties": {"links": [{"url": "https://example.com", "expires": null}]}}]};
  const { alpr } = client(() => json(200, { data: state }));
  const got = await alpr.customers.getState("cus_1");
  const grant = got.granted_benefits[0];
  assert.deepEqual(grant?.benefit_metadata, { flags: { beta: true, limits: { seats: 5, tiers: ["a", 2, null, 1.5] } } });
  assert.deepEqual(grant?.properties, { links: [{ url: "https://example.com", expires: null }] });
});

test("a POST without a key is sent with its own, a GET with none", async () => {
  const { alpr, seen } = client(() => json(201, { data: product("prod_1") }));
  await alpr.products.create({ name: "Curso" });
  await alpr.products.create({ name: "Curso" });
  await alpr.products.create({ name: "Curso" }, { idempotencyKey: "mine" });
  await alpr.products.get("prod_1");
  const keys = seen.map((each) => each.headers.get("idempotency-key"));
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
  assert.match(keys[0] ?? "", uuid);
  assert.match(keys[1] ?? "", uuid);
  assert.notEqual(keys[0], keys[1]);
  assert.equal(keys[2], "mine");
  assert.equal(keys[3], null);
});

test("iterating walks every page", async () => {
  const { alpr, seen } = client(({ url }) =>
    json(200, { data: { items: [product(`prod_${url.searchParams.get("page")}`)], pagination: { total_count: 3, max_page: 3 } } }),
  );
  const ids: string[] = [];
  for await (const item of alpr.products.listIter({ limit: 1 })) {
    ids.push(item.id);
  }
  assert.deepEqual(ids, ["prod_1", "prod_2", "prod_3"]);
  assert.equal(seen[0]?.url.searchParams.get("limit"), "1");
});

test("a redirect is refused and the key never follows it", async () => {
  const elsewhere: Array<string | undefined> = [];
  const other = createServer((request, response) => {
    elsewhere.push(request.headers.authorization);
    response.end("{}");
  });
  await new Promise<void>((resolve) => other.listen(0, "127.0.0.1", resolve));
  const first = createServer((_request, response) => {
    response.writeHead(302, { Location: `http://127.0.0.1:${(other.address() as AddressInfo).port}/steal` });
    response.end();
  });
  await new Promise<void>((resolve) => first.listen(0, "127.0.0.1", resolve));
  try {
    const alpr = new Alpr({ apiKey: "prk_test_key", baseUrl: `http://127.0.0.1:${(first.address() as AddressInfo).port}` });
    await assert.rejects(alpr.products.get("prod_1"), (error) => error instanceof AlprError && error.status === 302);
    assert.deepEqual(elsewhere, []);
  } finally {
    first.close();
    other.close();
  }
});

test("a refusal is a typed error", async () => {
  const { alpr } = client(({ url }) =>
    url.pathname === "/api/v1/customers"
      ? json(422, { error: "invalid_request", fields: { email: ["send an e-mail"] } })
      : new Response(null, { status: 429, headers: { "Retry-After": "7" } }),
  );
  await assert.rejects(alpr.customers.create({ name: "x", email: "x" }), (error: unknown) => {
    assert.ok(error instanceof AlprError);
    assert.equal(error.status, 422);
    assert.equal(error.code, "invalid_request");
    assert.deepEqual(error.fields["email"], ["send an e-mail"]);
    return true;
  });
  await assert.rejects(alpr.products.list(), (error: unknown) => {
    assert.ok(error instanceof AlprError);
    assert.equal(error.status, 429);
    assert.equal(error.retryAfter, 7);
    return true;
  });
});

// The webhook vectors every SDK checks: Standard Webhooks' own example, and
// Alpr.sh events signed under two secrets, as while one is rotated.
const referenceSecret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
const oldSecret = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=";
const newSecret = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=";
const orderPaid =
  '{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}';
const usageRecorded =
  '{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}';
const payoutSent = '{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}';
const signedAt = 1792670400;
const webhookHeaders = (id: string, at: number, signature: string) => ({ "Webhook-Id": id, "webhook-timestamp": String(at), "webhook-signature": signature });

test("the Standard Webhooks vector verifies", async () => {
  const body = '{"test": 2432232314}';
  const headers = webhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 1614265330, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=");
  await verifyWebhookSignature(referenceSecret, headers, body, 1614265330_000);
  await assert.rejects(verifyWebhookSignature(referenceSecret, headers, `${body} `, 1614265330_000), WebhookVerificationError);
  await assert.rejects(verifyWebhookSignature(referenceSecret, headers, body, (1614265330 + 301) * 1000), WebhookVerificationError);
  await assert.rejects(verifyWebhookSignature(newSecret, headers, body, 1614265330_000), WebhookVerificationError);
});

test("a timestamp that is not plain digits is refused", async () => {
  const body = '{"test": 2432232314}';
  for (const [stamp, signature] of [["+1614265330", "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8="], ["²", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY="], ["", "x"], ["1_6", "x"]] as const) {
    const headers = { "Webhook-Id": "msg_p5jXN8AQM9LWM0D4loKWxJek", "webhook-timestamp": stamp, "webhook-signature": `v1,${signature}` };
    await assert.rejects(verifyWebhookSignature(referenceSecret, headers, body, 1614265330_000), WebhookVerificationError, stamp);
  }
});

test("a webhook answers its typed event", async () => {
  const now = (signedAt + 120) * 1000;
  const headers = webhookHeaders("msg_2", signedAt, "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=");
  for (const secret of [newSecret, oldSecret]) {
    const event = await verifyWebhook(secret, headers, orderPaid, now);
    assert.equal(event.type, "order.paid");
    if (event.type !== "order.paid") {
      return;
    }
    assert.deepEqual([event.data.id, event.data.installments, event.data.installment_interest_cents], ["ord_1", 3, 360]);
  }
  await assert.rejects(verifyWebhook(referenceSecret, headers, orderPaid, now), WebhookVerificationError);
  const usage = await verifyWebhook(newSecret, webhookHeaders("msg_3", signedAt, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="), usageRecorded, now);
  assert.equal(usage.type === "usage_event.recorded" && usage.data["merchant_id"], "mer_1");
  const unknown = await verifyWebhook(newSecret, webhookHeaders("msg_4", signedAt, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="), new TextEncoder().encode(payoutSent), now);
  assert.equal(unknown.type as string, "payout.sent");
  assert.deepEqual(unknown.data, { payout_id: "po_1", amount_cents: 5000 });
});
