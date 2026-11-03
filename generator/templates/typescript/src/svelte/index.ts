import { createMonitor, type Monitor, type MonitorOptions, type MonitorState } from "../monitor/index.ts";

/**
 * The monitor as a Svelte store: `$monitor` is the state, and `monitor.start()`
 * and `monitor.stop()` run from onMount and onDestroy. It follows the store
 * contract (`subscribe` calls back at once and on every change), so it works
 * the same in Svelte 4 and 5.
 */
export function monitorStore(options: MonitorOptions): Monitor {
  return createMonitor(options);
}

export type { Monitor, MonitorState };
export { createMonitor, monitorCss, monitorView, endpointSource, staticSource, widgetSource, MonitorError } from "../monitor/index.ts";
export type { MonitorCamera, MonitorDataSource, MonitorOptions, MonitorSession, MonitorSnapshot, MonitorView } from "../monitor/index.ts";
