import { monitorTree, monitorView, rowsTree, summaryTree, type Attrs, type H, type MonitorSnapshot, type MonitorState, type Part, type StatusFilter, type MonitorTheme, MonitorError } from "../monitor/index.ts";

/** HTML already escaped: what the string renderer's nodes are. */
export interface Html {
  readonly html: string;
}

const ESCAPES: Record<string, string> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

/** Escapes text for an HTML body or a double-quoted attribute. */
export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ESCAPES[char] ?? char);
}

const VOID = new Set(["input", "br", "hr", "img"]);

/** Builds escaped HTML from the screen's neutral tree. Text children are escaped; nodes are not. No inline style, no inline script, no event attribute. */
export const htmlOf: H<Html> = (tag, attrs, children) => {
  let open = `<${tag}`;
  for (const [name, value] of Object.entries(attrs)) {
    if (value === undefined || value === false) {
      continue;
    }
    // The value of a select is carried by the selected option.
    if (tag === "select" && name === "value") {
      continue;
    }
    open += value === true ? ` ${name}` : ` ${name}="${escapeHtml(String(value))}"`;
  }
  if (VOID.has(tag)) {
    return { html: `${open}>` };
  }
  return { html: `${open}>${children.map((child) => (typeof child === "string" ? escapeHtml(child) : child.html)).join("")}</${tag}>` };
};

export interface FragmentOptions {
  /** Where the fragments are served: the route that monitorFragments answers. */
  path: string;
  /** Seconds between the automatic refreshes the markup asks htmx for; 10 by default. 0 turns them off. */
  refreshSeconds?: number;
  theme?: MonitorTheme;
  /** Prefixes the ids, when two monitors share a page; "alpr" by default. */
  idPrefix?: string;
  /** The title of the screen. */
  title?: string;
  /** The clock in ms, for the relative times; Date.now by default. */
  now?: number;
}

/** What a fragment draws: a snapshot, or a whole state (with an error, a filter, a query). */
export type FragmentInput = MonitorSnapshot | MonitorState;

function stateOf(input: FragmentInput, filter?: StatusFilter, query?: string): MonitorState {
  const base: MonitorState = "phase" in input ? input : { phase: "ready", refreshing: false, snapshot: input, error: null, filter: "all", query: "", updatedAt: null };
  return { ...base, filter: filter ?? base.filter, query: query ?? base.query };
}

/** hx-get and friends for each part: the markup is the whole script, and the browser needs no JavaScript of yours. */
function hxFor(options: FragmentOptions): (part: Part) => Attrs {
  const id = options.idPrefix ?? "alpr";
  const every = options.refreshSeconds ?? 10;
  const url = (part: string) => `${options.path}${options.path.includes("?") ? "&" : "?"}part=${part}`;
  const includes = `#${id}-status, #${id}-search`;
  return (part) => {
    switch (part) {
      case "root":
        return { id: `${id}-monitor` };
      case "summary":
        return { id: `${id}-summary`, "hx-get": url("summary"), "hx-swap": "outerHTML", ...(every > 0 ? { "hx-trigger": `every ${every}s` } : {}) };
      case "rows":
        return { id: `${id}-rows`, "hx-get": url("rows"), "hx-include": includes, "hx-swap": "innerHTML", ...(every > 0 ? { "hx-trigger": `every ${every}s` } : {}) };
      case "search":
        return { "hx-get": url("rows"), "hx-trigger": "input changed delay:300ms, search", "hx-target": `#${id}-rows`, "hx-include": `#${id}-status`, "hx-swap": "innerHTML" };
      case "status":
        return { "hx-get": url("rows"), "hx-trigger": "change", "hx-target": `#${id}-rows`, "hx-include": `#${id}-search`, "hx-swap": "innerHTML" };
      case "refresh":
        return { "hx-get": url("all"), "hx-target": `#${id}-monitor`, "hx-include": includes, "hx-swap": "outerHTML" };
    }
  };
}

const noActions = { setFilter() {}, setQuery() {}, refresh() {} };

/** The whole monitor screen as HTML, with the hx-* attributes that keep it fresh. Drop it in a page, or answer it to hx-get. */
export function renderMonitor(input: FragmentInput, options: FragmentOptions, filter?: StatusFilter, query?: string): string {
  const view = monitorView(stateOf(input, filter, query), options.now ?? Date.now());
  const tree = { extra: hxFor(options), ...(options.theme ? { theme: options.theme } : {}), ...(options.idPrefix ? { idPrefix: options.idPrefix } : {}), ...(options.title ? { title: options.title } : {}) };
  return monitorTree(view, noActions, htmlOf, tree).html;
}

/** The four summary cards as HTML; the section refreshes itself. */
export function renderSummary(input: FragmentInput, options: FragmentOptions): string {
  const view = monitorView(stateOf(input), options.now ?? Date.now());
  return summaryTree(view, htmlOf, { extra: hxFor(options) }).html;
}

/** The rows of the table as HTML (`<tr>` elements), filtered and searched as asked: what the rows part answers. */
export function renderCameraRows(input: FragmentInput, options: Pick<FragmentOptions, "now">, filter?: StatusFilter, query?: string): string {
  const view = monitorView(stateOf(input, filter, query), options.now ?? Date.now());
  return rowsTree(view, htmlOf).map((row) => row.html).join("");
}

/** A state for a load that failed, to draw the error instead of the cameras. */
export function failedState(error: unknown): MonitorState {
  return { phase: "error", refreshing: false, snapshot: null, error: error instanceof MonitorError ? error : new MonitorError("unavailable", "O Alpr.sh não respondeu agora. Tente de novo."), filter: "all", query: "", updatedAt: null };
}
