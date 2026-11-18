  // ------------------------------------------------------------ Decisions (More › Decisions): pure parts, tested on their own

  var DECISION_TYPES = { operational: "Operational", strategic: "Strategic", investment: "Investment" };

  // The list as the phone shows it: Reviews due, This week, Maybe, Earlier. Queued actions show at once: a "Not a decision"
  // hides the decision, an answered review is no longer due.
  function decisionSections(list, queue) {
    var gone = {}, reviewed = {};
    (queue || []).forEach(function (a) {
      if (a.action === "not_decision") gone[a.decision] = true;
      if (a.action === "review") reviewed[a.decision] = true;
    });
    var out = { due: [], week: [], maybe: [], earlier: [] };
    (Array.isArray(list) ? list : []).forEach(function (d) {
      if (!d || typeof d.id !== "string" || gone[d.id]) return;
      var x = reviewed[d.id] && d.review === "due" ? Object.assign({}, d, { review: "done" }) : d;
      if (x.review === "due") out.due.push(x);
      else if (x.status === "maybe") out.maybe.push(x);
      else if (x.this_week) out.week.push(x);
      else out.earlier.push(x);
    });
    return out;
  }

  // "Not a decision" is offered on this week's decisions and on Maybe ones.
  function canDismiss(d) { return !!d && (d.this_week === true || d.status === "maybe"); }

  function reviewAction(d, happened, sound, id, nowIso) {
    happened = String(happened || "").trim(); sound = String(sound || "").trim();
    if (!happened && !sound) return null;
    return { id: id, decision: d.id, action: "review", happened: happened, sound: sound, made_at: nowIso };
  }

  function notDecisionAction(d, id, nowIso) { return { id: id, decision: d.id, action: "not_decision", made_at: nowIso }; }

  function decisionQueueAfter(queue, accepted) {
    var done = {};
    (accepted || []).forEach(function (id) { done[id] = true; });
    return (queue || []).filter(function (a) { return !done[a.id]; });
  }

  function decisionDetail(d) {
    var parts = [DECISION_TYPES[d.type] || "Operational", "recorded " + d.recorded];
    if (d.found_by === "claude") parts.push("found by Claude");
    return parts.join(" · ");
  }

  // Predictions are never guessed: "not recorded" until the owner adds them, then "added later" when added after recording.
  function decisionPrediction(d) {
    var e = "Expected outcome: " + (d.expected ? d.expected + (d.expected_later ? " (added later)" : "") : "not recorded");
    if (!d.confidence) return e;
    return e + " · Confidence: " + d.confidence + (d.confidence_later ? " (added later)" : "");
  }

  function decisionsWaiting(n) { return n > 0 ? n + (n === 1 ? " change" : " changes") + " waiting for your Mac" : ""; }

  // ------------------------------------------------------------ Make decision on the phone (from a jot)
  // The 4-field form (decision, why, expected outcome, confidence; type smaller) opens filled by code, then Claude's fill
  // (the shared fill_form job) fills only the fields the owner has not touched. Save queues a "make" action; the Mac records it.

  var DECISION_CONFIDENCE = ["", "low", "medium", "high"];

  function decisionFormStart(selection) {
    var line = String(selection || "").split(/\r?\n/).map(function (l) { return l.trim(); }).filter(Boolean)[0] || "";
    return { text: line.slice(0, 300), why: "not recorded", expected: "", confidence: "", type: "operational" };
  }

  // Claude's answer into the fields not touched (touched: { text?, why?, expected?, confidence?, type? }).
  function decisionFormFill(form, touched, answer) {
    var out = Object.assign({}, form), t = touched || {}, a = answer || {};
    if (!t.text && typeof a.decision === "string" && a.decision.trim()) out.text = a.decision.trim().slice(0, 300);
    if (!t.why && typeof a.why === "string" && a.why.trim()) out.why = a.why.trim().slice(0, 500);
    if (!t.expected && typeof a.expected === "string") out.expected = a.expected.trim().slice(0, 500);
    if (!t.confidence && DECISION_CONFIDENCE.indexOf(a.confidence || "") >= 0) out.confidence = a.confidence || "";
    if (!t.type && DECISION_TYPES[a.type]) out.type = a.type;
    return out;
  }

  // The queued action; null when the decision is empty. "not recorded" is sent as no reason.
  function makeDecisionAction(form, quote, source, id, nowIso) {
    var text = String(form && form.text || "").trim().slice(0, 300);
    if (!text) return null;
    var why = String(form.why || "").trim();
    if (why.toLowerCase() === "not recorded") why = "";
    return { id: id, action: "make", text: text, why: why.slice(0, 500), expected: String(form.expected || "").trim().slice(0, 500),
      confidence: DECISION_CONFIDENCE.indexOf(form.confidence || "") >= 0 ? form.confidence || "" : "",
      type: DECISION_TYPES[form.type] ? form.type : "operational", quote: String(quote || "").slice(0, 4000),
      source: /^[A-Za-z0-9:_@.-]{1,80}$/.test(String(source || "")) ? String(source) : "", made_at: nowIso };
  }

  // The queue goes out only once /app/api/me has confirmed the signed-in account and it is the account the queue was made under.
  function decisionQueueSendable(queue, confirmed) {
    return !!(queue && confirmed && queue.account === confirmed && Array.isArray(queue.actions) && queue.actions.length);
  }

  // The next request body: at most 50 actions, with the account the queue was made under (the engine refuses it for any
  // other account, so a stale confirmation can never send them to the wrong one).
  // What goes in one send: the oldest actions, at most 50 and under the engine's 300 KB cap (a long queue goes in several
  // sends). An oldest action too big to send at all is named in `tooBig` (the app drops it with a message), so it can never
  // hold up the queue.
  var DECISION_SEND_BYTES = 250000;
  function decisionBytes(s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) { var c = s.charCodeAt(i); n += c < 0x80 ? 1 : c < 0x800 ? 2 : (c >= 0xd800 && c <= 0xdfff) ? 2 : 3; }
    return n;
  }
  function decisionSendBody(queue, confirmed) {
    if (!decisionQueueSendable(queue, confirmed)) return null;
    var out = [], size = decisionBytes(JSON.stringify({ account: queue.account, actions: [] }));
    for (var i = 0; i < queue.actions.length && out.length < 50; i++) {
      var n = decisionBytes(JSON.stringify(queue.actions[i])) + 1;
      if (size + n > DECISION_SEND_BYTES) {
        if (!out.length) return { account: queue.account, actions: [], tooBig: queue.actions[i].id };
        break;
      }
      out.push(queue.actions[i]); size += n;
    }
    return { account: queue.account, actions: out };
  }

  // The queue with one more action, made under `account` (the account the form or sheet was opened in). Null when there is
  // no account, or when the queue holds another account's waiting changes (never mixed, never overwritten).
  function decisionEnqueue(queue, action, account) {
    if (!action || !account) return null;
    var q = queue && Array.isArray(queue.actions) ? queue : { account: null, actions: [] };
    if (q.actions.length && q.account !== account) return null;
    return { account: account, actions: (q.account === account ? q.actions : []).concat([action]) };
  }
