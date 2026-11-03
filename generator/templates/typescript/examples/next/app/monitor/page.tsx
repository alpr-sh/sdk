// A Server Component: it loads the cameras on the server and draws them; the
// browser then refreshes from /api/alpr/monitor.
import "@alpr-sh/sdk/monitor.css";

import { Alpr } from "@alpr-sh/sdk";
import { AlprMonitorServer, apiKeySource } from "@alpr-sh/sdk/next";

const alpr = new Alpr({ apiKey: process.env.ALPR_API_KEY! });

export default function Page() {
  return <AlprMonitorServer source={apiKeySource(alpr)} endpointUrl="/api/alpr/monitor" injectStyles={false} />;
}
