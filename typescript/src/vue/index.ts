import { computed, defineComponent, Fragment, h as vueH, onMounted, onUnmounted, shallowRef, type ComputedRef, type PropType, type ShallowRef, type VNode } from "vue";

import { createMonitor, monitorCss, monitorTree, monitorView, type Actions, type H, type Monitor, type MonitorDataSource, type MonitorSnapshot, type MonitorState, type MonitorTheme, type MonitorView } from "../monitor/index.ts";

/** Builds Vue nodes from the screen's neutral tree: typing and choosing become onInput and onChange, and the value of a field is the DOM property. */
const h: H<VNode> = (tag, attrs, children, events) => {
  const props: Record<string, unknown> = {};
  for (const [name, value] of Object.entries(attrs)) {
    if (value !== undefined) {
      props[name] = value;
    }
  }
  if (events.input) {
    const input = events.input;
    props.onInput = (event: Event) => input((event.target as HTMLInputElement).value);
  }
  if (events.change) {
    const change = events.change;
    props.onChange = (event: Event) => change((event.target as HTMLSelectElement).value);
  }
  if (events.click) {
    props.onClick = events.click;
  }
  if (tag === "option") {
    delete props.selected;
  }
  return vueH(tag, props, children as (VNode | string)[]);
};

export interface UseMonitorOptions {
  source: MonitorDataSource;
  refreshMs?: number;
  initialSnapshot?: MonitorSnapshot | null;
}

/** The monitor's logic as a Vue composable: reactive state and view, and the actions; started when the component mounts and stopped when it unmounts. */
export function useMonitor(options: UseMonitorOptions): { monitor: Monitor; state: ShallowRef<MonitorState>; view: ComputedRef<MonitorView> } & Actions {
  const monitor = createMonitor(options);
  const state = shallowRef(monitor.getState());
  const stop = monitor.watch((next) => {
    state.value = next;
  });
  onMounted(() => monitor.start());
  onUnmounted(() => {
    stop();
    monitor.stop();
  });
  return { monitor, state, view: computed(() => monitorView(state.value)), setFilter: monitor.setFilter, setQuery: monitor.setQuery, refresh: () => void monitor.refresh() };
}

/**
 * The monitor screen as a Vue 3 component, written with render functions: no
 * Single File Component and no build plugin in your project.
 *
 *     <AlprMonitor :source="endpointSource('/api/alpr/monitor')" />
 */
export const AlprMonitor = defineComponent({
  name: "AlprMonitor",
  props: {
    source: { type: Object as PropType<MonitorDataSource>, required: true },
    refreshMs: { type: Number, default: 30_000 },
    initialSnapshot: { type: Object as PropType<MonitorSnapshot | null>, default: null },
    theme: { type: String as PropType<MonitorTheme>, default: "auto" },
    title: { type: String, default: "" },
    idPrefix: { type: String, default: "" },
    /** Writes the stylesheet in a <style> beside the screen. Turn it off when the page links @alpr-sh/sdk/monitor.css. */
    injectStyles: { type: Boolean, default: true },
    nonce: { type: String, default: "" },
  },
  setup(props) {
    const { view, setFilter, setQuery, refresh } = useMonitor({ source: props.source, refreshMs: props.refreshMs, initialSnapshot: props.initialSnapshot });
    return () => {
      const tree = monitorTree(view.value, { setFilter, setQuery, refresh }, h, { theme: props.theme, ...(props.title ? { title: props.title } : {}), ...(props.idPrefix ? { idPrefix: props.idPrefix } : {}) });
      return props.injectStyles ? vueH(Fragment, null, [vueH("style", props.nonce ? { nonce: props.nonce } : {}, monitorCss), tree]) : tree;
    };
  },
});

export { monitorCss };
export { endpointSource, staticSource, widgetSource, MonitorError } from "../monitor/index.ts";
export type { MonitorCamera, MonitorDataSource, MonitorSession, MonitorSnapshot, MonitorState, MonitorView } from "../monitor/index.ts";
