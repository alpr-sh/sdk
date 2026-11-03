<script>
  import AlprMonitor from "@alpr-sh/sdk/svelte/AlprMonitor.svelte";
  import { endpointSource } from "@alpr-sh/sdk/svelte";
  import "@alpr-sh/sdk/monitor.css";

  const source = endpointSource("/api/alpr/monitor");
</script>

<AlprMonitor {source} refreshMs={30000} theme="auto" />
