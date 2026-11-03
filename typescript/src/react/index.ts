import { createElement, Fragment, useEffect, useMemo, useState, useSyncExternalStore, type ReactElement, type ReactNode } from "react";

import { createMonitor, monitorTree, monitorCss, monitorView, type Actions, type Events, type H, type Monitor, type MonitorOptions, type MonitorState, type MonitorView, type MonitorTheme } from "../monitor/index.ts";

/** Builds React elements from the screen's neutral tree: class and for become className and htmlFor, typing and choosing become onChange. */
const h: H<ReactElement> = (tag, attrs, children, events) => {
  const props: Record<string, unknown> = {};
  for (const [name, value] of Object.entries(attrs)) {
    if (value === undefined) {
      continue;
    }
    props[name === "class" ? "className" : name === "for" ? "htmlFor" : name === "colspan" ? "colSpan" : name === "tabindex" ? "tabIndex" : name === "autocomplete" ? "autoComplete" : name] = value;
  }
  const bound = events as Events;
  if (tag === "select") {
    props.onChange = (event: { target: { value: string } }) => bound.change?.(event.target.value);
  } else if (tag === "input") {
    props.onChange = (event: { target: { value: string } }) => bound.input?.(event.target.value);
  } else if (bound.click) {
    props.onClick = bound.click;
  }
  if (tag === "option") {
    delete props.selected;
  }
  return createElement(tag, props, ...(children as ReactNode[]));
};

/** The monitor's logic as a React hook: the state, the view and the actions, started and stopped with the component. */
export interface UseMonitor extends Actions {
  monitor: Monitor;
  state: MonitorState;
  view: MonitorView;
}

export function useMonitor(options: MonitorOptions): UseMonitor {
  // One monitor a component, made on the first render: the source is read from there.
  const [monitor] = useState(() => createMonitor(options));
  const state = useSyncExternalStore(
    (listener) => monitor.watch(listener),
    () => monitor.getState(),
    () => monitor.getState(),
  );
  useEffect(() => {
    monitor.start();
    return () => monitor.stop();
  }, [monitor]);
  const view = useMemo(() => monitorView(state), [state]);
  return { monitor, state, view, setFilter: monitor.setFilter, setQuery: monitor.setQuery, refresh: () => void monitor.refresh() };
}

export interface AlprMonitorProps extends MonitorOptions {
  theme?: MonitorTheme;
  title?: string;
  /** A prefix for the field ids, when two monitors share a page. */
  idPrefix?: string;
  /** Writes the stylesheet in a <style> beside the screen; true by default. Turn it off when the page links @alpr-sh/sdk/monitor.css (a strict CSP needs that or `nonce`). */
  injectStyles?: boolean;
  /** The CSP nonce of the <style>. */
  nonce?: string;
}

/**
 * The monitor screen: the cameras of the workspace, how many are online, the
 * readings of today and of the month, and a table with status, last reading,
 * filter and search. It reads from `source`, never with the workspace's API
 * key: use endpointSource (your backend) or widgetSource (a short-lived
 * session).
 */
export function AlprMonitor(props: AlprMonitorProps): ReactElement {
  const { theme, title, idPrefix, injectStyles = true, nonce, ...options } = props;
  const { view, setFilter, setQuery, refresh } = useMonitor(options);
  const tree = monitorTree(view, { setFilter, setQuery, refresh }, h, { ...(theme ? { theme } : {}), ...(title ? { title } : {}), ...(idPrefix ? { idPrefix } : {}) });
  if (!injectStyles) {
    return tree;
  }
  return createElement(Fragment, null, createElement("style", nonce ? { nonce } : null, monitorCss), tree);
}

export { monitorCss };
export type { MonitorOptions, MonitorState, MonitorView };
export { endpointSource, staticSource, widgetSource, MonitorError } from "../monitor/index.ts";
export type { MonitorCamera, MonitorDataSource, MonitorSession, MonitorSnapshot } from "../monitor/index.ts";
