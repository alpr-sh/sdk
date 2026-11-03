import { text } from "./format.ts";
import { MonitorError, type MonitorCamera, type MonitorDataSource, type MonitorSession, type MonitorSnapshot } from "./types.ts";

type Json = Record<string, unknown>;

const isObject = (value: unknown): value is Json => typeof value === "object" && value !== null && !Array.isArray(value);
const str = (value: unknown, fallback = ""): string => (typeof value === "string" ? value : fallback);
const num = (value: unknown): number | null => (typeof value === "number" && Number.isFinite(value) ? value : null);

/**
 * Reads the answer of a camera list into a snapshot. It takes the monitor of
 * Alpr.sh's partner API (`data`, `last_read_at`, `reads_today`, `has_more`)
 * and the same thing written in camelCase, with `cameras` or `data`, so an
 * integrator's backend may forward either.
 */
export function normalizeSnapshot(raw: unknown): MonitorSnapshot {
  if (!isObject(raw)) {
    throw new MonitorError("unavailable", text.unavailableError);
  }
  const list = Array.isArray(raw.cameras) ? raw.cameras : Array.isArray(raw.data) ? raw.data : undefined;
  if (!list) {
    throw new MonitorError("unavailable", text.unavailableError);
  }
  const cameras: MonitorCamera[] = [];
  for (const each of list) {
    if (!isObject(each) || typeof each.id !== "string") {
      continue;
    }
    cameras.push({
      id: each.id,
      name: str(each.name, str(each.label, each.id)),
      enabled: each.enabled !== false,
      online: typeof each.online === "boolean" ? each.online : null,
      status: str(each.status),
      lastReadAt: typeof each.last_read_at === "string" ? each.last_read_at : typeof each.lastReadAt === "string" ? each.lastReadAt : null,
      readsToday: num(each.reads_today ?? each.readsToday),
      readsMonth: num(each.reads_month ?? each.readsMonth),
    });
  }
  return { cameras, engine: raw.engine === "unavailable" ? "unavailable" : "ok", hasMore: raw.has_more === true || raw.hasMore === true };
}

async function refusal(response: Response): Promise<MonitorError> {
  let body: Json = {};
  try {
    const parsed: unknown = await response.json();
    if (isObject(parsed)) {
      body = parsed;
    }
  } catch {
    // A refusal without a JSON body is still a refusal.
  }
  if (response.status === 402 || body.error === "subscription_required") {
    return new MonitorError("subscription", text.subscriptionError, typeof body.renew_url === "string" ? body.renew_url : undefined);
  }
  if (response.status === 401 || response.status === 403 || response.status === 404) {
    return new MonitorError("unauthorized", text.unauthorizedError);
  }
  return new MonitorError(response.status >= 500 || response.status === 429 ? "unavailable" : "network", response.status >= 500 || response.status === 429 ? text.unavailableError : text.networkError);
}

async function fetchSnapshot(fetchImpl: typeof fetch, url: string, init: RequestInit): Promise<MonitorSnapshot | Response> {
  let response: Response;
  try {
    response = await fetchImpl(url, init);
  } catch (error) {
    if (init.signal?.aborted) {
      throw error;
    }
    throw new MonitorError("network", text.networkError);
  }
  if (!response.ok) {
    return response;
  }
  try {
    return normalizeSnapshot(await response.json());
  } catch (error) {
    if (error instanceof MonitorError) {
      throw error;
    }
    throw new MonitorError("unavailable", text.unavailableError);
  }
}

export interface EndpointSourceOptions {
  fetch?: typeof fetch;
  /** Extra headers, such as a CSRF token. Never the workspace's API key. */
  headers?: Record<string, string>;
  /** Whether cookies go with the call; "same-origin" by default. */
  credentials?: RequestCredentials;
}

/**
 * The snapshot an integrator's own backend answers at `url`: the backend holds
 * the API key (or the partner credentials), the browser holds nothing.
 */
export function endpointSource(url: string, options: EndpointSourceOptions = {}): MonitorDataSource {
  return {
    async load(signal) {
      const init: RequestInit = { method: "GET", headers: { Accept: "application/json", ...options.headers }, credentials: options.credentials ?? "same-origin", cache: "no-store", redirect: "manual" };
      if (signal) {
        init.signal = signal;
      }
      const result = await fetchSnapshot(options.fetch ?? ((input, request) => fetch(input, request)), url, init);
      if (result instanceof Response) {
        throw await refusal(result);
      }
      return result;
    },
  };
}

export interface WidgetSourceOptions {
  /**
   * Asks the integrator's backend for a session (the backend calls
   * createWidgetSession, which holds the partner's secret) and answers null
   * when the person has not connected. Called again when the session is
   * about to expire or Alpr.sh refuses it.
   */
  getSession: () => Promise<MonitorSession | null>;
  /** Alpr.sh's address; https://alpr.sh by default. */
  baseUrl?: string;
  fetch?: typeof fetch;
  /** The clock in ms; Date.now by default. */
  now?: () => number;
}

/** Reads the monitor of Alpr.sh straight from the browser, with the short-lived token of the widget. The token is the only credential the page holds. */
export function widgetSource(options: WidgetSourceOptions): MonitorDataSource {
  const base = (options.baseUrl ?? "https://alpr.sh").replace(/\/+$/, "");
  const now = options.now ?? Date.now;
  let session: MonitorSession | null = null;

  const ensure = async (renew: boolean): Promise<MonitorSession> => {
    // Thirty seconds before it expires, the token is renewed rather than risked.
    if (!renew && session && session.expiresAt * 1000 - 30_000 > now()) {
      return session;
    }
    session = null;
    const fresh = await options.getSession();
    if (!fresh) {
      throw new MonitorError("unauthorized", text.unauthorizedError);
    }
    session = fresh;
    return fresh;
  };

  const attempt = async (token: string, signal: AbortSignal | undefined) => {
    const init: RequestInit = { method: "GET", headers: { Accept: "application/json", Authorization: `Bearer ${token}` }, credentials: "omit", cache: "no-store", redirect: "manual" };
    if (signal) {
      init.signal = signal;
    }
    return fetchSnapshot(options.fetch ?? ((input, request) => fetch(input, request)), `${base}/api/partner/v1/cameras/activity`, init);
  };

  return {
    async load(signal) {
      let result = await attempt((await ensure(false)).token, signal);
      if (result instanceof Response && result.status === 401) {
        // The token was refused: one new one, once.
        result = await attempt((await ensure(true)).token, signal);
      }
      if (result instanceof Response) {
        throw await refusal(result);
      }
      return result;
    },
  };
}

/** A source that always answers the snapshot it was given: for previews, tests and server rendering. */
export function staticSource(snapshot: MonitorSnapshot): MonitorDataSource {
  return { load: async () => snapshot };
}
