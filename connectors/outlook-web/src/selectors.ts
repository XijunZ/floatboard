// Every DOM selector and page pattern the extension relies on lives in this file, so a change to the Outlook page is a
// one-file fix. The values below are a first guess at the Outlook on the web message list; check them against a
// scrubbed sample of the real page (options page > Save page sample) and adjust here.

export const SEL = {
  /** The message list of the open folder. */
  messageList: '[role="listbox"][aria-label*="message list" i], div[role="main"] [role="listbox"]',
  /** Any row in the message list (used to tell "empty inbox" from "rows not recognised"). */
  anyRow: '[role="option"]',
  /** A message row we can read. */
  row: '[role="option"][data-convid]',
  /** Attributes that may hold the row's item id, in order of preference. */
  rowIdAttrs: ["data-convid", "data-item-id", "data-itemid"],
  /** The row's accessible label starts with this when the message is unread. */
  unreadLabel: /^\s*unread\b/i,
  /** Inside a row. */
  sender: "span.OZZZK, [data-testid='SenderName'], span[title*='@']",
  subject: "span.TtcXM, [data-testid='Subject']",
  time: "span._rWRU, [data-testid='ReceivedTime'], time",
  preview: "div.Pz1t8, span.Pz1t8, [data-testid='Preview']",

  /** The signed-in account shown in the page header. */
  mailboxText: "#mectrl_currentAccount_secondary",
  mailboxLabelled: "#mectrl_main_trigger, #O365_MainLink_Me, #O365_HeaderRightRegion [aria-label*='@']",
  /** Present on a signed-in Outlook page (account header). */
  signedInHeader: "#mectrl_main_trigger, #O365_MainLink_Me, #mectrl_currentAccount_secondary, #O365_HeaderRightRegion",
  /** Present on a signed-out or sign-in page. */
  signedOutMarkers:
    'input[name="loginfmt"], input[type="password"], a[href*="login.live.com"], a[href*="login.microsoftonline.com"], a[href*="/owa/?nlp=1"]',

  /** URL paths that show the Inbox list (including the Focused and Other tabs and an open reading pane). */
  inboxPath: /^\/mail(?:\/\d+)?(?:\/inbox(?:\/.*)?)?\/?$/i,
} as const;
