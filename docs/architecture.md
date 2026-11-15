# FloatBoard architecture

This page is the architecture of record. **Edition 1** is what is built today (7 to 14 Nov 2026). **Edition 2** is a
change to it (15 Nov 2026): it lists what changes, what stays, and why. **Phase 1 is built** (Settings sections,
instruction history, keys in the Keychain, feedback); the later phases are not yet.

---

## Edition 1: as built

**Principle:** the Mac app is deterministic and is the truth; the online engine is probabilistic and only proposes.

```
 Gmail, Fathom, Outlook (extension), WhatsApp (read on the Mac)
                         │
                         ▼
 ┌──────────── engine (Cloudflare Worker + D1, the user's own account) ────────────┐
 │ filter → one Claude call per batch (Haiku) → proposals; recaps; reply drafts      │
 │ (Sonnet); learning every 50 corrections; due/Watch alerts; phone app; /setup page │
 └──────────────────────────────────────────────────────────────────────────────────┘
          ▲ events (outbox, idempotent)            │ proposals (idempotent, by source key)
          │                                        ▼
 ┌──────────────────────── Mac app (board.sqlite = the truth) ──────────────────────┐
 │ board, bar, groups, history, outbox, Activity log, health watchdog, backups,      │
 │ Watch timers, local due/chase notifications, Google Calendar                      │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

What Edition 1 established, and Edition 2 keeps:

- The board lives only on the Mac (`board.sqlite`). The app is fully useful with no engine, network or accounts.
- Every crossing between the app and the engine is durable: changes go through the outbox, proposals and events are
  idempotent, and both sides tolerate being offline for days.
- No silent failures: every error is logged, visible in Activity, and retried when retrying can work. A watchdog
  treats silence (no successful run, a stuck outbox, an old backup) as a failure.
- Every correction is kept forever on the Mac; learned preferences can be rebuilt from them.
- Re-check never deletes; tiered local backups; a backup before every migration.
- The settings the user writes (rules, group notes, lists) are owned by the app and copied to the engine with a
  version number.

What Edition 1 got in the way of:

1. **Screening needs a server.** Without the engine there is no AI screening at all, so "Mac only" means "board
   only".
2. **One hosting choice, many manual steps.** Cloudflare only, about 12 terminal and console steps, plus a 6-screen
   Google Cloud setup.
3. **Settings are split by where code runs, not by what the user wants.** Secrets are on the engine's web page,
   rules are in the app, outputs (phone alerts, drafts, calendar) are scattered.
4. **Learning is invisible.** The learned preferences are one text field that is overwritten each time; there is no
   record of what changed or why.

---

## Edition 2: proposed changes

### The product in one picture

The Mac app is the core. Everything else is an optional ring around it, and every choice is made in one Settings
window.

```
                 ┌──────────────────────── Settings ────────────────────────┐
                 │  Mode · Inputs · Outputs · Rules & learning · Keys        │
                 └───────────────────────────────────────────────────────────┘

   INPUTS                      SCREENING                         OUTPUTS
   Gmail ──────┐        filter → AI judge → proposals      ┌── Board (always)
   WhatsApp ───┤        runs on the Mac (Mac only)    ─────┼── Phone alerts
   Fathom ─────┤        or online (Always on)              ├── Reply drafts
   Outlook ────┘        same code, same rules file         ├── Calendar events
                                                           └── Phone app (Always on)
```

### Changes at a glance

| # | Area | Edition 1 | Edition 2 |
|---|---|---|---|
| C1 | Mode | Engine optional, but no screening without it | Choose **Mac only** or **Always on**; screening works in both |
| C2 | Where screening runs | Engine only | One screening module, run on the Mac or online |
| C3 | Online services | Cloudflare | Cloudflare, Vercel, Supabase behind one platform layer |
| C4 | Online setup | ~12 terminal steps | One step per platform plus a picture guide |
| C5 | Inputs | Set up in different places | One **Connect** button each, with a picture guide |
| C6 | Outputs | Scattered | Their own section, each one a switch |
| C7 | AI model | Fixed (Haiku to judge, Sonnet for drafts) | The user picks per job, with an estimated monthly cost |
| C8 | Learning | One overwritten text field | A readable instructions file with a dated change log |
| C9 | Keys | Engine web page plus a credentials file | One Keys section, stored in the macOS Keychain |
| C10 | Feedback | None | **Send feedback** in the Help menu, previewed, collected centrally |
| C11 | Phone app | Pages written as strings inside the engine | Plain web files in their own folder, served by the online service |

### Principles: kept and changed

| Edition 1 | Edition 2 | Why |
|---|---|---|
| The app makes no AI calls (anti-goal) | **The board core makes no AI calls.** The screening module may run inside the app, but it reaches the board only through the same proposal and outbox contract an online engine uses | Mac-only screening is impossible otherwise. Keeping the contract means the core stays deterministic and testable, and the screening module is replaceable |
| Secrets are entered on the engine's page and never stored on the Mac | **Keys live on the Mac (Keychain).** In Always on mode the Mac sends the online service the keys it needs, encrypted | One place for the user; Mac-only mode needs them on the Mac anyway |
| Settings the user writes are owned by the app | Kept, and extended to the instructions file and its history | |
| Board truth on the Mac, outbox, idempotency, no silent failures, backups, re-check | Kept unchanged | |

---

### C1. Mode: Mac only or Always on

The first section of Settings. One choice, changeable later without losing anything.

| | **Mac only** | **Always on** |
|---|---|---|
| Screening runs | On the Mac, while it is on and online | On the user's online service, every 5 minutes |
| Needs | A Claude key (or the on-device model, C7) | An online service account (C3) and a Claude key |
| Board data | On the Mac | On the Mac (the service keeps only its inbox and the phone's copy) |
| Phone app | Not available (a phone cannot reach a sleeping laptop) | Available |
| Cost | Pennies of Claude usage | The same, plus the online service (free on Cloudflare and Supabase) |

Switching from Mac only to Always on carries over the instructions file, corrections and cursors (how far each
input has been read). Switching back stops the online service from reading; nothing on the Mac is lost.

### C2. One screening module, two places to run

The engine's screening code (sources, filter, the AI call, recaps, learning, drafts) becomes one module written once
in TypeScript, with no platform code inside it. It needs five things from whoever runs it: a database, a scheduler
tick, outgoing HTTP, the keys, and a clock.

- **Online:** a platform adapter (C3) provides them.
- **On the Mac:** the app runs the same bundle in macOS's built-in JavaScript engine (JavaScriptCore). A small Swift
  host provides a local SQLite database (a separate file, `screening.sqlite`, never the board), HTTP through the
  app's network layer, keys from the Keychain, and a tick every 5 minutes while the Mac is awake. The module hands
  proposals to the board through the same reconciler an online engine's proposals go through.

Why not rewrite it in Swift: two copies of the same logic drift apart. One module means one rulebook, one set of
tests, and identical judgements in both modes.

Inputs by mode:

| Input | Mac only | Always on | Note |
|---|---|---|---|
| Gmail | Yes | Yes | The Mac signs in with the same Google client (C9) |
| WhatsApp | Yes | Yes | Read on the Mac in both modes, as today |
| Fathom | Yes, by asking Fathom's API for new meetings (the existing hourly catch-up, run on each tick) | Yes, webhook plus catch-up | |
| Outlook (extension) | No at first | Yes | The extension runs on a work laptop that may not have FloatBoard |

### C3. Online services: Cloudflare, Vercel, Supabase

A platform layer provides the five things in C2 for each service. The screening module does not know which one it
is on.

| Service | Runs on a schedule | Database | Free plan |
|---|---|---|---|
| **Cloudflare** (Workers + D1) | Every 5 min | D1 (SQLite) | Enough for 24/7 |
| **Vercel** (Functions + Neon Postgres from the Vercel Marketplace) | Every 5 min on Pro; **once a day on Hobby** | Postgres | Hobby is not enough for 24/7: setup says so and offers Pro or another service |
| **Supabase** (Edge Functions + Postgres + pg_cron) | Every 5 min (pg_cron calls the function) | Postgres | Free projects pause after 7 days of low activity. To check before shipping: whether the 5-minute job counts as activity |

Two database dialects: SQLite (D1, and the Mac) and Postgres (Vercel, Supabase). Migrations are kept in both, and the
test suite runs against both, so a change can't work on one and break the other. Order: Cloudflare is already
built; Vercel and Supabase follow in phase 4.

### C4. One-step online setup

- **Cloudflare and Vercel:** a **Deploy** button in the README and in the app. It copies the code into the user's
  account and creates the database. Migrations run as part of the deploy.
- **Supabase:** one command, `npm run setup:supabase`, using the Supabase CLI. The same `npm run setup` works for
  every service from a terminal.
- **Claiming:** the first visit to a new service shows "Make this yours". It creates the owner and pairs the Mac in
  one go. No admin key is copied around.
- The Mac app shows the steps as a picture guide (C5) and checks each one before moving on.

To verify before building: what each Deploy button can create (database, scheduled job, secrets). The fallback is the
one-command setup.

### C5. Inputs: one Connect button each

Each input is one row in Settings › Inputs: icon, name, state, **Connect**. Connect opens a guide in the app:
numbered steps, one screenshot per step, short sentences, and a check after each step ("Found your Google client ✓").
Written so a 10-year-old can follow it.

| Input | What the guide covers |
|---|---|
| Gmail | Make a Google client once (the steps are shorter with C9's single Desktop client), then sign in |
| WhatsApp | Give FloatBoard Full Disk Access (one macOS screen), then turn it on |
| Fathom | Paste your Fathom key (Mac only) or the webhook address (Always on) |
| Outlook | Install the extension in Chrome, then paste the code it shows |

Gmail cannot be truly one click until FloatBoard has its own Google app approved by Google, which needs a paid yearly
security review. That belongs with a hosted paid version, not now.

### C6. Outputs as their own section

Settings › Outputs lists every output as a switch, each with a short line saying what it does:

- **Board**: always on, cannot be turned off.
- **Phone alerts**: urgent tasks and due reminders (Web Push, or ntfy). Always on only.
- **Phone app**: the board on your phone. Always on only.
- **Reply drafts**: a Draft reply button on email tasks; drafts go to Gmail and are never sent.
- **Calendar**: create or link a meeting from a task.
- **Mac notifications**: due and chase reminders (already local).

### C7. The user picks the AI model

Settings › Rules & learning › AI model, one choice per job:

| Job | Choices | Default |
|---|---|---|
| Judge messages | Claude Haiku · Claude Sonnet · **On this Mac** (Apple's on-device model, free and private, Mac only mode) | Haiku |
| Meeting recaps | Haiku · Sonnet | Haiku |
| Reply drafts | Haiku · Sonnet | Sonnet |

Each choice shows an estimated monthly cost from the user's own recent usage ("about £0.40 a month"). The on-device
choice is offered only after a side-by-side test on real messages shows how often it agrees with Haiku. That number
is shown next to it.

### C8. Learning as a readable instructions file

Settings › Rules & learning shows **one document** in three parts:

1. **Shared rules**: the shipped rulebook (email, chats). Read-only, with a version.
2. **Your rules**: written by you.
3. **Learned**: written by FloatBoard from your corrections. You can edit it too.

Every change to parts 2 and 3 is a **version** with a dated log line and the difference shown, for example:
"14 Nov, learned from 50 corrections: + survey requests aren't tasks; − newsletters from X are tasks". Any version can
be restored. The app owns the document and its history (in `board.sqlite`); the screening module gets the current
version, as settings are today.

Changes from Edition 1: learned text was one field overwritten each time. Now each learning run produces a new
version instead of replacing the old one.

### C9. Keys in one section

Settings › Keys lists every key with its state (set, missing, expired), where it is used, and **Replace** / **Remove**:
Claude key, Google client, Gmail sign-ins, Fathom, online service, phone push keys.

- Stored in the **macOS Keychain** (Edition 1 used a credentials file with owner-only permissions).
- In Always on mode the Mac sends the service only the keys it needs, encrypted, through the existing outbox, and
  the Keys section shows "also on your online service". Removing a key removes it there too.
- **One Google client** for everything: a Desktop type client, which needs no redirect address. The Mac signs in and
  passes the sign-in to the service. To verify before building: a server can refresh a Desktop client's sign-in.
  Fallback: today's Web client, kept for the service only.
- The engine's `/setup` page shrinks to claiming (C4) and a status view.

### C10. Feedback

Help › **Send feedback**:

1. The user writes what happened. App version and macOS version are added. "Include diagnostics" is **off** by
   default; when on, it adds the Activity rows and counts, never task or message text.
2. A preview shows exactly what will be sent.
3. It goes to a small central FloatBoard feedback service (run by the maintainer, separate from anyone's own online
   service). The service stores it and opens an issue in a **private** feedback repository on GitHub, so nothing a
   user writes becomes public. The maintainer copies anything worth fixing into the public repository's issues.
4. A copy is kept in the user's own Activity log, marked "Sent feedback".

**Kept and alerted.** Every message is kept in two places: the collector's own database, kept until the maintainer
deletes it, and the private GitHub issue, kept for good. The issue is the working copy: label it, reply, close it.
New issues alert the maintainer through GitHub's own notifications (email and the GitHub phone app), so nothing
extra has to run. The collector also sends one push through ntfy to the maintainer's topic per message, if a topic is
set. If the GitHub step fails, the message is kept in the database and retried every hour; three failures in a row
send an ntfy alert, so feedback never sits unseen.

Why not a link to a public GitHub issue: many users have no GitHub account, and public issues would expose whatever
they write. Why not email: nothing is collected in one place, and duplicates can't be grouped.

### C11. Phone app as plain web files

The phone app's page, styles and script move out of TypeScript strings into ordinary files in a top-level `phone/`
folder. The online service serves them as static files from the same address, so sign-in (passkeys) and the single
deploy are unchanged. The 1,065-line script can then be split into normal files.

---

### Folder layout after Edition 2

```
FloatBoard/
  mac/                  the Mac app (core, UI, and the JavaScriptCore host for screening)
  screening/            the screening module: sources, filter, AI judge, recaps, learning, drafts, rulebooks
  platforms/
    cloudflare/         Worker entry, D1, cron, static files
    vercel/             Functions entry, Postgres, cron
    supabase/           Edge Function entry, Postgres, pg_cron
  phone/                the phone app (plain web files)
  outlook-extension/    Chrome extension for Outlook on the web
  feedback/             the maintainer's feedback collector (C10)
  docs/
```

Today's `engine/` splits into `screening/` (most of it) and `platforms/cloudflare/`.

### Anti-goals (Edition 2)

- The board core calling any AI, or any input bypassing the proposal contract.
- Any user-written data (rules, corrections, instructions history) that exists only online.
- A hosting option whose database dialect is not covered by the automated tests.
- Feedback sent without the user seeing exactly what goes.
- A setup step that only works if you already know the terminal (the terminal path exists but is never the only one).

---

### Phases

Each phase ships on its own and leaves everything working.

| Phase | Delivers | Changes |
|---|---|---|
| **1. Settings shape** | The Settings window with Mode, Inputs, Outputs, Rules & learning, Keys; the instructions file with versions and log; Keys in the Keychain; Send feedback with the central collector | C5 (layout and guides for what exists), C6, C8, C9, C10. Mode shows Always on only until phase 2 |
| **2. Mac only mode** | The screening module carved out of `engine/`; the JavaScriptCore host; Gmail and Fathom read from the Mac; model choice | C1, C2, C7 (Claude models) |
| **3. One-step Always on** | Platform layer; Cloudflare Deploy button and `npm run setup`; claiming; the single Google client; phone app as plain files | C3 (Cloudflare), C4, C9 (single client), C11 |
| **4. More services and models** | Vercel and Supabase adapters with Postgres tests; the on-device model after a side-by-side test | C3, C7 (on-device) |

### To verify before building (each one can change a detail, not the direction)

1. What the Cloudflare and Vercel Deploy buttons can create: database, scheduled job, secrets.
2. Whether a server can refresh a Google Desktop client's sign-in.
3. Whether Supabase's free plan counts the 5-minute pg_cron job as activity.
4. JavaScriptCore can run the screening bundle: it has no `fetch` or Web Crypto, so the Swift host provides both.
5. How accurate Apple's on-device model is against Haiku on the same messages.

### Details settled in review (designer's calls, open to change)

1. **How keys reach the online service.** They are sent over HTTPS with the Mac's connection key, as all app-to-service
   traffic is today. The service encrypts them at rest with its own key (`ENC_KEY`, as Edition 1). This is not
   end-to-end encryption: the service must be able to use the keys. Rotating a key means replacing it in Keys; the
   new one is sent and the old one is deleted on the service. Removing the online service deletes all keys there.
2. **One holder of each Gmail sign-in at a time.** In Mac only mode the Mac holds the refresh token. On a switch to
   Always on, the Mac hands it to the service and deletes its own copy after the service confirms. On a switch back,
   the reverse happens. Calendar keeps its own separate sign-in on the Mac. If the Desktop-client check (to verify,
   item 2) fails, Mac only mode uses the Desktop client and the service uses a Web client. The user then signs in
   once more when switching, through the same guide.
3. **Switching modes.** One handover call moves the cursors and the list of already-seen source keys. The new
   runner starts reading only after the old one confirms it has stopped. A stop request goes through the outbox, so
   it is delivered even after the Mac was offline. A rare duplicate during the overlap is harmless, because the
   board reconciles proposals by source key (Message-ID and received time), which is the same in both runners. The
   cost is at most a few repeated Claude calls. Each runner's `screening.sqlite` or online database is not copied
   wholesale; only cursors and seen keys move.
4. **Mac only, while the Mac sleeps.** FloatBoard already runs all the time as a menu-bar app. After waking it
   catches up from its cursors, at most 7 days back (as WhatsApp does today). The watchdog measures "last successful
   run" in awake time, so sleep is never reported as a failure.
5. **Instructions file versions.** The current learned text becomes version 1 of Learned, and the current own rules
   become version 1 of Your rules. Learned is stored as one bullet per line, and the log and differences are per
   bullet. A learning run returns bullet changes (add or remove), applied to the current version. If you edited
   since the run started, your edit wins and the run's changes are applied on top only where they don't touch the
   lines you changed. Learning runs wherever screening runs (on the Mac in Mac only mode, on the service in Always
   on mode), and the result comes back to the Mac as a proposal, as in Edition 1.
6. **Feedback service.** It lives in `feedback/` in this repository. It is a small Cloudflare Worker run from the
   maintainer's own account, with its own D1 database and a GitHub token limited to issues on one private
   repository. Abuse controls:
   - each install sends a random id; at most 5 messages a day per install;
   - 5,000 characters at most per message;
   - the id is never linked to a name.

   The service is part of phase 1.
7. **Two database dialects.** There is a small storage layer with named statements; each statement has a SQLite
   version and a Postgres version, and the tests run both. Existing Cloudflare deployments are upgraded in place
   with migrations, as today. Existing installs (two people) re-enter their Claude key and Google client once in
   the new Keys section, using a guide. Secrets on the engine cannot be read back by design.
8. **Outlook in Mac only mode.** Shown greyed out: "Needs Always on: the extension runs on another computer."
9. **Phase 1 and keys.** Phase 1 makes the Keys section the one place: the engine gains an endpoint to receive
   keys, and the `/setup` page's key forms become read-only status. Two key stores never coexist. Mode shows "Mac
   only (coming soon)".
10. **What the screening module may use.** Only what the Swift host provides:
    - `fetch` (whole responses, no streaming);
    - SHA-256, HMAC and AES-GCM;
    - `TextEncoder` and `TextDecoder`;
    - timers.

    Web Push and passkeys stay in the platform layer, because they only exist in Always on mode. The module's
    tests run with only these available, so a forbidden API fails a test.

### Left to the builder

File names inside each folder, the Swift host's bridging details, migration tooling for two dialects, screenshots
for the guides, and the exact wording of each guide step (plain words, one action per step).
