  // ------------------------------------------------------------ Jots (docs/superpowers/specs/2026-11-17-jots-design.md §5)
  // Pure functions first (tested on their own: test/jots/jots-phone.test.ts), then the screen (JotsScreen), which the app
  // script creates with its helpers.

  var JOT_DAYS = 30;
  var JOT_TITLE = 120;

  // The list the phone shows: the engine's copy plus queued changes (adds as waiting jots, edits applied, deletes hidden,
  // restores shown), added in the last 30 days, newest first.
  function jotsView(cache, queue, nowMs) {
    var byKey = {};
    var list = (Array.isArray(cache) ? cache : []).map(function (j) { var c = Object.assign({}, j); byKey[c.key] = c; return c; });
    (queue || []).forEach(function (a) {
      if (a.op === "add") {
        if (byKey["phone:" + a.id]) return;
        var n = { key: "phone:" + a.id, text: a.text, kind: "jot", source: "phone", tags: [], added: a.made_at, updated: a.made_at, queued: true };
        byKey[n.key] = n;
        list.push(n);
        return;
      }
      var j = byKey[a.key];
      if (!j) return;
      if (a.op === "edit") { j.text = a.text; j.updated = a.made_at; j.queued = true; }
      if (a.op === "delete") j.gone = true;
      if (a.op === "restore") j.gone = false;
    });
    var since = nowMs - JOT_DAYS * 86400000;
    return list.filter(function (j) { return !j.gone && !j.deleted && Date.parse(j.added) >= since; })
      .sort(function (a, b) { return Date.parse(b.added) - Date.parse(a.added) || (a.key < b.key ? -1 : 1); });
  }

  // Every search word in the text or the tags (case ignored); a tag filter ("untagged" for none).
  function jotsFilter(list, query, tag) {
    var words = String(query || "").toLowerCase().split(/\s+/).filter(Boolean);
    return list.filter(function (j) {
      var tags = Array.isArray(j.tags) ? j.tags : [];
      if (tag === "untagged" && tags.length) return false;
      if (tag && tag !== "untagged" && tags.indexOf(tag) < 0) return false;
      var hay = (j.text + " " + tags.join(" ")).toLowerCase();
      return words.every(function (w) { return hay.indexOf(w) >= 0; });
    });
  }

  // The tags seen on the jots, sorted (for the filter).
  function jotTags(list) {
    var seen = {};
    list.forEach(function (j) { (Array.isArray(j.tags) ? j.tags : []).forEach(function (t) { seen[t] = true; }); });
    return Object.keys(seen).sort(function (a, b) { return a.toLowerCase() < b.toLowerCase() ? -1 : 1; });
  }

  function zonedDay(ms, zone) {
    try {
      return new Intl.DateTimeFormat("en-CA", { timeZone: zone || undefined, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(ms));
    } catch (e) { return new Date(ms).toISOString().slice(0, 10); }
  }

  // "Today", "Yesterday", else "Tue 10 Nov", in the Mac's time zone.
  function jotDayLabel(ms, nowMs, zone) {
    var d = zonedDay(ms, zone);
    if (d === zonedDay(nowMs, zone)) return "Today";
    if (d === zonedDay(nowMs - 86400000, zone)) return "Yesterday";
    try {
      var p = {};
      new Intl.DateTimeFormat("en-GB", { timeZone: zone || undefined, weekday: "short", day: "numeric", month: "short" }).formatToParts(new Date(ms))
        .forEach(function (x) { p[x.type] = x.value; });
      return p.weekday + " " + p.day + " " + p.month;
    } catch (e) { return d; }
  }

  function jotTime(ms, zone) {
    try { return new Intl.DateTimeFormat("en-GB", { timeZone: zone || undefined, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(ms)); }
    catch (e) { return ""; }
  }

  // The next request for POST /app/api/jots: the whole queue (it is small: at most 100 actions).
  // One send: the oldest changes, at most 100 and under the engine's 512 KB cap (a long queue goes in several sends). One
  // change is at most 20,000 characters, so a single one always fits.
  var JOT_SEND_BYTES = 400000;
  // At most 100 actions under the engine's cap (the shared queueTake); one too big for any send is named in `tooBig`.
  function takeJotBatch(queue, sentAt) {
    var t = queueTake(queue, 100, JOT_SEND_BYTES, 200);
    return t.tooBig ? { sent_at: sentAt, actions: t.actions, tooBig: t.tooBig } : { sent_at: sentAt, actions: t.actions };
  }

  // Only malformed actions leave the queue without being taken; anything else stays queued and is sent again.
  var JOT_PERMANENT = { "bad id": true, "bad key": true, "unknown op": true, "text is required": true, "text too long": true };
  // Drops what the engine took (accepted) or can never take (malformed) from the queue.
  function afterJotSend(queue, result) {
    var dropped = (result.dropped || []).filter(function (d) { return d && d.id && JOT_PERMANENT[d.reason]; }).map(function (d) { return d.id; });
    return queueWithout(queue, (result.accepted || []).concat(dropped));
  }

  // Sent at least once (named `attempted`, as on the board's queue; a queue saved by an older version says `sent`).
  function jotAttempted(a) { return !!(a && (a.attempted || a.sent)); }

  // Actions about to be sent are marked: if the answer is lost, Undo must not assume they never arrived.
  function markJotsAttempted(queue, ids) {
    var sent = {};
    (ids || []).forEach(function (id) { sent[id] = true; });
    return (queue || []).map(function (a) { return sent[a.id] && !jotAttempted(a) ? Object.assign({}, a, { attempted: true }) : a; });
  }

  // Undo of a delete: one never sent is taken out of the queue; one sent (or being sent; its answer may be lost) stays and a
  // restore made after it is queued, so the jot always comes back.
  function undoJotDelete(queue, del) {
    var q = queue || [];
    var i = -1;
    q.forEach(function (a, n) { if (a.id === del.id) i = n; });
    if (i >= 0 && !jotAttempted(q[i])) return { queue: q.slice(0, i).concat(q.slice(i + 1)), restore: false };
    return { queue: q, restore: true };
  }

  function jotWaitingText(n) { return n === 1 ? "1 jot waiting to sync" : n + " jots waiting to sync"; }

  // Long-press icon shortcuts: "/app/?go=jot" (the writing box) and "/app/?go=plan".
  function launchTarget(search) {
    var m = /[?&]go=([a-z]+)/.exec(search || "");
    return m && (m[1] === "jot" || m[1] === "plan") ? m[1] : null;
  }

  // Share into FloatBoard (Android share target, GET): title, text and link as one text, without repeats; null when not a share.
  function sharedText(search) {
    var q;
    try { q = new URLSearchParams(search || ""); } catch (e) { return null; }
    var parts = [];
    ["share_title", "share_text", "share_url"].forEach(function (k) {
      var v = (q.get(k) || "").trim();
      if (v && parts.every(function (p) { return p.indexOf(v) < 0; })) parts.push(v);
    });
    return parts.length ? parts.join("\n") : null;
  }

  // A task title from selected text: its first non-empty line, at most 120 characters.
  function selectionTitle(text) {
    var line = String(text || "").split(/\r?\n/).map(function (l) { return l.trim(); }).filter(Boolean)[0] || "";
    return line.length > JOT_TITLE ? line.slice(0, JOT_TITLE - 1) + "…" : line;
  }

  // ------------------------------------------------------------ the Jots screen

  // h: the app's helpers { $, el, api, openSheet, closeSheet, toast, store, load, newId, account(), modules(), zone(),
  //   offline(e), SignedOut, addTask(title), sheetOpen() }.
  function JotsScreen(h) {
    var CACHE_KEY = "floatboard.jots";       // { account, jots, at }
    var QUEUE_KEY = "floatboard.jotqueue";   // { account, actions }
    var cache = [];
    var queue = [];
    var syncing = false;
    var lastSel = { text: "", key: null };
    var undoTimer = 0;
    var cancelUndo = null;   // takes the delete-undo bar away (also on an account switch)
    var DRAFT_KEY = "floatboard.jotdraft";   // { account, text }: the writing box's unsaved text, for its own account only
    // Which account the cache and queue belong to. An answer to a request sent before a sign-out or an account change is
    // thrown away (never cached under the new account): the app's shared session check (h.stamp / h.sameSession).
    var heldBy = null;
    var shared = SharedQueue(QUEUE_KEY, h.load, function (k, v) { return (h.storeDurable || function (k2, v2) { h.store(k2, v2); return true; })(k, v); });

    function restore() {
      var acct = h.account();
      var c = h.load(CACHE_KEY), q = h.load(QUEUE_KEY);
      if (acct !== heldBy) { heldBy = acct; syncing = false; }
      cache = c && c.account === acct && Array.isArray(c.jots) ? c.jots : [];
      queue = acct ? shared.load(acct) : [];   // the queue every tab of this phone shares (round 28)
      // The writing box: this account's own draft, or nothing (a draft of another account, or one from before drafts named
      // their account, is never shown).
      var box = h.$("jot-text"), d = h.load(DRAFT_KEY);
      if (box && !box.value) box.value = d && typeof d === "object" && d.account && d.account === acct && typeof d.text === "string" ? d.text : "";
    }
    function saveDraft(text) { h.store(DRAFT_KEY, text && heldBy ? { account: heldBy, text: text } : null); }
    // Saved merged with what other tabs stored (a capture another tab made is never wiped).
    function saveQueue() { if (heldBy) { var out = shared.save(heldBy, queue); if (out) queue = out; } }

    function drop() {
      heldBy = null; syncing = false; cache = []; queue = []; h.store(CACHE_KEY, null); h.store(QUEUE_KEY, null); shared.forget();
      h.store(DRAFT_KEY, null);
      var box = h.$("jot-text");
      if (box) box.value = "";   // the old account's unsaved words leave the screen too
      if (cancelUndo) cancelUndo();
    }

    // Jots: account binding. Before any change is queued, the screen is bound to the account signed in now.
    function bound() { if (h.account() && heldBy !== h.account()) restore(); }

    // The engine takes a phone jot of up to 20,000 characters (as JavaScript counts them). A longer one is never cut: it
    // stays on screen with a message.
    var PHONE_TEXT_MAX = 20000;
    function tooLong(text) {
      if (text.length <= PHONE_TEXT_MAX) return false;
      h.toast("Too long for the phone (" + text.length.toLocaleString() + " of 20,000 characters). Shorten it, or save it on your Mac. Nothing was cut.");
      return true;
    }

    // Queues one change, kept on this phone first (read back): null when it couldn't be kept (storage full or off, or no
    // account), and then nothing is cleared or called saved; the caller keeps the words on screen.
    function queueAction(a) {
      bound();
      a.id = a.id || h.newId();
      a.made_at = a.made_at || new Date().toISOString();
      var saved = heldBy ? shared.save(heldBy, queue.concat([a])) : null;   // merged with other tabs', then read back
      if (!saved) {
        h.toast("Couldn't save on this phone (storage full?). Your text is still here; try again.");
        return null;
      }
      queue = saved;
      render();
      pull();
      return a;
    }

    async function pull() {
      if (syncing || !h.account() || !(h.modules() || {}).jots) return;
      syncing = true;
      var stamp = h.stamp(), acct = stamp.account;
      var current = function () { return h.sameSession(stamp); };
      try {
        var r;
        if (heldBy) queue = shared.merged(heldBy, queue);   // what other tabs queued goes too
        var body = queue.length && heldBy ? takeJotBatch(queue, new Date().toISOString()) : null;
        while (body && body.tooBig) {   // too big for any send: dropped with a message, never holding up the queue
          queue = queueWithout(queue, [body.tooBig]); saveQueue();
          h.toast("A change was too big to send and was removed.");
          body = queue.length ? takeJotBatch(queue, new Date().toISOString()) : null;
        }
        if (body) {
          queue = markJotsAttempted(queue, body.actions.map(function (a) { return a.id; }));
          saveQueue();
          // The queue's own account goes with it: the engine refuses another account's (409; the queue stays here).
          r = await h.api("/app/api/jots", { method: "POST", body: Object.assign({ account: heldBy }, body) });
          if (!h.sameSession(stamp, r.account)) return;   // signed out or another account meanwhile: this answer belongs to nobody here now
          queue = afterJotSend(queue, r);
          saveQueue();
          var lost = (r.superseded || []).length;
          if (lost) h.toast(lost === 1 ? "Your Mac had a newer version; your edit is kept in the jot's history." : "Your Mac had newer versions; your " + lost + " edits are kept in the jots' history.");
        } else {
          r = await h.api("/app/api/jots");
          if (!h.sameSession(stamp, r.account)) return;
        }
        if (Array.isArray(r.jots)) { cache = r.jots; h.store(CACHE_KEY, { account: acct, jots: cache, at: Date.now() }); }
      } catch (e) {
        if (e instanceof h.SignedOut) throw e;
        // Offline or refused: the queue stays and goes with the next sync; the list shows the last copy.
      } finally {
        if (current()) { syncing = false; render(); }
      }
    }

    function shown() { return jotsView(cache, queue, Date.now()); }

    function render() {
      var list = h.$("jot-list");
      if (!list) return;
      var all = shown();
      var tagSel = h.$("jot-tag");
      var current = tagSel.value;
      var tags = jotTags(all);
      tagSel.textContent = "";
      [["", "All tags"]].concat(tags.map(function (t) { return [t, t]; }), [["untagged", "Untagged"]]).forEach(function (o) {
        var opt = h.el("option", null, o[1]);
        opt.value = o[0];
        tagSel.appendChild(opt);
      });
      tagSel.value = current === "untagged" || tags.indexOf(current) >= 0 ? current : "";
      var rows = jotsFilter(all, h.$("jot-search").value, tagSel.value);
      list.textContent = "";
      var zone = h.zone(), lastDay = null;
      rows.forEach(function (j) {
        var ms = Date.parse(j.added);
        var day = jotDayLabel(ms, Date.now(), zone);
        if (day !== lastDay) { list.appendChild(h.el("h2", "jot-day", day)); lastDay = day; }
        var b = h.el("button", "card jot" + (j.queued ? " pending" : ""));
        b.type = "button";
        var body = h.el("div", "body");
        body.appendChild(h.el("div", "t", j.text));
        var meta = h.el("div", "meta");
        meta.appendChild(h.el("span", null, jotTime(ms, zone)));
        if (j.kind === "meeting_notes") meta.appendChild(h.el("span", null, "Meeting notes"));
        if (j.kind === "task_note") meta.appendChild(h.el("span", null, "Task note"));
        var tg = Array.isArray(j.tags) ? j.tags : [];
        if (!tg.length) meta.appendChild(h.el("span", "tag untagged", "untagged"));
        tg.forEach(function (t) { meta.appendChild(h.el("span", "tag", t)); });
        if (j.queued) meta.appendChild(h.el("span", null, "Not synced yet"));
        body.appendChild(meta);
        b.appendChild(body);
        b.addEventListener("click", function () { jotSheet(j); });
        list.appendChild(b);
      });
      h.$("jot-empty").hidden = rows.length > 0;
      h.$("jot-empty").textContent = all.length ? "No jots match." : "No jots in the last 30 days. Write one above.";
      var waiting = queue.length;
      h.$("jot-wait").textContent = waiting ? jotWaitingText(waiting) : "";
    }

    function save() {
      var box = h.$("jot-text");
      var text = box.value.trim();
      if (!text) { box.focus(); return; }
      if (tooLong(text) || !queueAction({ op: "add", text: text })) { saveDraft(box.value); return; }   // kept on screen and as the draft
      box.value = "";
      saveDraft(null);
      h.toast("Saved");
    }

    // Before and after side by side; "Use cleaned" or "Keep mine". Needs a connection.
    async function cleanup(text, use) {
      if (!text.trim()) return;
      var r;
      // Jots: account binding. The answer and "Use cleaned" count only for the account and session that asked:
      // the app's shared session check (h.stamp / h.sameSession), as for sync.
      var stamp = h.stamp();
      var current = function () { return h.sameSession(stamp); };
      try { r = await h.api("/app/api/jots/cleanup", { method: "POST", body: { text: text } }); }
      catch (e) {
        if (e instanceof h.SignedOut) throw e;
        if (current()) h.toast(h.offline(e) ? "Clean up needs a connection." : (e.status === 409 ? "Clean up needs Claude, set up on your Mac." : "Couldn't clean up. Try again."));
        return;
      }
      if (!current()) return;
      h.openSheet(function (sheet) {
        sheet.appendChild(h.el("h3", null, "Clean up"));
        sheet.appendChild(h.el("p", "sub", "Claude fixed grammar and structure only. Your text is kept in the jot's history."));
        var cmp = h.el("div", "jot-compare");
        var a = h.el("div", "jot-side"); a.appendChild(h.el("div", "jot-label", "Yours")); a.appendChild(h.el("div", "jot-full", text));
        var b = h.el("div", "jot-side"); b.appendChild(h.el("div", "jot-label", "Cleaned")); b.appendChild(h.el("div", "jot-full", r.cleaned));
        cmp.appendChild(a); cmp.appendChild(b);
        sheet.appendChild(cmp);
        var ok = h.el("button", "btn", "Use cleaned");
        ok.addEventListener("click", function () { h.closeSheet(); if (current()) use(r.cleaned); });
        var keep = h.el("button", "btn secondary", "Keep mine");
        keep.addEventListener("click", h.closeSheet);
        sheet.appendChild(ok);
        sheet.appendChild(keep);
      });
    }

    function remember(textEl, key) {
      document.addEventListener("selectionchange", function () {
        var s = window.getSelection ? window.getSelection() : null;
        if (!s || !s.rangeCount || !textEl.isConnected) return;
        if (!textEl.contains(s.anchorNode)) return;
        var t = s.toString();
        if (t.trim()) lastSel = { text: t, key: key };
      });
    }

    function selectionOr(j) { return lastSel.key === j.key && lastSel.text.trim() ? lastSel.text : j.text; }

    function jotSheet(j) {
      lastSel = { text: "", key: null };
      h.openSheet(function (sheet) {
        var full = h.el("div", "jot-full");
        full.textContent = j.text;
        sheet.appendChild(full);
        remember(full, j.key);
        var meta = [jotDayLabel(Date.parse(j.added), Date.now(), h.zone()) + " " + jotTime(Date.parse(j.added), h.zone())];
        if (j.kind === "meeting_notes") meta.push("Meeting notes");
        if (j.kind === "task_note") meta.push("Task note");
        meta.push((j.tags || []).length ? j.tags.join(", ") : "untagged");
        sheet.appendChild(h.el("p", "sub", meta.join(" · ")));
        sheet.appendChild(h.el("p", "hint muted small", "Select words first to make a task or decision from just those."));
        var mk = h.el("button", "btn act", "Make task");
        mk.addEventListener("click", function () {
          var text = selectionOr(j);
          if (!queueAction({ op: "make_task", key: j.key, jot_added: j.added, text: text.slice(0, 2000) })) return;
          h.closeSheet();
          h.toast("Task \"" + selectionTitle(text) + "\" goes to your Mac.");
        });
        sheet.appendChild(mk);
        if ((h.modules() || {}).decisions) {
          var md = h.el("button", "btn act", "Make decision");
          md.addEventListener("click", function () {
            var text = selectionOr(j);
            h.closeSheet();
            h.makeDecision(text.slice(0, 8000), j.key, j.text);   // Decisions' form on the phone (files/decisions.client.js)
          });
          sheet.appendChild(md);
        }
        var ed = h.el("button", "btn act", "Edit");
        ed.addEventListener("click", function () { editSheet(j); });
        sheet.appendChild(ed);
        var cl = h.el("button", "btn act", "Clean up");
        cl.addEventListener("click", function () {
          cleanup(j.text, function (cleaned) {
            if (queueAction({ op: "edit", key: j.key, jot_added: j.added, text: cleaned })) h.toast("Cleaned. Your text is in its history.");
          });
        });
        sheet.appendChild(cl);
        var del = h.el("button", "btn act danger", "Delete");
        del.addEventListener("click", function () { remove(j); });
        sheet.appendChild(del);
      });
    }

    function editSheet(j) {
      h.openSheet(function (sheet) {
        sheet.appendChild(h.el("h3", null, "Edit jot"));
        var box = h.el("textarea", "jot-box");
        box.value = j.text;
        box.rows = 8;
        sheet.appendChild(box);
        var ok = h.el("button", "btn", "Save");
        ok.addEventListener("click", function () {
          var t = box.value.trim();
          if (!t || t === j.text) { h.closeSheet(); return; }
          if (tooLong(t) || !queueAction({ op: "edit", key: j.key, jot_added: j.added, text: t })) return;   // the sheet and its text stay
          h.closeSheet();
          h.toast("Saved");
        });
        sheet.appendChild(ok);
        setTimeout(function () { box.focus(); }, 50);
      });
    }

    function remove(j) {
      var a = queueAction({ op: "delete", key: j.key, jot_added: j.added });
      if (!a) return;
      h.closeSheet();
      try { if (navigator.vibrate) navigator.vibrate(30); } catch (e) { /* no vibration */ }
      var bar = h.$("undo");
      h.$("undo-text").textContent = "Jot deleted";
      bar.hidden = false;
      var btn = h.$("undo-btn");
      if (cancelUndo) cancelUndo();
      var undo = function () {
        cancel();
        var cur = queue.filter(function (x) { return x.id === a.id; })[0] || a;
        var step = undoJotDelete(queue, jotAttempted(cur) || syncing ? Object.assign({}, cur, { attempted: true }) : cur);
        if (step.restore) queueAction({ op: "restore", key: j.key, jot_added: j.added });
        else { queue = step.queue; saveQueue(); render(); }
      };
      var cancel = function () { btn.removeEventListener("click", undo, true); bar.hidden = true; clearTimeout(undoTimer); cancelUndo = null; };
      cancelUndo = cancel;
      btn.addEventListener("click", undo, true);
      clearTimeout(undoTimer);
      undoTimer = setTimeout(cancel, 8000);
    }

    // A share from another app: save it as a jot, or as a task.
    function shareSheet(text, taskOnly) {
      h.openSheet(function (sheet) {
        sheet.appendChild(h.el("h3", null, "Save to FloatBoard"));
        var box = h.el("textarea", "jot-box");
        box.value = text;
        box.rows = 5;
        sheet.appendChild(box);
        var asJot = h.el("button", "btn", "Save as jot");
        asJot.addEventListener("click", function () {
          if (!box.value.trim()) return;
          var shared = box.value.trim();
          if (tooLong(shared) || !queueAction({ op: "add", text: shared })) return;   // the share stays open with its text
          h.closeSheet();
          h.toast("Saved as a jot");
        });
        var asTask = h.el("button", "btn secondary", "Save as task");
        asTask.addEventListener("click", function () {
          var title = selectionTitle(box.value);
          if (!title) return;
          h.closeSheet();
          h.addTask(title);
        });
        if (!taskOnly) sheet.appendChild(asJot);
        sheet.appendChild(asTask);
      });
    }

    function wire() {
      var box = h.$("jot-text");
      box.addEventListener("input", function () { bound(); saveDraft(box.value); });
      h.$("jot-save").addEventListener("click", save);
      h.$("jot-clean").addEventListener("click", function () {
        cleanup(box.value, function (cleaned) { box.value = cleaned; saveDraft(cleaned); });
      });
      h.$("jot-search").addEventListener("input", render);
      h.$("jot-tag").addEventListener("change", render);
    }

    return { restore: restore, drop: drop, sync: pull, remove: remove, render: render, wire: wire, shareSheet: shareSheet, cleanup: cleanup,
      add: function (text) { return queueAction({ op: "add", text: text }); },
      focus: function () { setTimeout(function () { h.$("jot-text").focus(); }, 80); } };
  }
