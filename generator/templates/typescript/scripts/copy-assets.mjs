// Writes what tsc does not compile into dist: the stylesheet, and the Svelte
// component, which the consumer's Svelte compiler builds.
import { cpSync, writeFileSync } from "node:fs";

const { monitorCss } = await import(new URL("../dist/monitor/styles.js", import.meta.url).href);
writeFileSync(new URL("../dist/monitor.css", import.meta.url), monitorCss);
cpSync(new URL("../src/svelte/AlprMonitor.svelte", import.meta.url), new URL("../dist/svelte/AlprMonitor.svelte", import.meta.url));
