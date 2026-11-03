<!--
  The monitor screen as a Svelte component, in the syntax that Svelte 4 and 5
  both compile. Its stylesheet is not here: import "@alpr-sh/sdk/monitor.css"
  once (it keeps a strict CSP happy). It reads from `source`, never with the
  workspace's API key: use endpointSource (your backend) or widgetSource (a
  short-lived session).

    <script>
      import AlprMonitor from "@alpr-sh/sdk/svelte/AlprMonitor.svelte";
      import { endpointSource } from "@alpr-sh/sdk/svelte";
      import "@alpr-sh/sdk/monitor.css";
    </script>
    <AlprMonitor source={endpointSource("/api/alpr/monitor")} />
-->
<script>
  import { onDestroy, onMount } from "svelte";
  import { createMonitor, monitorView, text } from "../monitor/index.js";

  /** @type {import("../monitor/index.js").MonitorDataSource} */
  export let source;
  export let refreshMs = 30000;
  /** @type {import("../monitor/index.js").MonitorSnapshot | null} */
  export let initialSnapshot = null;
  /** @type {"auto" | "light" | "dark"} */
  export let theme = "auto";
  export let title = "";
  /** A prefix for the field ids, when two monitors share a page. */
  export let idPrefix = "alpr";

  const monitor = createMonitor({ source, refreshMs, initialSnapshot });
  let state = monitor.getState();
  const unwatch = monitor.watch((next) => {
    state = next;
  });
  onMount(() => monitor.start());
  onDestroy(() => {
    unwatch();
    monitor.stop();
  });

  $: view = monitorView(state);
  const choose = (event) => monitor.setFilter(event.currentTarget.value === "online" || event.currentTarget.value === "offline" ? event.currentTarget.value : "all");
  const search = (event) => monitor.setQuery(event.currentTarget.value);
  const clear = () => {
    monitor.setFilter("all");
    monitor.setQuery("");
  };
</script>

<div class="alpr-monitor" data-theme={theme} aria-busy={view.refreshing || view.phase === "loading" ? "true" : "false"}>
  <header class="alpr-monitor__header">
    <div>
      <h2 class="alpr-monitor__title">{title || text.title}</h2>
      <p class="alpr-monitor__subtitle">{text.subtitle}</p>
      {#if view.engine}
        <p class="alpr-monitor__engine {view.engine.ok ? 'is-ok' : 'is-down'}" title={view.engine.note}>
          <span class="alpr-monitor__dot" aria-hidden="true"></span>{view.engine.label}
        </p>
      {/if}
    </div>
    <button type="button" class="alpr-monitor__button" aria-label={text.refresh} title={text.refresh} disabled={view.refreshing} on:click={() => monitor.refresh()}>{text.refresh}</button>
  </header>
  {#if view.error}
    <div class="alpr-monitor__alert" role="alert">
      {view.error.message}
      {#if view.error.renewUrl}
        <a href={view.error.renewUrl} rel="noopener noreferrer">{text.renew}</a>
      {/if}
    </div>
  {/if}
  <section class="alpr-monitor__summary" aria-label="Resumo">
    {#each view.cards as card (card.key)}
      <div class="alpr-monitor__card" data-card={card.key}>
        <p class="alpr-monitor__card-label">{card.label}</p>
        <p class="alpr-monitor__card-value">{card.value}</p>
        <p class="alpr-monitor__card-note">{card.note}</p>
      </div>
    {/each}
  </section>
  <div class="alpr-monitor__toolbar">
    <div class="alpr-monitor__field">
      <label for="{idPrefix}-status">{text.statusFilter}</label>
      <select id="{idPrefix}-status" name="status" class="alpr-monitor__input" value={view.filter} on:change={choose}>
        <option value="all" selected={view.filter === "all"}>{text.all}</option>
        <option value="online" selected={view.filter === "online"}>{text.online}</option>
        <option value="offline" selected={view.filter === "offline"}>{text.offline}</option>
      </select>
    </div>
    <div class="alpr-monitor__field alpr-monitor__field--grow">
      <label for="{idPrefix}-search" class="alpr-monitor__sr">{text.searchLabel}</label>
      <input id="{idPrefix}-search" name="q" type="search" class="alpr-monitor__input" placeholder={text.search} value={view.query} autocomplete="off" on:input={search} />
    </div>
    {#if view.filtered}
      <button type="button" class="alpr-monitor__button alpr-monitor__button--quiet" on:click={clear}>{text.clear}</button>
    {/if}
  </div>
  <div class="alpr-monitor__tablewrap" role="region" aria-label={text.cameras} tabindex="0">
    <table class="alpr-monitor__table">
      <caption class="alpr-monitor__sr">{text.cameras}</caption>
      <thead>
        <tr>
          <th scope="col">{text.name}</th>
          <th scope="col">{text.status}</th>
          <th scope="col">{text.reads}</th>
          <th scope="col">{text.lastRead}</th>
        </tr>
      </thead>
      <tbody>
        {#each view.rows as row (row.id)}
          <tr data-camera={row.id}>
            <th scope="row" class="alpr-monitor__name">{row.name}</th>
            <td><span class="alpr-monitor__badge alpr-monitor__badge--{row.statusKey}" title={row.statusNote}>{row.statusLabel}</span></td>
            <td class="alpr-monitor__reads"><strong>{row.readsToday}</strong> {text.today} · {row.readsMonth} {text.readsMonth}</td>
            <td class="alpr-monitor__last">{row.lastRead}</td>
          </tr>
        {:else}
          <tr class="alpr-monitor__empty">
            <td colspan="4" aria-live={view.phase === "idle" || view.phase === "loading" ? "polite" : undefined}>{view.phase === "idle" || view.phase === "loading" ? text.loading : (view.empty ?? text.empty)}</td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
  {#if view.hasMore}
    <p class="alpr-monitor__note">{text.moreCameras}</p>
  {/if}
</div>
