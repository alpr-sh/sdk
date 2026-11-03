import { monitorCss, type MonitorDataSource, type StatusFilter } from "../monitor/index.ts";
import { escapeHtml, failedState, renderCameraRows, renderMonitor, renderSummary, type FragmentOptions } from "./html.ts";

export interface MonitorFragmentsOptions extends FragmentOptions {
  /** Read on the server, with the secret (apiKeySource or partnerPersonSource). It never reaches the browser. */
  source: MonitorDataSource;
  /** Return false (or throw) to answer 401: whether this request may see the monitor. */
  authorize?: (request: Request) => Promise<boolean> | boolean;
}

const HTML = { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", Vary: "HX-Request" };

/**
 * A handler for the monitor's fragments, on the Web `Request` and `Response`
 * every modern runtime has. GET `?part=all` (the default) answers the whole
 * screen, `?part=summary` the cards and `?part=rows` the table rows,
 * filtered by `?status=online|offline` and `?q=`. Load htmx on the page and
 * put `renderMonitor(...)` or `hx-get="<path>" hx-trigger="load"` in it.
 */
export function monitorFragments(options: MonitorFragmentsOptions): (request: Request) => Promise<Response> {
  return async (request) => {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }
    try {
      if (options.authorize && !(await options.authorize(request))) {
        return new Response(`<p class="alpr-monitor__alert" role="alert">${escapeHtml("Entre para ver as câmeras.")}</p>`, { status: 401, headers: HTML });
      }
    } catch {
      return new Response("", { status: 401, headers: HTML });
    }
    const query = new URL(request.url).searchParams;
    const part = query.get("part") ?? "all";
    const status = query.get("status");
    const filter: StatusFilter = status === "online" || status === "offline" ? status : "all";
    const q = (query.get("q") ?? "").slice(0, 200);
    let input;
    try {
      input = await options.source.load(request.signal);
    } catch (error) {
      input = failedState(error);
    }
    // A failed load answers 200 with the error drawn: htmx swaps only 2xx.
    const fragmentOptions = { ...options, now: Date.now() };
    const body = part === "rows" ? renderCameraRows(input, fragmentOptions, filter, q) : part === "summary" ? renderSummary(input, fragmentOptions) : renderMonitor(input, fragmentOptions, filter, q);
    return new Response(request.method === "HEAD" ? null : body, { status: 200, headers: HTML });
  };
}

/** A handler that serves the stylesheet, for <link rel="stylesheet" href="…"> under a strict CSP. */
export function monitorStylesheet(): (request: Request) => Promise<Response> {
  return async () => new Response(monitorCss, { status: 200, headers: { "Content-Type": "text/css; charset=utf-8", "Cache-Control": "public, max-age=3600" } });
}

/** The minimal shape of an Express request and response. */
interface ExpressRequest {
  method: string;
  protocol: string;
  originalUrl: string;
  headers: Record<string, string | string[] | undefined>;
  get(name: string): string | undefined;
}
interface ExpressResponse {
  status(code: number): ExpressResponse;
  set(headers: Record<string, string>): ExpressResponse;
  send(body: string): unknown;
}

function headersOf(source: Record<string, string | string[] | undefined>): Headers {
  const headers = new Headers();
  for (const [name, value] of Object.entries(source)) {
    if (typeof value === "string") {
      headers.set(name, value);
    } else if (Array.isArray(value)) {
      headers.set(name, value.join(", "));
    }
  }
  return headers;
}

/** Express: `app.get("/alpr/monitor", expressHandler(monitorFragments({ … })))`. */
export function expressHandler(handler: (request: Request) => Promise<Response>): (request: ExpressRequest, response: ExpressResponse) => Promise<void> {
  return async (request, response) => {
    const url = `${request.protocol}://${request.get("host") ?? "localhost"}${request.originalUrl}`;
    const answer = await handler(new Request(url, { method: request.method, headers: headersOf(request.headers) }));
    response.status(answer.status).set(Object.fromEntries(answer.headers)).send(await answer.text());
  };
}

/** The minimal shape of a Fastify request and reply. */
interface FastifyRequest {
  method: string;
  protocol: string;
  hostname: string;
  url: string;
  headers: Record<string, string | string[] | undefined>;
}
interface FastifyReply {
  status(code: number): FastifyReply;
  headers(headers: Record<string, string>): FastifyReply;
  send(body: string): unknown;
}

/** Fastify: `app.get("/alpr/monitor", fastifyHandler(monitorFragments({ … })))`. */
export function fastifyHandler(handler: (request: Request) => Promise<Response>): (request: FastifyRequest, reply: FastifyReply) => Promise<void> {
  return async (request, reply) => {
    const answer = await handler(new Request(`${request.protocol}://${request.hostname}${request.url}`, { method: request.method, headers: headersOf(request.headers) }));
    reply.status(answer.status).headers(Object.fromEntries(answer.headers)).send(await answer.text());
  };
}

/** Hono: `app.get("/alpr/monitor", honoHandler(monitorFragments({ … })))`. Hono speaks Request and Response already. */
export function honoHandler(handler: (request: Request) => Promise<Response>): (context: { req: { raw: Request } }) => Promise<Response> {
  return (context) => handler(context.req.raw);
}
