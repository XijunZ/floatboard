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
    try {
      var r = await api("/app/api/decisions/action", { method: "POST", body: body });
      if (r.account === body.account) {
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
      var b = await api("/app/api/decisions");
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

  function queueDecision(a) {
    if (!a) return;
    var acc = confirmedAccount() || (decisions && decisions.account) || null;
    if (!acc) { toast("Sign in again to do this."); return; }
    if (decQueue.account !== acc) decQueue = { account: acc, actions: [] };
    decQueue.actions.push(a);
    saveDecQueue();
    renderDecisions();
    syncDecisions();
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
          queueDecision(notDecisionAction(d, newId(), new Date().toISOString()));
          closeSheet();
          toast("Marked not a decision. Your Mac adds it to the Decisions rulebook.");
        });
        sheet.appendChild(n);
      }
      sheet.appendChild(el("p", "sub hint", "Edit decisions on your Mac."));
    });
  }

  function reviewSheet(d) {
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
        queueDecision(act);
        closeSheet();
        toast("Review saved. Your Mac keeps it as a jot.");
      });
      sheet.appendChild(form);
    });
  }

  $("more-decisions").addEventListener("click", openDecisions);
  $("decisions-back").addEventListener("click", function () { decisionsShown = false; render(); window.scrollTo(0, 0); });
