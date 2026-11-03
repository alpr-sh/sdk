/** The state of one camera on the monitor screen. */
export interface MonitorCamera {
  id: string;
  name: string;
  /** False when the camera is switched off in the panel. */
  enabled: boolean;
  /** True when the camera is on and reading; null when the API does not say. */
  online: boolean | null;
  /** What the reading service says: running, waiting, disabled, offline, expired… */
  status: string;
  /** RFC 3339, or null when the camera never read. */
  lastReadAt: string | null;
  readsToday: number | null;
  readsMonth: number | null;
}

/** What the monitor draws: the cameras, and whether the reading service answered. */
export interface MonitorSnapshot {
  cameras: MonitorCamera[];
  /** "unavailable" means the status of the cameras may be out of date. */
  engine: "ok" | "unavailable";
  /** True when there may be cameras beyond the ones listed. */
  hasMore: boolean;
}

/** Where the monitor's data comes from. The browser never holds the workspace's API key: a source asks the integrator's backend, or Alpr.sh with a short-lived session. */
export interface MonitorDataSource {
  load(signal?: AbortSignal): Promise<MonitorSnapshot>;
}

/** Why a load failed. */
export type MonitorErrorKind = "network" | "unauthorized" | "subscription" | "unavailable";

/** A failed load, with a message in Portuguese for the screen. */
export class MonitorError extends Error {
  readonly kind: MonitorErrorKind;
  /** Where to renew, when the subscription is inactive. */
  readonly renewUrl: string | undefined;

  constructor(kind: MonitorErrorKind, message: string, renewUrl?: string) {
    super(message);
    this.name = "MonitorError";
    this.kind = kind;
    this.renewUrl = renewUrl;
  }
}

/** The status filter of the table. */
export type StatusFilter = "all" | "online" | "offline";

/** A short-lived session the monitor reads Alpr.sh with. */
export interface MonitorSession {
  token: string;
  /** Unix seconds. */
  expiresAt: number;
}

export type MonitorTheme = "auto" | "light" | "dark";
