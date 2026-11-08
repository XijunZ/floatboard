import { readFileSync } from "node:fs";
import { defineConfig } from "vitest/config";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";

export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            // The documented data model (docs/data-model.md), checked against the migrations by test/data-model.test.ts.
            DATA_MODEL_DOC: readFileSync(new URL("../../docs/data-model.md", import.meta.url), "utf8"),
            // Test-only secrets.
            ENC_KEY: "dGVzdC1rZXktdGVzdC1rZXktdGVzdC1rZXktMzJieXQ=",
            ADMIN_KEY: "admin-test-key",
            TELEGRAM_BOT_TOKEN: "123:test-token",
            TELEGRAM_BOT_NAME: "FloatBoardTestBot",
            TELEGRAM_WEBHOOK_SECRET: "tg-secret",
          },
        },
      }),
    ],
    test: { setupFiles: ["./test/setup.ts"] },
  };
});
