/**
 * The phone app's script, served as `/app/app.js` (same origin, so the page's CSP needs no inline script).
 *
 * Plain JavaScript, no framework. Data from the engine is only ever written with textContent / attributes, never parsed
 * as HTML. Screens: pair (from `#pair=<code>`), sign in (passkey), board, settings. WebAuthn uses `navigator.credentials`
 * directly with base64url <-> bytes done here.
 *
 * Kept as a string: no backticks or dollar-brace inside.
 */
export const APP_JS = String.raw`"use strict";
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var SCREENS = ["loading", "pair", "signin", "board", "settings"];
  var STATUSES = ["todo", "doing", "watch", "done"];
  var MOVE = { todo: "Move to To do", doing: "Move to Doing", watch: "Move to Watch", done: "Mark as done" };
  var MOVED = { todo: "Moved to To do", doing: "Moved to Doing", watch: "Moved to Watch", done: "Done" };
  var BOARD_KEY = "floatboard.board";
  var PAIR_KEY = "floatboard.pair";
  var ua = navigator.userAgent;
  var isIOS = /iPad|iPhone|iPod/.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  var standalone = function () {
    return navigator.standalone === true || (window.matchMedia && matchMedia("(display-mode: standalone)").matches);
  };

  var board = null;      // { updated, cards, pending }
  var me = null;         // { user, device }
  var tab = "todo";
  var current = "loading";
  var busy = false;
  var sheetOpen = false;
  var lastLoad = 0;
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
      await api("/app/api/pair/finish", { method: "POST", body: { code: code, response: response, deviceName: $("device-name").value.trim() } });
      sessionSet(PAIR_KEY, null);
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

  function showSignIn() {
    board = null;
    me = null;
    store(BOARD_KEY, null);
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
      await api("/app/api/login/finish", { method: "POST", body: { challengeId: r.challengeId, response: response } });
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
    if (!board || !Array.isArray(board.cards)) return [];
    var list = board.cards.filter(function (c) { return status === "done" ? doneToday(c) : c.status === status; });
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
    ((board && board.cards) || []).forEach(function (c) {
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

  function updatedText() {
    if (!board || !board.updated) return "Waiting for your Mac to send the board";
    var d = parseDate(board.updated);
    if (!d) return "";
    var time = d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    if (dayStart(d).getTime() === dayStart(new Date()).getTime()) return "Updated " + time;
    return "Updated " + d.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" }) + ", " + time;
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
    if (c.pending) meta.appendChild(el("span", null, "Waiting for your Mac"));
    body.appendChild(meta);
    b.appendChild(body);
    b.appendChild(marks(c));
    b.addEventListener("click", function () { cardSheet(c); });
    return b;
  }

  function render() {
    if (!board) return;
    STATUSES.forEach(function (s) {
      document.querySelector('[data-count="' + s + '"]').textContent = String(cardsFor(s).length);
      document.querySelector('[data-tab="' + s + '"]').setAttribute("aria-selected", String(s === tab));
    });
    $("updated").textContent = updatedText();
    var pending = typeof board.pending === "number" ? board.pending : 0;
    $("pending-note").hidden = pending === 0;
    $("pending-note").textContent = pending === 1 ? "1 change is waiting for your Mac." : pending + " changes are waiting for your Mac.";
    var list = $("list");
    list.replaceChildren();
    var cards = cardsFor(tab);
    cards.forEach(function (c) { list.appendChild(cardButton(c)); });
    $("empty").hidden = cards.length > 0;
    $("empty").textContent = {
      todo: "Nothing to do. Tap + to add a task.",
      doing: "Nothing in progress.",
      watch: "Nothing you're waiting on.",
      done: "Nothing done yet today.",
    }[tab];
  }

  function setBoard(b, fromNetwork) {
    board = b;
    if (fromNetwork) store(BOARD_KEY, b);
    $("offline").hidden = !!fromNetwork;
    render();
  }

  async function loadBoard(quiet) {
    lastLoad = Date.now();
    var spin = $("refresh").firstElementChild;
    spin.classList.add("spin");
    try {
      setBoard(await api("/app/api/board"), true);
    } catch (e) {
      if (e instanceof SignedOut) { showSignIn(); return; }
      if (offline(e)) {
        $("offline").hidden = false;
        if (!quiet) toast("No connection. Showing the last board this phone loaded.");
      } else if (!quiet) toast(message(e));
    } finally {
      spin.classList.remove("spin");
    }
  }

  async function openBoard() {
    show("board");
    var cached = load(BOARD_KEY);
    if (!board && cached) setBoard(cached, false);
    if (!board) setBoard({ updated: null, cards: [], pending: 0 }, false);
    await loadBoard(true);
    if (current === "board" && !me) api("/app/api/me").then(function (m) { me = m; }).catch(function () { /* shown later */ });
  }

  async function act(body, done) {
    if (busy) return;
    busy = true;
    try {
      setBoard(await api("/app/api/action", { method: "POST", body: body }), true);
      closeSheet();
      toast(done);
    } catch (e) {
      if (e instanceof SignedOut) { showSignIn(); return; }
      if (e.status === 404) { closeSheet(); toast("That task changed on your Mac. Refreshing."); busy = false; await loadBoard(true); return; }
      toast(message(e));
    } finally {
      busy = false;
    }
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
        sheet.appendChild(el("p", "sub", "Waiting for your Mac. You can move it once your Mac has added it."));
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
        act({ action: "add", title: t, group: group.value }, "Added. It will show on your Mac shortly.");
      });
      sheet.appendChild(form);
      setTimeout(function () { title.focus(); }, 50);
    });
  }

  // ------------------------------------------------------------ settings and notifications

  function pushSupported() { return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window; }

  async function currentSubscription() {
    if (!pushSupported()) return null;
    var reg = await navigator.serviceWorker.ready;
    return reg.pushManager.getSubscription();
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
        status.textContent = "Notifications are off. Turn them on to hear about urgent tasks.";
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
      var reg = await navigator.serviceWorker.ready;
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
    if (!me) api("/app/api/me").then(function (m) { me = m; $("who").textContent = "This phone: " + m.device; }).catch(function (e) {
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
      await api("/app/api/logout", { method: "POST", body: {} });
      busy = false;
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
    show("loading");
    $("loading-text").textContent = "Loading…";
    $("retry").hidden = true;
    try {
      me = await api("/app/api/me");
      await openBoard();
    } catch (e) {
      if (e instanceof SignedOut) { showSignIn(); return; }
      if (load(BOARD_KEY)) { await openBoard(); return; }
      $("loading-text").textContent = offline(e) ? "Can't reach FloatBoard. Check your internet connection." : message(e);
      $("retry").hidden = false;
    }
  }

  STATUSES.forEach(function (s) {
    document.querySelector('[data-tab="' + s + '"]').addEventListener("click", function () { tab = s; render(); window.scrollTo(0, 0); });
  });
  $("pair-go").addEventListener("click", pair);
  $("pair-skip").addEventListener("click", function () { sessionSet(PAIR_KEY, null); start(); });
  $("signin-go").addEventListener("click", signIn);
  $("retry").addEventListener("click", start);
  $("refresh").addEventListener("click", function () { loadBoard(false); });
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
    if (current === "board" && !busy && !sheetOpen && Date.now() - lastLoad > 3000) loadBoard(true);
    if (current === "settings") renderNotifications();
  }
  document.addEventListener("visibilitychange", refreshSoon);
  window.addEventListener("focus", refreshSoon);
  window.addEventListener("online", refreshSoon);

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
