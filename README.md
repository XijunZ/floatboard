# FloatBoard

A floating to-do board for macOS. A one-line bar sits across the top or bottom of your screen; expand it into a
To do / Doing / Done board with groups, due dates, importance and timestamps.

- **Offline.** The app never needs the internet to work.
- **One source of truth.** The app's own database (`board.sqlite`) is the single source of truth for your tasks,
  with a full history of every change. Nothing else holds a second copy that can disagree with it.
- **The app works alone.** Connectors are optional add-ons that suggest tasks from outside sources. If you never
  add one, nothing changes.

## Repository layout

| Folder | What it is |
|---|---|
| `app/` | The Mac app (Swift). `FloatBoardCore` is the offline board, database, backups and health checks. |
| `connectors/email/` | An optional email connector: a Cloudflare Worker you run yourself. See its [README](connectors/email/README.md). |
| `connectors/outlook-web/` | Build plan for an Outlook on the web connector (a Chrome extension). See [PLAN.md](connectors/outlook-web/PLAN.md). |
| `docs/` | The data model: every local data location and how each data point links into which field ([data-model.md](docs/data-model.md)). |

## Using the app

- **Bar**: every open task in one row (tasks with a due date first, then Doing, then To do by importance). Hover to scroll.
- **Ctrl-Opt-N** quick add from anywhere. **Ctrl-Opt-B** show or hide. The menu bar icon has the rest (reset position, export).
- Drag the grip to move the bar. `+` quick-adds, the expand icon opens the board, `-` minimises, `x` closes.
- **Board**: drag cards between columns, or hover for arrows, tick, edit and delete. Right-click for more.
- **Groups** tab: add, rename, recolour, reorder and delete groups.
- **Help** menu: **Guide**, **Activity...** (everything the app did and every problem it hit) and **Restore from backup...**.
- Menu bar, **Export to CSV** writes cards and history to `~/Downloads`.

### Keeping windows clear of the bar
When the bar sits at the bottom, FloatBoard uses the Accessibility API to shrink standard windows whose bottom
edge runs under it (checked once a second, never while the mouse button is down; full-screen apps are left alone).
Toggle it from the menu bar. It needs System Settings, Privacy & Security, Accessibility, FloatBoard. Builds are
ad-hoc signed, so macOS may forget the permission after a rebuild: remove FloatBoard from the list and add it again.

## Where your data lives

Everything is in `~/Library/Application Support/FloatBoard/`:

| Item | What it is |
|---|---|
| `board.sqlite` | Your tasks (`cards`), every change (`events`), groups (`areas`), connectors, the outbox of changes waiting to send, and the Activity log. |
| `Backups/` | Verified snapshots of `board.sqlite`. |
| `google-credentials.json` | Secrets (connector keys, optional Google Calendar sign-in). A private file, owner read/write only, never stored in the database. |

### Backups
A snapshot is taken at launch and every 6 hours (one "daily" per calendar day), verified, then rotated:

- **Daily**: the newest 14 days.
- **Weekly**: the newest 8 weeks.
- **Monthly**: the newest 12 months.
- **Pre-migration**, **pre-recheck** and **pre-restore** snapshots (taken just before a database upgrade, an email re-check, or a restore) are kept for 90 days.

Restore with **Help, Restore from backup...**. Restoring first takes a pre-restore snapshot, so it can be undone.

### Activity window and health watchdog
**Help, Activity...** lists everything the app did and every problem it hit, newest first. Select a row and press
**Show trace** for the details behind it. A watchdog also checks for problems that make no error of their own
(a connector unreachable, changes stuck waiting, a stalled engine, an old or missing backup, unseen errors). When something
is wrong, a warning appears on the bar and in Activity; **Dismiss** hides one until it happens again. Nothing is ever
silently swallowed: the `check-silent.sh` script enforces that.

## Build and check

```
cd app
./scripts/build-app.sh        # builds, signs ad-hoc, installs to /Applications
swift build -c release        # build only
```

Checks never touch your real data. `FloatBoardChecks` refuses to run unless all three scratch paths are set:

```
cd app
scratch=$(mktemp -d)
FLOATBOARD_DB=$scratch/board.sqlite FLOATBOARD_CREDS=$scratch/creds.json FLOATBOARD_BACKUPS=$scratch/Backups \
  swift run FloatBoardChecks
./scripts/check-silent.sh        # every `try?` must carry a "try?-ok:" justification (no swallowed errors)
./scripts/check-core-offline.sh  # FloatBoardCore must not use the network
```

Dev: `FLOATBOARD_DB=/path/test.sqlite .build/release/FloatBoard --snapshot <dir>` renders PNGs of the views.
