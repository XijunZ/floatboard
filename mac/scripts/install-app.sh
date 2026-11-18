#!/bin/bash
# Installs a built FloatBoard.app: copied beside the installed one first, then swapped in, so a failed copy leaves the old
# app in place. Prints INSTALLED_AT=<path> (Update now reopens that copy). Usage: install-app.sh <built .app>
#   FLOATBOARD_FROM_UPDATER=1: run by the app's Update now; the app quits and reopens itself, so nothing is stopped here.
#   FLOATBOARD_INSTALL_DEST=<folder>: install there instead (checks, on scratch folders); nothing is stopped or opened.
set -euo pipefail
APP="$1"
if [ -n "${FLOATBOARD_INSTALL_DEST:-}" ]; then DEST="$FLOATBOARD_INSTALL_DEST"; MANAGED=0
else DEST=/Applications; [ -w "$DEST" ] || DEST="$HOME/Applications"; MANAGED=1; fi
NEW="$DEST/.FloatBoard.app.new"; OLD="$DEST/.FloatBoard.app.old"
# An earlier install stopped between its two moves (the app moved aside, the new one not in): put the app back first,
# before anything is cleared, whatever happens next.
if [ ! -d "$DEST/FloatBoard.app" ] && [ -d "$OLD" ]; then mv "$OLD" "$DEST/FloatBoard.app"; fi
[ -d "$APP" ] || { echo "error: no built app at $APP; nothing was installed." >&2; exit 1; }
mkdir -p "$DEST"
rm -rf "$NEW" "$OLD"
cp -R "$APP" "$NEW" || { rm -rf "$NEW"; echo "error: copying the new app failed; the installed one is unchanged." >&2; exit 1; }
if [ "$MANAGED" = 1 ] && [ -z "${FLOATBOARD_FROM_UPDATER:-}" ]; then pkill -x FloatBoard 2>/dev/null || true; fi
[ -d "$DEST/FloatBoard.app" ] && mv "$DEST/FloatBoard.app" "$OLD"
if ! mv "$NEW" "$DEST/FloatBoard.app"; then
  [ -d "$OLD" ] && mv "$OLD" "$DEST/FloatBoard.app"
  echo "error: swapping in the new app failed; the installed one is unchanged." >&2; exit 1
fi
rm -rf "$OLD"
echo "Installed to $DEST/FloatBoard.app"
echo "INSTALLED_AT=$DEST/FloatBoard.app"
# A manual install reopens the app it stopped; Update now reopens it itself.
if [ "$MANAGED" = 1 ] && [ -z "${FLOATBOARD_FROM_UPDATER:-}" ]; then open "$DEST/FloatBoard.app" || true; fi
