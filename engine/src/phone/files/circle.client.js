  // ------------------------------------------------------------ Circle screen (features §10; uses the app's helpers above)
  //
  // The Mac's copy (GET /app/api/circle) is kept for offline reading with the account it belongs to (dropped on sign-out
  // or another account). Taps ("I contacted them", "We talked", "Snooze") go into their own queue, show at once, and are
  // sent with POST /app/api/circle/action. "Draft" asks the engine for a Haiku draft and opens WhatsApp or Gmail with it.

  var CIRCLE_KEY = "floatboard.circle";        // { account, copy, at }
  var CIRCLE_QUEUE_KEY = "floatboard.circleq"; // { account, actions: [...] }
  var CIRCLE_SEND_BYTES = 30000;
  // Written only by the active tab (round 31); kept (read back) on each change.
  var circleShared = QueueStore(CIRCLE_QUEUE_KEY, load, storeDurable);
  function circleSave() { return tabActive && circleQueue.account ? circleShared.save(circleQueue.account, circleQueue.actions) : false; }
  // The tiers' names, closest first; a tier not listed (a newer Mac) shows no label.
  var CIRCLE_TIERS = { family: "Family", close: "Close friend", friend: "Friend", network: "Network" };               // under the engine's 32 KB cap for /app/api/circle/action
  var circleCopy = null;
  var circleQueue = { account: null, actions: [] };
  var circleQuery = "";
  var CIRCLE_DONE = { contacted: "Marked as contacted", talked: "Marked as talked", snooze: "Snoozed" };

  function circleAccount() { return me ? me.account : shownAccount; }

  function circleLoad() {
    var acc = circleAccount();
    var c = load(CIRCLE_KEY), q = load(CIRCLE_QUEUE_KEY);
    circleCopy = c && c.account === acc ? c.copy : null;
    // This account's queue, with anything parked for it while another account was signed in (round 30).
    circleQueue = { account: acc, actions: acc && tabActive ? circleShared.load(acc) : [] };
  }

  // Sign-out or another account: everything Circle kept on this phone goes. (The session and account a screen or sheet was
  // opened under is the app's shared `sessionStamp()`; a tap made under another one is refused by `sameSession`.)
  function circleDrop() {
    // A Circle sheet left open (a person, a draft, a link's confirm) belongs to the account that is going: closed.
    if (document.querySelector(".sheet[data-circle]")) closeSheet();
    // The outgoing account's waiting changes were parked first (parkAll in app.client.js; nothing is dropped otherwise).
    circleCopy = null;
    circleQueue = { account: null, actions: [] };
    store(CIRCLE_KEY, null);
    if (navigator.clearAppBadge) navigator.clearAppBadge().catch(function () { /* no badge support */ });
  }

  // After each board sync: send the queue, then fetch the copy. Quiet on failure (the board's status line covers it).
  var circleSyncing = false;
  async function circleSync() {
    if (!tabActive) return;   // only the active tab sends (round 31)
    if (!board || !board.modules || !board.modules.circle || circleSyncing) return;
    if (circleQueue.account !== circleAccount()) circleLoad();
    if (circleHash(location.hash)) circleFromHash();   // asks first; acts only on a tap
    circleSyncing = true;
    var asked = sessionStamp();   // the shared session check (app.client.js): a sign-out or another account meanwhile drops the answer
    var still = function (respAccount) { return sameSession(asked, respAccount); };
    try {
      if (circleQueue.actions.length && circleQueue.account) {
        var t = queueTake(circleQueue.actions, 50, CIRCLE_SEND_BYTES, byteLength(JSON.stringify({ account: circleQueue.account, actions: [] })));
        if (t.tooBig) {   // too big for any send: dropped with a message, never holding up the queue
          circleQueue.actions = queueWithout(circleQueue.actions, [t.tooBig]);
          circleSave();
          toast("A Circle change was too big to send and was removed.");
        } else {
          // The queue's own account goes with it: the engine refuses another account's (409; the queue stays here).
          var r;
          try {
            r = await api("/app/api/circle/action", { method: "POST", body: { account: circleQueue.account, actions: t.actions } });
          } catch (e) {
            // A malformed action would block the queue for good: the engine names it (an older engine: the first goes).
            if (e && e.status === 400 && still()) {
              circleQueue.actions = queueAfterRefusal(circleQueue.actions, e.id);
              circleSave();
            }
            throw e;
          }
          if (!still(r.account)) return;   // signed out or another account meanwhile: nothing of this answer is kept
          circleQueue.actions = queueWithout(circleQueue.actions, (r.accepted || []).concat((r.dropped || []).map(function (d) { return d.id; })));
          circleSave();
        }
      }
      var got = await api("/app/api/circle");
      if (!still(got.account)) return;
      if (got.copy) {
        circleCopy = got.copy;
        if (circleHash(location.hash)) circleFromHash();   // a link that waited for the copy (first launch, or after a switch)
        // Actions the engine already holds stay shown until the Mac's next copy reflects them.
        store(CIRCLE_KEY, { account: asked.account, copy: circleCopy, at: Date.now() });
      }
    } catch (e) { /* offline or signed out: the copy kept on the phone is shown */ }
    finally { circleSyncing = false; }
    circleRender();
  }

  // `asked`: when the tap's screen or sheet was opened. A tap from before a sign-out or account switch marks nobody.
  function circleAct(person, action, asked) {
    if (!sameSession(asked)) { closeSheet(); return; }
    var a = circleAction(person, action, newId(), new Date().toISOString());
    var acc = circleAccount();
    if (!acc) { toast("Couldn't save that on this phone. Try again."); return; }
    // Kept on this phone first (read back): shown as done only once it is.
    var next = (circleQueue.account === acc ? circleQueue.actions : []).concat([a]);
    if (!tabActive || !circleShared.save(acc, next)) { toast("Couldn't save that on this phone. Try again."); return; }
    circleQueue = { account: acc, actions: next };
    circleActDone(action);
  }

  function circleActDone(action) {
    toast(CIRCLE_DONE[action]);
    circleRender();
    circleSync();
  }

  function circleRender() {
    var on = !!(board && board.modules && board.modules.circle);
    var v = circleView(circleCopy, circleQueue.actions, Date.now());
    if (navigator.setAppBadge) {
      var n = badgeCount(shown, on ? v.due.length : 0, Date.now());
      (n ? navigator.setAppBadge(n) : navigator.clearAppBadge()).catch(function () { /* no badge support */ });
    }
    circlePlan(on ? v : null);
    var box = $("circle-list");
    if (!box) return;
    box.replaceChildren();
    $("circle-empty").hidden = true;
    if (!circleCopy) {
      $("circle-empty").hidden = false;
      $("circle-empty").textContent = "Waiting for your Mac to send Circle.";
      return;
    }
    if (!circleQuery && v.due.length) {
      box.appendChild(el("h2", null, "Due this week"));
      v.due.forEach(function (p) { box.appendChild(circleRow(p, true)); });
      box.appendChild(el("h2", null, "Everyone"));
    }
    var list = circleSearch(v.people, circleQuery);
    list.forEach(function (p) { box.appendChild(circleRow(p, false)); });
    if (!list.length) { $("circle-empty").hidden = false; $("circle-empty").textContent = "No one matches."; }
  }

  function circleRow(p, dueRow) {
    var b = el("button", "card person");
    b.type = "button";
    b.appendChild(el("div", "t", p.name));
    var meta = el("div", "meta");
    meta.appendChild(el("span", null, CIRCLE_TIERS[p.tier] || ""));
    meta.appendChild(el("span", null, "talked " + circleAgo(p.last_talked, Date.now())));
    if (p.waiting) meta.appendChild(el("span", "late", CIRCLE_DONE[p.waiting]));
    else if (p.due) meta.appendChild(el("span", "late", "Due"));
    (p.context || []).forEach(function (x) { meta.appendChild(el("span", null, x)); });
    b.appendChild(meta);
    b.addEventListener("click", function () { personSheet(p); });
    return b;
  }

  // Plan: "Due to contact" with one tap "I contacted them".
  function circlePlan(v) {
    var box = $("plan-circle");
    if (!box) return;
    box.replaceChildren();
    box.hidden = !v || !v.due.length;
    if (box.hidden) return;
    box.appendChild(el("h2", null, "Due to contact"));
    var asked = sessionStamp();
    v.due.forEach(function (p) {
      var row = el("div", "card person pp");
      row.appendChild(el("div", "t", p.name));
      var btn = el("button", "btn small", "I contacted them");
      btn.type = "button";
      btn.addEventListener("click", function () { circleAct(p.id, "contacted", asked); });
      row.appendChild(btn);
      box.appendChild(row);
    });
    $("plan-empty").hidden = true;
  }

  function personSheet(p) {
    var asked = sessionStamp();
    openSheet(function (sheet) {
      sheet.dataset.circle = "1";
      sheet.appendChild(el("h3", null, p.name));
      sheet.appendChild(el("p", "sub", [CIRCLE_TIERS[p.tier] || "", p.company].concat(p.tags || []).filter(Boolean).join(" · ")));
      var now = Date.now();
      sheet.appendChild(el("p", "sub", "Last talked " + circleAgo(p.last_talked, now) + " · heard from " + circleAgo(p.last_heard, now)
        + " · outreach " + circleAgo(p.last_outreach, now)));
      if (p.snoozed_until) sheet.appendChild(el("p", "sub", "Snoozed until " + circleAgo(p.snoozed_until, now).replace(" ago", "")));
      [["contacted", "I contacted them"], ["talked", "We talked"], ["snooze", "Snooze"]].forEach(function (x) {
        var b = el("button", "btn act", x[1]);
        b.addEventListener("click", function () { closeSheet(); circleAct(p.id, x[0], asked); });
        sheet.appendChild(b);
      });
      if (p.wa || p.email) {
        var d = el("button", "btn act", "Draft a message");
        d.addEventListener("click", function () { draftSheet(p); });
        sheet.appendChild(d);
      }
      if ((p.whats_new || []).length) {
        sheet.appendChild(el("h4", null, "What's new"));
        p.whats_new.forEach(function (u) {
          var line = el("p", "sub", (u.possible ? "Possible: " : "") + u.title);
          var href = u.url ? safeLink(u.url) : null;
          if (href) { var a = el("a", null, " Open"); a.href = href; a.target = "_blank"; a.rel = "noopener"; line.appendChild(a); }
          sheet.appendChild(line);
        });
      }
      if ((p.open_tasks || []).length) {
        sheet.appendChild(el("h4", null, "Open tasks"));
        p.open_tasks.forEach(function (t) { sheet.appendChild(el("p", "sub", t.title)); });
      }
      if ((p.timeline || []).length) {
        sheet.appendChild(el("h4", null, "Timeline"));
        p.timeline.forEach(function (t) { sheet.appendChild(el("p", "sub", circleAgo(t.at, now) + " · " + t.title)); });
      }
    });
  }

  function draftSheet(p) {
    var asked = sessionStamp();
    openSheet(function (sheet) {
      sheet.dataset.circle = "1";
      sheet.appendChild(el("h3", null, "Draft to " + p.name));
      var status = el("p", "sub", "Writing a draft from your notes…");
      var text = el("textarea", "draft");
      text.rows = 5;
      text.hidden = true;
      var open = el("button", "btn", p.wa ? "Open in WhatsApp" : "Open in Gmail");
      open.hidden = true;
      open.addEventListener("click", function () {
        if (!sameSession(asked)) { closeSheet(); return; }
        var link = draftLink(p, text.value);
        if (link) window.open(link, "_blank", "noopener");
        closeSheet();
      });
      sheet.appendChild(status);
      sheet.appendChild(text);
      sheet.appendChild(open);
      sheet.appendChild(el("p", "hint", "Written by Claude; never sent by itself. Check it before you send."));
      api("/app/api/circle/draft", { method: "POST", body: { person: p.id, account: asked.account } }).then(function (r) {
        if (!sameSession(asked, r.account)) return;   // signed out or another account meanwhile (even in another tab): dropped
        text.value = r.draft || "";
        text.hidden = false; open.hidden = false;
        status.textContent = "Edit it, then open it in the app to send.";
      }).catch(function (e) { status.textContent = message(e); });
    });
  }

  // A notification button the service worker could not send itself arrives in the address (#circle=contacted:P-12). A link
  // never acts by itself (anyone can make one): it opens a confirm sheet, and only the tap marks the person.
  function circleFromHash() {
    var next = circleLinkStep(location.hash, circleCopy, circleAccount());
    if (next.step === "none" || next.step === "wait") return;   // waiting: tried again after the next copy loads
    history.replaceState(null, "", location.pathname + location.search);   // shown now, or it can never be: the address is cleared
    if (next.step === "drop") return;
    var c = next.confirm;
    var asked = sessionStamp();
    openSheet(function (sheet) {
      sheet.dataset.circle = "1";
      sheet.appendChild(el("h3", null, c.text));
      var yes = el("button", "btn", c.text.replace(/\?$/, ""));
      yes.addEventListener("click", function () { closeSheet(); circleAct(c.person, c.action, asked); });
      sheet.appendChild(yes);
    });
  }

  (function circleWire() {
    var q = $("circle-search");
    if (q) q.addEventListener("input", function () { circleQuery = q.value; circleRender(); });
  })();
