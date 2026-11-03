"use client";

import { createElement, useMemo, type ReactElement } from "react";

import { endpointSource, widgetSource, type MonitorSession, type MonitorSnapshot, type MonitorTheme } from "../monitor/index.ts";
import { AlprMonitor } from "../react/index.ts";

export interface AlprMonitorLiveProps {
  /** What the server loaded, drawn at once; the browser refreshes it. */
  initialSnapshot?: MonitorSnapshot | null;
  /** Your route that answers the snapshot (the browser holds no key). */
  endpointUrl?: string;
  /** Your route that answers a short-lived session (createSessionRoute): the browser then reads Alpr.sh itself. */
  sessionUrl?: string;
  /** Alpr.sh's address, for sessionUrl; https://alpr.sh by default. */
  baseUrl?: string;
  refreshMs?: number;
  theme?: MonitorTheme;
  title?: string;
  injectStyles?: boolean;
  nonce?: string;
}

/**
 * The Client Component of the monitor: it refreshes on its own, from
 * `endpointUrl` or from Alpr.sh with the session `sessionUrl` hands out.
 * Props are plain data, so a Server Component can render it.
 */
export function AlprMonitorLive(props: AlprMonitorLiveProps): ReactElement {
  const { endpointUrl, sessionUrl, baseUrl, ...rest } = props;
  const source = useMemo(() => {
    if (sessionUrl) {
      return widgetSource({
        ...(baseUrl ? { baseUrl } : {}),
        getSession: async (): Promise<MonitorSession | null> => {
          const response = await fetch(sessionUrl, { method: "POST", credentials: "same-origin", cache: "no-store" });
          if (!response.ok) {
            return null;
          }
          const body = (await response.json()) as { token?: unknown; expiresAt?: unknown };
          return typeof body.token === "string" && typeof body.expiresAt === "number" ? { token: body.token, expiresAt: body.expiresAt } : null;
        },
      });
    }
    return endpointSource(endpointUrl ?? "/api/alpr/monitor");
  }, [endpointUrl, sessionUrl, baseUrl]);
  return createElement(AlprMonitor, { source, ...rest });
}
