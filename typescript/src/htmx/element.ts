import { createMonitor, endpointSource, monitorCss, monitorTree, monitorView, widgetSource, type Monitor, type MonitorDataSource, type MonitorSession, type MonitorTheme, type Part } from "../monitor/index.ts";
import { htmlOf } from "./html.ts";

/**
 * Registers the `<alpr-monitor>` custom element, which serves any framework
 * and plain HTML. Nothing runs on import: the call is yours, and it does
 * nothing on a server (no DOM there).
 *
 *     <alpr-monitor src="/api/alpr/monitor" refresh="30"></alpr-monitor>
 *     <alpr-monitor session-url="/api/alpr/session"></alpr-monitor>
 *
 * Attributes: `src` (your route that answers the snapshot), `session-url`
 * (your route that answers a short-lived session; the element then reads
 * Alpr.sh itself), `base-url` (Alpr.sh's address), `refresh` (seconds, 30 by
 * default, 0 for never), `theme` (auto, light or dark). The `source`
 * property sets the data source from code. The key never reaches the page.
 * The stylesheet is adopted by the element's shadow root (allowed by a
 * strict CSP); there is no inline style or script.
 */
export function defineAlprMonitor(tagName = "alpr-monitor"): void {
  const registry = (globalThis as { customElements?: CustomElementRegistry }).customElements;
  const Base = (globalThis as { HTMLElement?: typeof HTMLElement }).HTMLElement;
  if (!registry || !Base || registry.get(tagName)) {
    return;
  }

  const PARTS: Record<Part, string> = { root: "root", summary: "summary", rows: "rows", search: "search", status: "status", refresh: "refresh" };

  class AlprMonitorElement extends Base {
    static observedAttributes = ["src", "session-url", "base-url", "refresh", "theme"];

    /** Set from code to read from somewhere else than `src` or `session-url`. */
    source: MonitorDataSource | undefined;
    #monitor: Monitor | undefined;
    #unwatch: (() => void) | undefined;
    #shadow: ShadowRoot | undefined;
    #sheet: CSSStyleSheet | undefined;

    connectedCallback(): void {
      this.#shadow ??= this.attachShadow({ mode: "open" });
      this.#adoptStyles();
      this.#shadow.addEventListener("input", this.#onInput);
      this.#shadow.addEventListener("change", this.#onChange);
      this.#shadow.addEventListener("click", this.#onClick);
      this.#start();
    }

    disconnectedCallback(): void {
      this.#stop();
      this.#shadow?.removeEventListener("input", this.#onInput);
      this.#shadow?.removeEventListener("change", this.#onChange);
      this.#shadow?.removeEventListener("click", this.#onClick);
    }

    attributeChangedCallback(): void {
      if (this.isConnected && this.#monitor) {
        this.#stop();
        this.#start();
      }
    }

    #adoptStyles(): void {
      const shadow = this.#shadow;
      if (!shadow || shadow.querySelector("style")) {
        return;
      }
      const Sheet = (globalThis as { CSSStyleSheet?: typeof CSSStyleSheet }).CSSStyleSheet;
      if (Sheet && "adoptedStyleSheets" in shadow) {
        try {
          this.#sheet = new Sheet();
          this.#sheet.replaceSync(monitorCss);
          (shadow as ShadowRoot & { adoptedStyleSheets: CSSStyleSheet[] }).adoptedStyleSheets = [this.#sheet];
          return;
        } catch {
          // Fall back to a <style> element below.
        }
      }
      const style = this.ownerDocument.createElement("style");
      style.textContent = monitorCss;
      shadow.append(style);
    }

    #sourceNow(): MonitorDataSource {
      if (this.source) {
        return this.source;
      }
      const sessionUrl = this.getAttribute("session-url");
      if (sessionUrl) {
        const baseUrl = this.getAttribute("base-url");
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
      return endpointSource(this.getAttribute("src") ?? "/api/alpr/monitor");
    }

    #start(): void {
      const seconds = Number(this.getAttribute("refresh") ?? "30");
      const monitor = createMonitor({ source: this.#sourceNow(), refreshMs: Number.isFinite(seconds) && seconds >= 0 ? seconds * 1000 : 30_000 });
      this.#monitor = monitor;
      this.#unwatch = monitor.watch(() => this.#render());
      this.#render();
      monitor.start();
    }

    #stop(): void {
      this.#unwatch?.();
      this.#monitor?.stop();
      this.#monitor = undefined;
    }

    /** Draws the whole screen again; the field in use keeps its focus and its cursor. */
    #render(): void {
      const shadow = this.#shadow;
      const monitor = this.#monitor;
      if (!shadow || !monitor) {
        return;
      }
      const active = shadow.activeElement as (HTMLInputElement | HTMLSelectElement) | null;
      const focus = active?.id ? { id: active.id, start: "selectionStart" in active ? active.selectionStart : null, end: "selectionEnd" in active ? active.selectionEnd : null } : undefined;
      const theme = (this.getAttribute("theme") as MonitorTheme | null) ?? "auto";
      const tree = monitorTree(monitorView(monitor.getState()), monitor, htmlOf, { theme: theme === "light" || theme === "dark" ? theme : "auto", extra: (part) => ({ "data-part": PARTS[part] }) });
      let holder = shadow.querySelector("[data-root]");
      if (!holder) {
        holder = this.ownerDocument.createElement("div");
        holder.setAttribute("data-root", "");
        shadow.append(holder);
      }
      holder.innerHTML = tree.html;
      if (focus) {
        const again = shadow.getElementById(focus.id) as HTMLInputElement | null;
        again?.focus();
        if (again && focus.start !== null && focus.end !== null && typeof again.setSelectionRange === "function") {
          try {
            again.setSelectionRange(focus.start, focus.end);
          } catch {
            // A select has no selection to restore.
          }
        }
      }
    }

    #part(event: Event): HTMLElement | null {
      return (event.target as HTMLElement | null)?.closest?.("[data-part]") ?? null;
    }

    #onInput = (event: Event): void => {
      if (this.#part(event)?.getAttribute("data-part") === "search") {
        this.#monitor?.setQuery((event.target as HTMLInputElement).value);
      }
    };

    #onChange = (event: Event): void => {
      if (this.#part(event)?.getAttribute("data-part") === "status") {
        const value = (event.target as HTMLSelectElement).value;
        this.#monitor?.setFilter(value === "online" || value === "offline" ? value : "all");
      }
    };

    #onClick = (event: Event): void => {
      const button = (event.target as HTMLElement | null)?.closest?.("button");
      if (!button) {
        return;
      }
      if (button.getAttribute("data-part") === "refresh") {
        void this.#monitor?.refresh();
      } else if (button.className.includes("alpr-monitor__button--quiet")) {
        this.#monitor?.setFilter("all");
        this.#monitor?.setQuery("");
      }
    };
  }

  registry.define(tagName, AlprMonitorElement);
}
