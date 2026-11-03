<script setup lang="ts">
import { AlprMonitor, endpointSource } from "@alpr-sh/sdk/vue";

const source = endpointSource("/api/alpr/monitor");
</script>

<template>
  <AlprMonitor :source="source" :refresh-ms="30000" theme="auto" />
</template>
