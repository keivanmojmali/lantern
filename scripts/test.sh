#!/bin/bash
# End-to-end test: runs the real app in the BACKGROUND (no Dock icon, no focus steal, window placed
# off-screen, isolated data dir) and takes screenshots with WKWebView.takeSnapshot.
# It never touches your real windows or ~/.lantern.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"; OUT="${OUT:-$ROOT/tests/screenshots}"; mkdir -p "$OUT"
export LANTERN_HOME="$(mktemp -d /tmp/lt.XXXX)"; export LANTERN_TEST=1
WORK="$(mktemp -d /tmp/ltw.XXXX)"; cp -R tests/fixtures/* "$WORK/"
APP="$ROOT/build/Build/Products/Debug/Lantern.app"; export LANTERN_APP="$APP"
L="$ROOT/build/Build/Products/Debug/lantern"
PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
ev()   { "$L" eval "$1" 2>&1; }
shot() { "$L" snapshot "$OUT/$1.png" >/dev/null 2>&1; sleep 0.3; }
cleanup(){ "$L" close >/dev/null 2>&1; pkill -f "$APP/Contents/MacOS/Lantern" 2>/dev/null; rm -rf "$LANTERN_HOME" "$WORK"; }
trap cleanup EXIT

echo "== open a single plan (window, background)"
"$L" open "$WORK/plan.md" >/dev/null; sleep 2.5
shot 01-single
check "plan rendered"            '[[ "$(ev "document.querySelectorAll(\".blk\").length")" -gt 8 ]]'
check "frontmatter card"         '[[ "$(ev "!!document.querySelector(\".front\")")" != 0 ]]'
check "code highlighted"         '[[ "$(ev "document.querySelectorAll(\"pre code .hljs-keyword\").length>0")" != 0 ]]'
check "table wrapped"            '[[ "$(ev "document.querySelectorAll(\".tablewrap table\").length")" == 1 ]]'
check "task circles (2/4 done)"  '[[ "$(ev "document.querySelectorAll(\"input[type=checkbox]:checked\").length")" == 2 ]]'
check "file refs clickable"      '[[ "$(ev "document.querySelectorAll(\".ref\").length")" -ge 2 ]]'
check "mermaid svg rendered"     '[[ "$(ev "!!document.querySelector(\".mermaid-wrap svg\")")" != 0 ]]'
check "single file: no tab strip" '[[ "$(ev "document.getElementById(\"tabs\").hidden")" != 0 ]]'
check "no review/approve UI"     '[[ "$(ev "document.querySelectorAll(\"button:not(.tab):not(.copy)\").length")" == 0 ]]'
check "md file untouched"        '[[ -z "$(ls "$WORK"/plan.md.* 2>/dev/null)" ]] && diff -q tests/fixtures/plan.md "$WORK/plan.md" >/dev/null'

echo "== live edit glows"
printf '\n## New section\n\nClaude just added this block.\n' >> "$WORK/plan.md"; sleep 1.0
shot 02-glow
check "changed block glows"      '[[ "$(ev "document.querySelectorAll(\".glow\").length")" -ge 1 ]]'

echo "== folder: horizontal tabs"
"$L" close >/dev/null 2>&1; sleep 0.5
"$L" open "$WORK/plans" >/dev/null; sleep 2
shot 03-folder-tabs
check "folder opens both plans"  '[[ "$("$L" list | wc -l | tr -d " ")" == 2 ]]'
check "tabs strip visible"       '[[ "$(ev "document.querySelectorAll(\"#tabs .tab\").length")" == 2 ]]'
check "tabs are one horizontal row" '[[ "$(ev "(()=>{const t=[...document.querySelectorAll(\"#tabs .tab\")];return t[0].getBoundingClientRect().top===t[1].getBoundingClientRect().top})()")" != 0 ]]'
check "switch by name"           '"$L" switch beta >/dev/null; [[ "$(ev "document.querySelector(\"#tabs .tab.on\").textContent")" == beta* ]]'
printf '# Gamma\n\nnew plan\n' > "$WORK/plans/gamma.md"; sleep 7
shot 04-new-tab
check "new file adds a tab w/ dot" '[[ "$(ev "document.querySelectorAll(\"#tabs .tab\").length")" == 3 && "$(ev "!!document.querySelector(\"#tabs .dot\")")" != 0 ]]'

echo "== MCP server (what Claude uses)"
mcp() { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}' "$1" | "$L" mcp; }
check "mcp lists 6 tools"        '[[ "$(mcp "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}" | grep -o lantern_ | wc -l | tr -d " ")" -ge 6 ]]'
check "mcp switch works"         '[[ "$(mcp "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"lantern_switch\",\"arguments\":{\"target\":\"alpha\"}}}")" == *"switched to alpha"* ]]'
check "mcp window resize works"         '[[ "$(mcp "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"lantern_window\",\"arguments\":{\"width\":640,\"height\":500}}}")" == *"640x500"* ]]'
check "mcp reports bad path as error" '[[ "$(mcp "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"lantern_open\",\"arguments\":{\"paths\":[\"/nope.md\"]}}}")" == *"isError\":true"* ]]'

echo "== details / footnotes / broken images"
"$L" open "$WORK/extras.md" >/dev/null; sleep 2; "$L" switch extras >/dev/null; sleep 1
shot 03-extras
check "details is one block"     '[[ "$(ev "document.querySelector(\"details\").textContent.includes(\"Hidden content\")")" != 0 ]]'
check "footnotes numbered"       '[[ "$(ev "document.querySelectorAll(\"sup.fn\").length")" == 2 && "$(ev "document.querySelectorAll(\"ol.footnotes li\").length")" == 2 ]]'
check "broken image placeholder" '[[ "$(ev "document.querySelectorAll(\".imgerr\").length")" == 1 ]]'

echo "== dark"
ev "document.documentElement.dataset.theme='dark'" >/dev/null; shot 05-dark
echo "== close"
"$L" close >/dev/null 2>&1; sleep 0.5
check "close removes plans"      '[[ "$("$L" list | wc -l | tr -d " ")" == 0 ]]'

echo
echo "passed: $PASS  failed: $FAIL   screenshots: $OUT"
[[ $FAIL == 0 ]]
