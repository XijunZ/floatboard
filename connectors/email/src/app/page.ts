/**
 * The phone app's HTML shell and styles. All behaviour lives in `/app/app.js` (src/app/client.ts), so the page runs
 * under a CSP with `script-src 'self'` and no inline script. Icons are inline SVG symbols reused with <use>.
 */

export const THEME_LIGHT = "#f2f3f7";
export const THEME_DARK = "#0f1115";

const CSS = `
:root{--bg:${THEME_LIGHT};--surface:#fff;--surface2:#e8eaf0;--text:#1c1c1e;--muted:#6b6f7b;--line:rgba(0,0,0,.08);
--accent:#2f5be0;--accent-text:#fff;--danger:#d93025;--shadow:0 6px 24px rgba(20,30,60,.12);color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--bg:${THEME_DARK};--surface:#1b1e24;--surface2:#262a32;--text:#f2f3f5;--muted:#9aa0ab;
--line:rgba(255,255,255,.08);--accent:#7d9bff;--accent-text:#0f1115;--danger:#ff6b6b;--shadow:0 6px 24px rgba(0,0,0,.5)}}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--bg);color:var(--text)}
body{font:16px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;min-height:100vh;
min-height:100dvh;padding:0 env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
-webkit-text-size-adjust:100%;overscroll-behavior-y:contain}
[hidden]{display:none!important}
svg.i{width:22px;height:22px;flex:none;fill:none;stroke:currentColor;stroke-width:1.9;stroke-linecap:round;stroke-linejoin:round}
button,input,select{font:inherit;color:inherit}
button{cursor:pointer;border:0;background:none;padding:0}
.btn{display:flex;align-items:center;justify-content:center;gap:8px;width:100%;min-height:50px;padding:12px 18px;border-radius:14px;
background:var(--accent);color:var(--accent-text);font-weight:600;font-size:17px}
.btn.secondary{background:var(--surface2);color:var(--text)}
.btn.danger{background:var(--surface2);color:var(--danger)}
.btn:disabled{opacity:.55}
.icon-btn{display:inline-flex;align-items:center;justify-content:center;min-width:44px;min-height:44px;border-radius:12px;color:var(--text)}
.icon-btn:active,.card:active,.tab:active{opacity:.6}
.screen{max-width:640px;margin:0 auto;padding:0 16px 120px}
.center{min-height:80vh;display:flex;flex-direction:column;justify-content:center;gap:16px;text-align:center;
padding-top:calc(24px + env(safe-area-inset-top))}
.logo{width:72px;height:72px;margin:0 auto;border-radius:18px;box-shadow:var(--shadow)}
h1{font-size:26px;margin:0}
h2{font-size:15px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin:28px 4px 8px;font-weight:600}
p{margin:0}
.muted{color:var(--muted)}
.small{font-size:14px}
.error{color:var(--danger);min-height:1.4em}
label{display:block;text-align:left;font-size:14px;color:var(--muted);margin:0 4px 6px}
input[type=text],select{width:100%;min-height:50px;padding:12px 14px;border-radius:12px;border:1px solid var(--line);
background:var(--surface);font-size:17px;-webkit-appearance:none;appearance:none}
select{padding-right:40px;background:var(--surface) no-repeat right 14px center/14px 14px url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 14 14'%3E%3Cpath d='M2 5l5 5 5-5' fill='none' stroke='%238e8e93' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E")}
input[type=text]:focus,select:focus{outline:2px solid var(--accent);outline-offset:0}
.bar{position:sticky;top:0;z-index:5;background:var(--bg);padding-top:env(safe-area-inset-top);margin:0 -16px;padding-left:16px;
padding-right:16px}
header.top{display:flex;align-items:center;gap:4px;padding:8px 0 4px}
#settings header.top{position:sticky;top:0;z-index:5;background:var(--bg);padding-top:calc(8px + env(safe-area-inset-top))}
header.top .title{flex:1;min-width:0}
header.top h1{font-size:24px}
.updated{font-size:13px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.updated.off{color:var(--text)}
.note{font-size:13px;color:var(--muted);margin:0 0 8px 4px}
nav.tabs{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:6px;padding:6px 0 10px}
.tab{display:flex;flex-direction:column;align-items:center;gap:2px;min-height:58px;padding:6px 2px;border-radius:14px;
color:var(--muted);font-size:13px;font-weight:600}
.tab .row{display:flex;align-items:center;gap:5px}
.tab .count{font-size:15px}
.tab[aria-selected=true]{background:var(--surface);color:var(--text);box-shadow:var(--shadow)}
.list{display:flex;flex-direction:column;gap:8px}
.card{display:flex;align-items:flex-start;gap:12px;width:100%;text-align:left;padding:14px;border-radius:16px;background:var(--surface);
min-height:56px;box-shadow:0 1px 2px rgba(0,0,0,.06)}
.card.pending{opacity:.55}
.dot{width:12px;height:12px;border-radius:50%;margin-top:5px;flex:none;background:#8e8e93}
.card .body{flex:1;min-width:0}
.card .t{font-size:17px;overflow-wrap:anywhere;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:3;overflow:hidden}
.card .meta{display:flex;flex-wrap:wrap;gap:4px 10px;margin-top:3px;font-size:14px;color:var(--muted)}
.card .due.late{color:var(--danger);font-weight:600}
.marks{font-weight:800;letter-spacing:-.05em;color:var(--muted);flex:none;margin-top:1px}
.marks.m1{color:var(--text)}
.marks.m2{color:var(--danger)}
.empty{text-align:center;color:var(--muted);padding:48px 16px}
.banner{background:var(--surface);border-radius:14px;padding:12px 14px;margin-bottom:10px;font-size:14px;color:var(--muted)}
.fab{position:fixed;right:calc(20px + env(safe-area-inset-right));bottom:calc(24px + env(safe-area-inset-bottom));z-index:6;width:60px;
height:60px;border-radius:30px;background:var(--accent);color:var(--accent-text);display:flex;align-items:center;justify-content:center;
box-shadow:var(--shadow)}
.fab svg.i{width:28px;height:28px;stroke-width:2.4}
.group{background:var(--surface);border-radius:16px;padding:14px;display:flex;flex-direction:column;gap:10px}
.group p{font-size:15px}
.group ol{margin:0;padding-left:22px;font-size:15px;display:flex;flex-direction:column;gap:4px}
.scrim{position:fixed;inset:0;z-index:20;background:rgba(0,0,0,.35);display:flex;align-items:flex-end;justify-content:center}
.sheet{width:100%;max-width:640px;background:var(--bg);border-radius:20px 20px 0 0;padding:10px 16px calc(20px + env(safe-area-inset-bottom));
display:flex;flex-direction:column;gap:10px;max-height:85vh;overflow:auto;animation:up .18s ease-out}
.sheet .grab{width:40px;height:5px;border-radius:3px;background:var(--surface2);margin:0 auto 6px}
.sheet h3{margin:0 4px;font-size:19px;overflow-wrap:anywhere}
.sheet .sub{margin:0 4px 6px;color:var(--muted);font-size:14px}
.sheet .hint{margin:2px 4px 0;text-align:center}
.sheet .act{justify-content:flex-start;background:var(--surface);color:var(--text);font-weight:500}
@keyframes up{from{transform:translateY(40px);opacity:.4}to{transform:none;opacity:1}}
.toast{position:fixed;left:16px;right:16px;bottom:calc(96px + env(safe-area-inset-bottom));z-index:30;margin:0 auto;max-width:520px;
background:var(--text);color:var(--bg);padding:12px 16px;border-radius:14px;text-align:center;box-shadow:var(--shadow)}
.spin{animation:spin 1s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion:reduce){.sheet,.spin{animation:none}}
`;

const ICONS = `<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0" style="position:absolute" aria-hidden="true">
<symbol id="i-todo" viewBox="0 0 24 24"><path d="M12 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-6"/><path d="M17.5 3.5a2.1 2.1 0 0 1 3 3L12 15l-4 1 1-4z"/></symbol>
<symbol id="i-doing" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M12 3.5a8.5 8.5 0 0 1 0 17z" fill="currentColor"/></symbol>
<symbol id="i-watch" viewBox="0 0 24 24"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></symbol>
<symbol id="i-done" viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></symbol>
<symbol id="i-gear" viewBox="0 0 24 24"><path d="M18.8 10.3L21.5 10.8L21.5 13.2L18.8 13.7L18 15.6L19.6 17.9L17.9 19.6L15.6 18L13.7 18.8L13.2 21.5L10.8 21.5L10.3 18.8L8.4 18L6.1 19.6L4.4 17.9L6 15.6L5.2 13.7L2.5 13.2L2.5 10.8L5.2 10.3L6 8.4L4.4 6.1L6.1 4.4L8.4 6L10.3 5.2L10.8 2.5L13.2 2.5L13.7 5.2L15.6 6L17.9 4.4L19.6 6.1L18 8.4Z"/><circle cx="12" cy="12" r="3"/></symbol>
<symbol id="i-refresh" viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.6-5.9"/><path d="M20 4v5h-5"/></symbol>
<symbol id="i-plus" viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></symbol>
<symbol id="i-back" viewBox="0 0 24 24"><path d="M15 5l-7 7 7 7"/></symbol>
<symbol id="i-link" viewBox="0 0 24 24"><path d="M14 4h6v6"/><path d="M20 4l-9 9"/><path d="M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4"/></symbol>
<symbol id="i-key" viewBox="0 0 24 24"><circle cx="8" cy="15" r="4"/><path d="M11 12l9-9M17 6l3 3M15 8l2 2"/></symbol>
</svg>`;

const icon = (name: string) => `<svg class="i" aria-hidden="true"><use href="#i-${name}"/></svg>`;

const tab = (status: string, label: string) =>
  `<button class="tab" role="tab" data-tab="${status}" aria-selected="false"><span class="row">${icon(status)}<span class="count" data-count="${status}">0</span></span><span>${label}</span></button>`;

const BODY = `${ICONS}
<main id="loading" class="screen"><div class="center"><img class="logo" src="/app/icon.svg" alt=""><p id="loading-text" class="muted">Loading…</p>
<button id="retry" class="btn secondary" hidden>Try again</button></div></main>

<main id="pair" class="screen" hidden><div class="center">
<img class="logo" src="/app/icon.svg" alt="">
<h1>Set up this phone</h1>
<p class="muted">This connects the phone to your FloatBoard. Your phone will ask for your face, fingerprint or screen lock to make a passkey.</p>
<div><label for="device-name">Name for this phone</label><input id="device-name" type="text" maxlength="60" autocomplete="off"></div>
<button id="pair-go" class="btn">${icon("key")}Set up this phone</button>
<p id="pair-error" class="error" role="alert"></p>
<button id="pair-skip" class="btn secondary">This phone is already set up</button>
</div></main>

<main id="signin" class="screen" hidden><div class="center">
<img class="logo" src="/app/icon.svg" alt="">
<h1>Sign in</h1>
<p class="muted">Your phone will ask for your face, fingerprint or screen lock.</p>
<button id="signin-go" class="btn">${icon("key")}Sign in</button>
<p id="signin-error" class="error" role="alert"></p>
<p class="muted small">First time? On your Mac open FloatBoard, Connectors tab, Pair a phone, and scan the code.</p>
</div></main>

<main id="board" class="screen" hidden>
<div class="bar">
<header class="top"><div class="title"><h1>FloatBoard</h1><div id="sync-status" class="updated" role="status" aria-live="polite"></div></div>
<button id="refresh" class="icon-btn" aria-label="Sync now">${icon("refresh")}</button>
<button id="open-settings" class="icon-btn" aria-label="Settings">${icon("gear")}</button></header>
<nav class="tabs" role="tablist">${tab("todo", "To do")}${tab("doing", "Doing")}${tab("watch", "Watch")}${tab("done", "Done today")}</nav>
</div>
<p id="sync-note" class="note" role="status" hidden></p>
<div id="pending-note" class="banner" hidden></div>
<div id="list" class="list" role="tabpanel"></div>
<p id="empty" class="empty" hidden></p>
<button id="add" class="fab" aria-label="Add a task">${icon("plus")}</button>
</main>

<main id="settings" class="screen" hidden>
<header class="top"><button id="close-settings" class="icon-btn" aria-label="Back">${icon("back")}</button><div class="title"><h1>Settings</h1></div></header>
<h2>Notifications</h2>
<div class="group">
<p id="notif-status"></p>
<div id="notif-ios" hidden><p>Add to Home Screen first:</p><ol><li>Tap Share in Safari.</li><li>Tap Add to Home Screen.</li><li>Open FloatBoard from your Home Screen and come back here.</li></ol></div>
<button id="notif-on" class="btn" hidden>Turn on notifications</button>
<button id="notif-test" class="btn secondary" hidden>Send a test notification</button>
<button id="notif-off" class="btn danger" hidden>Turn off</button>
</div>
<h2>Put FloatBoard on your Home Screen</h2>
<div class="group">
<p><b>Android (Chrome):</b> tap the menu (three dots), then Install app or Add to Home screen.</p>
<p><b>iPhone (Safari):</b> tap Share, then Add to Home Screen. Notifications need iOS 16.4 or later.</p>
</div>
<h2>Phone and Mac</h2>
<div class="group">
<p class="muted small">Move tasks, add tasks and open links here. Mac only: editing or deleting tasks, notes, reply drafts, calendar and settings.</p>
</div>
<h2>This phone</h2>
<div class="group">
<p id="who" class="muted"></p>
<button id="signout" class="btn danger">Sign out</button>
<p class="muted small">To remove this phone completely, open the engine's setup page on your computer and press Remove next to it.</p>
</div>
</main>

<div id="toast" class="toast" role="status" hidden></div>
<script src="/app/app.js" defer></script>`;

export const MANIFEST = JSON.stringify({
  id: "/app/",
  name: "FloatBoard",
  short_name: "FloatBoard",
  description: "Your FloatBoard tasks on your phone.",
  start_url: "/app/",
  scope: "/app/",
  display: "standalone",
  background_color: THEME_LIGHT,
  theme_color: THEME_LIGHT,
  icons: [
    { src: "/app/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any maskable" },
    { src: "/app/icon-512.png", sizes: "512x512", type: "image/png", purpose: "any maskable" },
    { src: "/app/icon.svg", sizes: "any", type: "image/svg+xml", purpose: "any" },
  ],
});

export const PAGE_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>FloatBoard</title>
<meta name="theme-color" content="${THEME_LIGHT}" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="${THEME_DARK}" media="(prefers-color-scheme: dark)">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="FloatBoard">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="format-detection" content="telephone=no">
<link rel="manifest" href="/app/manifest.webmanifest">
<link rel="icon" href="/app/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/app/icon-180.png">
<style>${CSS}</style>
</head>
<body>
${BODY}
</body>
</html>
`;
