# FloatBoard email connector

An **optional** connector for the FloatBoard app. It is a small Cloudflare Worker (with a D1 database) that you run
on your own free Cloudflare account. Every hour, even when your Mac is off, it reads your Gmail, uses Claude to turn
emails that need *your* action into task suggestions, adds meeting-note summaries to your meeting tasks, and can
send critical actions to your phone through Telegram. The FloatBoard app stays the source of truth: it pulls
suggestions from the engine and sends your changes back.

Each person runs **their own** engine, so nobody else holds your email data. Setup takes about 20 minutes. You need
a Mac with FloatBoard installed, a terminal, and Node.js 20 or newer (`node --version`).

Tests: `npm test` (runs locally in the Workers runtime with fake Google/Claude/Telegram).

---

## 1. Get the code

```bash
git clone https://github.com/<owner>/FloatBoard.git
cd FloatBoard/connectors/email
npm install
```

## 2. Cloudflare (free)

1. Create a free account at <https://dash.cloudflare.com/sign-up>.
2. Log in from the terminal (opens your browser):
   ```bash
   npx wrangler login
   ```
3. Create the database and copy the `database_id` it prints into `wrangler.toml` (replace the zeros):
   ```bash
   npx wrangler d1 create floatboard
   ```
4. Create the tables:
   ```bash
   npx wrangler d1 migrations apply floatboard --remote
   ```

## 3. Secrets

Values are generated on your Mac and sent straight to Cloudflare. You never see them, except the admin key, which is
copied to your clipboard.

```bash
openssl rand -base64 32 | npx wrangler secret put ENC_KEY
openssl rand -hex 32 | tee >(pbcopy) | npx wrangler secret put ADMIN_KEY      # admin key -> clipboard
```

Paste the admin key into your password manager now. You need it to create your user and to invite other people.

Optional, for phone alerts (step 7):

```bash
npx wrangler secret put TELEGRAM_BOT_TOKEN      # paste the bot token when asked
npx wrangler secret put TELEGRAM_BOT_NAME       # the bot's username, without @
```

## 4. Deploy

```bash
npx wrangler deploy
```

It prints your engine's address, e.g. `https://floatboard.<your-subdomain>.workers.dev` (called `<your-engine>` below).
Check it is up: `curl -s -o /dev/null -w "%{http_code}" <your-engine>/v2/status` should print `401` (it needs a key).

## 5. The engine's setup page

Open `<your-engine>/setup/admin` and sign in with the **admin key** to create your user (just a name). That gives you
an invite link and a user key. Then open `<your-engine>/setup` and sign in with your **user key**. The setup page holds
only secrets and connections (rules, groups and lists live in the FloatBoard app). Work down it:

### Google Cloud (read email)

1. Go to <https://console.cloud.google.com> and create a project.
2. **APIs & Services, Library**: enable the **Gmail API** (and the **Google Calendar API** if you also want the app's optional calendar feature).
3. **Google Auth Platform, Get started**: app name FloatBoard, External, your email.
4. **Audience**: press **Publish app** so the status is **In production**. If you leave it in Testing, Google expires every
   sign-in after **7 days** and you must reconnect each week. You will see a one-time "unverified app" warning when you
   connect; that is expected for your own app: choose **Advanced**, then continue.
5. **Clients, Create client**: type **Web application** (not Desktop). Add this exact **Authorized redirect URI**:
   `<your-engine>/setup/google/callback`
6. Scopes needed: `gmail.modify` and `openid email`.
7. On the setup page, paste the **Client ID** and **Client secret** under "Google Cloud client", then press
   **Connect a Gmail account** and sign in. Repeat for each inbox.

### Claude key
Create an API key at <https://console.anthropic.com>, then paste it under "Claude API key". It is stored encrypted on
your engine, not on your Mac. The engine uses a small, cheap Claude model: a few cents per hundred emails after the free
newsletter and ads filter.

### Connect to FloatBoard
Press **Connect to FloatBoard** at the bottom of the setup page. It opens the app on this Mac and adds the engine as a
connector (the address goes in the app's database, the key in its private credentials file). If it does not appear,
sign out of the setup page and sign in again to get the link.

## 6. Fathom meeting notes (optional)

Recap emails from Fathom are matched to your meeting tasks automatically. For faster notes, create the webhook address
under "Fathom meeting recaps" on the setup page and paste it into Fathom's webhook settings.

## 7. Telegram alerts (optional)

1. In Telegram, open **@BotFather**, send `/newbot`, pick a name and a username ending in `bot`. Set the two secrets from step 3, then deploy again.
2. Point Telegram at the engine (replace `<your-engine>`):
   ```bash
   SECRET=$(openssl rand -hex 24)
   echo "$SECRET" | npx wrangler secret put TELEGRAM_WEBHOOK_SECRET
   read -s "TOKEN?Bot token: "; echo          # zsh; in bash: read -s -p "Bot token: " TOKEN
   curl -s "https://api.telegram.org/bot$TOKEN/setWebhook" -d "url=<your-engine>/telegram/webhook" -d "secret_token=$SECRET"
   ```
   It should answer `{"ok":true,...}`.
3. On the setup page press **Get Telegram link**, then **Open Telegram and press Start**. Critical actions (urgent, or due
   within 24 hours) now arrive on your phone.

**Your own bot (optional, per user).** Anyone can use their own bot instead of the shared one: create a bot with
@BotFather (`/newbot`), paste its token under **Telegram alerts** on the setup page and press **Save**, then press
**Get Telegram link** again. The engine checks the token, stores it encrypted, and points that bot's webhook at
`<your-engine>/telegram/webhook/u/<random id>` with its own secret, so no command line is needed. Alerts and replies for
that user then come from their bot. **Remove my bot** goes back to the shared bot (link the chat again).

**Phone alerts with the ntfy app (optional, no bot needed).** On the setup page, under **Phone alerts (ntfy app)**, press
**Turn on**. The engine makes a private random topic and shows its address. Install the free ntfy app (Android or iPhone),
tap +, paste the topic name (on iPhone allow notifications), then press **Send a test alert**. Urgent items go to every
channel you have (ntfy and Telegram); one failing never stops the other. Alerts carry the task title, due date, sender and
a link, never the email text. **New topic** replaces a leaked topic; **Turn off** stops them. `alerts_on = false` in
settings silences all channels.

**Reporting a miss.** If an email needed action but the engine did not turn it into a task, send the bot
`missed: <a few words from the email>`. No task is created. The engine only *learns* from it, so similar emails are
caught next time.

## 8. Phone app (optional)

The engine also serves a small phone app at `<your-engine>/app`: your board (To do, Doing, Watch, Done today), with a
tap to move a task, open its link or add a new one, and lock-screen notifications for urgent tasks. It is a web app you
put on your Home Screen, so there is no app store. Your Mac stays in charge: changes made on the phone are picked up by
the Mac within a couple of minutes and show as "Waiting for your Mac" until then.

1. **Pair the phone.** On your Mac open FloatBoard, **Connectors** tab, **Pair a phone**, and scan the code with the
   phone's camera (the code works once, for 10 minutes). Tap **Set up this phone**; the phone makes a passkey with your
   face, fingerprint or screen lock. Later sign-ins use the same passkey; no password.
2. **Android (Chrome):** open the menu (three dots), then **Install app** (or **Add to Home screen**). Open FloatBoard
   from the Home Screen, tap the gear, then **Turn on notifications**.
3. **iPhone (Safari, iOS 16.4 or later):** tap **Share**, then **Add to Home Screen**. Open FloatBoard from the Home
   Screen and tap **Sign in** (the Home Screen app keeps its own sign-in). Notifications only work from the Home Screen
   app: tap the gear, then **Turn on notifications**, and allow them.
4. **Test it:** in the app's settings press **Send a test notification**.

**Removing a phone:** on the engine's setup page, under **Phones**, press **Remove** next to it. That signs it out, deletes
its passkey on the engine and stops its notifications. **Sign out** in the app's settings signs out only that phone.

## Inviting other people

Open `<your-engine>/setup/admin`, sign in with the admin key, enter a name and press **Create invite**. Send them the link
(shown once). Opening it on their Mac connects their FloatBoard to your engine with their own private data. The
`key=` part is also how they sign in to `/setup`. Each person's Google client is stored with their own account, so on
their `/setup` page they paste a Google Cloud client too: their own (step 5 above), or the same Client ID and secret as
yours (add their Gmail address as a test user if your Google app is still in Testing). Anyone who prefers not to share your engine can run their own
engine instead.

## How emails are judged and how it learns

Claude follows one shared skill file, [`src/skills/email-triage.md`](src/skills/email-triage.md): what counts as an
action, and how to treat invitations, bookings, bills, security alerts, threads and dates. It is the same for everyone
and contains nothing personal. To improve it for everyone, edit the file and redeploy.

Each person adds their own layer in the app (Connectors, settings): what each group means and their own rules. The
engine also learns from you. When you delete a task as "Not an action" or "Wrong details", change a suggested task's
group, importance, title or due date, or report a missed email, that is a correction. Finishing a task is not a
correction: it only marks the email read (if that setting is on). Once **50** (or **100**, your choice in settings)
corrections have collected, one Claude call turns them into short **learned preferences**, which the app stores and
shows so you can edit or remove anything wrong. Rules about security email are never learned. If an update would remove
most of what was already learned, it is refused and the status line says "Learning paused"; it tries again after new
corrections arrive or a day later.

## Updating

```bash
git pull && npm install && npx wrangler d1 migrations apply floatboard --remote && npx wrangler deploy
```

---

## Troubleshooting

Start in the app: **Help, Activity...** (select a row, **Show trace**) and the **Connectors** tab status line.

| What you see | What it means / what to do |
|---|---|
| Watchdog: "<connector> hasn't been reachable for over an hour" | The app cannot reach the engine. Check your internet, then open `<your-engine>/v2/status` (a `401` means the engine is up). If not, run `npx wrangler deploy` again. Your changes are kept and sent when it is back. |
| Watchdog: "N changes ... waiting to send for over an hour" | Changes made in the app have not reached the engine. Usually the same cause as "unreachable"; check the Connectors tab. They are sent automatically once it is reachable. |
| Watchdog: "engine hasn't finished a run for over 2 hours" | The hourly email run is stuck or failing. Look at the Connectors status line for a "needs attention" line and the setup page for an inbox that needs reconnecting; check Cloudflare dashboard, Workers, floatboard, Logs. |
| Watchdog: "<connector> has never synced" | The connect link was opened but the first sync never worked. Open the setup page, press **Connect to FloatBoard** again, or check the address in the Connectors tab. |
| Watchdog: "no verified backup" / "newest verified backup is over 36 hours old" | Backups are not being made or are damaged. Check free disk space and Activity for a backup error, then restart the app (it backs up at launch). |
| Watchdog: "Couldn't read <connector>'s status" | The engine sent something the app could not understand, usually after a version mismatch. Update the engine (see Updating) and the app to the same version. |
| Setup page: inbox "needs attention", sign-in expired or revoked | Press **Reconnect** for that inbox. If it happens every 7 days, the Google app is still in Testing: set it to **In production** (step 5.4). |
| "The engine didn't accept this key." | Wrong user key or admin key. Re-check, or create a new invite. |
| Google sign-in shows `redirect_uri_mismatch` (after **Connect a Gmail account**) | Saving the client doesn't check the redirect; Google does at sign-in. In the Google client, the redirect URI must be exactly `<your-engine>/setup/google/callback`, and the client type must be **Web application**. Fix it there, then connect again. |
| "Learning paused: ..." | A learning update would have removed most of your learned preferences, so it was refused. Review them in the app (Connectors, settings); learning tries again after new corrections or a day later. |
| "Add your Claude API key..." / "Claude API key was rejected." | Save a key on the setup page. A rejected key was revoked or mistyped. |
| No Telegram messages | Re-run the `setWebhook` command (step 7), then press **Get Telegram link** again. |
| `wrangler` asks to log in again | Run `npx wrangler login`. |
| Errors mentioning daily limits | The free Cloudflare database allows 100,000 writes a day; normal use is about 1%. It resets at midnight UTC. |
