#!/bin/bash
# Fails if FloatBoardCore touches the network. Core must stay offline and deterministic.
cd "$(dirname "$0")/.."
if grep -rnE "URLSession|import Network|NWListener" Sources/FloatBoardCore; then
  echo "FAIL: FloatBoardCore must not use networking"; exit 1
fi
echo "core offline OK"
