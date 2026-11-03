// A SPA: the browser asks YOUR backend for the cameras (see ../next for the
// route that answers it); the API key stays on the server.
import { AlprMonitor, endpointSource } from "@alpr-sh/sdk/react";

const source = endpointSource("/api/alpr/monitor");

export default function App() {
  return <AlprMonitor source={source} refreshMs={30_000} theme="auto" />;
}
