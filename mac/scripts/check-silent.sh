#!/bin/bash
# Fails listing every `try?` in app/Sources that lacks a `// try?-ok:` justification on the same line.
cd "$(dirname "$0")/.."
hits=$(grep -rn 'try?' Sources --include='*.swift' | grep -v '// try?-ok:' || true)
if [ -n "$hits" ]; then
  echo "$hits"; echo "FAIL: $(echo "$hits" | wc -l | tr -d ' ') unannotated try? (swallowed errors)"; exit 1
fi
echo "no silent try? OK"
