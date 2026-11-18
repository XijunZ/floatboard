#!/bin/bash
# Builds the engine for Mac only mode (Resources/engine.js) fresh from ../engine, installing the engine's packages first when
# node_modules is missing or older than package-lock.json. Stops (exit 1) with a clear message when npm or the build fails:
# an app build never ships an old engine.js. Used by build-app.sh; checked by FloatBoardChecks (UpdatePathChecks.swift),
# which points FLOATBOARD_ENGINE_DIR and FLOATBOARD_ENGINE_OUT at scratch folders.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
ENGINE_DIR="${FLOATBOARD_ENGINE_DIR:-$here/../../engine}"
export FLOATBOARD_ENGINE_OUT="${FLOATBOARD_ENGINE_OUT:-$here/../Resources/engine.js}"
command -v npm >/dev/null || { echo "error: npm (Node.js) is needed to build the engine. Install Node.js, then build again." >&2; exit 1; }
command -v node >/dev/null || { echo "error: node (Node.js) is needed to build the engine. Install Node.js, then build again." >&2; exit 1; }
lock="$ENGINE_DIR/package-lock.json"; installed="$ENGINE_DIR/node_modules/.package-lock.json"
if [ ! -d "$ENGINE_DIR/node_modules" ] || [ ! -f "$installed" ] || [ "$lock" -nt "$installed" ]; then
  echo "Installing the engine's packages (npm ci)…"
  (cd "$ENGINE_DIR" && npm ci --silent) || { echo "error: 'npm ci' in engine/ failed; nothing was built." >&2; exit 1; }
fi
rm -f "$FLOATBOARD_ENGINE_OUT"
(cd "$ENGINE_DIR" && node local/build.mjs >/dev/null) || { echo "error: building the engine (Resources/engine.js) failed; nothing was installed." >&2; exit 1; }
[ -s "$FLOATBOARD_ENGINE_OUT" ] || { echo "error: the engine build wrote no Resources/engine.js; nothing was installed." >&2; exit 1; }
