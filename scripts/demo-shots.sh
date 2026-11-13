#!/bin/bash
# Regenerates docs/*.png from docs/demo (fake data) using the Debug build, in the background.
set -uo pipefail
cd "$(dirname "$0")/.."; ROOT="$PWD"
export LANTERN_HOME="$(mktemp -d /tmp/lt.XXXX)" LANTERN_TEST=1
APP="$ROOT/build/Build/Products/Debug/Lantern.app"; export LANTERN_APP="$APP"
L="$ROOT/build/Build/Products/Debug/lantern"; D="$ROOT/docs/demo"
trap '"$L" close >/dev/null 2>&1; pkill -f "$APP/Contents/MacOS/Lantern" 2>/dev/null; rm -rf "$LANTERN_HOME"' EXIT
ev(){ "$L" eval "$1" >/dev/null 2>&1; }
"$L" open "$D" >/dev/null; sleep 3
"$L" window --width 1100 --height 760 >/dev/null 2>&1; sleep 1
"$L" switch migration >/dev/null 2>&1; sleep 1
"$L" snapshot "$ROOT/docs/hero.png" >/dev/null; sleep 0.5
ev "(()=>{const p=[...document.querySelectorAll('.blk p')].find(p=>p.textContent.includes('append-only'));const t=p.lastChild;const i=t.textContent.indexOf('append-only event log');const r=document.createRange();r.setStart(t,i);r.setEnd(t,i+21);const s=getSelection();s.removeAllRanges();s.addRange(r);p.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}))})()"; sleep 0.4
ev "document.getElementById('cbtn').click()"; sleep 0.2
ev "(()=>{const t=document.querySelector('#cpop textarea');t.value='Love it. Can we keep a snapshot every 10k events to speed up replays?';[...document.querySelectorAll('#cpop .ask-send')][0].click()})()"; sleep 0.8
"$L" snapshot "$ROOT/docs/comments.png" >/dev/null
ev "getSelection().removeAllRanges()"; ev "document.getElementById('doc').scrollTop=99999"; sleep 0.6
"$L" snapshot "$ROOT/docs/ask.png" >/dev/null
ev "document.documentElement.dataset.theme='dark'"; ev "document.getElementById('doc').scrollTop=0"; sleep 0.5
"$L" snapshot "$ROOT/docs/dark.png" >/dev/null
