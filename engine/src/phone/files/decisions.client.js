  // ------------------------------------------------------------ Decisions (More › Decisions): the screen
  // Read-only list from the Mac's copy (cached for offline reading, per account), plus two actions: answer a review and
  // "Not a decision". Actions queue in localStorage with their own id and time and are sent when online.

  var DEC_KEY = "floatboard.decisions";          // { account, decisions, updated }
  var DEC_QUEUE_KEY = "floatboard.decisions.queue"; // { account, actions }
  var decisions = null;
  var decQueue = { account: null, actions: [] };
  var decisionsShown = false;
  var decWaiting = 0;

  // The account /app/api/me confirmed for this session (null until it answers).
  function confirmedAccount() { return (me && me.account) || null; }

  // The cached copy and queue, each under the account it was made for. Shown before /me answers (offline reading), but the
  // queue is sent only once /me confirms that same account; anything of another confirmed account is dropped.
  function loadDecisionCache() {
    var c = load(DEC_KEY), q = load(DEC_QUEUE_KEY), acc = confirmedAccount();
    decisions = c && typeof c.account === "string" && (!acc || c.account === acc) ? c : null;
    decQueue = q && typeof q.account === "string" && Array.isArray(q.actions) && (!acc || q.account === acc) ? q
      : { account: decisions ? decisions.account : acc, actions: [] };
    if (!decQueue.account) decQueue.account = acc;
  }

  function saveDecQueue() { store(DEC_QUEUE_KEY, decQueue.actions.length ? decQueue : null); }

  // Signing out or another account: drop what this phone holds for Decisions.
  function dropDecisions() {
    decisions = null;
    decQueue = { account: null, actions: [] };
    store(DEC_KEY, null);
    store(DEC_QUEUE_KEY, null);
  }

  // Shows or hides the Decisions screen inside More (called by render()).
  function decisionsView(moreOn) {
    if (!moreOn) decisionsShown = false;
    $("more").hidden = !moreOn || decisionsShown;
    $("decisions").hidden = !moreOn || !decisionsShown;
  }

  async function openDecisions() {
    decisionsShown = true;
    loadDecisionCache();
    render();
    renderDecisions();
    window.scrollTo(0, 0);
    await syncDecisions();
  }

  // Sends the queue when the confirmed account is the one it was made under. The engine checks that account again when
  // it stores them (409 for another account: the queue is held, never sent elsewhere). One send at a time.
  var decSending = false;
  async function sendDecisionQueue() {
    var body = decisionSendBody(decQueue, confirmedAccount());
    if (!body || decSending) return;
    decSending = true;
    var stamp = sessionStamp();   // the shared session check (app.client.js)
    try {
      var r = await api("/app/api/decisions/action", { method: "POST", body: body });
      if (sameSession(stamp, r.account) && r.account === body.account) {
        decQueue.actions = decisionQueueAfter(decQueue.actions, r.accepted || []);
        saveDecQueue();
      }
    } catch (e) {
      if (e instanceof SignedOut) throw e;
      if (e && e.status === 400 && decQueue.actions.length) {   // a malformed action would block the queue: drop it
        decQueue.actions = decQueue.actions.slice(1);
        saveDecQueue();
      }
      // 409 (another account now) and offline: held for later.
    } finally { decSending = false; }
  }

  // Reconnecting, coming back to the front, or a board sync that worked: try the waiting queue again (it is loaded from
  // storage if the Decisions screen was never opened in this session).
  function retryDecisionQueue() {
    if (!decQueue.actions.length) loadDecisionCache();
    if (!decQueue.actions.length) return;
    sendDecisionQueue().then(function () { if (decisionsShown) renderDecisions(); }).catch(function () { /* signed out: the next sync shows Sign in */ });
  }
  window.addEventListener("online", retryDecisionQueue);
  document.addEventListener("visibilitychange", function () { if (document.visibilityState === "visible") retryDecisionQueue(); });

  async function syncDecisions() {
    try {
      await sendDecisionQueue();
      var stamp = sessionStamp();
      var b = await api("/app/api/decisions");
      if (!sameSession(stamp, typeof b.account === "string" ? b.account : null)) { renderDecisions(); return; }   // signed out or switched meanwhile
      var acc = typeof b.account === "string" ? b.account : confirmedAccount();
      if (!acc || (confirmedAccount() && acc !== confirmedAccount())) { renderDecisions(); return; }   // not this session's account
      decisions = { account: acc, decisions: Array.isArray(b.decisions) ? b.decisions : [], updated: b.updated || null };
      decWaiting = b.waiting || 0;
      store(DEC_KEY, decisions);
    } catch (e) {
      if (e instanceof SignedOut) { showSignIn(); return; }
    }
    renderDecisions();
  }

  // Queues an action under `account` (the account its form or sheet was opened in; otherwise the confirmed one or the cached
  // copy's). True only once it is kept on this phone; false: nothing was queued (the caller keeps its form open).
  function queueDecision(a, account) {
    if (!a) return false;
    var acc = account || confirmedAccount() || (decisions && decisions.account) || null;
    if (!acc) { toast("Sign in again to do this."); return false; }
    if (decQueue.account !== acc) loadDecisionCache();   // a queue this phone already holds (screen not opened yet) is kept
    var next = decisionEnqueue(decQueue, a, acc);
    if (!next) { toast("Changes of another account are still waiting on this phone. Sign in to it, or sign out, first."); return false; }
    if (!storeDurable(DEC_QUEUE_KEY, next)) return false;
    decQueue = next;
    renderDecisions();
    syncDecisions();
    return true;
  }

  function renderDecisions() {
    var box = $("decisions-list");
    if (!box) return;
    box.replaceChildren();
    var list = decisions ? decisions.decisions : [];
    var s = decisionSections(list, decQueue.actions);
    var status = [decisions && decisions.updated ? "From your Mac, " + new Date(decisions.updated).toLocaleString() : "Waiting for your Mac to send Decisions.",
      decisionsWaiting(decQueue.actions.length + decWaiting)].filter(Boolean).join(" · ");
    $("decisions-status").textContent = status;
    var any = false;
    [["Reviews due", s.due], ["This week", s.week], ["Maybe", s.maybe], ["Earlier", s.earlier]].forEach(function (pair) {
      if (!pair[1].length) return;
      any = true;
      box.appendChild(el("h2", "dec-h", pair[0]));
      pair[1].forEach(function (d) { box.appendChild(decisionRow(d)); });
    });
    if (!any) box.appendChild(el("p", "empty", "No decisions yet. Your Mac finds them in your jots each Sunday."));
  }

  function decisionRow(d) {
    var b = el("button", "dec-row");
    b.type = "button";
    var top = el("span", "dec-top");
    top.appendChild(el("span", "dec-id", d.id));
    top.appendChild(el("span", "dec-text", d.text));
    b.appendChild(top);
    b.appendChild(el("span", "dec-sub", (d.status === "maybe" ? "Maybe · " : "") + decisionDetail(d)));
    b.addEventListener("click", function () { decisionSheet(d); });
    return b;
  }

  function decisionSheet(d) {
    var origin = sessionStamp();
    openSheet(function (sheet) {
      sheet.appendChild(el("h3", null, d.text));
      sheet.appendChild(el("p", "sub", d.id + " · " + decisionDetail(d) + " · " + (d.status === "maybe" ? "Maybe" : d.status)));
      sheet.appendChild(el("p", "sub", "Decided: " + (d.decided || "unknown")));
      if (d.quote) sheet.appendChild(el("p", "dec-quote", "“" + d.quote + "” (" + d.source + ")"));
      sheet.appendChild(el("p", "sub", "Why: " + (d.why || "not recorded")));
      sheet.appendChild(el("p", "sub", decisionPrediction(d)));
      if (d.tags && d.tags.length) sheet.appendChild(el("p", "sub", "Tags: " + d.tags.join(", ")));
      if (d.people && d.people.length) sheet.appendChild(el("p", "sub", "People: " + d.people.join(", ")));
      if (d.review === "due") {
        var r = el("button", "btn", "Answer review");
        r.addEventListener("click", function () { reviewSheet(d); });
        sheet.appendChild(r);
      } else if (d.review_due && d.review === "scheduled") {
        sheet.appendChild(el("p", "sub", "Review " + d.review_due));
      }
      if (canDismiss(d)) {
        var n = el("button", "btn secondary", "Not a decision");
        n.addEventListener("click", function () {
          if (!sameSession(origin)) { closeSheet(); toast("You changed account, so nothing was marked."); return; }
          if (!queueDecision(notDecisionAction(d, newId(), new Date().toISOString()), origin.account)) return;
          closeSheet();
          toast("Marked not a decision. Your Mac adds it to the Decisions rulebook.");
        });
        sheet.appendChild(n);
      }
      sheet.appendChild(el("p", "sub hint", "Edit decisions on your Mac."));
    });
  }

  function reviewSheet(d) {
    var origin = sessionStamp();
    openSheet(function (sheet) {
      sheet.appendChild(el("h3", null, "Review " + d.id));
      sheet.appendChild(el("p", "dec-quote", d.text));
      sheet.appendChild(el("p", "dec-expected", decisionPrediction(d)));
      var form = el("form", "dec-form");
      var label1 = el("label", null, "What happened?");
      var a1 = el("textarea"); a1.rows = 3; a1.maxLength = 4000; a1.id = "dec-happened"; label1.htmlFor = "dec-happened";
      var label2 = el("label", null, "Was the thinking sound?");
      var a2 = el("textarea"); a2.rows = 3; a2.maxLength = 4000; a2.id = "dec-sound"; label2.htmlFor = "dec-sound";
      var save = el("button", "btn", "Save review"); save.type = "submit";
      [label1, a1, label2, a2, save].forEach(function (x) { form.appendChild(x); });
      form.addEventListener("submit", function (e) {
        e.preventDefault();
        var act = reviewAction(d, a1.value, a2.value, newId(), new Date().toISOString());
        if (!act) { toast("Write what happened first."); return; }
        if (!sameSession(origin)) { closeSheet(); toast("You changed account, so this review was not saved."); return; }
        if (!queueDecision(act, origin.account)) { toast("Couldn't keep this review on the phone. Your words are still here; try Save again."); return; }
        closeSheet();
        toast("Review saved. Your Mac keeps it as a jot.");
      });
      sheet.appendChild(form);
    });
  }

  // Make decision from a jot (Jots' sheet, only while Decisions is on): the 4-field form on the phone, filled by code at
  // once, then by Claude (shared fill_form job) in the fields not touched. Save queues it; the Mac records it on its next
  // sync, linked to the jot.
  function decisionForm(selection, source, context) {
    var form = decisionFormStart(selection), touched = {};
    var origin = sessionStamp();   // the account and session the form belongs to (shared session check, app.client.js)
    openSheet(function (sheet) {
      sheet.appendChild(el("h3", null, "Make decision"));
      var f = el("form", "dec-form");
      var fields = {};
      function area(key, label, rows, max) {
        var l = el("label", null, label), t = el("textarea");
        t.rows = rows; t.maxLength = max; t.id = "dec-make-" + key; l.htmlFor = t.id; t.value = form[key];
        t.addEventListener("input", function () { touched[key] = true; });
        f.appendChild(l); f.appendChild(t); fields[key] = t;
      }
      function choice(key, label, options) {
        var l = el("label", null, label), c = el("select");
        c.id = "dec-make-" + key; l.htmlFor = c.id;
        options.forEach(function (o) { var op = el("option", null, o[1]); op.value = o[0]; c.appendChild(op); });
        c.value = form[key];
        c.addEventListener("change", function () { touched[key] = true; });
        f.appendChild(l); f.appendChild(c); fields[key] = c;
      }
      area("text", "Decision", 2, 300);
      area("why", "Why", 2, 500);
      area("expected", "Expected outcome", 2, 500);
      choice("confidence", "Confidence", [["", "Not recorded"], ["low", "Low"], ["medium", "Medium"], ["high", "High"]]);
      choice("type", "Type", [["operational", "Operational"], ["strategic", "Strategic"], ["investment", "Investment"]]);
      var wait = el("p", "sub", "Claude is filling in the form…");
      wait.setAttribute("role", "status");
      var save = el("button", "btn", "Save decision"); save.type = "submit";
      f.appendChild(wait); f.appendChild(save);
      if (selection) sheet.appendChild(el("p", "dec-quote", "“" + String(selection).slice(0, 600) + "”"));
      sheet.appendChild(f);
      f.addEventListener("submit", function (e) {
        e.preventDefault();
        Object.keys(fields).forEach(function (k) { form[k] = fields[k].value; });
        var act = makeDecisionAction(form, selection, source, newId(), new Date().toISOString());
        if (!act) { toast("Write the decision first."); return; }
        if (!sameSession(origin)) {   // signed out or another account since the form opened: never saved under it
          closeSheet();
          toast("You changed account, so this decision was not saved.");
          return;
        }
        if (!queueDecision(act, origin.account)) { toast("Couldn't keep this decision on the phone. Your words are still here; try Save again."); return; }
        closeSheet();
        toast("Decision saved. Your Mac records it on its next sync.");
      });
      api("/app/api/decisions/fill", { method: "POST", body: { selection: String(selection || "").slice(0, 8000), context: String(context || "").slice(0, 8000) } })
        .then(function (answer) {
          if (!fields.text.isConnected || !sameSession(origin)) return;   // the sheet was closed, or another account now
          Object.keys(fields).forEach(function (k) { form[k] = fields[k].value; });
          var filled = decisionFormFill(form, touched, answer);
          Object.keys(fields).forEach(function (k) { if (!touched[k]) fields[k].value = filled[k]; });
          wait.textContent = "Filled in by Claude from your words. Check it before saving.";
        })
        .catch(function () { if (fields.text.isConnected) wait.textContent = "Fill in the form yourself (Claude isn't available right now)."; });
    });
  }

  $("more-decisions").addEventListener("click", openDecisions);
  $("decisions-back").addEventListener("click", function () { decisionsShown = false; render(); window.scrollTo(0, 0); });
