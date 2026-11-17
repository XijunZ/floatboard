# People intelligence, Fathom and recurrence: research notes (17 Nov 2026)

Bottom line: no LinkedIn scraping. Use the owner's own LinkedIn Connections.csv export (diff monthly by profile URL for
company/position changes), LinkedIn's own "notify me about posts" bell for ~20-30 key people, UK Companies House API
(free, official; officer appointments) for directorships, Google Alerts / Google News RSS per person or firm, RSS for
people who write (Substack, blogs, team/news pages). Optional later: one paid enrichment API (People Data Labs ~$0.10-0.30
per record) — never anything that uses the owner's LinkedIn login (PhantomBuster, Lix, extensions: ToS breach, ban risk).
Proxycurl closed July 2025 after LinkedIn's lawsuit. LinkedIn's official portability APIs are EU/EEA/CH only.
Chinese contacts: Maimai/Qichacha/Tianyancha/WeChat accounts are not practical to automate from the UK; manual "last checked".

Fathom meetings carry meeting_url, meeting_title, scheduled_start_time/end_time and calendar_invitees[] (name, email,
is_external) but no calendar event id. Match: Meet link (hangoutLink / conferenceData entry URI) = meeting_url, then
scheduled start within a few minutes; invitees and title break ties. https://developers.fathom.ai/api-reference/meetings/list-meetings

Google Calendar: instances have no recurrence field; get the master with events.get(recurringEventId, fields=recurrence),
cache per series, turn the RRULE into a short label locally. https://developers.google.com/workspace/calendar/api/guides/recurringevents

Sources: https://nubela.co/blog/goodbye-proxycurl/ · https://www.linkedin.com/help/linkedin/answer/a566336 ·
https://www.linkedin.com/help/linkedin/answer/a6214075 · https://developer-specs.company-information.service.gov.uk/guides/rateLimiting
Prices for PDL, Coresignal, Bright Data, Apify, Clay, Crunchbase, X were not re-checked (orders of magnitude only).
