# FloatBoard feedback service

Receives **Help › Send Feedback…** from the Mac app (docs/architecture.md, Edition 2, C10). Run by whoever builds and
hands out FloatBoard (the maintainer), not by each user. A small Cloudflare Worker with its own D1 database.

- Every message is **stored** first, then filed as an issue in a **private** GitHub repository (label `feedback`),
  and announced on your ntfy topic if you set one. GitHub also notifies you of each new issue (email and phone app).
- If GitHub can't be reached, the message stays stored and is retried on every new message, and hourly if your
  Cloudflare account has a free cron slot (the free plan allows 5 in all; remove `[triggers]` from your
  wrangler.local.toml if it has none). Three failures in a row send one ntfy alert.
- At most 5 messages a day per install, 5,000 characters each. Diagnostics come only when the person ticks
  "Include diagnostics" in the app, and never contain task or message text.

## Set up (once)

1. On GitHub, create a **private** repository, e.g. `floatboard-feedback`.
2. Create a **fine-grained token**: Settings › Developer settings › Fine-grained tokens › Generate. Repository access:
   only that repository. Permissions: **Issues: Read and write**. Copy it.
3. In this folder:
   ```
   npm install
   cp wrangler.local.toml.example wrangler.local.toml     # set GITHUB_REPO and the database id below
   npx wrangler d1 create floatboard-feedback              # copy the database_id into wrangler.local.toml
   npx wrangler d1 migrations apply floatboard-feedback --remote --config wrangler.local.toml
   npx wrangler secret put GITHUB_TOKEN --config wrangler.local.toml    # paste the token
   npx wrangler secret put NTFY_TOPIC --config wrangler.local.toml      # optional
   npx wrangler deploy --config wrangler.local.toml
   ```
4. Put the address it prints, plus `/feedback`, in the Mac app's build values (`mac/scripts/local.env`):
   `FEEDBACK_URL=https://floatboard-feedback.<you>.workers.dev/feedback`, then rebuild the app.

Tests: `npm test`.
