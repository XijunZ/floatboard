import { defineConfig } from "vitest/config";

// A fixed, non-UTC test zone (no daylight saving) so page times are read the way a browser in that zone would.
process.env.TZ = "Asia/Tokyo";

export default defineConfig({
  test: { environment: "node", include: ["test/**/*.test.ts"] },
});
