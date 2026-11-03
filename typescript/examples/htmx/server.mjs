// An Express server that answers the monitor's fragments to htmx.
// npm install express htmx.org && node server.mjs
import express from "express";

import { Alpr } from "@alpr-sh/sdk";
import { apiKeySource, expressHandler, monitorFragments, monitorStylesheet } from "@alpr-sh/sdk/htmx";

const alpr = new Alpr({ apiKey: process.env.ALPR_API_KEY });
const app = express();

app.get("/alpr/monitor", expressHandler(monitorFragments({ source: apiKeySource(alpr), path: "/alpr/monitor", authorize: (request) => request.headers.has("cookie") })));
app.get("/alpr/monitor.css", expressHandler(monitorStylesheet()));
app.use("/vendor/htmx.js", express.static("node_modules/htmx.org/dist/htmx.min.js"));
app.get("/", (_request, response) => response.sendFile(new URL("./page.html", import.meta.url).pathname));

app.listen(3000);
