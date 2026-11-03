import assert from "node:assert/strict";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

import { Window } from "happy-dom";
import { createElement } from "react";
import { renderToString } from "react-dom/server";
import { compile } from "svelte/compiler";
import { render as renderSvelte } from "svelte/server";
import { createSSRApp } from "vue";
import { renderToString as renderVue } from "vue/server-renderer";

import { monitorCss, staticSource, type MonitorSnapshot } from "../src/monitor/index.ts";
import { AlprMonitorLive } from "../src/next/client.ts";
import { AlprMonitorServer, createMonitorRoute, createPagesSessionHandler, createSessionRoute } from "../src/next/index.ts";
import { AlprMonitor as ReactMonitor } from "../src/react/index.ts";
import { AlprMonitor as VueMonitor } from "../src/vue/index.ts";
import { defineAlprMonitor } from "../src/htmx/element.ts";
import { expressHandler, fastifyHandler, honoHandler, monitorFragments, monitorStylesheet, renderCameraRows, renderMonitor, renderSummary } from "../src/htmx/index.ts";

const EVIL = `<img src=x onerror="alert(1)">`;

const snapshot: MonitorSnapshot = {
  engine: "ok",
  hasMore: true,
  cameras: [
    { id: "a", name: "Portão", enabled: true, online: true, status: "running", lastReadAt: "2026-10-22T12:00:00Z", readsToday: 10, readsMonth: 100 },
    { id: "b", name: `Garagem ${EVIL}`, enabled: true, online: false, status: "failed", lastReadAt: null, readsToday: 0, readsMonth: 5 },
    { id: "c", name: "Fundos", enabled: false, online: false, status: "disabled", lastReadAt: null, readsToday: null, readsMonth: null },
  ],
};

/** The words of a rendering: tags and comments gone, spaces squeezed. */
function words(html: string): string {
  return html.replace(/<style[\s\S]*?<\/style>/g, "").replace(/<!--[\s\S]*?-->/g, "").replace(/<[^>]*>/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/\s+/g, " ").trim();
}

async function svelteMonitor(): Promise<unknown> {
  // The component is compiled the way a consumer's Svelte compiler does, from the file the package ships.
  const source = readFileSync(new URL("../dist/svelte/AlprMonitor.svelte", import.meta.url), "utf8");
  const { js } = compile(source, { generate: "server", filename: "AlprMonitor.svelte" });
  const file = new URL("../dist/svelte/.compiled-AlprMonitor.mjs", import.meta.url);
  writeFileSync(file, js.code);
  try {
    return (await import(pathToFileURL(file.pathname).href)).default;
  } finally {
    rmSync(file, { force: true });
  }
}

const rendered = async () => {
  const react = renderToString(createElement(ReactMonitor, { source: staticSource(snapshot), initialSnapshot: snapshot }));
  const vue = await renderVue(createSSRApp(VueMonitor, { source: staticSource(snapshot), initialSnapshot: snapshot }));
  const svelte = renderSvelte((await svelteMonitor()) as never, { props: { source: staticSource(snapshot), initialSnapshot: snapshot } }).body;
  const htmx = renderMonitor(snapshot, { path: "/alpr/monitor" });
  return { react, vue, svelte, htmx };
};

test("React, Vue, Svelte and HTML draw the same screen, with the same words", async () => {
  const all = await rendered();
  const reference = words(all.htmx);
  assert.match(reference, /Monitor Suas câmeras do Alpr\.sh\./);
  assert.match(reference, /Total de câmeras 3 Câmeras no Alpr\.sh/);
  assert.match(reference, /Online 1 Lendo placas agora/);
  assert.match(reference, /Offline 1 Sem leitura agora/);
  assert.match(reference, /Leituras hoje 10 105 no mês/);
  assert.match(reference, /Portão Online 10 hoje · 100 no mês 22\/10\/2026 às 09:00/);
  assert.match(reference, /Fundos Desativada – hoje · – no mês Nunca/);
  assert.match(reference, /Há mais câmeras do que as listadas\./);
  for (const [name, html] of Object.entries(all)) {
    assert.equal(words(html), reference, `${name} differs from the HTML rendering`);
  }
});

test("a camera's name is text in every framework, never markup", async () => {
  const all = await rendered();
  for (const [name, html] of Object.entries(all)) {
    assert.equal(html.includes("<img"), false, `${name} wrote the name as markup`);
    assert.ok(html.includes("&lt;img src=x onerror="), `${name} has no escaped name`);
  }
});

test("the screen is accessible markup: a captioned table with scoped headers, labelled fields, and no colour-only status", async () => {
  const html = renderMonitor(snapshot, { path: "/alpr/monitor" });
  assert.match(html, /<caption class="alpr-monitor__sr">Câmeras<\/caption>/);
  assert.match(html, /<th scope="col">Nome<\/th>/);
  assert.match(html, /<th scope="row" class="alpr-monitor__name">Portão<\/th>/);
  assert.match(html, /<label for="alpr-status">Status<\/label>/);
  assert.match(html, /<label for="alpr-search" class="alpr-monitor__sr">Buscar câmera<\/label>/);
  assert.match(html, /role="region" aria-label="Câmeras" tabindex="0"/);
  assert.match(html, /alpr-monitor__badge--online[^>]*>Online</);
  assert.match(html, /aria-busy="false"/);
  assert.match(monitorCss, /prefers-color-scheme:dark/);
  assert.match(monitorCss, /\[data-theme="dark"\]/);
  assert.match(monitorCss, /:focus-visible/);
  assert.equal(/url\(|@import|https?:/.test(monitorCss), false, "the stylesheet loads nothing from outside");
});

test("React and Vue write the stylesheet unless told not to; Svelte, Next and HTMX link it", async () => {
  const withStyle = renderToString(createElement(ReactMonitor, { source: staticSource(snapshot), initialSnapshot: snapshot, nonce: "abc" }));
  assert.match(withStyle, /<style nonce="abc">\.alpr-monitor/);
  assert.equal(renderToString(createElement(ReactMonitor, { source: staticSource(snapshot), initialSnapshot: snapshot, injectStyles: false })).includes("<style"), false);
  assert.match(await renderVue(createSSRApp(VueMonitor, { source: staticSource(snapshot), initialSnapshot: snapshot })), /<style>\.alpr-monitor/);
  assert.equal((await renderVue(createSSRApp(VueMonitor, { source: staticSource(snapshot), initialSnapshot: snapshot, injectStyles: false }))).includes("<style"), false);
  assert.equal((await rendered()).svelte.includes("<style"), false);
  assert.equal(readFileSync(new URL("../dist/monitor.css", import.meta.url), "utf8"), monitorCss);
});

test("a theme is chosen by an attribute, and the title can change", async () => {
  const dark = renderToString(createElement(ReactMonitor, { source: staticSource(snapshot), initialSnapshot: snapshot, theme: "dark", title: "Portaria", injectStyles: false }));
  assert.match(dark, /data-theme="dark"/);
  assert.match(dark, />Portaria</);
});

test("before the first load the screen says it is loading, and a failed load shows the error", async () => {
  const loading = renderToString(createElement(ReactMonitor, { source: staticSource(snapshot), injectStyles: false }));
  assert.match(words(loading), /Carregando as câmeras…/);
  assert.match(loading, /aria-live="polite"/);
});

test("Next: the server component loads on the server and hands the browser plain data", async () => {
  const element = await AlprMonitorServer({ source: staticSource(snapshot), endpointUrl: "/api/alpr/monitor", refreshMs: 15_000 });
  assert.equal(element.type, AlprMonitorLive);
  const props = element.props as { initialSnapshot: MonitorSnapshot | null; endpointUrl: string; source?: unknown };
  assert.deepEqual(props.initialSnapshot, snapshot);
  assert.equal(props.endpointUrl, "/api/alpr/monitor");
  assert.equal("source" in props, false, "a data source is a function holder and must not cross to the browser");
  assert.equal(JSON.stringify(props).includes("apiKey"), false);
  const html = renderToString(element);
  assert.match(words(html), /Portão Online/);
  // A failed server load still renders: the browser tries again by itself.
  const failed = await AlprMonitorServer({ source: { load: async () => { throw new Error("down"); } }, sessionUrl: "/api/alpr/session" });
  assert.equal((failed.props as { initialSnapshot: unknown }).initialSnapshot, null);
  const client = readFileSync(new URL("../dist/next/client.js", import.meta.url), "utf8");
  assert.match(client, /^"use client";/);
});

test("Next: the session route gives the browser a token and keeps the partner's secret", async () => {
  const calls: { url: string; auth: string | null; body: string }[] = [];
  const client = {
    clientId: "oda",
    clientSecret: "s3cret",
    fetch: (async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(input), auth: new Headers(init?.headers).get("authorization"), body: String(init?.body) });
      const person = JSON.parse(String(init?.body)).external_user_id;
      return person === "ghost" ? new Response(JSON.stringify({ error: "not_connected" }), { status: 404 }) : person === "down" ? new Response("", { status: 500 }) : new Response(JSON.stringify({ expires_at: 1792670400, token: "aws1.token" }), { status: 200 });
    }) as typeof fetch,
  };
  const route = createSessionRoute({ client, personOf: (request) => request.headers.get("x-person") });
  const ask = async (person: string | null) => route.POST(new Request("https://app.test/api/alpr/session", { method: "POST", headers: person ? { "x-person": person } : {} }));
  const ok = await ask("u1");
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get("cache-control"), "no-store");
  assert.deepEqual(await ok.json(), { token: "aws1.token", expiresAt: 1792670400 });
  assert.equal(calls[0]?.body, JSON.stringify({ external_user_id: "u1" }));
  assert.ok(calls[0]?.auth?.startsWith("Basic "));
  const unauthorized = await ask(null);
  assert.equal(unauthorized.status, 401);
  assert.equal(calls.length, 1, "nobody signed in: Alpr.sh is not even asked");
  assert.equal((await ask("ghost")).status, 404);
  const unavailable = await ask("down");
  assert.equal(unavailable.status, 503);
  assert.equal(JSON.stringify(await unavailable.json()).includes("s3cret"), false);
  // GET works too, for a route that is read rather than posted.
  assert.equal((await route.GET(new Request("https://app.test/x", { headers: { "x-person": "u1" } }))).status, 200);
  // The Pages Router.
  const sent: { status?: number; body?: unknown; headers: Record<string, string> } = { headers: {} };
  const response = { status(code: number) { sent.status = code; return response; }, setHeader(name: string, value: string) { sent.headers[name] = value; }, json(body: unknown) { sent.body = body; } };
  await createPagesSessionHandler({ client, personOf: () => "u1" })({ headers: {} }, response);
  assert.equal(sent.status, 200);
  assert.deepEqual(sent.body, { token: "aws1.token", expiresAt: 1792670400 });
  assert.equal(sent.headers["Cache-Control"], "no-store");
  // The monitor route answers the snapshot, behind the integrator's own check.
  const monitor = createMonitorRoute({ source: staticSource(snapshot), authorize: (request) => request.headers.has("x-person") });
  assert.equal((await monitor.GET(new Request("https://app.test/m"))).status, 401);
  assert.deepEqual(await (await monitor.GET(new Request("https://app.test/m", { headers: { "x-person": "u1" } }))).json(), snapshot);
});

test("HTMX: the fragments carry their own hx-* attributes and no script, style or handler of their own", () => {
  const clean: MonitorSnapshot = { ...snapshot, cameras: snapshot.cameras.map((each) => ({ ...each, name: each.name.replace(EVIL, "") })) };
  const html = renderMonitor(clean, { path: "/alpr/monitor", refreshSeconds: 10 });
  assert.match(html, /<tbody[^>]*id="alpr-rows"[^>]*hx-get="\/alpr\/monitor\?part=rows"/);
  assert.match(html, /hx-trigger="every 10s"/);
  assert.match(html, /hx-trigger="input changed delay:300ms, search"/);
  assert.match(html, /hx-include="#alpr-status, #alpr-search"/);
  assert.match(html, /<section[^>]*id="alpr-summary"[^>]*hx-get="\/alpr\/monitor\?part=summary"/);
  assert.equal(/<script|<style|\sstyle=|\son[a-z]+=|javascript:/i.test(html), false, "strict CSP: no inline script, style or handler");
  assert.equal(renderMonitor(snapshot, { path: "/x", refreshSeconds: 0 }).includes("every"), false);
  assert.equal(renderMonitor(snapshot, { path: "/x", idPrefix: "oda" }).includes('id="oda-rows"'), true);
  assert.equal(renderSummary(snapshot, { path: "/x" }).startsWith("<section"), true);
  const rows = renderCameraRows(snapshot, {}, "online", "");
  assert.equal(rows.startsWith("<tr"), true);
  assert.equal(rows.includes("Portão") && !rows.includes("Fundos"), true);
  assert.equal(rows.includes("<img"), false);
});

test("HTMX: the fragments handler answers the whole screen, the cards and the rows, filtered", async () => {
  const handler = monitorFragments({ source: staticSource(snapshot), path: "/alpr/monitor" });
  const get = (query: string, method = "GET") => handler(new Request(`https://app.test/alpr/monitor${query}`, { method }));
  const all = await get("");
  assert.equal(all.status, 200);
  assert.equal(all.headers.get("content-type"), "text/html; charset=utf-8");
  assert.equal(all.headers.get("cache-control"), "no-store");
  assert.match(await all.text(), /^<div class="alpr-monitor"/);
  const rows = await (await get("?part=rows&status=offline")).text();
  assert.equal(rows.includes("Garagem") && !rows.includes("Portão"), true);
  assert.equal((await (await get("?part=rows&q=fund")).text()).includes("Fundos"), true);
  assert.equal((await (await get("?part=rows&q=zzz")).text()).includes("Nenhuma câmera encontrada."), true);
  assert.match(await (await get("?part=summary")).text(), /^<section/);
  assert.equal((await get("", "POST")).status, 405);
  const head = await get("", "HEAD");
  assert.equal(head.status, 200);
  assert.equal(await head.text(), "");
  const denied = monitorFragments({ source: staticSource(snapshot), path: "/x", authorize: () => false });
  assert.equal((await denied(new Request("https://app.test/x"))).status, 401);
  // A failed load is drawn, with a 200: htmx swaps only 2xx.
  const failing = monitorFragments({ source: { load: async () => { throw new Error("down"); } }, path: "/x" });
  const failure = await failing(new Request("https://app.test/x"));
  assert.equal(failure.status, 200);
  assert.match(await failure.text(), /role="alert"/);
  const css = await monitorStylesheet()(new Request("https://app.test/css"));
  assert.equal(css.headers.get("content-type"), "text/css; charset=utf-8");
  assert.equal(await css.text(), monitorCss);
});

test("HTMX: Express, Fastify and Hono adapters hand the request over and write the answer back", async () => {
  const handler = monitorFragments({ source: staticSource(snapshot), path: "/alpr/monitor" });
  const out: { status?: number; headers?: Record<string, string>; body?: string } = {};
  await expressHandler(handler)(
    { method: "GET", protocol: "https", originalUrl: "/alpr/monitor?part=rows&q=port", headers: { cookie: "a=b" }, get: (name) => (name === "host" ? "app.test" : undefined) },
    { status(code) { out.status = code; return this; }, set(headers) { out.headers = headers; return this; }, send(body) { out.body = body; } },
  );
  assert.equal(out.status, 200);
  assert.ok(out.body?.includes("Portão") && !out.body.includes("Fundos"));
  assert.equal(out.headers?.["cache-control"], "no-store");
  const fastify: { status?: number; body?: string } = {};
  await fastifyHandler(handler)(
    { method: "GET", protocol: "http", hostname: "localhost", url: "/alpr/monitor?part=summary", headers: {} },
    { status(code) { fastify.status = code; return this; }, headers() { return this; }, send(body) { fastify.body = body; } },
  );
  assert.equal(fastify.status, 200);
  assert.ok(fastify.body?.startsWith("<section"));
  const hono = await honoHandler(handler)({ req: { raw: new Request("https://app.test/alpr/monitor?part=rows") } });
  assert.equal(hono.status, 200);
});

test("HTMX: the <alpr-monitor> element draws in its shadow root, filters, searches and refreshes", async () => {
  const window = new Window();
  const globals = globalThis as Record<string, unknown>;
  const saved = { HTMLElement: globals.HTMLElement, customElements: globals.customElements, CSSStyleSheet: globals.CSSStyleSheet };
  globals.HTMLElement = window.HTMLElement;
  globals.customElements = window.customElements;
  try {
    defineAlprMonitor();
    defineAlprMonitor();
    assert.ok(window.customElements.get("alpr-monitor"));
    let loads = 0;
    const element = window.document.createElement("alpr-monitor") as unknown as HTMLElement & { source: unknown; shadowRoot: ShadowRoot };
    element.setAttribute("refresh", "0");
    element.source = { load: async () => { loads++; return snapshot; } };
    window.document.body.append(element as never);
    await new Promise((resolve) => setTimeout(resolve, 20));
    const text = () => words(element.shadowRoot.innerHTML);
    assert.match(text(), /Portão Online/);
    assert.equal(loads, 1);
    // The screen is drawn again on each change, so a field is found again each time.
    const type = (value: string) => {
      const search = element.shadowRoot.getElementById("alpr-search") as unknown as HTMLInputElement;
      search.value = value;
      search.dispatchEvent(new window.Event("input", { bubbles: true }) as never);
    };
    type("fund");
    assert.match(text(), /Fundos/);
    assert.equal(/Portão/.test(text()), false);
    type("");
    const select = element.shadowRoot.getElementById("alpr-status") as unknown as HTMLSelectElement;
    select.value = "offline";
    select.dispatchEvent(new window.Event("change", { bubbles: true }) as never);
    assert.match(text(), /Garagem/);
    assert.equal(/Portão/.test(text()), false);
    const refresh = element.shadowRoot.querySelector('[data-part="refresh"]') as unknown as HTMLElement;
    refresh.dispatchEvent(new window.Event("click", { bubbles: true }) as never);
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(loads, 2);
    element.remove();
    await new Promise((resolve) => setTimeout(resolve, 10));
  } finally {
    globals.HTMLElement = saved.HTMLElement;
    globals.customElements = saved.customElements;
    await window.happyDOM.close();
  }
});

test("no browser entry reaches the API client or the helpers that hold a secret", () => {
  const dist = new URL("../dist/", import.meta.url);
  const reach = (entry: string, seen = new Set<string>()): Set<string> => {
    if (seen.has(entry)) {
      return seen;
    }
    seen.add(entry);
    const source = readFileSync(new URL(entry, dist), "utf8");
    for (const match of source.matchAll(/(?:from|import)\s*["'](\.[^"']+)["']/g)) {
      reach(new URL(match[1] as string, new URL(entry, dist)).href.replace(dist.href, ""), seen);
    }
    return seen;
  };
  for (const entry of ["monitor/index.js", "react/index.js", "vue/index.js", "svelte/index.js", "next/client.js", "htmx/element.js", "htmx/register.js"]) {
    const reached = [...reach(entry)];
    for (const forbidden of ["client.js", "monitor/server.js", "services.js", "webhooks.js"]) {
      assert.equal(reached.includes(forbidden), false, `${entry} reaches ${forbidden}`);
    }
    for (const file of reached) {
      const source = readFileSync(new URL(file, dist), "utf8");
      assert.equal(/alpr_live_|clientSecret|client_secret/.test(source), false, `${file} (from ${entry}) names a secret`);
    }
  }
  const component = readFileSync(new URL("svelte/AlprMonitor.svelte", dist), "utf8");
  assert.equal(/from "\.\.\/(client|monitor\/server)/.test(component) || component.includes("alpr_live_"), false);
});
