# Calendar: morning checklist

The calendar is built and all automatic checks pass. These steps are what is left before it goes live, in order.

1. **Review.** Read the spec (`docs/superpowers/specs/2026-11-16-calendar-design.md`) and look at the branch `calendar`. Nothing has been installed, deployed or pushed.
2. **Reconnect each Google account once.** The calendar needs one more permission. Settings, Calendar, press Reconnect on every account.
3. **Recapture the Google test fixtures from real responses and compare them with the hand-written ones.** The hand-written ones are guesses at Google's format. Note that the events-page fixture is a wrapper holding `page1` and `page2`. Fix any difference the live responses show.
4. **Deploy the engine first** (database migrations if there are any, then the code), **then install the Mac app.** Engine first means the phone shows Today from the first push; an old engine ignores the new data safely.
5. **Live checks the automatic tests could not do:**
   - drag an event, resize an event, click empty time to add one
   - open the event panel (title, time, delete, Open in Google Calendar)
   - the link picker, from an event and from a task
   - the bar's next meeting and its Join button, also on a narrow bar
   - the phone's Today list in a browser
   - Settings, Calendar in each state (loading, reconnect needed, normal) and the Time zone setting
   - move a task in FloatBoard and in Google, delete its event in Google, delete the task
6. **Reconcile today.** Compare what FloatBoard's calendar shows for today with Google, event by event and task by task.
7. **Merge and push** only when steps 1 to 6 look right.

Known small limits to keep in mind (listed in the progress notes): all-day events cannot be dragged, an existing event cannot be moved to another calendar from FloatBoard (use Open in Google Calendar), and a new event made offline shows as waiting until it sends.
