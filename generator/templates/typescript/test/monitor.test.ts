import assert from "node:assert/strict";
import { mock, test } from "node:test";

import { Alpr } from "../src/index.ts";
import { apiKeySource, basicAuthorization, createWidgetSession, listPersonCameras, partnerPersonSource } from "../src/monitor/server.ts";
import {
  createMonitor,
  endpointSource,
  formatRelative,
  monitorView,
  MonitorError,
  normalizeSnapshot,
  staticSource,
  statusOf,
  summarize,
  visibleCameras,
  widgetSource,
  type MonitorCamera,
  type MonitorSnapshot,
} from "../src/monitor/index.ts";

const camera = (id: string, extra: Partial<MonitorCamera> = {}): MonitorCamera => ({
  id,
  name: `Câmera ${id}`,
  enabled: true,
  online: true,
  status: "running",
  lastReadAt: "2026-10-22T12:00:00Z",
  readsToday: 10,
  readsMonth: 100,
  ...extra,
});

const snapshot: MonitorSnapshot = {
  engine: "ok",
  hasMore: false,
  cameras: [camera("a", { name: "Portão" }), camera("b", { name: "Garagem", online: false, status: "failed", readsToday: 0, readsMonth: 5, lastReadAt: null }), camera("c", { name: "Fundos", enabled: false, online: false, status: "disabled", readsToday: null, readsMonth: null }), camera("d", { name: "Entrada", online: null })],
};

const json = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

test("the partner API's answer and the same thing in camelCase read into a snapshot", () => {
  const partner = normalizeSnapshot({ data: [{ enabled: true, id: "x", last_read_at: "2026-10-25T18:04:05Z", name: "Portão", online: true, reads_month: 812, reads_today: 37, status: "running" }], engine: "unavailable", has_more: true });
  assert.deepEqual(partner, { cameras: [{ id: "x", name: "Portão", enabled: true, online: true, status: "running", lastReadAt: "2026-10-25T18:04:05Z", readsToday: 37, readsMonth: 812 }], engine: "unavailable", hasMore: true });
  const camel = normalizeSnapshot({ cameras: [{ id: "y", name: "Garagem", enabled: false, online: null, lastReadAt: null, readsToday: 1, readsMonth: 2 }] });
  assert.equal(camel.cameras[0]?.enabled, false);
  assert.equal(camel.cameras[0]?.online, null);
  assert.equal(camel.engine, "ok");
  assert.throws(() => normalizeSnapshot("nope"), MonitorError);
  assert.throws(() => normalizeSnapshot({ nothing: [] }), MonitorError);
  assert.equal(normalizeSnapshot({ data: [{ name: "no id" }, 3] }).cameras.length, 0);
});

test("the summary counts every camera and the status says why", () => {
  assert.deepEqual(summarize(snapshot), { total: 4, online: 1, offline: 1, readsToday: 20, readsMonth: 205 });
  assert.deepEqual(snapshot.cameras.map((each) => statusOf(each, "ok")), ["online", "offline", "disabled", "unknown"]);
  // With the reading service down, nothing enabled can be called online or offline.
  assert.deepEqual(snapshot.cameras.map((each) => statusOf(each, "unavailable")), ["unknown", "unknown", "disabled", "unknown"]);
  assert.equal(statusOf(camera("e", { status: "expired", online: false }), "ok"), "expired");
  assert.equal(summarize(null), null);
});

test("the filter and the search leave the cameras that match, ignoring case", () => {
  const state = (filter: "all" | "online" | "offline", query: string) => ({ snapshot, filter, query });
  assert.equal(visibleCameras(state("all", "")).length, 4);
  assert.deepEqual(visibleCameras(state("online", "")).map((each) => each.id), ["a"]);
  assert.deepEqual(visibleCameras(state("offline", "")).map((each) => each.id), ["b"]);
  assert.deepEqual(visibleCameras(state("all", "  GARA ")).map((each) => each.id), ["b"]);
  assert.deepEqual(visibleCameras(state("online", "garagem")), []);
});

test("the view words everything in Portuguese", () => {
  const view = monitorView({ phase: "ready", refreshing: false, snapshot, error: null, filter: "all", query: "", updatedAt: 0 }, Date.parse("2026-10-22T12:05:00Z"));
  assert.deepEqual(view.cards.map((card) => [card.label, card.value]), [["Total de câmeras", "4"], ["Online", "1"], ["Offline", "1"], ["Leituras hoje", "20"]]);
  assert.equal(view.cards[3]?.note, "205 no mês");
  assert.equal(view.rows[0]?.statusLabel, "Online");
  assert.equal(view.rows[0]?.statusNote, "Última leitura há 5 minutos");
  assert.equal(view.rows[0]?.lastRead, "22/10/2026 às 09:00");
  assert.equal(view.rows[1]?.statusNote, "Ainda sem leitura");
  assert.equal(view.rows[1]?.lastRead, "Nunca");
  assert.equal(view.rows[2]?.readsToday, "–");
  assert.equal(view.engine?.label, "Alpr.sh conectado");
  assert.equal(formatRelative("2026-10-22T11:00:00Z", Date.parse("2026-10-22T12:00:00Z")), "há 1 hora");
  const down = monitorView({ phase: "ready", refreshing: false, snapshot: { ...snapshot, engine: "unavailable" }, error: null, filter: "all", query: "", updatedAt: 0 });
  assert.equal(down.engine?.label, "Leitura do Alpr.sh sem resposta");
  const empty = monitorView({ phase: "ready", refreshing: false, snapshot: { cameras: [], engine: "ok", hasMore: false }, error: null, filter: "all", query: "", updatedAt: 0 });
  assert.equal(empty.empty, "Ainda não há câmeras neste espaço.");
  const none = monitorView({ phase: "ready", refreshing: false, snapshot, error: null, filter: "all", query: "zzz", updatedAt: 0 });
  assert.equal(none.empty, "Nenhuma câmera encontrada.");
  assert.equal(none.filtered, true);
});

test("the monitor loads, refreshes on a timer, and keeps the last snapshot when a refresh fails", async () => {
  mock.timers.enable({ apis: ["setInterval"] });
  try {
    let calls = 0;
    let fail = false;
    const monitor = createMonitor({
      refreshMs: 30_000,
      source: { load: async () => {
        calls++;
        if (fail) {
          throw new MonitorError("network", "sem rede");
        }
        return snapshot;
      } },
    });
    const seen: string[] = [];
    monitor.watch((state) => seen.push(state.phase + (state.refreshing ? "*" : "")));
    assert.equal(monitor.getState().phase, "idle");
    monitor.start();
    monitor.start();
    await monitor.refresh();
    assert.equal(monitor.getState().phase, "ready");
    assert.equal(monitor.getState().snapshot?.cameras.length, 4);
    const before = calls;
    mock.timers.tick(30_000);
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(calls, before + 1);
    fail = true;
    await monitor.refresh();
    assert.equal(monitor.getState().phase, "ready");
    assert.equal(monitor.getState().snapshot?.cameras.length, 4);
    assert.equal(monitor.getState().error?.message, "sem rede");
    monitor.setFilter("online");
    monitor.setQuery("x");
    assert.equal(monitor.getState().filter, "online");
    monitor.stop();
    const stopped = calls;
    mock.timers.tick(90_000);
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(calls, stopped);
    // Svelte's store contract: the state now, then every change.
    const values: string[] = [];
    const unsubscribe = monitor.subscribe((state) => values.push(state.filter));
    monitor.setFilter("offline");
    unsubscribe();
    monitor.setFilter("all");
    assert.deepEqual(values, ["online", "offline"]);
  } finally {
    mock.timers.reset();
  }
});

test("a first failure is an error state, and a load in flight is cancelled by stop", async () => {
  const monitor = createMonitor({ source: { load: async () => { throw new Error("boom"); } } });
  await monitor.refresh();
  assert.equal(monitor.getState().phase, "error");
  assert.equal(monitor.getState().error?.kind, "network");
  let aborted = false;
  const slow = createMonitor({ source: { load: (signal) => new Promise((_resolve, reject) => signal?.addEventListener("abort", () => { aborted = true; reject(new Error("aborted")); })) } });
  const pending = slow.refresh();
  slow.stop();
  await pending;
  assert.equal(aborted, true);
  assert.equal(slow.getState().phase, "loading");
  assert.equal(slow.getState().error, null);
});

test("an endpoint source asks the integrator's backend, with no key", async () => {
  const seen: { url: string; init: RequestInit }[] = [];
  const source = endpointSource("/api/alpr/monitor", { fetch: async (input, init) => { seen.push({ url: String(input), init: init ?? {} }); return json(200, snapshot); } });
  assert.equal((await source.load()).cameras.length, 4);
  assert.equal(seen[0]?.url, "/api/alpr/monitor");
  assert.equal(seen[0]?.init.credentials, "same-origin");
  assert.equal(JSON.stringify(seen[0]?.init.headers).includes("Authorization"), false);
  const refused = (status: number, body: unknown = {}) => endpointSource("/x", { fetch: async () => json(status, body) }).load();
  await assert.rejects(refused(401), (error: unknown) => error instanceof MonitorError && error.kind === "unauthorized");
  await assert.rejects(refused(402, { error: "subscription_required", renew_url: "https://alpr.sh/painel/planos" }), (error: unknown) => error instanceof MonitorError && error.kind === "subscription" && error.renewUrl === "https://alpr.sh/painel/planos");
  await assert.rejects(refused(503), (error: unknown) => error instanceof MonitorError && error.kind === "unavailable");
  await assert.rejects(endpointSource("/x", { fetch: async () => { throw new TypeError("offline"); } }).load(), (error: unknown) => error instanceof MonitorError && error.kind === "network");
});

test("a widget source reads Alpr.sh with the short-lived token, renews it, and retries once on a 401", async () => {
  let now = 1_000_000;
  const sessions: string[] = [];
  const calls: { url: string; auth: string | null }[] = [];
  const source = widgetSource({
    now: () => now,
    getSession: async () => {
      const token = `aws1.${sessions.length + 1}`;
      sessions.push(token);
      return { token, expiresAt: now / 1000 + 900 };
    },
    fetch: async (input, init) => {
      const auth = new Headers(init?.headers).get("authorization");
      calls.push({ url: String(input), auth });
      if (auth === "Bearer aws1.1" && calls.length === 3) {
        return json(401, { error: "invalid_token" });
      }
      return json(200, { data: [{ id: "x", name: "Portão", enabled: true, online: true, status: "running", last_read_at: null, reads_today: 1, reads_month: 2 }], engine: "ok", has_more: false });
    },
  });
  await source.load();
  assert.equal(calls[0]?.url, "https://alpr.sh/api/partner/v1/cameras/activity");
  assert.equal(calls[0]?.auth, "Bearer aws1.1");
  await source.load();
  assert.equal(sessions.length, 1, "the session is kept while it lasts");
  // Refused once: a new session, and the call again.
  await source.load();
  assert.equal(sessions.length, 2);
  assert.equal(calls.at(-1)?.auth, "Bearer aws1.2");
  // Twenty seconds before it expires, it is renewed rather than risked.
  now += 890_000;
  await source.load();
  assert.equal(sessions.length, 3);
  const none = widgetSource({ getSession: async () => null, fetch: async () => json(200, {}) });
  await assert.rejects(none.load(), (error: unknown) => error instanceof MonitorError && error.kind === "unauthorized");
  const inactive = widgetSource({ getSession: async () => ({ token: "t", expiresAt: Date.now() / 1000 + 900 }), fetch: async () => json(402, { error: "subscription_required", renew_url: "https://alpr.sh/painel/planos" }) });
  await assert.rejects(inactive.load(), (error: unknown) => error instanceof MonitorError && error.kind === "subscription");
});

test("the partner's server helpers send the client as RFC 6749 asks and never answer its secret", async () => {
  // Each part is form-urlencoded before the Basic encoding: a space is +, a colon is %3A.
  const header = basicAuthorization("cli ent", "se:cr/et+é");
  assert.equal(atob(header.replace("Basic ", "")), "cli+ent:se%3Acr%2Fet%2B%C3%A9");
  const calls: { url: string; method: string; auth: string | null; body: string }[] = [];
  const client = {
    clientId: "oda",
    clientSecret: "s3cret",
    fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(input), method: init?.method ?? "GET", auth: new Headers(init?.headers).get("authorization"), body: String(init?.body ?? "") });
      const url = String(input);
      if (url.endsWith("/widget-sessions")) {
        return json(200, { expires_at: 1792670400, token: "aws1.token" });
      }
      if (url.includes("/people/ghost/")) {
        return json(404, { error: "not_connected" });
      }
      if (url.includes("/people/bad/")) {
        return json(401, { error: "invalid_client" });
      }
      return json(200, { data: [{ id: "x", name: "Portão", enabled: true, online: true, status: "running", last_read_at: null, reads_today: 1, reads_month: 2 }], engine: "ok", has_more: false });
    }) as typeof fetch,
  };
  assert.deepEqual(await createWidgetSession(client, "u/1"), { token: "aws1.token", expiresAt: 1792670400 });
  assert.equal(calls[0]?.url, "https://alpr.sh/api/partner/v1/widget-sessions");
  assert.equal(calls[0]?.method, "POST");
  assert.equal(calls[0]?.body, JSON.stringify({ external_user_id: "u/1" }));
  assert.equal(calls[0]?.auth, basicAuthorization("oda", "s3cret"));
  const people = await listPersonCameras(client, "u/1");
  assert.equal(people?.cameras[0]?.name, "Portão");
  assert.equal(calls[1]?.url, "https://alpr.sh/api/partner/v1/people/u%2F1/cameras");
  assert.equal(await listPersonCameras(client, "ghost"), null);
  await assert.rejects(listPersonCameras(client, "bad"), (error: unknown) => error instanceof MonitorError && error.kind === "unauthorized" && !error.message.includes("s3cret"));
  await assert.rejects(partnerPersonSource(client, "ghost").load(), MonitorError);
  assert.equal((await partnerPersonSource(client, "u/1").load()).cameras.length, 1);
});

test("the API-key source counts today's and the month's readings per camera, and says nothing about online", async () => {
  const reading = (id: string, cameraId: string | null, capturedAt: string) => ({ id, cameraId, capturedAt, conf: 90, plate: "BRA2E19", source: cameraId ? "camera" : "api" });
  const pages: Record<string, unknown> = {
    "": { data: [reading("r1", "cam_1", "2026-10-22T11:00:00-03:00"), reading("r2", null, "2026-10-22T10:00:00-03:00"), reading("r3", "cam_1", "2026-10-21T10:00:00-03:00")], next: "p2" },
    p2: { data: [reading("r4", "cam_2", "2026-10-02T10:00:00-03:00"), reading("r5", "cam_1", "2026-09-30T23:00:00-03:00")], next: "p3" },
    p3: { data: [reading("r6", "cam_1", "2026-09-01T10:00:00-03:00")], next: null },
  };
  const seen: string[] = [];
  const alpr = new Alpr({
    apiKey: "alpr_live_" + "0".repeat(64),
    baseUrl: "https://alpr.test",
    fetch: async (input) => {
      const url = new URL(String(input));
      seen.push(url.pathname + url.search);
      if (url.pathname === "/api/v1/cameras") {
        return json(200, { data: [
          { createdAt: "2026-10-01T09:00:00-03:00", enabled: true, id: "cam_1", location: "", name: "Portão", protocol: "rtsp", readingArea: null },
          { createdAt: "2026-10-01T09:00:00-03:00", enabled: false, id: "cam_2", location: "", name: "Garagem", protocol: "rtsp", readingArea: null },
          { createdAt: "2026-10-01T09:00:00-03:00", enabled: true, id: "cam_3", location: "", name: "Fundos", protocol: "rtsp", readingArea: null },
        ] });
      }
      return json(200, pages[url.searchParams.get("before") ?? ""]);
    },
  });
  const result = await apiKeySource(alpr, { now: () => Date.parse("2026-10-22T15:00:00Z") }).load();
  assert.equal(result.engine, "ok");
  assert.deepEqual(result.cameras.map((each) => [each.id, each.readsToday, each.readsMonth, each.lastReadAt, each.online, each.status]), [
    ["cam_1", 1, 2, "2026-10-22T11:00:00-03:00", null, "enabled"],
    ["cam_2", 0, 1, "2026-10-02T10:00:00-03:00", null, "disabled"],
    ["cam_3", 0, 0, null, null, "enabled"],
  ]);
  // It stops at the first reading before the month: page 3 is never asked.
  assert.equal(seen.some((each) => each.includes("before=p3")), false);
  const view = monitorView({ phase: "ready", refreshing: false, snapshot: result, error: null, filter: "all", query: "", updatedAt: 0 });
  assert.deepEqual(view.rows.map((row) => row.statusLabel), ["Sem informação", "Desativada", "Sem informação"]);
});

test("a static source answers what it was given", async () => {
  assert.equal(await staticSource(snapshot).load(), snapshot);
});
