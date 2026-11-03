// GET /api/alpr/monitor: the snapshot, read with the workspace's API key.
import { Alpr } from "@alpr-sh/sdk";
import { apiKeySource, createMonitorRoute } from "@alpr-sh/sdk/next";

import { currentUserId } from "@/lib/auth"; // your own session

const alpr = new Alpr({ apiKey: process.env.ALPR_API_KEY! });

export const { GET } = createMonitorRoute({
  source: apiKeySource(alpr),
  authorize: async () => (await currentUserId()) !== null,
});
