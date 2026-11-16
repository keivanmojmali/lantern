# Comments sidebar

A docked panel on the right that lists every comment on the open plan. Click a row and the document scrolls to the highlight. It replaces today's small floating list.

## What exists today

- Floating list `#clist`, opened from the "N comments" pill (`Resources/web/comments.js:125-150`, styled at `Resources/web/style.css:105`).
- Rows already scroll to and pulse the highlight (`comments.js:145`) and have a delete button (`comments.js:142`).
- Layout is a column: tabs, then `#doc` (`style.css:57-60`), so there is no room for a side panel yet.

So this is mostly **layout + a better list**, not new data plumbing.

## Behaviour

| Area | Decision |
|------|----------|
| Open / close | Toggle with the "N comments" pill, **⌘⇧C**, or **Esc**. Remembered per window across launches. |
| Layout | Doc shrinks, sidebar docks right at 320px. Below ~900px wide it overlays instead of squeezing the doc. |
| Rows | Quote (clamped), comment text, section heading, relative time. Ordered **by position in the doc**, not creation time. |
| Click a row | Scroll to the highlight, pulse it, mark the row active. |
| Scroll the doc | The row for the highlight nearest the top of the viewport gets an active style (scroll-spy). |
| Edit / delete | Click the text to edit in place, ✕ to delete. Same save path as today. |
| Detached comments | Quote no longer found: dimmed, "text changed" badge, grouped at the bottom. |
| Footer | **Done — send to Claude** moves here. The floating pill keeps only the count. |
| Empty state | "Select text in the plan to leave a comment." |

## Mockup

```
┌───────────────────────────────────────┬──────────────────┐
│ plan.md   notes.md                    │ Comments (3)   ✕ │
├───────────────────────────────────────┤──────────────────┤
│ # Migrate billing                     │ ▌“append-only…”  │
│ We move to an [append-only event log] │ ▌ Keep snapshots │
│ with projections.                     │ ▌ §Migrate       │
│                                       │                  │
│ ## Rollout                            │  “Cut reads…”    │
│ ...                                   │   Behind a flag? │
│                                       │──────────────────│
│                                       │ [Done — send]    │
└───────────────────────────────────────┴──────────────────┘
```

## Implementation steps

1. **Layout** (`index.html`, `style.css`). Wrap `#doc` and a new `<aside id="csb">` in a flex row. Add a `body.csb-open` class that sets the sidebar width. Keep `#doc` as the scroll container so `scrollTop` handling in `app.js` stays valid.
2. **Sidebar module** (`comments.js`). Replace `fillList` with `renderSidebar()`. Sort by the DOM position of each `mark.cmt`, using `compareDocumentPosition`. Call it from `bar()` so every existing save, render and tab switch refreshes it for free.
3. **Scroll-spy** (`comments.js`). On `#doc` scroll, throttled with `requestAnimationFrame`, find the first `mark.cmt` whose rect is below the top edge and set `.active` on its row. Scroll the sidebar to keep that row visible.
4. **Inline edit.** Reuse `editor()` (`comments.js:97`) but anchor it to the row instead of the highlight.
5. **Toggle + persistence.** Add the ⌘⇧C shortcut in the keydown handler (`comments.js:89`). Persist open or closed via `localStorage`, or via the existing app state if the web view data store is non-persistent. Check this first.
6. **Slim the pill.** Pill shows the count and toggles the sidebar. Remove `#clist`.
7. **Tests** (`scripts/test.sh`, new "comments sidebar" section). Cover: sidebar hidden by default, toggle opens it, rows ordered by doc position, row click scrolls and pulses, delete from the sidebar updates the highlight, detached comment shown dimmed, state survives a re-render. Add a `08-sidebar.png` screenshot.
8. **Docs.** Add a sidebar screenshot to `docs/demo-shots.sh` output, plus one line in the README.

## Risks

- **Mermaid and wide tables** re-measure when the doc shrinks. Fix: re-run the layout on `ResizeObserver`, which is already likely in place; verify.
- **Scroll position on toggle** can jump when the doc width changes. Fix: capture the top-most block before toggling and restore it afterwards.
- **`localStorage` persistence** in `WKWebView` depends on the data store. Fall back to a Swift-side setting if it doesn't stick.

## Open questions

```answer q1
Should the sidebar open automatically the first time you add a comment, or only when you toggle it?
```

```answer q2
Should the Done button live in the sidebar footer (my suggestion), or stay in the floating pill?
```
