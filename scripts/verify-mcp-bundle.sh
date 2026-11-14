#!/bin/bash
# Checks the help MCP server inside a built MultiCred.app:
#   scripts/verify-mcp-bundle.sh dist/MultiCred.app
# - the helper exists, is signed and the whole bundle verifies;
# - it speaks MCP over stdio (initialize + tools/list) and offers exactly the four read-only tools.
# Only initialize and tools/list are sent, so nothing on this Mac is read or changed.
set -euo pipefail

APP="${1:?usage: verify-mcp-bundle.sh path/to/MultiCred.app}"
HELPER="$APP/Contents/Helpers/multicred-mcp"

[[ -x "$HELPER" ]] || { echo "missing helper: $HELPER" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
codesign --verify --strict "$HELPER"

REPLY="$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | "$HELPER")"

NAMES="$(printf '%s\n' "$REPLY" | python3 -I -c '
import json, sys
names = []
for line in sys.stdin:
    result = json.loads(line).get("result", {})
    names += [t["name"] for t in result.get("tools", [])]
print(",".join(names))')"

EXPECTED="sobre_o_multicred,como_fazer,solucao_de_problemas,diagnostico_do_meu_multicred"
if [[ "$NAMES" != "$EXPECTED" ]]; then
  echo "unexpected tools: $NAMES" >&2
  exit 1
fi
echo "multicred-mcp ok: $NAMES"
