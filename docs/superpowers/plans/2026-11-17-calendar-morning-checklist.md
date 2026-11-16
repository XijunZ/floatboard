# Calendar: morning checklist

The calendar is built and all automatic checks pass. These steps are what is left before it goes live, in order.

1. **Review.** Read the spec (`docs/superpowers/specs/2026-11-16-calendar-design.md`) and look at the branch `calendar`. Nothing has been installed, deployed or pushed.
2. **Reconnect each Google account once.** The calendar needs one more permission. Settings, Calendar, press Reconnect on every account.
3. **Recapture the Google test fixtures from real responses.** They live in `mac/Tests/Fixtures/` (the `gcal-*.json` files). The hand-written ones carry a `_note` field saying so. In practice: after reconnecting, make one real read per endpoint (calendar list, an events page, a cancelled event, a 410 and the missing-permission reply), scrub personal details, save over the matching file, then compare field names with the hand-written version. `gcal-events-page.json` is a wrapper holding `page1` and `page2`. Delete the `_note` from a fixture once it is genuinely captured. After any fixture fix, re-run FloatBoardChecks, `check-silent.sh`, `check-core-offline.sh` and the engine tests.
4. **Deploy the engine first, then install the Mac app.** There are no new engine migrations on this branch, so deploying the engine is just the code. Engine first means the phone shows Today from the first push; an old engine ignores the new data safely. The Mac app upgrades its database from version 10 to 11 on first launch and backs it up first.
5. **Live checks the automatic tests could not do:**
   - drag an event, resize an event, click empty time to add one
   - open the event panel (title, time, delete, Open in Google Calendar)
   - the link picker, from an event and from a task
   - the bar's next meeting and its Join button, also on a narrow bar
   - the phone's Today list in a browser
   - Settings, Calendar in each state (loading, reconnect needed, normal) and the Time zone setting
   - the invisible x on a linked item must not be clickable (no accidental unlink)
   - open an edit pop-up, change the event in Google, then save the pop-up: Google's change must not be reverted
   - a narrow bar with a meeting showing: check it does not lose its chips
   - a new event that fails or is parked lingers as "waiting" with no error shown (known gap)
   - after a sync reset, nothing in Google should look deleted
   - move a task in FloatBoard and in Google, delete its event in Google, delete the task
6. **Reconcile today.** Compare what FloatBoard's calendar shows for today with Google, event by event and task by task.
7. **Before merging:** check main's `DB.schemaVersion`. If it has moved past 10, renumber this branch's version 11 block, regenerate the schema fixture and re-run the checks.
8. **Merge and push** only when steps 1 to 7 look right.

Known small limits to keep in mind (listed in the progress notes): all-day events cannot be dragged, an existing event cannot be moved to another calendar from FloatBoard (use Open in Google Calendar), and a new event made offline shows as waiting until it sends.
