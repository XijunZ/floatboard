# FloatBoard for Outlook (Chrome extension)

Reads the unread emails Outlook on the web shows in your own signed-in Chrome tab and sends them to your FloatBoard
engine, which turns the ones that need action into tasks. It only reads the page: it never clicks, scrolls, opens a
message or changes read state, and it never calls Outlook's own services. See `PLAN.md` for the full design.

## Build and load

```sh
npm install
npx vitest run && npx tsc --noEmit
node build.mjs
```

Then in Chrome: Extensions > turn on Developer mode > Load unpacked > choose the `dist/` folder. After a rebuild, press
the reload button on the extension's card and reload the Outlook tab.

## Limits

The extension can only read what Outlook shows without scrolling, usually the newest 20 to 50 messages. On the first
run it picks up unread emails from the last 7 days; after that only new ones.

## Capture a page sample

Outlook changes its page without notice, so the parser is checked against samples of the real page.

1. Open your Outlook inbox in Chrome.
2. Open the extension's options page and press **Save page sample**. It downloads `outlook-sample-<date>.html`: the
   page with every name, address, id and message text replaced by placeholders (times and dates are kept).
3. Look through the file before sharing it, then add it under `test/samples/`.
4. Adjust `src/selectors.ts` (all page selectors live there) until `parses_unread_rows_from_sample` passes on it.

`test/samples/guess-inbox.html` is a hand-made guess at the page, with invented names and addresses only.
