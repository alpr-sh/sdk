// POST /api/alpr/session: a short-lived Alpr.sh session for the signed-in
// person. The partner's secret stays here.
import { createSessionRoute } from "@alpr-sh/sdk/next";

import { currentUserId } from "@/lib/auth"; // your own session

export const { GET, POST } = createSessionRoute({
  client: { clientId: process.env.ALPR_CLIENT_ID!, clientSecret: process.env.ALPR_CLIENT_SECRET! },
  personOf: async () => (await currentUserId()) ?? null,
});
