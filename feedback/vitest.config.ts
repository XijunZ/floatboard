import { defineConfig } from "vitest/config";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";

export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: { bindings: { TEST_MIGRATIONS: migrations, GITHUB_TOKEN: "gh-test-token", NTFY_TOPIC: "fb-test-topic" } },
      }),
    ],
    test: { setupFiles: ["./test/vitest-setup.ts"] },
  };
});
