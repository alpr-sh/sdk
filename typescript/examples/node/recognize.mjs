// node recognize.mjs foto.jpg
import { readFile } from "node:fs/promises";

import { Alpr } from "@alpr-sh/sdk";

const alpr = new Alpr({ apiKey: process.env.ALPR_API_KEY });

const result = await alpr.photos.recognize({ image: await readFile(process.argv[2]) });
for (const plate of result.plates) {
  console.log(plate.plate, plate.conf);
}

for await (const reading of alpr.recognitions.listIter({ plate: "BRA" })) {
  console.log(reading.capturedAt, reading.plate);
}
