/**
 * The phone app's script, served as `/app/app.js` (same origin, so the page's CSP needs no inline script).
 *
 * Plain JavaScript, no framework. Data from the engine is only ever written with textContent / attributes, never parsed
 * as HTML. Screens: pair (from `#pair=<code>`), sign in (passkey), board, settings. WebAuthn uses `navigator.credentials`
 * directly with base64url <-> bytes done here.
 *
 * - Each browser install keeps a random install id in localStorage and sends it, with a device name, when pairing and
 *   signing in, so the engine knows it as one device (see app/auth.ts).
 * - Works offline (sync v2). The last board is kept with the account marker of the account last confirmed on this phone
 *   and shown at once, labelled "Last synced hh:mm" or "Offline". When `/app/api/me` or the board answers with another
 *   account, that board and the queue are dropped before anything else happens. A 401 goes to Sign in; the queue is kept
 *   and sent only if the same account signs back in.
 * - Moves and adds go into a queue in localStorage, each with its own id and the time it was made, and show at once.
 *   The queue is sent in batches (`POST /app/api/action` with `sent_at`), retried 5 s doubling to 5 minutes and at once
 *   when the phone comes online, the app is opened or comes back to the front. No error pop-ups: a one-line status at the
 *   top says "Synced", "Last synced 14:02", "3 changes waiting" or "Offline, 3 changes waiting".
 * - After pairing or signing in, the browser is reset: cached board dropped and any old push subscription unsubscribed,
 *   so a browser that changes hands never shows or receives the previous account's data.
 * - The queue logic is in src/app/sync-logic.ts (pure functions, tested on their own).
 *
 * Kept as a string: no backticks or dollar-brace inside (apart from the SYNC_JS insert).
 */
import { SYNC_JS } from "./sync-logic";

export const APP_JS = String.raw`"use strict";
(function () {
${SYNC_JS}

  var $ = function (id) { return document.getElementById(id); };
  var SCREENS = ["loading", "pair", "signin", "board", "settings"];
  var STATUSES = ["todo", "doing", "watch", "done"];
  var MOVE = { todo: "Move to To do", doing: "Move to Doing", watch: "Move to Watch", done: "Mark as done" };
  var MOVED = { todo: "Moved to To do", doing: "Moved to Doing", watch: "Moved to Watch", done: "Done" };
  var BOARD_KEY = "floatboard.board";   // { account, board, at }: the last board and when it was synced
  var QUEUE_KEY = "floatboard.queue";   // { account, actions: [{ id, made_at, card_id?, action, title?, group? }] }
  var SENT_KEY = "floatboard.sent";     // ids this phone sent lately, to notice when the engine reports one not applied
  var REFRESH_MS = 60000;
  var PAIR_KEY = "floatboard.pair";
  var INSTALL_KEY = "floatboard.install";
  var ua = navigator.userAgent;
  var isIOS = /iPad|iPhone|iPod/.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  var standalone = function () {
    return navigator.standalone === true || (window.matchMedia && matchMedia("(display-mode: standalone)").matches);
  };

  var board = null;      // the last board from the engine: { updated, cards, pending }
  var me = null;         // { user, device, account }: set only once /app/api/me has answered in this session
  var shownAccount = null; // account whose board and queue are in memory (from the cache before /me answers)
  var queue = { account: null, actions: [] };
  var sentIds = [];
  var shown = [];        // cards as shown: the board plus queued actions
  var lastSync = 0;      // phone clock (ms) of the last good answer from the engine
  var isOffline = false;
  var syncing = false;
  var syncAgain = false;
  var failures = 0;
  var retryTimer = 0;
  var tab = "todo";
  var current = "loading";
  var busy = false;
  var sheetOpen = false;
  var reloadWhenIdle = false;

  // ------------------------------------------------------------ small helpers

  function SignedOut() { this.name = "SignedOut"; }
  SignedOut.prototype = Object.create(Error.prototype);

  function show(name) {
    current = name;
    SCREENS.forEach(function (s) { $(s).hidden = s !== name; });
    window.scrollTo(0, 0);
  }

  var toastTimer = 0;
  function toast(text) {
    var t = $("toast");
    t.textContent = text;
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.hidden = true; }, 3200);
  }

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function icon(name) {
    var ns = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(ns, "svg");
    svg.setAttribute("class", "i");
    svg.setAttribute("aria-hidden", "true");
    var use = document.createElementNS(ns, "use");
    use.setAttribute("href", "#i-" + name);
    svg.appendChild(use);
    return svg;
  }

  function store(key, value) {
    try { if (value == null) localStorage.removeItem(key); else localStorage.setItem(key, JSON.stringify(value)); } catch (e) { /* storage off */ }
  }
  function load(key) {
    try { var v = localStorage.getItem(key); return v ? JSON.parse(v) : null; } catch (e) { return null; }
  }
  function sessionGet(key) { try { return sessionStorage.getItem(key); } catch (e) { return null; } }
  function sessionSet(key, v) { try { if (v == null) sessionStorage.removeItem(key); else sessionStorage.setItem(key, v); } catch (e) { /* storage off */ } }

  function offline(e) { return e instanceof TypeError; } // fetch() rejects with TypeError when there is no connection

  async function api(path, opts) {
    opts = opts || {};
    var init = { method: opts.method || "GET", credentials: "same-origin", cache: "no-store", headers: {} };
    if (opts.body !== undefined) {
      init.headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(opts.body);
    }
    var r = await fetch(path, init);
    var data = null;
    try { data = await r.json(); } catch (e) { data = null; }
    if (r.status === 401) throw new SignedOut();
    if (!r.ok) {
      var err = new Error((data && typeof data.error === "string" && data.error) || "Something went wrong. Please try again.");
      err.status = r.status;
      throw err;
    }
    return data || {};
  }

  function message(e) {
    if (offline(e)) return "No connection. Check your internet and try again.";
    return (e && e.message) || "Something went wrong. Please try again.";
  }

  // ------------------------------------------------------------ passkeys (WebAuthn)

  function fromB64url(s) {
    s = String(s).replace(/-/g, "+").replace(/_/g, "/");
    while (s.length % 4) s += "=";
    var bin = atob(s);
    var out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  function toB64url(buf) {
    var b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
    var s = "";
    for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }
  function withIds(list) {
    return (list || []).map(function (c) { return Object.assign({}, c, { id: fromB64url(c.id) }); });
  }
  function extensionResults(cred) {
    try { return cred.getClientExtensionResults ? cred.getClientExtensionResults() : {}; } catch (e) { return {}; }
  }

  function passkeysMissing() {
    if (!window.isSecureContext || !window.PublicKeyCredential || !navigator.credentials) {
      return "This browser can't use passkeys. Open this page in Chrome on Android or Safari on iPhone.";
    }
    return "";
  }

  function passkeyError(e, creating) {
    var name = e && e.name;
    if (name === "NotAllowedError" || name === "AbortError") return "That was cancelled or timed out. Tap the button to try again.";
    if (name === "InvalidStateError" && creating) return "This phone already has a FloatBoard passkey. Tap \"This phone is already set up\" to sign in.";
    if (name === "SecurityError") return "Passkeys can't be used on this address.";
    return message(e);
  }

  async function createPasskey(o) {
    var pk = Object.assign({}, o, {
      challenge: fromB64url(o.challenge),
      user: Object.assign({}, o.user, { id: fromB64url(o.user.id) }),
      excludeCredentials: withIds(o.excludeCredentials),
    });
    delete pk.hints;
    var c = await navigator.credentials.create({ publicKey: pk });
    var r = c.response;
    return {
      id: c.id, rawId: toB64url(c.rawId), type: c.type,
      authenticatorAttachment: c.authenticatorAttachment || undefined,
      clientExtensionResults: extensionResults(c),
      response: {
        clientDataJSON: toB64url(r.clientDataJSON),
        attestationObject: toB64url(r.attestationObject),
        transports: r.getTransports ? r.getTransports() : [],
      },
    };
  }

  async function getPasskey(o) {
    var pk = Object.assign({}, o, { challenge: fromB64url(o.challenge), allowCredentials: withIds(o.allowCredentials) });
    delete pk.hints;
    var c = await navigator.credentials.get({ publicKey: pk });
    var r = c.response;
    return {
      id: c.id, rawId: toB64url(c.rawId), type: c.type,
      authenticatorAttachment: c.authenticatorAttachment || undefined,
      clientExtensionResults: extensionResults(c),
      response: {
        clientDataJSON: toB64url(r.clientDataJSON),
        authenticatorData: toB64url(r.authenticatorData),
        signature: toB64url(r.signature),
        userHandle: r.userHandle ? toB64url(r.userHandle) : undefined,
      },
    };
  }

  // ------------------------------------------------------------ pairing and sign in

  var memoryInstall = null;
  function installId() {
    var id = load(INSTALL_KEY);
    if (typeof id === "string" && /^[A-Za-z0-9_-]{16,100}$/.test(id)) return id;
    if (!memoryInstall) memoryInstall = toB64url(crypto.getRandomValues(new Uint8Array(24)));
    store(INSTALL_KEY, memoryInstall);
    return memoryInstall;
  }

  // A new sign-in on this browser: forget the previous account's board and stop its notifications on this browser.
  // The queue stays until /app/api/me names the account: kept for the same account, dropped for another (acceptAccount).
  async function resetBrowser() {
    board = null;
    me = null;
    shownAccount = null;
    store(BOARD_KEY, null);
    try {
      var sub = await currentSubscription();
      if (sub) await sub.unsubscribe();
    } catch (e) { /* best effort */ }
  }

  function defaultDeviceName() {
    if (/iPhone/.test(ua)) return "iPhone";
    if (/iPad/.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)) return "iPad";
    if (/Android/.test(ua)) return "Android phone";
    return "Phone";
  }

  function showPair() {
    show("pair");
    $("device-name").value = defaultDeviceName();
    $("pair-error").textContent = passkeysMissing();
  }

  async function pair() {
    var code = sessionGet(PAIR_KEY);
    if (!code || busy) return;
    var problem = passkeysMissing();
    if (problem) { $("pair-error").textContent = problem; return; }
    busy = true;
    $("pair-go").disabled = true;
    $("pair-error").textContent = "";
    try {
      var options = await api("/app/api/pair/options", { method: "POST", body: { code: code } });
      var response = await createPasskey(options);
      await api("/app/api/pair/finish", { method: "POST", body: { code: code, response: response, deviceName: $("device-name").value.trim(), installId: installId() } });
      sessionSet(PAIR_KEY, null);
      await resetBrowser();
      busy = false;
      await openBoard();
      toast("This phone is set up.");
    } catch (e) {
      $("pair-error").textContent = passkeyError(e, true);
    } finally {
      busy = false;
      $("pair-go").disabled = false;
    }
  }

  // Signed out (401): the board is no longer shown or kept; the queue stays, tied to its account, for a sign-in back.
  function showSignIn() {
    board = null;
    me = null;
    shownAccount = null;
    store(BOARD_KEY, null);
    clearTimeout(retryTimer);
    closeSheet();
    show("signin");
    $("signin-error").textContent = passkeysMissing();
  }

  async function signIn() {
    if (busy) return;
    var problem = passkeysMissing();
    if (problem) { $("signin-error").textContent = problem; return; }
    busy = true;
    $("signin-go").disabled = true;
    $("signin-error").textContent = "";
    try {
      var r = await api("/app/api/login/options", { method: "POST", body: {} });
      var response = await getPasskey(r.options);
      await api("/app/api/login/finish", { method: "POST", body: { challengeId: r.challengeId, response: response, deviceName: defaultDeviceName(), installId: installId() } });
      await resetBrowser();
      busy = false;
      await openBoard();
    } catch (e) {
      $("signin-error").textContent = passkeyError(e, false);
    } finally {
      busy = false;
      $("signin-go").disabled = false;
    }
  }

  // ------------------------------------------------------------ the board

  function dayStart(d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()); }

  function parseDate(s) {
    if (typeof s !== "string") return null;
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
    var d = m ? new Date(+m[1], +m[2] - 1, +m[3]) : new Date(s);
    return isNaN(d.getTime()) ? null : d;
  }

  function dueInfo(c) {
    var d = parseDate(c.due);
    if (!d) return null;
    var now = new Date();
    var today = dayStart(now);
    var day = dayStart(d);
    var diff = Math.round((day.getTime() - today.getTime()) / 86400000);
    var label = diff === 0 ? "Today" : diff === 1 ? "Tomorrow" : diff === -1 ? "Yesterday"
      : d.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
    if (c.has_time) label += ", " + d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    var late = c.status !== "done" && (c.has_time ? d.getTime() < now.getTime() : day.getTime() < today.getTime());
    return { label: label, late: late, t: d.getTime() };
  }

  function doneToday(c) {
    if (c.status !== "done") return false;
    var d = parseDate(c.done_at);
    return !d || dayStart(d).getTime() === dayStart(new Date()).getTime();
  }

  function cardsFor(status) {
    var list = shown.filter(function (c) { return status === "done" ? doneToday(c) : c.status === status; });
    if (status === "done") {
      return list.sort(function (a, b) {
        var x = parseDate(a.done_at), y = parseDate(b.done_at);
        return (y ? y.getTime() : 0) - (x ? x.getTime() : 0);
      });
    }
    return list.map(function (c, i) { return { c: c, i: i, due: dueInfo(c) }; }).sort(function (a, b) {
      var x = a.due ? a.due.t : Infinity, y = b.due ? b.due.t : Infinity;
      if (x !== y) return x < y ? -1 : 1;
      if ((b.c.importance || 0) !== (a.c.importance || 0)) return (b.c.importance || 0) - (a.c.importance || 0);
      return a.i - b.i;
    }).map(function (x) { return x.c; });
  }

  function groups() {
    var seen = [];
    shown.forEach(function (c) {
      if (typeof c.group === "string" && c.group && seen.indexOf(c.group) < 0) seen.push(c.group);
    });
    return seen.length ? seen : ["Inbox"];
  }

  function colour(c) { return typeof c.color === "string" && /^#[0-9a-fA-F]{6}$/.test(c.color) ? c.color : "#8e8e93"; }

  function marks(c) {
    var n = c.importance === 2 ? 2 : c.importance === 1 ? 1 : 0;
    var m = el("span", "marks m" + n, "!!!".slice(0, n + 1));
    m.setAttribute("aria-label", ["Low", "Medium", "High"][n] + " importance");
    return m;
  }

  function waitingText() {
    var n = typeof board.pending === "number" ? board.pending : 0;
    return n === 0 ? "" : n === 1 ? "1 change is waiting for your Mac." : n + " changes are waiting for your Mac.";
  }

  function cardButton(c) {
    var b = el("button", "card" + (c.pending ? " pending" : ""));
    var dot = el("span", "dot");
    dot.style.background = colour(c);
    b.appendChild(dot);
    var body = el("span", "body");
    body.appendChild(el("span", "t", c.title));
    var meta = el("span", "meta");
    var due = dueInfo(c);
    if (due) meta.appendChild(el("span", "due" + (due.late ? " late" : ""), due.label));
    if (c.group) meta.appendChild(el("span", null, c.group));
    if (c.queued) meta.appendChild(el("span", "wait", "Not synced yet"));
    else if (c.pending) meta.appendChild(el("span", null, "Waiting for your Mac"));
    body.appendChild(meta);
    b.appendChild(body);
    b.appendChild(marks(c));
    b.addEventListener("click", function () { cardSheet(c); });
    return b;
  }

  function statusLine() {
    return statusText({ waiting: queue.actions.length, offline: isOffline, lastSync: lastSync, now: Date.now() }) || "Syncing…";
  }

  function render() {
    if (!board) return;
    shown = viewBoard(board, queue.actions).cards;
    STATUSES.forEach(function (s) {
      document.querySelector('[data-count="' + s + '"]').textContent = String(cardsFor(s).length);
      document.querySelector('[data-tab="' + s + '"]').setAttribute("aria-selected", String(s === tab));
    });
    $("sync-status").textContent = statusLine();
    $("sync-status").classList.toggle("off", isOffline);
    var w = waitingText();
    $("pending-note").hidden = !w;
    $("pending-note").textContent = w;
    var list = $("list");
    list.replaceChildren();
    var cards = cardsFor(tab);
    cards.forEach(function (c) { list.appendChild(cardButton(c)); });
    $("empty").hidden = cards.length > 0;
    $("empty").textContent = !board.updated && !shown.length ? "Waiting for your Mac to send the board." : {
      todo: "Nothing to do. Tap + to add a task.",
      doing: "Nothing in progress.",
      watch: "Nothing you're waiting on.",
      done: "Nothing done yet today.",
    }[tab];
  }

  var noteTimer = 0;
  function note(text) {
    if (!text) return;
    var n = $("sync-note");
    n.textContent = text;
    n.hidden = false;
    clearTimeout(noteTimer);
    noteTimer = setTimeout(function () { n.hidden = true; }, 6000);
  }

  function saveQueue() { store(QUEUE_KEY, queue.actions.length ? queue : null); }

  // Forget everything this phone holds for an account: its board, its queue and the ids it sent.
  function dropAccountData() {
    board = null;
    shownAccount = null;
    queue = { account: null, actions: [] };
    sentIds = [];
    store(BOARD_KEY, null);
    store(QUEUE_KEY, null);
    store(SENT_KEY, null);
  }

  // /app/api/me answered: the session's account. Any board or queue of another account is dropped, never shown or sent.
  function acceptAccount(m) {
    var cached = load(BOARD_KEY);
    var other = (cached && !(cached.account === m.account)) || (shownAccount && shownAccount !== m.account) ||
      (queue.account && queue.account !== m.account);
    if (other) dropAccountData();
    me = m;
    shownAccount = m.account;
    queue.account = m.account;
  }

  // A board from the engine (GET /app/api/board or the answer to a batch of actions).
  function gotBoard(b) {
    if (b.account && me && b.account !== me.account) {
      // The session now belongs to another account (signed in elsewhere in this browser): start clean for it.
      dropAccountData();
      me.account = b.account;
      shownAccount = b.account;
      queue.account = b.account;
    }
    board = { updated: b.updated || null, cards: Array.isArray(b.cards) ? b.cards : [], pending: b.pending || 0 };
    var sup = noticeSuperseded(sentIds, b.superseded);
    sentIds = sup.sentIds;
    store(SENT_KEY, sentIds);
    queue.actions = afterSend(queue.actions, { superseded: b.superseded }).actions;
    saveQueue();
    lastSync = Date.now();
    isOffline = false;
    if (me && me.account) store(BOARD_KEY, { account: me.account, board: board, at: lastSync });
    return sup.count;
  }

  function scheduleRetry() {
    clearTimeout(retryTimer);
    retryTimer = setTimeout(sync, retryDelay(failures));
  }

  // Send the queue (if any) and get the latest board. Never shows an error: the status line says how things stand.
  async function sync() {
    if (current === "pair" || current === "signin") return;
    if (syncing) { syncAgain = true; return; } // a tap during a sync: go again once this one is done
    syncing = true;
    syncAgain = false;
    clearTimeout(retryTimer);
    var spin = $("refresh").firstElementChild;
    spin.classList.add("spin");
    var replaced = 0, dropped = 0, rejected = 0;
    try {
      if (!me) acceptAccount(await api("/app/api/me"));
      var got = false;
      while (queue.actions.length) {
        var body = takeBatch(queue.actions, new Date().toISOString());
        if (!body.actions.length) break;
        // A batch the engine refuses as malformed (400) is sent again one action at a time; one still refused leaves the queue.
        var sent = await sendBatch(body, function (b) { return api("/app/api/action", { method: "POST", body: b }); },
          function () { return new Date().toISOString(); });
        for (var i = 0; i < sent.results.length; i++) {
          var r = sent.results[i];
          sentIds = rememberSent(sentIds, r.accepted);
          var after = afterSend(queue.actions, r);
          queue.actions = after.actions;
          dropped += after.dropped;
          saveQueue();
          replaced += gotBoard(r);
          got = true;
        }
        if (sent.rejected.length) {
          queue.actions = afterSend(queue.actions, { accepted: sent.rejected }).actions;
          rejected += sent.rejected.length;
          saveQueue();
        }
      }
      if (!got) replaced += gotBoard(await api("/app/api/board"));
      failures = 0;
    } catch (e) {
      if (e instanceof SignedOut) { syncing = false; spin.classList.remove("spin"); showSignIn(); return; }
      isOffline = offline(e);
      failures += 1;
      scheduleRetry();
      if (current === "loading") {
        $("loading-text").textContent = isOffline ? "Can't reach FloatBoard. Check your internet connection." : message(e);
        $("retry").hidden = false;
      }
    } finally {
      syncing = false;
      spin.classList.remove("spin");
    }
    if (!board && me) board = { updated: null, cards: [], pending: 0 };
    if (board && current === "loading") show("board");
    render();
    note(replacedText(replaced, dropped, rejected));
    if (syncAgain && failures === 0 && me) { syncAgain = false; sync(); }
  }

  async function openBoard() {
    show("loading");
    $("loading-text").textContent = "Loading…";
    $("retry").hidden = true;
    failures = 0;
    await sync();
    if (me) checkPush();
  }

  function newId() {
    if (crypto.randomUUID) return crypto.randomUUID();
    var b = crypto.getRandomValues(new Uint8Array(16));
    var h = "";
    for (var i = 0; i < 16; i++) h += (b[i] < 16 ? "0" : "") + b[i].toString(16);
    return h.slice(0, 8) + "-" + h.slice(8, 12) + "-" + h.slice(12, 16) + "-" + h.slice(16, 20) + "-" + h.slice(20);
  }

  // A tap: queued with its own id and the time it was made, shown at once, sent as soon as possible.
  function act(a, done) {
    var account = me ? me.account : shownAccount;
    if (!account || !board) return;
    a.id = newId();
    a.made_at = new Date().toISOString();
    queue.account = account;
    queue.actions.push(a);
    saveQueue();
    closeSheet();
    render();
    toast(done);
    failures = 0;
    sync();
  }

  // ------------------------------------------------------------ sheets

  function closeSheet() {
    var s = document.querySelector(".scrim");
    if (s) s.remove();
    sheetOpen = false;
    if (reloadWhenIdle) location.reload();
  }

  function openSheet(fill) {
    closeSheet();
    var scrim = el("div", "scrim");
    var sheet = el("div", "sheet");
    sheet.setAttribute("role", "dialog");
    sheet.setAttribute("aria-modal", "true");
    sheet.appendChild(el("div", "grab"));
    fill(sheet);
    var close = el("button", "btn secondary", "Close");
    close.addEventListener("click", closeSheet);
    sheet.appendChild(close);
    scrim.appendChild(sheet);
    scrim.addEventListener("click", function (e) { if (e.target === scrim) closeSheet(); });
    document.body.appendChild(scrim);
    sheetOpen = true;
  }

  function safeLink(link) {
    try {
      var u = new URL(link);
      return u.protocol === "https:" || u.protocol === "http:" ? u.href : null;
    } catch (e) { return null; }
  }

  function cardSheet(c) {
    openSheet(function (sheet) {
      sheet.appendChild(el("h3", null, c.title));
      var due = dueInfo(c);
      sheet.appendChild(el("p", "sub", [c.group, due ? "Due " + due.label : ""].filter(Boolean).join(" · ")));
      if (c.pending) {
        sheet.appendChild(el("p", "sub", c.queued ? "Not synced yet. You can move it once your Mac has added it."
          : "Waiting for your Mac. You can move it once your Mac has added it."));
      } else {
        STATUSES.forEach(function (s) {
          if (s === c.status) return;
          var b = el("button", "btn act");
          b.appendChild(icon(s));
          b.appendChild(document.createTextNode(MOVE[s]));
          b.addEventListener("click", function () { act({ card_id: c.id, action: s }, MOVED[s]); });
          sheet.appendChild(b);
        });
      }
      var href = c.link ? safeLink(c.link) : null;
      if (href) {
        var a = el("a", "btn act");
        a.href = href;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        a.style.textDecoration = "none";
        a.appendChild(icon("link"));
        a.appendChild(document.createTextNode("Open link"));
        sheet.appendChild(a);
      }
      sheet.appendChild(el("p", "sub hint", "Edit details on your Mac."));
    });
  }

  function addSheet() {
    openSheet(function (sheet) {
      sheet.appendChild(el("h3", null, "Add a task"));
      var form = el("form");
      form.style.display = "flex";
      form.style.flexDirection = "column";
      form.style.gap = "10px";
      var tl = el("label", null, "What needs doing?");
      tl.htmlFor = "add-title";
      var title = el("input");
      title.type = "text";
      title.id = "add-title";
      title.maxLength = 200;
      title.autocomplete = "off";
      title.enterKeyHint = "done";
      var gl = el("label", null, "Group");
      gl.htmlFor = "add-group";
      var group = el("select");
      group.id = "add-group";
      groups().forEach(function (g) { group.appendChild(el("option", null, g)); });
      var go = el("button", "btn", "Add");
      go.type = "submit";
      [tl, title, gl, group, go].forEach(function (x) { form.appendChild(x); });
      form.addEventListener("submit", function (e) {
        e.preventDefault();
        var t = title.value.trim();
        if (!t) { title.focus(); return; }
        tab = "todo";
        act({ action: "add", title: t.slice(0, 200), group: group.value }, "Added. It will show on your Mac shortly.");
      });
      sheet.appendChild(form);
      setTimeout(function () { title.focus(); }, 50);
    });
  }

  // ------------------------------------------------------------ settings and notifications

  function pushSupported() { return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window; }

  // The service worker's registration, or null when it isn't running (ready never settles then, so wait at most 4 s).
  function workerReady() {
    return Promise.race([navigator.serviceWorker.ready, new Promise(function (r) { setTimeout(function () { r(null); }, 4000); })]);
  }

  async function currentSubscription() {
    if (!pushSupported()) return null;
    var reg = await workerReady();
    return reg ? reg.pushManager.getSubscription() : null;
  }

  function notifButtons(on, test, off) {
    $("notif-on").hidden = !on;
    $("notif-test").hidden = !test;
    $("notif-off").hidden = !off;
  }

  async function renderNotifications() {
    var status = $("notif-status");
    $("notif-ios").hidden = true;
    notifButtons(false, false, false);
    if (isIOS && !standalone()) {
      status.textContent = "To get notifications on iPhone, FloatBoard has to be on your Home Screen.";
      $("notif-ios").hidden = false;
      return;
    }
    if (!pushSupported()) {
      status.textContent = isIOS ? "Notifications need iOS 16.4 or later." : "This browser can't show notifications. Try Chrome.";
      return;
    }
    if (Notification.permission === "denied") {
      status.textContent = "Notifications are blocked for FloatBoard. Allow them in your phone's settings, then come back here.";
      return;
    }
    status.textContent = "Checking…";
    try {
      var sub = await currentSubscription();
      if (sub && Notification.permission === "granted") {
        status.textContent = "Notifications are on for this phone. Urgent tasks will show on your lock screen.";
        notifButtons(false, true, true);
      } else {
        status.textContent = "Notifications are off on this phone. Turn them on to hear about urgent tasks.";
        notifButtons(true, false, false);
      }
    } catch (e) {
      status.textContent = "Couldn't check notifications. " + message(e);
      notifButtons(true, false, false);
    }
  }

  async function sendSubscription(sub) {
    await api("/app/api/push/subscribe", { method: "POST", body: sub.toJSON() });
  }

  // At start: notifications were allowed but the browser has no subscription any more (it can drop one): make a new one
  // quietly. Asking for permission needs a tap, so a phone that never allowed them is left to Settings.
  async function checkPush() {
    try {
      if (!pushSupported() || Notification.permission !== "granted" || (isIOS && !standalone())) return;
      var reg = await workerReady();
      if (!reg || await reg.pushManager.getSubscription()) return;
      var key = (await api("/app/api/push/key")).key;
      var sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: fromB64url(key) });
      await sendSubscription(sub);
    } catch (e) { /* Settings shows "Notifications are off on this phone" */ }
  }

  async function turnOn() {
    if (busy) return;
    busy = true;
    $("notif-on").disabled = true;
    try {
      // Ask first, straight from the tap: iPhone only shows the question in response to a tap.
      var permission = await Notification.requestPermission();
      if (permission !== "granted") {
        toast(permission === "denied" ? "Notifications are blocked. Allow them in your phone's settings." : "Notifications stay off.");
        return;
      }
      var key = (await api("/app/api/push/key")).key;
      var reg = await workerReady();
      if (!reg) throw new Error("The app is still starting. Close it, open it again and try once more.");
      var sub = await reg.pushManager.getSubscription();
      var old = sub && sub.options && sub.options.applicationServerKey;
      if (sub && (!old || toB64url(old) !== key)) { await sub.unsubscribe(); sub = null; }
      if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: fromB64url(key) });
      await sendSubscription(sub);
      toast("Notifications are on.");
    } catch (e) {
      if (e instanceof SignedOut) { showSignIn(); return; }
      toast("Couldn't turn on notifications. " + message(e));
    } finally {
      busy = false;
      $("notif-on").disabled = false;
      if (current === "settings") renderNotifications();
    }
  }

  async function sendTest() {
    if (busy) return;
    busy = true;
    $("notif-test").disabled = true;
    try {
      try {
        await api("/app/api/push/test", { method: "POST", body: {} });
      } catch (e) {
        if (e.status !== 409) throw e;
        // The engine lost this phone's subscription: send it again and retry once.
        var sub = await currentSubscription();
        if (!sub) throw e;
        await sendSubscription(sub);
        await api("/app/api/push/test", { method: "POST", body: {} });
      }
      toast("Sent. It should arrive in a few seconds.");
    } catch (e) {
      if (e instanceof SignedOut) { showSignIn(); return; }
      if (e.status === 410) {
        var gone = await currentSubscription().catch(function () { return null; });
        if (gone) await gone.unsubscribe().catch(function () { /* already gone */ });
      }
      toast(message(e));
    } finally {
      busy = false;
      $("notif-test").disabled = false;
      if (current === "settings") renderNotifications();
    }
  }

  async function turnOff() {
    if (busy) return;
    busy = true;
    try {
      var sub = await currentSubscription();
      if (sub) await sub.unsubscribe();
      await api("/app/api/push/subscribe", { method: "DELETE" });
      toast("Notifications are off.");
    } catch (e) {
      if (e instanceof SignedOut) { showSignIn(); return; }
      toast(message(e));
    } finally {
      busy = false;
      if (current === "settings") renderNotifications();
    }
  }

  function openSettings() {
    show("settings");
    $("who").textContent = me && me.device ? "This phone: " + me.device : "";
    if (!me) api("/app/api/me").then(function (m) { acceptAccount(m); $("who").textContent = "This phone: " + m.device; render(); }).catch(function (e) {
      if (e instanceof SignedOut) showSignIn();
    });
    renderNotifications();
  }

  async function signOut() {
    if (busy) return;
    busy = true;
    try {
      // A signed-out phone should not keep getting alerts.
      try {
        var sub = await currentSubscription();
        if (sub) {
          await api("/app/api/push/subscribe", { method: "DELETE" }).catch(function () { /* best effort */ });
          await sub.unsubscribe();
        }
      } catch (e) { /* best effort */ }
      // Changes still waiting get one last chance to go before the queue is dropped with the rest of this account's data.
      if (queue.actions.length && me) await sync();
      await api("/app/api/logout", { method: "POST", body: {} });
      busy = false;
      dropAccountData();
      showSignIn();
    } catch (e) {
      if (e instanceof SignedOut) { busy = false; showSignIn(); return; }
      toast(message(e));
    } finally {
      busy = false;
    }
  }

  // ------------------------------------------------------------ start

  async function start() {
    var m = /[#&]pair=([A-Za-z0-9_-]{10,200})/.exec(location.hash);
    if (m) {
      // Keep the code for this tab only and take it out of the address, so a Home Screen copy never carries it.
      sessionSet(PAIR_KEY, m[1]);
      history.replaceState(null, "", location.pathname + location.search);
    }
    if (sessionGet(PAIR_KEY)) { showPair(); return; }
    var q = load(QUEUE_KEY);
    queue = q && typeof q.account === "string" && Array.isArray(q.actions) ? q : { account: null, actions: [] };
    var sent = load(SENT_KEY);
    sentIds = Array.isArray(sent) ? sent : [];
    me = null;
    // Offline first: the last board of the account last confirmed on this phone shows at once, labelled with when it was
    // synced, while /app/api/me and the board load. If /me names another account, acceptAccount drops it.
    var cached = load(BOARD_KEY);
    if (cached && typeof cached.account === "string" && cached.board && Array.isArray(cached.board.cards) &&
        (!queue.account || queue.account === cached.account)) {
      shownAccount = cached.account;
      board = cached.board;
      lastSync = typeof cached.at === "number" ? cached.at : 0;
      queue.account = cached.account;
      show("board");
      render();
      failures = 0;
      await sync();
      if (me) checkPush();
      return;
    }
    await openBoard();
  }

  STATUSES.forEach(function (s) {
    document.querySelector('[data-tab="' + s + '"]').addEventListener("click", function () { tab = s; render(); window.scrollTo(0, 0); });
  });
  $("pair-go").addEventListener("click", pair);
  $("pair-skip").addEventListener("click", function () { sessionSet(PAIR_KEY, null); start(); });
  $("signin-go").addEventListener("click", signIn);
  $("retry").addEventListener("click", start);
  $("refresh").addEventListener("click", function () { failures = 0; sync(); });
  $("open-settings").addEventListener("click", openSettings);
  $("close-settings").addEventListener("click", function () { show("board"); render(); });
  $("add").addEventListener("click", addSheet);
  $("notif-on").addEventListener("click", turnOn);
  $("notif-test").addEventListener("click", sendTest);
  $("notif-off").addEventListener("click", turnOff);
  $("signout").addEventListener("click", signOut);
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") closeSheet(); });

  function refreshSoon() {
    if (document.visibilityState !== "visible") return;
    if (reloadWhenIdle && !busy && !sheetOpen) { location.reload(); return; }
    if (current === "board" || current === "settings" || (current === "loading" && !$("retry").hidden)) { failures = 0; sync(); }
    if (current === "settings") renderNotifications();
  }
  // Retry at once when the phone comes back online or the app comes back to the front.
  document.addEventListener("visibilitychange", refreshSoon);
  window.addEventListener("focus", refreshSoon);
  window.addEventListener("online", refreshSoon);
  window.addEventListener("offline", function () { isOffline = true; render(); });
  // While the app is open and in front: the latest board every minute (sync skips while a retry is waiting its turn).
  setInterval(function () {
    if (document.visibilityState !== "visible" || failures > 0) { render(); return; }
    if (current === "board" || current === "settings") sync();
  }, REFRESH_MS);

  if ("serviceWorker" in navigator) {
    var hadController = !!navigator.serviceWorker.controller;
    navigator.serviceWorker.addEventListener("controllerchange", function () {
      // A new version of the app took over: reload, but never in the middle of something.
      if (!hadController) { hadController = true; return; }
      if (busy || sheetOpen || current === "pair") reloadWhenIdle = true; else location.reload();
    });
    navigator.serviceWorker.register("/app/sw.js", { scope: "/app/" }).catch(function () { /* the app still works without it */ });
  }

  start();
})();
`;
