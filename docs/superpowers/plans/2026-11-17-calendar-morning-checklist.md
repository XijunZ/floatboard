# Calendar: morning checklist

The calendar is built and all automatic checks pass. These steps are what is left before it goes live, in order.

1. **Review.** Read the spec (`docs/superpowers/specs/2026-11-16-calendar-design.md`) and look at the branch `calendar`. Nothing has been installed, deployed or pushed.
2. **Deploy the engine, then install the Mac app.** There are no new engine migrations on this branch, so deploying the engine is just the code. Engine first means the phone shows Today from the first push; an old engine ignores the new data safely. The Mac app then upgrades its database from version 10 to 11 on first launch and backs it up first.
3. **Optional: press "Show all calendars…" once per Google account** (Settings › Outputs › Calendar). Calendars work at once with each account's main calendar and nothing needs reconnecting; the button signs in again so the account's other calendars (shared, team) can be listed too. Reinstalling never needs a reconnect.
4. **Ask Claude to recapture the Google fixtures live:** one read per endpoint (calendar list, an events page, a cancelled event, a 410 and the missing-permission reply), scrubbed of personal details, shown to you before anything is committed. Don't paste live data yourself. The fixtures live in `mac/Tests/Fixtures/` (the `gcal-*.json` files; `gcal-events-page.json` is a wrapper holding `page1` and `page2`); the hand-written ones carry a `_note` field, removed once a file is genuinely captured. After any fixture change, re-run FloatBoardChecks, `check-silent.sh`, `check-core-offline.sh` and the engine tests.
5. **Live checks the automatic tests could not do:**
   - drag an event, resize an event, click empty time to add one (click at 23:00: the new event ends at midnight, not 23:15)
   - open the event panel (title, time, delete, Open in Google Calendar)
   - open and close the panel of an event that runs past midnight without changing anything: Google is unchanged
   - an account connected before this release shows "Showing your main calendar." with its events; press "Show all calendars…": its other calendars appear within a minute
   - connect Gmail from Settings › Connections › Inputs › Gmail for an account: one consent covers Calendar too, and that account then shows in Settings › Outputs › Calendar
   - delete a task that is on the calendar and press Undo within the 8 seconds the bar shows: the event keeps its guests and Meet link, and nothing is sent to Google (the delete is held back about 10 seconds)
   - the link picker, from an event and from a task
   - the bar's next meeting and its Join button, also on a narrow bar (it does not lose its chips); during a long block, a meeting starting within the hour is the one shown
   - the phone's Today list in a browser
   - Settings › Outputs › Calendar in each state (loading, main calendar only, reconnect needed after a revoked sign-in, normal) and the Time zone setting
   - a linked item's remove x only works while it shows (hover); right-click offers Remove link
   - open an edit pop-up, change the event's title in Google, change only the notes in the pop-up and save: Google's title stays
   - a change Google refuses (for example editing an event on a calendar you can only read) shows one error in Activity and is not retried; a refused new event shows a red mark with Discard
   - after a sync reset, nothing in Google should look deleted
   - move a task in FloatBoard and in Google, delete its event in Google, delete the task
6. **Reconcile today.** Compare what FloatBoard's calendar shows for today with Google, event by event and task by task.
7. **Before merging:** check main's `DB.schemaVersion`. If it has moved past 10, renumber this branch's version 11 block, regenerate the schema fixture and re-run the checks.
8. **Merge and push** only when steps 1 to 7 look right.

Known small limits to keep in mind (listed in the progress notes): all-day events cannot be dragged, an existing event cannot be moved to another calendar from FloatBoard (use Open in Google Calendar), and a new event made offline shows as waiting until it sends.
