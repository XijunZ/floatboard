
  var BATCH_MAX = 100;
  var BATCH_BYTES = 60000;
  var SENT_KEEP = 200;
  var UNDO_MS = 8000;
  var STEP_NAMES = { todo: "To do", doing: "Doing", watch: "Watch", done: "Done" };

  function viewBoard(board, actions) {
    var cards = ((board && Array.isArray(board.cards)) ? board.cards : []).map(function (c) { return Object.assign({}, c); });
    var addsShown = {};
    cards.forEach(function (c) { if (c.action_id) addsShown[c.action_id] = true; });
    var temp = 0;
    var hidden = {};
    (actions || []).forEach(function (a) {
      // Delete hides the card until the Mac has deleted it; a later restore (Undo after it was sent) shows it again.
      if (a.action === "delete") { hidden[a.card_id] = true; return; }
      if (a.action === "restore") { delete hidden[a.card_id]; return; }
      if (a.action === "add") {
        if (addsShown[a.id]) return;
        temp += 1;
        var same = cards.filter(function (c) { return c.group === a.group && c.color; })[0];
        cards.push({ id: -1000000 - temp, pending: true, action_id: a.id, title: a.title, group: a.group || "", status: "todo",
          color: same ? same.color : null,
          importance: 0, due: null, has_time: false, link: null, done_at: null, status_at: a.made_at, queued: true });
        return;
      }
      for (var i = 0; i < cards.length; i++) {
        var c = cards[i];
        if (c.id === a.card_id && !c.pending && (a.action === "link_email" || a.action === "unlink_email")) {
          if (a.action === "link_email") c.email = "user"; else delete c.email;
          c.queued = true;
          break;
        }
        if (c.id === a.card_id && !c.pending) {
          if (c.status !== a.action) c.done_at = a.action === "done" ? a.made_at : null;
          c.status = a.action;
          c.status_at = a.made_at;
          c.queued = true;
          break;
        }
      }
    });
    cards = cards.filter(function (c) { return !hidden[c.id]; });
    return Object.assign({}, board || {}, { cards: cards });
  }

  function byteLength(s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      n += c < 0x80 ? 1 : c < 0x800 ? 2 : (c >= 0xd800 && c <= 0xdfff) ? 2 : 3;
    }
    return n;
  }

  function takeBatch(actions, sentAt) {
    var out = [];
    var size = 40;
    for (var i = 0; i < (actions || []).length && out.length < BATCH_MAX; i++) {
      var a = actions[i];
      var item = { id: a.id, made_at: a.made_at, action: a.action };
      if (a.action === "add") { item.title = a.title; if (a.group) item.group = a.group; } else item.card_id = a.card_id;
      if (a.action === "link_email") { item.message_id = a.message_id; item.gmail_id = a.gmail_id; item.account = a.account; item.sent_at = a.sent_at || null; }
      if (a.action === "delete" && a.teach) item.teach = a.teach;
      var n = byteLength(JSON.stringify(item)) + 1;
      if (out.length && size + n > BATCH_BYTES) break;
      size += n;
      out.push(item);
    }
    return { sent_at: sentAt, actions: out };
  }

  // Before a batch goes, its actions are marked as sent at least once (kept on this phone, never sent): the engine may take
  // them even if its answer is lost, so a delete marked so is never taken back locally (see undoDeleteStep).
  function markAttempted(actions, batch) {
    var ids = {};
    ((batch && batch.actions) || []).forEach(function (a) { ids[a.id] = true; });
    return (actions || []).map(function (a) { return ids[a.id] && !a.attempted ? Object.assign({}, a, { attempted: true }) : a; });
  }

  function afterSend(actions, result) {
    var gone = {};
    var dropped = 0;
    ((result && result.accepted) || []).forEach(function (id) { gone[id] = true; });
    ((result && result.dropped) || []).forEach(function (d) { if (d && d.id) { gone[d.id] = true; dropped += 1; } });
    ((result && result.superseded) || []).forEach(function (id) { gone[id] = true; });
    return { actions: (actions || []).filter(function (a) { return !gone[a.id]; }), dropped: dropped };
  }

  // send(body) resolves with the engine's answer or rejects with an error carrying .status. Only a 400 splits the batch:
  // 429, other errors and no connection go up unchanged (the queue stays and is retried with back-off).
  async function sendBatch(body, send, now) {
    try {
      return { results: [await send(body)], rejected: [] };
    } catch (e) {
      if (!e || e.status !== 400) throw e;
    }
    var results = [];
    var rejected = [];
    for (var i = 0; i < body.actions.length; i++) {
      try {
        results.push(await send({ sent_at: now(), actions: [body.actions[i]] }));
      } catch (e) {
        if (!e || e.status !== 400) throw e;
        rejected.push(body.actions[i].id);
      }
    }
    return { results: results, rejected: rejected };
  }

  function rememberSent(sentIds, ids) {
    var list = (sentIds || []).concat(ids || []);
    return list.length > SENT_KEEP ? list.slice(list.length - SENT_KEEP) : list;
  }

  function noticeSuperseded(sentIds, superseded) {
    var set = {};
    (superseded || []).forEach(function (id) { set[id] = true; });
    var hit = 0;
    var keep = (sentIds || []).filter(function (id) { if (set[id]) { hit += 1; return false; } return true; });
    return { sentIds: keep, count: hit };
  }

  function retryDelay(failures) {
    var n = Math.max(0, (failures || 1) - 1);
    return Math.min(300000, 5000 * Math.pow(2, Math.min(n, 10)));
  }

  function clock(d) {
    return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
  }

  function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  }

  // s: { waiting: queued count, offline: bool, lastSync: ms or 0, now: ms }
  function statusText(s) {
    var waiting = s.waiting || 0;
    var changes = waiting === 1 ? "1 change waiting" : waiting + " changes waiting";
    if (s.offline) return waiting ? "Offline, " + changes : s.lastSync ? "Offline. " + lastSyncedText(s.lastSync, s.now) : "Offline";
    if (waiting) return changes;
    if (!s.lastSync) return "";
    if (s.now - s.lastSync < 120000) return "Synced";
    return lastSyncedText(s.lastSync, s.now);
  }

  function lastSyncedText(at, now) {
    var d = new Date(at);
    var n = new Date(now);
    if (sameDay(d, n)) return "Last synced " + clock(d);
    var y = new Date(n.getFullYear(), n.getMonth(), n.getDate() - 1);
    if (sameDay(d, y)) return "Last synced yesterday " + clock(d);
    return "Last synced " + d.getDate() + " " + ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getMonth()] + " " + clock(d);
  }

  // A move just queued, kept so it can be undone; null when there is nothing to undo (an add, a pending card, no change).
  function undoFor(card, move, nowMs) {
    if (!card || card.pending || !move || !STEP_NAMES[move.action] || card.id !== move.card_id || card.status === move.action) return null;
    return { card_id: card.id, from: card.status, to: move.action, made_at: move.made_at, at: nowMs };
  }

  function undoLive(u, nowMs) {
    return !!u && nowMs - u.at < UNDO_MS;
  }

  function undoText(u) {
    return u.deleted ? "Deleted" : "Moved to " + (STEP_NAMES[u.to] || u.to);
  }

  // Undo for a delete: "Deleted · Undo" for the same 8 seconds.
  function deleteUndoFor(card, del, nowMs) {
    if (!card || card.pending || !del || del.action !== "delete" || card.id !== del.card_id) return null;
    return { deleted: true, card_id: card.id, del_id: del.id, made_at: del.made_at, at: nowMs };
  }

  // Undo of a delete: never sent (not marked as attempted, not being sent): it is taken out of the queue and nothing is
  // sent. Sent at least once (even if its answer was lost and it is still queued) or on its way: it stays (sending it again
  // is harmless) and a `restore` of its own, made after the delete, brings the task back on the Mac.
  function undoDeleteStep(u, actions, inFlight, id, nowIso) {
    var list = actions || [];
    var waiting = list.some(function (a) { return a.id === u.del_id && !a.attempted; });
    if (waiting && !inFlight) return { actions: list.filter(function (a) { return a.id !== u.del_id; }), restore: null };
    var after = Date.parse(u.made_at) + 1;
    var made = Date.parse(nowIso) >= after ? nowIso : new Date(after).toISOString();
    return { actions: list, restore: { id: id, made_at: made, card_id: u.card_id, action: "restore" } };
  }

  // The move back: a new action of its own, made after the move it undoes (even if the phone's clock went back).
  function undoAction(u, id, nowIso) {
    var after = Date.parse(u.made_at) + 1;
    var made = Date.parse(nowIso) >= after ? nowIso : new Date(after).toISOString();
    return { id: id, made_at: made, card_id: u.card_id, action: u.from };
  }

  function webUrl(v) {
    if (typeof v !== "string" || !v || v.length > 2000) return null;
    try {
      var u = new URL(v);
      return u.protocol === "https:" || u.protocol === "http:" ? v : null;
    } catch (e) { return null; }
  }

  // The links to show as buttons: the card's links (web addresses only), else its single link from an older Mac.
  function cardLinks(c) {
    var list = c && Array.isArray(c.links) ? c.links : (c && c.link ? [{ kind: "link", url: c.link }] : []);
    var out = [];
    list.forEach(function (l) {
      if (!l || !webUrl(l.url)) return;
      var item = { kind: l.kind === "email" || l.kind === "meeting" ? l.kind : "link", url: l.url };
      if (l.label === "calendar") item.label = "calendar";
      out.push(item);
    });
    return out;
  }

  function linkLabel(l) {
    if (l.kind === "meeting") return "Join meeting";
    if (l.kind === "email") return "Open email";
    return l.label === "calendar" ? "Open calendar" : "Open link";
  }

  // "link" (Link an email), "unlink" (Remove email link) or null: never on the sorting's own tasks or a task not on the
  // Mac yet; a task with an email link from an older Mac (which does not say who linked it) gets neither.
  function emailChoice(c) {
    if (!c || c.pending) return null;
    if (c.email === "user") return "unlink";
    if (c.email === "sorting") return null;
    var hasEmail = Array.isArray(c.links) && c.links.some(function (l) { return l && l.kind === "email"; });
    return hasEmail ? null : "link";
  }

  function linkAction(c, hit, id, nowIso) {
    return { id: id, made_at: nowIso, card_id: c.id, action: "link_email", message_id: hit.message_id, gmail_id: hit.gmail_id,
      account: hit.account, sent_at: hit.sent_at || null };
  }

  var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  function hitLines(hit, nowMs) {
    var from = String(hit.from || "");
    var name = from.replace(/<[^>]*>\s*$/, "").replace(/^\s*"|"\s*$/g, "").trim() || from.trim();
    var t = Date.parse(hit.sent_at || hit.date || "");
    var day = "";
    if (!isNaN(t)) {
      var d = new Date(t);
      day = d.getDate() + " " + MONTHS[d.getMonth()] + (d.getFullYear() !== new Date(nowMs).getFullYear() ? " " + d.getFullYear() : "");
    }
    return { subject: String(hit.subject || "").trim() || "(no subject)", detail: [name, day].filter(Boolean).join(" · ") };
  }

  function replacedText(superseded, dropped, rejected) {
    var parts = [];
    if (superseded) parts.push(superseded === 1 ? "1 change was replaced by a newer change on your Mac" : superseded + " changes were replaced by newer changes on your Mac");
    if (dropped) parts.push(dropped === 1 ? "1 change was for a task no longer on your board" : dropped + " changes were for tasks no longer on your board");
    if (rejected) parts.push(rejected === 1 ? "1 change couldn't be sent" : rejected + " changes couldn't be sent");
    return parts.join(". ");
  }

  // ---- planning summary: Today, Rest of this week, Next week

  /** "YYYY-MM-DD" of a time on the calendar of the zone. */
  function dayKey(ms, zone) {
    var p = {};
    new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit" })
      .formatToParts(new Date(ms)).forEach(function (x) { p[x.type] = x.value; });
    return p.year + "-" + p.month + "-" + p.day;
  }

  function keyParts(key) { var p = key.split("-"); return Date.UTC(+p[0], +p[1] - 1, +p[2]); }
  function addDays(key, n) { return new Date(keyParts(key) + n * 86400000).toISOString().slice(0, 10); }
  /** 1 = Monday ... 7 = Sunday. */
  function weekdayOf(key) { var d = new Date(keyParts(key)).getUTCDay(); return d === 0 ? 7 : d; }

  function planBlocks(events, cards, nowMs, zone) {
    var today = dayKey(nowMs, zone);
    var wd = weekdayOf(today);
    var blocks = [{ key: "today", title: "Today", from: today, to: today }];
    if (wd < 7) blocks.push({ key: "week", title: "Rest of this week", from: addDays(today, 1), to: addDays(today, 7 - wd) });
    blocks.push({ key: "next", title: "Next week", from: addDays(today, 8 - wd), to: addDays(today, 14 - wd) });
    var clock = new Intl.DateTimeFormat("en-GB", { timeZone: zone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
    var dayName = function (key) { return ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][weekdayOf(key) - 1]; };

    var evs = (Array.isArray(events) ? events : []).map(function (e) {
      if (!e || typeof e !== "object" || typeof e.title !== "string") return null;
      var s = Date.parse(e.start), n = Date.parse(e.end);
      if (isNaN(s) || isNaN(n)) return null;
      return { e: e, s: s, first: dayKey(s, zone), last: dayKey(n > s ? n - 1 : s, zone),
        series: typeof e.series === "string" && e.series ? e.series : null,
        // Moved in Google (its start is not its original start): never folded into the series row.
        moved: typeof e.original_start === "string" && !isNaN(Date.parse(e.original_start)) && Date.parse(e.original_start) !== s,
        label: typeof e.repeat === "string" && e.repeat ? e.repeat : null };
    }).filter(Boolean).sort(function (a, b) { return a.s - b.s; });

    var open = (Array.isArray(cards) ? cards : []).filter(function (c) {
      return c && typeof c === "object" && c.status !== "done" && typeof c.due === "string";
    }).map(function (c) {
      var key = /^\d{4}-\d{2}-\d{2}$/.test(c.due) ? c.due : (isNaN(Date.parse(c.due)) ? null : dayKey(Date.parse(c.due), zone));
      return key ? { c: c, key: key, at: /^\d{4}-\d{2}-\d{2}$/.test(c.due) ? keyParts(c.due) : Date.parse(c.due) } : null;
    }).filter(Boolean).sort(function (a, b) { return a.at - b.at; });

    // An instance's time of day ("all day" for an all-day one), to tell a series' usual instances from moved ones.
    var timeKey = function (x) { return x.e.all_day ? "all day" : clock.format(new Date(x.s)); };

    return blocks.map(function (b) {
      var meetings = [], bySeries = {};
      var inBlock = evs.filter(function (x) { return !(x.first > b.to || x.last < b.from); });
      // A series' usual time in this block: the time in its label ("weekdays 09:00"), else the time most of its instances
      // here share (the earliest on a tie), counting only instances not moved in Google. A moved instance (its original start
      // differs) or one at another time is never hidden in the series row: it is its own row with its day, time and Join.
      var usual = {};
      inBlock.forEach(function (x) {
        if (!x.series || x.moved || usual[x.series]) return;
        var named = x.label && x.label.match(/\b\d{2}:\d{2}\b/);
        if (named) { usual[x.series] = named[0]; return; }
        var count = {}, best = null;
        inBlock.forEach(function (y) {
          if (y.series !== x.series || y.moved) return;
          var k = timeKey(y);
          count[k] = (count[k] || 0) + 1;
          if (best === null || count[k] > count[best]) best = k;
        });
        usual[x.series] = best;
      });
      inBlock.forEach(function (x) {
        var tasks = Array.isArray(x.e.tasks) ? x.e.tasks.filter(function (t) { return typeof t === "number"; }) : [];
        var video = typeof x.e.video === "string" && /^https:\/\//.test(x.e.video) ? x.e.video : null;
        var day = x.first < b.from ? b.from : x.first;
        var time = x.e.all_day || x.first < b.from ? "" : clock.format(new Date(x.s));
        var when = b.key === "today" ? (time || "All day") : dayName(day) + (time ? " " + time : "");
        if (x.series && !x.moved && timeKey(x) === usual[x.series]) {
          var m = bySeries[x.series];
          if (m) { tasks.forEach(function (t) { if (m.tasks.indexOf(t) < 0) m.tasks.push(t); }); return; }
          // The series row: its rule in words; in Today also the occurrence's actual time.
          m = { id: x.e.id, title: x.e.title, label: x.label || "repeats", when: b.key === "today" ? when : "", tasks: tasks.slice(), video: video, color: x.e.color };
          bySeries[x.series] = m;
          meetings.push(m);
          return;
        }
        meetings.push({ id: x.e.id, title: x.e.title, label: null, when: when, tasks: tasks, video: video, color: x.e.color });
      });
      var due = open.filter(function (t) { return t.key >= b.from && t.key <= b.to; }).map(function (t) { return t.c; });
      // Open tasks due before today lead the Today block, oldest first.
      var overdue = b.key === "today" ? open.filter(function (t) { return t.key < today; }).map(function (t) { return t.c; }) : [];
      return { key: b.key, title: b.title, from: b.from, to: b.to, meetings: meetings, tasks: due, overdue: overdue };
    });
  }

