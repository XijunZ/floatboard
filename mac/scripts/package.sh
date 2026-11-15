#!/bin/bash
# Builds FloatBoard and zips it for sharing (e.g. AirDrop): dist/FloatBoard.zip
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh >/dev/null
mkdir -p dist
rm -f dist/FloatBoard.zip
ditto -c -k --keepParent build/FloatBoard.app dist/FloatBoard.zip
echo "dist/FloatBoard.zip ($(du -h dist/FloatBoard.zip | cut -f1))"
