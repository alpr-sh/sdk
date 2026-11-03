import assert from "node:assert/strict";
import { test } from "node:test";

import { Alpr, AlprError, isKnownWebhookEvent, verifyWebhook, verifyWebhookSignature, WebhookVerificationError } from "../src/index.ts";

interface Seen {
  method: string;
  url: URL;
  headers: Headers;
  body: FormData | undefined;
}

const KEY = "alpr_live_" + "0123456789abcdef".repeat(4);

function client(answer: (seen: Seen) => Response): { alpr: Alpr; seen: Seen[] } {
  const seen: Seen[] = [];
  const fake: typeof fetch = async (input, init) => {
    const request = { method: init?.method ?? "GET", url: new URL(String(input)), headers: new Headers(init?.headers), body: init?.body as FormData | undefined };
    seen.push(request);
    return answer(request);
  };
  return { alpr: new Alpr({ apiKey: KEY, baseUrl: "https://alpr.test/", fetch: fake }), seen };
}

const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01]);
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52]);

const recognized = {
  creditsRemaining: 41,
  imageHeight: 720,
  imageWidth: 1280,
  plates: [{ charConfs: "0.99;0.98", conf: 97.3, coordinateBottom: 361, coordinateLeft: 120, coordinateRight: 300, coordinateTop: 301, createdAt: "2026-10-22T12:00:00-03:00", plate: "BRA2E19", plateType: "car", time: "2026-10-22T12:00:00-03:00" }],
  processingTimeMs: 84,
};

test("a call carries the key, the user agent and no idempotency key, and a list unwraps data", async () => {
  const { alpr, seen } = client(() =>
    json(200, { data: [
      { createdAt: "2026-10-01T09:00:00-03:00", enabled: true, id: "cam_1", location: "Portaria", name: "Portão", protocol: "rtsp", readingArea: null },
      { createdAt: "2026-10-01T09:00:00-03:00", enabled: false, id: "cam_2", location: "", name: "Garagem", protocol: "rtsp", readingArea: { box: { height: 0.5, width: 0.5, x: 0.1, y: 0.2 }, points: [[0.1, 0.2], [0.6, 0.2], [0.6, 0.7]] } },
    ] }),
  );
  const cameras = await alpr.cameras.list();
  assert.equal(cameras.length, 2);
  assert.equal(cameras[0]?.readingArea, null);
  assert.equal(cameras[1]?.readingArea?.box.x, 0.1);
  assert.deepEqual(cameras[1]?.readingArea?.points[1], [0.6, 0.2]);
  assert.equal(seen[0]?.method, "GET");
  assert.equal(seen[0]?.url.pathname, "/api/v1/cameras");
  assert.equal(seen[0]?.headers.get("authorization"), `Bearer ${KEY}`);
  assert.match(seen[0]?.headers.get("user-agent") ?? "", /^alpr-typescript\//);
  assert.equal(seen[0]?.headers.get("accept"), "application/json");
  assert.equal(seen[0]?.headers.get("idempotency-key"), null);
});

test("a photo goes as multipart, named and typed by its bytes", async () => {
  const { alpr, seen } = client(() => json(200, recognized));
  const result = await alpr.photos.recognize({ image: JPEG, lpr_confidence: 0.5 });
  assert.equal(result.creditsRemaining, 41);
  assert.equal(result.plates[0]?.plate, "BRA2E19");
  assert.equal(result.plates[0]?.conf, 97.3);
  assert.equal(seen[0]?.method, "POST");
  assert.equal(seen[0]?.url.pathname, "/api/v1/recognize");
  const form = seen[0]?.body;
  assert.ok(form instanceof FormData);
  const file = form.get("image") as File;
  assert.equal(file.name, "photo.jpg");
  assert.equal(file.type, "image/jpeg");
  assert.deepEqual(new Uint8Array(await file.arrayBuffer()), JPEG);
  assert.equal(form.get("lpr_confidence"), "0.5");
  assert.equal(form.has("min_ocr_confidence"), false);
  // No Content-Type of its own: fetch writes the boundary.
  assert.equal(seen[0]?.headers.get("content-type"), null);
  const sent = await new Response(form).arrayBuffer();
  assert.ok(sent.byteLength > JPEG.length);
});

test("a photo is named by its bytes, whether bytes, a buffer or a Blob", async () => {
  const cases: [Uint8Array | ArrayBuffer | Blob, string, string][] = [
    [JPEG, "photo.jpg", "image/jpeg"],
    [PNG, "photo.png", "image/png"],
    [new TextEncoder().encode("not an image"), "photo", "application/octet-stream"],
    [PNG.buffer.slice(0) as ArrayBuffer, "photo.png", "image/png"],
    [new Blob([JPEG]), "photo.jpg", "image/jpeg"],
  ];
  for (const [image, name, type] of cases) {
    const { alpr, seen } = client(() => json(200, { imageHeight: 10, imageWidth: 20, plates: [], processingTimeMs: 3 }));
    const result = await alpr.photos.detect({ image });
    assert.equal(result.imageWidth, 20);
    const file = seen[0]?.body?.get("image") as File;
    assert.equal(file.name, name);
    assert.equal(file.type, type);
  }
});

test("a plate image is read by OCR", async () => {
  const { alpr, seen } = client(() => json(200, { confidence: 0.91, creditsRemaining: 40, detectionId: null, latencyMs: 12, plate: "ABC1234" }));
  const result = await alpr.photos.ocr({ image: PNG });
  assert.equal(result.plate, "ABC1234");
  assert.equal(result.detectionId, null);
  assert.equal(seen[0]?.url.pathname, "/api/v1/ocr");
});

test("a detection image is a link, and the id is escaped in the path", async () => {
  const { alpr, seen } = client(() => json(200, { detectionId: "a/b", expiresIn: 300, imageUrl: "https://alpr.sh/api/v1/detections/a/image/file?s=x" }));
  const link = await alpr.recognitions.image("a/b");
  assert.equal(link.expiresIn, 300);
  assert.equal(link.detectionId, "a/b");
  assert.equal(seen[0]?.url.pathname, "/api/v1/detections/a%2Fb/image");
});

const reading = (id: string) => ({ cameraId: null, capturedAt: "2026-10-22T12:00:00-03:00", conf: 90, id, plate: "BRA2E19", source: "api" });

test("iterating walks every page by cursor, carrying the filters", async () => {
  const { alpr, seen } = client(({ url }) => {
    if (url.searchParams.get("before") === null) {
      return json(200, { data: [reading("r3"), reading("r2")], next: "c2" });
    }
    return json(200, { data: [reading("r1")], next: null });
  });
  const ids: string[] = [];
  for await (const each of alpr.recognitions.listIter({ plate: "BRA", source: "api" })) {
    ids.push(each.id);
  }
  assert.deepEqual(ids, ["r3", "r2", "r1"]);
  assert.equal(seen.length, 2);
  assert.equal(seen[0]?.url.searchParams.has("before"), false);
  assert.equal(seen[1]?.url.searchParams.get("before"), "c2");
  for (const each of seen) {
    assert.equal(each.url.searchParams.get("plate"), "BRA");
    assert.equal(each.url.searchParams.get("source"), "api");
  }
  const page = await alpr.recognitions.list({ before: "c2" });
  assert.equal(page.items.length, 1);
  assert.equal(page.next, null);
  assert.equal(page.items[0]?.cameraId, null);
});

test("a cursor that does not move ends the walk", async () => {
  const { alpr, seen } = client(() => json(200, { data: [reading("r1")], next: "same" }));
  let count = 0;
  for await (const _ of alpr.recognitions.listIter()) {
    count++;
  }
  assert.equal(count, 2);
  assert.equal(seen.length, 2);
});

test("a refusal is a typed error", async () => {
  const { alpr } = client(({ url }) =>
    url.pathname === "/api/v1/recognize"
      ? json(402, { error: "insufficient_credits", message: "This workspace has no credits left." })
      : json(429, { error: "rate_limited", message: "Too many requests." }, { "Retry-After": "7" }),
  );
  await assert.rejects(alpr.photos.recognize({ image: JPEG }), (error: unknown) => {
    assert.ok(error instanceof AlprError);
    assert.equal(error.status, 402);
    assert.equal(error.code, "insufficient_credits");
    assert.equal(error.message, "alpr: 402 insufficient_credits: This workspace has no credits left.");
    assert.equal(error.retryAfter, undefined);
    return true;
  });
  await assert.rejects(alpr.cameras.list(), (error: unknown) => {
    assert.ok(error instanceof AlprError);
    assert.equal(error.status, 429);
    assert.equal(error.code, "rate_limited");
    assert.equal(error.retryAfter, 7);
    return true;
  });
});

test("a call can use another key", async () => {
  const { alpr, seen } = client(() => json(200, { data: [] }));
  await alpr.cameras.list({ apiKey: "alpr_live_other" });
  assert.equal(seen[0]?.headers.get("authorization"), "Bearer alpr_live_other");
});

test("a redirect is never followed", async () => {
  let init: RequestInit | undefined;
  const fake: typeof fetch = async (_input, options) => {
    init = options;
    return new Response(null, { status: 302, headers: { Location: "https://evil.test/steal" } });
  };
  const alpr = new Alpr({ apiKey: KEY, baseUrl: "https://alpr.test", fetch: fake });
  await assert.rejects(alpr.cameras.list(), (error: unknown) => error instanceof AlprError && error.status === 302);
  assert.equal(init?.redirect, "manual");
});

test("a base URL must be https unless it is loopback", () => {
  for (const baseUrl of ["https://alpr.sh", "http://localhost:8080", "http://LOCALHOST", "http://127.0.0.1:1", "http://127.255.0.3", "http://[::1]:8080"]) {
    assert.doesNotThrow(() => new Alpr({ apiKey: "k", baseUrl }), baseUrl);
  }
  for (const baseUrl of ["http://alpr.sh", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "http://10.0.0.1", "ftp://localhost", "alpr.sh", "", "http://[::2]"]) {
    assert.throws(() => new Alpr({ apiKey: "k", baseUrl }), /must be https/, baseUrl);
  }
});

// The webhook vectors every SDK checks (generator/testdata/webhook-vectors.json).
const NEW = "whsec_SDK-test-secret-new-0123456789";
const OLD = "whsec_SDK-test-secret-old-0123456789";
const OTHER = "whsec_SDK-test-secret-other-012345678";
const SIGNED_AT = 1792670400;
const NOW = (SIGNED_AT + 120) * 1000;
const RECOGNITION = "{\"event\":\"recognition.created\",\"id\":\"rec_1\",\"tenant_id\":\"ws_1\",\"source\":\"camera\",\"camera_id\":\"cam_1\",\"plate\":\"BRA2E19\",\"confidence\":0.97,\"captured_at\":\"2026-10-22T11:59:58Z\"}";
const ALERT = "{\"event\":\"alert.triggered\",\"id\":\"alt_1\",\"tenant_id\":\"ws_1\",\"rule_id\":\"rule_1\",\"rule_name\":\"Veículo bloqueado\",\"recognition_id\":\"rec_1\",\"plate\":\"BRA2E19\",\"camera_id\":\"cam_1\",\"confidence\":0.97,\"captured_at\":\"2026-10-22T11:59:58Z\"}";
const TEST = "{\"event\":\"webhook.test\",\"id\":\"evt_1\",\"tenant_id\":\"ws_1\",\"sent_at\":\"2026-10-22T12:00:00Z\"}";
const UNKNOWN = "{\"event\":\"payout.sent\",\"id\":\"po_1\",\"tenant_id\":\"ws_1\"}";
const RECOGNITION_NEW = "sha256=97deaf1c8a9348f3a7d64ce68943f4e6b4cc44590df4caea4c16d6373fa7d623";
const RECOGNITION_OLD = "sha256=12b70f2a8838157260e3b9470befa2627c16c42fe5e4b1d80fb841e206f8c781";
const ALERT_NEW = "sha256=0b84627fa4564b006237b52feca68ca3c8dfebc54d4e271e881105f75e2a962a";
const TEST_NEW = "sha256=f3064f502ba3ffe3e409d9186c89ce7e425ad1dcad34b73edbeb1ad8e0633245";
const UNKNOWN_NEW = "sha256=cb5b4f83462c974ea9706723b97a28de5d591d2093aa62e8dc8e388997daa0d6";
const PLUS_SIGN = "sha256=ceef0f02180106de386c85b403f2b448142e897911c1e6075725b7e8d2912771";

const signed = (id: string, stamp: string | number, ...signatures: string[]) =>
  new Headers([["X-Alprsh-Delivery-Id", id], ["X-Alprsh-Timestamp", String(stamp)], ...signatures.map((each): [string, string] => ["X-Alprsh-Signature", each])]);

test("a webhook vector verifies, and what changed does not", async () => {
  const headers = signed("del_0001", SIGNED_AT, RECOGNITION_NEW);
  await verifyWebhookSignature(NEW, headers, RECOGNITION, NOW);
  await verifyWebhookSignature(NEW, headers, new TextEncoder().encode(RECOGNITION), NOW);
  await assert.rejects(verifyWebhookSignature(NEW, headers, RECOGNITION + " ", NOW), WebhookVerificationError);
  await assert.rejects(verifyWebhookSignature(NEW, signed("del_0009", SIGNED_AT, RECOGNITION_NEW), RECOGNITION, NOW), WebhookVerificationError);
  await assert.rejects(verifyWebhookSignature(NEW, headers, RECOGNITION, (SIGNED_AT + 301) * 1000), WebhookVerificationError);
  await assert.rejects(verifyWebhookSignature(NEW, headers, RECOGNITION, (SIGNED_AT - 301) * 1000), WebhookVerificationError);
  await verifyWebhookSignature(NEW, headers, RECOGNITION, (SIGNED_AT + 300) * 1000);
  await assert.rejects(verifyWebhookSignature(OTHER, headers, RECOGNITION, NOW), WebhookVerificationError);
  await assert.rejects(verifyWebhookSignature("", headers, RECOGNITION, NOW), (error: unknown) => error instanceof Error && !(error instanceof WebhookVerificationError));
  await assert.rejects(verifyWebhookSignature(NEW, new Headers(), RECOGNITION, NOW), WebhookVerificationError);
  // Node's http hands headers over as an object, lower-cased.
  await verifyWebhookSignature(NEW, { "x-alprsh-delivery-id": "del_0001", "x-alprsh-timestamp": String(SIGNED_AT), "x-alprsh-signature": [RECOGNITION_NEW] }, RECOGNITION, NOW);
});

test("a timestamp that is not plain digits is refused", async () => {
  for (const stamp of ["+1792670400", "²", "", "1_7", " 1792670400", "1792670400 "]) {
    await assert.rejects(verifyWebhookSignature(NEW, signed("del_0001", stamp, PLUS_SIGN), RECOGNITION, NOW), WebhookVerificationError, JSON.stringify(stamp));
  }
});

test("more than one signature verifies during a rotation", async () => {
  const headers = [
    signed("del_0001", SIGNED_AT, `${RECOGNITION_OLD},${RECOGNITION_NEW}`),
    signed("del_0001", SIGNED_AT, RECOGNITION_OLD, RECOGNITION_NEW),
    signed("del_0001", SIGNED_AT, `${RECOGNITION_OLD}, ${RECOGNITION_NEW}`),
  ];
  for (const each of headers) {
    await verifyWebhookSignature(NEW, each, RECOGNITION, NOW);
    await verifyWebhookSignature(OLD, each, RECOGNITION, NOW);
    await assert.rejects(verifyWebhookSignature(OTHER, each, RECOGNITION, NOW), WebhookVerificationError);
  }
  for (const signature of ["sha256=zz," + RECOGNITION_NEW, RECOGNITION_NEW.slice("sha256=".length), "sha256=97de", (RECOGNITION_OLD + ",").repeat(6) + RECOGNITION_NEW]) {
    await assert.rejects(verifyWebhookSignature(NEW, signed("del_0001", SIGNED_AT, signature), RECOGNITION, NOW), WebhookVerificationError, signature);
  }
});

test("a webhook answers its typed event", async () => {
  const read = await verifyWebhook(NEW, signed("del_0001", SIGNED_AT, RECOGNITION_NEW), RECOGNITION, NOW);
  assert.ok(isKnownWebhookEvent(read));
  assert.equal(read.event, "recognition.created");
  if (read.event === "recognition.created") {
    assert.equal(read.id, "rec_1");
    assert.equal(read.plate, "BRA2E19");
    assert.equal(read.camera_id, "cam_1");
    assert.equal(read.tenant_id, "ws_1");
    assert.equal(read.confidence, 0.97);
    assert.equal(read.captured_at, "2026-10-22T11:59:58Z");
  }
  const alert = await verifyWebhook(NEW, signed("del_0002", SIGNED_AT, ALERT_NEW), ALERT, NOW);
  assert.ok(isKnownWebhookEvent(alert));
  if (alert.event === "alert.triggered") {
    assert.equal(alert.rule_name, "Veículo bloqueado");
    assert.equal(alert.recognition_id, "rec_1");
  }
  const sent = await verifyWebhook(NEW, signed("del_0003", SIGNED_AT, TEST_NEW), TEST, NOW);
  assert.ok(isKnownWebhookEvent(sent) && sent.event === "webhook.test" && sent.sent_at === "2026-10-22T12:00:00Z");
  const unknown = await verifyWebhook(NEW, signed("del_0004", SIGNED_AT, UNKNOWN_NEW), UNKNOWN, NOW);
  assert.ok(!isKnownWebhookEvent(unknown));
  assert.equal(unknown.event, "payout.sent");
  assert.equal(unknown.id, "po_1");
  assert.deepEqual(unknown.body, JSON.parse(UNKNOWN));
});

test("a signed body that is not an event is refused", async () => {
  // The signature comes first: a body nobody signed is a signature error.
  await assert.rejects(verifyWebhook(NEW, signed("del_0001", SIGNED_AT, "sha256=" + "0".repeat(64)), "[1]", NOW), WebhookVerificationError);
});
