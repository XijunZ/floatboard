/**
 * The phone app's offline queue logic, as plain functions with no access to the page, storage or network. The source is
 * embedded in `/app/app.js` (src/app/client.ts) and tests run the same text (test/phone-sync.test.ts), so what is tested
 * is exactly what the phone runs.
 *
 * - `viewBoard(board, actions)`: the board as the phone shows it: the last board from the engine plus queued actions not
 *   sent yet (moves change the step, adds show as cards waiting for the Mac).
 * - `takeBatch(actions, sentAt)`: the next request body for `POST /app/api/action`: at most 100 actions and under 60 KB.
 * - `sendBatch(body, send, now)`: sends one batch; when the engine refuses it as malformed (400), sends each action on
 *   its own once and reports the ones still refused (`rejected`) so they can leave the queue instead of blocking it.
 * - `afterSend(actions, sentIds, result)`: drops accepted and dropped ids from the queue.
 * - `noticeSuperseded(sentIds, superseded)`: which of this phone's sent ids the engine reports as not applied.
 * - `retryDelay(failures)`: 5 s doubling to 5 minutes.
 * - `statusText(s)`: the one-line sync status at the top of the board.
 *
 * Kept as a string: no backticks or dollar-brace inside.
 */
export const SYNC_JS = String.raw`
  var BATCH_MAX = 100;
  var BATCH_BYTES = 60000;
  var SENT_KEEP = 200;

  function viewBoard(board, actions) {
    var cards = ((board && Array.isArray(board.cards)) ? board.cards : []).map(function (c) { return Object.assign({}, c); });
    var addsShown = {};
    cards.forEach(function (c) { if (c.action_id) addsShown[c.action_id] = true; });
    var temp = 0;
    (actions || []).forEach(function (a) {
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
        if (c.id === a.card_id && !c.pending) {
          if (c.status !== a.action) c.done_at = a.action === "done" ? a.made_at : null;
          c.status = a.action;
          c.status_at = a.made_at;
          c.queued = true;
          break;
        }
      }
    });
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
      var n = byteLength(JSON.stringify(item)) + 1;
      if (out.length && size + n > BATCH_BYTES) break;
      size += n;
      out.push(item);
    }
    return { sent_at: sentAt, actions: out };
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

  function replacedText(superseded, dropped, rejected) {
    var parts = [];
    if (superseded) parts.push(superseded === 1 ? "1 change was replaced by a newer change on your Mac" : superseded + " changes were replaced by newer changes on your Mac");
    if (dropped) parts.push(dropped === 1 ? "1 change was for a task no longer on your board" : dropped + " changes were for tasks no longer on your board");
    if (rejected) parts.push(rejected === 1 ? "1 change couldn't be sent" : rejected + " changes couldn't be sent");
    return parts.join(". ");
  }
`;

/** Names the tests pull out of SYNC_JS. */
export const SYNC_EXPORTS = ["viewBoard", "takeBatch", "sendBatch", "afterSend", "rememberSent", "noticeSuperseded", "retryDelay", "statusText",
  "replacedText", "byteLength"];
