  // ------------------------------------------------------------ Circle: pure logic (tested on its own; see circle-client.ts)

  var CIRCLE_ACTIONS = ["contacted", "talked", "snooze"];

  // The Circle screen as shown: the Mac's copy plus this phone's queued actions (a contacted, talked or snoozed person
  // leaves the due list at once). Bad entries in the copy are skipped.
  function circleView(copy, queued, nowMs) {
    var people = copy && Array.isArray(copy.people) ? copy.people.filter(function (p) { return p && typeof p.id === "string" && typeof p.name === "string"; }) : [];
    var acted = {};
    (queued || []).forEach(function (a) { if (a && a.person && CIRCLE_ACTIONS.indexOf(a.action) >= 0) acted[a.person] = a; });
    var dueIds = copy && Array.isArray(copy.due) ? copy.due : [];
    var due = people.filter(function (p) { return dueIds.indexOf(p.id) >= 0 && !acted[p.id]; });
    return { people: people.map(function (p) { return acted[p.id] ? Object.assign({}, p, { due: false, waiting: acted[p.id].action }) : p; }), due: due };
  }

  // The queued action for a tap (its own id, the time it was made).
  function circleAction(person, action, id, nowIso) {
    return { id: id, person: person, action: action, made_at: nowIso };
  }

  // Search: every word in the name, company or tags (case and accents ignored).
  function circleSearch(people, q) {
    var fold = function (s) { return String(s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase(); };
    var words = fold(q).split(/\s+/).filter(Boolean);
    if (!words.length) return people;
    return people.filter(function (p) {
      var hay = fold([p.name, p.company].concat(p.tags || []).join(" "));
      return words.every(function (w) { return hay.indexOf(w) >= 0; });
    });
  }

  // "today", "yesterday", "3 days ago", "12 Nov" (or "never").
  function circleAgo(iso, nowMs) {
    var t = Date.parse(iso || "");
    if (!isFinite(t)) return "never";
    var d = Math.floor((new Date(nowMs).setHours(0, 0, 0, 0) - new Date(t).setHours(0, 0, 0, 0)) / 86400000);
    if (d <= 0) return "today";
    if (d === 1) return "yesterday";
    if (d < 7) return d + " days ago";
    var m = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    var x = new Date(t);
    return x.getDate() + " " + m[x.getMonth()] + (x.getFullYear() !== new Date(nowMs).getFullYear() ? " " + x.getFullYear() : "");
  }

  // The app icon's badge: overdue open tasks plus people due (§10).
  function badgeCount(cards, dueCount, nowMs) {
    var start = new Date(nowMs); start.setHours(0, 0, 0, 0);
    var overdue = (cards || []).filter(function (c) {
      if (!c || c.status === "done" || !c.due) return false;
      var t = Date.parse(c.due);
      return isFinite(t) && (c.has_time ? t < nowMs : t < start.getTime());
    }).length;
    return overdue + (dueCount || 0);
  }

  // Where a draft opens: WhatsApp (wa.me with the text) or Gmail's compose window; null when the person has neither.
  function draftLink(person, text) {
    var t = encodeURIComponent(text || "");
    if (person && /^\d{8,15}$/.test(person.wa || "")) return "https://wa.me/" + person.wa + "?text=" + t;
    if (person && /^[^@\s]+@[^@\s]+$/.test(person.email || "")) return "https://mail.google.com/mail/?view=cm&to=" + encodeURIComponent(person.email) + "&body=" + t;
    return null;
  }

  // A notification button arrives as "#circle=contacted:P-12" when the service worker could not send it itself.
  function circleHash(hash) {
    var m = /[#&]circle=(contacted|talked|snooze):(P-\d{1,12})(?::([0-9a-f]{32}))?/.exec(hash || "");
    if (!m) return null;
    var h = { action: m[1], person: m[2] };
    if (m[3]) h.account = m[3];
    return h;
  }

  // What the confirm sheet for a link's action says (a link never acts by itself); null for someone not on this phone.
  // A link that names another account (an old alert after switching) shows nothing.
  function circleConfirm(h, people, account) {
    if (h && h.account && h.account !== account) return null;
    var p = h && (people || []).filter(function (x) { return x && x.id === h.person; })[0];
    if (!p) return null;
    var text = h.action === "talked" ? "Mark talked to " + p.name + "?" : h.action === "snooze" ? "Snooze " + p.name + "?" : "Mark " + p.name + " as contacted?";
    return { action: h.action, person: p.id, text: text };
  }
