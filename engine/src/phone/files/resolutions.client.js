  // ---- Resolutions (More › Resolutions): this quarter's goals as the Mac sent them, read-only. Pure functions. ----

  // One goal's counts, without scoring: "2 done · 3 open", or "Nothing linked yet".
  function goalCounts(g) {
    var done = typeof g.done === "number" ? g.done : 0, open = typeof g.open === "number" ? g.open : 0;
    return done || open ? done + " done · " + open + " open" : "Nothing linked yet";
  }

  // The screen: the quarter's title and each goal with its parent, counts and the titles of its open tasks (from the board,
  // so a task ticked on the phone drops out at once). Bad entries are skipped.
  function goalsView(goals, cards) {
    var byId = {};
    (cards || []).forEach(function (c) { if (c && typeof c.id === "number") byId[c.id] = c; });
    var items = (Array.isArray(goals) ? goals : []).filter(function (g) {
      return g && typeof g.id === "string" && typeof g.title === "string";
    }).map(function (g) {
      var tasks = (Array.isArray(g.tasks) ? g.tasks : []).map(function (id) { return byId[id]; })
        .filter(function (c) { return c && c.status !== "done"; }).map(function (c) { return c.title; });
      return { id: g.id, title: g.title, parent: typeof g.parent === "string" && g.parent ? "under " + g.parent : "",
        counts: goalCounts(g), tasks: tasks };
    });
    var first = (Array.isArray(goals) ? goals : []).filter(function (g) { return g && typeof g.period === "string"; })[0];
    return { period: first ? first.period : null, items: items };
  }

  // The More row's second line.
  function goalsSub(goals) {
    var list = (Array.isArray(goals) ? goals : []).filter(function (g) { return g && typeof g.id === "string"; });
    if (!list.length) return "No goals this quarter yet";
    return (list[0].period || "This quarter") + " · " + list.length + " goal" + (list.length === 1 ? "" : "s");
  }
