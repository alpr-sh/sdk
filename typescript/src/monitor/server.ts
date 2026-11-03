import type { Alpr } from "../client.ts";
import { normalizeSnapshot } from "./sources.ts";
import { text } from "./format.ts";
import { MonitorError, type MonitorCamera, type MonitorDataSource, type MonitorSession, type MonitorSnapshot } from "./types.ts";

// Server only: these helpers hold a secret (the partner's client secret, or the workspace's API key). Never import this file in code a browser runs.

/** The OAuth client of a native partner of Alpr.sh. */
export interface PartnerClient {
  clientId: string;
  clientSecret: string;
  /** Alpr.sh's address; https://alpr.sh by default. */
  baseUrl?: string;
  fetch?: typeof fetch;
}

/** application/x-www-form-urlencoded, as RFC 6749 asks for a client's id and secret. */
function formEncode(value: string): string {
  let out = "";
  for (const byte of new TextEncoder().encode(value)) {
    const char = String.fromCharCode(byte);
    if (/[A-Za-z0-9*\-._]/.test(char)) {
      out += char;
    } else if (byte === 0x20) {
      out += "+";
    } else {
      out += `%${byte.toString(16).toUpperCase().padStart(2, "0")}`;
    }
  }
  return out;
}

/** The Authorization header of the partner's server calls. */
export function basicAuthorization(clientId: string, clientSecret: string): string {
  const bytes = new TextEncoder().encode(`${formEncode(clientId)}:${formEncode(clientSecret)}`);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return `Basic ${btoa(binary)}`;
}

async function partnerCall(client: PartnerClient, method: string, path: string, body?: unknown): Promise<Response> {
  const base = (client.baseUrl ?? "https://alpr.sh").replace(/\/+$/, "");
  const headers: Record<string, string> = { Authorization: basicAuthorization(client.clientId, client.clientSecret), Accept: "application/json" };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
  }
  const init: RequestInit = { method, headers, redirect: "manual", cache: "no-store", signal: AbortSignal.timeout(15_000) };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
  }
  try {
    return await (client.fetch ?? ((input, request) => fetch(input, request)))(base + path, init);
  } catch {
    throw new MonitorError("network", text.networkError);
  }
}

function failure(response: Response): MonitorError {
  if (response.status === 401 || response.status === 403) {
    return new MonitorError("unauthorized", "As credenciais do parceiro foram recusadas pelo Alpr.sh.");
  }
  return new MonitorError("unavailable", text.unavailableError);
}

/**
 * Asks Alpr.sh for the short-lived widget session of a person who already
 * connected, from the partner's server. `externalUserId` is the person's id
 * at the partner, taken from the partner's own session, never from the
 * browser. Answers null when the person never connected or disconnected.
 * The token is a credential: hand it only to that person, in a response with
 * no cache, and never log it.
 */
export async function createWidgetSession(client: PartnerClient, externalUserId: string): Promise<MonitorSession | null> {
  const response = await partnerCall(client, "POST", "/api/partner/v1/widget-sessions", { external_user_id: externalUserId });
  if (response.status === 404) {
    return null;
  }
  if (!response.ok) {
    throw failure(response);
  }
  const body = (await response.json()) as { token?: unknown; expires_at?: unknown };
  if (typeof body.token !== "string" || typeof body.expires_at !== "number") {
    throw new MonitorError("unavailable", text.unavailableError);
  }
  return { token: body.token, expiresAt: body.expires_at };
}

/** The cameras of a connected person, read from the partner's server. Null when the person is not connected. */
export async function listPersonCameras(client: PartnerClient, externalUserId: string): Promise<MonitorSnapshot | null> {
  const response = await partnerCall(client, "GET", `/api/partner/v1/people/${encodeURIComponent(externalUserId)}/cameras`);
  if (response.status === 404) {
    return null;
  }
  if (!response.ok) {
    throw failure(response);
  }
  return normalizeSnapshot(await response.json());
}

/** A source that reads one person's cameras through the partner's credentials: for the server, to render or to answer an endpoint. */
export function partnerPersonSource(client: PartnerClient, externalUserId: string): MonitorDataSource {
  return {
    async load() {
      const snapshot = await listPersonCameras(client, externalUserId);
      if (!snapshot) {
        throw new MonitorError("unauthorized", "A conta do Alpr.sh não está conectada.");
      }
      return snapshot;
    },
  };
}

export interface ApiKeySourceOptions {
  /** The most readings it walks to count the month; 5 000 by default. Past it the counts are lower bounds. */
  maxReadings?: number;
  /** The clock in ms; Date.now by default. */
  now?: () => number;
}

/** The date in the Alpr.sh zone, as the readings write it: 2026-10-22. */
function saoPauloDate(ms: number): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo", year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(ms));
}

/**
 * A snapshot from the workspace's API key: the cameras, and the readings of
 * today and of the month counted from the readings list. The public API does
 * not say whether a camera is online, so `online` is null and the screen
 * shows "Sem informação" for an enabled camera; the partner API (see
 * partnerPersonSource and widgetSource) has the live state.
 */
export function apiKeySource(alpr: Pick<Alpr, "cameras" | "recognitions">, options: ApiKeySourceOptions = {}): MonitorDataSource {
  return {
    async load(signal) {
      const now = (options.now ?? Date.now)();
      const today = saoPauloDate(now);
      const month = today.slice(0, 7);
      const limit = options.maxReadings ?? 5000;
      const callOptions = signal ? { signal } : undefined;
      let cameras: Awaited<ReturnType<typeof alpr.cameras.list>>;
      try {
        cameras = await alpr.cameras.list(callOptions);
      } catch (error) {
        throw error instanceof MonitorError ? error : new MonitorError("unavailable", text.unavailableError);
      }
      const seen = new Map<string, { today: number; month: number; last: string | null }>();
      let walked = 0;
      try {
        for await (const reading of alpr.recognitions.listIter({}, callOptions)) {
          // Newest first: past the month, nothing more counts.
          if (reading.capturedAt.slice(0, 7) < month || ++walked > limit) {
            break;
          }
          if (reading.cameraId === null) {
            continue;
          }
          const entry = seen.get(reading.cameraId) ?? { today: 0, month: 0, last: null };
          entry.month++;
          if (reading.capturedAt.slice(0, 10) === today) {
            entry.today++;
          }
          entry.last ??= reading.capturedAt;
          seen.set(reading.cameraId, entry);
        }
      } catch {
        throw new MonitorError("unavailable", text.unavailableError);
      }
      return {
        engine: "ok",
        hasMore: false,
        cameras: cameras.map((camera): MonitorCamera => {
          const entry = seen.get(camera.id);
          return {
            id: camera.id,
            name: camera.name,
            enabled: camera.enabled,
            online: null,
            status: camera.enabled ? "enabled" : "disabled",
            lastReadAt: entry?.last ?? null,
            readsToday: entry?.today ?? 0,
            readsMonth: entry?.month ?? 0,
          };
        }),
      };
    },
  };
}
