import { MonitorError, type MonitorDataSource, type MonitorSnapshot, type StatusFilter } from "./types.ts";
import { count, formatDateTime, formatRelative, statusLabel, statusOf, text, type StatusKey } from "./format.ts";

/** Everything the screen is made from. */
export interface MonitorState {
  /** idle before the first load, then loading, ready or error (a failed refresh keeps the last snapshot). */
  phase: "idle" | "loading" | "ready" | "error";
  /** True while a refresh is in flight. */
  refreshing: boolean;
  snapshot: MonitorSnapshot | null;
  error: MonitorError | null;
  filter: StatusFilter;
  query: string;
  /** When the snapshot arrived, in ms. */
  updatedAt: number | null;
}

export interface MonitorOptions {
  source: MonitorDataSource;
  /** Milliseconds between refreshes while started; 30 000 by default (the API keeps its answer for 30 s). 0 turns polling off. */
  refreshMs?: number;
  /** A snapshot already in hand, such as one loaded on the server. */
  initialSnapshot?: MonitorSnapshot | null;
  /** The clock; Date.now by default. */
  now?: () => number;
}

/** The monitor's logic without a framework: state, refresh, filter and search. */
export interface Monitor {
  getState(): MonitorState;
  /** Calls listener on every change; returns the way to stop. */
  watch(listener: (state: MonitorState) => void): () => void;
  /** A Svelte store: calls run with the state now and on every change. */
  subscribe(run: (state: MonitorState) => void): () => void;
  /** Loads again; a load in flight is cancelled. Never throws: a failure is in the state. */
  refresh(): Promise<void>;
  setFilter(filter: StatusFilter): void;
  setQuery(query: string): void;
  /** Loads now (unless an initial snapshot is fresh) and keeps refreshing. */
  start(): void;
  /** Stops refreshing and cancels what is in flight. */
  stop(): void;
}

export function createMonitor(options: MonitorOptions): Monitor {
  const now = options.now ?? Date.now;
  const refreshMs = options.refreshMs ?? 30_000;
  let state: MonitorState = {
    phase: options.initialSnapshot ? "ready" : "idle",
    refreshing: false,
    snapshot: options.initialSnapshot ?? null,
    error: null,
    filter: "all",
    query: "",
    updatedAt: options.initialSnapshot ? now() : null,
  };
  const listeners = new Set<(state: MonitorState) => void>();
  let timer: ReturnType<typeof setInterval> | undefined;
  let controller: AbortController | undefined;

  const set = (next: Partial<MonitorState>) => {
    state = { ...state, ...next };
    for (const listener of [...listeners]) {
      listener(state);
    }
  };

  const watch = (listener: (state: MonitorState) => void) => {
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
  };

  const refresh = async () => {
    controller?.abort();
    const mine = new AbortController();
    controller = mine;
    set({ refreshing: true, phase: state.snapshot ? state.phase : "loading" });
    try {
      const snapshot = await options.source.load(mine.signal);
      if (mine.signal.aborted) {
        return;
      }
      set({ snapshot, phase: "ready", error: null, refreshing: false, updatedAt: now() });
    } catch (error) {
      if (mine.signal.aborted) {
        return;
      }
      const failure = error instanceof MonitorError ? error : new MonitorError("network", text.networkError);
      // A failed refresh keeps the last snapshot on the screen, with the error beside it.
      set({ error: failure, phase: state.snapshot ? "ready" : "error", refreshing: false });
    }
  };

  return {
    getState: () => state,
    watch,
    subscribe(run) {
      run(state);
      return watch(run);
    },
    refresh,
    setFilter: (filter) => set({ filter }),
    setQuery: (query) => set({ query }),
    start() {
      if (timer !== undefined) {
        return;
      }
      void refresh();
      if (refreshMs > 0) {
        timer = setInterval(() => void refresh(), refreshMs);
      }
    },
    stop() {
      if (timer !== undefined) {
        clearInterval(timer);
        timer = undefined;
      }
      controller?.abort();
      controller = undefined;
      if (state.refreshing) {
        set({ refreshing: false });
      }
    },
  };
}

/** The totals of the summary cards. */
export interface MonitorSummary {
  total: number;
  online: number;
  offline: number;
  readsToday: number | null;
  readsMonth: number | null;
}

/** Totals over every camera, not only the ones the filter shows. */
export function summarize(snapshot: MonitorSnapshot | null): MonitorSummary | null {
  if (!snapshot) {
    return null;
  }
  const sum = (pick: (camera: MonitorSnapshot["cameras"][number]) => number | null) => {
    let known = false;
    let total = 0;
    for (const camera of snapshot.cameras) {
      const value = pick(camera);
      if (value !== null) {
        known = true;
        total += value;
      }
    }
    return known ? total : null;
  };
  const keys = snapshot.cameras.map((camera) => statusOf(camera, snapshot.engine));
  return {
    total: snapshot.cameras.length,
    online: keys.filter((key) => key === "online").length,
    offline: keys.filter((key) => key === "offline").length,
    readsToday: sum((camera) => camera.readsToday),
    readsMonth: sum((camera) => camera.readsMonth),
  };
}

/** The cameras the filter and the search leave. */
export function visibleCameras(state: Pick<MonitorState, "snapshot" | "filter" | "query">): MonitorSnapshot["cameras"] {
  const term = state.query.trim().toLowerCase();
  const engine = state.snapshot?.engine ?? "ok";
  return (state.snapshot?.cameras ?? []).filter((camera) => {
    const key = statusOf(camera, engine);
    if (state.filter === "online" && key !== "online") {
      return false;
    }
    if (state.filter === "offline" && key !== "offline") {
      return false;
    }
    return term === "" || camera.name.toLowerCase().includes(term);
  });
}

/** One row of the table, with every word it shows. */
export interface MonitorRow {
  id: string;
  name: string;
  statusKey: StatusKey;
  statusLabel: string;
  /** "Última leitura há 5 minutos" or "Ainda sem leitura", for the tooltip. */
  statusNote: string;
  readsToday: string;
  readsMonth: string;
  lastRead: string;
}

/** What a screen shows, ready to draw: the same for every framework. */
export interface MonitorView {
  phase: MonitorState["phase"];
  refreshing: boolean;
  cards: { key: string; label: string; value: string; note: string }[];
  engine: { ok: boolean; label: string; note: string } | null;
  rows: MonitorRow[];
  /** The text of the empty table, or null when there are rows. */
  empty: string | null;
  /** The message of a failed load, with where to renew if the subscription is inactive. */
  error: { message: string; renewUrl: string | undefined } | null;
  hasMore: boolean;
  filter: StatusFilter;
  query: string;
  filtered: boolean;
}

/** The view of a state at a time. */
export function monitorView(state: MonitorState, now: number = Date.now()): MonitorView {
  const summary = summarize(state.snapshot);
  const engineDown = state.snapshot?.engine === "unavailable";
  const rows = visibleCameras(state).map((camera): MonitorRow => {
    const key = statusOf(camera, state.snapshot?.engine ?? "ok");
    return {
      id: camera.id,
      name: camera.name,
      statusKey: key,
      statusLabel: statusLabel(key),
      statusNote: camera.lastReadAt ? `${text.lastRead} ${formatRelative(camera.lastReadAt, now)}` : text.noReadYet,
      readsToday: count(camera.readsToday),
      readsMonth: count(camera.readsMonth),
      lastRead: camera.lastReadAt ? formatDateTime(camera.lastReadAt) : text.never,
    };
  });
  const filtered = state.filter !== "all" || state.query.trim() !== "";
  return {
    phase: state.phase,
    refreshing: state.refreshing,
    cards: [
      { key: "total", label: text.total, value: count(summary?.total), note: text.totalNote },
      { key: "online", label: text.online, value: count(summary?.online), note: text.onlineNote },
      { key: "offline", label: text.offline, value: count(summary?.offline), note: text.offlineNote },
      { key: "reads", label: text.readsToday, value: count(summary?.readsToday), note: `${count(summary?.readsMonth)} ${text.readsMonth}` },
    ],
    engine: state.snapshot ? { ok: !engineDown, label: engineDown ? text.engineDown : text.engineOk, note: engineDown ? text.engineDownNote : "" } : state.error ? { ok: false, label: text.noAnswer, note: "" } : null,
    rows,
    empty: rows.length > 0 || state.phase === "loading" || state.phase === "idle" ? null : state.snapshot && state.snapshot.cameras.length === 0 ? text.noCameras : text.empty,
    error: state.error ? { message: state.error.message, renewUrl: state.error.renewUrl } : null,
    hasMore: state.snapshot?.hasMore ?? false,
    filter: state.filter,
    query: state.query,
    filtered,
  };
}
