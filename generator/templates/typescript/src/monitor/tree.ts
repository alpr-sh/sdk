import { text } from "./format.ts";
import type { MonitorView } from "./store.ts";
import type { MonitorTheme, StatusFilter } from "./types.ts";

/** An element's attributes: plain HTML names (class, for, aria-label, data-…). */
export type Attrs = Record<string, string | number | boolean | undefined>;

/** What a user can do on the screen; an adapter wires each to its framework's event. */
export interface Events {
  /** Typing in a text field: the value now. */
  input?: (value: string) => void;
  /** Choosing in a select: the value now. */
  change?: (value: string) => void;
  click?: () => void;
}

/** Builds one node of a framework: React's createElement, Vue's h, or a string. */
export type H<T> = (tag: string, attrs: Attrs, children: (T | string)[], events: Events) => T;

/** The actions of the screen. */
export interface Actions {
  setFilter(filter: StatusFilter): void;
  setQuery(query: string): void;
  refresh(): void;
}

/** The parts a caller may add attributes to (hx-get on the rows, for HTMX). */
export type Part = "root" | "summary" | "rows" | "search" | "status" | "refresh";

export interface TreeOptions {
  theme?: MonitorTheme;
  /** Prefixes the ids of the form fields, so two monitors can share a page. */
  idPrefix?: string;
  /** The title of the screen; "Monitor" by default. */
  title?: string;
  /** Attributes added to a part. */
  extra?: (part: Part) => Attrs;
}

const NONE: Events = {};

function node<T>(h: H<T>, options: TreeOptions, part: Part | undefined, tag: string, attrs: Attrs, children: (T | string)[], events: Events = NONE): T {
  return h(tag, part && options.extra ? { ...attrs, ...options.extra(part) } : attrs, children, events);
}

/** The four summary cards. */
export function summaryTree<T>(view: MonitorView, h: H<T>, options: TreeOptions = {}): T {
  return node(h, options, "summary", "section", { class: "alpr-monitor__summary", "aria-label": "Resumo" },
    view.cards.map((card) =>
      node(h, options, undefined, "div", { class: "alpr-monitor__card", "data-card": card.key }, [
        node(h, options, undefined, "p", { class: "alpr-monitor__card-label" }, [card.label]),
        node(h, options, undefined, "p", { class: "alpr-monitor__card-value" }, [card.value]),
        node(h, options, undefined, "p", { class: "alpr-monitor__card-note" }, [card.note]),
      ]),
    ),
  );
}

/** The rows of the table: one a camera, or the one row that says why there are none. */
export function rowsTree<T>(view: MonitorView, h: H<T>, options: TreeOptions = {}): T[] {
  if (view.rows.length === 0) {
    const loading = view.phase === "idle" || view.phase === "loading";
    const message = loading ? text.loading : (view.empty ?? text.empty);
    return [
      node(h, options, undefined, "tr", { class: "alpr-monitor__empty" }, [
        node(h, options, undefined, "td", { colspan: 4, ...(loading ? { "aria-live": "polite" } : {}) }, [message]),
      ]),
    ];
  }
  return view.rows.map((row) =>
    node(h, options, undefined, "tr", { "data-camera": row.id }, [
      node(h, options, undefined, "th", { scope: "row", class: "alpr-monitor__name" }, [row.name]),
      node(h, options, undefined, "td", {}, [
        node(h, options, undefined, "span", { class: `alpr-monitor__badge alpr-monitor__badge--${row.statusKey}`, title: row.statusNote }, [row.statusLabel]),
      ]),
      node(h, options, undefined, "td", { class: "alpr-monitor__reads" }, [
        node(h, options, undefined, "strong", {}, [row.readsToday]),
        ` ${text.today} · ${row.readsMonth} ${text.readsMonth}`,
      ]),
      node(h, options, undefined, "td", { class: "alpr-monitor__last" }, [row.lastRead]),
    ]),
  );
}

/** The whole screen: header, summary, filters and table. */
export function monitorTree<T>(view: MonitorView, actions: Actions, h: H<T>, options: TreeOptions = {}): T {
  const id = options.idPrefix ?? "alpr";
  const node_ = <A extends Part | undefined>(part: A, tag: string, attrs: Attrs, children: (T | string)[], events?: Events) => node(h, options, part, tag, attrs, children, events);
  const select = node_("status", "select", { id: `${id}-status`, name: "status", class: "alpr-monitor__input", value: view.filter }, [
    node_(undefined, "option", { value: "all", selected: view.filter === "all" }, [text.all]),
    node_(undefined, "option", { value: "online", selected: view.filter === "online" }, [text.online]),
    node_(undefined, "option", { value: "offline", selected: view.filter === "offline" }, [text.offline]),
  ], { change: (value) => actions.setFilter(value === "online" || value === "offline" ? value : "all") });
  const header: (T | string)[] = [
    node_(undefined, "div", {}, [
      node_(undefined, "h2", { class: "alpr-monitor__title" }, [options.title ?? text.title]),
      node_(undefined, "p", { class: "alpr-monitor__subtitle" }, [text.subtitle]),
      ...(view.engine
        ? [node_(undefined, "p", { class: `alpr-monitor__engine ${view.engine.ok ? "is-ok" : "is-down"}`, title: view.engine.note }, [
            node_(undefined, "span", { class: "alpr-monitor__dot", "aria-hidden": "true" }, []),
            view.engine.label,
          ])]
        : []),
    ]),
    node_("refresh", "button", { type: "button", class: "alpr-monitor__button", "aria-label": text.refresh, title: text.refresh, disabled: view.refreshing || undefined }, [text.refresh], { click: () => actions.refresh() }),
  ];
  const children: (T | string)[] = [node_(undefined, "header", { class: "alpr-monitor__header" }, header)];
  if (view.error) {
    children.push(node_(undefined, "div", { class: "alpr-monitor__alert", role: "alert" }, [
      view.error.message,
      ...(view.error.renewUrl ? [" ", node_(undefined, "a", { href: view.error.renewUrl, rel: "noopener noreferrer" }, [text.renew])] : []),
    ]));
  }
  children.push(
    summaryTree(view, h, options),
    node_(undefined, "div", { class: "alpr-monitor__toolbar" }, [
      node_(undefined, "div", { class: "alpr-monitor__field" }, [node_(undefined, "label", { for: `${id}-status` }, [text.statusFilter]), select]),
      node_(undefined, "div", { class: "alpr-monitor__field alpr-monitor__field--grow" }, [
        node_(undefined, "label", { for: `${id}-search`, class: "alpr-monitor__sr" }, [text.searchLabel]),
        node_("search", "input", { id: `${id}-search`, name: "q", type: "search", class: "alpr-monitor__input", placeholder: text.search, value: view.query, autocomplete: "off" }, [], { input: (value) => actions.setQuery(value) }),
      ]),
      ...(view.filtered
        ? [node_(undefined, "button", { type: "button", class: "alpr-monitor__button alpr-monitor__button--quiet" }, [text.clear], { click: () => { actions.setFilter("all"); actions.setQuery(""); } })]
        : []),
    ]),
    node_(undefined, "div", { class: "alpr-monitor__tablewrap", role: "region", "aria-label": text.cameras, tabindex: 0 }, [
      node_(undefined, "table", { class: "alpr-monitor__table" }, [
        node_(undefined, "caption", { class: "alpr-monitor__sr" }, [text.cameras]),
        node_(undefined, "thead", {}, [
          node_(undefined, "tr", {}, [
            node_(undefined, "th", { scope: "col" }, [text.name]),
            node_(undefined, "th", { scope: "col" }, [text.status]),
            node_(undefined, "th", { scope: "col" }, [text.reads]),
            node_(undefined, "th", { scope: "col" }, [text.lastRead]),
          ]),
        ]),
        node_("rows", "tbody", {}, rowsTree(view, h, options)),
      ]),
    ]),
  );
  if (view.hasMore) {
    children.push(node_(undefined, "p", { class: "alpr-monitor__note" }, [text.moreCameras]));
  }
  return node_("root", "div", { class: "alpr-monitor", "data-theme": options.theme ?? "auto", "aria-busy": view.refreshing || view.phase === "loading" ? "true" : "false" }, children);
}
