  // ------------------------------------------------------------ Circle screen (features §10; uses the app's helpers above)
  //
  // The Mac's copy (GET /app/api/circle) is kept for offline reading with the account it belongs to (dropped on sign-out
  // or another account). Taps ("I contacted them", "We talked", "Snooze") go into their own queue, show at once, and are
  // sent with POST /app/api/circle/action. "Draft" asks the engine for a Haiku draft and opens WhatsApp or Gmail with it.

  var CIRCLE_KEY = "floatboard.circle";        // { account, copy, at }
  var CIRCLE_QUEUE_KEY = "floatboard.circleq"; // { account, actions: [...] }
  var circleCopy = null;
  var circleQueue = { account: null, actions: [] };
  var circleQuery = "";
  var CIRCLE_DONE = { contacted: "Marked as contacted", talked: "Marked as talked", snooze: "Snoozed" };

  function circleAccount() { return me ? me.account : shownAccount; }

  function circleLoad() {
    var acc = circleAccount();
    var c = load(CIRCLE_KEY), q = load(CIRCLE_QUEUE_KEY);
    circleCopy = c && c.account === acc ? c.copy : null;
    circleQueue = q && q.account === acc && Array.isArray(q.actions) ? q : { account: acc, actions: [] };
  }

  // Sign-out or another account: everything Circle kept on this phone goes.
  function circleDrop() {
    circleCopy = null;
    circleQueue = { account: null, actions: [] };
    store(CIRCLE_KEY, null);
    store(CIRCLE_QUEUE_KEY, null);
    if (navigator.clearAppBadge) navigator.clearAppBadge().catch(function () { /* no badge support */ });
  }

  // After each board sync: send the queue, then fetch the copy. Quiet on failure (the board's status line covers it).
  var circleSyncing = false;
  async function circleSync() {
    if (!board || !board.modules || !board.modules.circle || circleSyncing) return;
    if (circleQueue.account !== circleAccount()) circleLoad();
    if (circleHash(location.hash)) circleFromHash();   // asks first; acts only on a tap
    circleSyncing = true;
    var asked = sessionStamp();   // the shared session check (app.client.js): a sign-out or another account meanwhile drops the answer
    var still = function (respAccount) { return sameSession(asked, respAccount); };
    try {
      if (circleQueue.actions.length) {
        var sent = circleQueue.actions.slice(0, 50);
        var r = await api("/app/api/circle/action", { method: "POST", body: { actions: sent } });
        if (!still()) return;   // signed out or another account meanwhile: nothing of this answer is kept
        var done = (r.accepted || []).concat((r.dropped || []).map(function (d) { return d.id; }));
        circleQueue.actions = circleQueue.actions.filter(function (a) { return done.indexOf(a.id) < 0; });
        store(CIRCLE_QUEUE_KEY, circleQueue);
      }
      var got = await api("/app/api/circle");
      if (!still(got.account)) return;
      if (got.copy) {
        circleCopy = got.copy;
        // Actions the engine already holds stay shown until the Mac's next copy reflects them.
        store(CIRCLE_KEY, { account: asked.account, copy: circleCopy, at: Date.now() });
      }
    } catch (e) { /* offline or signed out: the copy kept on the phone is shown */ }
    finally { circleSyncing = false; }
    circleRender();
  }

  function circleAct(person, action) {
    var a = circleAction(person, action, newId(), new Date().toISOString());
    circleQueue.account = circleAccount();
    circleQueue.actions.push(a);
    store(CIRCLE_QUEUE_KEY, circleQueue);
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
    meta.appendChild(el("span", null, ({ family: "Family", close: "Close friend", network: "Network" })[p.tier] || ""));
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
    v.due.forEach(function (p) {
      var row = el("div", "card person pp");
      row.appendChild(el("div", "t", p.name));
      var btn = el("button", "btn small", "I contacted them");
      btn.type = "button";
      btn.addEventListener("click", function () { circleAct(p.id, "contacted"); });
      row.appendChild(btn);
      box.appendChild(row);
    });
    $("plan-empty").hidden = true;
  }

  function personSheet(p) {
    openSheet(function (sheet) {
      sheet.appendChild(el("h3", null, p.name));
      sheet.appendChild(el("p", "sub", [({ family: "Family", close: "Close friend", network: "Network" })[p.tier], p.company].concat(p.tags || []).filter(Boolean).join(" · ")));
      var now = Date.now();
      sheet.appendChild(el("p", "sub", "Last talked " + circleAgo(p.last_talked, now) + " · heard from " + circleAgo(p.last_heard, now)
        + " · outreach " + circleAgo(p.last_outreach, now)));
      if (p.snoozed_until) sheet.appendChild(el("p", "sub", "Snoozed until " + circleAgo(p.snoozed_until, now).replace(" ago", "")));
      [["contacted", "I contacted them"], ["talked", "We talked"], ["snooze", "Snooze"]].forEach(function (x) {
        var b = el("button", "btn act", x[1]);
        b.addEventListener("click", function () { closeSheet(); circleAct(p.id, x[0]); });
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
    openSheet(function (sheet) {
      sheet.appendChild(el("h3", null, "Draft to " + p.name));
      var status = el("p", "sub", "Writing a draft from your notes…");
      var text = el("textarea", "draft");
      text.rows = 5;
      text.hidden = true;
      var open = el("button", "btn", p.wa ? "Open in WhatsApp" : "Open in Gmail");
      open.hidden = true;
      open.addEventListener("click", function () {
        var link = draftLink(p, text.value);
        if (link) window.open(link, "_blank", "noopener");
        closeSheet();
      });
      sheet.appendChild(status);
      sheet.appendChild(text);
      sheet.appendChild(open);
      sheet.appendChild(el("p", "hint", "Written by Claude; never sent by itself. Check it before you send."));
      api("/app/api/circle/draft", { method: "POST", body: { person: p.id } }).then(function (r) {
        text.value = r.draft || "";
        text.hidden = false; open.hidden = false;
        status.textContent = "Edit it, then open it in the app to send.";
      }).catch(function (e) { status.textContent = message(e); });
    });
  }

  // A notification button the service worker could not send itself arrives in the address (#circle=contacted:P-12). A link
  // never acts by itself (anyone can make one): it opens a confirm sheet, and only the tap marks the person.
  function circleFromHash() {
    var h = circleHash(location.hash);
    if (!h) return;
    history.replaceState(null, "", location.pathname + location.search);
    var c = circleConfirm(h, circleView(circleCopy, [], Date.now()).people, circleAccount());
    if (!c) return;
    openSheet(function (sheet) {
      sheet.appendChild(el("h3", null, c.text));
      var yes = el("button", "btn", c.text.replace(/\?$/, ""));
      yes.addEventListener("click", function () { closeSheet(); circleAct(c.person, c.action); });
      sheet.appendChild(yes);
    });
  }

  (function circleWire() {
    var q = $("circle-search");
    if (q) q.addEventListener("input", function () { circleQuery = q.value; circleRender(); });
  })();
