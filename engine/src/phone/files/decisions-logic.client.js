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

  // The queue goes out only once /app/api/me has confirmed the signed-in account and it is the account the queue was made under.
  function decisionQueueSendable(queue, confirmed) {
    return !!(queue && confirmed && queue.account === confirmed && Array.isArray(queue.actions) && queue.actions.length);
  }
