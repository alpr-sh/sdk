import { createElement, type ReactElement } from "react";

import { createWidgetSession, type PartnerClient } from "../monitor/server.ts";
import type { MonitorDataSource, MonitorSnapshot } from "../monitor/index.ts";
import { AlprMonitorLive, type AlprMonitorLiveProps } from "./client.ts";

export { apiKeySource, createWidgetSession, listPersonCameras, partnerPersonSource, type PartnerClient } from "../monitor/server.ts";
export { AlprMonitorLive, type AlprMonitorLiveProps } from "./client.ts";
export { endpointSource, MonitorError, monitorCss, staticSource, widgetSource } from "../monitor/index.ts";
export type { MonitorCamera, MonitorDataSource, MonitorSession, MonitorSnapshot } from "../monitor/index.ts";

export interface AlprMonitorServerProps extends Omit<AlprMonitorLiveProps, "initialSnapshot"> {
  /** Read on the server, with the secret (apiKeySource or partnerPersonSource). It never reaches the browser. */
  source: MonitorDataSource;
}

/**
 * The Server Component of the monitor (App Router): it loads the cameras on
 * the server, so the page arrives drawn, and hands the browser only the data
 * and the way to refresh it (`endpointUrl` or `sessionUrl`).
 *
 *     export default function Page() {
 *       return <AlprMonitorServer source={apiKeySource(alpr)} endpointUrl="/api/alpr/monitor" />;
 *     }
 */
export async function AlprMonitorServer(props: AlprMonitorServerProps): Promise<ReactElement> {
  const { source, ...live } = props;
  let initialSnapshot: MonitorSnapshot | null = null;
  try {
    initialSnapshot = await source.load();
  } catch {
    // The browser tries again by itself and shows the error.
  }
  return createElement(AlprMonitorLive, { ...live, initialSnapshot });
}

export interface SessionRouteOptions {
  client: PartnerClient;
  /** Who is asking: the id of the signed-in person at your system, from your own session. Return null when nobody is signed in. Never read it from the request body or the query. */
  personOf: (request: Request) => Promise<string | null> | string | null;
}

const NO_STORE = { "Cache-Control": "no-store", "Content-Type": "application/json" };

async function mint(options: SessionRouteOptions, request: Request): Promise<Response> {
  const person = await options.personOf(request);
  if (!person) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: NO_STORE });
  }
  try {
    const session = await createWidgetSession(options.client, person);
    if (!session) {
      return new Response(JSON.stringify({ error: "not_connected" }), { status: 404, headers: NO_STORE });
    }
    return new Response(JSON.stringify({ token: session.token, expiresAt: session.expiresAt }), { status: 200, headers: NO_STORE });
  } catch {
    return new Response(JSON.stringify({ error: "unavailable" }), { status: 503, headers: NO_STORE });
  }
}

/**
 * The route handlers that give the browser a short-lived Alpr.sh session
 * without the partner's secret: export them from app/api/alpr/session/route.ts
 * (`export const { GET, POST } = createSessionRoute({ … })`).
 */
export function createSessionRoute(options: SessionRouteOptions): { GET: (request: Request) => Promise<Response>; POST: (request: Request) => Promise<Response> } {
  const handler = (request: Request) => mint(options, request);
  return { GET: handler, POST: handler };
}

/** The route handler that answers the snapshot `source` loads, for `endpointUrl`: export it as GET from app/api/alpr/monitor/route.ts. */
export function createMonitorRoute(options: { source: MonitorDataSource; authorize?: (request: Request) => Promise<boolean> | boolean }): { GET: (request: Request) => Promise<Response> } {
  return {
    GET: async (request) => {
      if (options.authorize && !(await options.authorize(request))) {
        return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: NO_STORE });
      }
      try {
        const snapshot = await options.source.load(request.signal);
        return new Response(JSON.stringify(snapshot), { status: 200, headers: NO_STORE });
      } catch {
        return new Response(JSON.stringify({ error: "unavailable" }), { status: 503, headers: NO_STORE });
      }
    },
  };
}

/** The minimal shape of a Pages Router API request and response. */
interface PagesRequest {
  method?: string | undefined;
  headers: Record<string, string | string[] | undefined>;
}
interface PagesResponse {
  status(code: number): PagesResponse;
  setHeader(name: string, value: string): unknown;
  json(body: unknown): unknown;
}

/** The session route for the Pages Router (pages/api/alpr/session.ts): `export default createPagesSessionHandler({ … })`; personOf reads the Node request. */
export function createPagesSessionHandler(options: { client: PartnerClient; personOf: (request: PagesRequest) => Promise<string | null> | string | null }): (request: PagesRequest, response: PagesResponse) => Promise<void> {
  return async (request, response) => {
    response.setHeader("Cache-Control", "no-store");
    const person = await options.personOf(request);
    if (!person) {
      response.status(401).json({ error: "unauthorized" });
      return;
    }
    try {
      const session = await createWidgetSession(options.client, person);
      if (!session) {
        response.status(404).json({ error: "not_connected" });
        return;
      }
      response.status(200).json({ token: session.token, expiresAt: session.expiresAt });
    } catch {
      response.status(503).json({ error: "unavailable" });
    }
  };
}
