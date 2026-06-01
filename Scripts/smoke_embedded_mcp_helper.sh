#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-}"
SMOKE_LABEL="${2:-Embedded MCP helper}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -n "$APP_BUNDLE" ]] || fail "Usage: $0 <app-bundle> [label]"
[[ -d "$APP_BUNDLE" ]] || fail "Missing app bundle: $APP_BUNDLE"

MCP_HELPER="$APP_BUNDLE/Contents/MacOS/repoprompt-mcp"
[[ -x "$MCP_HELPER" ]] || fail "Missing executable MCP helper: $MCP_HELPER"

status=0
"$MCP_HELPER" --version || status=$?
(( status == 0 )) ||
    fail "$SMOKE_LABEL failed --version smoke (exit $status): $MCP_HELPER"

printf 'OK: %s passed --version smoke.\n' "$SMOKE_LABEL"
