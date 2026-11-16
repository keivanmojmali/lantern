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
add(){ ev "(()=>{const p=[...document.querySelectorAll('#docin .blk p, #docin .blk li, #docin .blk td')].find(p=>p.textContent.includes('$1'));const w=document.createTreeWalker(p,NodeFilter.SHOW_TEXT);let n;while(n=w.nextNode()){const i=n.textContent.indexOf('$1');if(i>=0){const r=document.createRange();r.setStart(n,i);r.setEnd(n,i+'$1'.length);const s=getSelection();s.removeAllRanges();s.addRange(r);p.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));return 1}}})()"; sleep 0.4
  ev "document.getElementById('cbtn').click()"; sleep 0.2
  ev "(()=>{const t=document.querySelector('#cpop textarea');t.value='$2';[...document.querySelectorAll('#cpop .ask-send')][0].click()})()"; sleep 0.6; }
add "append-only event log" "Can we snapshot every 10k events so replays stay fast?"
add "Dual-write events" "Run this off-peak. Last time it locked the table."
add "Sign-off from Finance" "Ping Priya, she owns this."
ev "document.dispatchEvent(new KeyboardEvent('keydown',{code:'KeyC',key:'c',metaKey:true,shiftKey:true,bubbles:true}))"; sleep 0.8
ev "document.querySelectorAll('#csb .crow')[1].click()"; sleep 1.2
"$L" snapshot "$ROOT/docs/comments.png" >/dev/null
ev "document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))"; ev "getSelection().removeAllRanges()"; ev "document.getElementById('doc').scrollTop=99999"; sleep 0.6
"$L" snapshot "$ROOT/docs/ask.png" >/dev/null
ev "document.documentElement.dataset.theme='dark'"; ev "document.getElementById('doc').scrollTop=0"; sleep 0.5
"$L" snapshot "$ROOT/docs/dark.png" >/dev/null
